#!/usr/bin/python3
"""
watchtower-netprobe — a standing vantage on the path from this machine to the
Cilex Vision backend that does NOT depend on the app being alive (A4, 2026-09-25).

WHY THIS SHAPE. The 111 s API stall of 2026-09-22 (D1) ended with two readings
alive and no way to separate them after the fact, because nothing was recording:
  (1) a tunnel path change wedges ESTABLISHED flows while NEW flows succeed —
      the RTSP tile that opened in 230 ms mid-stall was a NEW connection;
  (2) narrowly-scoped server queueing (pool.acquire() unbounded vs max_size=10).
So every second this records the two things that tell them apart:
  keep   GET /health on ONE persistent keep-alive connection (an established flow)
  fresh  GET /health on a NEW connection every time
and every 10 s the Tailscale path to the server peer (direct endpoint vs DERP
relay) and this machine's default route, so a path change is timestamped.

READING A STALL (correlate with the app's flight recorder, WT_TRACE on):
  app slow,  keep fast,  fresh fast  → server-side and scoped (reading 2) → CV's pg_stat_activity
  app slow,  keep STALL, fresh fast  → established flows wedged (reading 1) → look for a `path` change
  keep STALL and fresh STALL         → server or whole path down
  GAP ... slept_s=N                  → the laptop slept; the interval is not evidence
/health is unauthenticated and does not touch the database, so it cannot see
reading 2 by itself — that is what the server-side sampler is for.

Stdlib only: runs under /usr/bin/python3 (3.9) from a LaunchAgent.
Env: WT_PROBE_HOST (100.107.51.72), WT_PROBE_PORT (8000), WT_PROBE_PATH (/health),
     WT_PROBE_DIR (~/Library/Logs/watchtower-capture), WT_PROBE_KEEP_DAYS (14),
     WT_PROBE_TIMEOUT_S (10).
"""
import datetime as dt
import glob
import gzip
import http.client
import json
import os
import shutil
import socket
import statistics
import subprocess
import threading
import time

