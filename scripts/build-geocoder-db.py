#!/usr/bin/env python3
"""
Build TravelLog's bundled offline-geocoder SQLite database.

# What it does

Assembles `TravelLog/Resources/Geocoder.sqlite` from multiple open-data
sources. Each "layer" is a separate table + R*Tree spatial index. The
Swift `GeocodeResolver` queries these layers to turn a coordinate into
{country, admin-1, metro, locality, island, …} with no network calls.

# Layers (Pragmatic tier, ~85 MB app target)

1. **city**            — GeoNames allCountries, feature_class=P. Every
                          named populated place worldwide. ~30 MB.
2. **admin1**          — Natural Earth 10m admin_1_states_provinces.
                          Polygons replacing Apple's deprecated
                          administrativeArea. ~5 MB.
3. **fua**             — GHS-FUA UCDB2015 R2019A. Functional Urban
                          Areas (metros) globally. ~9 MB.
4. **island**          — OSM place=island (named, all). ~8 MB.
5. **neighbourhood**   — OSM place=neighbourhood/suburb, filtered to
                          notable (has wikidata/wikipedia/name:en
                          tags). ~10 MB.

Layers 1-3 use stdlib-only Python. Layers 4-5 require OSM tooling
(see `_phase_osm` for the strategy in use).

# Run

    python3 scripts/build-geocoder-db.py            # full rebuild
    python3 scripts/build-geocoder-db.py --phase=1b # just GeoNames
    python3 scripts/build-geocoder-db.py --phase=1c # just admin-1
    python3 scripts/build-geocoder-db.py --phase=1d # just GHS-FUA
    python3 scripts/build-geocoder-db.py --phase=1e # just OSM
    python3 scripts/build-geocoder-db.py --phase=1f # just GHS-UCDB urban centres

Phase 1F needs the GHS-UCDB R2024A GeoPackage on disk (CC BY 4.0, ~285 MB,
build-time only — never redistributed). It is NOT downloaded automatically;
pass `--ucdb-input` or place it at UCDB_GPKG_PATH_DEFAULT.


# Idempotency

The script drops + recreates tables each run, so re-running is safe.
For incremental development, use `--phase=…` to skip layers you've
already built (the cache lives in a temp dir between runs).

# Output

Single file: `TravelLog/Resources/Geocoder.sqlite`. Always closed in
journal_mode=DELETE before this script exits (mandatory for bundle
shipping; WAL mode requires sidecar files the bundle can't host).

# License attribution required (add to app's About screen)

- GeoNames data © (https://www.geonames.org/), CC-BY 4.0.
- Natural Earth, public domain.
- GHS-FUA © European Union, 2019 (JRC), EU reuse with attribution.
- OpenStreetMap contributors, ODbL.
"""

from __future__ import annotations

import argparse
import csv
from contextlib import nullcontext
import hashlib
import io
import json
import math
import os
import re
import shutil
import sqlite3
import struct
import sys
import tempfile
import time
import urllib.request
import zipfile
from pathlib import Path

# ---------------------------------------------------------------------
# Paths and constants
# ---------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_PATH = REPO_ROOT / "TravelLog" / "Resources" / "Geocoder.sqlite"
CACHE_DIR = REPO_ROOT / ".build-cache" / "geocoder"  # downloads cached here

# Allow user to override cache location (useful in CI).
CACHE_DIR = Path(os.environ.get("TRAVELLOG_GEOCODER_CACHE", CACHE_DIR))

# ODbL 1.0 section 4.2(b): the licence notice travels inside the database.
# Keep identical to ship-trim-geocoder.py's LICENCE (the tooling test checks).
GEOCODER_LICENCE = (
    "Contains information from OpenStreetMap © OpenStreetMap contributors, "
    "made available under the Open Database License 1.0 "
    "(https://opendatacommons.org/licenses/odbl/1-0/). Also contains GeoNames "
    "(CC BY 4.0), GHS-UCDB R2024A and GHS-FUA R2019A (CC BY 4.0, © European "
    "Union), Natural Earth (public domain) and Wikidata (CC0) data. The database "
    "as a whole is available under the ODbL 1.0. Attributions: "
    "THIRD_PARTY_NOTICES.md in https://github.com/konstantinosfragkoulis/TravelLog"
)

# Source URLs. The classification-relevant FUA source is byte-pinned below.
# GeoNames and Natural Earth still require their own snapshot/checksum pass
# before those layers can become classification authority.
GEONAMES_ALL_COUNTRIES = "https://download.geonames.org/export/dump/allCountries.zip"
GEONAMES_ADMIN1_CODES = "https://download.geonames.org/export/dump/admin1CodesASCII.txt"

# Natural Earth 1:10m admin-1 (states / regions / prefectures). This legacy
# display lookup still follows `master`; it must be commit-pinned before any
# future classifier treats it as authority.
NE_ADMIN1_URL = (
    "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/"
    "master/geojson/ne_10m_admin_1_states_provinces.geojson"
)

# Polygon-simplification tolerance, in degrees. 0.01° ≈ 1.1 km — about
# right for "are you in this admin-1 region" point-in-polygon. Smaller
# than 0.01° starts inflating WKB sizes without changing geocoding
# behavior, since our typical input coordinate accuracy is ~50-500 m.
ADMIN1_SIMPLIFY_TOLERANCE = 0.01

# Phase 1E (OSM) input — produced on a desktop-class machine by:
#   brew install osmium-tool
#   wget https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf
#   osmium tags-filter planet-latest.osm.pbf \
#       n/place=neighbourhood,suburb \
#       n/place=island w/place=island r/place=island \
#       -o filtered.osm.pbf
#   osmium export filtered.osm.pbf -f geojsonseq -o places.geojsonseq
# Then: python3 scripts/build-geocoder-db.py --phase=1e --osm-input=…
#
# This phase requires ~70 GB free disk (planet PBF) and is unusable
# on resource-constrained machines. The Python step itself is
# stdlib-only and runs anywhere.
OSM_GEOJSONSEQ_PATH_DEFAULT = (
    REPO_ROOT / ".build-cache" / "geocoder" / "places.geojsonseq"
)

# GHS-FUA (Functional Urban Areas) — 8,790 metros globally. Built by
# Copernicus/JRC. Hosted on JRC's open-data FTP. Mollweide projection
# (EPSG:54009); we reproject to WGS84 at build time.
GHS_FUA_URL = (
    "https://jeodpp.jrc.ec.europa.eu/ftp/jrc-opendata/GHSL/"
    "GHS_FUA_UCDB2015_GLOBE_R2019A/V1-0/"
    "GHS_FUA_UCDB2015_GLOBE_R2019A_54009_1K_V1_0.zip"
)
GHS_FUA_ZIP_SHA256 = (
    "d54de59b82b8c4d64a710f90ccd554975a3be92233f14115ac154094c3549979"
)
GHS_FUA_GPKG_MEMBER = (
    "GHS_FUA_UCDB2015_GLOBE_R2019A_54009_1K_V1_0.gpkg"
)
GHS_FUA_GPKG_SHA256 = (
    "9934364827132232df67e8984768fb30865a846f5a786db999d49fc37fb7698d"
)
# 0.003° is about 330 m, below the source's own 1 km grid, so the stored
# boundary stays faithful to the dataset. The old 0.02° tolerance removed
# interior holes and could discard much of a polygon's area. The source
# excludes majority-sea coastal cells, so waterfront city centres can sit
# outside even the true boundary. Home-region membership consumers must
# pad (inside-or-within about 2.5 km, same country), not just use PIP.
FUA_SIMPLIFY_TOLERANCE = 0.003

# The source and legacy WKB consumer use coordinate-linear interpolation,
# while the uncertainty-aware runtime evaluator uses minor great-circle arcs.
# After coordinate-linear Douglas-Peucker simplification, subdivide every edge
# until sampled coordinate-linear ↔ spherical-interpolation deviation is at
# most this value. The transform and bound are part of dataset identity.
FUA_OPERATIONAL_MAX_ERROR_METERS = 0.25
FUA_RTREE_PADDING_METERS = FUA_OPERATIONAL_MAX_ERROR_METERS
# Re-signed 2026-08-03 after the MOLLWEIDE_R correction (see that constant).
# Every vertex moved, so the transform version is bumped and the three
# geometry digests below are re-signed. Feature count, skipped count,
# unmapped-ISO count and simplified-vertex count are UNCHANGED — the
# signature of a pure coordinate correction, not a data change.
FUA_GEOMETRY_TRANSFORM_VERSION = (
    "wgs84-dp0.003-coordinate-linear-to-geodesic-0.25m-v2-sphere6378137"
)
FUA_DATASET_VERSION = (
    "GHS_FUA_UCDB2015_GLOBE_R2019A_54009_1K_V1_0"
    f"+travellog-{FUA_GEOMETRY_TRANSFORM_VERSION}"
)
FUA_EXPECTED_FEATURE_COUNT = 9_023
FUA_EXPECTED_SKIPPED_GEOMETRY_COUNT = 0
FUA_EXPECTED_UNMAPPED_ISO_COUNT = 8
FUA_EXPECTED_SIMPLIFIED_VERTEX_COUNT = 414_443
FUA_EXPECTED_OPERATIONAL_VERTEX_COUNT = 434_216
FUA_EXPECTED_WKB_BYTES = 7_149_034
FUA_EXPECTED_LAYER_SHA256 = (
    "009ff305a7a984330bc364942e3881c8b7d85755f2e5743f9f7a1171bfccd948"
)

# OSM island polygons. Aggressive simplification since islands are usually
# well-separated from each other (a 1km coastline wiggle never makes the
# difference between "in this island" and "not"). Greenland/Australia are
# tagged place=island and would dominate disk usage without this.
OSM_ISLAND_SIMPLIFY_TOLERANCE = 0.005

# OSM neighborhood polygons (when available — most are nodes). Tighter
# tolerance because neighborhoods themselves are sub-km features.
OSM_NEIGHBORHOOD_SIMPLIFY_TOLERANCE = 0.0005

# Min island bbox area in deg² to keep, regardless of name. Drops sub-
# 1km² unpopulated rocks (~ a 0.01° × 0.01° box at the equator). Islands
# with an explicit `population` tag bypass this filter.
OSM_ISLAND_MIN_BBOX_DEG2 = 0.0001

# GHS-UCDB R2024A urban centres — the HOME-SHAPE seed layer (phase 1F).
#
# Deliberately UNSIMPLIFIED, unlike every other polygon layer here. Measured
# on the source: 11,422 centres, 287,203 vertices total, p50 = 17 vertices,
# p90 = 43, max 1,158 — about 4.4 MB of coordinate data. There is nothing to
# gain by simplifying and a great deal to lose: the source is a 1 km grid, so
# FUA_SIMPLIFY_TOLERANCE (0.003° ≈ 334 m) sits BELOW the grid step and would
# round off precisely the boundary corners that decide whether a suburb is
# inside your home area. Athens carries 105 vertices for 412 km² here, versus
# the shipped FUA layer's 21 points for 2,246 km².
#
# CARRY THE FUA WATERFRONT CAVEAT (see FUA_SIMPLIFY_TOLERANCE above): GHSL
# excludes majority-sea cells, so a waterfront city centre can fall OUTSIDE
# its own urban centre. Consumers doing home-region membership must pad
# (inside-or-within a couple of km), not just point-in-polygon.
UCDB_GPKG_PATH_DEFAULT = (
    REPO_ROOT / "UCDB" / "GHS_UCDB_GLOBE_R2024A_V1_2" / "GHS_UCDB_GLOBE_R2024A.gpkg"
)
# The source ships 16 geometry layers, so the table cannot be picked with the
# `LIMIT 1` probe phase 1D uses. Match on theme instead of hard-coding the
# release-stamped name, and require EXACTLY one hit.
UCDB_TABLE_PATTERN = "%GENERAL_CHARACTERISTICS%"
# Attribute prefixes: the source suffixes column names with a data year
# (GC_UCN_MAI_2025), so resolve by prefix and a year bump still builds.
UCDB_COLUMN_PREFIXES = {
    "name": "GC_UCN_MAI_",
    "country": "GC_CNT_GAD_",
    "area": "GC_UCA_KM2_",
    "population": "GC_POP_TOT_",
}
UCDB_ID_COLUMN = "ID_UC_G0"
# Guard: reprojecting an already-WGS84 source would silently corrupt every
# vertex. Assert the declared CRS instead of trusting the release notes.
UCDB_SOURCE_SRS_ID = 54009
UC_GEOMETRY_TRANSFORM_VERSION = "wgs84-unsimplified-coordinate-linear-v1-sphere6378137"

# Twin-row id offsets for antimeridian-crossing features:
# an R*Tree row cannot wrap around ±180°, so a crossing feature is stored
# as TWO (base row, rtree row) pairs — the second under a namespaced id
# that can never collide with a real one. FUA eFUA ids are small ints;
# OSM packed ids occupy [0, 4e12) (NODE/WAY/REL/AUTO bands of 1e12 each),
# so the dateline band starts at 4e12. UCDB ID_UC_G0 runs 1..11,686, so its
# band sits at 2e9 — clear of real ids and of FUA's 1e9 band (separate
# tables, but keeping the bands distinct makes a mis-joined row obvious).
FUA_DATELINE_OFF = 10**9
UC_DATELINE_OFF = 2 * (10**9)
OSM_DATELINE_OFF = 4 * (10**12)

