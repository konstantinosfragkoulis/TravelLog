#!/usr/bin/env python3
"""
Compare two outputs of TravelLogTests/GeocoderSnapshotDumpTests (the current
database and a rebuild candidate resolved over the same coordinate list).
Stdlib only. Labels group by their prefix before ":" or a trailing number.

    python3 scripts/compare-geocoder-dumps.py baseline.tsv candidate.tsv \
        [group,field,kind,count ...]      e.g. apt,island,lost,20

Fields: iso country admin metro locality sublocality island.
Kinds:  gained lost renamed.
"""

import argparse, collections, math
F = ["iso", "country", "admin", "metro", "locality", "sublocality", "island"]
def load(p):
    d = {}
    with open(p, encoding="utf-8") as rows:
        for number, line in enumerate(rows, 1):
            c = line.rstrip("\n").split("\t")
            where = f"{p}:{number}"
            if len(c) != 3 + len(F) or not c[0]:
                raise ValueError(f"{where}: expected a label, latitude, longitude and {len(F)} result fields")
            if c[0] in d:
                raise ValueError(f"{where}: duplicate label {c[0]!r}")
            try:
                lat, lon = map(float, c[1:3])
            except ValueError:
                raise ValueError(f"{where}: invalid coordinates {c[1:3]!r}") from None
            if not (math.isfinite(lat) and math.isfinite(lon)
                    and -90 <= lat <= 90 and -180 <= lon <= 180):
                raise ValueError(f"{where}: coordinates out of range {c[1:3]!r}")
            d[c[0]] = c
    if not d:
        raise ValueError(f"{p}: no probe rows")
    return d

def example_spec(spec):
    parts = spec.split(",")
    if len(parts) != 4:
        raise argparse.ArgumentTypeError("expected group,field,kind,count (e.g. apt,island,lost,20)")
    g, f, kind, n = parts
    if not g or f not in F or kind not in ("gained", "lost", "renamed"):
        raise argparse.ArgumentTypeError(f"invalid group, field or kind in {spec!r}; fields: {', '.join(F)}; kinds: gained, lost, renamed")
    try:
        if int(n) < 0:
            raise ValueError
    except ValueError:
        raise argparse.ArgumentTypeError("example count must be a non-negative integer") from None
    return parts

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("baseline", help="Baseline resolver TSV dump")
    parser.add_argument("candidate", help="Candidate resolver TSV dump")
    parser.add_argument("examples", nargs="*", type=example_spec, metavar="group,field,kind,count")
    args = parser.parse_args()
    try:
        a, b = load(args.baseline), load(args.candidate)
        if a.keys() != b.keys():
            raise ValueError("label sets differ")
        for k in a:
            if tuple(map(float, a[k][1:3])) != tuple(map(float, b[k][1:3])):
                raise ValueError(f"coordinates differ for label {k!r}: {a[k][1:3]!r} != {b[k][1:3]!r}")
    except (OSError, ValueError) as error:
        parser.error(str(error))
    groups = collections.defaultdict(lambda: collections.Counter())
    examples = collections.defaultdict(list)
    for k in a:
        g = k.split(":")[0].rstrip("0123456789")
        groups[g]["total"] += 1
        for i, f in enumerate(F):
            x, y = a[k][3 + i], b[k][3 + i]
            if x != y:
                kind = "gained" if not x else "lost" if not y else "renamed"
                groups[g][f"{f}:{kind}"] += 1
                examples[(g, f, kind)].append((k, a[k][1], a[k][2], x, y))
    for g, c in groups.items():
        print(f"\n== {g}: {c['total']:,} points")
        for key in sorted(k for k in c if k != "total"):
            print(f"   {key:22s} {c[key]:6,d}  ({100 * c[key] / c['total']:.2f}%)")
    for g, f, kind, n in args.examples:
        print(f"\n-- {g} {f} {kind} (first {n})")
        for k, la, lo, x, y in examples[(g, f, kind)][: int(n)]:
            print(f"   {k:16s} {la:>10s},{lo:<11s} {x!r:32s} -> {y!r}")

if __name__ == "__main__":
    main()
