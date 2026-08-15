#!/usr/bin/env python3
"""Booth (client) half of the paired reconnect study — 2026-08-15 01:30->09:30 UTC+3.

Deliberately the MIRROR of tools/conn-diag/srv-diag.py: same language, same
30 s cadence, same START_AT gate, same UTC clock, same "NA never 0" rule, same
JSONL-per-sample shape. The two halves are analysed by the SAME script
(tools/conn-diag/report.py), so neither station can compute a percentile its own
way and call the difference a finding.

    START_AT=01:30 HOURS=8 CV=<ip CV is reached on> python3 booth-diag.py > booth-8h.jsonl

Runs on Windows and Linux, stdlib only. psutil is used if present, otherwise it
falls back to parsing netstat/ss. EVERY value it cannot obtain is the string
"NA" — never 0, never an empty column. That rule exists because a collector that
silently reported zeros is what nearly produced a fabricated statistic on 08-14.

UNTESTED ON WINDOWS by its author (no Windows box here). Run it for three
samples and eyeball the output before trusting eight hours of it.
"""
import json, os, re, subprocess, sys, time

CV = os.environ.get("CV", "192.168.1.79")
INTERVAL = 30
HOURS = float(os.environ.get("HOURS", "8"))
START_AT = os.environ.get("START_AT", "")
LABEL = os.environ.get("LABEL", "booth")
APPNAME = os.environ.get("APPNAME", "watchtower")
WIN = sys.platform.startswith("win")
NA = "NA"

try:
    import psutil
except Exception:
    psutil = None


def utc():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def run(cmd):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True,
                              timeout=25).stdout
    except Exception:
        return ""


