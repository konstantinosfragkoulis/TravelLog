#!/usr/bin/env python3
"""
Produce the BUNDLED `Geocoder.sqlite` from the full MASTER database by
removing data the app never reads, then prove the app's queries return
identical rows from both files. Stdlib only.

# Why

The master database carries build-time columns (`island.wikidata` for the
supplement's dedupe and missing-island checks, OSM `place_kind`, GeoNames
`feature_code`, source areas/populations) and indexes no resolver statement
uses. `GeocodeResolver` reads a fixed set of columns through nine prepared
statements; everything else is download size. The neighbourhood polygons are
the largest single item: the resolver ranks neighbourhoods by their
representative point and the R*Tree box, and never decodes `neighborhood.wkb`.

# Rules

- The master is opened read-only and is never modified. Keep it outside
  `TravelLog/` (that folder is synchronized into the app target, so any
  extra file there ships in the bundle): `.build-cache/geocoder/` is the
  conventional place.
- Build tooling (`build-geocoder-db.py`, `supplement-islands.py`, the
  runbook's verification queries) must run against the master, never against
  a trimmed file. A trimmed file carries `build_meta.ship_trim_applied` and
  this script refuses it as a master.
- Only the listed drops are applied; an unknown future column survives.
- The four small indexes (`fua_iso_idx`, `fua_pop_idx`, `admin1_iso_idx`,
  `urban_centre_country_idx`) stay. Dropping `fua_iso_idx` flips the planner
  of the nearby-FUA statement to an R*Tree-driven plan and changes its row
  ORDER (same rows); keeping it costs under 0.1 MB and keeps row order
  byte-identical.

# Verification

The statements are extracted from `GeocodeResolver.swift` at run time, so the
check follows the app. Each is executed against master and output for a fixed
seeded sample (jittered city coordinates, uniform global points, a dateline
band, by-name and admin-code lookups) and the full ordered row lists are
compared. By-name lookups run in both app shapes, without a country and
scoped to the sampled city's own country. A statement this script does not
know how to bind is an error, not a skip, and so is a rule whose parameter
count differs from the statement's highest `?N`; both are checked before any
file is written.

The trimmed file is built and verified under a temporary name next to
`--output` and moved into place only when every result matches and the
master is unchanged. Any failure, including an exception or an interrupt,
removes the temporary file and deletes an existing `--output`, so a chained
`cp` fails instead of shipping a stale or unverified file. The exit status is
non-zero.

# Usage

    python3 scripts/ship-trim-geocoder.py \\
        --master .build-cache/geocoder/Geocoder.master.sqlite \\
        --output .build-cache/geocoder/Geocoder.ship.sqlite
"""

from __future__ import annotations

import argparse
import hashlib
import math
import os
import random
import re
import shutil
import sqlite3
import sys
import tempfile
import unicodedata
from contextlib import closing
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RESOLVER = REPO / "TravelLog" / "Services" / "Geography" / "GeocodeResolver.swift"

DROP_INDEXES = [
    "city_iso_idx",
    "city_pop_idx",
    "neighborhood_name_idx",
]

DROP_COLUMNS = {
    "neighborhood": ["wkb", "wikidata", "wikipedia", "place_kind"],
    "city": ["feature_code"],
    "island": ["wikidata"],
    "admin1": ["iso_3166_2", "type_en"],
    "fua": ["fua_area_km2", "uc_area_km2", "fua_pop_2015"],
    "urban_centre": ["population"],
    "admin1_name": ["asciiname", "geoname_id"],
}

TRIM_MARKER = "ship_trim_applied"

# ODbL 1.0 section 4.2(b): the licence notice travels inside the database.
# build-geocoder-db.py stamps the same value into a fresh master.
LICENCE_KEY = "licence"
LICENCE = (
    "Contains information from OpenStreetMap © OpenStreetMap contributors, "
    "made available under the Open Database License 1.0 "
    "(https://opendatacommons.org/licenses/odbl/1-0/). Also contains GeoNames "
    "(CC BY 4.0), GHS-UCDB R2024A and GHS-FUA R2019A (CC BY 4.0, © European "
    "Union), Natural Earth (public domain) and Wikidata (CC0) data. The database "
    "as a whole is available under the ODbL 1.0. Attributions: "
    "THIRD_PARTY_NOTICES.md in https://github.com/konstantinosfragkoulis/TravelLog"
)

