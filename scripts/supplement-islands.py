#!/usr/bin/env python3
"""
Supplement the offline-geocoder's `island` table with Wikidata-classified
islands that OSM's `place=island` filter (Phase 1E) misses.

# Why

OSM data quality is uneven: some islands lack the canonical `place=island`
tag. A named multipolygon relation can be linked to a Wikidata island
without a `place=` tag, so `osmium tags-filter r/place=island` skips it.
Without supplementation, reverse-geocoding a point inside that island
returns nil islandName.

Wikidata maintains an authoritative classification: P31=Q23442 ("instance
of: island") plus subclasses. P402 ("OpenStreetMap relation ID") links the
Wikidata item to its OSM relation. This script:

  1. Reads Wikidata's relation-link list (scripts/wikidata-island-relations.csv).
  2. Computes which of those relations are NOT already in our island layer
     (cross-referenced via the real OSM relation ID — requires the build
     script to have been run with `osmium export -a id,type`).
  3. Extracts those missing relations from the planet PBF (with referenced
     ways/nodes via `osmium getid -r`) — done as a pre-step, outside this
     script. Input: a pre-extracted GeoJSON dump of the candidates.
  4. Classifies each by its OSM tag pattern; the --variant flag selects
     which classes to include.
  5. Simplifies each polygon (more leniently than Phase 1E so we don't
     drop multi-islet structures like Bassas da India), encodes WKB,
     INSERTs into the island table.

# Variants

  --variant=B : missing-tag relations only: lacking place/natural/boundary
                tags (true OSM mistagging). ~38 islands.
  --variant=C : B + relations tagged `place=island` whose geometry collapsed
                under Phase 1E's 0.005° simplification. ~700 islands.
  --variant=D : C + relations tagged `boundary=administrative` OR
                `place=town/village/city/hamlet` that Wikidata classifies as
                island. ~1700 islands. WARNING: includes admin polygons that
                may extend beyond the physical island.
  --variant=E : D + sane spatial deduplication against the baseline.

# Output

Writes to --output. Input SQLite is read-only: an --output that names the
baseline (same path, symlink, hardlink or case variant) is refused before
anything is written, and so is a ship-trimmed baseline. New rows are INSERTed
into the `island` table with osm_id = 2_000_000_000_000 + relation_id (same
packing convention as the main build script). R-tree is updated. Journal
mode flipped to DELETE before exit.

The copy is supplemented under a temporary name next to --output and moved
into place only after finalization, so a failed or interrupted run leaves no
partial file there and an earlier completed --output stays as it was.

# Usage

Keep intermediates outside the synchronized `TravelLog/` folder:

    python3 scripts/supplement-islands.py \\
        --baseline .build-cache/geocoder/Geocoder.sqlite.new \\
        --output   .build-cache/geocoder/Geocoder.sqlite.B \\
        --candidates .build-cache/geocoder/relations.geojson \\
        --variant B
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import shutil
import sqlite3
import struct
import sys
import tempfile
import time
from contextlib import closing
from pathlib import Path

# Reuse simplify_geometry / encode_wkb from the main build script.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import importlib.util as _ilu
_bgd_spec = _ilu.spec_from_file_location("bgd", Path(__file__).resolve().parent / "build-geocoder-db.py")
bgd = _ilu.module_from_spec(_bgd_spec)
_bgd_spec.loader.exec_module(bgd)

REL_OFF = 2 * (10 ** 12)
WAY_OFF = 10 ** 12

# Default simplification tolerance for newly-ingested island polygons.
# 0.005° matches Phase 1E for consistency, but the simplifier here is
# more lenient (preserves rings smaller than the tolerance rather than
# dropping them — fixes the Bassas da India class of multi-islet
# collapse).
TOLERANCE = 0.005


def _lenient_simplify(geom: dict, tolerance: float) -> dict:
    """
    Like bgd.simplify_geometry but: if a ring is smaller than `tolerance`
    in diameter, keep it AS IS rather than collapsing it.  Without this,
    Bassas-da-India-class multi-islet structures lose every individual
    ring (each is < 0.005° across) even though the overall MultiPolygon
    bbox passes the area filter.
    """
    t = geom.get("type")
    if t == "Polygon":
        return {"type": "Polygon", "coordinates": _lenient_rings(geom["coordinates"], tolerance)}
    if t == "MultiPolygon":
        polys: list[list[list[list[float]]]] = []
        for poly in geom["coordinates"]:
            filtered = _lenient_rings(poly, tolerance)
            if filtered:
                polys.append(filtered)
        return {"type": "MultiPolygon", "coordinates": polys}
    return geom


def _ring_diameter(ring: list[list[float]]) -> float:
    if not ring:
        return 0.0
    lats = [p[1] for p in ring]; lons = [p[0] for p in ring]
    return max(max(lats) - min(lats), max(lons) - min(lons))


def _lenient_rings(rings: list[list[list[float]]], tolerance: float) -> list[list[list[float]]]:
    if not rings:
        return []
    outer = rings[0]
    if _ring_diameter(outer) < tolerance:
        simplified_outer = outer if len(outer) >= 4 else []
    else:
        simplified_outer = bgd.simplify_ring(outer, tolerance)
        if len(simplified_outer) < 4:
            simplified_outer = outer if len(outer) >= 4 else []
    if not simplified_outer:
        return []
    result = [simplified_outer]
    for r in rings[1:]:
        if _ring_diameter(r) < tolerance:
            simp = r if len(r) >= 4 else []
        else:
            simp = bgd.simplify_ring(r, tolerance)
            if len(simp) < 4 and len(r) >= 4:
                simp = r
        if len(simp) >= 4:
            result.append(simp)
    return result


def _classify(props: dict, geom: dict) -> str:
    """Categorize a relation by its OSM tagging into one of the named buckets."""
    place = props.get("place")
    natural = props.get("natural")
    boundary = props.get("boundary")
    geom_type = geom.get("type")
    if geom_type not in ("Polygon", "MultiPolygon"):
        return "no_polygon"
    if place == "island":
        return "place_island_collapsed"
    if natural == "peninsula":
        return "peninsula"
    if natural:
        return "natural_other"
    if boundary == "administrative":
        # A state or territory boundary is never an island shape. Wikidata
        # classes island countries (Bahrain, Samoa, Comoros) under island, and
        # their national polygons, territorial waters included, beat the real
        # island under the resolver's largest-below-the-cap rule (Bequia read
        # "Saint Vincent and the Grenadines") or push it over the cap (Jamaica,
        # Okinawa read nil). Municipal levels stay: there the boundary is
        # often the only polygon the island has.
        if props.get("ISO3166-1") or str(props.get("admin_level", "")).strip() in ("2", "3", "4"):
            return "admin_state_level"
        return "admin_boundary"
    if boundary == "national_park":
        return "national_park"
    if boundary:
        return "boundary_other"
    if place in ("town", "village", "city", "hamlet", "locality"):
        return "settled_place"
    if place:
        return "place_other"
    return "missing_tag_relation"   # no place/natural/boundary tags, just multipolygon


VARIANT_INCLUDE = {
    "B": {"missing_tag_relation"},
    "C": {"missing_tag_relation", "place_island_collapsed"},
    "D": {"missing_tag_relation", "place_island_collapsed", "admin_boundary", "settled_place"},
    "E": {"missing_tag_relation", "place_island_collapsed", "admin_boundary", "settled_place"},  # same as D but with extra spatial dedup
    # F: D's categories + any Wikidata-linked OSM way (via --candidates-ways).
    # Same allow-set as D for relation processing; the new ways are admitted
    # unconditionally as long as they form a valid polygon and have a name.
    "F": {"missing_tag_relation", "place_island_collapsed", "admin_boundary", "settled_place"},
}


def _wikidata_relation_set(csv_path: Path) -> set[int]:
    s = set()
    with open(csv_path) as f:
        for row in csv.DictReader(f):
            v = row.get("osm_rel", "").strip()
            if v.isdigit():
                s.add(int(v))
    return s


def _baseline_relation_set(conn: sqlite3.Connection) -> set[int]:
    s = set()
    for (osm_id,) in conn.execute("SELECT osm_id FROM island WHERE osm_id BETWEEN ? AND ?",
                                   (REL_OFF, 3 * 10**12 - 1)):
        s.add(osm_id - REL_OFF)
    return s


def _baseline_bboxes(conn: sqlite3.Connection):
    """Returns list of (osm_id, min_lat, max_lat, min_lon, max_lon) for spatial dedup."""
    return conn.execute("SELECT osm_id, min_lat, max_lat, min_lon, max_lon FROM island_rtree").fetchall()


def _bbox_overlaps(a, b, eps=0.001):
    """True if bbox a and b overlap significantly (>50% of smaller bbox)."""
    a_lo_lat, a_hi_lat, a_lo_lon, a_hi_lon = a
    b_lo_lat, b_hi_lat, b_lo_lon, b_hi_lon = b
    # intersection bbox
    lo_lat = max(a_lo_lat, b_lo_lat)
    hi_lat = min(a_hi_lat, b_hi_lat)
    lo_lon = max(a_lo_lon, b_lo_lon)
    hi_lon = min(a_hi_lon, b_hi_lon)
    if lo_lat >= hi_lat or lo_lon >= hi_lon:
        return False
    inter = (hi_lat - lo_lat) * (hi_lon - lo_lon)
    area_a = max((a_hi_lat - a_lo_lat) * (a_hi_lon - a_lo_lon), eps)
    area_b = max((b_hi_lat - b_lo_lat) * (b_hi_lon - b_lo_lon), eps)
    smaller = min(area_a, area_b)
    return inter / smaller > 0.5


def _is_ship_trimmed(path: Path) -> bool:
    """True when `path` carries ship-trim's marker. Read immutably: nothing,
    not even a -shm sidecar, is written next to the baseline."""
    with closing(sqlite3.connect(f"{path.as_uri()}?mode=ro&immutable=1", uri=True)) as db:
        has_meta = db.execute(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'build_meta'"
        ).fetchone()
        return bool(has_meta) and db.execute(
            "SELECT 1 FROM build_meta WHERE key = 'ship_trim_applied'"
        ).fetchone() is not None


def _remove_candidate(candidate: Path) -> None:
    for suffix in ("", "-journal", "-wal", "-shm"):
        Path(f"{candidate}{suffix}").unlink(missing_ok=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--baseline", type=Path, required=True, help="Input SQLite (read-only)")
    ap.add_argument("--output",   type=Path, required=True, help="Output SQLite (will be created)")
    ap.add_argument("--candidates", type=Path, required=True,
                    help="GeoJSON FeatureCollection of candidate relations (pre-extracted via osmium getid -r)")
    ap.add_argument("--candidates-ways", type=Path,
                    help="GeoJSON FeatureCollection of candidate ways (Variant F only)")
    ap.add_argument("--wikidata-relations", type=Path,
                    default=Path(__file__).resolve().parent / "wikidata-island-relations.csv",
                    help="Wikidata→OSM relation CSV (default: scripts/wikidata-island-relations.csv)")
    ap.add_argument("--wikidata-ways", type=Path,
                    default=Path(__file__).resolve().parent / "wikidata-island-ways.csv",
                    help="Wikidata→OSM way CSV (default: scripts/wikidata-island-ways.csv)")
    ap.add_argument("--variant", choices=list(VARIANT_INCLUDE.keys()), required=True)
    args = ap.parse_args()

    baseline, output = args.baseline.resolve(), args.output.resolve()
    if not baseline.is_file():
        sys.exit(f"baseline {args.baseline} does not exist")
    # Checked before anything is written or removed: an --output naming the
    # baseline used to delete the input, then fail to copy it.
    if output == baseline or (output.exists() and os.path.samefile(baseline, output)):
        sys.exit("ERROR: --output must differ from --baseline")
    if output.is_dir():
        sys.exit(f"ERROR: --output is a directory: {output}")
    if _is_ship_trimmed(baseline):
        sys.exit("ERROR: --baseline is a ship-trimmed file; supplement the full master")

    fd, name = tempfile.mkstemp(prefix=f".{output.name}.", suffix=".partial",
                                dir=output.parent)
    os.close(fd)
    candidate = Path(name)
    try:
        shutil.copyfile(baseline, candidate)
        os.chmod(candidate, 0o644)
        with closing(sqlite3.connect(candidate)) as conn:
            stats, t0 = _supplement(conn, args)
            journal_mode = _finalize(conn)
        if journal_mode.lower() != "delete":
            raise RuntimeError(f"journal_mode is {journal_mode!r} after finalization, not 'delete'")
        os.replace(candidate, output)
    finally:
        _remove_candidate(candidate)

    print(f"\nVariant {args.variant} complete in {time.time() - t0:.1f}s")
    print(f"  Inserted: {stats['inserted']}")
    print(f"  Skipped by category:")
    for k, v in sorted(stats['skipped'].items(), key=lambda x: -x[1]):
        print(f"    {k}: {v}")
    out_mb = output.stat().st_size / 1024 / 1024
    base_mb = baseline.stat().st_size / 1024 / 1024
    print(f"  File size: {base_mb:.1f} MB → {out_mb:.1f} MB (+{out_mb - base_mb:.1f} MB)")


def _supplement(conn: sqlite3.Connection, args) -> tuple[dict, float]:
    """Insert the admitted candidates and stamp the supplement marker."""
    conn.executescript("""
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        PRAGMA cache_size = -50000;
    """)

    wd_rels = _wikidata_relation_set(args.wikidata_relations)
    baseline_rels = _baseline_relation_set(conn)
    target_rels = wd_rels - baseline_rels
    print(f"Baseline islands by relation: {len(baseline_rels):,}")
    print(f"Wikidata island relations:    {len(wd_rels):,}")
    print(f"Candidates not in baseline:   {len(target_rels):,}")

    include = VARIANT_INCLUDE[args.variant]
    print(f"Variant {args.variant} includes categories: {sorted(include)}")

    baseline_bboxes = _baseline_bboxes(conn) if args.variant == "E" else []

    with open(args.candidates) as f:
        data = json.load(f)

    stats = {"inserted": 0, "skipped": {}}
    t0 = time.time()
    inserts = []
    rtree_inserts = []
    for feat in data.get("features", []):
        p = feat.get("properties") or {}
        if p.get("@type") != "relation":
            continue
        rid = p.get("@id")
        if not isinstance(rid, int) or rid not in target_rels:
            continue
        g = feat.get("geometry") or {}
        cat = _classify(p, g)
        if cat not in include:
            stats["skipped"].setdefault(cat, 0)
            stats["skipped"][cat] += 1
            continue

        simplified = _lenient_simplify(g, TOLERANCE)
        if not bgd._polygon_is_valid(simplified):
            stats["skipped"].setdefault("invalid_after_simplify", 0)
            stats["skipped"]["invalid_after_simplify"] += 1
            continue

        try:
            wkb = bgd.encode_wkb(simplified)
        except (ValueError, struct.error):
            stats["skipped"].setdefault("wkb_encode_error", 0)
            stats["skipped"]["wkb_encode_error"] += 1
            continue

        min_lat, max_lat, min_lon, max_lon = bgd.geometry_bbox(simplified)

        if args.variant == "E" and baseline_bboxes:
            cand_bbox = (min_lat, max_lat, min_lon, max_lon)
            if any(_bbox_overlaps((b[1], b[2], b[3], b[4]), cand_bbox) for b in baseline_bboxes):
                stats["skipped"].setdefault("dedup_spatial_overlap", 0)
                stats["skipped"]["dedup_spatial_overlap"] += 1
                continue

        name = (p.get("name") or "").strip()
        if not name:
            stats["skipped"].setdefault("no_name", 0)
            stats["skipped"]["no_name"] += 1
            continue

        oid = REL_OFF + rid
        inserts.append((oid, name, p.get("name:en"), p.get("wikidata"), wkb))
        rtree_inserts.append((oid, min_lat, max_lat, min_lon, max_lon))
        stats["inserted"] += 1

    # ---- Variant F: also ingest Wikidata-linked OSM ways ----
    if args.variant == "F" and args.candidates_ways:
        wd_way_set = set()
        with open(args.wikidata_ways) as f:
            for row in csv.DictReader(f):
                v = row.get("osm_way", "").strip()
                if v.isdigit():
                    wd_way_set.add(int(v))

        our_ways = set()
        for (osm_id,) in conn.execute("SELECT osm_id FROM island WHERE osm_id BETWEEN ? AND ?",
                                       (WAY_OFF, 2 * 10**12 - 1)):
            our_ways.add(osm_id - WAY_OFF)
        target_ways = wd_way_set - our_ways
        print(f"\nVariant F: Wikidata island ways: {len(wd_way_set):,};  not in baseline: {len(target_ways):,}")

        with open(args.candidates_ways) as f:
            ways_data = json.load(f)

        way_stats = {"inserted": 0, "skipped": {}}
        # osmium-export emits closed ways twice (LineString + Polygon). Prefer
        # the polygon version when both are present.
        polygon_by_wid: dict[int, dict] = {}
        linestring_by_wid: dict[int, dict] = {}
        for feat in ways_data.get("features", []):
            p = feat.get("properties") or {}
            if p.get("@type") != "way":
                continue
            wid = p.get("@id")
            if not isinstance(wid, int) or wid not in target_ways:
                continue
            g = feat.get("geometry") or {}
            if g.get("type") in ("Polygon", "MultiPolygon"):
                polygon_by_wid[wid] = feat
            elif wid not in polygon_by_wid:
                linestring_by_wid[wid] = feat

        seen_way_ids = set()
        for wid, feat in polygon_by_wid.items():
            p = feat.get("properties") or {}
            g = feat.get("geometry") or {}
            if wid in seen_way_ids:
                continue
            seen_way_ids.add(wid)
            if g.get("type") not in ("Polygon", "MultiPolygon"):
                way_stats["skipped"].setdefault("not_polygon", 0)
                way_stats["skipped"]["not_polygon"] += 1
                continue
            simplified = _lenient_simplify(g, TOLERANCE)
            if not bgd._polygon_is_valid(simplified):
                way_stats["skipped"].setdefault("invalid_after_simplify", 0)
                way_stats["skipped"]["invalid_after_simplify"] += 1
                continue
            try:
                wkb = bgd.encode_wkb(simplified)
            except (ValueError, struct.error):
                way_stats["skipped"].setdefault("wkb_encode_error", 0)
                way_stats["skipped"]["wkb_encode_error"] += 1
                continue
            min_lat, max_lat, min_lon, max_lon = bgd.geometry_bbox(simplified)
            name = (p.get("name") or "").strip()
            if not name:
                way_stats["skipped"].setdefault("no_name", 0)
                way_stats["skipped"]["no_name"] += 1
                continue
            oid = WAY_OFF + wid
            inserts.append((oid, name, p.get("name:en"), p.get("wikidata"), wkb))
            rtree_inserts.append((oid, min_lat, max_lat, min_lon, max_lon))
            way_stats["inserted"] += 1

        # Count linestring-only ways that we genuinely can't use
        only_ls = set(linestring_by_wid) - set(polygon_by_wid)
        way_stats["skipped"].setdefault("linestring_only", 0)
        way_stats["skipped"]["linestring_only"] += len(only_ls)
        print(f"  Wikidata-way inserted: {way_stats['inserted']}")
        print(f"  Wikidata-way skipped:")
        for k, v in sorted(way_stats['skipped'].items(), key=lambda x: -x[1]):
            print(f"    {k}: {v}")

    print(f"\nInserting {len(inserts)} new island rows...")
    # Paired-insert discipline: `island` uses OR IGNORE
    # (a candidate may already exist in the baseline), but the R*Tree has
    # its own rowid primary key — a plain INSERT for an ignored duplicate
    # crashed the run on the rowid collision, and blindly ignoring BOTH
    # could leave an existing row indexed under the NEW candidate's bbox.
    # Insert each rtree entry only when its island row was actually
    # inserted (rowcount == 1); an ignored duplicate keeps its original
    # spatial entry untouched.
    #
    # Dateline crossers, exactly as Phase 1E: `geometry_bbox`
    # may leave [-180, 180], and an R*Tree row cannot wrap, so the second
    # longitude segment gets a twin base row under OSM_DATELINE_OFF.
    rtree_by_oid = {row[0]: row for row in rtree_inserts}
    cur = conn.cursor()
    ignored_dupes = 0
    inserted_rows = 0
    for row in inserts:
        oid, min_lat, max_lat, min_lon, max_lon = rtree_by_oid[row[0]]
        for i, (seg_min, seg_max) in enumerate(bgd.rtree_lon_segments(min_lon, max_lon)):
            row_id = oid if i == 0 else bgd.OSM_DATELINE_OFF + oid
            cur.execute(
                "INSERT OR IGNORE INTO island (osm_id, name, name_en, wikidata, wkb) VALUES (?,?,?,?,?)",
                (row_id,) + tuple(row[1:]),
            )
            if cur.rowcount == 1:
                cur.execute(
                    "INSERT INTO island_rtree (osm_id, min_lat, max_lat, min_lon, max_lon) VALUES (?,?,?,?,?)",
                    (row_id, min_lat, max_lat, seg_min, seg_max),
                )
                if i == 0:
                    inserted_rows += 1
            else:
                ignored_dupes += 1
    if ignored_dupes:
        print(f"  {ignored_dupes} duplicate osm_id(s) already in the baseline — "
              f"row and rtree entry kept as-is.")

    # Stamp the supplement marker: build-geocoder-db.py's
    # --phase=1e checks this and refuses to DROP the enriched island tables
    # unless --wipe-supplement is passed.
    conn.execute(
        "CREATE TABLE IF NOT EXISTS build_meta (key TEXT PRIMARY KEY, value TEXT)"
    )
    conn.execute(
        "INSERT OR REPLACE INTO build_meta (key, value) "
        "VALUES ('island_supplement_applied', ?)",
        (f"variant={args.variant}, rows={inserted_rows}",),
    )
    conn.commit()
    return stats, t0


def _finalize(conn: sqlite3.Connection) -> str:
    """journal_mode=DELETE + VACUUM (required for bundle shipping). Returns
    the journal mode SQLite reports after the switch."""
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE);")
    journal_mode = conn.execute("PRAGMA journal_mode = DELETE;").fetchone()[0]
    conn.execute("VACUUM;")
    conn.commit()
    return journal_mode


if __name__ == "__main__":
    sys.exit(main())
