#!/usr/bin/env python3
# Analyze the guard soak: mean/stdev (overall + per-action) of RSS & CPU, spikes (+ the action that caused
# them), crashes, and a CPU/RSS graph with action regions + crash markers.
import re, csv, os, bisect
import numpy as np
import matplotlib; matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches

D = '/tmp/guard_test'

samp, gaps = [], []
for r in csv.DictReader(open(D + '/samples.csv')):
    ep = int(r['epoch_ms']); rss = float(r['rss_mb']); cpu = float(r['cpu_pct'])
    if r['pid'] and rss > 0:
        samp.append((ep, rss, cpu))
    else:
        gaps.append(ep)
if len(samp) < 2:
    print("not enough samples yet"); raise SystemExit

acts = []
for line in open(D + '/app.log', errors='ignore'):
    m = re.search(r'\[GUARD\] t=(\d+) step=([a-z-]+)', line)
    if m:
        acts.append((int(m.group(1)), m.group(2)))
acts.sort()
act_eps = [a[0] for a in acts]
def act_for(ep):
    i = bisect.bisect_right(act_eps, ep) - 1
    return acts[i][1] if i >= 0 else 'startup'

rows = [(ep, rss, cpu, act_for(ep)) for ep, rss, cpu in samp]
t0 = rows[0][0]
rss = np.array([r[1] for r in rows]); cpu = np.array([r[2] for r in rows])
steps = [r[3] for r in rows]; hrs = np.array([(r[0] - t0) / 3.6e6 for r in rows])

print("==== EXTENDED LIVE-SCREEN GUARD SOAK — RESULTS ====")
print("duration: %.2f h   samples(alive): %d   relaunch-gap samples: %d" % (hrs[-1], len(rows), len(gaps)))
print("RSS  MB : mean %.0f  stdev %.0f  min %.0f  max %.0f" % (rss.mean(), rss.std(), rss.min(), rss.max()))
print("CPU  %%  : mean %.1f  stdev %.1f  min %.1f  max %.1f" % (cpu.mean(), cpu.std(), cpu.min(), cpu.max()))
# overall RSS trend (leak check) — MB/hour
if hrs[-1] > 0.2:
    slope = np.polyfit(hrs, rss, 1)[0]
    print("RSS trend: %+.1f MB/hour over the run (≈0 = no leak)" % slope)

print("\n-- per-action (mean +/- stdev) --")
print("%-16s %5s %9s %7s %9s %7s" % ("action", "n", "RSSmean", "RSSsd", "CPUmean", "CPUsd"))
for a in sorted(set(steps)):
    idx = [i for i, s in enumerate(steps) if s == a]
    r = rss[idx]; c = cpu[idx]
    print("%-16s %5d %9.0f %7.0f %9.1f %7.1f" % (a, len(idx), r.mean(), r.std(), c.mean(), c.std()))

print("\n-- top RSS spikes (and the action) --")
for i in np.argsort(rss)[-8:][::-1]:
    print("   %6.0f MB  @%6.2fh  during %s" % (rss[i], hrs[i], steps[i]))
print("-- top CPU spikes (and the action) --")
for i in np.argsort(cpu)[-8:][::-1]:
    print("   %6.1f %%  @%6.2fh  during %s" % (cpu[i], hrs[i], steps[i]))

ncrash = 0
if os.path.exists(D + '/incidents.log'):
    ncrash = open(D + '/incidents.log').read().count('CRASH/KILL')
print("\n-- crashes/kills: %d  (details in incidents.log) --" % ncrash)

# graph
fig, (a1, a2) = plt.subplots(2, 1, figsize=(14, 8), sharex=True)
a1.plot(hrs, rss, lw=0.6, color='tab:blue'); a1.set_ylabel('RSS (MB)'); a1.set_title('Guard soak — process RSS'); a1.grid(alpha=0.3)
a2.plot(hrs, cpu, lw=0.6, color='tab:green'); a2.set_ylabel('CPU (%)'); a2.set_xlabel('elapsed (hours)'); a2.set_title('CPU'); a2.grid(alpha=0.3)
colors = {'events-triage':'orange','events-map':'gold','events-timeline':'khaki','groups':'plum',
          'views':'lightblue','health':'lightgreen','playback-wall':'salmon'}
prev, start = None, None
for i in range(len(rows)):
    a = steps[i]
    if a != prev:
        if prev in colors and start is not None:
            for ax in (a1, a2): ax.axvspan(start, hrs[i], color=colors[prev], alpha=0.3)
        start = hrs[i]; prev = a
if prev in colors and start is not None:
    for ax in (a1, a2): ax.axvspan(start, hrs[-1], color=colors[prev], alpha=0.3)
ti = np.argsort(rss)[-5:]; a1.scatter(hrs[ti], rss[ti], color='red', s=20, zorder=5, label='RSS spikes')
ci = np.argsort(cpu)[-5:]; a2.scatter(hrs[ci], cpu[ci], color='red', s=20, zorder=5, label='CPU spikes')
for g in gaps:
    gh = (g - t0) / 3.6e6
    if gh >= 0:
        for ax in (a1, a2): ax.axvline(gh, color='black', ls=':', lw=0.8)
a1.legend(loc='upper left', fontsize=8)
a2.legend(handles=[mpatches.Patch(color=c, alpha=0.3, label=a) for a, c in colors.items()] +
          [mpatches.Patch(color='black', label='crash/relaunch')], loc='upper left', fontsize=7, ncol=4)
plt.tight_layout(); plt.savefig(D + '/guard_soak.png', dpi=110)
print("\ngraph: " + D + '/guard_soak.png')
