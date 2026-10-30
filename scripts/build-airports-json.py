#!/usr/bin/env python3
"""
build-airports-json.py — regenerate the bundled `TravelLog/Resources/airports.json`
from the OurAirports dataset (public domain, https://ourairports.com/data/).

The bundled slice keeps `large_airport` and `medium_airport` rows, plus
`small_airport` rows with scheduled service.
The July-2026 Collections feature ("Airports visited" list + flight log)
enriched each record with display fields:

    code : IATA when assigned, else `ident` (usually ICAO) — matches the
           original slice's fallback rule, so `Stay.isAirport` proximity
           semantics are unchanged.
    lat  : latitude_deg
    lon  : longitude_deg
    name : airport display name ("Amsterdam Airport Schiphol")
    city : municipality, omitted when empty
    iso  : ISO 3166-1 alpha-2 country code (drives flag rendering)
    svc  : scheduled_service flag. Military/GA fields (Tanagra LGTG et al.)
           carry `false`; the Collections airport list requires `svc` OR
           flown-through evidence, so highway drive-bys past airbases never
           become "visits". Detection (`isNearAirport`) is unaffected.
    size : the airport's tier, from `type` and the longest open runway
           (OurAirports `runways.csv`, also public domain):
             "L" major    — `large_airport` with a runway of at least
                            MAJOR_MIN_RUNWAY_M (or no runway data);
             "M" regional — `medium_airport`, or a `large_airport` whose
                            longest runway is shorter (narrow-body only:
                            OurAirports calls many regional fields large);
             "S" small    — `small_airport`.
           Omitted when unknown (a row since closed). `AirportRecord.tier`
           reads a missing or unknown value as `.unknown`. It ranks the
           airport a place outside every airport ring likely flew from
           (`AccessAirport`); detection is unaffected.
    ring : the `Stay.isAirport` radius in metres, from the open runways'
           ends (`runways.csv`): the farthest end from `lat`/`lon` (or half
           the longest runway, when no end has coordinates) plus
           RING_MARGIN_M for the terminal, apron and GPS noise, kept
           within RING_MIN_M..RING_MAX_M. Omitted at RING_MAX_M and when
           no runway is known; `AirportRecord.ringMeters` reads a missing
           value as RING_MAX_M, the ring every airport had before.
    isl  : the island the airport stands on: the largest OSM island
           polygon under ISLAND_AREA_CAP_KM2 in the bundled Geocoder.sqlite
           that contains `lat`/`lon` (when no island polygon does, the one
           containing the nearest GeoNames town within about 5 km, as
           `GeocodeResolver` places a stay: an airfield on a spit or
           reclaimed shore the simplified outline leaves offshore), named
           exactly as `GeocodeResolver` names `Stay.islandName` (`name_en`,
           else `name`, in Latin ASCII).
           Omitted when no such island holds the point, or its name is
           empty. For display.
    islid: the same island's OSM id (`island.osm_id`), set even when its
           name is empty. `AirportGroundTable` finds a flight end's island
           by the same rule, and `AccessAirport` keeps an end whose island
           has a scheduled airport within reach on that island's airports
           and its commuting area's.

`svc` stays as OurAirports has it, even for a business-aviation field it
lists as scheduled: flipping it would drop the flight ends and stops users
already set there.

`AirportRecord` in `AirportDetector.swift` decodes `name`/`city`/`iso` as
Optional, so a stale or hand-trimmed JSON still loads.

Usage:
    python3 scripts/build-airports-json.py [path/to/airports.csv] [--runways path/to/runways.csv]
    python3 scripts/build-airports-json.py --tiers-only [path/to/airports.csv] [--runways ...]
    python3 scripts/build-airports-json.py --islands-only [--geocoder path/to/Geocoder.sqlite]

With no CSV argument the script downloads the current CSVs from the
canonical mirror. The output path is fixed: TravelLog/Resources/airports.json
(relative to the repo root, resolved from this script's location).

`--tiers-only` keeps the bundled records exactly as they are and only
(re)writes each one's `size` and `ring` from the CSVs: the record's code, else a
same-type row at its coordinates (`TIER_MATCH_KM`), so a rebuild of the
tiers never moves an airport or changes a name. Rows the CSV no longer
lists, or lists as closed, get no `size`.

`--islands-only` keeps the bundled records and only (re)writes each one's
`isl` and `islid`; it needs no CSV. Every mode reads the
islands from `--geocoder` (default: the bundled TravelLog/Resources/
Geocoder.sqlite, built by scripts/build-geocoder-db.py), and names that are
not ASCII are transliterated by `swift` with the transforms of
`String.toLatinAscii`, so this mode needs macOS.
"""

