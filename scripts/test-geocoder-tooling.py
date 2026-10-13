#!/usr/bin/env python3
"""
Self-contained checks for the geocoder build tooling. Stdlib only:

    python3 scripts/test-geocoder-tooling.py

Covers:
- Full rebuilds publish atomically after validation; failed or interrupted
  builds preserve earlier output, and partial phases keep untouched layers.
- `decode_wkb_to_geojson` honors each MultiPolygon
  sub-geometry's OWN byte-order marker (synthetic mixed-endian fixture:
  a little-endian parent carrying one LE and one BE child).
- The write side stays uniform little-endian (`encode_wkb` round-trip) —
  the app's loadUnaligned parser reads only what this pipeline writes.
- The radius gate: the shipped GHS layers forward-project onto the
  source's 1 km Mollweide grid under MOLLWEIDE_R, and NOT under the
  authalic radius, which displaces metro boundaries.
- ship-trim's binding rules match the resolver SQL's parameters
  (checked before any file is written), the by-name lookup is compared with
  and without a country, and a failed or interrupted trim leaves no file at
  --output.
- supplement-islands refuses an --output that aliases the baseline
  and publishes its output atomically.
"""

import contextlib
import hashlib
import importlib.util
import json
import os
import sqlite3
import struct
import sys
import tempfile
from pathlib import Path

# The build script's filename has dashes — load it as a module by path.
_spec = importlib.util.spec_from_file_location(
    "build_geocoder_db", Path(__file__).parent / "build-geocoder-db.py"
)
bg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bg)


def _load_script(module_name: str, file_name: str):
    spec = importlib.util.spec_from_file_location(module_name, Path(__file__).parent / file_name)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


st = _load_script("ship_trim_geocoder", "ship-trim-geocoder.py")
si = _load_script("supplement_islands", "supplement-islands.py")


def _polygon_body(end: str, rings):
    parts = [struct.pack(end + "I", len(rings))]
    for ring in rings:
        parts.append(struct.pack(end + "I", len(ring)))
        for x, y in ring:
            parts.append(struct.pack(end + "dd", x, y))
    return b"".join(parts)


def test_mixed_endian_multipolygon():
    ring_a = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 0.0)]
    ring_b = [(10.0, 10.0), (11.0, 10.0), (11.0, 11.0), (10.0, 10.0)]

    # Little-endian parent header: MultiPolygon with 2 children.
    blob = struct.pack("<BII", 0x01, 6, 2)
    # Child 1: little-endian Polygon.
    blob += struct.pack("<BI", 0x01, 3) + _polygon_body("<", [ring_a])
    # Child 2: BIG-endian Polygon — the case the old decoder silently
    # misread by assuming the parent's order.
    blob += struct.pack(">BI", 0x00, 3) + _polygon_body(">", [ring_b])

    geom = bg.decode_wkb_to_geojson(blob)
    assert geom["type"] == "MultiPolygon", geom["type"]
    coords = geom["coordinates"]
    assert coords[0][0] == [list(p) for p in ring_a], coords[0][0]
    assert coords[1][0] == [list(p) for p in ring_b], coords[1][0]
    print("✓ mixed-endian MultiPolygon decodes correctly")


def test_encode_round_trip_uniform_le():
    geom = {
        "type": "MultiPolygon",
        "coordinates": [
            [[[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 0.0]]],
            [[[5.0, 5.0], [6.0, 5.0], [6.0, 6.0], [5.0, 5.0]]],
        ],
    }
    wkb = bg.encode_wkb(geom)
    # Writer contract: parent AND every child marker are little-endian.
    assert wkb[0] == 0x01
    n = struct.unpack_from("<I", wkb, 5)[0]
    assert n == 2
    offset = 9
    for _ in range(n):
        assert wkb[offset] == 0x01, "child not little-endian"
        # Skip child: order byte + type + nrings, then rings.
        nrings = struct.unpack_from("<I", wkb, offset + 5)[0]
        offset += 9
        for _ in range(nrings):
            npts = struct.unpack_from("<I", wkb, offset)[0]
            offset += 4 + npts * 16
    decoded = bg.decode_wkb_to_geojson(wkb)
    assert decoded == geom, decoded
    print("✓ encode_wkb emits uniform little-endian and round-trips")