# Earth radius in meters used by ESRI:54009 (World_Mollweide). The projection
# is spherical, and the sphere it uses is the WGS84 SEMI-MAJOR AXIS — the CRS
# definition shipped in the source GeoPackage reads
#     SPHEROID["WGS 84",6378137,298.257223563]
#
# It is NOT the authalic radius (6371007.181). Using that instead is a 0.112%
# scale error, which inverse-projects every vertex away from (0,0).
# The resulting kilometre-scale displacement can move city centres and
# nearby districts outside their own FUA and misclassify home stays.
# Keep this aligned with the CRS of the source GeoPackage.
MOLLWEIDE_R = 6378137.0


# GeoNames feature codes we KEEP, with population gates.
# See https://www.geonames.org/export/codes.html — feature_class P.
#
# ADMIN places (kept regardless of population — they're definitionally real):
# PPLA   seat of a 1st-order admin division
# PPLA2  seat of a 2nd-order admin division
# PPLA3  seat of a 3rd-order admin division
# PPLA4  seat of a 4th-order admin division
# PPLA5  seat of a 5th-order admin division (rare; included for completeness)
# PPLC   capital of a political entity
# PPLG   seat of government
# PPLS   populated places (plural form — uncommon, ~300 worldwide)
#
# PPL places (kept only with population >= MIN_PPL_POPULATION):
# PPL    populated place (generic). 4.7M worldwide; ~4.3M have pop=0 in
#        GeoNames (which means "no data" but in practice is noise dominated
#        by hamlets, farms, and unverified entries). We filter out the
#        no-pop subset to keep the bundle small and the data signal-rich.
#
# DROPPED entirely:
# PPLF   farm village (rural noise)
# PPLR   religious populated place (monasteries; rarely user-relevant)
# PPLX   section of populated place (neighborhood-level; OSM is the better
#        source for this layer)
# PPLH   historical, no longer exists
# PPLQ   abandoned
# PPLW   destroyed by war/disaster
# PPLL   small locality, often duplicates PPL with worse data
ADMIN_FEATURE_CODES = {
    "PPLA", "PPLA2", "PPLA3", "PPLA4", "PPLA5",
    "PPLC", "PPLG", "PPLS",
}
# PPL = generic populated place. PPLX = "section of populated place"
# (US neighbourhoods like Beverly Hills tag this way; some other countries
# too). Both kept only when population ≥ MIN_PPL_POPULATION — admin codes
# bypass.
GENERIC_FEATURE_CODES = {"PPL", "PPLX"}
KEEP_FEATURE_CODES = ADMIN_FEATURE_CODES | GENERIC_FEATURE_CODES

# Min population for generic PPL/PPLX entries. Admin codes ignore this.
# 100 keeps Apollonas-class villages (pop 250), Beverly Hills (pop 34869),
# and similar real places; drops 4M+ pop=0 noise.
MIN_PPL_POPULATION = 100


# ---------------------------------------------------------------------
# Cache helpers
# ---------------------------------------------------------------------

def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _verify_sha256(
    path: Path,
    expected_sha256: str,
    *,
    label: str,
) -> None:
    actual = _sha256_file(path)
    if actual != expected_sha256:
        raise RuntimeError(
            f"{label} SHA-256 mismatch: expected {expected_sha256}, "
            f"found {actual} at {path}"
        )


def _cached_download(
    url: str,
    filename: str | None = None,
    *,
    expected_sha256: str | None = None,
) -> Path:
    """
    Download `url` to CACHE_DIR/filename (defaulting to the URL's tail).
    Skips the download if the file already exists. Returns the local path.
    """
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    name = filename or url.rsplit("/", 1)[-1]
    target = CACHE_DIR / name
    if target.exists() and target.stat().st_size > 0:
        if expected_sha256 is not None:
            _verify_sha256(
                target,
                expected_sha256,
                label=f"cached {name}",
            )
        size_mb = target.stat().st_size / 1024 / 1024
        print(f"  ✓ Cached: {name} ({size_mb:.1f} MB)")
        return target

    print(f"  ↓ Downloading {url}")
    print(f"      → {target}")
    t0 = time.time()
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{name}.",
        suffix=".download",
        dir=CACHE_DIR,
    )
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        urllib.request.urlretrieve(url, temporary)
        if expected_sha256 is not None:
            _verify_sha256(
                temporary,
                expected_sha256,
                label=f"downloaded {name}",
            )
        os.replace(temporary, target)
    finally:
        if temporary.exists():
            temporary.unlink()
    elapsed = time.time() - t0
    size_mb = target.stat().st_size / 1024 / 1024
    print(f"  ✓ Downloaded {size_mb:.1f} MB in {elapsed:.1f}s")
    return target


def _extract_pinned_zip_member(
    archive: Path,
    member_name: str,
    expected_sha256: str,
) -> Path:
    """Extract one exact, pinned member atomically into the build cache."""
    if Path(member_name).name != member_name:
        raise ValueError("Pinned ZIP member must be a basename")
    target = CACHE_DIR / member_name
    if target.exists() and target.stat().st_size > 0:
        try:
            _verify_sha256(
                target,
                expected_sha256,
                label=f"cached {member_name}",
            )
            return target
        except RuntimeError:
            # The pinned archive remains authority. Replace a stale extracted
            # member atomically instead of trusting or editing it in place.
            pass

    with zipfile.ZipFile(archive) as source:
        matches = [
            info for info in source.infolist()
            if info.filename == member_name and not info.is_dir()
        ]
        if len(matches) != 1:
            raise RuntimeError(
                f"Expected exactly one ZIP member {member_name!r}; "
                f"found {len(matches)}"
            )
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=f".{member_name}.",
            suffix=".extract",
            dir=CACHE_DIR,
        )
        os.close(descriptor)
        temporary = Path(temporary_name)
        try:
            with source.open(matches[0]) as compressed, temporary.open(
                "wb"
            ) as destination:
                shutil.copyfileobj(compressed, destination)
            _verify_sha256(
                temporary,
                expected_sha256,
                label=f"extracted {member_name}",
            )
            os.replace(temporary, target)
        finally:
            if temporary.exists():
                temporary.unlink()
    return target


# ---------------------------------------------------------------------
# Database open / common schema
# ---------------------------------------------------------------------

def _open_db(path: Path) -> sqlite3.Connection:
    """
    Open the build SQLite. Sets pragmas appropriate for fast bulk insert.
    We'll flip to journal_mode=DELETE just before exit (required for
    bundle shipping; iOS can't write to the bundle for WAL sidecars).
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        PRAGMA journal_mode = WAL;       -- fast during build
        PRAGMA synchronous = NORMAL;     -- safe enough for a build
        PRAGMA cache_size = -50000;      -- 50 MB page cache
        PRAGMA temp_store = MEMORY;
        PRAGMA foreign_keys = OFF;
        """
    )
    return conn


def _upsert_build_metadata(
    conn: sqlite3.Connection,
    values: dict[str, str],
) -> None:
    conn.execute(
        "CREATE TABLE IF NOT EXISTS build_meta "
        "(key TEXT PRIMARY KEY, value TEXT NOT NULL)"
    )
    conn.executemany(
        "INSERT OR REPLACE INTO build_meta (key, value) VALUES (?, ?)",
        sorted(values.items()),
    )


def _stable_rows_sha256(rows: list[tuple]) -> str:
    """Hash typed row values without delimiter or locale ambiguity."""
    encoded_rows: list[bytes] = []
    for row in rows:
        encoded = bytearray(struct.pack("<I", len(row)))
        for value in row:
            if value is None:
                payload = b""
                marker = b"n"
            elif isinstance(value, bytes):
                payload = value
                marker = b"b"
            elif isinstance(value, str):
                payload = value.encode("utf-8")
                marker = b"s"
            elif isinstance(value, int):
                payload = struct.pack("<q", value)
                marker = b"i"
            elif isinstance(value, float):
                if not math.isfinite(value):
                    raise ValueError("Non-finite value in artifact digest")
                payload = struct.pack("<d", value)
                marker = b"f"
            else:
                raise TypeError(
                    f"Unsupported artifact-digest value: {type(value)!r}"
                )
            encoded.extend(marker)
            encoded.extend(struct.pack("<Q", len(payload)))
            encoded.extend(payload)
        encoded_rows.append(bytes(encoded))

    digest = hashlib.sha256()
    for encoded in sorted(encoded_rows):
        digest.update(struct.pack("<Q", len(encoded)))
        digest.update(encoded)
    return digest.hexdigest()


def _validate_fua_build(
    *,
    feature_count: int,
    skipped_geometry_count: int,
    unmapped_iso_count: int,
    simplified_vertex_count: int,
    operational_vertex_count: int,
    wkb_bytes: int,
    layer_sha256: str,
) -> None:
    actual = {
        "feature_count": feature_count,
        "skipped_geometry_count": skipped_geometry_count,
        "unmapped_iso_count": unmapped_iso_count,
        "simplified_vertex_count": simplified_vertex_count,
        "operational_vertex_count": operational_vertex_count,
        "wkb_bytes": wkb_bytes,
        "layer_sha256": layer_sha256,
    }
    expected = {
        "feature_count": FUA_EXPECTED_FEATURE_COUNT,
        "skipped_geometry_count":
            FUA_EXPECTED_SKIPPED_GEOMETRY_COUNT,
        "unmapped_iso_count": FUA_EXPECTED_UNMAPPED_ISO_COUNT,
        "simplified_vertex_count":
            FUA_EXPECTED_SIMPLIFIED_VERTEX_COUNT,
        "operational_vertex_count":
            FUA_EXPECTED_OPERATIONAL_VERTEX_COUNT,
        "wkb_bytes": FUA_EXPECTED_WKB_BYTES,
        "layer_sha256": FUA_EXPECTED_LAYER_SHA256,
    }
    mismatches = [
        f"{key}: expected {expected[key]!r}, found {actual[key]!r}"
        for key in expected
        if actual[key] != expected[key]
    ]
    if mismatches:
        raise RuntimeError(
            "Pinned FUA build invariant failed; do not publish or bump "
            "expectations without adjudicating the source/transform change:\n"
            + "\n".join(f"  - {mismatch}" for mismatch in mismatches)
        )


def _finalize_db(conn: sqlite3.Connection) -> None:
    """
    Switch journal mode to DELETE (no WAL sidecars) and VACUUM. Required
    before shipping inside the iOS bundle: bundle is read-only, can't
    host -wal/-shm files.
    """
    print("Finalizing: VACUUM and journal_mode=DELETE")
    conn.commit()
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE);")
    conn.execute("PRAGMA journal_mode = DELETE;")
    conn.execute("VACUUM;")
    conn.commit()


# ---------------------------------------------------------------------
# Geometry helpers (pure stdlib — Douglas-Peucker + WKB encoder)
# ---------------------------------------------------------------------

def _perp_distance(p: list[float], a: list[float], b: list[float]) -> float:
    """Perpendicular distance from p to line a-b, in degrees."""
    if a == b:
        return math.hypot(p[0] - a[0], p[1] - a[1])
    dx, dy = b[0] - a[0], b[1] - a[1]
    t = ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / (dx * dx + dy * dy)
    t = max(0.0, min(1.0, t))
    px, py = a[0] + t * dx, a[1] + t * dy
    return math.hypot(p[0] - px, p[1] - py)


def simplify_ring(ring: list[list[float]], tolerance: float) -> list[list[float]]:
    """Iterative Douglas-Peucker on a polygon ring. Preserves closure."""
    if len(ring) < 4:
        return ring
    keep = [False] * len(ring)
    keep[0] = True
    keep[-1] = True
    stack = [(0, len(ring) - 1)]
    while stack:
        lo, hi = stack.pop()
        if hi - lo < 2:
            continue
        a, b = ring[lo], ring[hi]
        max_dist, max_idx = -1.0, -1
        for i in range(lo + 1, hi):
            d = _perp_distance(ring[i], a, b)
            if d > max_dist:
                max_dist, max_idx = d, i
        if max_dist > tolerance:
            keep[max_idx] = True
            stack.append((lo, max_idx))
            stack.append((max_idx, hi))
    out = [pt for pt, k in zip(ring, keep) if k]
    if out[0] != out[-1]:
        out.append(out[0])
    return out


def simplify_geometry(geom: dict, tolerance: float) -> dict:
    """
    Simplify Polygon / MultiPolygon. Drops degenerate rings (< 4 points
    after simplification) — without this, aggressive simplification can
    collapse small inner rings (lakes inside an island, etc.) to slivers
    that would crash WKB consumers. Outer ring loss skips the whole
    sub-polygon. A MultiPolygon survives if at least one sub-polygon
    has a valid outer ring.
    """
    t = geom.get("type")
    if t == "Polygon":
        return {"type": "Polygon",
                "coordinates": _filter_rings(geom["coordinates"], tolerance)}
    if t == "MultiPolygon":
        valid_polys: list[list[list[list[float]]]] = []
        for poly in geom["coordinates"]:
            filtered = _filter_rings(poly, tolerance)
            if filtered:  # at least the outer ring survived
                valid_polys.append(filtered)
        return {"type": "MultiPolygon", "coordinates": valid_polys}
    return geom


