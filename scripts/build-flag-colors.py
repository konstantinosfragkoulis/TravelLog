#!/usr/bin/env python3
"""Generate TravelLog/Views/Shared/FlagColors.swift: each shipped flag's
colours for the Trips list's leading-edge wash, as three bands top to bottom.

Reads the app's own flag artwork (TravelLog/Flags.xcassets, flag-<iso>
image sets: lipis/flag-icons 4:3 vectors, shipped as librsvg-converted
PDFs), rasterizes each at 120 x 90 px with poppler's pdftoppm, crops it to
the 3:2 frame FlagView shows (the 4:3 art fills a 3:2 frame, losing a band
top and bottom; the stretched flags keep the whole art), then:

  1. merges pixel colours into clusters within OKLab distance 0.06, the most
     common colour first (anti-aliasing, gradients, small shading), and keeps
     clusters of at least 1.5% of the frame; a cluster's colour is its most
     common pixel colour, so the table holds the flag's own colours;
  2. calls a cluster vivid at OKLab chroma 0.06 and lightness 0.25 or more
     (white, black and grey are not: the wash leaves them clear);
  3. splits the flag into thirds both ways, top to bottom and left to right.
     A third's colour is the cluster holding most of it, but a vivid cluster
     with a quarter of the third wins over white, black or grey (Japan's
     disc), and a third of only those is clear. The way whose thirds are the
     purest wins, a little bonus going to thirds that differ (Germany's
     stripes run across, Italy's down);
  4. writes the three thirds as the wash's three bands, top to bottom: a flag
     striped left to right reads its stripes from the top (Italy: green,
     clear, red). A flag with a single vivid colour in its bands fills all
     three (Japan, Switzerland), and one with a vivid colour too small for
     any third fills them with it too; a flag with no vivid colour is left
     out (the row draws no wash);
  5. adds the lead: the vivid colour covering most of the flag, which a trip
     through several countries uses for each one.

Deterministic: same artwork, same table. Pure Python plus pdftoppm
(`brew install poppler`); no image libraries.

Usage:
  python3 scripts/build-flag-colors.py . [--out FILE]
"""

import argparse
import math
import subprocess
import sys
from pathlib import Path

W, H = 120, 90
CROP_ROWS = 5  # 4:3 -> 3:2: 90 rows to 80
STRETCHED = {"gd", "lk", "me"}  # FlagView scales these to the frame, no crop
UNFRAMED = {"np"}
MERGE = 0.06
MIN_COVERAGE = 0.015
VIVID_CHROMA = 0.06
VIVID_LIGHTNESS = 0.25
VIVID_SHARE = 0.25
DISTINCT_BONUS = 0.04


def decode_ppm(data):
    """Binary P6 PPM (8-bit) -> rows of (r, g, b)."""
    fields, pos = [], 0
    while len(fields) < 4:
        while data[pos:pos + 1].isspace():
            pos += 1
        if data[pos:pos + 1] == b"#":
            pos = data.index(b"\n", pos) + 1
            continue
        end = pos
        while not data[end:end + 1].isspace():
            end += 1
        fields.append(data[pos:end])
        pos = end
    assert fields[0] == b"P6" and int(fields[3]) == 255, fields
    width, height = int(fields[1]), int(fields[2])
    pixels = data[pos + 1:]
    return [[tuple(pixels[(y * width + x) * 3:(y * width + x) * 3 + 3]) for x in range(width)]
            for y in range(height)]


def raster(pdf):
    out = subprocess.run(["pdftoppm", "-singlefile", "-scale-to-x", str(W), "-scale-to-y", str(H), str(pdf)],
                         check=True, capture_output=True).stdout
    return decode_ppm(out)


def oklab(c):
    def linear(v):
        v /= 255
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (linear(v) for v in c)
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l, m, s = (math.copysign(abs(v) ** (1 / 3), v) for v in (l, m, s))
    return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)


def is_vivid(c):
    L, a, b = oklab(c)
    return math.hypot(a, b) >= VIVID_CHROMA and L >= VIVID_LIGHTNESS