def test_antimeridian_bbox_and_segments():
    """
    a Fiji-like polygon crossing ±180° must NOT get a
    globe-spanning bbox/R*Tree entry. INVARIANT: for any query longitude,
    the feature is probed iff its true wrapped extent contains it.
    """
    # Synthetic Fiji: a MultiPolygon with parts on both sides of ±180.
    fiji = {
        "type": "MultiPolygon",
        "coordinates": [
            [[[179.2, -17.0], [180.0, -17.0], [180.0, -18.0],
              [179.2, -18.0], [179.2, -17.0]]],
            [[[-179.8, -16.5], [-179.1, -16.5], [-179.1, -17.5],
              [-179.8, -17.5], [-179.8, -16.5]]],
        ],
    }
    min_lat, max_lat, min_lon, max_lon = bg.geometry_bbox(fiji)
    # First-vertex frame (anchor 179.2): the west-of-dateline part unwraps
    # to 180.2..180.9 — a ~1.7°-wide box, not 360°.
    assert abs(min_lon - 179.2) < 1e-9, min_lon
    assert abs(max_lon - 180.9) < 1e-9, max_lon
    assert max_lon - min_lon < 2.0, "bbox spans the globe"

    segments = bg.rtree_lon_segments(min_lon, max_lon)
    assert len(segments) == 2, segments
    for seg_min, seg_max in segments:
        assert -180.0 <= seg_min <= seg_max <= 180.0, segments
        assert seg_max - seg_min < 360.0, "segment spans the globe"

    def probed(lon):
        return any(seg_min <= lon <= seg_max for seg_min, seg_max in segments)

    assert probed(179.5), "east-of-dateline interior must be probed"
    assert probed(-179.5), "west-of-dateline interior must be probed"
    assert not probed(23.7), "a Greek-longitude probe must never fetch Fiji"
    assert not probed(0.0) and not probed(-90.0) and not probed(90.0)

    # Westward unwrap (anchor just west of the dateline): frame-space
    # min_lon < -180 exercises the other split branch.
    chukotka_ring = {
        "type": "Polygon",
        "coordinates": [
            [[-179.5, 65.0], [178.5, 65.0], [178.5, 67.0],
             [-179.5, 67.0], [-179.5, 65.0]]
        ],
    }
    _, _, w_min, w_max = bg.geometry_bbox(chukotka_ring)
    assert w_min < -180.0 < w_max <= 180.0, (w_min, w_max)
    w_segments = bg.rtree_lon_segments(w_min, w_max)
    assert len(w_segments) == 2, w_segments
    w_probed = lambda lon: any(a <= lon <= b for a, b in w_segments)
    assert w_probed(179.0) and w_probed(-179.9) and not w_probed(23.7)

    # Non-crossing geometries stay BIT-identical to the old behavior
    # (single segment, raw min/max) — the entire existing dataset.
    greece = {
        "type": "Polygon",
        "coordinates": [
            [[19.3, 39.6], [26.6, 39.6], [26.6, 35.0], [19.3, 35.0], [19.3, 39.6]]
        ],
    }
    _, _, g_min, g_max = bg.geometry_bbox(greece)
    assert g_min == 19.3 and g_max == 26.6, (g_min, g_max)
    assert bg.rtree_lon_segments(g_min, g_max) == [(19.3, 26.6)]
    print("✓ antimeridian polygons get tight split R*Tree segments")