def _filter_rings(rings: list[list[list[float]]], tolerance: float) -> list[list[list[float]]]:
    """
    Simplify each ring, drop degenerate ones. Returns rings where the
    outer ring is valid (≥ 4 points); returns empty list if the outer
    ring itself collapses.
    """
    if not rings:
        return []
    # Outer ring
    outer = simplify_ring(rings[0], tolerance)
    if len(outer) < 4:
        return []
    result = [outer]
    # Inner rings (holes) — keep only valid ones
    for r in rings[1:]:
        simp = simplify_ring(r, tolerance)
        if len(simp) >= 4:
            result.append(simp)
    return result


def wrapped_lon_delta(a: float, b: float) -> float:
    """
    Signed shortest-arc longitude difference a − b, in [-180, 180].
    Mirror of the app's GeoMath.wrappedLongitudeDelta: BIT-IDENTICAL to
    plain a − b whenever |a − b| ≤ 180 (branching, not modulo — valid for
    normalized inputs, where the raw difference is always within ±360).
    """
    d = a - b
    if d > 180.0:
        return d - 360.0
    if d < -180.0:
        return d + 360.0
    return d


def normalized_lon(lon: float) -> float:
    """Normalize a longitude into [-180, 180) — GeoMath.normalizedLongitude."""
    if -180.0 <= lon < 180.0:
        return lon
    l = math.fmod(lon + 180.0, 360.0)
    if l < 0:
        l += 360.0
    return l - 180.0


def geometry_bbox(geom: dict) -> tuple[float, float, float, float]:
    """
    Return (min_lat, max_lat, min_lon, max_lon) over a Polygon or
    MultiPolygon. Iterates rings; small constant memory.

    Longitudes are unwrapped into a CONTINUOUS frame anchored at the
    geometry's first vertex (`anchor + wrapped_lon_delta(lon, anchor)` —
    the exact first-vertex-frame convention GeocodeResolver.ringContains /
    GeoMath.pointInPolygon use), so an antimeridian-crossing polygon
    (Fiji, Chukotka, the far Aleutians) gets its true tight box instead of
    min≈-180 / max≈+180 — a globe-spanning R*Tree entry that matched EVERY
    query longitude. The returned lon bounds may
    therefore leave [-180, 180]; feed them through `rtree_lon_segments`
    before inserting R*Tree rows. Valid for geometries spanning < 180° of
    longitude — the same contract as the app parser.
    """
    min_lat, max_lat = 90.0, -90.0
    min_lon, max_lon = 180.0, -180.0
    anchor: float | None = None
    rings: list[list[list[float]]] = []
    t = geom.get("type")
    if t == "Polygon":
        rings = geom["coordinates"]
    elif t == "MultiPolygon":
        rings = [r for poly in geom["coordinates"] for r in poly]
    for ring in rings:
        for lon, lat in ring:
            if anchor is None:
                anchor = lon
            lon = anchor + wrapped_lon_delta(lon, anchor)
            if lat < min_lat: min_lat = lat
            if lat > max_lat: max_lat = lat
            if lon < min_lon: min_lon = lon
            if lon > max_lon: max_lon = lon
    return (min_lat, max_lat, min_lon, max_lon)


def rtree_lon_segments(min_lon: float, max_lon: float) -> list[tuple[float, float]]:
    """
    Map frame-space longitude bounds from `geometry_bbox` (which may leave
    [-180, 180]) onto one or two in-range segments whose union covers the
    same wrapped extent — the write-side twin of the app's
    GeoMath.longitudeSegments. INVARIANT: for any query
    longitude or window, a feature must be probed iff its true wrapped
    extent overlaps the window — so an antimeridian-crossing feature gets
    TWO R*Tree rows (each joined to its own copy of the base row; R*Tree
    rows cannot wrap and each needs a distinct rowid), never one
    globe-spanning row.
    """
    if max_lon - min_lon >= 360.0:
        return [(-180.0, 180.0)]
    if min_lon >= -180.0 and max_lon <= 180.0:
        return [(min_lon, max_lon)]
    if max_lon > 180.0:
        return [(min_lon, 180.0), (-180.0, max_lon - 360.0)]
    # min_lon < -180 (anchor near -180 with westward unwrap)
    return [(-180.0, max_lon), (min_lon + 360.0, 180.0)]


def expand_geographic_bbox(
    min_lat: float,
    max_lat: float,
    min_lon: float,
    max_lon: float,
    padding_meters: float,
) -> tuple[float, float, float, float]:
    """
    Conservatively expand a vertex bbox by a spherical distance.

    Operational edges are great-circle arcs and can bow outside their endpoint
    bbox. The densification contract bounds that bow relative to the source
    coordinate-linear segment, so padding by the same declared error keeps the
    R*Tree a complete candidate index rather than an accidental geometry clip.
    Longitude stays in the bbox's continuous frame for later dateline split.
    """
    if (
        not all(
            math.isfinite(value)
            for value in (min_lat, max_lat, min_lon, max_lon, padding_meters)
        )
        or min_lat > max_lat
        or min_lon > max_lon
        or padding_meters < 0
    ):
        raise ValueError("Invalid geographic bbox or padding")
    angular = padding_meters / MOLLWEIDE_R
    latitude_padding = math.degrees(angular)
    padded_min_lat = max(-90.0, min_lat - latitude_padding)
    padded_max_lat = min(90.0, max_lat + latitude_padding)
    maximum_absolute_latitude = max(
        abs(padded_min_lat),
        abs(padded_max_lat),
    )
    cosine = math.cos(math.radians(maximum_absolute_latitude))
    if cosine <= 0 or math.sin(angular) >= cosine:
        longitude_padding = 180.0
    else:
        longitude_padding = math.degrees(
            math.asin(math.sin(angular) / cosine)
        )
    if longitude_padding >= 180:
        return (
            padded_min_lat,
            padded_max_lat,
            -180.0,
            180.0,
        )
    return (
        padded_min_lat,
        padded_max_lat,
        min_lon - longitude_padding,
        max_lon + longitude_padding,
    )


# --- Mollweide ↔ WGS84 inverse projection (EPSG:54009 → EPSG:4326) ---
#
# Pure stdlib. Inverse formulas (Snyder, "Map Projections — A Working
# Manual", USGS PP 1395, p. 251):
#     θ  = arcsin(y / (R √2))
#     φ  = arcsin( (2θ + sin(2θ)) / π )
#     λ  = π · x / (2 R √2 cos(θ))
#
# Numerically well-behaved; no iteration needed (the inverse is closed-form,
# unlike the forward transform which requires Newton's method for θ).

_MOLLWEIDE_R_SQRT2 = MOLLWEIDE_R * math.sqrt(2.0)

def mollweide_to_wgs84(x: float, y: float) -> tuple[float, float]:
    """
    Convert (x, y) in EPSG:54009 metres to (lon, lat) in degrees.
    Returns the tuple in (lon, lat) order to match GeoJSON convention.
    """
    sin_theta = y / _MOLLWEIDE_R_SQRT2
    # Numerical clamp — at the projection's poles, accumulated float
    # error can push sin_theta a hair past ±1.
    if sin_theta > 1.0: sin_theta = 1.0
    elif sin_theta < -1.0: sin_theta = -1.0
    theta = math.asin(sin_theta)
    sin_phi = (2.0 * theta + math.sin(2.0 * theta)) / math.pi
    if sin_phi > 1.0: sin_phi = 1.0
    elif sin_phi < -1.0: sin_phi = -1.0
    phi = math.asin(sin_phi)
    cos_theta = math.cos(theta)
    if abs(cos_theta) < 1e-12:
        # Pole — longitude is undefined; return 0 to avoid div/0.
        return (0.0, math.degrees(phi))
    lam = math.pi * x / (2.0 * _MOLLWEIDE_R_SQRT2 * cos_theta)
    return (math.degrees(lam), math.degrees(phi))


# --- WKB parser (we read FUA polygons as GPB-wrapped WKB) ---
#
# GeoPackage Binary (GPB) is WKB prefixed with a small envelope. See
# OGC 12-128r19 §2.1.3. Layout:
#   2 bytes: magic "GP" (0x47, 0x50)
#   1 byte:  version (0)
#   1 byte:  flags. Bit 0 = byte order (0=BE, 1=LE). Bits 1-3 = envelope
#            kind (0=none, 1=xy, 2=xyz, 3=xym, 4=xyzm). Bit 5 = empty.
#   4 bytes: srs_id (int32, endianness per flags)
#   envelope: 0, 32, 48, or 64 bytes depending on flag bits 1-3
#   WKB: rest of the blob

def parse_gpb_to_wkb(gpb_blob: bytes) -> bytes:
    """Strip GeoPackage Binary header, return the inner WKB."""
    if len(gpb_blob) < 8 or gpb_blob[:2] != b"GP":
        raise ValueError("Not a GeoPackage Binary blob")
    flags = gpb_blob[3]
    envelope_kind = (flags >> 1) & 0x7
    envelope_sizes = {0: 0, 1: 32, 2: 48, 3: 48, 4: 64}
    env_size = envelope_sizes.get(envelope_kind)
    if env_size is None:
        raise ValueError(f"Unknown GPB envelope kind {envelope_kind}")
    header_size = 8 + env_size
    return gpb_blob[header_size:]


def decode_wkb_to_geojson(wkb_blob: bytes) -> dict:
    """
    Decode WKB (little or big endian) into a GeoJSON-shaped dict.
    Supports Polygon (type 3) and MultiPolygon (type 6) only — that's
    what GHS-FUA uses. Returns the same shape that simplify_geometry
    and encode_wkb operate on.
    """
    if len(wkb_blob) < 5:
        raise ValueError("WKB too short")
    byte_order = wkb_blob[0]
    end = "<" if byte_order == 0x01 else ">"
    geom_type = struct.unpack_from(end + "I", wkb_blob, 1)[0]
    offset = 5

    def read_uint32() -> int:
        nonlocal offset
        v = struct.unpack_from(end + "I", wkb_blob, offset)[0]
        offset += 4
        return v

    def read_point() -> list[float]:
        nonlocal offset
        x, y = struct.unpack_from(end + "dd", wkb_blob, offset)
        offset += 16
        return [x, y]

    def read_ring() -> list[list[float]]:
        n = read_uint32()
        return [read_point() for _ in range(n)]

    def read_polygon_body() -> list[list[list[float]]]:
        n = read_uint32()
        return [read_ring() for _ in range(n)]

    if geom_type == 3:  # Polygon
        return {"type": "Polygon", "coordinates": read_polygon_body()}
    if geom_type == 6:  # MultiPolygon
        n = read_uint32()
        polys = []
        for _ in range(n):
            # Each sub-geometry has its own byte-order + type header —
            # HONOR it. Mixed-endian WKB is rare but
            # valid (some PostGIS exports emit it); assuming the parent's
            # order decoded garbage coordinates silently. Rebinding `end`
            # here re-points the closure the read_* helpers share, so the
            # child's rings parse under its own order. (The WRITE side —
            # encode_geojson_to_wkb — emits uniform little-endian for the
            # parent and every child, so the app's loadUnaligned parser
            # contract is unaffected.)
            sub_bo = wkb_blob[offset]
            offset += 1
            end = "<" if sub_bo == 0x01 else ">"
            sub_type = struct.unpack_from(end + "I", wkb_blob, offset)[0]
            offset += 4
            if sub_type != 3:
                raise ValueError(f"MultiPolygon contains non-Polygon ({sub_type})")
            polys.append(read_polygon_body())
        return {"type": "MultiPolygon", "coordinates": polys}
    raise ValueError(f"Unsupported geometry type for WKB decode: {geom_type}")


def reproject_geometry(geom: dict) -> dict:
    """
    Apply mollweide_to_wgs84 to every point in a Polygon / MultiPolygon
    in-place-style (returns a new dict). Used by Phase 1D.
    """
    t = geom.get("type")
    if t == "Polygon":
        return {"type": "Polygon",
                "coordinates": [[list(mollweide_to_wgs84(x, y)) for x, y in r]
                                for r in geom["coordinates"]]}
    if t == "MultiPolygon":
        return {"type": "MultiPolygon",
                "coordinates": [
                    [[list(mollweide_to_wgs84(x, y)) for x, y in r] for r in poly]
                    for poly in geom["coordinates"]
                ]}
    return geom


def _validated_lon_lat(point: list[float]) -> tuple[float, float]:
    if len(point) < 2:
        raise ValueError("Coordinate has fewer than two values")
    lon, lat = float(point[0]), float(point[1])
    if (
        not math.isfinite(lon)
        or not math.isfinite(lat)
        or not -180.0 <= lon <= 180.0
        or not -90.0 <= lat <= 90.0
    ):
        raise ValueError(f"Invalid WGS84 coordinate: {point!r}")
    return lon, lat


def _unit_vector(point: list[float]) -> tuple[float, float, float]:
    lon, lat = _validated_lon_lat(point)
    lon_radians = math.radians(lon)
    lat_radians = math.radians(lat)
    latitude_cosine = math.cos(lat_radians)
    return (
        latitude_cosine * math.cos(lon_radians),
        latitude_cosine * math.sin(lon_radians),
        math.sin(lat_radians),
    )


