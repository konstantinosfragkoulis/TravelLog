#!/usr/bin/env python3
"""home-orbit-replica.py: reference measurements for home-shape and orbit rules.

Independent Python implementation of HomeShape geometry, TripConfidence
score/excursions, PresenceEvidence unknown gaps, and HomeOrbit clusters and
qualifying returns. It supports geometry/parity experiments; it does not run
the shipping Swift classifier.

Modes:
  store [STORE_PATH]          store analysis: baseline parity + expansion
                              measurements (K sweep, link-radius plateau, disc
                              radii, point-vs-shape eligibility iteration).
                              STORE_PATH must be a copy of the input store;
                              keep the original and its WAL together.
  probe LAT LON               print the resolved UC seed for a coordinate.

K variants (K = returns required in a 12-month window; d = km from home POINT):
  A  max(3, d/3)              distance-based return threshold
  B  3                        flat floor
  C  max(3, min(d/3, 12))     distance-capped at monthly cadence
  D  max(3, min(d/3, 6))      distance-capped at ~bimonthly cadence
  E  max(3, ceil(sqrt(d/3)))  sublinear distance term

Constants used by the replica: theta=2.0, T*=24h,
unknown gap 7d, return window 12h, dwell floor 30min, trailing window
12 months, D0=3 km/visit, link radius 1 km, disc radius
= cluster p90 floored at 1 km, D* = seed area radius floored at 1 km
(discs never change D*).
"""
import argparse
import datetime as dt
import json
import math
import os
import sqlite3
import struct
from collections import defaultdict

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GEOCODER = os.path.join(REPO, "TravelLog", "Resources", "Geocoder.sqlite")

KM_PER_DEG = 6371.0088 * math.pi / 180.0
THETA = 2.0
TSTAR_HOURS = 24.0
UNKNOWN_GAP_S = 7 * 24 * 3600.0
RETURN_WINDOW_S = 12 * 3600.0
DWELL_FLOOR_S = 30 * 60.0
TRAILING_WINDOW_S = 365.25 * 24 * 3600.0
D0_KM = 3.0
LINK_KM = 1.0
DISC_FLOOR_KM = 1.0

# ---------------------------------------------------------------- geometry

def parse_wkb(data):
    pos = [0]
    def u8():
        v = data[pos[0]]; pos[0] += 1; return v
    def u32(le):
        v = struct.unpack_from('<I' if le else '>I', data, pos[0])[0]; pos[0] += 4; return v
    def f64(le):
        v = struct.unpack_from('<d' if le else '>d', data, pos[0])[0]; pos[0] += 8; return v
    def ring(le):
        n = u32(le)
        return [(f64(le), f64(le)) for _ in range(n)]  # (lon, lat)
    def polygon(le):
        n = u32(le)
        return [ring(le) for _ in range(n)]
    le = u8() == 1
    t = u32(le)
    if t == 3:
        return [polygon(le)]
    if t == 6:
        n = u32(le)
        polys = []
        for _ in range(n):
            le2 = u8() == 1
            t2 = u32(le2)
            assert t2 == 3, t2
            polys.append(polygon(le2))
        return polys
    raise ValueError(f"wkb type {t}")


def ring_contains(ring, lon, lat):
    n = len(ring)
    if n < 3:
        return False
    inside = False
    j = n - 1
    for i in range(n):
        xi, yi = ring[i]; xj, yj = ring[j]
        if (yi > lat) != (yj > lat) and lon < (xj - xi) * (lat - yi) / (yj - yi + 1e-30) + xi:
            inside = not inside
        j = i
    return inside