def test_antimeridian_rtree_end_to_end():
    """
    The invariant against a REAL SQLite R*Tree: split rows are fetched by
    probes inside the wrapped extent and never by far-away longitudes.
    """
    import sqlite3

    fiji = {
        "type": "MultiPolygon",
        "coordinates": [
            [[[179.2, -17.0], [180.0, -17.0], [180.0, -18.0],
              [179.2, -18.0], [179.2, -17.0]]],
            [[[-179.8, -16.5], [-179.1, -16.5], [-179.1, -17.5],
              [-179.8, -17.5], [-179.8, -16.5]]],
        ],
    }
    min_lat, max_lat, min_lon, max_lon = bg.geometry_bbox(fiji)

    conn = sqlite3.connect(":memory:")
    conn.execute(
        "CREATE VIRTUAL TABLE t_rtree USING rtree"
        "(id, min_lat, max_lat, min_lon, max_lon)"
    )
    # The build scripts' twin-row shape: distinct rowids per segment.
    for i, (seg_min, seg_max) in enumerate(bg.rtree_lon_segments(min_lon, max_lon)):
        conn.execute(
            "INSERT INTO t_rtree VALUES (?,?,?,?,?)",
            (1 if i == 0 else bg.OSM_DATELINE_OFF + 1,
             min_lat, max_lat, seg_min, seg_max),
        )

    def hits(lat, lon):
        return conn.execute(
            "SELECT COUNT(*) FROM t_rtree "
            "WHERE min_lat <= ?1 AND max_lat >= ?1 "
            "AND min_lon <= ?2 AND max_lon >= ?2",
            (lat, lon),
        ).fetchone()[0]

    assert hits(-17.5, 179.5) == 1, "east side must hit exactly one row"
    assert hits(-17.0, -179.5) == 1, "west side must hit exactly one row"
    assert hits(37.9, 23.7) == 0, "Athens must never fetch Fiji"
    assert hits(-17.5, 0.0) == 0
    conn.close()
    print("✓ split R*Tree rows satisfy the probe-iff-overlap invariant")


def _mollweide_forward(lon_deg: float, lat_deg: float, radius: float):
    """Forward Mollweide (Snyder p. 251), Newton for theta. Test-only twin of
    the build script's inverse — an independent formula, so agreement between
    the two is evidence, not tautology."""
    import math
    phi = math.radians(lat_deg)
    lam = math.radians(lon_deg)
    theta = phi
    for _ in range(50):
        f = 2 * theta + math.sin(2 * theta) - math.pi * math.sin(phi)
        d = 2 + 2 * math.cos(2 * theta)
        if abs(d) < 1e-12:
            break
        theta -= f / d
        if abs(f) < 1e-14:
            break
    x = 2 * math.sqrt(2) * radius * lam * math.cos(theta) / math.pi
    y = math.sqrt(2) * radius * math.sin(theta)
    return x, y


def _grid_fraction(db_path: Path, table: str, radius: float, sample: int = 300) -> float:
    """Fraction of sampled polygon vertices that forward-project to within
    1 m of the source's 1 km Mollweide grid under `radius`."""
    import random
    import sqlite3
    conn = sqlite3.connect(db_path)
    rows = conn.execute(f"SELECT wkb FROM {table}").fetchall()
    conn.close()
    random.seed(20260903)
    total = on_grid = 0
    for (wkb,) in random.sample(rows, min(sample, len(rows))):
        geom = bg.decode_wkb_to_geojson(wkb)
        polys = geom["coordinates"] if geom["type"] == "MultiPolygon" else [geom["coordinates"]]
        for poly in polys:
            for ring in poly:
                for lon, lat in ring[:50]:
                    x, y = _mollweide_forward(lon, lat, radius)
                    residual = max(abs(x - round(x / 1000.0) * 1000.0),
                                   abs(y - round(y / 1000.0) * 1000.0))
                    total += 1
                    on_grid += residual < 1.0
    return on_grid / total if total else 0.0


def test_shipped_projected_layers_sit_on_the_source_grid():
    """The radius gate. GHS-UCDB and GHS-FUA are 1 km grid products in
    World Mollweide, so every shipped vertex must forward-project back onto
    exact 1000 m multiples under MOLLWEIDE_R. The authalic radius the script
    used until 2026-08-03 displaced every boundary by ~5 km (Athens: 5.02 km
    north, 3.13 km east) and puts NO vertex on the grid, which is what this
    check turns into a hard failure. FUA carries ~2.6 % deliberate off-grid
    vertices (great-circle subdivision points), hence its lower bar."""
    assert bg.MOLLWEIDE_R == 6378137.0, "ESRI:54009 sphere is the WGS84 semi-major axis"
    db_path = Path(__file__).resolve().parents[1] / "TravelLog" / "Resources" / "Geocoder.sqlite"
    if not db_path.exists():
        print("⚠ shipped Geocoder.sqlite not present — grid gate skipped")
        return
    uc_ok = _grid_fraction(db_path, "urban_centre", bg.MOLLWEIDE_R)
    fua_ok = _grid_fraction(db_path, "fua", bg.MOLLWEIDE_R)
    uc_bad = _grid_fraction(db_path, "urban_centre", 6371007.181)
    assert uc_ok >= 0.99, f"urban_centre only {uc_ok:.1%} on the 1 km grid — wrong radius or transform"
    assert fua_ok >= 0.95, f"fua only {fua_ok:.1%} on the 1 km grid — wrong radius or transform"
    assert uc_bad < 0.01, f"the authalic radius must NOT fit ({uc_bad:.1%}); the gate would be vacuous"
    print(f"✓ shipped urban_centre {uc_ok:.1%} / fua {fua_ok:.1%} of vertices on the 1 km Mollweide grid "
          f"under R={bg.MOLLWEIDE_R:.0f}; authalic radius fits {uc_bad:.1%}")