HOST = os.environ.get("WT_PROBE_HOST", "100.107.51.72")
PORT = int(os.environ.get("WT_PROBE_PORT", "8000"))
PATH = os.environ.get("WT_PROBE_PATH", "/health")
DIR = os.path.expanduser(os.environ.get("WT_PROBE_DIR", "~/Library/Logs/watchtower-capture"))
KEEP_DAYS = int(os.environ.get("WT_PROBE_KEEP_DAYS", "14"))
TIMEOUT = float(os.environ.get("WT_PROBE_TIMEOUT_S", "10"))
TAILSCALE = next((p for p in ("/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
                              "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
                  if os.access(p, os.X_OK)), None)


def utc_now():
    return dt.datetime.now(dt.timezone.utc)


def stamp(t=None):
    t = t or utc_now()
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (t.microsecond // 1000)


class DailyLog:
    """One file per UTC day; yesterday's is gzipped, anything past KEEP_DAYS pruned."""

    def __init__(self, directory):
        self.dir = directory
        os.makedirs(self.dir, exist_ok=True)
        self.lock = threading.Lock()
        self.day = None
        self.f = None

    def _roll(self, day):
        if self.f:
            self.f.close()
            prev = os.path.join(self.dir, "netprobe-%s.log" % self.day)
            try:
                with open(prev, "rb") as src, gzip.open(prev + ".gz", "wb") as dst:
                    shutil.copyfileobj(src, dst)
                os.remove(prev)
            except OSError:
                pass
        self.day = day
        self.f = open(os.path.join(self.dir, "netprobe-%s.log" % day), "a", buffering=1)
        cutoff = time.time() - KEEP_DAYS * 86400
        for p in glob.glob(os.path.join(self.dir, "netprobe-*.log*")):
            try:
                if os.path.getmtime(p) < cutoff:
                    os.remove(p)
            except OSError:
                pass

    def write(self, kind, text):
        now = utc_now()
        with self.lock:
            day = now.strftime("%Y%m%d")
            if day != self.day:
                self._roll(day)
            self.f.write("%s %-6s %s\n" % (stamp(now), kind, text))


LOG = DailyLog(DIR)


class Window:
    """Per-minute rollup so a quiet day can be scanned without reading 172,800 lines."""

    def __init__(self):
        self.lock = threading.Lock()
        self.ms = {"keep": [], "fresh": []}
        self.err = {"keep": 0, "fresh": 0}

    def add(self, kind, ms, ok):
        with self.lock:
            self.ms[kind].append(ms)
            if not ok:
                self.err[kind] += 1

    def drain(self):
        with self.lock:
            ms, err = self.ms, self.err
            self.ms = {"keep": [], "fresh": []}
            self.err = {"keep": 0, "fresh": 0}
        parts = []
        for k in ("keep", "fresh"):
            v = ms[k]
            if v:
                parts.append("%s n=%d p50=%d max=%d err=%d" % (k, len(v), statistics.median(v), max(v), err[k]))
            else:
                parts.append("%s n=0" % k)
        return " | ".join(parts)


WIN = Window()


def sleep_to_next_second():
    time.sleep(1.0 - (time.time() % 1.0))


def keep_loop():
    """ONE connection, reused for as long as it lives. Its local port is logged on every
    (re)connect, so 'same flow' vs 'new flow' is never an inference."""
    conn = None
    lport = 0
    while True:
        sleep_to_next_second()
        t0 = time.monotonic()
        try:
            if conn is None:
                conn = http.client.HTTPConnection(HOST, PORT, timeout=TIMEOUT)
                c0 = time.monotonic()
                conn.connect()
                lport = conn.sock.getsockname()[1]
                LOG.write("keep", "connect ms=%d lport=%d" % ((time.monotonic() - c0) * 1000, lport))
            conn.request("GET", PATH, headers={"Connection": "keep-alive"})
            r = conn.getresponse()
            r.read()
            ms = int((time.monotonic() - t0) * 1000)
            ok = r.status == 200
            LOG.write("keep", "%s ms=%d code=%d lport=%d" % ("ok " if ok else "BAD", ms, r.status, lport))
            WIN.add("keep", ms, ok)
            if r.getheader("Connection", "").lower() == "close":
                conn.close()
                conn = None
                LOG.write("keep", "server-closed lport=%d" % lport)
        except Exception as e:  # noqa: BLE001 — every failure is data here
            ms = int((time.monotonic() - t0) * 1000)
            LOG.write("keep", "ERR ms=%d err=%s lport=%d" % (ms, type(e).__name__, lport))
            WIN.add("keep", ms, False)
            try:
                if conn:
                    conn.close()
            except Exception:  # noqa: BLE001
                pass
            conn = None


def fresh_loop():
    while True:
        sleep_to_next_second()
        t0 = time.monotonic()
        conn = http.client.HTTPConnection(HOST, PORT, timeout=TIMEOUT)
        try:
            conn.connect()
            cms = int((time.monotonic() - t0) * 1000)
            conn.request("GET", PATH, headers={"Connection": "close"})
            r = conn.getresponse()
            r.read()
            ms = int((time.monotonic() - t0) * 1000)
            ok = r.status == 200
            LOG.write("fresh", "%s ms=%d connect_ms=%d code=%d" % ("ok " if ok else "BAD", ms, cms, r.status))
            WIN.add("fresh", ms, ok)
        except Exception as e:  # noqa: BLE001
            ms = int((time.monotonic() - t0) * 1000)
            LOG.write("fresh", "ERR ms=%d err=%s" % (ms, type(e).__name__))
            WIN.add("fresh", ms, False)
        finally:
            conn.close()


def run(cmd, timeout=5):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:  # noqa: BLE001
        return ""


def tailscale_path():
    if not TAILSCALE:
        return "tailscale=absent", None
    raw = run([TAILSCALE, "status", "--json"])
    try:
        st = json.loads(raw)
    except ValueError:
        return "tailscale=unreadable", None
    # An exit node tunnels ALL of this machine's internet traffic (measured 2026-09-25:
    # on, 100.95.220.35). It does not carry tailnet traffic to the server, but it shares
    # the machine's uplink and the tunnel stack, and a failover of it moves everything
    # else — so it belongs in the key: a change of exit node is a logged CHANGE.
    ex = st.get("ExitNodeStatus") or {}
    exit_txt = "exit=%s/%s" % (",".join(i.split("/")[0] for i in (ex.get("TailscaleIPs") or [])[:1]) or "-",
                               "up" if ex.get("Online") else ("down" if ex else "off"))
    for peer in (st.get("Peer") or {}).values():
        if HOST in (peer.get("TailscaleIPs") or []):
            cur = peer.get("CurAddr") or "-"
            relay = peer.get("Relay") or "-"
            via = "direct" if peer.get("CurAddr") else ("relay:" + relay if relay != "-" else "none")
            key = (via, cur, bool(peer.get("Online")), bool(peer.get("Active")), exit_txt)
            text = "peer=%s via=%s cur=%s relay=%s online=%d active=%d %s handshake=%s rx=%s tx=%s" % (
                peer.get("HostName", "?"), via, cur, relay, peer.get("Online", False), peer.get("Active", False),
                exit_txt, peer.get("LastHandshake", "-"), peer.get("RxBytes", "-"), peer.get("TxBytes", "-"))
            return text, key
    return "peer=%s not-in-tailnet-status" % HOST, ("absent",)


def default_route():
    """The default route is a TUNNEL whenever an exit node is on (utun*), which hides the
    network the laptop is actually on. Report both: the winning default, and the physical
    one underneath it — roaming shows up as a change of phys/ip/gw."""
    top = phys = None
    for line in run(["/usr/sbin/netstat", "-rn", "-f", "inet"]).splitlines():
        f = line.split()
        if len(f) >= 4 and f[0] == "default":
            gw, iface = f[1], f[-1]
            top = top or iface
            if phys is None and not iface.startswith(("utun", "ipsec", "ppp")):
                phys = (iface, gw)
    if phys:
        ip = run(["/usr/sbin/ipconfig", "getifaddr", phys[0]]).strip() or "-"
        return "default=%s phys=%s ip=%s gw=%s" % (top or "-", phys[0], ip, phys[1])
    return "default=%s phys=- (no physical default route)" % (top or "-")


def context_loop():
    """Every 10 s: Tailscale path + default route, logged on CHANGE; a heartbeat every
    60 s carries the per-minute rollup and the current path even when nothing moved."""
    last_path = last_route = None
    n = 0
    while True:
        text, key = tailscale_path()
        if key != last_path:
            LOG.write("path", ("CHANGE " if last_path is not None else "") + text)
            last_path = key
        route = default_route()
        if route != last_route:
            LOG.write("route", ("CHANGE " if last_route is not None else "") + route)
            last_route = route
        n += 1
        if n % 6 == 0:
            LOG.write("min", WIN.drain())
            LOG.write("hb", text)
        time.sleep(10)


def gap_loop():
    """Wall clock vs monotonic: on macOS time.monotonic() stops while the machine sleeps,
    so a wall jump with no monotonic jump is sleep, not a stall. Never read an interval
    that contains a GAP as network evidence."""
    lw, lm = time.time(), time.monotonic()
    while True:
        time.sleep(1)
        w, m = time.time(), time.monotonic()
        dw, dm = w - lw, m - lm
        if dw > 5:
            LOG.write("GAP", "wall_s=%.1f mono_s=%.1f slept_s=%.1f" % (dw, dm, max(0.0, dw - dm)))
        lw, lm = w, m


def main():
    LOG.write("start", "pid=%d host=%s:%d path=%s timeout_s=%g tailscale=%s keep_days=%d host_name=%s" % (
        os.getpid(), HOST, PORT, PATH, TIMEOUT, TAILSCALE or "-", KEEP_DAYS, socket.gethostname()))
    for fn in (keep_loop, fresh_loop, context_loop, gap_loop):
        threading.Thread(target=fn, name=fn.__name__, daemon=True).start()
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
