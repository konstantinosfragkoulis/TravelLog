#!/usr/bin/env python3
"""
Download Natural Earth 1:10m country polygons and emit the file at
TravelLog/Resources/countries.geojson. Replaces the previous 1:50m
file, which collapsed dense archipelagos (Greek, Indonesian,
Philippine, Norwegian fjords) into smoothed blobs.
Running this downloads a pinned source revision and overwrites the tracked GeoJSON.

# Why

The 1:10m dataset has ~30x more polygon vertices than 1:50m, so on
the globe view every Aegean island, every Indonesian island, every
Pacific atoll is drawn individually. Geocoding behavior is
unchanged — point-in-polygon works at any resolution.

# Sizes

- 1:50m source: ~2.5 MB GeoJSON (242 features, ~100K coords) — current
- 1:10m source: ~24 MB GeoJSON (258 features, ~3M coords) — new

After Douglas-Peucker simplification at tolerance ~0.005° (~500m),
output should land in the 8-12 MB range. We aim for legible borders
without the full 1:10m verbosity — most of those 3M vertices are
sub-pixel detail invisible at globe scale.

# License

Natural Earth is public domain — no attribution required.
https://www.naturalearthdata.com/about/terms-of-use/

# How

Pinned to nvkelso/natural-earth-vector commit
9380cca83db5f9aef52d5e762765100745f84b27 (May 13, 2022), the newest
revision of this source file before the September 11, 2026 bundle rebuild.
The tracked bundle instead matches a 0.01-degree simplification and four-decimal
rounding of an earlier bundled countries.geojson, retaining only
two-character ISO codes. A fresh source rebuild has 245 features versus the
bundle's 244 and differs by 1,277 bytes; pinning the input does not remove
that existing preprocessing difference.

To bump: replace the commit SHA in SOURCE_URL, rebuild, and review the
geometry diff before shipping. Update this note with the revision and date.
NE_ADMIN1_URL in build-geocoder-db.py has a separate source/version policy.

# Run

    python3 scripts/build-countries-10m.py

No third-party dependencies — stdlib only.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import tempfile
import urllib.request
from pathlib import Path

# Natural Earth 1:10m Admin 0 Countries, GeoJSON build.
#
# naciscdn.org distributes shapefile only, which would require pyshp /
# fiona. Instead we use the GeoJSON build maintained by nvkelso (the
# project lead for Natural Earth) on GitHub. Bit-identical data to the
# official release; only difference is the file format.
#
# To bump: replace the commit SHA and review the rebuilt geometry diff.
SOURCE_URL = (
    "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/"
    "9380cca83db5f9aef52d5e762765100745f84b27/geojson/ne_10m_admin_0_countries.geojson"
)

# Douglas-Peucker simplification tolerance in degrees. At lat ~40°,
# 0.005° ≈ 500 m. Tolerance shows up as the "step" between successive
# vertices — anything finer is invisible at globe scale on a phone.
SIMPLIFY_TOLERANCE = 0.01

# Where to write the final GeoJSON.
REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_PATH = REPO_ROOT / "TravelLog" / "Resources" / "countries.geojson"


def download_to(tmpdir: Path) -> Path:
    """Fetch the NE 10m GeoJSON into tmpdir. Returns the path to it."""
    geojson_path = tmpdir / "ne_10m_admin_0_countries.geojson"
    print(f"Downloading Natural Earth 1:10m countries from\n  {SOURCE_URL}")
    urllib.request.urlretrieve(SOURCE_URL, geojson_path)
    size_mb = geojson_path.stat().st_size / 1024 / 1024
    print(f"  ✓ {size_mb:.1f} MB downloaded")
    return geojson_path


# ---- Pure-Python Douglas-Peucker simplification ----
# We avoid Shapely so the script works with stdlib-only Python.
# DP is a recursive perpendicular-distance simplifier; topologically
# safe enough for country borders at globe-view scale.

def _perp_distance(p: list[float], a: list[float], b: list[float]) -> float:
    """Perpendicular distance from p to the line a-b, in degrees."""
    if a == b:
        return math.hypot(p[0] - a[0], p[1] - a[1])
    dx, dy = b[0] - a[0], b[1] - a[1]
    t = ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / (dx * dx + dy * dy)
    t = max(0.0, min(1.0, t))
    px, py = a[0] + t * dx, a[1] + t * dy
    return math.hypot(p[0] - px, p[1] - py)


def simplify_ring(ring: list[list[float]], tolerance: float) -> list[list[float]]:
    """Douglas-Peucker on a single polygon ring. Returns the simplified ring."""
    if len(ring) < 4:  # too small to simplify (closed ring of <4 points)
        return ring

    # Iterative DP to avoid Python's recursion limit on very dense rings.
    keep = [False] * len(ring)
    keep[0] = True
    keep[-1] = True
    stack = [(0, len(ring) - 1)]
    while stack:
        lo, hi = stack.pop()
        if hi - lo < 2:
            continue
        a, b = ring[lo], ring[hi]
        max_dist = -1.0
        max_idx = -1
        for i in range(lo + 1, hi):
            d = _perp_distance(ring[i], a, b)
            if d > max_dist:
                max_dist = d
                max_idx = i
        if max_dist > tolerance:
            keep[max_idx] = True
            stack.append((lo, max_idx))
            stack.append((max_idx, hi))

    simplified = [pt for pt, k in zip(ring, keep) if k]
    # Ensure ring is closed
    if simplified[0] != simplified[-1]:
        simplified.append(simplified[0])
    return simplified


def round_coordinates(coords, places: int):
    """Round every lon/lat to `places` decimals (4 = ~11 m, plenty for a globe fill)."""
    if isinstance(coords[0], (int, float)):
        return [round(coords[0], places), round(coords[1], places)]
    return [round_coordinates(c, places) for c in coords]


def simplify_geometry(geom: dict, tolerance: float) -> dict:
    """Recursively simplify all rings inside a Polygon or MultiPolygon."""
    gtype = geom.get("type")
    if gtype == "Polygon":
        return {
            "type": "Polygon",
            "coordinates": [simplify_ring(r, tolerance) for r in geom["coordinates"]],
        }
    if gtype == "MultiPolygon":
        return {
            "type": "MultiPolygon",
            "coordinates": [
                [simplify_ring(r, tolerance) for r in poly]
                for poly in geom["coordinates"]
            ],
        }
    return geom


def trim_properties(props: dict) -> dict | None:
    """
    Keep only ISO_A2 — the only property the app reads. Drops ~50
    other columns (names, populations, GDP, etc.) that Natural Earth
    ships but we never use, shaving the output size dramatically.

    NE 10m marks some entries' `ISO_A2` as the sentinel "-99" even for
    well-defined countries (France, Norway) — apparently because NE's
    classification has them as "indeterminate" for political reasons.
    The `ISO_A2_EH` ("Eastern-Hemisphere", NE's disputes-resolved variant)
    is the practical fallback. We try keys in order and accept the first
    plain two-letter value: Taiwan's `ISO_A2` is "CN-TW", so it must fall
    through to `ISO_A2_EH` ("TW") instead of being dropped.
    """
    for key in ("ISO_A2", "ISO_A2_EH", "WB_A2"):
        code = props.get(key)
        if code and len(code) == 2 and code.isalpha():
            return {"ISO_A2": code}
    return None


def main():
    parser = argparse.ArgumentParser(
        description="Download Natural Earth 1:10m countries from a pinned revision and overwrite the tracked GeoJSON."
    )
    parser.parse_args()

    if not OUTPUT_PATH.parent.is_dir():
        raise SystemExit(f"Resources dir not found at {OUTPUT_PATH.parent}")

    previous_size_mb = (
        OUTPUT_PATH.stat().st_size / 1024 / 1024 if OUTPUT_PATH.exists() else 0
    )

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        src = download_to(tmp)
        print(f"Source: {src.name}")

        with open(src, encoding="utf-8") as f:
            data = json.load(f)

    features_in = data.get("features", [])
    print(f"Read {len(features_in)} features from source")

    features_out = []
    total_coords_in = 0
    total_coords_out = 0
    skipped = 0

    for f in features_in:
        props = trim_properties(f.get("properties", {}))
        if props is None:
            skipped += 1
            continue
        geom = f.get("geometry") or {}

        # Count input vertices for diagnostics
        def count_coords(g):
            t = g.get("type")
            if t == "Polygon":
                return sum(len(r) for r in g["coordinates"])
            if t == "MultiPolygon":
                return sum(sum(len(r) for r in p) for p in g["coordinates"])
            return 0

        total_coords_in += count_coords(geom)
        simplified = simplify_geometry(geom, SIMPLIFY_TOLERANCE)
        simplified["coordinates"] = round_coordinates(simplified["coordinates"], 4)
        total_coords_out += count_coords(simplified)

        features_out.append(
            {
                "type": "Feature",
                "properties": props,
                "geometry": simplified,
            }
        )

    output = {"type": "FeatureCollection", "features": features_out}

    # Write with compact separators — saves ~20% bundle size vs pretty-printed.
    # Write to a sibling temp file and os.replace() so the tracked, shipped
    # resource is never left half-written if the dump is interrupted.
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = OUTPUT_PATH.with_name(OUTPUT_PATH.name + ".tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(output, f, separators=(",", ":"))
    os.replace(tmp_path, OUTPUT_PATH)

    size_mb = OUTPUT_PATH.stat().st_size / 1024 / 1024

    print()
    print("─" * 60)
    print("Build summary")
    print("─" * 60)
    print(f"  Features kept           : {len(features_out)}")
    print(f"  Features dropped (no ISO): {skipped}")
    print(f"  Vertices in source       : {total_coords_in:,}")
    print(f"  Vertices after simplify  : {total_coords_out:,} "
          f"({100 * total_coords_out / max(total_coords_in, 1):.1f}%)")
    print(f"  Tolerance                : {SIMPLIFY_TOLERANCE}° "
          f"(~{SIMPLIFY_TOLERANCE * 111 * 1000:.0f} m at equator)")
    print(f"  Output size              : {size_mb:.1f} MB"
          + (f"  (was {previous_size_mb:.1f} MB)" if previous_size_mb else ""))
    print(f"  Output path              : {OUTPUT_PATH}")
    print()
    print("Sanity-check: Greece, Indonesia, Philippines should now render with")
    print("individual islands on the globe view.")


if __name__ == "__main__":
    main()