# ---------------------------------------------------------------------------
# Shared helpers for the script-lifecycle checks


@contextlib.contextmanager
def _patched(owner, name, value):
    original = getattr(owner, name)
    setattr(owner, name, value)
    try:
        yield
    finally:
        setattr(owner, name, original)


@contextlib.contextmanager
def _argv(*args):
    with _patched(sys, "argv", ["script", *map(str, args)]):
        yield


def _sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _names(directory: Path) -> set:
    return {p.name for p in directory.iterdir()}


def _expect_exit(fn):
    try:
        fn()
    except SystemExit as exit:
        assert exit.code not in (None, 0), f"exited with {exit.code!r}"
        return
    raise AssertionError("expected a non-zero SystemExit")


def _expect_raise(fn, kind):
    try:
        fn()
    except kind:
        return
    raise AssertionError(f"expected {kind.__name__}")


def _write_db(path: Path, script: str, rows=()):
    conn = sqlite3.connect(path)
    conn.executescript(script)
    for sql, params in rows:
        conn.execute(sql, params)
    conn.commit()
    conn.close()


# ---------------------------------------------------------------------------
# ship-trim-geocoder.py


def test_trim_binding_rules_match_resolver_sql():
    """Every rule's declared and emitted parameter count equals the highest
    ?N of the statement GeocodeResolver.swift prepares. The two-parameter
    stmtCityByName rule that met a three-parameter query fails here."""
    statements = st.resolver_statements()
    st.check_signatures(statements)
    for name, sql in statements.items():
        _, declared = st.STATEMENT_BINDINGS[name]
        assert st.parameter_count(name, sql) == declared, name
        for label, params in st.emitted_params(name):
            assert len(params) == declared, label
    shapes = dict(st.emitted_params("stmtCityByName"))
    assert shapes["stmtCityByName"][2] is None, "the no-country shape leaves ?3 NULL"
    assert shapes["stmtCityByName[iso]"][2] == "GR", "the scoped shape binds the ISO"

    drifted = dict(statements)
    drifted["stmtCityByName"] = statements["stmtCityByName"].replace(
        "LIMIT 1", "AND ?4 IS NULL LIMIT 1")
    _expect_exit(lambda: st.check_signatures(drifted))
    _expect_exit(lambda: st.parameter_count("bare", "SELECT 1 WHERE a = ?"))
    _expect_exit(lambda: st.parameter_count("named", "SELECT 1 WHERE a = :name"))
    print("✓ trim binding rules match the resolver SQL; drift is refused")


def test_trim_city_by_name_shapes_run_the_real_query():
    """The extracted stmtCityByName runs with the bindings the verifier
    emits: homonyms in two countries, no country, the matching country, a
    foreign country, and a plain name whose folded probe differs."""
    sql = st.resolver_statements()["stmtCityByName"]
    db = sqlite3.connect(":memory:")
    db.executescript("""
        CREATE TABLE city (geoname_id INTEGER PRIMARY KEY, name TEXT, name_lc TEXT,
                           iso_country TEXT, lat REAL, lon REAL, population INTEGER);
        INSERT INTO city VALUES (1, 'Paris', 'paris', 'FR', 48.82042, 2.31067, 2100000);
        INSERT INTO city VALUES (2, 'Paris', 'paris', 'US', 33.66, -95.55, 25000);
        INSERT INTO city VALUES (3, 'Bellinzona', 'bellinzona', 'CH', 46.19611, 9.00725, 400000);
    """)

    def run(params):
        row = db.execute(sql, params).fetchone()
        return row[1] if row else None

    shapes = dict(st.lookup_params(st.CITY_NAME, "US", "TX", "paris"))
    assert run(shapes[""]) == "FR", "no country: most populous homonym"
    assert run(shapes["[iso]"]) == "US", "scoped: the city's own country"
    foreign = shapes["[iso]"][:2] + ("DE",)
    assert run(foreign) is None, "a foreign country must not fall back to another"
    folded = dict(st.lookup_params(st.CITY_NAME, "CH", "TI", "bellinzóna"))
    assert folded[""][:2] == ("bellinzóna", "bellinzona"), folded
    assert run(folded[""]) == "CH" and run(folded["[iso]"]) == "CH"
    db.close()
    print("✓ stmtCityByName is compared with and without a country")