def _dist_seg(ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    l2 = dx * dx + dy * dy
    if l2 == 0:
        return math.hypot(ax, ay)
    t = max(0.0, min(1.0, -(ax * dx + ay * dy) / l2))
    return math.hypot(ax + t * dx, ay + t * dy)


def great_circle_km(lat1, lon1, lat2, lon2):
    p = math.pi / 180.0
    a = (math.sin((lat2 - lat1) * p / 2) ** 2 +
         math.cos(lat1 * p) * math.cos(lat2 * p) * math.sin((lon2 - lon1) * p / 2) ** 2)
    return 2 * 6371.0088 * math.asin(math.sqrt(min(1.0, a)))


class Seed:
    """A home seed: urban-centre polygon set or a 1 km fallback disc.
    D* = area radius floored at 1 km, from the SEED alone."""

    def __init__(self, polys, area_km2, label, home_lat, home_lon):
        self.polys = polys          # None for the fallback disc
        self.label = label
        self.home = (home_lat, home_lon)
        self.dstar = max(1.0, math.sqrt(area_km2 / math.pi))

    @property
    def is_disc(self):
        return self.polys is None

    def contains(self, lat, lon):
        if self.polys is None:
            return great_circle_km(self.home[0], self.home[1], lat, lon) <= 1.0
        for poly in self.polys:
            if poly and ring_contains(poly[0], lon, lat):
                if not any(ring_contains(h, lon, lat) for h in poly[1:]):
                    return True
        return False

    def distance_km(self, lat, lon):
        if self.contains(lat, lon):
            return 0.0
        if self.polys is None:
            return max(0.0, great_circle_km(self.home[0], self.home[1], lat, lon) - 1.0)
        kx = KM_PER_DEG * math.cos(lat * math.pi / 180.0)
        ky = KM_PER_DEG
        best = float('inf')
        for poly in self.polys:
            ring = poly[0]
            n = len(ring)
            for i in range(n):
                a, b = ring[i], ring[(i + 1) % n]
                best = min(best, _dist_seg((a[0] - lon) * kx, (a[1] - lat) * ky,
                                           (b[0] - lon) * kx, (b[1] - lat) * ky))
        return best


def resolve_seed(lat, lon):
    """Point -> containing urban centre from the bundled geocoder, else a
    1 km disc. Mirrors GeocodeResolver.urbanCentre + HomeShape.fallbackDisc."""
    db = sqlite3.connect(f"file:{GEOCODER}?mode=ro&immutable=1", uri=True)
    try:
        rows = db.execute(
            """SELECT uc.uc_id, uc.name, uc.area_km2, uc.wkb
               FROM urban_centre_rtree r JOIN urban_centre uc ON uc.uc_id = r.uc_id
               WHERE r.min_lon <= ? AND r.max_lon >= ?
                 AND r.min_lat <= ? AND r.max_lat >= ?""",
            (lon, lon, lat, lat)).fetchall()
    finally:
        db.close()
    best = None
    for uc_id, name, area, wkb in rows:
        polys = parse_wkb(wkb)
        probe = Seed(polys, area, name or f"#{uc_id}", lat, lon)
        if probe.contains(lat, lon) and (best is None or area < best[0]):
            best = (area, uc_id, name, polys)
    if best is None:
        return Seed(None, math.pi * 1.0 ** 2, "fallback-disc", lat, lon)
    area, uc_id, name, polys = best
    return Seed(polys, area, f"{name or '?'} #{uc_id}", lat, lon)


# ---------------------------------------------------------------- score

def score(d_km, t_hours, dstar):
    if d_km <= 0 or dstar <= 0:
        return 0.0
    return math.log2(1 + d_km / dstar) * (1 + math.log2(1 + max(0.0, t_hours) / TSTAR_HOURS))


# ---------------------------------------------------------------- stays / excursions
# A stay everywhere below: dict(id, start, end, lat, lon, transit, live)
# start/end are epoch seconds (any epoch, must be uniform).

def bracketed_excursions(stays, inside_fn):
    """TripConfidence.excursions: maximal runs of outside stays, split at
    inside stays and at >7d unknown gaps. inside_fn(stay) -> bool.
    Returns dict(stays, departure, ret): `departure` is the inside stay with
    the latest end before the run when the gap to the run's first start is
    observed (<= 7d; an unknown closure forgets it), `ret` the inside stay
    whose start closed the run (None for an unknown gap or end of input)."""
    out, cur, reach, dep, last_home = [], [], None, None, None

    def close(ret):
        if cur:
            out.append({"stays": cur, "departure": dep, "ret": ret})

    for s in stays:
        end = max(s["start"], s["end"])
        if reach is not None and (s["start"] - reach) > UNKNOWN_GAP_S:
            close(None)
            cur, reach, dep, last_home = [], None, None, None
        if inside_fn(s):
            close(s)
            cur, reach, dep = [], None, None
            if last_home is None or end >= max(last_home["start"], last_home["end"]):
                last_home = s
        else:
            if not cur and last_home is not None and \
                    s["start"] - max(last_home["start"], last_home["end"]) <= UNKNOWN_GAP_S:
                dep = last_home
            cur.append(s)
            reach = end if reach is None else max(reach, end)
    close(None)
    return out


def excursions(stays, inside_fn):
    """The runs alone, for confidence scoring (brackets never change them)."""
    return [e["stays"] for e in bracketed_excursions(stays, inside_fn)]


def run_metrics(run, dist_fn):
    anchors = [s for s in run if not s["transit"]] or run
    t_hours = (max(max(s["start"], s["end"]) for s in run) - run[0]["start"]) / 3600.0
    d_km = max(dist_fn(s["lat"], s["lon"]) for s in anchors)
    return d_km, t_hours


# ---------------------------------------------------------------- expansion

def cluster_stays(stays, link_km=LINK_KM):
    """Single-linkage union-find over live, non-transit stays.
    Returns list of clusters: dict(center=(lat,lon), radius_km, members)."""
    pts = [s for s in stays if s["live"] and not s["transit"]]
    pts.sort(key=lambda s: (s["start"], s["id"]))
    n = len(pts)
    parent = list(range(n))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    # Grid-bucket neighbours so this is not O(n^2) on big stores.
    cell = link_km / KM_PER_DEG
    grid = defaultdict(list)
    for i, s in enumerate(pts):
        grid[(int(s["lat"] / cell), int(s["lon"] / (cell / max(0.2, math.cos(s["lat"] * math.pi / 180.0)))))].append(i)
    for (gy, gx), members in grid.items():
        neigh = []
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                neigh.extend(grid.get((gy + dy, gx + dx), []))
        for i in members:
            si = pts[i]
            for j in neigh:
                if j <= i:
                    continue
                sj = pts[j]
                if great_circle_km(si["lat"], si["lon"], sj["lat"], sj["lon"]) <= link_km:
                    ri, rj = find(i), find(j)
                    if ri != rj:
                        parent[max(ri, rj)] = min(ri, rj)

    groups = defaultdict(list)
    for i in range(n):
        groups[find(i)].append(pts[i])
    clusters = []
    for members in groups.values():
        lat = sum(s["lat"] for s in members) / len(members)
        lon = sum(s["lon"] for s in members) / len(members)  # fixture nowhere near antimeridian
        dists = sorted(great_circle_km(lat, lon, s["lat"], s["lon"]) for s in members)
        p90 = dists[min(len(dists) - 1, int(math.ceil(0.9 * len(dists))) - 1)] if dists else 0.0
        clusters.append({"lat": lat, "lon": lon,
                         "radius_km": max(DISC_FLOOR_KM, p90),
                         "members": members})
    return clusters


def witnessed_return(exc):
    """Clause (b): live inside stays bracket the run on both sides, neither
    overlaps an away observation, and home is reached <= 12h after the run's
    first start. Returns the home arrival, or None."""
    run, dep, ret = exc["stays"], exc["departure"], exc["ret"]
    if dep is None or ret is None or not dep["live"] or not ret["live"]:
        return None
    away_end = max(max(s["start"], s["end"]) for s in run)
    if max(dep["start"], dep["end"]) > run[0]["start"] or away_end > ret["start"]:
        return None
    if ret["start"] - run[0]["start"] > RETURN_WINDOW_S:
        return None
    return ret["start"]


def qualifying_returns(cluster, seed_excursions):
    """Bracketed excursions (from bracketed_excursions) that (a)
    reached the cluster, (b) went home the same day (witnessed_return),
    (c) are not transit-only, (d) dwelled >= 30 min at the cluster.
    Returns sorted list of return times (the witnessed home arrival)."""
    times = []
    for exc in seed_excursions:
        run = exc["stays"]
        returned = witnessed_return(exc)
        if returned is None:
            continue                                    # (b)
        if all(s["transit"] for s in run):
            continue                                    # (c)
        members = [s for s in run
                   if s["live"] and not s["transit"]
                   and great_circle_km(cluster["lat"], cluster["lon"], s["lat"], s["lon"]) <= cluster["radius_km"]]
        if not members:
            continue                                    # (a)
        dwell = sum(max(s["start"], s["end"]) - s["start"] for s in members)
        if dwell < DWELL_FLOOR_S:
            continue                                    # (d)
        times.append(returned)
    return sorted(times)


K_VARIANTS = {
    "A": lambda d: max(3, d / D0_KM),
    "B": lambda d: 3,
    "C": lambda d: max(3, min(d / D0_KM, 12)),
    "D": lambda d: max(3, min(d / D0_KM, 6)),
    "E": lambda d: max(3, math.ceil(math.sqrt(d / D0_KM))),
}


def validity_intervals(return_times, k):
    """Evidence-span validity:
    tuple (r_i .. r_{i+K-1}) within 12 months -> valid on
    [r_i - 12h, r_{i+K-1} + 12mo]. Backward edge = the pattern's own start
    (never claims pre-pattern history); forward edge = forgetting from the
    LAST return (a sparse-but-alive routine never expires mid-pattern)."""
    k = int(math.ceil(k))
    if k <= 0 or len(return_times) < k:
        return []
    out = []
    for i in range(len(return_times) - k + 1):
        lo, hi = return_times[i], return_times[i + k - 1]
        if hi - lo <= TRAILING_WINDOW_S:
            out.append((lo - RETURN_WINDOW_S, hi + TRAILING_WINDOW_S))
    if not out:
        return []
    out.sort()
    merged = [out[0]]
    for a, b in out[1:]:
        if a <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], b))
        else:
            merged.append((a, b))
    return merged