# How each resolver statement is bound, and how many parameters that rule
# binds. Longitude windows mirror the resolver's latitude-scaled half-widths;
# exact parity with Swift's segment splitting is not needed because both files
# receive the same bindings. A rule's count must equal the statement's highest
# `?N` (checked before trimming), so a parameter added in GeocodeResolver.swift
# stops the run until its binding is added here.
POINT, FUA_NEAR, CITY_WIN, NBHD_WIN, ADMIN_CODE, CITY_NAME, CITY_HOMONYMS, ADMIN1_NAMES = range(8)
COORDINATE_MODES = (POINT, FUA_NEAR, CITY_WIN, NBHD_WIN)
STATEMENT_BINDINGS = {
    "stmtAdmin1": (POINT, 2),
    "stmtFua": (POINT, 2),
    "stmtUrbanCentre": (POINT, 2),
    "stmtIsland": (POINT, 2),
    "stmtFuaNearby": (FUA_NEAR, 4),
    "stmtCity": (CITY_WIN, 3),
    "stmtNeighborhood": (NBHD_WIN, 3),
    "stmtAdmin1Name": (ADMIN_CODE, 2),
    "stmtCityByName": (CITY_NAME, 3),
    "stmtCityHomonyms": (CITY_HOMONYMS, 2),
    "stmtAdmin1ByName": (ADMIN1_NAMES, 0),
}


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def resolver_statements() -> dict[str, str]:
    source = RESOLVER.read_text(encoding="utf-8")
    found = dict(re.findall(
        r'prepare\(&(stmt\w+),\s*sql:\s*"""\n(.*?)"""', source, flags=re.S))
    if not found:
        sys.exit(f"ERROR: no prepared statements found in {RESOLVER}")
    unknown = sorted(set(found) - set(STATEMENT_BINDINGS))
    if unknown:
        sys.exit("ERROR: resolver statements without a binding rule here: "
                 + ", ".join(unknown)
                 + ". Add them to STATEMENT_BINDINGS before shipping a trim.")
    missing = sorted(set(STATEMENT_BINDINGS) - set(found))
    if missing:
        sys.exit("ERROR: expected resolver statements not found: "
                 + ", ".join(missing))
    return found


def parameter_count(name: str, sql: str) -> int:
    """Highest `?N` in `sql`. Bare `?` and named parameters are refused: their
    count does not follow from the text the way numbered ones do."""
    if re.search(r"\?(?!\d)", sql) or re.search(r"(?<![\w'\"])[:@$][A-Za-z_]", sql):
        sys.exit(f"ERROR: {name} uses a bare or named parameter; "
                 "the trim verifier binds numbered ?N parameters only")
    return max((int(n) for n in re.findall(r"\?(\d+)", sql)), default=0)


def fold(name_lc: str) -> str:
    """The resolver's second probe: diacritics removed, then lowercased."""
    decomposed = unicodedata.normalize("NFD", name_lc)
    stripped = "".join(c for c in decomposed if not unicodedata.combining(c))
    return unicodedata.normalize("NFC", stripped).lower()


def coordinate_params(mode: int, lat: float, lon: float, iso: str) -> tuple:
    scale = max(math.cos(math.radians(lat)), 0.01)
    if mode == POINT:
        return (lat, lon)
    if mode == FUA_NEAR:
        return (lat, lon - 0.5 / scale, lon + 0.5 / scale, iso)
    if mode == CITY_WIN:
        return (lat, lon - 0.05 / scale, lon + 0.05 / scale)
    if mode == NBHD_WIN:
        return (lat, lon - 0.01 / scale, lon + 0.01 / scale)
    raise ValueError(f"not a coordinate binding mode: {mode}")


def lookup_params(mode: int, iso: str, code: str, name_lc: str) -> list[tuple[str, tuple]]:
    """(label suffix, parameters) for every call shape the app uses."""
    if mode == ADMIN_CODE:
        return [("", (iso, code))]
    if mode == CITY_NAME:
        # resolveCityName leaves ?3 unbound (NULL) without a country and
        # binds it to the ISO code with one. Both shapes must match.
        probes = (name_lc, fold(name_lc))
        return [("", probes + (None,)), ("[iso]", probes + (iso,))]
    if mode == CITY_HOMONYMS:
        # cityHomonyms binds the plain and diacritic-folded name only.
        return [("", (name_lc, fold(name_lc)))]
    if mode == ADMIN1_NAMES:
        # isAdmin1Name reads every admin-1 name once, unbound, and folds them itself.
        return [("", ())]
    raise ValueError(f"not a lookup binding mode: {mode}")