def _great_circle_distance_meters(
    first: list[float],
    second: list[float],
) -> float:
    first_vector = _unit_vector(first)
    second_vector = _unit_vector(second)
    cross = (
        first_vector[1] * second_vector[2]
        - first_vector[2] * second_vector[1],
        first_vector[2] * second_vector[0]
        - first_vector[0] * second_vector[2],
        first_vector[0] * second_vector[1]
        - first_vector[1] * second_vector[0],
    )
    cross_length = math.sqrt(sum(value * value for value in cross))
    dot = sum(
        first_value * second_value
        for first_value, second_value
        in zip(first_vector, second_vector)
    )
    return MOLLWEIDE_R * math.atan2(
        cross_length,
        min(1.0, max(-1.0, dot)),
    )


def _coordinate_linear_interpolate(
    first: list[float],
    second: list[float],
    fraction: float,
) -> list[float]:
    if fraction <= 0:
        return list(first)
    if fraction >= 1:
        return list(second)
    first_lon, first_lat = _validated_lon_lat(first)
    second_lon, second_lat = _validated_lon_lat(second)
    return [
        normalized_lon(
            first_lon
            + wrapped_lon_delta(second_lon, first_lon) * fraction
        ),
        first_lat + (second_lat - first_lat) * fraction,
    ]


def _spherical_interpolate(
    first: list[float],
    second: list[float],
    fraction: float,
) -> list[float]:
    if fraction <= 0:
        return list(first)
    if fraction >= 1:
        return list(second)
    first_vector = _unit_vector(first)
    second_vector = _unit_vector(second)
    dot = min(
        1.0,
        max(
            -1.0,
            sum(
                first_value * second_value
                for first_value, second_value
                in zip(first_vector, second_vector)
            ),
        ),
    )
    angle = math.acos(dot)
    if angle < 1e-15:
        return _coordinate_linear_interpolate(
            first,
            second,
            fraction,
        )
    if math.pi - angle < 1e-12:
        raise ValueError("Antipodal edge has no unique minor arc")
    sine = math.sin(angle)
    first_weight = math.sin((1 - fraction) * angle) / sine
    second_weight = math.sin(fraction * angle) / sine
    vector = tuple(
        first_weight * first_value + second_weight * second_value
        for first_value, second_value
        in zip(first_vector, second_vector)
    )
    length = math.sqrt(sum(value * value for value in vector))
    if not math.isfinite(length) or length <= 0:
        raise ValueError("Invalid spherical interpolation")
    x, y, z = (value / length for value in vector)
    return [
        math.degrees(math.atan2(y, x)),
        math.degrees(math.atan2(z, math.hypot(x, y))),
    ]


def _sampled_segment_interpolation_error_meters(
    first: list[float],
    second: list[float],
    fractions: tuple[float, ...],
) -> float:
    maximum = 0.0
    for fraction in fractions:
        coordinate_linear = _coordinate_linear_interpolate(
            first,
            second,
            fraction,
        )
        spherical = _spherical_interpolate(
            first,
            second,
            fraction,
        )
        maximum = max(
            maximum,
            _great_circle_distance_meters(
                coordinate_linear,
                spherical,
            ),
        )
    return maximum


def densify_ring_for_geodesic(
    ring: list[list[float]],
    maximum_error_meters: float,
) -> list[list[float]]:
    """
    Approximate one coordinate-linear closed ring with minor great-circle
    arcs. Adaptive subdivision uses quarter/midpoint samples; an independent
    eighth-sample pass validates every emitted segment.
    """
    if (
        not math.isfinite(maximum_error_meters)
        or maximum_error_meters <= 0
    ):
        raise ValueError("maximum_error_meters must be finite and positive")
    if len(ring) < 4:
        raise ValueError("Polygon ring has fewer than four positions")
    for point in ring:
        _validated_lon_lat(point)
    first_lon, first_lat = _validated_lon_lat(ring[0])
    last_lon, last_lat = _validated_lon_lat(ring[-1])
    if (
        abs(wrapped_lon_delta(last_lon, first_lon)) > 1e-12
        or abs(last_lat - first_lat) > 1e-12
    ):
        raise ValueError("Polygon ring is not closed")

    output = [list(ring[0])]
    subdivision_samples = (0.25, 0.5, 0.75)
    validation_samples = tuple(index / 8 for index in range(1, 8))
    maximum_depth = 24
    maximum_points = 1_000_000

    def append_edge(
        start: list[float],
        end: list[float],
        depth: int,
    ) -> None:
        if len(output) >= maximum_points:
            raise ValueError("Densified ring exceeds safety point limit")
        if _great_circle_distance_meters(start, end) <= 1e-9:
            output.append(list(end))
            return
        error = _sampled_segment_interpolation_error_meters(
            start,
            end,
            subdivision_samples,
        )
        if error <= maximum_error_meters:
            output.append(list(end))
            return
        if depth >= maximum_depth:
            raise ValueError(
                "Coordinate-linear edge did not converge under densification"
            )
        midpoint = _coordinate_linear_interpolate(
            start,
            end,
            0.5,
        )
        append_edge(start, midpoint, depth + 1)
        append_edge(midpoint, end, depth + 1)

    for start, end in zip(ring, ring[1:]):
        append_edge(start, end, 0)
    output[-1] = list(output[0])

    for start, end in zip(output, output[1:]):
        validated_error = _sampled_segment_interpolation_error_meters(
            start,
            end,
            validation_samples,
        )
        if validated_error > maximum_error_meters + 1e-6:
            raise ValueError(
                "Densified edge exceeds sampled approximation bound: "
                f"{validated_error:.9f} m"
            )
    return output


def densify_geometry_for_geodesic(
    geom: dict,
    maximum_error_meters: float,
) -> dict:
    """Apply `densify_ring_for_geodesic` to Polygon/MultiPolygon rings."""
    geometry_type = geom.get("type")
    if geometry_type == "Polygon":
        return {
            "type": "Polygon",
            "coordinates": [
                densify_ring_for_geodesic(
                    ring,
                    maximum_error_meters,
                )
                for ring in geom["coordinates"]
            ],
        }
    if geometry_type == "MultiPolygon":
        return {
            "type": "MultiPolygon",
            "coordinates": [
                [
                    densify_ring_for_geodesic(
                        ring,
                        maximum_error_meters,
                    )
                    for ring in polygon
                ]
                for polygon in geom["coordinates"]
            ],
        }
    raise ValueError(
        f"Unsupported geometry type for densification: {geometry_type}"
    )


def encode_wkb(geom: dict) -> bytes:
    """
    Encode a GeoJSON Polygon or MultiPolygon as little-endian WKB.

    WKB 1.2 layout:
      Polygon (type 3):
        u8  byte_order = 0x01
        u32 type       = 3
        u32 num_rings
        for ring:
            u32 num_points
            for point: f64 lon, f64 lat
      MultiPolygon (type 6):
        u8  byte_order = 0x01
        u32 type       = 6
        u32 num_polys
        for poly: full Polygon WKB (with its own header)

    Swift consumers: read with Data + withUnsafeBytes; or wrap with
    a small custom parser. Standard format — turf-swift and most
    geo libs accept WKB directly.
    """
    parts: list[bytes] = []
    t = geom.get("type")
    if t == "Polygon":
        rings = geom["coordinates"]
        parts.append(struct.pack("<BII", 0x01, 3, len(rings)))
        for ring in rings:
            parts.append(struct.pack("<I", len(ring)))
            for lon, lat in ring:
                parts.append(struct.pack("<dd", lon, lat))
    elif t == "MultiPolygon":
        polys = geom["coordinates"]
        parts.append(struct.pack("<BII", 0x01, 6, len(polys)))
        for rings in polys:
            parts.append(struct.pack("<BII", 0x01, 3, len(rings)))
            for ring in rings:
                parts.append(struct.pack("<I", len(ring)))
                for lon, lat in ring:
                    parts.append(struct.pack("<dd", lon, lat))
    else:
        raise ValueError(f"Unsupported geometry type for WKB: {t}")
    return b"".join(parts)


# ---------------------------------------------------------------------
# Phase 1B — GeoNames cities (populated places)
# ---------------------------------------------------------------------


def phase_geonames(conn: sqlite3.Connection) -> None:
    """
    Download GeoNames allCountries.zip, filter to feature_class='P' with
    feature_code in KEEP_FEATURE_CODES, and insert into city + city_rtree.

    The zip extracts to a single ~1.7 GB tab-separated file. We stream it
    rather than load fully — millions of rows, only ~1.5M of which are
    populated places we want.
    """
    print()
    print("═" * 60)
    print(" Phase 1B — GeoNames populated places")
    print("═" * 60)

    # Download cached zip
    print("\nDownloading allCountries.zip from GeoNames (~400 MB)...")
    print("(This is the big one — cached after first run.)")
    zip_path = _cached_download(GEONAMES_ALL_COUNTRIES)

    # Schema
    print("\nCreating schema...")
    conn.executescript(
        """
        DROP TABLE IF EXISTS city;
        DROP TABLE IF EXISTS city_rtree;
        CREATE TABLE city (
            geoname_id   INTEGER PRIMARY KEY,
            name         TEXT NOT NULL,
            name_lc      TEXT NOT NULL,
            iso_country  TEXT NOT NULL,
            admin1_code  TEXT,
            population   INTEGER NOT NULL DEFAULT 0,
            feature_code TEXT NOT NULL,
            lat          REAL NOT NULL,
            lon          REAL NOT NULL
        );
        CREATE VIRTUAL TABLE city_rtree USING rtree(
            geoname_id,
            min_lat, max_lat,
            min_lon, max_lon
        );
        """
    )

    # Stream and filter
    print("\nStreaming + filtering...")
    rows_total = 0
    rows_kept = 0
    batch: list[tuple] = []
    BATCH_SIZE = 10_000
    t0 = time.time()

    with zipfile.ZipFile(zip_path) as zf:
        # The zip contains a single file: allCountries.txt
        names = [n for n in zf.namelist() if n.endswith(".txt")]
        if not names:
            raise SystemExit("allCountries.zip didn't contain a .txt file?")
        inner_name = names[0]
        print(f"  Reading inner file: {inner_name}")

        with zf.open(inner_name) as raw:
            # Wrap in TextIOWrapper for utf-8 decoding without loading all
            reader = csv.reader(
                io.TextIOWrapper(raw, encoding="utf-8", newline=""),
                delimiter="\t",
                quoting=csv.QUOTE_NONE,
            )
            for row in reader:
                rows_total += 1
                if len(row) < 19:
                    continue
                feature_class = row[6]
                if feature_class != "P":
                    continue
                feature_code = row[7]
                if feature_code not in KEEP_FEATURE_CODES:
                    continue

                try:
                    geonameid = int(row[0])
                    lat = float(row[4])
                    lon = float(row[5])
                    population = int(row[14]) if row[14] else 0
                except ValueError:
                    continue

                # Generic-PPL population gate — admin codes bypass.
                # Keeps Apollonas (pop 250) and similar real villages,
                # drops the ~4.3M pop=0 noise entries.
                if (feature_code in GENERIC_FEATURE_CODES
                        and population < MIN_PPL_POPULATION):
                    continue

                name = row[1].strip()
                if not name:
                    continue
                iso_country = row[8].strip().upper()
                admin1_code = row[10].strip() or None

                batch.append(
                    (geonameid, name, name.lower(), iso_country, admin1_code,
                     population, feature_code, lat, lon)
                )
                rows_kept += 1

                if len(batch) >= BATCH_SIZE:
                    _flush_city_batch(conn, batch)
                    batch = []
                    if rows_kept % 100_000 == 0:
                        elapsed = time.time() - t0
                        print(f"  {rows_kept:,} kept of {rows_total:,} scanned "
                              f"({rows_kept * 100 / rows_total:.1f}%) in {elapsed:.0f}s")

    if batch:
        _flush_city_batch(conn, batch)

    # Helpful index for case-insensitive city-name lookups (search,
    # alt-name match). Pop the alpha-2 country index too since gravity
    # queries always filter by country.
    print("\nIndexing...")
    conn.executescript(
        """
        CREATE INDEX city_name_lc_idx ON city(name_lc);
        CREATE INDEX city_iso_idx     ON city(iso_country);
        CREATE INDEX city_pop_idx     ON city(population);
        """
    )
    conn.commit()

    elapsed = time.time() - t0
    print(f"\n✓ Phase 1B complete: {rows_kept:,} populated places "
          f"({100 * rows_kept / max(rows_total, 1):.1f}% of {rows_total:,} scanned) "
          f"in {elapsed:.0f}s")


def _flush_city_batch(conn: sqlite3.Connection, batch: list[tuple]) -> None:
    """Insert a batch into city and the matching city_rtree row."""
    conn.executemany(
        "INSERT INTO city (geoname_id, name, name_lc, iso_country, admin1_code, "
        "population, feature_code, lat, lon) "
        "VALUES (?,?,?,?,?,?,?,?,?)",
        batch,
    )
    # R*Tree row: bbox is (lat, lat, lon, lon) — a degenerate point
    rtree_rows = [(r[0], r[7], r[7], r[8], r[8]) for r in batch]
    conn.executemany(
        "INSERT INTO city_rtree (geoname_id, min_lat, max_lat, min_lon, max_lon) "
        "VALUES (?,?,?,?,?)",
        rtree_rows,
    )
    conn.commit()


# ---------------------------------------------------------------------
# Phase 1B helper — admin1 codes (the name lookup table)
# ---------------------------------------------------------------------

