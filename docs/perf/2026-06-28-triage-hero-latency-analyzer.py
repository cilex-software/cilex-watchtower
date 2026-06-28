#!/usr/bin/env python3
# Analyze the Triage-hero latency test: open latency, per-step seek latency + frozen rate, mem/CPU, spikes.
import re, csv, sys
import numpy as np
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt

APP="/tmp/htfull_app.log"; CSV="/tmp/htfull_samples.csv"
GREEN="#2e8b57"; RED="#c0392b"; BLUE="#2b6cb0"; AMBER="#d98e00"; GREY="#888"

opens=[]; seeks=[]; froz=[]
for ln in open(APP, errors="ignore"):
    m=re.search(r'\[HT\] OPEN lat=(\d+) dur=(\d+) ev=(\S+) t=(\d+)', ln)
    if m: opens.append((int(m.group(4)), int(m.group(1)), int(m.group(2)))); continue
    m=re.search(r'\[HT\] SEEK req=(-?\d+) lat=(\d+) t=(\d+)', ln)
    if m: seeks.append((int(m.group(3)), abs(int(m.group(1))), int(m.group(2)))); continue
    m=re.search(r'\[HT\] SEEK TIMEOUT req=(-?\d+) t=(\d+)', ln)
    if m: froz.append((int(m.group(2)), abs(int(m.group(1)))))

# sampler
st=[]; srss=[]; scpu=[]
for r in csv.DictReader(open(CSV)):
    try: st.append(int(r["t_ms"])); srss.append(float(r["rss_mb"])); scpu.append(float(r.get("cpu_pct",r.get("cpu","0")) or 0))
    except: pass
st=np.array(st); srss=np.array(srss); scpu=np.array(scpu)
def rss_at(t):
    if not len(st): return np.nan
    return float(srss[np.argmin(np.abs(st-t))])

def stats(a):
    a=np.array(a,float)
    return (len(a), float(np.mean(a)) if len(a) else 0, float(np.median(a)) if len(a) else 0,
            float(np.std(a)) if len(a) else 0, float(np.min(a)) if len(a) else 0, float(np.max(a)) if len(a) else 0)

print("="*78)
print("TRIAGE-HERO LATENCY TEST  —  results")
print("="*78)
# OPEN (click -> playback opens)
ol=[o[1] for o in opens]
n,mn,md,sd,lo,hi=stats(ol)
print(f"\nCLICK -> PLAYBACK-OPEN latency  (n={n} event opens)")
print(f"  mean {mn:.0f} ms · median {md:.0f} ms · std {sd:.0f} ms · min {lo:.0f} · max {hi:.0f}")

# per-step seek
print(f"\nSEEK -> ACTUAL-FRAME-UPDATE latency, per jump size  (frozen = no frame in 2.5 s)")
print(f"  {'step':>6} | {'rendered':>8} {'frozen':>6} {'frozen%':>7} | {'mean':>7} {'median':>7} {'std':>7} {'min':>5} {'max':>6}")
steporder=[1000,10000,30000,60000,300000]
stepname={1000:'1s',10000:'10s',30000:'30s',60000:'1m',300000:'5m'}
perstep={}
for s in steporder:
    wl=[k[2] for k in seeks if k[1]==s]; fz=[k for k in froz if k[1]==s]
    nn,m_,md_,sd_,lo_,hi_=stats(wl)
    tot=len(wl)+len(fz); fpct=(100*len(fz)/tot) if tot else 0
    perstep[s]={'work':wl,'froz':len(fz),'fpct':fpct}
    print(f"  {stepname[s]:>6} | {len(wl):>8} {len(fz):>6} {fpct:>6.0f}% | {m_:>6.0f}m {md_:>6.0f}m {sd_:>6.0f}m {lo_:>4.0f} {hi_:>5.0f}")
allw=[k[2] for k in seeks]; allf=len(froz)
nn,m_,md_,sd_,lo_,hi_=stats(allw)
tot=len(allw)+allf
print(f"  {'ALL':>6} | {len(allw):>8} {allf:>6} {(100*allf/tot if tot else 0):>6.0f}% | {m_:>6.0f}m {md_:>6.0f}m {sd_:>6.0f}m {lo_:>4.0f} {hi_:>5.0f}")
print(f"  (total jumps attempted: {tot})")