# ---------- process ----------------------------------------------------------
def app():
    if psutil:
        for p in psutil.process_iter(["pid", "name", "create_time"]):
            n = (p.info["name"] or "").lower()
            if APPNAME in n:
                try:
                    return {"pid": p.info["pid"],
                            "uptime_s": int(time.time() - p.info["create_time"]),
                            "rss_mb": p.memory_info().rss // (1 << 20)}
                except Exception:
                    return {"pid": p.info["pid"], "uptime_s": NA, "rss_mb": NA}
        return None
    if WIN:
        # pid is parsed INDEPENDENTLY of the memory field. Coupling them cost six
        # columns on wt-sm-vnutri-01: that locale renders memory as "688 856 K"
        # (space-separated thousands), the combined regex missed, and est_cv /
        # syn_sent / time_wait / close_wait / rss_mb all cascaded to NA.
        out = run('tasklist /FI "IMAGENAME eq %s.exe" /FO CSV /NH' % APPNAME)
        mp = re.search(r'^"[^"]*","(\d+)"', out, re.M)
        if not mp:
            return None
        rss = NA
        mm = re.search(r',"([^"]*?)\s*K"\s*$', out, re.M)
        if mm:
            digits = re.sub(r"\D", "", mm.group(1))
            if digits:
                rss = int(digits) // 1024
        return {"pid": int(mp.group(1)), "uptime_s": NA, "rss_mb": rss}
    out = run("pgrep -x %s | head -1" % APPNAME).strip()
    if not out:
        return None
    pid = int(out)
    rss = re.search(r"VmRSS:\s+(\d+)", open("/proc/%s/status" % pid).read())
    return {"pid": pid, "uptime_s": NA, "rss_mb": int(rss.group(1)) // 1024 if rss else NA}


# ---------- sockets ----------------------------------------------------------
def sockets(pid):
    """Counts of this pid's TCP sockets, split by state; est/time_wait scoped to CV."""
    res = {"est_cv": NA, "syn_sent": NA, "time_wait": NA, "close_wait": NA}
    if pid is None:
        return res
    if psutil:
        try:
            est = syn = tw = cw = 0
            for c in psutil.net_connections(kind="tcp"):
                if c.pid != pid:
                    continue
                st = c.status
                to_cv = bool(c.raddr) and c.raddr.ip == CV
                if st == "ESTABLISHED" and to_cv: est += 1
                elif st == "SYN_SENT":            syn += 1
                elif st == "CLOSE_WAIT":          cw += 1
                elif st == "TIME_WAIT" and to_cv: tw += 1
            return {"est_cv": est, "syn_sent": syn, "time_wait": tw, "close_wait": cw}
        except Exception:
            return res
    if WIN:
        out = run("netstat -ano -p TCP")
        est = syn = tw = cw = 0
        for line in out.splitlines():
            f = line.split()
            if len(f) < 5 or not f[-1].isdigit():
                continue
            if int(f[-1]) != pid:
                continue
            state, remote = f[3].upper(), f[2]
            to_cv = remote.rsplit(":", 1)[0] == CV
            if state == "ESTABLISHED" and to_cv: est += 1
            elif state == "SYN_SENT":            syn += 1
            elif state == "CLOSE_WAIT":          cw += 1
            elif state == "TIME_WAIT" and to_cv: tw += 1
        return {"est_cv": est, "syn_sent": syn, "time_wait": tw, "close_wait": cw}
    tag = "pid=%d," % pid
    g = lambda st, dst="": run("ss -tnp state %s %s 2>/dev/null" % (st, dst))
    return {"est_cv": g("established", "dst %s" % CV).count(tag),
            "syn_sent": g("syn-sent").count(tag),
            "time_wait": max(0, len(g("time-wait", "dst %s" % CV).splitlines()) - 1),
            "close_wait": g("close-wait").count(tag)}


# ---------- interface + tcp counters ----------------------------------------
def nic():
    if psutil:
        try:
            io = psutil.net_io_counters()
            return io.bytes_recv, io.bytes_sent
        except Exception:
            return None, None
    if not WIN:
        try:
            ifn = re.search(r"dev (\S+)", run("ip route get %s" % CV)).group(1)
            base = "/sys/class/net/%s/statistics/" % ifn
            return int(open(base + "rx_bytes").read()), int(open(base + "tx_bytes").read())
        except Exception:
            return None, None
    # Windows: measure the interface that ROUTES TO CV, matching what the Linux
    # branch above does via `ip route get`. Two reasons the old netstat -e path
    # was wrong: (a) `(\d[\d,\s]*)` spans the whitespace between the Received and
    # Sent columns, so it returned ONE 19-digit number formed by concatenating
    # both (1495453706 + 480238975), which is where 2e10 Mbit/s came from; and
    # (b) netstat -e is machine-wide, and on a Tailscale station the tunnel rides
    # inside Ethernet, so both count the same bytes and the total is ~doubled.
    ps = ("$i=(Find-NetRoute -RemoteIPAddress '%s'|Select-Object -First 1)"
          ".InterfaceAlias;$s=Get-NetAdapterStatistics -Name $i;"
          "'{0} {1}' -f $s.ReceivedBytes,$s.SentBytes" % CV)
    m = re.search(r"(\d+)\s+(\d+)",
                  run('powershell -NoProfile -NonInteractive -Command "%s"' % ps))
    if m:
        return int(m.group(1)), int(m.group(2))
    # Fallback keeps the per-column split correct even if the above is blocked.
    m = re.search(r"Bytes\s+(\d+)\s+(\d+)", run("netstat -e"))
    return (int(m.group(1)), int(m.group(2))) if m else (None, None)


def tcp_counters():
    """(TcpRetransSegs, TcpOutSegs). The real data-plane loss signal — NOT ICMP."""
    if WIN:
        out = run("netstat -s -p tcp")
        rt = re.search(r"Segments Retransmitted\s*=\s*(\d+)", out, re.I)
        os_ = re.search(r"Segments Sent\s*=\s*(\d+)", out, re.I)
        return (int(rt.group(1)) if rt else None, int(os_.group(1)) if os_ else None)
    try:
        lines = [l for l in open("/proc/net/snmp") if l.startswith("Tcp:")]
        k, v = lines[0].split(), lines[1].split()
        return int(v[k.index("RetransSegs")]), int(v[k.index("OutSegs")])
    except Exception:
        return None, None


def ping():
    c = ("ping -n 3 -w 2000 " if WIN else "ping -n -c 3 -W 2 ") + CV
    out = run(c)
    loss = re.search(r"(\d+)% (?:packet )?loss", out)
    if WIN:
        m = re.search(r"Minimum = (\d+)ms, Maximum = (\d+)ms, Average = (\d+)ms", out)
        rtt = (float(m.group(1)), float(m.group(3)), float(m.group(2))) if m else (NA, NA, NA)
    else:
        m = re.search(r"=\s*([\d.]+)/([\d.]+)/([\d.]+)/", out)
        rtt = (float(m.group(1)), float(m.group(2)), float(m.group(3))) if m else (NA, NA, NA)
    return rtt, (int(loss.group(1)) if loss else NA)


# ---------- flight recorder --------------------------------------------------
FR = os.environ.get("FLIGHTREC", "")
_fr_pos = [0]
RECONNECT_RE = re.compile(r"recycling stuck pipeline|reconnect|Connecting…|streamErrored", re.I)


def reconnects():
    """Count reconnect events appended since the previous sample.

    NA — not 0 — when the journal is absent or unreadable. A zero here would be
    indistinguishable from 'the log is dead', which is the exact confusion that
    cost the 08-14 run its conclusion."""
    if not FR or not os.path.exists(FR):
        return NA
    try:
        sz = os.path.getsize(FR)
        if sz < _fr_pos[0]:
            _fr_pos[0] = 0                       # rotated
        with open(FR, "r", errors="replace") as f:
            f.seek(_fr_pos[0])
            chunk = f.read()
            _fr_pos[0] = f.tell()
        return sum(1 for l in chunk.splitlines() if RECONNECT_RE.search(l))
    except Exception:
        return NA


# ---------- main -------------------------------------------------------------
def sample(prev):
    a = app()
    pid = a["pid"] if a else None
    rx, tx = nic()
    rt, os_ = tcp_counters()
    (rmin, ravg, rmax), loss = ping()

    def rate(new, old):
        if new is None or old is None:
            return NA
        return round((new - old) * 8 / INTERVAL / 1e6, 3)

    def delta(new, old):
        return NA if (new is None or old is None) else new - old

    row = {"ts_utc": utc(), "label": LABEL,
           "app_pid": a["pid"] if a else NA,
           "app_uptime_s": a["uptime_s"] if a else NA,
           "rss_mb": a["rss_mb"] if a else NA}
    row.update(sockets(pid))
    row.update({"rx_mbps": rate(rx, prev.get("rx")), "tx_mbps": rate(tx, prev.get("tx")),
                "rtt_min_ms": rmin, "rtt_avg_ms": ravg, "rtt_max_ms": rmax,
                "loss_pct": loss,
                "retrans_delta": delta(rt, prev.get("rt")),
                "outseg_delta": delta(os_, prev.get("os")),
                "tiles_total": os.environ.get("TILES_TOTAL", NA),
                "tiles_streaming": NA,
                "reconnects_interval": reconnects()})
    return row, {"rx": rx, "tx": tx, "rt": rt, "os": os_}


if __name__ == "__main__":
    if START_AT:
        hh, mm = map(int, START_AT.split(":"))
        while (time.localtime().tm_hour, time.localtime().tm_min) != (hh, mm):
            time.sleep(5)
    end = time.time() + HOURS * 3600
    prev = {}
    while time.time() < end:
        t0 = time.time()
        try:
            row, prev = sample(prev)
            print(json.dumps(row), flush=True)
        except Exception as e:
            print(json.dumps({"ts_utc": utc(), "sample_error": repr(e)}), flush=True)
        time.sleep(max(0, INTERVAL - (time.time() - t0)))