import argparse
import csv
import io
import json
import math
import os
import sqlite3
import struct
import subprocess
import urllib.request
from pathlib import Path
from typing import Optional

CSV_URL = "https://davidmegginson.github.io/ourairports-data/airports.csv"
RUNWAYS_URL = "https://davidmegginson.github.io/ourairports-data/runways.csv"
KEEP_TYPES = {"large_airport", "medium_airport"}

# A `large_airport` needs a runway this long to count as major: about what a
# long-haul wide-body needs, and a line OurAirports' type does not draw (it
# calls fields with one 2,000 m runway "large", like the biggest hubs).
MAJOR_MIN_RUNWAY_M = 2500
TIER_TYPES = {"large_airport", "medium_airport", "small_airport"}
# `--tiers-only`: how far a bundled record may sit from the CSV row it takes
# its tier from (by code, else by position for a recoded airport).
TIER_MATCH_KM = 5.0
TIER_POSITION_KM = 1.0
# `ring`: a small island field's ring must not reach the town or ferry port
# beside it (often about 2 km from the field's point), while a big
# airport's terminals sit up to 3 km from its reference point. Mirrors
# `AirportRecord.ringMeters` in AirportDetector.swift.
RING_MARGIN_M = 1000
RING_MIN_M = 1500
RING_MAX_M = 3000

# `isl`: islands above this are landmasses, never an island end. Mirrors
# `GeocodeResolver.islandAreaCapKm2`.
ISLAND_AREA_CAP_KM2 = 30000.0
EARTH_RADIUS_KM = 6371.0088

# small_airport rows are kept only with scheduled service, including
# small island and regional airports used by scheduled passenger flights.
# Unscheduled small strips stay excluded: they would bloat the bundle ~6x and spray false
# `Stay.isAirport` flags near every grass field.
#
# Setting this False keeps all small airports, scheduled or not. The flag
# bypasses the service requirement rather than excluding every small airport.
SMALL_REQUIRES_SCHEDULED = True


def load_csv_text(csv_path: Optional[Path] = None, url: str = CSV_URL) -> str:
    if csv_path is not None:
        return csv_path.read_text(encoding="utf-8")
    print(f"Downloading {url} …")
    with urllib.request.urlopen(url, timeout=120) as resp:
        return resp.read().decode("utf-8")


def longest_runways(text: str) -> dict:
    """Airport `id` → its longest open runway in metres (0 when unknown)."""
    longest: dict = {}
    for row in csv.DictReader(io.StringIO(text)):
        if (row.get("closed") or "").strip() == "1":
            continue
        try:
            metres = float(row["length_ft"]) * 0.3048
        except (ValueError, KeyError):
            continue
        ref = row.get("airport_ref") or ""
        longest[ref] = max(longest.get(ref, 0.0), metres)
    return longest


