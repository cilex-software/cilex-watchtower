#!/usr/bin/env python3
import sys, re, statistics as st

path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/wallperf_full.log"
LABEL = {10:"10m",30:"30m",60:"1h",120:"2h",1440:"1d",2880:"2d"}
ORDER = [10,30,60,120,1440,2880]

meta = {}
warm = None
# rows[(offMin,dir)][iter] = (lat, status, kind)
rows = {}
for raw in open(path, errors="replace"):
    line = raw.strip()
    if "WALLPERF" not in line: continue
    line = line[line.index("WALLPERF"):]
    f = line.split(",")
    if f[1] == "META":
        for kv in f[2:]:
            if "=" in kv: k,v = kv.split("=",1); meta[k]=v
        continue
    if f[1] == "WARMUP":
        warm = (f[2], f[3]); continue
    if f[1] == "DONE":
        meta["done"]=f[2].split("=")[-1]; continue
    if f[1] in ("seek","reopen"):
        kind=f[1]; offMin=int(f[2]); d=f[3]; it=int(f[4]); lat=int(f[5]); status=f[6]
        rows.setdefault((offMin,d),{})[it]=(lat,status,kind)

iters = int(meta.get("iters","20"))
print("## Meta")
for k in ("cams","iters","steps","done","baseSmall","baseBig"):
    if k in meta: print(f"- {k}: {meta[k]}")
if warm: print(f"- warmup (initial composite cold-start): {warm[1]} [{warm[0]}]")
print()

# ---- per-iteration matrix ----
cols = []
for o in ORDER:
    for d in ("FF","RW"):
        if (o,d) in rows: cols.append((o,d))
hdr = "| iter | " + " | ".join(f"{LABEL[o]} {d}" for o,d in cols) + " |"
sep = "|------|" + "|".join("------" for _ in cols) + "|"
print("## Per-iteration latency (ms) — TIMEOUT/FAIL flagged")
print(hdr); print(sep)
for it in range(1, iters+1):
    cells=[]
    for o,d in cols:
        v = rows.get((o,d),{}).get(it)
        if v is None: cells.append("·")
        else:
            lat,status,kind = v
            cells.append(f"{lat}" if status=="OK" else f"{lat}!{status[:2]}")
    print(f"| {it} | " + " | ".join(cells) + " |")
print()

# ---- summary ----
def pct(xs,p):
    xs=sorted(xs);
    if not xs: return 0
    i=min(len(xs)-1, int(round((p/100)*(len(xs)-1)))); return xs[i]
print("## Summary per offset × direction (OK samples)")
print("| offset | dir | kind | n_ok | n_to | min | median | mean | p90 | max |")
print("|--------|-----|------|------|------|-----|--------|------|-----|-----|")
for o,d in cols:
    data=rows[(o,d)]
    ok=[v[0] for v in data.values() if v[1]=="OK"]
    to=sum(1 for v in data.values() if v[1]!="OK")
    kind=next(iter(data.values()))[2]
    if ok:
        print(f"| {LABEL[o]} | {d} | {kind} | {len(ok)} | {to} | {min(ok)} | {int(st.median(ok))} | {int(st.mean(ok))} | {pct(ok,90)} | {max(ok)} |")
    else:
        print(f"| {LABEL[o]} | {d} | {kind} | 0 | {to} | - | - | - | - | - |")
print()

# ---- cold vs warm (in-stream seeks) ----
print("## Cold vs warm (in-stream seeks)")
print("First visit to a region = cold (composite on demand); revisits = warm (cached).")
seek_first=[]; seek_rest=[]
for (o,d),data in rows.items():
    if next(iter(data.values()))[2]!="seek": continue
    for it,v in data.items():
        if v[1]!="OK": continue
        (seek_first if it==1 else seek_rest).append(v[0])
if seek_first: print(f"- cold (iter 1): n={len(seek_first)} median={int(st.median(seek_first))}ms mean={int(st.mean(seek_first))}ms max={max(seek_first)}ms")
if seek_rest:  print(f"- warm (iter 2+): n={len(seek_rest)} median={int(st.median(seek_rest))}ms mean={int(st.mean(seek_rest))}ms max={max(seek_rest)}ms")
reop=[v[0] for data in rows.values() for v in data.values() if v[2]=="reopen" and v[1]=="OK"]
reop_to=sum(1 for data in rows.values() for v in data.values() if v[2]=="reopen" and v[1]!="OK")
if reop: print(f"- re-open (1d/2d) OK: n={len(reop)} median={int(st.median(reop))}ms mean={int(st.mean(reop))}ms max={max(reop)}ms; stalls/timeouts={reop_to}")