def _tiny_master(directory: Path) -> Path:
    master = directory / "master.sqlite"
    _write_db(master, "CREATE TABLE build_meta (key TEXT PRIMARY KEY, value TEXT);",
              [("INSERT INTO build_meta VALUES (?, ?)", ("built", "test"))])
    os.chmod(master, 0o444)
    return master


def test_trim_failed_run_leaves_no_output():
    with tempfile.TemporaryDirectory() as tmp:
        directory = Path(tmp)
        master = _tiny_master(directory)
        master_sha = _sha(master)
        output = directory / "ship.sqlite"

        def run():
            with _argv("--master", master, "--output", output, "--points", 10):
                st.main()

        def stale():
            output.write_bytes(b"an earlier candidate")

        def boom(*_args, **_kwargs):
            raise RuntimeError("injected")

        def interrupt(*_args, **_kwargs):
            raise KeyboardInterrupt

        verified = (st, "verify", lambda *a, **k: 0)
        failures = [
            ("verify raises", [(st, "verify", boom)], RuntimeError),
            ("verify interrupted", [(st, "verify", interrupt)], KeyboardInterrupt),
            ("verify mismatches", [(st, "verify", lambda *a, **k: 1)], SystemExit),
            ("trim raises", [(st, "trim", boom)], RuntimeError),
            ("replace fails", [verified, (st.os, "replace", boom)], RuntimeError),
        ]
        for label, patches, kind in failures:
            stale()
            with contextlib.ExitStack() as stack:
                for owner, name, value in patches:
                    stack.enter_context(_patched(owner, name, value))
                _expect_raise(run, kind)
            assert not output.exists(), f"{label}: --output survived a failed run"
            assert _names(directory) == {"master.sqlite"}, f"{label}: {_names(directory)}"
            assert _sha(master) == master_sha, label

        # The master changing under the run is caught after verification.
        stale()
        hashes = iter([master_sha, "changed"])
        with _patched(st, "verify", lambda *a, **k: 0), \
                _patched(st, "sha256_of", lambda _path: next(hashes)):
            _expect_raise(run, SystemExit)
        assert _names(directory) == {"master.sqlite"}, "master drift"

        # SQL drift is refused before a candidate exists.
        swift = directory / "GeocodeResolver.swift"
        swift.write_text(st.RESOLVER.read_text(encoding="utf-8").replace(
            "WHERE name_lc IN (?1, ?2)", "WHERE name_lc IN (?1, ?2, ?4)"))
        stale()
        created = []
        real_mkstemp = st.tempfile.mkstemp
        with _patched(st, "RESOLVER", swift), \
                _patched(st.tempfile, "mkstemp",
                         lambda *a, **k: created.append(1) or real_mkstemp(*a, **k)):
            _expect_raise(run, SystemExit)
        assert not created, "a candidate was created before the signature check"
        assert _names(directory) == {"master.sqlite", "GeocodeResolver.swift"}
        assert _sha(master) == master_sha
    print("✓ a failed or interrupted trim leaves no --output and no temp files")