def runway_ends(text: str) -> dict:
    """Airport `id` → (longest open runway in metres, [(lat, lon)] of its
    open runways' ends)."""
    found: dict = {}
    for row in csv.DictReader(io.StringIO(text)):
        if (row.get("closed") or "").strip() == "1":
            continue
        ref = row.get("airport_ref") or ""
        longest, ends = found.get(ref, (0.0, []))
        try:
            longest = max(longest, float(row["length_ft"]) * 0.3048)
        except (ValueError, KeyError):
            pass
        for end in ("le", "he"):
            try:
                ends.append((float(row[end + "_latitude_deg"]), float(row[end + "_longitude_deg"])))
            except (ValueError, KeyError):
                pass
        found[ref] = (longest, ends)
    return found


def ring(row: dict, ends: dict, lat: float, lon: float) -> Optional[int]:
    """The `ring` for an airport at `lat`/`lon` with `row`'s runways; None
    when it is RING_MAX_M or no runway is known."""
    longest, points = ends.get(row.get("id") or "", (0.0, []))
    reach = max([km_between(lat, lon, a, b) * 1000 for a, b in points] + [longest / 2])
    if reach <= 0:
        return None
    metres = min(RING_MAX_M, max(RING_MIN_M, math.ceil((reach + RING_MARGIN_M) / 100) * 100))
    return None if metres >= RING_MAX_M else metres


def tier(row: dict, runways: dict) -> Optional[str]:
    kind = row.get("type")
    if kind == "small_airport":
        return "S"
    if kind == "medium_airport":
        return "M"
    if kind == "large_airport":
        runway = runways.get(row.get("id") or "", 0.0)
        return "M" if 0 < runway < MAJOR_MIN_RUNWAY_M else "L"
    return None


def row_code(row: dict) -> str:
    return (row.get("iata_code") or "").strip() or row["ident"].strip()


