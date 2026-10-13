#!/usr/bin/env python3
"""
build-airports-json.py — regenerate the bundled `TravelLog/Resources/airports.json`
from the OurAirports dataset (public domain, https://ourairports.com/data/).

The bundled slice keeps only `large_airport` and `medium_airport` rows
(~5,300 worldwide) — the same filter the original code+lat+lon slice used.
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

`AirportRecord` in `AirportDetector.swift` decodes `name`/`city`/`iso` as
Optional, so a stale or hand-trimmed JSON still loads.

Usage:
    python3 scripts/build-airports-json.py [path/to/airports.csv]

With no argument the script downloads the current CSV from the canonical
mirror. The output path is fixed: TravelLog/Resources/airports.json
(relative to the repo root, resolved from this script's location).
"""

import csv
import io
import json
import sys
import urllib.request
from pathlib import Path

CSV_URL = "https://davidmegginson.github.io/ourairports-data/airports.csv"
KEEP_TYPES = {"large_airport", "medium_airport"}

# small_airport rows are kept only with scheduled service, including
# small island and regional airports used by scheduled passenger flights.
# Unscheduled small strips stay excluded: they would bloat the bundle ~6x and spray false
# `Stay.isAirport` flags near every grass field.
#
# Setting this False keeps all small airports, scheduled or not. The flag
# bypasses the service requirement rather than excluding every small airport.
SMALL_REQUIRES_SCHEDULED = True


def load_csv_text() -> str:
    if len(sys.argv) > 1:
        return Path(sys.argv[1]).read_text(encoding="utf-8")
    print(f"Downloading {CSV_URL} …")
    with urllib.request.urlopen(CSV_URL, timeout=120) as resp:
        return resp.read().decode("utf-8")


def main() -> None:
    text = load_csv_text()
    out_path = (
        Path(__file__).resolve().parent.parent
        / "TravelLog" / "Resources" / "airports.json"
    )

    records = []
    for row in csv.DictReader(io.StringIO(text)):
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
        records.append(record)

    # Deterministic output order (code, then coords for the rare duplicate
    # code) so regenerating produces reviewable diffs.
    records.sort(key=lambda r: (r["code"], r["lat"], r["lon"]))

    out_path.write_text(
        json.dumps(records, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    size_kb = out_path.stat().st_size / 1024
    print(f"Wrote {len(records)} airports → {out_path} ({size_kb:.0f} KB)")


if __name__ == "__main__":
    main()