def test_trim_success_replaces_output_atomically():
    with tempfile.TemporaryDirectory() as tmp:
        directory = Path(tmp)
        master = _tiny_master(directory)
        master_sha = _sha(master)
        output = directory / "ship.sqlite"
        output.write_bytes(b"an earlier candidate")
        with _patched(st, "verify", lambda *a, **k: 0), \
                _argv("--master", master, "--output", output, "--points", 10):
            st.main()
        assert _names(directory) == {"master.sqlite", "ship.sqlite"}
        conn = sqlite3.connect(output)
        marker = conn.execute(
            "SELECT value FROM build_meta WHERE key = ?", (st.TRIM_MARKER,)).fetchone()
        licence = conn.execute(
            "SELECT value FROM build_meta WHERE key = ?", (st.LICENCE_KEY,)).fetchone()
        conn.close()
        assert marker == (f"master_sha256={master_sha}",), marker
        assert licence == (st.LICENCE,), licence
        assert "https://opendatacommons.org/licenses/odbl/1-0/" in st.LICENCE
        assert _sha(master) == master_sha
    print("✓ a verified trim replaces --output and leaves the master untouched")


def test_trim_refuses_master_aliases():
    with tempfile.TemporaryDirectory() as tmp:
        directory = Path(tmp)
        master = _tiny_master(directory)
        master_sha = _sha(master)
        (directory / "hard.sqlite").hardlink_to(master)
        (directory / "soft.sqlite").symlink_to(master)
        for alias in (master, directory / "." / "master.sqlite",
                      directory / "hard.sqlite", directory / "soft.sqlite"):
            with _argv("--master", master, "--output", alias):
                _expect_exit(st.main)
            assert master.exists() and _sha(master) == master_sha, alias
    print("✓ ship-trim refuses an --output that aliases the master")


# ---------------------------------------------------------------------------
# supplement-islands.py

_ISLAND_SCHEMA = """
    CREATE TABLE island (osm_id INTEGER PRIMARY KEY, name TEXT NOT NULL,
                         name_en TEXT, wikidata TEXT, wkb BLOB NOT NULL);
    CREATE VIRTUAL TABLE island_rtree USING rtree(osm_id, min_lat, max_lat, min_lon, max_lon);
"""


def _supplement_fixture(directory: Path):
    baseline = directory / "base.sqlite"
    _write_db(baseline, _ISLAND_SCHEMA)
    candidates = directory / "relations.geojson"
    square = [[25.1, 37.0], [25.3, 37.0], [25.3, 37.2], [25.1, 37.2], [25.1, 37.0]]
    candidates.write_text(json.dumps({"type": "FeatureCollection", "features": [{
        "type": "Feature",
        "properties": {"@type": "relation", "@id": 452381, "name": "Samos", "wikidata": "Q156882"},
        "geometry": {"type": "Polygon", "coordinates": [square]},
    }]}))
    relations = directory / "rel.csv"
    relations.write_text("osm_rel\n452381\n")
    ways = directory / "ways.csv"
    ways.write_text("osm_way\n")
    return baseline, candidates, relations, ways


def _run_supplement(baseline, output, candidates, relations, ways):
    with _argv("--baseline", baseline, "--output", output, "--candidates", candidates,
               "--wikidata-relations", relations, "--wikidata-ways", ways, "--variant", "B"):
        si.main()


def test_supplement_refuses_baseline_aliases():
    with tempfile.TemporaryDirectory() as tmp:
        directory = Path(tmp)
        baseline, candidates, relations, ways = _supplement_fixture(directory)
        baseline_sha = _sha(baseline)
        (directory / "hard.sqlite").hardlink_to(baseline)
        (directory / "soft.sqlite").symlink_to(baseline)
        (directory / "linked").symlink_to(directory, target_is_directory=True)
        aliases = [baseline, directory / "." / "base.sqlite", directory / "hard.sqlite",
                   directory / "soft.sqlite", directory / "linked" / "base.sqlite"]
        upper = directory / "BASE.sqlite"
        if upper.exists():  # case-insensitive volume
            aliases.append(upper)
        before = _names(directory)
        for alias in aliases:
            _expect_exit(lambda: _run_supplement(baseline, alias, candidates, relations, ways))
            assert baseline.exists() and _sha(baseline) == baseline_sha, alias
            assert _names(directory) == before, alias
    print("✓ supplement-islands refuses an --output that aliases the baseline")


