#!/usr/bin/env python3
"""Report for the rock-n-roll soak: per group / action stats with outliers visible, plus the hand notes."""
import json, statistics, collections, sys, os
OUT = sys.argv[1] if len(sys.argv) > 1 else "/home/cilex-vision/projects/cilex-watchtower/docs/perf/2026-09-12-rocknroll-soak"
rows = [json.loads(l) for l in open(f"{OUT}/rows.jsonl")] if os.path.exists(f"{OUT}/rows.jsonl") else []
notes = [json.loads(l) for l in open(f"{OUT}/notes.jsonl")] if os.path.exists(f"{OUT}/notes.jsonl") else []
def q(v, f): v = sorted(v); return v[min(len(v) - 1, max(0, int(len(v) * f) - 1))] if v else None
print("# Rock-n-roll soak — %s → %s, %d runs\n" % (rows[0]["ts"][11:16] if rows else "?", rows[-1]["ts"][11:16] if rows else "?", len(rows)))
print("| group | action | n | over target | outliers (crash / fail / no metric / ≥2.5× median) | primary median | p90 | max | target | builds |\n\nPrimary metric per action: the first `[TAG] key=` the harness prints for that action (playback = the day click's own first frame; live = `playing dt`; wall = `first_frame dt`; stress = an error/violation count). Outlier = crash, harness FAIL, no metric, over the target, or over 2.5× the action's running median.\n")
print("|---|---|---|---|---|---|---|---|---|---|")
byg = collections.defaultdict(lambda: collections.defaultdict(list))
for r in rows: byg[r["group"]][r["action"]].append(r)
def split_live(rs):
    """LIVE open rows split by the recorded target_lit flag: on-page / off-page / unknown."""
    parts = []
    for name, cond in (("on-page", lambda r: r.get("target_lit") is True), ("off-page", lambda r: r.get("target_lit") is False), ("unknown-page", lambda r: r.get("target_lit") is None)):
        sub = [r for r in rs if cond(r)]
        if sub: parts.append((name, sub))
    return parts
def emit(g, a, rs):
    v = [r["primary"] for r in rs if isinstance(r.get("primary"), (int, float))]
    over = [r for r in rs if (r.get("reason") or "").startswith("over_target")]
    out = [r for r in rs if r["outcome"] == "outlier" and not (r.get("reason") or "").startswith("over_target")]
    fmt = lambda x: "-" if x is None else ("%d" % x if x >= 10 else "%.1f" % x)
    tgt = next((x.get("target") for x in rs if x.get("target") is not None), None)
    print("| %s | %s | %d | %d | **%d** | %s | %s | %s | %s | %s |" % (g, a, len(rs), len(over), len(out), fmt(statistics.median(v)) if v else "-", fmt(q(v, .9)), fmt(max(v)) if v else "-", tgt if tgt is not None else "median×2.5", ",".join(sorted({r["build"].split("+")[0] for r in rs}))))
for g in sorted(byg):
    for a in sorted(byg[g]):
        rs = byg[g][a]
        if g == "LIVE" and a.startswith("live_open"):
            for suffix, sub in split_live(rs): emit(g, "%s (%s)" % (a, suffix), sub)
        else:
            emit(g, a, rs)
print("\n## Outliers (reason → count), by action\n")
kinds = collections.Counter((r["action"], (r.get("reason") or "").split(":")[0]) for r in rows if r["outcome"] == "outlier")
for (a, k), c in kinds.most_common(): print("- `%s` — %s × %d" % (a, k, c))
print("\n## Every outlier\n\n| n | time | action | reason | primary | params | log |\n|---|---|---|---|---|---|---|")
for r in rows:
    if r["outcome"] == "outlier": print("| %d | %s | %s | %s | %s | %s | %s |" % (r["n"], r["ts"][11:19], r["action"], r.get("reason"), r.get("primary"), json.dumps(r.get("params"), ensure_ascii=False)[:60], r.get("log", "")))
if notes:
    print("\n## Causes found and fixes applied during the run\n")
    for nt in notes: print("- **%s** (%s): %s — fix: %s%s" % (nt.get("kind"), nt.get("ts", "")[11:16], nt.get("cause"), nt.get("fix"), (" (`%s`)" % nt["commit"]) if nt.get("commit") else ""))