def valid_at(intervals, t):
    return any(a <= t <= b for a, b in intervals)


class Membership:
    """seed ∪ time-valid discs for ONE home. D* is the seed's alone."""

    def __init__(self, seed, discs):
        self.seed = seed
        self.discs = discs   # list of (lat, lon, radius_km, intervals)

    def contains(self, lat, lon, t):
        if self.seed.contains(lat, lon):
            return True
        for dlat, dlon, r, iv in self.discs:
            if valid_at(iv, t) and great_circle_km(dlat, dlon, lat, lon) <= r:
                return True
        return False

    def distance_km(self, lat, lon, t):
        d = self.seed.distance_km(lat, lon)
        for dlat, dlon, r, iv in self.discs:
            if valid_at(iv, t):
                d = min(d, max(0.0, great_circle_km(dlat, dlon, lat, lon) - r))
        return d


def derive_discs(stays, seed, k_fn, link_km=LINK_KM, min_returns_probe=1):
    """One-shot disc derivation (evidence counted against SEED-ONLY
    excursions; eligibility gated on distance from the home POINT)."""
    seed_exc = bracketed_excursions(stays, lambda s: seed.contains(s["lat"], s["lon"]))
    discs, audit = [], []
    for c in cluster_stays(stays, link_km):
        if seed.contains(c["lat"], c["lon"]):
            continue
        d_point = great_circle_km(seed.home[0], seed.home[1], c["lat"], c["lon"])
        rt = qualifying_returns(c, seed_exc)
        if len(rt) >= min_returns_probe:
            k = k_fn(d_point)
            iv = validity_intervals(rt, k)
            audit.append((c, d_point, rt, k, iv))
            if iv:
                discs.append((c["lat"], c["lon"], c["radius_km"], iv))
    return discs, audit


