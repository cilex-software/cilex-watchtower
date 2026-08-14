#!/usr/bin/env python3
"""Server-side half of the paired reconnect study (2026-08-15, 01:30->09:30 UTC+3).

Counterpart to tools/conn-diag/net-diag.sh, which the booth runs. Protocol is
fixed in docs/letters/2026-08-15-paired-reconnect-protocol.md — do not change a
column without amending that file, or the two halves stop joining.

Three things this measures that the booth structurally cannot:

  1. THE BOOTH'S OWN CONSUMERS, seen from the server. go2rtc exposes
     remote_addr per consumer, so the booth's attach/detach churn is observable
     independently of the booth's own accounting. If the booth logs a reconnect
     the server never saw, the drop never reached the network.
  2. COLD-START cost. The 08-14 run measured 213 warm probes and zero cold, so
     it said nothing about connection establishment — the mechanism most likely
     behind "constantly reconnecting". Each sample now also probes a stream with
     no consumers and no producer, forcing a fresh RTSP open, rotating through
     the pool so no stream is kept artificially warm.
  3. Whether the server was under load at the moment of each booth reconnect.

NA, never 0, for anything not measured. A silent zero is the failure mode that
cost the booth agent its first collector.
"""
import json, os, sys, time, urllib.request, urllib.error

G2 = "http://192.168.1.79:1984"
WARM = [("102", "hiwatch-083bc16da380-sub"),
        ("126", "hiwatch-083bc1df39d1-sub"),
        ("189", "hiwatch-04eecdd45e0d-sub")]
INTERVAL = 30
HOURS = float(os.environ.get("HOURS", "8"))
START_AT = os.environ.get("START_AT", "")      # "HH:MM" local, wait for it


def now_utc():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def rd(p, d=""):
    try:
        return open(p).read()
    except OSError:
        return d


def psi(res, kind, avg):
    for line in rd("/proc/pressure/" + res).splitlines():
        if line.startswith(kind):
            for kv in line.split()[1:]:
                k, _, v = kv.partition("=")
                if k == avg:
                    return float(v)
    return None


def counters():
    d = {}
    for line in rd("/proc/vmstat").splitlines():
        k, _, v = line.partition(" ")
        if k in ("pswpin", "pswpout", "pgmajfault"):
            d[k] = int(v)
    return d


def swap_used_mb():
    t = f_ = None
    for line in rd("/proc/meminfo").splitlines():
        p = line.split()
        if p[0] == "SwapTotal:":
            t = int(p[1])
        elif p[0] == "SwapFree:":
            f_ = int(p[1])
    return (t - f_) // 1024 if t is not None and f_ is not None else None


def wt_local():
    for pid in os.listdir("/proc"):
        if not pid.isdigit() or "watchtower" not in rd("/proc/%s/comm" % pid):
            continue
        st = rd("/proc/%s/stat" % pid).split()
        if len(st) < 24:
            continue
        clk = os.sysconf("SC_CLK_TCK")
        return {"pid": int(pid), "rss_mb": int(st[23]) * 4096 // (1 << 20),
                "alive_s": int(float(rd("/proc/uptime").split()[0]) - int(st[21]) / clk)}
    return None


def get(url, timeout=25):
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            first = time.monotonic()
            b = r.read()
            return {"http": r.status, "ttfb_s": round(first - t0, 3), "bytes": len(b)}
    except urllib.error.HTTPError as e:
        return {"http": e.code, "ttfb_s": None, "bytes": 0}
    except Exception as e:
        return {"http": 0, "ttfb_s": None, "bytes": 0, "err": type(e).__name__}


def streams():
    try:
        with urllib.request.urlopen(G2 + "/api/streams", timeout=15) as f:
            return json.load(f)
    except Exception:
        return None


_cold_i = 0


def pick_cold(d):
    """Next stream with no consumers AND no connected producer — a true cold open."""
    global _cold_i
    pool = [k for k, v in sorted(d.items())
            if k.endswith("-sub")
            and not (v.get("consumers") or [])
            and not any("id" in p for p in (v.get("producers") or []))]
    if not pool:
        return None
    k = pool[_cold_i % len(pool)]
    _cold_i += 1
    return k


def sample(prev_counts, prev_ctr):
    d = streams()
    row = {"ts_utc": now_utc(), "host": "serverroom"}
    if d is None:
        row["go2rtc_error"] = True
        return row, prev_counts, prev_ctr

    per, by_ip = {}, {}
    prod = cons = 0
    for k, v in d.items():
        cs = v.get("consumers") or []
        per[k] = len(cs)
        cons += len(cs)
        if any("id" in p for p in (v.get("producers") or [])):
            prod += 1
        for c in cs:
            ip = (c.get("remote_addr") or "?").split(":")[0]
            by_ip[ip] = by_ip.get(ip, 0) + 1

    # Churn: per-stream consumer deltas since the previous sample. attach/detach
    # counted separately — a reconnect is a detach followed by an attach, and
    # summing them would hide which half is happening.
    att = det = 0
    if prev_counts:
        for k in set(per) | set(prev_counts):
            dlt = per.get(k, 0) - prev_counts.get(k, 0)
            if dlt > 0:
                att += dlt
            elif dlt < 0:
                det += -dlt
    row["go2rtc"] = {"streams": len(d), "producers_connected": prod,
                     "consumers_total": cons, "consumers_by_ip": by_ip,
                     "attach": att if prev_counts else None,
                     "detach": det if prev_counts else None}

    row["warm"] = []
    for ip, s in WARM:
        r = get("%s/api/frame.jpeg?src=%s" % (G2, s))
        r["ip"] = ip
        row["warm"].append(r)

    ck = pick_cold(d)
    if ck:
        r = get("%s/api/frame.jpeg?src=%s" % (G2, ck), timeout=30)
        r["stream"] = ck
        row["cold"] = r
    else:
        row["cold"] = None            # NA, not zero: no idle stream existed

    c = counters()
    row["host_load"] = {
        "load1": float(rd("/proc/loadavg", "0 ").split()[0]),
        "swap_used_mb": swap_used_mb(),
        "psi_io_full_avg60": psi("io", "full", "avg60"),
        "psi_mem_full_avg60": psi("memory", "full", "avg60"),
        "pswpout_delta": (c.get("pswpout", 0) - prev_ctr.get("pswpout", 0)) if prev_ctr else None,
        "pgmajfault_delta": (c.get("pgmajfault", 0) - prev_ctr.get("pgmajfault", 0)) if prev_ctr else None,
    }
    row["watchtower_local"] = wt_local()
    return row, per, c


if __name__ == "__main__":
    if START_AT:
        hh, mm = map(int, START_AT.split(":"))
        while True:
            t = time.localtime()
            if (t.tm_hour, t.tm_min) == (hh, mm):
                break
            time.sleep(5)
    end = time.time() + HOURS * 3600
    pc, pctr = None, {}
    while time.time() < end:
        t0 = time.time()
        try:
            row, pc, pctr = sample(pc, pctr)
            print(json.dumps(row), flush=True)
        except Exception as e:
            print(json.dumps({"ts_utc": now_utc(), "sample_error": repr(e)}), flush=True)
        time.sleep(max(0, INTERVAL - (time.time() - t0)))
