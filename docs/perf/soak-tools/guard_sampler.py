#!/usr/bin/env python3
# Samples the watchtower process (RSS + CPU%) every ~2s, epoch-stamped so it aligns with the app's
# [GUARD] t=<epoch> action log. Re-resolves the pid each tick → survives crash/relaunch (logs rss=0 in the gap).
import time, os, sys

CLK = os.sysconf('SC_CLK_TCK')
PAGE_KB = os.sysconf('SC_PAGE_SIZE') // 1024
out = sys.argv[1]
dur = int(sys.argv[2]) if len(sys.argv) > 2 else 999999

def find_pid():
    for p in os.listdir('/proc'):
        if not p.isdigit():
            continue
        try:
            if open('/proc/%s/comm' % p).read().strip() == 'watchtower':
                return int(p)
        except Exception:
            pass
    return None

def sample(pid):
    try:
        st = open('/proc/%d/stat' % pid).read().rsplit(')', 1)[1].split()
        ticks = int(st[11]) + int(st[12])              # utime + stime (after the "(comm)" field)
        rss_pages = int(open('/proc/%d/statm' % pid).read().split()[1])
        return ticks, rss_pages * PAGE_KB // 1024      # rss in MB
    except Exception:
        return None

fo = open(out, 'w')
fo.write('epoch_ms,pid,rss_mb,cpu_pct\n'); fo.flush()
start = time.time()
last_pid = last_ticks = last_t = None
while time.time() - start < dur:
    pid = find_pid()
    ep = int(time.time() * 1000)
    if pid is None:
        fo.write('%d,,0,0.0\n' % ep); fo.flush()
        last_pid = last_ticks = last_t = None
        time.sleep(2); continue
    s = sample(pid)
    if s is None:
        time.sleep(2); continue
    ticks, rss = s; now = time.time(); cpu = 0.0
    if pid == last_pid and last_ticks is not None and now > last_t:
        cpu = (ticks - last_ticks) / CLK / (now - last_t) * 100.0
    fo.write('%d,%d,%d,%.1f\n' % (ep, pid, rss, cpu)); fo.flush()
    last_pid, last_ticks, last_t = pid, ticks, now
    time.sleep(2)
fo.close()
