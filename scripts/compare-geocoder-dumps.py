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

import sys, collections
F = ["iso", "country", "admin", "metro", "locality", "sublocality", "island"]
def load(p):
    d = {}
    for line in open(p, encoding="utf-8"):
        c = line.rstrip("\n").split("\t")
        d[c[0]] = c
    return d
a, b = load(sys.argv[1]), load(sys.argv[2])
assert a.keys() == b.keys(), "label sets differ"
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
show = sys.argv[3:] or []
for spec in show:
    g, f, kind, n = spec.split(",")
    print(f"\n-- {g} {f} {kind} (first {n})")
    for k, la, lo, x, y in examples[(g, f, kind)][: int(n)]:
        print(f"   {k:16s} {la:>10s},{lo:<11s} {x!r:32s} -> {y!r}")
