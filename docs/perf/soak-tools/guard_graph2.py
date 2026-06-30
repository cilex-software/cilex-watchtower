#!/usr/bin/env python3
import re, csv, bisect
import numpy as np
import matplotlib; matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches

D = '/tmp/guard_test'
samp = []
for r in csv.DictReader(open(D + '/samples.csv')):
    if r['pid'] and float(r['rss_mb']) > 0:
        samp.append((int(r['epoch_ms']), float(r['rss_mb']), float(r['cpu_pct'])))
acts = []
for line in open(D + '/app.log', errors='ignore'):
    m = re.search(r'\[GUARD\] t=(\d+) step=([a-z-]+)', line)
    if m: acts.append((int(m.group(1)), m.group(2)))
acts.sort(); act_eps = [a[0] for a in acts]
def act_for(ep):
    i = bisect.bisect_right(act_eps, ep) - 1
    return acts[i][1] if i >= 0 else 'startup'

t0 = samp[0][0]
hrs = np.array([(s[0]-t0)/3.6e6 for s in samp])
rss = np.array([s[1] for s in samp]); cpu = np.array([s[2] for s in samp])
steps = [act_for(s[0]) for s in samp]
wedge_h = (acts[-1][0]-t0)/3.6e6 if acts else None   # last [GUARD] = wedge onset
colors = {'live':'#cfe8ff','events-triage':'orange','events-map':'gold','events-timeline':'khaki',
          'groups':'plum','views':'lightblue','health':'lightgreen','playback-wall':'salmon'}

fig = plt.figure(figsize=(14, 10))
ax1 = fig.add_subplot(3,1,1); ax2 = fig.add_subplot(3,1,2)
ax3 = fig.add_subplot(3,1,3)

# full-run RSS + CPU
for ax, y, lab, col in ((ax1, rss, 'RSS (MB)', 'tab:blue'), (ax2, cpu, 'CPU (%)', 'tab:green')):
    ax.plot(hrs, y, lw=0.6, color=col); ax.set_ylabel(lab); ax.grid(alpha=0.3)
    if wedge_h: ax.axvline(wedge_h, color='red', ls='--', lw=1.2)
ax1.set_title('Full 10.5 h run — RSS (note: GUI wedged at the red line; flat tail = frozen, not active use)')
ax2.set_title('Full 10.5 h run — CPU'); ax2.set_xlabel('elapsed (hours)')
if wedge_h: ax1.annotate('GUI wedge\n(playback-wall→Live)', xy=(wedge_h, rss.max()),
            xytext=(wedge_h+1.2, rss.max()-60), color='red', fontsize=9,
            arrowprops=dict(color='red', arrowstyle='->'))

# zoom: first 25 min (the real guard-usage data) with action regions
mask = hrs <= 0.45
zh = hrs[mask]; zr = rss[mask]; zc = cpu[mask]; zs = [steps[i] for i in range(len(steps)) if mask[i]]
ax3.plot(zh*60, zr, lw=1.0, color='tab:blue', label='RSS (MB)')
axc = ax3.twinx(); axc.plot(zh*60, zc, lw=1.0, color='tab:green', alpha=0.7, label='CPU (%)')
ax3.set_ylabel('RSS (MB)', color='tab:blue'); axc.set_ylabel('CPU (%)', color='tab:green')
ax3.set_xlabel('elapsed (minutes)'); ax3.set_title('Zoom: first 25 min = the one real guard-usage cycle (action regions shaded)')
prev, start = None, None
for i in range(len(zs)):
    if zs[i] != prev:
        if prev in colors and start is not None:
            ax3.axvspan(start*60, zh[i]*60, color=colors[prev], alpha=0.35)
        start = zh[i]; prev = zs[i]
if prev in colors and start is not None: ax3.axvspan(start*60, zh[-1]*60, color=colors[prev], alpha=0.35)
ax3.legend(handles=[mpatches.Patch(color=c, alpha=0.4, label=a) for a,c in colors.items()],
           loc='upper left', fontsize=7, ncol=4)
plt.tight_layout(); plt.savefig(D + '/guard_soak_annotated.png', dpi=110)
print('wrote', D + '/guard_soak_annotated.png', '| wedge at %.2f h (%.0f min)' % (wedge_h, wedge_h*60))