def phase_admin1_codes(conn: sqlite3.Connection) -> None:
    """
    Download admin1CodesASCII.txt and ingest as admin1_name. This is the
    text-name lookup keyed by (country_code, admin1_code). Separate from
    the polygon table (Phase 1C) — that's the geometric lookup.
    """
    print()
    print("═" * 60)
    print(" Phase 1B′ — GeoNames admin1 code → name table")
    print("═" * 60)

    path = _cached_download(GEONAMES_ADMIN1_CODES)

    conn.executescript(
        """
        DROP TABLE IF EXISTS admin1_name;
        CREATE TABLE admin1_name (
            iso_country  TEXT NOT NULL,
            admin1_code  TEXT NOT NULL,
            name         TEXT NOT NULL,
            asciiname    TEXT,
            geoname_id   INTEGER,
            PRIMARY KEY (iso_country, admin1_code)
        );
        """
    )

    rows = 0
    with open(path, encoding="utf-8") as f:
        reader = csv.reader(f, delimiter="\t", quoting=csv.QUOTE_NONE)
        batch = []
        for row in reader:
            if len(row) < 4:
                continue
            # Format: GR.A\tAttica\tAttica\t6692732
            country_admin1, name, asciiname, geoname_id = row[:4]
            if "." not in country_admin1:
                continue
            iso, code = country_admin1.split(".", 1)
            try:
                gid = int(geoname_id) if geoname_id else None
            except ValueError:
                gid = None
            batch.append((iso, code, name, asciiname, gid))
            rows += 1

    conn.executemany(
        "INSERT OR REPLACE INTO admin1_name "
        "(iso_country, admin1_code, name, asciiname, geoname_id) "
        "VALUES (?,?,?,?,?)",
        batch,
    )
    conn.commit()

    print(f"  ✓ {rows:,} admin1 codes loaded "
          f"(includes 'GR.B' → 'Attica', 'US.CA' → 'California', etc.)")


# ---------------------------------------------------------------------
# Phase 1C — NE 10m admin-1 polygons (states / regions)
# ---------------------------------------------------------------------

def phase_admin1_polygons(conn: sqlite3.Connection) -> None:
    """
    Load Natural Earth 1:10m admin_1_states_provinces, simplify, write
    polygon WKB + R*Tree index. This is Layer C of the resolver — replaces
    Apple's deprecated `administrativeArea` field with offline point-in-
    polygon lookup.

    ~4,600 polygons globally. After 0.01° Douglas-Peucker simplification
    and WKB packing, expect ~5 MB total. Coverage includes every named
    sub-national admin-1 division worldwide (states, provinces, regions,
    prefectures, oblasts, Bundesländer, etc.).
    """
    print()
    print("═" * 60)
    print(" Phase 1C — NE 10m admin-1 polygons")
    print("═" * 60)

    path = _cached_download(NE_ADMIN1_URL,
                            filename="ne_10m_admin_1_states_provinces.geojson")

    conn.executescript(
        """
        DROP TABLE IF EXISTS admin1;
        DROP TABLE IF EXISTS admin1_rtree;
        CREATE TABLE admin1 (
            id              INTEGER PRIMARY KEY,
            name            TEXT NOT NULL,
            name_en         TEXT,
            iso_country     TEXT,
            iso_3166_2      TEXT,
            type_en         TEXT,
            wkb             BLOB NOT NULL
        );
        CREATE VIRTUAL TABLE admin1_rtree USING rtree(
            id,
            min_lat, max_lat,
            min_lon, max_lon
        );
        CREATE INDEX admin1_iso_idx ON admin1(iso_country);
        """
    )

    print(f"\nLoading + simplifying (tolerance {ADMIN1_SIMPLIFY_TOLERANCE}°)...")
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    features = data.get("features", [])

    inserted = 0
    skipped = 0
    total_in_coords = 0
    total_out_coords = 0
    rows_admin1: list[tuple] = []
    rows_rtree: list[tuple] = []

    for f in features:
        props = f.get("properties") or {}
        geom = f.get("geometry") or {}

        name = (props.get("name") or props.get("name_en") or "").strip()
        if not name:
            skipped += 1
            continue
        if geom.get("type") not in ("Polygon", "MultiPolygon"):
            skipped += 1
            continue

        # Country code with fallback chain (NE's "-99" sentinel masks
        # some real countries — same gotcha as build-countries-10m.py).
        iso = None
        for key in ("iso_a2", "iso_a2_eh", "adm0_a2"):
            v = props.get(key)
            if v and v not in ("-99", "-"):
                iso = v
                break

        iso_3166_2 = props.get("iso_3166_2")
        if iso_3166_2 in ("-99", "-", ""):
            iso_3166_2 = None

        type_en = props.get("type_en") or props.get("type")

        # Count input vertices for diagnostics
        def n_coords(g):
            t = g.get("type")
            if t == "Polygon":
                return sum(len(r) for r in g["coordinates"])
            if t == "MultiPolygon":
                return sum(sum(len(r) for r in p) for p in g["coordinates"])
            return 0

        total_in_coords += n_coords(geom)
        simplified = simplify_geometry(geom, ADMIN1_SIMPLIFY_TOLERANCE)
        total_out_coords += n_coords(simplified)

        try:
            wkb = encode_wkb(simplified)
        except ValueError:
            skipped += 1
            continue

        min_lat, max_lat, min_lon, max_lon = geometry_bbox(simplified)

        # A polygon that simplified down to nothing (no coordinates) leaves
        # geometry_bbox at its inverted sentinel (min > max). Inserting that
        # into the R*Tree raises and aborts the ENTIRE build, so skip the
        # degenerate row instead of poisoning the batch.
        if min_lat > max_lat or min_lon > max_lon:
            skipped += 1
            continue

        # `id` is just the row index — admin-1 has no global stable ID
        # the way GeoNames cities do, so assign locally.
        #
        # An antimeridian-crossing feature (Chukotka, Fiji, the far
        # Aleutians) yields TWO lon segments: each gets its own base row +
        # R*Tree row; an R*Tree row cannot wrap and the
        # join is by id. The WKB is byte-identical in both copies; the
        # app's first-vertex-frame ringContains verifies either copy
        # correctly from either side of ±180°.
        for seg_min, seg_max in rtree_lon_segments(min_lon, max_lon):
            inserted += 1
            rows_admin1.append(
                (inserted, name, props.get("name_en"), iso, iso_3166_2, type_en, wkb)
            )
            rows_rtree.append((inserted, min_lat, max_lat, seg_min, seg_max))

    print(f"  Loaded {len(features)} features; kept {inserted}, skipped {skipped}")
    print(f"  Vertices: {total_in_coords:,} → {total_out_coords:,} "
          f"({100 * total_out_coords / max(total_in_coords, 1):.1f}%)")

    print("Inserting...")
    conn.executemany(
        "INSERT INTO admin1 (id, name, name_en, iso_country, iso_3166_2, "
        "type_en, wkb) VALUES (?,?,?,?,?,?,?)",
        rows_admin1,
    )
    conn.executemany(
        "INSERT INTO admin1_rtree (id, min_lat, max_lat, min_lon, max_lon) "
        "VALUES (?,?,?,?,?)",
        rows_rtree,
    )
    conn.commit()

    # Diagnostics: total WKB byte size
    wkb_bytes = conn.execute("SELECT SUM(LENGTH(wkb)) FROM admin1").fetchone()[0] or 0
    print(f"\n✓ Phase 1C complete: {inserted} admin-1 polygons, "
          f"{wkb_bytes / 1024 / 1024:.1f} MB of WKB blobs")


# ---------------------------------------------------------------------
# Phase 1D — GHS-FUA metro polygons (Functional Urban Areas)
# ---------------------------------------------------------------------

# Minimal ISO 3166-1 alpha-3 → alpha-2 mapping for the country codes
# that appear in GHS-FUA. The dataset uses alpha-3; the rest of our
# schema uses alpha-2 (to match GeoNames). Covers the ~200 countries
# in GHS-FUA — missing entries are silently skipped.
ISO3_TO_ISO2 = {
    "AFG":"AF","ALB":"AL","DZA":"DZ","ASM":"AS","AND":"AD","AGO":"AO","AIA":"AI","ATA":"AQ",
    "ATG":"AG","ARG":"AR","ARM":"AM","ABW":"AW","AUS":"AU","AUT":"AT","AZE":"AZ","BHS":"BS",
    "BHR":"BH","BGD":"BD","BRB":"BB","BLR":"BY","BEL":"BE","BLZ":"BZ","BEN":"BJ","BMU":"BM",
    "BTN":"BT","BOL":"BO","BES":"BQ","BIH":"BA","BWA":"BW","BVT":"BV","BRA":"BR","IOT":"IO",
    "BRN":"BN","BGR":"BG","BFA":"BF","BDI":"BI","CPV":"CV","KHM":"KH","CMR":"CM","CAN":"CA",
    "CYM":"KY","CAF":"CF","TCD":"TD","CHL":"CL","CHN":"CN","CXR":"CX","CCK":"CC","COL":"CO",
    "COM":"KM","COG":"CG","COD":"CD","COK":"CK","CRI":"CR","HRV":"HR","CUB":"CU","CUW":"CW",
    "CYP":"CY","CZE":"CZ","CIV":"CI","DNK":"DK","DJI":"DJ","DMA":"DM","DOM":"DO","ECU":"EC",
    "EGY":"EG","SLV":"SV","GNQ":"GQ","ERI":"ER","EST":"EE","SWZ":"SZ","ETH":"ET","FLK":"FK",
    "FRO":"FO","FJI":"FJ","FIN":"FI","FRA":"FR","GUF":"GF","PYF":"PF","ATF":"TF","GAB":"GA",
    "GMB":"GM","GEO":"GE","DEU":"DE","GHA":"GH","GIB":"GI","GRC":"GR","GRL":"GL","GRD":"GD",
    "GLP":"GP","GUM":"GU","GTM":"GT","GGY":"GG","GIN":"GN","GNB":"GW","GUY":"GY","HTI":"HT",
    "HMD":"HM","VAT":"VA","HND":"HN","HKG":"HK","HUN":"HU","ISL":"IS","IND":"IN","IDN":"ID",
    "IRN":"IR","IRQ":"IQ","IRL":"IE","IMN":"IM","ISR":"IL","ITA":"IT","JAM":"JM","JPN":"JP",
    "JEY":"JE","JOR":"JO","KAZ":"KZ","KEN":"KE","KIR":"KI","PRK":"KP","KOR":"KR","KWT":"KW",
    "KGZ":"KG","LAO":"LA","LVA":"LV","LBN":"LB","LSO":"LS","LBR":"LR","LBY":"LY","LIE":"LI",
    "LTU":"LT","LUX":"LU","MAC":"MO","MKD":"MK","MDG":"MG","MWI":"MW","MYS":"MY","MDV":"MV",
    "MLI":"ML","MLT":"MT","MHL":"MH","MTQ":"MQ","MRT":"MR","MUS":"MU","MYT":"YT","MEX":"MX",
    "FSM":"FM","MDA":"MD","MCO":"MC","MNG":"MN","MNE":"ME","MSR":"MS","MAR":"MA","MOZ":"MZ",
    "MMR":"MM","NAM":"NA","NRU":"NR","NPL":"NP","NLD":"NL","NCL":"NC","NZL":"NZ","NIC":"NI",
    "NER":"NE","NGA":"NG","NIU":"NU","NFK":"NF","MNP":"MP","NOR":"NO","OMN":"OM","PAK":"PK",
    "PLW":"PW","PSE":"PS","PAN":"PA","PNG":"PG","PRY":"PY","PER":"PE","PHL":"PH","PCN":"PN",
    "POL":"PL","PRT":"PT","PRI":"PR","QAT":"QA","ROU":"RO","RUS":"RU","RWA":"RW","REU":"RE",
    "BLM":"BL","SHN":"SH","KNA":"KN","LCA":"LC","MAF":"MF","SPM":"PM","VCT":"VC","WSM":"WS",
    "SMR":"SM","STP":"ST","SAU":"SA","SEN":"SN","SRB":"RS","SYC":"SC","SLE":"SL","SGP":"SG",
    "SXM":"SX","SVK":"SK","SVN":"SI","SLB":"SB","SOM":"SO","ZAF":"ZA","SGS":"GS","SSD":"SS",
    "ESP":"ES","LKA":"LK","SDN":"SD","SUR":"SR","SJM":"SJ","SWE":"SE","CHE":"CH","SYR":"SY",
    "TWN":"TW","TJK":"TJ","TZA":"TZ","THA":"TH","TLS":"TL","TGO":"TG","TKL":"TK","TON":"TO",
    "TTO":"TT","TUN":"TN","TUR":"TR","TKM":"TM","TCA":"TC","TUV":"TV","UGA":"UG","UKR":"UA",
    "ARE":"AE","GBR":"GB","USA":"US","UMI":"UM","URY":"UY","UZB":"UZ","VUT":"VU","VEN":"VE",
    "VNM":"VN","VGB":"VG","VIR":"VI","WLF":"WF","ESH":"EH","YEM":"YE","ZMB":"ZM","ZWE":"ZW",
}


