#!/usr/bin/env python3
"""Cilex Watchtower — 6 h connection diagnosis, server-room side.

Emits one JSON object per sample to stdout (JSONL). Method is documented in
docs/perf/2026-08-14-connection-diagnosis-method.md so the booth agent can run
the IDENTICAL probe set — the comparison is only meaningful if both sides hit
the same three cameras with the same request.

Read-only throughout: /proc, /sys, go2rtc's HTTP API, and a single JPEG frame
per camera per sample. Nothing is written to the fleet, no PTZ, no acks.
"""
import json, os, sys, time, urllib.request, urllib.error

# :1984 was CLOSED by CV on 2026-08-15 (every go2rtc producer URL on that port
# carried a camera password). Verified refused on LAN and tailnet 2026-08-16.
# Every G2 call below is therefore dead. They are left in place rather than
# deleted because this harness is still the record of the open consumer-attrition
# investigation — but they must NEVER be allowed to report a zero, because "the
# port is gone" and "the value is zero" are different facts and conflating them is
# how three wrong findings got written this week.
# Replacements: consumer counts -> GET /client/streams/consumers (authenticated);
# per-camera frame rate -> tools/conn-diag/fps-sweep.sh over RTSP :8554.
G2 = None          # hard-fail any surviving caller instead of silently timing out
# Pinned by IP so both machines probe the same optics. -sub is what the wall
# actually consumes; the main streams are HEVC and only the recorder pulls them.
PROBES = [
    ("102", "hiwatch-083bc16da380-sub"),
    ("126", "hiwatch-083bc1df39d1-sub"),
    ("189", "hiwatch-04eecdd45e0d-sub"),
]
INTERVAL = 300
DURATION = 6 * 3600


def read(p, default=""):
    try:
        with open(p) as f:
            return f.read()
    except OSError:
        return default


def psi(res):
    out = {}
    for line in read("/proc/pressure/" + res).splitlines():
        kind = line.split()[0]                       # some | full
        for kv in line.split()[1:]:
            k, _, v = kv.partition("=")
            if k in ("avg10", "avg60"):
                out["%s_%s" % (kind, k)] = float(v)
    return out


def vmstat():
    d = {}
    for line in read("/proc/vmstat").splitlines():
        k, _, v = line.partition(" ")
        if k in ("pswpin", "pswpout", "pgmajfault"):
            d[k] = int(v)
    return d


def meminfo():
    d = {}
    for line in read("/proc/meminfo").splitlines():
        parts = line.split()
        if parts and parts[0].rstrip(":") in ("MemTotal", "MemAvailable", "SwapTotal", "SwapFree"):
            d[parts[0].rstrip(":")] = int(parts[1]) // 1024      # MB
    d["SwapUsed"] = d.get("SwapTotal", 0) - d.get("SwapFree", 0)
    return d


def watchtower():
    """RSS/CPU/uptime of the running wall, if any. A restart shows as etimes
    dropping — which matters, because a reconnect storm follows every restart."""
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        if "watchtower" not in read("/proc/%s/comm" % pid):
            continue
        st = read("/proc/%s/stat" % pid).split()
        if len(st) < 24:
            continue
        clk = os.sysconf("SC_CLK_TCK")
        used = (int(st[13]) + int(st[14])) / clk
        up = float(read("/proc/uptime").split()[0]) - int(st[21]) / clk
        return {"pid": int(pid), "rss_mb": int(st[23]) * 4096 // (1024 * 1024),
                "cpu_s": round(used, 1), "alive_s": int(up)}
    return None


def timed_get(url, timeout=25):
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            first = time.monotonic()
            body = r.read()
            return {"http": r.status, "ttfb_s": round(first - t0, 3),
                    "total_s": round(time.monotonic() - t0, 3), "bytes": len(body)}
    except urllib.error.HTTPError as e:
        return {"http": e.code, "ttfb_s": None,
                "total_s": round(time.monotonic() - t0, 3), "bytes": 0}
    except Exception as e:
        return {"http": 0, "error": type(e).__name__,
                "total_s": round(time.monotonic() - t0, 3), "bytes": 0}


def census():
    """go2rtc fleet state + which of our probe streams are already warm."""
    r = timed_get(G2 + "/api/streams")
    out = {"api_ms": int(r["total_s"] * 1000), "api_http": r["http"],
           "api_bytes": r["bytes"]}
    try:
        with urllib.request.urlopen(G2 + "/api/streams", timeout=15) as f:
            d = json.load(f)
    except Exception:
        out["error"] = True
        return out, {}
    prod = cons = 0
    warm = {}
    for k, v in d.items():
        c = len(v.get("consumers") or [])
        cons += c
        connected = any("id" in p for p in (v.get("producers") or []))
        if connected:
            prod += 1
        warm[k] = connected
    out.update(streams=len(d), producers_connected=prod, consumers_total=cons)
    return out, warm


def sample():
    c, warm = census()
    probes = []
    for ip, stream in PROBES:
        pre = warm.get(stream)
        r = timed_get("%s/api/frame.jpeg?src=%s" % (G2, stream))
        r.update(ip=ip, stream=stream, warm_before=pre)
        probes.append(r)
    return {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "epoch": int(time.time()),
        "host": "server-room/cilex-vision-MS-7E06",
        "load1": float(read("/proc/loadavg", "0 ").split()[0]),
        "mem": meminfo(),
        "vmstat": vmstat(),
        "psi": {"cpu": psi("cpu"), "memory": psi("memory"), "io": psi("io")},
        "watchtower": watchtower(),
        "go2rtc": c,
        "probes": probes,
    }


if __name__ == "__main__":
    end = time.time() + DURATION
    while time.time() < end:
        try:
            print(json.dumps(sample()), flush=True)
        except Exception as e:                       # never let one bad sample end the run
            print(json.dumps({"epoch": int(time.time()), "sample_error": repr(e)}), flush=True)
        time.sleep(INTERVAL)