def km_between(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    dy = (lat1 - lat2) * 111.32
    dx = (lon1 - lon2) * 111.32 * math.cos(math.radians((lat1 + lat2) / 2))
    return math.hypot(dx, dy)


def write_records(records: list, out_path: Path) -> None:
    body = json.dumps(records, ensure_ascii=False, separators=(",", ":"))
    tmp_path = out_path.with_name(out_path.name + ".tmp")
    try:
        tmp_path.write_text(body, encoding="utf-8")
        if json.loads(tmp_path.read_text(encoding="utf-8")) != records:
            raise RuntimeError("written airports do not match generated data")
        os.replace(tmp_path, out_path)
    finally:
        tmp_path.unlink(missing_ok=True)
    size_kb = out_path.stat().st_size / 1024
    print(f"Wrote {len(records)} airports → {out_path} ({size_kb:.0f} KB)")


def parse_wkb(wkb: bytes) -> list:
    """A little-endian WKB Polygon or MultiPolygon as [polygon][ring][(lon, lat)],
    like `WKBPolygon(data:)`; empty for anything else."""
    offset = 0

    def u32() -> int:
        nonlocal offset
        value = struct.unpack_from("<I", wkb, offset)[0]
        offset += 4
        return value

    def polygon() -> list:
        nonlocal offset
        rings = []
        for _ in range(u32()):
            count = u32()
            flat = struct.unpack_from("<%dd" % (2 * count), wkb, offset)
            offset += 16 * count
            rings.append([(flat[2 * i], flat[2 * i + 1]) for i in range(count)])
        return rings

    if len(wkb) < 5 or wkb[0] != 1:
        return []
    offset = 1
    kind = u32()
    if kind == 3:
        return [polygon()]
    if kind == 6:
        polygons = []
        for _ in range(u32()):
            offset += 1
            if u32() != 3:
                return []
            polygons.append(polygon())
        return polygons
    return []


def wrapped_delta(a: float, b: float) -> float:
    d = a - b
    return d - 360 if d > 180 else d + 360 if d < -180 else d


def ring_contains(ring: list, x: float, y: float) -> bool:
    """`WKBPolygon.ringContains`: a ray cast with longitudes unwrapped
    around the ring's first vertex."""
    if len(ring) < 3:
        return False
    ref = ring[0][0]
    px = ref + wrapped_delta(x, ref)
    inside = False
    j = len(ring) - 1
    for i in range(len(ring)):
        xi, yi = ref + wrapped_delta(ring[i][0], ref), ring[i][1]
        xj, yj = ref + wrapped_delta(ring[j][0], ref), ring[j][1]
        if (yi > y) != (yj > y) and px < (xj - xi) * (y - yi) / (yj - yi + 1e-30) + xi:
            inside = not inside
        j = i
    return inside


def polygons_contain(polygons: list, lon: float, lat: float) -> bool:
    return any(rings and ring_contains(rings[0], lon, lat)
               and not any(ring_contains(hole, lon, lat) for hole in rings[1:])
               for rings in polygons)


def ring_area_km2(ring: list) -> float:
    """`WKBPolygon.ringAreaKm2`: unsigned spherical area of one ring."""
    count = len(ring)
    if count >= 2 and ring[0] == ring[-1]:
        count -= 1
    if count < 3:
        return 0.0
    total = 0.0
    for i in range(count):
        delta = ring[(i + 1) % count][0] - ring[(i + count - 1) % count][0]
        if delta > 180:
            delta -= 360
        elif delta < -180:
            delta += 360
        total += math.radians(delta) * math.sin(math.radians(ring[i][1]))
    return abs(total) * EARTH_RADIUS_KM ** 2 / 2


def polygons_area_km2(polygons: list) -> float:
    total = sum(ring_area_km2(ring) * (1 if index == 0 else -1)
                for rings in polygons for index, ring in enumerate(rings))
    return max(0.0, total)


def latin_ascii(names: set) -> dict:
    """Each name as `String.toLatinAscii` writes it (ICU Any-Latin, then
    diacritics stripped); ASCII names unchanged."""
    foreign = sorted(name for name in names if not name.isascii())
    result = {name: name for name in names if name.isascii()}
    if not foreign:
        return result
    program = (
        "import Foundation\n"
        "while let line = readLine() {\n"
        "    let latin = line.applyingTransform(.toLatin, reverse: false)\n"
        "    let stripped = (latin ?? line).applyingTransform(.stripDiacritics, reverse: false)\n"
        "    print(stripped ?? latin ?? line)\n"
        "}\n")
    out = subprocess.run(["swift", "-e", program], input="\n".join(foreign) + "\n",
                         capture_output=True, text=True, check=True).stdout.split("\n")
    if len(out) < len(foreign):
        raise RuntimeError("swift transliterated %d of %d island names" % (len(out), len(foreign)))
    result.update(zip(foreign, out))
    return result


def longitude_segments(center: float, half: float) -> list:
    """`GeoMath.longitudeSegments`: `center ± half` split at ±180°."""
    if half >= 180:
        return [(-180.0, 180.0)]
    center = center - 360 if center > 180 else center + 360 if center < -180 else center
    low, high = center - half, center + half
    if low < -180:
        return [(-180.0, high), (low + 360, 180.0)]
    if high > 180:
        return [(low, 180.0), (-180.0, high - 360)]
    return [(low, high)]


def nearest_town(con, lat: float, lon: float) -> Optional[tuple]:
    """`GeocodeResolver.nearestCity`'s point: the nearest GeoNames town in a
    window of 0.05° of latitude and the same ground width of longitude."""
    cos_lat = math.cos(math.radians(lat))
    half = 180.0 if cos_lat <= 0.01 else min(0.05 / cos_lat, 180.0)
    best = None
    for low, high in longitude_segments(lon, half):
        for town_lat, town_lon in con.execute(
                "SELECT city.lat, city.lon FROM city_rtree JOIN city ON city.geoname_id = city_rtree.geoname_id "
                "WHERE city_rtree.min_lat BETWEEN ?1 - 0.05 AND ?1 + 0.05 AND city_rtree.min_lon BETWEEN ?2 AND ?3",
                (lat, low, high)):
            dy = town_lat - lat
            dx = wrapped_delta(town_lon, lon) * math.cos(math.radians(lat))
            if best is None or dy * dy + dx * dx < best[0]:
                best = (dy * dy + dx * dx, town_lat, town_lon)
    return best[1:] if best else None


def airport_islands(records: list, geocoder: Path) -> dict:
    """Code → (`islid`, `isl`) for every record on an island under
    ISLAND_AREA_CAP_KM2, as `GeocodeResolver` places a stay there (and
    `AirportGroundTable` a flight end): the largest such island polygon
    containing the airport's point, or, when no island polygon contains it,
    its nearest town's. `isl` is empty for an island whose name
    transliterates to nothing."""
    if not geocoder.exists():
        raise SystemExit(f"{geocoder} not found: build it with scripts/build-geocoder-db.py")
    con = sqlite3.connect(f"file:{geocoder}?mode=ro", uri=True)
    cache: dict = {}
    found: dict = {}

    def island_hits(lat: float, lon: float) -> list:
        hits = []
        for osm_id, name, name_en, wkb in con.execute(
                "SELECT island.osm_id, island.name, island.name_en, island.wkb "
                "FROM island_rtree JOIN island ON island.osm_id = island_rtree.osm_id "
                "WHERE island_rtree.min_lat <= ?1 AND island_rtree.max_lat >= ?1 "
                "AND island_rtree.min_lon <= ?2 AND island_rtree.max_lon >= ?2 "
                "ORDER BY island.osm_id", (lat, lon)):
            if osm_id not in cache:
                polygons = parse_wkb(wkb)
                cache[osm_id] = (polygons, polygons_area_km2(polygons))
            polygons, area = cache[osm_id]
            if polygons_contain(polygons, lon, lat):
                hits.append((area, osm_id, name_en or name))
        return hits

    try:
        for record in records:
            hits = island_hits(record["lat"], record["lon"])
            if not hits:
                town = nearest_town(con, record["lat"], record["lon"])
                if town:
                    hits = island_hits(*town)
            under = [hit for hit in hits if hit[0] < ISLAND_AREA_CAP_KM2]
            if under:
                _, osm_id, name = max(under, key=lambda hit: hit[0])
                found[record["code"]] = (osm_id, name)
    finally:
        con.close()
    names = latin_ascii({name for _, name in found.values()})
    return {code: (osm_id, names[name]) for code, (osm_id, name) in found.items()}


def annotate_islands(records: list, geocoder: Path) -> None:
    """Sets each record's `isl` and `islid`, dropping stale ones."""
    islands = airport_islands(records, geocoder)
    for record in records:
        record.pop("isl", None)
        record.pop("islid", None)
        if record["code"] in islands:
            osm_id, name = islands[record["code"]]
            if name:
                record["isl"] = name
            record["islid"] = osm_id
    print("Airports on an island under", int(ISLAND_AREA_CAP_KM2), "km²:", len(islands))


def annotate_tiers(rows: list, runways: dict, ends: dict, out_path: Path) -> None:
    """Rewrites only `size` and `ring` on the bundled records (see `--tiers-only`)."""
    records = json.loads(out_path.read_text(encoding="utf-8"))
    by_code: dict = {}
    for row in rows:
        if row.get("type") not in TIER_TYPES:
            continue
        for code in {row_code(row), row["ident"].strip(), (row.get("iata_code") or "").strip()} - {""}:
            by_code.setdefault(code, []).append(row)
    open_rows = [row for row in rows if row.get("type") in TIER_TYPES]

    def position(row: dict) -> tuple:
        return float(row["latitude_deg"]), float(row["longitude_deg"])

    counts: dict = {}
    rings = 0
    for record in records:
        def near(row: dict) -> float:
            lat, lon = position(row)
            return km_between(record["lat"], record["lon"], lat, lon)
        match = min(by_code.get(record["code"], []), key=near, default=None)
        if match is not None and near(match) > TIER_MATCH_KM:
            match = None
        if match is None:
            # Recoded since the slice was cut: the open row on the spot.
            band = [row for row in open_rows
                    if abs(float(row["latitude_deg"]) - record["lat"]) <= 0.02]
            match = min(band, key=near, default=None)
            if match is not None and near(match) > TIER_POSITION_KM:
                match = None
        record.pop("size", None)
        record.pop("ring", None)
        value = tier(match, runways) if match is not None else None
        if value:
            record["size"] = value
        metres = ring(match, ends, record["lat"], record["lon"]) if match is not None else None
        if metres:
            record["ring"] = metres
        counts[value] = counts.get(value, 0) + 1
        rings += metres is not None
    print("Tiers:", {str(k): v for k, v in sorted(counts.items(), key=lambda kv: str(kv[0]))})
    print("Rings under", RING_MAX_M, "m:", rings)
    write_records(records, out_path)


def main() -> None:
    parser = argparse.ArgumentParser(description="Regenerate bundled airports.json from OurAirports.")
    parser.add_argument("csv_path", nargs="?", type=Path,
                        help="Local airports.csv (default: download the canonical CSV)")
    parser.add_argument("--runways", type=Path,
                        help="Local runways.csv (default: download the canonical CSV)")
    parser.add_argument("--tiers-only", action="store_true",
                        help="Keep the bundled records; only rewrite each one's size")
    parser.add_argument("--islands-only", action="store_true",
                        help="Keep the bundled records; only rewrite each one's isl and islid")
    parser.add_argument("--geocoder", type=Path,
                        help="Geocoder.sqlite with the island polygons (default: the bundled one)")
    args = parser.parse_args()
    resources = Path(__file__).resolve().parent.parent / "TravelLog" / "Resources"
    out_path = resources / "airports.json"
    geocoder = args.geocoder or resources / "Geocoder.sqlite"
    if args.islands_only:
        records = json.loads(out_path.read_text(encoding="utf-8"))
        annotate_islands(records, geocoder)
        write_records(records, out_path)
        return
    text = load_csv_text(args.csv_path)
    runways_text = load_csv_text(args.runways, RUNWAYS_URL)
    runways = longest_runways(runways_text)
    ends = runway_ends(runways_text)
    rows = list(csv.DictReader(io.StringIO(text)))
    if args.tiers_only:
        annotate_tiers(rows, runways, ends, out_path)
        return

    records = []
    for row in rows:
        scheduled = (row.get("scheduled_service") or "").strip() == "yes"
        if row["type"] not in KEEP_TYPES:
            keep_small = row["type"] == "small_airport" and (
                scheduled or not SMALL_REQUIRES_SCHEDULED
            )
            if not keep_small:
                continue
        code = (row.get("iata_code") or "").strip() or row["ident"].strip()
        if not code:
            continue
        try:
            lat = round(float(row["latitude_deg"]), 5)
            lon = round(float(row["longitude_deg"]), 5)
        except (ValueError, KeyError):
            continue
        record = {"code": code, "lat": lat, "lon": lon}
        name = (row.get("name") or "").strip()
        if name:
            record["name"] = name
        city = (row.get("municipality") or "").strip()
        if city:
            record["city"] = city
        iso = (row.get("iso_country") or "").strip().upper()
        if len(iso) == 2:
            record["iso"] = iso
        record["svc"] = (row.get("scheduled_service") or "").strip() == "yes"
        size = tier(row, runways)
        if size:
            record["size"] = size
        metres = ring(row, ends, lat, lon)
        if metres:
            record["ring"] = metres
        records.append(record)

    # Deterministic output order (code, then coords for the rare duplicate
    # code) so regenerating produces reviewable diffs.
    records.sort(key=lambda r: (r["code"], r["lat"], r["lon"]))
    annotate_islands(records, geocoder)

    write_records(records, out_path)


if __name__ == "__main__":
    main()