def wash(iso, pdf):
    """(lead, [top, middle, bottom]) as RGB tuples (a band None when clear), or None."""
    rows = raster(pdf)
    if iso not in STRETCHED and iso not in UNFRAMED:
        rows = rows[CROP_ROWS:len(rows) - CROP_ROWS]
    height, width = len(rows), len(rows[0])
    counts = {}
    for row in rows:
        for c in row:
            counts[c] = counts.get(c, 0) + 1
    # Clusters: the most common colours first, each later colour joining the
    # first cluster within MERGE of its representative.
    reps, cluster_of = [], {}
    for c, _ in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])):
        lab = oklab(c)
        for i, (rep, rep_lab) in enumerate(reps):
            if math.dist(lab, rep_lab) <= MERGE:
                cluster_of[c] = i
                break
        else:
            cluster_of[c] = len(reps)
            reps.append((c, lab))
    total = height * width
    sizes = [0] * len(reps)
    for c, n in counts.items():
        sizes[cluster_of[c]] += n
    kept = [i for i in range(len(reps)) if sizes[i] / total >= MIN_COVERAGE]
    vivid = {i for i in kept if is_vivid(reps[i][0])}
    if not vivid:
        return None
    lead = max(vivid, key=lambda i: (sizes[i], -i))

    def thirds(across):
        parts = [[0] * len(reps) for _ in range(3)]
        for y, row in enumerate(rows):
            for x, c in enumerate(row):
                part = y * 3 // height if across else x * 3 // width
                parts[part][cluster_of[c]] += 1
        picks, purity = [], 0.0
        for part in parts:
            n = sum(part)
            shares = {i: part[i] / n for i in kept}
            top = max(kept, key=lambda i: (shares[i], -i))
            purity += shares[top]
            if top not in vivid:
                best = max(vivid, key=lambda i: (shares[i], -i))
                top = best if shares[best] >= VIVID_SHARE else None
            picks.append(top)
        score = purity / 3 + DISTINCT_BONUS * (len(set(picks)) - 1)
        return score, picks

    across, down = thirds(True), thirds(False)
    picks = across[1] if across[0] >= down[0] - 1e-9 else down[1]
    shown = {p for p in picks if p is not None}
    if len(shown) <= 1:
        fill = next(iter(shown)) if shown else lead
        picks = [fill] * 3
    return reps[lead][0], [None if p is None else reps[p][0] for p in picks]


def hexs(c):
    return "nil" if c is None else "0x%02X%02X%02X" % c


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("repo", type=Path)
    ap.add_argument("--out", type=Path)
    args = ap.parse_args()
    assets = args.repo / "TravelLog" / "Flags.xcassets"
    out = args.out or args.repo / "TravelLog" / "Views" / "Shared" / "FlagColors.swift"
    entries, skipped = [], []
    for imageset in sorted(assets.glob("flag-*.imageset")):
        iso = imageset.name[5:-9]
        art = sorted(imageset.glob("*.pdf"))
        if not art:
            raise SystemExit("no PDF in %s" % imageset)
        result = wash(iso, art[0])
        if result:
            entries.append((iso.upper(), result))
        else:
            skipped.append(iso)
    lines = [
        "// GENERATED offline from Flags.xcassets (the flag-icons vectors) by",
        "// scripts/build-flag-colors.py: each flag's lead colour and its wash's",
        "// three bands, top to bottom, in the 3:2 frame FlagView shows. Do not",
        "// edit by hand; regenerate with the script.",
        "",
        "import Foundation",
        "",
        "nonisolated enum FlagColors {",
        "    /// Uppercase ISO 3166-1 alpha-2 code: the vivid colour covering most of",
        "    /// the flag, then the wash's top, middle and bottom bands as 0xRRGGBB,",
        "    /// nil where the flag is white, black or grey there.",
        "    /// Flags without a vivid colour (%s) are absent." % (", ".join(s.upper() for s in skipped) or "none"),
        "    static let wash: [String: (lead: UInt32, top: UInt32?, middle: UInt32?, bottom: UInt32?)] = [",
    ]
    for iso, (lead, bands) in entries:
        lines.append('        "%s": (%s, %s, %s, %s),' % (iso, hexs(lead), *(hexs(b) for b in bands)))
    lines += ["    ]", "}", ""]
    out.write_text("\n".join(lines))
    print("wrote %s: %d flags, skipped %s" % (out, len(entries), skipped or "none"), file=sys.stderr)


if __name__ == "__main__":
    main()
