#!/usr/bin/env python3
"""Shared analysis for the paired reconnect study. BOTH stations run THIS file.

    python3 report.py booth-8h.jsonl      > booth-report.md
    python3 report.py srv-8h.jsonl        > srv-report.md
    python3 report.py booth-8h.jsonl srv-8h.jsonl > paired.md     # §5/§6 too

Exists so neither station computes a percentile its own way and reports the
difference as a finding. Percentile method, episode definition, rank
correlation and the NA policy are fixed here, once, for both of us.

Conventions, fixed:
  * percentile = nearest-rank on the sorted sample (p95 of n=960 is element 912)
  * "NA" is excluded from every statistic and counted separately — never
    coerced to 0
  * episode = >= 3 consecutive samples with est_cv < 0.6 * that file's own
    median est_cv (self-normalised, so different fleet sizes cannot confound)
  * Spearman, not Pearson: these are counts with heavy tails
"""
import bisect, json, math, sys, time
from collections import Counter

NA = "NA"


def load(p):
    rows = []
    for line in open(p, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        if "sample_error" in d:
            continue
        rows.append(flatten(d))
    return rows


def flatten(d, pre=""):
    out = {}
    for k, v in d.items():
        key = pre + k
        if isinstance(v, dict):
            out.update(flatten(v, key + "."))
        elif isinstance(v, list):
            for i, x in enumerate(v):
                if isinstance(x, dict):
                    out.update(flatten(x, "%s%d." % (key, i)))
        else:
            out[key] = v
    return out


def nums(rows, col):
    v, na = [], 0
    for r in rows:
        x = r.get(col, None)
        if x is None or x == NA:
            na += 1
            continue
        try:
            v.append(float(x))
        except (TypeError, ValueError):
            na += 1
    return v, na


def pct(sorted_v, p):
    if not sorted_v:
        return None
    return sorted_v[min(len(sorted_v) - 1, int(math.ceil(p * len(sorted_v))) - 1)]


def describe(rows, col):
    v, na = nums(rows, col)
    if not v:
        return None
    s = sorted(v)
    n = len(s)
    mean = sum(s) / n
    sd = math.sqrt(sum((x - mean) ** 2 for x in s) / n) if n > 1 else 0.0
    return dict(col=col, n=n, na=na, mean=mean, sd=sd, p25=pct(s, .25),
                med=pct(s, .50), p75=pct(s, .75), p95=pct(s, .95),
                mn=s[0], mx=s[-1])


def table(rows, cols):
    print("| column | n | NA | mean | sd | p25 | median | p75 | p95 | min | max |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
    for c in cols:
        d = describe(rows, c)
        if not d:
            print("| `%s` | 0 | %d | — | — | — | — | — | — | — | — |" % (c, len(rows)))
            continue
        print("| `%(col)s` | %(n)d | %(na)d | %(mean).3f | %(sd).3f | %(p25).3f | "
              "**%(med).3f** | %(p75).3f | %(p95).3f | %(mn).3f | %(mx).3f |" % d)


def episodes(rows, col="est_cv", frac=0.6, minlen=3):
    v, _ = nums(rows, col)
    if not v:
        return [], None
    med = pct(sorted(v), .50)
    thr = frac * med
    out, run = [], []
    for r in rows:
        x = r.get(col)
        low = x not in (None, NA) and float(x) < thr
        if low:
            run.append(r)
        else:
            if len(run) >= minlen:
                out.append(run)
            run = []
    if len(run) >= minlen:
        out.append(run)
    return out, thr


def ranks(v):
    order = sorted(range(len(v)), key=lambda i: v[i])
    rk = [0.0] * len(v)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and v[order[j + 1]] == v[order[i]]:
            j += 1
        avg = (i + j) / 2.0 + 1
        for k in range(i, j + 1):
            rk[order[k]] = avg
        i = j + 1
    return rk


def spearman(a, b):
    pairs = [(x, y) for x, y in zip(a, b)
             if x not in (None, NA) and y not in (None, NA)]
    if len(pairs) < 3:
        return None, 0
    ra, rb = ranks([p[0] for p in pairs]), ranks([p[1] for p in pairs])
    n = len(pairs)
    ma, mb = sum(ra) / n, sum(rb) / n
    num = sum((x - ma) * (y - mb) for x, y in zip(ra, rb))
    den = math.sqrt(sum((x - ma) ** 2 for x in ra) * sum((y - mb) ** 2 for y in rb))
    return (num / den if den else None), n


def report(path, rows):
    print("# %s — n=%d" % (path, len(rows)))
    if rows:
        print("\nwindow: `%s` → `%s`\n" % (rows[0].get("ts_utc"), rows[-1].get("ts_utc")))
    print("## §2 Distributions\n")
    skip = {"ts_utc", "label", "host"}
    cols, seen = [], set()
    for r in rows:
        for k, v in r.items():
            if k in skip or k in seen:
                continue
            try:
                float(v)
            except (TypeError, ValueError):
                if v != NA:
                    continue
            seen.add(k)
            cols.append(k)
    table(rows, cols)

    if any("est_cv" in r for r in rows):
        eps, thr = episodes(rows)
        print("\n## §4 Episodes  (>=3 consecutive samples, est_cv < %.1f)\n" % (thr or 0))
        if not eps:
            print("None.")
        for e in eps:
            print("- `%s` → `%s`  (%d samples, min est_cv=%s)" %
                  (e[0]["ts_utc"], e[-1]["ts_utc"], len(e),
                   min(x.get("est_cv") for x in e)))

    rc = [r.get("reconnects_interval") for r in rows]
    have = [x for x in rc if x not in (None, NA)]
    print("\n## §3 Reconnect census\n")
    if not have:
        print("`reconnects_interval` is NA for every sample — journal unavailable. "
              "Not reported as zero.")
    else:
        tot = sum(float(x) for x in have)
        hours = max(1e-9, len(rows) * 30 / 3600.0)
        print("- total events: **%d**\n- per hour: **%.1f**\n- samples with >0: %d/%d"
              % (tot, tot / hours, sum(1 for x in have if float(x) > 0), len(rows)))


def paired(a_rows, b_rows):
    print("\n## §5/§6 Paired\n")
    # Nearest-sample match within +/-15 s, NOT minute truncation.
    # The two stations' clocks differ (booth measured +1.827 s against
    # time.windows.com, server room +0.002 s). Truncating to the minute puts a
    # booth sample stamped :00.5 into the previous minute on the server's clock
    # and silently drops ~6 % of pairs at boundaries. Nearest-match is immune to
    # any skew smaller than half the cadence and needs no correction constant.
    import calendar
    def epoch(t):
        return calendar.timegm(time.strptime(t, "%Y-%m-%dT%H:%M:%SZ"))
    bs = sorted(((epoch(r["ts_utc"]), r) for r in b_rows if "ts_utc" in r),
                key=lambda x: x[0])
    bt = [x[0] for x in bs]
    pa, pb = [], []
    for r in a_rows:
        if "ts_utc" not in r:
            continue
        t = epoch(r["ts_utc"])
        i = bisect.bisect_left(bt, t)
        cand = [j for j in (i - 1, i) if 0 <= j < len(bt)]
        if not cand:
            continue
        j = min(cand, key=lambda j: abs(bt[j] - t))
        if abs(bt[j] - t) > 15:
            continue
        m = bs[j][1]
        x, y = r.get("reconnects_interval"), m.get("go2rtc.detach")
        if x not in (None, NA) and y not in (None, NA):
            pa.append(float(x)); pb.append(float(y))
    rho, n = spearman(pa, pb)
    print("joined minutes: **%d**" % len(pa))
    if rho is None:
        print("\nSpearman: insufficient paired data (needs booth `reconnects_interval` "
              "and server `go2rtc.detach`).")
    else:
        print("\nSpearman rho(booth reconnects, server detach) = **%.3f** (n=%d)" % (rho, n))
        print("\n> High rho = the drops reached the network. Near zero with booth "
              "reconnects > 0 = **the drop never left the client**.")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(2)
    files = sys.argv[1:]
    sets = []
    for p in files:
        rows = load(p)
        report(p, rows)
        sets.append(rows)
        print()
    if len(sets) == 2:
        booth = 0 if any("est_cv" in r for r in sets[0]) else 1
        paired(sets[booth], sets[1 - booth])