def phase_ghs_fua(conn: sqlite3.Connection) -> None:
    """
    Load GHS-FUA Functional Urban Areas, reproject from Mollweide to
    WGS84, simplify, write polygon WKB + R*Tree index. This is Layer A
    primary — point-in-polygon for "you are in the Athens / Istanbul /
    Tokyo metro" detection.

    The dataset is 9,031 polygons in EPSG:54009 (World Mollweide).
    After reprojection, simplification at FUA_SIMPLIFY_TOLERANCE, and
    WKB packing, expect ~5-8 MB at 0.003° (was ~1.3 MB at the old,
    layer-destroying 0.02° — see the tolerance constant's comment).
    """
    print()
    print("═" * 60)
    print(" Phase 1D — GHS-FUA metro polygons")
    print("═" * 60)

    zip_path = _cached_download(
        GHS_FUA_URL,
        filename="GHS_FUA.zip",
        expected_sha256=GHS_FUA_ZIP_SHA256,
    )
    print(f"\nExtracting pinned GeoPackage from {zip_path.name}...")
    gpkg_path = _extract_pinned_zip_member(
        zip_path,
        GHS_FUA_GPKG_MEMBER,
        GHS_FUA_GPKG_SHA256,
    )
    print(f"  Reading {gpkg_path.name}")

    # try/finally so the read-only handle is released on ANY exception in the
    # reprojection loop below; an unexpected column
    # shape, a StopIteration out of a glob, a coercion the broad excepts don't
    # cover. `phase_ghs_ucdb` uses the same handle cleanup.
    src = sqlite3.connect(f"file:{gpkg_path}?mode=ro", uri=True)
    try:
        # The data table's name matches the file name. Look it up rather
        # than hard-coding so this survives a version bump.
        table_name = src.execute(
            "SELECT table_name FROM gpkg_geometry_columns LIMIT 1"
        ).fetchone()[0]
        print(f"  Source table: {table_name}")

        # Output schema
        conn.executescript(
            """
            DROP TABLE IF EXISTS fua;
            DROP TABLE IF EXISTS fua_rtree;
            CREATE TABLE fua (
                efua_id         INTEGER PRIMARY KEY,
                name            TEXT NOT NULL,
                iso_country     TEXT NOT NULL,   -- alpha-2
                fua_area_km2    REAL,
                uc_area_km2     REAL,
                fua_pop_2015    INTEGER,
                uc_pop_2015     INTEGER,
                wkb             BLOB NOT NULL
            );
            CREATE VIRTUAL TABLE fua_rtree USING rtree(
                efua_id,
                min_lat, max_lat,
                min_lon, max_lon
            );
            CREATE INDEX fua_iso_idx  ON fua(iso_country);
            CREATE INDEX fua_pop_idx  ON fua(uc_pop_2015);
            """
        )

        print("\nReprojecting + simplifying...")
        rows_fua: list[tuple] = []
        rows_rtree: list[tuple] = []
        inserted = 0
        skipped = 0
        skipped_iso = 0
        simplified_vertices = 0
        operational_vertices = 0

        def vertex_count(geometry: dict) -> int:
            geometry_type = geometry.get("type")
            if geometry_type == "Polygon":
                return sum(
                    len(ring)
                    for ring in geometry["coordinates"]
                )
            if geometry_type == "MultiPolygon":
                return sum(
                    len(ring)
                    for polygon in geometry["coordinates"]
                    for ring in polygon
                )
            return 0

        cursor = src.execute(
            f'SELECT eFUA_ID, eFUA_name, Cntry_ISO, FUA_area, UC_area, '
            f'FUA_p_2015, UC_p_2015, geom FROM "{table_name}"'
        )

        for efua_id, name, cntry_iso3, fua_area, uc_area, fua_pop, uc_pop, geom_blob in cursor:
            if not geom_blob or not name:
                skipped += 1
                continue

            iso2 = ISO3_TO_ISO2.get(cntry_iso3)
            if not iso2:
                skipped_iso += 1
                continue

            # GPB → WKB → GeoJSON → reproject → simplify → WKB
            try:
                wkb = parse_gpb_to_wkb(bytes(geom_blob))
                geom_mollweide = decode_wkb_to_geojson(wkb)
            except (ValueError, struct.error) as e:
                skipped += 1
                continue

            geom_wgs84 = reproject_geometry(geom_mollweide)
            geom_simplified = simplify_geometry(geom_wgs84, FUA_SIMPLIFY_TOLERANCE)

            try:
                geom_operational = densify_geometry_for_geodesic(
                    geom_simplified,
                    FUA_OPERATIONAL_MAX_ERROR_METERS,
                )
                out_wkb = encode_wkb(geom_operational)
            except ValueError:
                skipped += 1
                continue
            simplified_vertices += vertex_count(geom_simplified)
            operational_vertices += vertex_count(geom_operational)

            min_lat, max_lat, min_lon, max_lon = geometry_bbox(
                geom_operational
            )

            # Skip a geometry that simplified to nothing — geometry_bbox returns its
            # inverted sentinel (min > max) and the R*Tree insert below would raise
            # and abort the whole build.
            if min_lat > max_lat or min_lon > max_lon:
                skipped += 1
                continue
            min_lat, max_lat, min_lon, max_lon = expand_geographic_bbox(
                min_lat,
                max_lat,
                min_lon,
                max_lon,
                FUA_RTREE_PADDING_METERS,
            )

            # Antimeridian-crossing FUAs: the second lon
            # segment gets a twin base row under FUA_DATELINE_OFF + efua_id —
            # an R*Tree row cannot wrap and the join is by efua_id. Real eFUA
            # ids are small ints, far below the offset.
            for i, (seg_min, seg_max) in enumerate(rtree_lon_segments(min_lon, max_lon)):
                row_id = int(efua_id) if i == 0 else FUA_DATELINE_OFF + int(efua_id)
                rows_fua.append(
                    (row_id, name, iso2,
                     float(fua_area) if fua_area is not None else None,
                     float(uc_area) if uc_area is not None else None,
                     int(fua_pop) if fua_pop is not None else None,
                     int(uc_pop) if uc_pop is not None else None,
                     out_wkb)
                )
                rows_rtree.append((row_id, min_lat, max_lat, seg_min, seg_max))
            inserted += 1

    finally:
        src.close()

    print(f"  Inserted {inserted} FUAs, skipped {skipped} (bad geom/missing data), "
          f"{skipped_iso} (unmapped ISO3)")
    print(
        "  Operational densification: "
        f"{simplified_vertices:,} → {operational_vertices:,} vertices "
        f"(sampled error ≤ {FUA_OPERATIONAL_MAX_ERROR_METERS:.2f} m)"
    )

    conn.executemany(
        "INSERT OR REPLACE INTO fua (efua_id, name, iso_country, fua_area_km2, "
        "uc_area_km2, fua_pop_2015, uc_pop_2015, wkb) "
        "VALUES (?,?,?,?,?,?,?,?)",
        rows_fua,
    )
    # OR REPLACE to match the `fua` insert above: a
    # duplicate eFUA_ID in the source replaces the fua row, and a plain
    # INSERT here then dies on the R*Tree rowid collision, killing the
    # whole phase. Symmetric OR REPLACE keeps both tables on the LAST
    # duplicate consistently — no orphaned/mismatched spatial entry.
    conn.executemany(
        "INSERT OR REPLACE INTO fua_rtree (efua_id, min_lat, max_lat, min_lon, max_lon) "
        "VALUES (?,?,?,?,?)",
        rows_rtree,
    )
    stored_rows = list(
        conn.execute(
            "SELECT efua_id, name, iso_country, fua_area_km2, "
            "uc_area_km2, fua_pop_2015, uc_pop_2015, wkb "
            "FROM fua ORDER BY efua_id"
        )
    )
    layer_digest = _stable_rows_sha256(stored_rows)
    wkb_bytes = sum(len(row[-1]) for row in stored_rows)
    _validate_fua_build(
        feature_count=inserted,
        skipped_geometry_count=skipped,
        unmapped_iso_count=skipped_iso,
        simplified_vertex_count=simplified_vertices,
        operational_vertex_count=operational_vertices,
        wkb_bytes=wkb_bytes,
        layer_sha256=layer_digest,
    )
    _upsert_build_metadata(
        conn,
        {
            "fua_dataset_version": FUA_DATASET_VERSION,
            "fua_edge_interpolation": "minor-great-circle",
            "fua_feature_count": str(inserted),
            "fua_geometry_transform_version":
                FUA_GEOMETRY_TRANSFORM_VERSION,
            "fua_layer_sha256": layer_digest,
            "fua_max_sampled_interpolation_error_meters":
                f"{FUA_OPERATIONAL_MAX_ERROR_METERS:.2f}",
            "fua_operational_vertex_count": str(operational_vertices),
            "fua_physical_row_count": str(len(stored_rows)),
            "fua_rtree_padding_meters":
                f"{FUA_RTREE_PADDING_METERS:.2f}",
            "fua_simplified_vertex_count": str(simplified_vertices),
            "fua_source_gpkg_member": GHS_FUA_GPKG_MEMBER,
            "fua_source_gpkg_sha256": GHS_FUA_GPKG_SHA256,
            "fua_source_url": GHS_FUA_URL,
            "fua_source_zip_sha256": GHS_FUA_ZIP_SHA256,
        },
    )
    conn.commit()

    print(f"\n✓ Phase 1D complete: {inserted} FUA polygons, "
          f"{wkb_bytes / 1024 / 1024:.1f} MB of WKB blobs")


# ---------------------------------------------------------------------
# Phase 1F — GHS-UCDB R2024A urban centres (the home-shape seed layer)
# ---------------------------------------------------------------------

def _resolve_ucdb_table(src: sqlite3.Connection) -> str:
    """
    Pick the general-characteristics geometry layer out of the 16 the source
    ships, and verify its CRS. Fails loudly rather than guessing: an ambiguous
    or missing match means the release layout changed, and silently building
    against the wrong theme would produce a plausible-looking bad layer.
    """
    rows = src.execute(
        "SELECT table_name, srs_id FROM gpkg_geometry_columns "
        "WHERE table_name LIKE ? ORDER BY table_name",
        (UCDB_TABLE_PATTERN,),
    ).fetchall()
    if len(rows) != 1:
        names = ", ".join(r[0] for r in rows) or "(none)"
        raise SystemExit(
            f"UCDB: expected exactly one geometry layer matching "
            f"{UCDB_TABLE_PATTERN!r}, found {len(rows)}: {names}\n"
            f"The source layout changed — update UCDB_TABLE_PATTERN."
        )
    table_name, srs_id = rows[0]
    if srs_id != UCDB_SOURCE_SRS_ID:
        raise SystemExit(
            f"UCDB: layer {table_name} declares srs_id={srs_id}, expected "
            f"{UCDB_SOURCE_SRS_ID} (World_Mollweide).\n"
            f"Reprojecting a non-Mollweide source would corrupt every vertex. "
            f"Refusing to build."
        )
    return table_name


def _resolve_ucdb_columns(src: sqlite3.Connection, table_name: str) -> dict[str, str]:
    """Map logical field -> actual (year-suffixed) column name."""
    available = [r[1] for r in src.execute(f'PRAGMA table_info("{table_name}")')]
    resolved: dict[str, str] = {}
    for logical, prefix in UCDB_COLUMN_PREFIXES.items():
        matches = sorted(c for c in available if c.startswith(prefix))
        if not matches:
            raise SystemExit(
                f"UCDB: no column starting with {prefix!r} in {table_name}.\n"
                f"Available: {', '.join(available)}"
            )
        # A release could carry several data years; take the newest suffix.
        resolved[logical] = matches[-1]
    if UCDB_ID_COLUMN not in available:
        raise SystemExit(f"UCDB: missing id column {UCDB_ID_COLUMN} in {table_name}")
    return resolved