def emitted_params(name: str) -> list[tuple[str, tuple]]:
    """(label, parameters) for every shape the rule for `name` emits."""
    mode, _ = STATEMENT_BINDINGS[name]
    if mode in COORDINATE_MODES:
        return [(name, coordinate_params(mode, 37.98, 23.72, "GR"))]
    return [(name + suffix, params)
            for suffix, params in lookup_params(mode, "GR", "35", "athens")]


def check_signatures(statements: dict[str, str]) -> None:
    """Every binding rule, declared and emitted, matches its SQL's parameters."""
    problems = []
    for name, sql in sorted(statements.items()):
        _, declared = STATEMENT_BINDINGS[name]
        takes = parameter_count(name, sql)
        if declared != takes:
            problems.append(f"{name}: the SQL takes {takes} parameters, "
                            f"STATEMENT_BINDINGS declares {declared}")
        for label, params in emitted_params(name):
            if len(params) != takes:
                problems.append(f"{label}: the rule binds {len(params)} parameters, "
                                f"the SQL takes {takes}")
    if problems:
        sys.exit("ERROR: trim verifier bindings are out of step with "
                 f"{RESOLVER.name}:\n  " + "\n  ".join(problems))


def validated_statements() -> dict[str, str]:
    statements = resolver_statements()
    check_signatures(statements)
    return statements


def open_read_only(path: Path) -> sqlite3.Connection:
    return sqlite3.connect(f"file:{path}?mode=ro", uri=True)


def table_columns(db: sqlite3.Connection, table: str) -> set[str]:
    return {row[1] for row in db.execute(f"PRAGMA table_info({table})")}


def stamp_licence(conn: sqlite3.Connection) -> None:
    conn.execute(
        "INSERT OR REPLACE INTO build_meta(key, value) VALUES (?, ?)",
        (LICENCE_KEY, LICENCE))


def trim(master: Path, output: Path, master_sha: str) -> None:
    shutil.copyfile(master, output)
    os.chmod(output, 0o644)
    db = sqlite3.connect(output)
    try:
        for index in DROP_INDEXES:
            db.execute(f"DROP INDEX IF EXISTS {index}")
        for table, columns in DROP_COLUMNS.items():
            present = table_columns(db, table)
            for column in columns:
                if column in present:
                    db.execute(f"ALTER TABLE {table} DROP COLUMN {column}")
        db.execute(
            "INSERT OR REPLACE INTO build_meta(key, value) VALUES (?, ?)",
            (TRIM_MARKER, f"master_sha256={master_sha}"))
        stamp_licence(db)
        db.commit()
        db.execute("PRAGMA journal_mode=DELETE")
        db.execute("VACUUM")
        result = db.execute("PRAGMA integrity_check").fetchone()[0]
        if result != "ok":
            raise RuntimeError(f"integrity_check: {result}")
    finally:
        db.close()