def test_supplement_success_publishes_complete_output():
    with tempfile.TemporaryDirectory() as tmp:
        directory = Path(tmp)
        baseline, candidates, relations, ways = _supplement_fixture(directory)
        baseline_sha = _sha(baseline)
        output = directory / "base.F.sqlite"
        output.write_bytes(b"an earlier output")
        before = _names(directory)
        _run_supplement(baseline, output, candidates, relations, ways)
        assert _names(directory) == before, _names(directory)
        assert _sha(baseline) == baseline_sha
        conn = sqlite3.connect(output)
        assert conn.execute("PRAGMA journal_mode").fetchone()[0] == "delete"
        assert conn.execute("SELECT name FROM island").fetchall() == [("Samos",)]
        rtree = conn.execute("SELECT osm_id FROM island_rtree").fetchall()
        assert rtree == [(si.REL_OFF + 452381,)], rtree
        marker = conn.execute(
            "SELECT value FROM build_meta WHERE key = 'island_supplement_applied'").fetchone()
        assert marker == ("variant=B, rows=1",), marker
        conn.close()

        trimmed = directory / "trimmed.sqlite"
        _write_db(trimmed, _ISLAND_SCHEMA + "CREATE TABLE build_meta (key TEXT PRIMARY KEY, value TEXT);",
                  [("INSERT INTO build_meta VALUES (?, ?)", ("ship_trim_applied", "x"))])
        _expect_exit(lambda: _run_supplement(trimmed, directory / "t.F.sqlite",
                                             candidates, relations, ways))
        assert not (directory / "t.F.sqlite").exists()
    print("✓ supplement-islands publishes a finalized output and refuses a trimmed baseline")


def test_supplement_failure_keeps_inputs_and_earlier_output():
    with tempfile.TemporaryDirectory() as tmp:
        directory = Path(tmp)
        baseline, candidates, relations, ways = _supplement_fixture(directory)
        baseline_sha = _sha(baseline)
        output = directory / "base.F.sqlite"
        output.write_bytes(b"an earlier output")
        earlier_sha = _sha(output)
        before = _names(directory)
        real_finalize = si._finalize

        def boom(*_args, **_kwargs):
            raise RuntimeError("injected")

        def interrupt(*_args, **_kwargs):
            raise KeyboardInterrupt

        def after_vacuum(conn):
            real_finalize(conn)
            raise RuntimeError("injected after VACUUM")

        failures = [
            ("after inserts", si, "_finalize", boom, RuntimeError),
            ("interrupted after inserts", si, "_finalize", interrupt, KeyboardInterrupt),
            ("after finalization", si, "_finalize", after_vacuum, RuntimeError),
            ("journal mode not delete", si, "_finalize", lambda conn: "wal", RuntimeError),
            ("replace fails", si.os, "replace", boom, RuntimeError),
        ]
        for label, owner, name, value, kind in failures:
            with _patched(owner, name, value):
                _expect_raise(lambda: _run_supplement(baseline, output, candidates, relations, ways),
                              kind)
            assert _names(directory) == before, f"{label}: {_names(directory)}"
            assert _sha(baseline) == baseline_sha, label
            assert _sha(output) == earlier_sha, label

        candidates.write_text("{ not json")
        _expect_raise(lambda: _run_supplement(baseline, output, candidates, relations, ways),
                      json.JSONDecodeError)
        assert _names(directory) == before and _sha(output) == earlier_sha
    print("✓ a failed supplement keeps the baseline and an earlier output, and leaves no temp files")


@contextlib.contextmanager
def _synthetic_build_phases():
    """Exercise publication through the real CLI without downloads."""
    def layer(conn, *_args, **_kwargs):
        conn.executescript("CREATE TABLE replacement (value TEXT);"
                           "INSERT INTO replacement VALUES ('new');")

    with contextlib.ExitStack() as stack:
        for name in ("phase_geonames", "phase_admin1_codes", "phase_admin1_polygons",
                     "phase_ghs_fua", "phase_osm_places", "phase_ghs_ucdb"):
            stack.enter_context(_patched(bg, name, layer if name == "phase_geonames"
                                         else lambda *_args, **_kwargs: None))
        yield


def _run_build(output, phase="all"):
    with _argv("--phase", phase, "--output", output):
        bg.main()