# ---------------------------------------------------------------- store mode

def load_store(path):
    db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    rows = db.execute(
        """SELECT Z_PK, ZSTARTTIME, ZENDTIME, ZCENTROIDLATITUDE, ZCENTROIDLONGITUDE,
                  ZISAIRPORT, ZTRIP, COALESCE(ZLOCALITY, ''), COALESCE(ZISLANDNAME, ''),
                  COALESCE(ZSOURCERAW, '')
           FROM ZSTAY ORDER BY ZSTARTTIME, ZENDTIME""").fetchall()
    stays = [{
        "id": r[0], "start": r[1], "end": max(r[1], r[2]),
        "lat": r[3], "lon": r[4], "transit": bool(r[5]), "trip": r[6],
        "place": r[7] or r[8] or "?",
        # liveSLC = pure live; merged = live evidence folded with an import —
        # both carry an observed return, so both anchor expansion evidence.
        "live": r[9] in ("liveSLC", "merged"),
    } for r in rows]
    trips = {pk: name for pk, name in db.execute(
        "SELECT Z_PK, COALESCE(ZCUSTOMNAME, ZAIGENERATEDTITLE, ZDESTINATIONSUMMARY, '?') FROM ZTRIP")}
    home = db.execute(
        "SELECT ZLATITUDE, ZLONGITUDE FROM ZHOME ORDER BY ZSTARTEDAT LIMIT 1").fetchone()
    db.close()
    return stays, trips, home