def phase_ghs_ucdb(conn: sqlite3.Connection, gpkg_path: Path) -> None:
    """
    Ingest GHS-UCDB R2024A urban centres as the `urban_centre` layer.

    This is the seed consumed by HomeShape:
    the polygon containing a user's declared home IS their baseline home
    region. It is a decision boundary, not a display label, which drives two
    departures from phase 1D:

      * NO simplification (see UCDB_GPKG_PATH_DEFAULT for the measurements).
      * A row is NEVER dropped for missing attributes. 14 source centres have
        a NULL name — in Madagascar, South Sudan, Afghanistan, Ethiopia and
        the DRC. Phase 1D's `if not name: skip` would discard exactly the
        places whose residents are least well served elsewhere, and a
        nameless urban centre is still a perfectly good home shape. Only a
        geometry that cannot be parsed, encoded, or bounded is skipped.

    UCDB carries no ISO code — only GADM country NAMES (191 distinct). We
    store the name verbatim rather than mapping it: phase 1D drops rows whose
    ISO3 will not map, and applying that here would lose urban centres for a
    country-name spelling mismatch. Nothing in the home-shape design needs an
    ISO code; containment and area are the whole job.
    """
    print("\n=== Phase 1F: GHS-UCDB R2024A urban centres ===")

    if not gpkg_path.exists():
        raise SystemExit(
            f"UCDB source not found: {gpkg_path}\n\n"
            f"Download GHS-UCDB R2024A (GeoPackage, ~285 MB) from\n"
            f"  https://human-settlement.emergency.copernicus.eu/ghs_ucdb_2024.php\n"
            f"and extract it so the .gpkg lands at the path above, or pass\n"
            f"  --ucdb-input /path/to/GHS_UCDB_GLOBE_R2024A.gpkg\n"
            f"Licence: CC BY 4.0 — attribution required in-app."
        )

    src = sqlite3.connect(f"file:{gpkg_path}?mode=ro", uri=True)
    try:
        table_name = _resolve_ucdb_table(src)
        cols = _resolve_ucdb_columns(src, table_name)
        print(f"  Source table: {table_name}")
        print(f"  Columns: {', '.join(f'{k}={v}' for k, v in sorted(cols.items()))}")

        conn.executescript(
            """
            DROP TABLE IF EXISTS urban_centre;
            DROP TABLE IF EXISTS urban_centre_rtree;
            CREATE TABLE urban_centre (
                uc_id        INTEGER PRIMARY KEY,
                name         TEXT,             -- NULL for 14 source centres
                country_name TEXT,             -- GADM name; source has no ISO
                area_km2     REAL NOT NULL,    -- source attribute, NOT polygon area
                population   INTEGER,
                wkb          BLOB NOT NULL
            );
            CREATE VIRTUAL TABLE urban_centre_rtree USING rtree(
                uc_id,
                min_lat, max_lat,
                min_lon, max_lon
            );
            CREATE INDEX urban_centre_country_idx ON urban_centre(country_name);
            """
        )

        rows_uc: list[tuple] = []
        rows_rtree: list[tuple] = []
        inserted = 0
        skipped_geometry = 0
        skipped_area = 0
        nameless = 0
        dateline = 0
        vertex_count = 0

        cursor = src.execute(
            f'SELECT "{UCDB_ID_COLUMN}", "{cols["name"]}", "{cols["country"]}", '
            f'"{cols["area"]}", "{cols["population"]}", geom FROM "{table_name}"'
        )

        for uc_id, name, country, area, population, geom_blob in cursor:
            if not geom_blob:
                skipped_geometry += 1
                continue
            # D* = sqrt(area/pi) is undefined without an area, and the polygon's
            # own area is not a substitute (the source attribute is computed on
            # the 1 km grid). Skip loudly rather than invent one. Zero rows hit
            # this today; the counter exists so a release change is visible.
            if area is None:
                skipped_area += 1
                continue

            try:
                wkb = parse_gpb_to_wkb(bytes(geom_blob))
                geom_mollweide = decode_wkb_to_geojson(wkb)
            except (ValueError, struct.error):
                skipped_geometry += 1
                continue

            # Reproject only — no simplification pass, by design.
            geom_wgs84 = reproject_geometry(geom_mollweide)

            try:
                out_wkb = encode_wkb(geom_wgs84)
            except ValueError:
                skipped_geometry += 1
                continue

            min_lat, max_lat, min_lon, max_lon = geometry_bbox(geom_wgs84)
            if min_lat > max_lat or min_lon > max_lon:
                # geometry_bbox's inverted sentinel — an R*Tree insert would
                # raise and abort the phase.
                skipped_geometry += 1
                continue

            clean_name = (name or "").strip() or None
            if clean_name is None:
                nameless += 1

            segments = rtree_lon_segments(min_lon, max_lon)
            if len(segments) > 1:
                dateline += 1
            for i, (seg_min, seg_max) in enumerate(segments):
                row_id = int(uc_id) if i == 0 else UC_DATELINE_OFF + int(uc_id)
                rows_uc.append(
                    (row_id, clean_name, country,
                     float(area),
                     int(population) if population is not None else None,
                     out_wkb)
                )
                rows_rtree.append((row_id, min_lat, max_lat, seg_min, seg_max))

            vertex_count += sum(
                len(r)
                for poly in (geom_wgs84["coordinates"]
                             if geom_wgs84["type"] == "MultiPolygon"
                             else [geom_wgs84["coordinates"]])
                for r in poly
            )
            inserted += 1
    finally:
        src.close()

    # OR REPLACE on both tables, symmetric with phase 1D: a
    # duplicate source id must land the same way in the base table and the
    # R*Tree, or a plain INSERT dies on a rowid collision mid-phase and leaves
    # the layer half-built.
    conn.executemany(
        "INSERT OR REPLACE INTO urban_centre "
        "(uc_id, name, country_name, area_km2, population, wkb) VALUES (?,?,?,?,?,?)",
        rows_uc,
    )
    conn.executemany(
        "INSERT OR REPLACE INTO urban_centre_rtree "
        "(uc_id, min_lat, max_lat, min_lon, max_lon) VALUES (?,?,?,?,?)",
        rows_rtree,
    )
    conn.commit()

    # --- integrity: the layer is unusable if these do not hold ---
    base_rows = conn.execute("SELECT COUNT(*) FROM urban_centre").fetchone()[0]
    rtree_rows = conn.execute("SELECT COUNT(*) FROM urban_centre_rtree").fetchone()[0]
    orphans = conn.execute(
        "SELECT COUNT(*) FROM urban_centre u "
        "LEFT JOIN urban_centre_rtree r ON r.uc_id = u.uc_id WHERE r.uc_id IS NULL"
    ).fetchone()[0]
    if base_rows != len(rows_uc) or rtree_rows != len(rows_rtree):
        raise SystemExit(
            f"UCDB: row-count mismatch after insert — base {base_rows}/"
            f"{len(rows_uc)}, rtree {rtree_rows}/{len(rows_rtree)}"
        )
    if orphans:
        raise SystemExit(f"UCDB: {orphans} urban_centre rows have no R*Tree entry")

    wkb_bytes = conn.execute(
        "SELECT SUM(LENGTH(wkb)) FROM urban_centre"
    ).fetchone()[0] or 0

    conn.execute(
        "CREATE TABLE IF NOT EXISTS build_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)"
    )
    for key, value in [
        ("uc_dataset_version", "GHS_UCDB_GLOBE_R2024A_V1_2"),
        ("uc_source_gpkg_member", gpkg_path.name),
        ("uc_source_table", table_name),
        ("uc_geometry_transform_version", UC_GEOMETRY_TRANSFORM_VERSION),
        ("uc_simplify_tolerance", "none"),
        ("uc_feature_count", str(inserted)),
        ("uc_physical_row_count", str(base_rows)),
        ("uc_vertex_count", str(vertex_count)),
        ("uc_nameless_count", str(nameless)),
        ("uc_dateline_feature_count", str(dateline)),
        ("uc_licence", "CC BY 4.0 — European Commission JRC, GHS-UCDB R2024A"),
    ]:
        conn.execute(
            "INSERT OR REPLACE INTO build_meta (key, value) VALUES (?,?)", (key, value)
        )
    conn.commit()

    print(f"  Inserted {inserted} urban centres ({base_rows} physical rows, "
          f"{dateline} antimeridian twins)")
    print(f"  {nameless} nameless centres KEPT (never a drop reason)")
    if skipped_geometry or skipped_area:
        print(f"  Skipped {skipped_geometry} (bad geometry), "
              f"{skipped_area} (no area attribute)")
    print(f"\n✓ Phase 1F complete: {vertex_count:,} vertices, "
          f"{wkb_bytes / 1024 / 1024:.1f} MB of WKB blobs")


# ---------------------------------------------------------------------
# Phase 1E — OSM islands + neighborhoods (from osmium-export geojsonseq)
# ---------------------------------------------------------------------

# Notability filter applied to place=neighbourhood / place=suburb. These
# tags are MANY worldwide (~280K total) but most are unknown to anyone
# outside the immediate locality. Notability signals indicate "this is
# a place travelers / Wikipedia / other languages have heard of."
#
# A place qualifies if it has ANY of:
#   - `wikidata`  tag (Wikidata Q-ID — strong signal)
#   - `wikipedia` tag (Wikipedia article exists)
#   - 3+ `name:LANG` tags (translated into multiple languages)
#   - `name:en` tag (specifically has English name → tourist relevance)
#
# This is the data-driven replacement for a hand-curated allowlist.
# Named neighborhoods with notability tags are retained; local districts
# without those tags are filtered out.

def _polygon_is_valid(geom: dict) -> bool:
    """
    Validity check after `simplify_geometry` has already filtered out
    degenerate rings. A geometry is valid iff it has at least one sub-
    polygon with an outer ring — empty geometries (every ring collapsed)
    are skipped at the caller, since WKB-encoding them would emit
    zero-length structures that no consumer can usefully PIP against.
    """
    t = geom.get("type")
    if t == "Polygon":
        return bool(geom.get("coordinates")) and len(geom["coordinates"][0]) >= 4
    if t == "MultiPolygon":
        return any(p and len(p[0]) >= 4 for p in geom.get("coordinates", []))
    return False


def _is_notable_neighborhood(props: dict) -> bool:
    if props.get("wikidata"): return True
    if props.get("wikipedia"): return True
    if props.get("name:en"): return True
    # Count any `name:*` tags
    lang_names = sum(1 for k in props if k.startswith("name:"))
    return lang_names >= 3


def _iter_geojsonseq(path: Path):
    """
    Iterate Feature dicts from a GeoJSON-text-sequence file (RFC 7464).
    Each record is JSON, separated by 0x1E (RS) + 0x0A (LF). Some
    osmium versions emit just 0x0A (NDJSON). Handle both.
    """
    rs = 0x1E
    with open(path, "rb") as f:
        buf = b""
        for chunk in iter(lambda: f.read(1 << 20), b""):
            buf += chunk
            while True:
                # Try to find a newline-terminated record
                i = buf.find(b"\n")
                if i < 0:
                    break
                record = buf[:i]
                buf = buf[i + 1:]
                # Strip leading 0x1E if present (RFC 7464)
                if record and record[0] == rs:
                    record = record[1:]
                record = record.strip()
                if not record:
                    continue
                try:
                    yield json.loads(record)
                except json.JSONDecodeError:
                    continue
        # Tail
        if buf.strip():
            tail = buf.strip()
            if tail and tail[0] == rs:
                tail = tail[1:]
            try:
                yield json.loads(tail)
            except json.JSONDecodeError:
                pass


def _island_supplement_marker(conn: sqlite3.Connection) -> str | None:
    """The `build_meta` marker supplement-islands.py stamps after enriching
    the island tables, or None when absent (fresh DB / never supplemented /
    pre-marker builds)."""
    has_meta = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='build_meta'"
    ).fetchone()
    if not has_meta:
        return None
    row = conn.execute(
        "SELECT value FROM build_meta WHERE key='island_supplement_applied'"
    ).fetchone()
    return row[0] if row else None