def test_full_build_success_replaces_output_atomically():
    with tempfile.TemporaryDirectory() as tmp, _synthetic_build_phases():
        directory = Path(tmp)
        output = directory / "out.sqlite"
        _write_db(output, "CREATE TABLE original (value TEXT);")
        before = _names(directory)
        _run_build(output)
        assert _names(directory) == before
        with sqlite3.connect(output) as conn:
            assert conn.execute("SELECT * FROM replacement").fetchall() == [("new",)]
            assert not conn.execute("SELECT name FROM sqlite_master WHERE name='original'").fetchall()
            assert conn.execute("SELECT value FROM build_meta WHERE key = 'licence'"
                                ).fetchall() == [(st.LICENCE,)], "master carries the ODbL notice"
            assert conn.execute("PRAGMA journal_mode").fetchone()[0] == "delete"
            assert conn.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    print("✓ full build publishes only its finalized replacement")


def test_full_build_failure_keeps_earlier_output():
    with tempfile.TemporaryDirectory() as tmp, _synthetic_build_phases():
        directory = Path(tmp)
        output = directory / "out.sqlite"
        _write_db(output, "CREATE TABLE original (value TEXT); INSERT INTO original VALUES ('old');")
        earlier_sha, before = _sha(output), _names(directory)
        real_layer, real_finalize, real_open = bg.phase_geonames, bg._finalize_db, bg._open_db

        def after_inserts(conn):
            real_layer(conn)
            raise RuntimeError("injected after inserts")

        def interrupt(conn):
            real_layer(conn)
            raise KeyboardInterrupt

        def after_finalize(conn):
            real_finalize(conn)
            raise RuntimeError("injected after finalization")

        def boom(*_args, **_kwargs):
            raise RuntimeError("injected publication failure")

        class InvalidIntegrityConnection:
            def __init__(self, conn):
                self.conn = conn

            def execute(self, sql, *args):
                if sql == "PRAGMA integrity_check":
                    return self.conn.execute("SELECT 'injected corruption'")
                return self.conn.execute(sql, *args)

            def __getattr__(self, name):
                return getattr(self.conn, name)

        failures = [
            ("after inserts", bg, "phase_geonames", after_inserts, RuntimeError),
            ("interrupted", bg, "phase_geonames", interrupt, KeyboardInterrupt),
            ("after finalization", bg, "_finalize_db", after_finalize, RuntimeError),
            ("journal mode not delete", bg, "_finalize_db", lambda conn: conn.commit(), RuntimeError),
            ("integrity check", bg, "_open_db", lambda path: InvalidIntegrityConnection(real_open(path)), RuntimeError),
            ("replace fails", bg.os, "replace", boom, RuntimeError),
        ]
        for label, owner, name, value, kind in failures:
            with _patched(owner, name, value):
                _expect_raise(lambda: _run_build(output), kind)
            assert _sha(output) == earlier_sha, label
            assert _names(directory) == before, f"{label}: {_names(directory)}"
    print("✓ failed or interrupted full builds preserve earlier bytes and leave no staging files")


def test_partial_build_keeps_other_layers():
    with tempfile.TemporaryDirectory() as tmp, _synthetic_build_phases():
        directory = Path(tmp)
        output = directory / "out.sqlite"
        _write_db(output, "CREATE TABLE original (value TEXT); INSERT INTO original VALUES ('old');")
        before = _names(directory)
        _run_build(output, phase="1b")
        assert _names(directory) == before
        with sqlite3.connect(output) as conn:
            assert conn.execute("SELECT * FROM original").fetchall() == [("old",)]
            assert conn.execute("SELECT * FROM replacement").fetchall() == [("new",)]
    print("✓ partial builds keep untouched layers in the requested database")


if __name__ == "__main__":
    test_full_build_success_replaces_output_atomically()
    test_full_build_failure_keeps_earlier_output()
    test_partial_build_keeps_other_layers()
    test_mixed_endian_multipolygon()
    test_encode_round_trip_uniform_le()
    test_antimeridian_bbox_and_segments()
    test_antimeridian_rtree_end_to_end()
    test_shipped_projected_layers_sit_on_the_source_grid()
    test_trim_binding_rules_match_resolver_sql()
    test_trim_city_by_name_shapes_run_the_real_query()
    test_trim_failed_run_leaves_no_output()
    test_trim_success_replaces_output_atomically()
    test_trim_refuses_master_aliases()
    test_supplement_refuses_baseline_aliases()
    test_supplement_success_publishes_complete_output()
    test_supplement_failure_keeps_inputs_and_earlier_output()
    print("All geocoder-tooling checks passed.")
    sys.exit(0)