def sample_inputs(master: sqlite3.Connection, points: int):
    rng = random.Random(20260919)
    cities = master.execute(
        "SELECT lat, lon, iso_country, admin1_code, name_lc FROM city"
    ).fetchall()
    near_cities = rng.sample(cities, min(len(cities), points * 3 // 4))
    isos = sorted({row[2] for row in near_cities})
    coords = [(lat + rng.uniform(-0.03, 0.03), lon + rng.uniform(-0.03, 0.03), iso)
              for lat, lon, iso, _, _ in near_cities]
    for _ in range(points // 5):
        coords.append((rng.uniform(-85, 85), rng.uniform(-180, 180), rng.choice(isos)))
    for _ in range(points // 20):
        coords.append((rng.uniform(-60, 75),
                       rng.choice((-1, 1)) * rng.uniform(179.0, 180.0),
                       rng.choice(("FJ", "RU", "US", "NZ", "KI"))))
    lookups = [(iso, code, name) for _, _, iso, code, name in near_cities[: points // 2]]
    return coords, lookups


def verify(master: Path, output: Path, points: int,
           statements: dict[str, str] | None = None) -> int:
    if statements is None:
        statements = validated_statements()
    labels = [label for name in sorted(statements) for label, _ in emitted_params(name)]
    mismatches = {label: 0 for label in labels}
    nonempty = {label: 0 for label in labels}

    with closing(open_read_only(master)) as a, closing(open_read_only(output)) as b:
        coords, lookups = sample_inputs(a, points)

        def compare(label: str, name: str, params: tuple) -> None:
            rows_a = a.execute(statements[name], params).fetchall()
            rows_b = b.execute(statements[name], params).fetchall()
            if rows_a:
                nonempty[label] += 1
            if rows_a != rows_b:
                mismatches[label] += 1

        coordinate_rules = [(name, STATEMENT_BINDINGS[name][0]) for name in sorted(statements)
                            if STATEMENT_BINDINGS[name][0] in COORDINATE_MODES]
        lookup_rules = [(name, STATEMENT_BINDINGS[name][0]) for name in sorted(statements)
                        if STATEMENT_BINDINGS[name][0] not in COORDINATE_MODES]
        for lat, lon, iso in coords:
            for name, mode in coordinate_rules:
                compare(name, name, coordinate_params(mode, lat, lon, iso))
        for iso, code, name_lc in lookups:
            for name, mode in lookup_rules:
                for suffix, params in lookup_params(mode, iso, code, name_lc):
                    compare(name + suffix, name, params)

    print(f"  verified {len(coords)} coordinates, {len(lookups)} lookups")
    for label in labels:
        print(f"  {label:20s} nonempty={nonempty[label]:6d} mismatches={mismatches[label]}")
        if nonempty[label] == 0:
            print(f"  ERROR: {label} never returned a row; the sample proves nothing")
            mismatches[label] += 1
    return sum(mismatches.values())


def remove_candidate(candidate: Path) -> None:
    for suffix in ("", "-journal", "-wal", "-shm"):
        Path(f"{candidate}{suffix}").unlink(missing_ok=True)


def build(master: Path, output: Path, points: int) -> None:
    if sqlite3.sqlite_version_info < (3, 35, 0):
        sys.exit("ERROR: SQLite 3.35+ is required for ALTER TABLE DROP COLUMN")
    if not master.is_file():
        sys.exit(f"ERROR: master not found: {master}")
    with closing(open_read_only(master)) as probe:
        marked = probe.execute(
            "SELECT value FROM build_meta WHERE key = ?", (TRIM_MARKER,)).fetchone()
    if marked:
        sys.exit("ERROR: --master is already a trimmed file; use the full master")
    statements = validated_statements()

    master_sha = sha256_of(master)
    print(f"master  {master}\n        sha256 {master_sha}")
    fd, name = tempfile.mkstemp(prefix=f".{output.name}.", suffix=".partial",
                                dir=output.parent)
    os.close(fd)
    candidate = Path(name)
    try:
        trim(master, candidate, master_sha)
        failures = verify(master, candidate, points, statements)
        if sha256_of(master) != master_sha:
            sys.exit("ERROR: master changed during the run; output deleted")
        if failures:
            sys.exit(f"ERROR: {failures} differing results; output deleted")
        os.replace(candidate, output)
    finally:
        remove_candidate(candidate)

    before, after = master.stat().st_size, output.stat().st_size
    print(f"output  {output}\n        sha256 {sha256_of(output)}")
    print(f"size    {before / 1048576:.1f} MB -> {after / 1048576:.1f} MB "
          f"({(before - after) / 1048576:.1f} MB removed)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--master", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--points", type=int, default=40000,
                        help="verification sample size (default 40000)")
    args = parser.parse_args()

    master, output = args.master.resolve(), args.output.resolve()
    if output == master or (output.exists() and master.exists()
                            and os.path.samefile(master, output)):
        sys.exit("ERROR: --output must differ from --master")
    if output.is_dir():
        sys.exit(f"ERROR: --output is a directory: {output}")
    # --output is now known not to be the master, so a failed run may delete
    # it: an earlier candidate left there would otherwise be copied as if this
    # run had verified it.
    try:
        build(master, output, args.points)
    except BaseException:
        output.unlink(missing_ok=True)
        raise


if __name__ == "__main__":
    main()