# memory
m=np.arange(len(srss))*0  # placeholder
relmin=(st-st[0])/60000.0 if len(st) else np.array([])
base=np.median(srss[:20]) if len(srss)>20 else (srss[0] if len(srss) else 0)
endrss=np.median(srss[-20:]) if len(srss)>20 else (srss[-1] if len(srss) else 0)
mlate=relmin>1.0
slope=np.polyfit(relmin[mlate],srss[mlate],1)[0] if mlate.sum()>5 else 0
print(f"\nMEMORY (RSS)  base {base:.0f} -> end {endrss:.0f} MB · peak {srss.max() if len(srss) else 0:.0f} · "
      f"trend {slope:+.1f} MB/min over {relmin[-1] if len(relmin) else 0:.1f} min")
# RSS at jumps
jt=[s[0] for s in seeks]+[f[0] for f in froz]+[o[0] for o in opens]
jr=[rss_at(t) for t in jt]
if jr: print(f"  RSS sampled at the {len(jr)} jump/open instants: {np.nanmin(jr):.0f}..{np.nanmax(jr):.0f} MB (mean {np.nanmean(jr):.0f})")

# spikes: RSS jumps > 40MB vs 10-sample trailing median; CPU > 85%
print(f"\nSPIKES")
spk=[]
for i in range(20,len(srss)):
    loc=np.median(srss[i-20:i])
    if srss[i]-loc>40: spk.append(("RSS", st[i], srss[i], srss[i]-loc))
cpuspk=[(st[i],scpu[i]) for i in range(len(scpu)) if scpu[i]>=85]
def near_event(t):
    cands=[("open",o[0],o[1]) for o in opens]+[("seek",s[0],s[1]) for s in seeks]+[("FROZE",f[0],f[1]) for f in froz]
    if not cands: return "?"
    k=min(cands,key=lambda c:abs(c[1]-t))
    if k[0]=="open": return f"event-open (lat {k[2]}ms)"
    return f"{k[0]} {stepname.get(k[2],k[2])}"
# coalesce RSS spikes
seen=set(); rspk=[]
for typ,t,v,d in spk:
    b=t//3000
    if b in seen: continue
    seen.add(b); rspk.append((t,v,d))
print(f"  RSS spikes (>+40MB vs trailing median): {len(rspk)}")
for t,v,d in rspk[:12]:
    print(f"    +{d:.0f}MB -> {v:.0f}MB  during {near_event(t)}")
print(f"  CPU samples >=85%: {len(cpuspk)}" + (f" (peak {max(c[1] for c in cpuspk):.0f}%)" if cpuspk else ""))
if cpuspk:
    # which step/open dominates near CPU spikes
    from collections import Counter
    c=Counter(near_event(t).split(' (')[0] for t,_ in cpuspk)
    print("    CPU-spike context: " + ", ".join(f"{k}×{v}" for k,v in c.most_common(5)))

# ---------------- GRAPH ----------------
fig,(ax1,ax2)=plt.subplots(2,1,figsize=(12,7),sharex=True)
ax1.plot(relmin,srss,color=BLUE,lw=1.3); ax1.set_ylabel("RSS (MB)")
ax1.set_title("Triage-hero latency stress — memory & CPU\n"
              f"{len(opens)} event-opens (mean {np.mean(ol) if ol else 0:.0f} ms), {tot} jumps "
              f"({len(allw)} rendered / {allf} froze = {(100*allf/tot if tot else 0):.0f}%)", loc="left", fontsize=11)
# mark frozen seeks (red ticks) and opens (grey ticks)
for f in froz:
    ax1.axvline((f[0]-st[0])/60000.0, color=RED, alpha=0.05, lw=0.6)
for t,v,d in rspk:
    ax1.plot((t-st[0])/60000.0, v, "v", color=RED, ms=7)
ax1.legend(handles=[plt.Line2D([],[],color=RED,marker='v',ls='',label='RSS spike'),
                    plt.Line2D([],[],color=RED,alpha=.4,label='frozen seek')], loc="upper left", fontsize=8)
ax2.plot(relmin,scpu,color=AMBER,lw=0.9); ax2.set_ylabel("CPU (% of 1 core)"); ax2.set_xlabel("minutes")
plt.tight_layout(); plt.savefig("/tmp/ht_graph.png",dpi=120); print("\ngraph -> /tmp/ht_graph.png")