def store_mode(path):
    stays, trips, home = load_store(path)
    src = defaultdict(int)
    for s in stays:
        src[("live" if s["live"] else "imported")] += 1
    seed = resolve_seed(home[0], home[1])
    print(f"store: {len(stays)} stays ({dict(src)}), {len(trips)} trips")
    print(f"seed: {seed.label}, D* = {seed.dstar:.2f} km")

    # ---- baseline parity (must match the shipped acceptance numbers) ----
    base_exc = excursions(stays, lambda s: seed.contains(s["lat"], s["lon"]))
    scored = []
    for run in base_exc:
        d, t = run_metrics(run, seed.distance_km)
        scored.append((run, d, t, score(d, t, seed.dstar)))
    trip_best = defaultdict(float)
    phantoms = []
    for run, d, t, sc in scored:
        tset = {s["trip"] for s in run if s["trip"] is not None}
        if tset:
            for tp in tset:
                trip_best[tp] = max(trip_best[tp], sc)
        else:
            phantoms.append(sc)
    ok = sum(1 for tp in trips if trip_best.get(tp, 0.0) >= THETA)
    print(f"\nBASELINE: excursions {len(scored)}, trips >= theta {ok}/{len(trips)}, "
          f"min trip score {min((trip_best.get(tp, 0.0) for tp in trips), default=0):.2f}, "
          f"phantom max {max(phantoms, default=0):.2f} (n={len(phantoms)})")

    # ---- expansion: K sweep at the default link radius ----
    print(f"\nK SWEEP (link {LINK_KM} km, dwell {DWELL_FLOOR_S/60:.0f} min, live-only anchors):")
    baseline_verdicts = {tp: trip_best.get(tp, 0.0) >= THETA for tp in trips}
    for name, k_fn in K_VARIANTS.items():
        discs, audit = derive_discs(stays, seed, k_fn)
        mem = Membership(seed, discs)
        exc2 = excursions(stays, lambda s: mem.contains(s["lat"], s["lon"], s["start"]))
        tb2 = defaultdict(float)
        ph2 = 0
        for run in exc2:
            d = max(mem.distance_km(s["lat"], s["lon"], s["start"])
                    for s in ([x for x in run if not x["transit"]] or run))
            t = (max(max(s["start"], s["end"]) for s in run) - run[0]["start"]) / 3600.0
            sc = score(d, t, seed.dstar)
            tset = {s["trip"] for s in run if s["trip"] is not None}
            for tp in tset:
                tb2[tp] = max(tb2[tp], sc)
            if not tset and sc >= THETA:
                ph2 += 1
        changed = [tp for tp in trips if (tb2.get(tp, 0.0) >= THETA) != baseline_verdicts[tp]]
        print(f"  K={name}: discs {len(discs):3d}, trips changed verdict {len(changed)}, "
              f"phantoms>=theta {ph2}")
        for c, d_point, rt, k, iv in sorted(audit, key=lambda a: -len(a[2]))[:6]:
            place = defaultdict(int)
            for m in c["members"]:
                place[m["place"]] += 1
            top = max(place.items(), key=lambda kv: kv[1])[0]
            print(f"      {top[:22]:22s} d_point {d_point:6.1f} km  returns {len(rt):2d}  "
                  f"K {k:5.1f}  admitted {'YES' if iv else 'no '}  r {c['radius_km']:.2f} km")
        if changed:
            print(f"      CHANGED: {[(tp, trips[tp][:20]) for tp in changed]}")

    # ---- link-radius plateau ----
    print("\nLINK-RADIUS PLATEAU (K=A):")
    for link in (0.5, 0.75, 1.0, 1.5, 2.0):
        discs, audit = derive_discs(stays, seed, K_VARIANTS["A"], link_km=link)
        radii = [c["radius_km"] for c, *_ in [(a[0],) for a in audit if a[4]]]
        print(f"  link {link:4.2f} km: clusters {len(cluster_stays(stays, link)):4d}, "
              f"admitted discs {len(discs)}, max disc radius {max(radii, default=0):.2f} km")

    # ---- point-vs-shape eligibility iteration (UC seed) ----
    print("\nELIGIBILITY ITERATION (K=B flat-3 = the most admissive; 5 rounds):")
    for gate in ("point", "shape"):
        mem = Membership(seed, [])
        counts = []
        for _ in range(5):
            seed_exc = bracketed_excursions(stays, lambda s: mem.contains(s["lat"], s["lon"], s["start"]))
            discs = []
            for c in cluster_stays(stays):
                if mem.contains(c["lat"], c["lon"], c["members"][0]["start"]):
                    continue
                if gate == "point":
                    d_gate = great_circle_km(seed.home[0], seed.home[1], c["lat"], c["lon"])
                else:
                    d_gate = mem.distance_km(c["lat"], c["lon"], c["members"][0]["start"])
                rt = qualifying_returns(c, seed_exc)
                iv = validity_intervals(rt, K_VARIANTS["B"](d_gate))
                if iv:
                    discs.append((c["lat"], c["lon"], c["radius_km"], iv))
            mem = Membership(seed, discs)
            counts.append(len(discs))
        print(f"  gate from {gate}: discs per round {counts}")

    # ---- corridor return diagnostics ----
    print("\nCORRIDOR RETURNS (dwell-floor denials at K=B):")
    seed_exc = bracketed_excursions(stays, lambda s: seed.contains(s["lat"], s["lon"]))
    for c in cluster_stays(stays):
        place = defaultdict(int)
        for m in c["members"]:
            place[m["place"]] += 1
        top = max(place.items(), key=lambda kv: kv[1])[0]
        no_d = []
        for exc in seed_exc:
            run = exc["stays"]
            if witnessed_return(exc) is None or all(s["transit"] for s in run):
                continue
            ms = [s for s in run if s["live"] and not s["transit"]
                  and great_circle_km(c["lat"], c["lon"], s["lat"], s["lon"]) <= c["radius_km"]]
            if ms:
                no_d.append(sum(max(s["start"], s["end"]) - s["start"] for s in ms))
        with_d = qualifying_returns(c, seed_exc)
        print(f"  {top[:12]:12s} returns without (d): {len(no_d):2d}  with (d): {len(with_d):2d}  "
              f"dwells(min): {[round(x/60) for x in sorted(no_d)[:8]]}")


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="mode", required=True)
    st = sub.add_parser("store")
    st.add_argument("path")
    pr = sub.add_parser("probe")
    pr.add_argument("lat", type=float)
    pr.add_argument("lon", type=float)
    args = ap.parse_args()
    if args.mode == "store":
        store_mode(args.path)
    else:
        s = resolve_seed(args.lat, args.lon)
        print(f"{s.label}  D* {s.dstar:.2f} km  disc={s.is_disc}")


if __name__ == "__main__":
    main()