def phase_osm_places(conn: sqlite3.Connection, input_path: Path,
                     wipe_supplement: bool = False) -> None:
    """
    Read an osmium-exported GeoJSON-sequence containing OSM
    `place=island`, `place=neighbourhood`, and `place=suburb` features.
    Filter neighbourhoods by notability signals (wikidata / wikipedia /
    multi-language names). Write islands as polygons (always), and
    notable neighbourhoods as points (or polygons if available).

    The osmium output is produced on a desktop-class machine per the
    OSM_GEOJSONSEQ_PATH_DEFAULT docstring at the top of this file. The
    Python side here is stdlib-only and fast — minutes for the ~500 MB
    geojsonseq input.
    """
    print()
    print("═" * 60)
    print(" Phase 1E — OSM islands + neighborhoods")
    print("═" * 60)

    if not input_path.exists():
        print(f"\n  ⚠  OSM input not found: {input_path}")
        print()
        print("  Phase 1E requires a pre-processed OSM extract. On a")
        print("  desktop-class machine (~70 GB free disk needed):")
        print()
        print("    brew install osmium-tool")
        print("    wget https://planet.openstreetmap.org/pbf/planet-latest.osm.pbf")
        print("    osmium tags-filter planet-latest.osm.pbf \\")
        print("        n/place=neighbourhood,suburb \\")
        print("        n/place=island w/place=island r/place=island \\")
        print("        -o filtered.osm.pbf")
        print("    osmium export filtered.osm.pbf -f geojsonseq \\")
        print(f"        -o {input_path}")
        print()
        print("  Then re-run with --phase=1e (or --phase=all).")
        print()
        print("  Phase 1E SKIPPED — Geocoder.sqlite still usable without it,")
        print("  but Karaköy / Beverly Hills / etc. won't appear at the")
        print("  neighborhood level in the timeline.")
        return

    # Refuse to silently discard the Wikidata island supplement:
    # this phase drops and recreates the island/neighborhood
    # tables, so running it over a Geocoder.sqlite that
    # supplement-islands.py already enriched throws ~4,800 island rows
    # away — the rebuild procedure's ordering landmine (the supplement is
    # ALWAYS the last step; see REBUILD_GEOCODER.md §4.5). Passing
    # --wipe-supplement acknowledges the loss; re-run the supplement
    # afterwards.
    marker = _island_supplement_marker(conn)
    if marker is not None and not wipe_supplement:
        print(f"\n  ✗ This database carries the Wikidata island supplement ({marker}).")
        print("    Phase 1E would DROP those rows. Either:")
        print("      - run 1E against a pre-supplement baseline, then re-run")
        print("        scripts/supplement-islands.py (the documented order), or")
        print("      - pass --wipe-supplement to proceed anyway, then RE-RUN the")
        print("        supplement before shipping.")
        sys.exit(1)
    if marker is not None:
        # Proceeding under --wipe-supplement: clear the marker so the fresh
        # (unsupplemented) tables aren't mistaken for enriched ones.
        conn.execute("DELETE FROM build_meta WHERE key='island_supplement_applied'")
        conn.commit()
        print(f"  --wipe-supplement: discarding supplement rows ({marker}); re-run supplement-islands.py before shipping.")

    print(f"\nReading {input_path.name}...")
    in_size_mb = input_path.stat().st_size / 1024 / 1024
    print(f"  Input size: {in_size_mb:.1f} MB")

    # Schema
    conn.executescript(
        """
        DROP TABLE IF EXISTS neighborhood;
        DROP TABLE IF EXISTS neighborhood_rtree;
        DROP TABLE IF EXISTS island;
        DROP TABLE IF EXISTS island_rtree;

        CREATE TABLE neighborhood (
            osm_id          INTEGER PRIMARY KEY,
            name            TEXT NOT NULL,
            name_en         TEXT,
            place_kind      TEXT NOT NULL,
            wikidata        TEXT,
            wikipedia       TEXT,
            lat             REAL NOT NULL,
            lon             REAL NOT NULL,
            wkb             BLOB   -- NULL for nodes; polygon for ways/relations
        );
        CREATE VIRTUAL TABLE neighborhood_rtree USING rtree(
            osm_id, min_lat, max_lat, min_lon, max_lon
        );
        CREATE INDEX neighborhood_name_idx ON neighborhood(name);

        CREATE TABLE island (
            osm_id      INTEGER PRIMARY KEY,
            name        TEXT NOT NULL,
            name_en     TEXT,
            wikidata    TEXT,
            wkb         BLOB NOT NULL
        );
        CREATE VIRTUAL TABLE island_rtree USING rtree(
            osm_id, min_lat, max_lat, min_lon, max_lon
        );
        """
    )

    nb_rows: list[tuple] = []
    nb_rtree: list[tuple] = []
    is_rows: list[tuple] = []
    is_rtree: list[tuple] = []
    scanned = 0
    kept_nb = 0
    skipped_nb_unnotable = 0
    kept_is = 0
    t0 = time.time()

    # osmium emits feature IDs in one of three formats depending on the
    # export flag used:
    #   `-a id,type`              → props["@type"]="node", props["@id"]=123 (int)
    #   `--add-unique-id=type_id` → feat["id"]="n123" (top-level, type-letter prefix)
    #   legacy / custom configs   → props["@id"]="node/123"
    # When NONE of these flags are set, no ID is emitted and we fall back
    # to a synthetic auto-increment counter (osm_id then becomes a SQLite
    # primary key only, no longer a traceable OSM reference). For a
    # build that needs to cross-reference Wikidata's P402 (OSM relation
    # ID), `-a id,type` is the recommended flag.
    next_auto_id = [1]  # mutable holder, used as nonlocal counter

    def parse_osm_id(at_id: str | None) -> tuple[int, str]:
        if not at_id:
            return (0, "")
        parts = at_id.split("/", 1)
        if len(parts) != 2:
            return (0, at_id)
        try:
            return (int(parts[1]), parts[0])
        except ValueError:
            return (0, at_id)

    NODE_OFF = 0
    WAY_OFF = 10**12
    REL_OFF = 2 * (10**12)
    AUTO_OFF = 3 * (10**12)  # auto-increment IDs live above the typed namespaces

    def normalize_feature_id(feat: dict, props: dict) -> str | None:
        """Coerce any of osmium's three @id encodings into 'type/id' form."""
        at_id = props.get("@id")
        if isinstance(at_id, str) and "/" in at_id:
            return at_id
        if isinstance(at_id, int):
            at_type = props.get("@type")
            if at_type in ("node", "way", "relation", "area"):
                # osmium emits @type=area for closed-way polygons; treat
                # those as ways for ID-packing purposes.
                if at_type == "area":
                    at_type = "way"
                return f"{at_type}/{at_id}"
        top = feat.get("id")
        if isinstance(top, str) and len(top) >= 2 and top[1:].isdigit():
            kind = {"n": "node", "w": "way", "r": "relation"}.get(top[0])
            if kind:
                return f"{kind}/{top[1:]}"
        return None

    def packed_id(at_id: str | None) -> int:
        oid, kind = parse_osm_id(at_id)
        if oid > 0:
            return oid + (NODE_OFF if kind == "node"
                          else WAY_OFF if kind == "way"
                          else REL_OFF)
        # No @id — synthesize one
        next_auto_id[0] += 1
        return AUTO_OFF + next_auto_id[0]

    print("Processing features...")
    for feat in _iter_geojsonseq(input_path):
        scanned += 1
        props = feat.get("properties") or {}
        geom = feat.get("geometry") or {}
        place = props.get("place")
        name = (props.get("name") or "").strip()
        if not place or not name:
            continue
        oid = packed_id(normalize_feature_id(feat, props))

        # Compute representative lat/lon + bbox for either point or polygon.
        # Polygons are simplified at this layer's tolerance before WKB
        # encoding — without this, place=island for Greenland-class
        # landmasses balloons the bundle by 600+ MB.
        if geom.get("type") == "Point":
            lon, lat = geom["coordinates"]
            min_lat = max_lat = lat
            min_lon = max_lon = lon
            wkb = None
            geom_for_bbox = None
        elif geom.get("type") in ("Polygon", "MultiPolygon"):
            tolerance = (OSM_ISLAND_SIMPLIFY_TOLERANCE if place == "island"
                         else OSM_NEIGHBORHOOD_SIMPLIFY_TOLERANCE)
            simplified = simplify_geometry(geom, tolerance)
            if not _polygon_is_valid(simplified):
                # Aggressive simplification can collapse degenerate rings
                # — skip those rather than ship a malformed WKB blob.
                continue
            try:
                wkb = encode_wkb(simplified)
            except (ValueError, struct.error):
                continue
            min_lat, max_lat, min_lon, max_lon = geometry_bbox(simplified)
            lat = (min_lat + max_lat) / 2
            # The bbox is frame-space (may leave ±180 for a dateline
            # crosser) — normalize the representative lon back in range.
            lon = normalized_lon((min_lon + max_lon) / 2)
            geom_for_bbox = simplified
        else:
            # LineString or other — skip; not meaningful as a place
            continue

        # Route by place kind
        if place == "island":
            # The shared loop guard already skips unnamed features. Per-layer
            # unnamed counts must be tallied above that guard.
            if wkb is None:
                # Island nodes (no polygon) are too small to be useful
                continue
            # Skip sub-1km² unpopulated rocks — saves bundle size without
            # hiding anything a traveller would recognize. Islands with
            # explicit `population` always pass.
            bbox_area = (max_lat - min_lat) * (max_lon - min_lon)
            # Parse the tag, don't truthiness-test it.
            # OSM tag values are STRINGS, and `bool("0")` is True in Python —
            # so an islet tagged `population=0`, the standard convention for
            # "explicitly uninhabited", read as populated and sailed straight
            # past the sub-1km² rock filter it was meant to be caught by.
            #
            # Only an explicit ZERO demotes: OSM population tags are messy
            # ("1,200", "~50", "approx 300"), and a strict int() would read
            # every one of those as 0 and DROP an inhabited islet the old
            # truthiness test kept. Pull the digits out; a tag with no digits
            # at all is unparseable, not a claim of emptiness, so it keeps the
            # benefit of the doubt exactly as before.
            raw_population = str(props.get("population") or "").strip()
            digits = re.sub(r"[^0-9]", "", raw_population)
            if digits:
                has_population = int(digits) > 0
            else:
                has_population = bool(raw_population)
            if bbox_area < OSM_ISLAND_MIN_BBOX_DEG2 and not has_population:
                continue
            kept_is += 1
            # Dateline crossers: second lon segment gets
            # a twin row under OSM_DATELINE_OFF — rtree rows can't wrap.
            for i, (seg_min, seg_max) in enumerate(rtree_lon_segments(min_lon, max_lon)):
                row_id = oid if i == 0 else OSM_DATELINE_OFF + oid
                is_rows.append(
                    (row_id, name, props.get("name:en"), props.get("wikidata"), wkb)
                )
                is_rtree.append((row_id, min_lat, max_lat, seg_min, seg_max))
        elif place in ("neighbourhood", "suburb"):
            if not _is_notable_neighborhood(props):
                skipped_nb_unnotable += 1
                continue
            kept_nb += 1
            for i, (seg_min, seg_max) in enumerate(rtree_lon_segments(min_lon, max_lon)):
                row_id = oid if i == 0 else OSM_DATELINE_OFF + oid
                nb_rows.append(
                    (row_id, name, props.get("name:en"), place,
                     props.get("wikidata"), props.get("wikipedia"),
                     lat, lon, wkb)
                )
                nb_rtree.append((row_id, min_lat, max_lat, seg_min, seg_max))

        if scanned % 50_000 == 0:
            elapsed = time.time() - t0
            print(f"  {scanned:,} scanned, {kept_nb:,} neighborhoods kept, "
                  f"{kept_is:,} islands kept ({elapsed:.0f}s)")

    print(f"\nInserting...")
    conn.executemany(
        "INSERT INTO neighborhood (osm_id, name, name_en, place_kind, "
        "wikidata, wikipedia, lat, lon, wkb) VALUES (?,?,?,?,?,?,?,?,?)",
        nb_rows,
    )
    conn.executemany(
        "INSERT INTO neighborhood_rtree (osm_id, min_lat, max_lat, min_lon, max_lon) "
        "VALUES (?,?,?,?,?)",
        nb_rtree,
    )
    conn.executemany(
        "INSERT INTO island (osm_id, name, name_en, wikidata, wkb) "
        "VALUES (?,?,?,?,?)",
        is_rows,
    )
    conn.executemany(
        "INSERT INTO island_rtree (osm_id, min_lat, max_lat, min_lon, max_lon) "
        "VALUES (?,?,?,?,?)",
        is_rtree,
    )
    conn.commit()

    elapsed = time.time() - t0
    nb_wkb_bytes = conn.execute(
        "SELECT COALESCE(SUM(LENGTH(wkb)), 0) FROM neighborhood WHERE wkb IS NOT NULL"
    ).fetchone()[0]
    is_wkb_bytes = conn.execute(
        "SELECT COALESCE(SUM(LENGTH(wkb)), 0) FROM island"
    ).fetchone()[0]

    print(f"\n✓ Phase 1E complete in {elapsed:.0f}s")
    print(f"  Scanned features: {scanned:,}")
    print(f"  Islands kept:        {kept_is:,} ({is_wkb_bytes / 1024 / 1024:.1f} MB WKB)")
    print(f"  Neighborhoods kept:  {kept_nb:,} ({nb_wkb_bytes / 1024 / 1024:.1f} MB WKB)")
    print(f"  Neighborhoods dropped (not notable): {skipped_nb_unnotable:,}")


# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Build TravelLog's offline-geocoder SQLite database."
    )
    parser.add_argument(
        "--phase",
        choices=["1b", "1c", "1d", "1e", "1f", "all"],
        default="all",
        help="Build only a specific phase (default: all)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=OUTPUT_PATH,
        help="Output SQLite path",
    )
    parser.add_argument(
        "--wipe-supplement",
        action="store_true",
        help="Allow --phase=1e to DROP island tables that carry the Wikidata "
             "supplement. You must re-run "
             "supplement-islands.py afterwards.",
    )
    parser.add_argument(
        "--osm-input",
        type=Path,
        default=OSM_GEOJSONSEQ_PATH_DEFAULT,
        help="Path to the GeoJSON-sequence produced by `osmium export "
             "filtered.osm.pbf -f geojsonseq -o …`. Phase 1E only.",
    )
    parser.add_argument(
        "--ucdb-input",
        type=Path,
        default=UCDB_GPKG_PATH_DEFAULT,
        help="Path to GHS_UCDB_GLOBE_R2024A.gpkg (CC BY 4.0, ~285 MB, "
             "build-time only — not redistributed). Phase 1F only.",
    )
    args = parser.parse_args()

    print(f"Output: {args.output}")
    print(f"Cache:  {CACHE_DIR}")

    # A full rebuild publishes only its finalized, validated replacement.
    # Partial phases still update the requested database in place.
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with (tempfile.TemporaryDirectory(prefix=f".{args.output.name}.",
                                     dir=args.output.parent)
          if args.phase == "all" else nullcontext()) as staging_dir:
        build_path = (Path(staging_dir) / args.output.name
                      if staging_dir else args.output)
        conn = _open_db(build_path)
        try:
            if args.phase in ("1b", "all"):
                phase_geonames(conn)
                phase_admin1_codes(conn)
            if args.phase in ("1c", "all"):
                phase_admin1_polygons(conn)
            if args.phase in ("1d", "all"):
                phase_ghs_fua(conn)
            if args.phase in ("1e", "all"):
                phase_osm_places(conn, args.osm_input,
                                 wipe_supplement=args.wipe_supplement)
            if args.phase in ("1f", "all"):
                phase_ghs_ucdb(conn, args.ucdb_input)
            _upsert_build_metadata(conn, {"licence": GEOCODER_LICENCE})

            _finalize_db(conn)
            if staging_dir:
                journal_mode = conn.execute("PRAGMA journal_mode").fetchone()[0]
                if journal_mode.lower() != "delete":
                    raise RuntimeError(f"journal_mode is {journal_mode!r}, not 'delete'")
                integrity = conn.execute("PRAGMA integrity_check").fetchone()[0]
                if integrity != "ok":
                    raise RuntimeError(f"integrity_check: {integrity}")
        finally:
            conn.close()
        if staging_dir:
            os.replace(build_path, args.output)

    size_mb = args.output.stat().st_size / 1024 / 1024
    print(f"\n✓ Build complete: {args.output} ({size_mb:.1f} MB)")


if __name__ == "__main__":
    sys.exit(main())
