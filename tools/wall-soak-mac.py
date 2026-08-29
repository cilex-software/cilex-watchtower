#!/usr/bin/env python3
# PROVENANCE COPY — the exact script behind docs/perf/2026-08-29-wall-soak-mac.md
# (written independently on the Mac the same night the canonical tools/wall-soak.py
# landed from the Ubuntu box, 8a249e5 — the two collided in flight; the box tool is
# canonical for future runs, this file preserves what the 136-cycle Mac run actually
# executed: pagination fix, cold-503 tracking, async-prewarm poll, one-in-flight).
"""16-camera playback-wall soak against the pilot backend (operator order 2026-08-29).

The grid is DERIVED from the segment inventory (/recording/segments): every camera
placed on a wall provably has continuous footage (gaps <= --gap-tol) across the
whole window — which is what makes a dark cell a real defect rather than an armed
camera that never recorded. Lit-cell counting is NOT the test.

Writes are limited to mosaic session create/prewarm/delete. One session in flight.
prewarm answers 202 (async) — the fragment is POLLED, never judged on one GET.
A cold 503 BEFORE prewarm is the known `ready`!=servable contract gap: tracked as a
rate, not a failure. backend-unavailable (HTTP 0/502/503/504 on control calls) is
classified separately from wall defects so a redeploy cannot poison the triage.

  tools/wall-soak.py --plan-only --hours-back 12
  tools/wall-soak.py --run-hours 6 --pace 150 --jsonl wall-soak.jsonl
"""
import argparse, json, random, signal, sys, time, urllib.request, urllib.error
from datetime import datetime, timedelta, timezone

def iso(dt): return dt.strftime("%Y-%m-%dT%H:%M:%SZ")
def parse_iso(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))

class Api:
    def __init__(self, base, user, pw):
        self.base, self.user, self.pw = base, user, pw
        self.token = None
    def login(self):
        r = self._req("POST", "/auth/login", {"username": self.user, "password": self.pw}, auth=False)
        self.token = r[2].get("access_token") if r[2] else None
        if not self.token:
            raise SystemExit(f"login failed: HTTP {r[0]}")
    def _req(self, method, path, body=None, auth=True, raw=False, timeout=30):
        url = self.base + path
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        if data is not None: req.add_header("Content-Type", "application/json")
        if auth and self.token: req.add_header("Cookie", "access_token=" + self.token)
        t0 = time.time()
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                payload = resp.read()
                ms = int((time.time() - t0) * 1000)
                if raw: return resp.status, ms, payload
                try: return resp.status, ms, json.loads(payload) if payload else {}
                except json.JSONDecodeError: return resp.status, ms, {}
        except urllib.error.HTTPError as e:
            ms = int((time.time() - t0) * 1000)
            try: detail = e.read()[:300]
            except Exception: detail = b""
            return e.code, ms, (detail if raw else {"detail": detail.decode(errors="replace")})
        except Exception as e:
            return 0, int((time.time() - t0) * 1000), (b"" if raw else {"detail": f"{type(e).__name__}: {e}"})

BACKEND_UNAVAILABLE = {0, 502, 503, 504}

def continuous_runs(segs, gap_tol):
    """Merge segments into continuous runs; gaps <= gap_tol s are bridged."""
    ivs = sorted((parse_iso(s["start_time"]), parse_iso(s["end_time"])) for s in segs)
    runs = []
    for a, b in ivs:
        if runs and (a - runs[-1][1]).total_seconds() <= gap_tol:
            runs[-1][1] = max(runs[-1][1], b)
        else:
            runs.append([a, b])
    return runs

def build_inventory(api, hours_back, gap_tol, log):
    r = api._req("GET", "/streams")
    if r[0] != 200: raise SystemExit(f"/streams HTTP {r[0]}")
    streams = r[2].get("streams", r[2] if isinstance(r[2], list) else [])
    cams = [s["camera_id"] for s in streams if s.get("recording_enabled")]
    t_end = datetime.now(timezone.utc) - timedelta(minutes=20)   # stay clear of the live edge
    t_start = t_end - timedelta(hours=hours_back)
    inv = {}
    for c in cams:
        # /recording/segments pages at limit<=1000 (default 100!) and its `total`
        # field mirrors the page size, not the true count — paginate to the end.
        segs, off = [], 0
        while True:
            r = api._req("GET", f"/recording/segments?camera_id={c}&start={iso(t_start)}"
                                f"&end={iso(t_end)}&limit=1000&offset={off}", timeout=60)
            if r[0] != 200:
                log({"ev": "inventory_error", "camera": c, "http": r[0], "offset": off})
                break
            page = r[2].get("segments", [])
            segs.extend(page)
            if len(page) < 1000 or off > 20000: break
            off += 1000
        if segs: inv[c] = continuous_runs(segs, gap_tol)
        time.sleep(0.1)
    return inv, t_start, t_end

def windows_with_coverage(inv, t_start, t_end, window_s, step_s=300):
    out = []
    t = t_start
    win = timedelta(seconds=window_s)
    while t + win <= t_end:
        covering = [c for c, runs in inv.items()
                    if any(a <= t and t + win <= b for a, b in runs)]
        if len(covering) >= 16: out.append((t, covering))
        t += timedelta(seconds=step_s)
    return out

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--base", default="http://100.107.51.72:8000")
    p.add_argument("--user", default="admin"); p.add_argument("--password", default="admin")
    p.add_argument("--hours-back", type=float, default=12)
    p.add_argument("--window", type=float, default=90, help="wall window seconds")
    p.add_argument("--gap-tol", type=float, default=3.0, help="max bridged gap seconds")
    p.add_argument("--pace", type=float, default=150)
    p.add_argument("--run-hours", type=float, default=6)
    p.add_argument("--plan-only", action="store_true")
    p.add_argument("--jsonl", default="wall-soak.jsonl")
    a = p.parse_args()

    jf = open(a.jsonl, "a", buffering=1)
    def log(d):
        d["ts"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
        jf.write(json.dumps(d) + "\n")

    api = Api(a.base, a.user, a.password); api.login()
    inv, t0, t1 = build_inventory(api, a.hours_back, a.gap_tol, log)
    wins = windows_with_coverage(inv, t0, t1, a.window)
    print(f"inventory: {len(inv)} cameras with footage; "
          f"{len(wins)} candidate windows of {a.window:.0f}s with >=16 continuous cells "
          f"(lookback {a.hours_back}h, gap-tol {a.gap_tol}s)")
    for t, cov in wins[:8]:
        print(f"  {iso(t)}  cameras={len(cov)}")
    if a.plan_only or not wins:
        if not wins: print("NO full-16 windows — widen --gap-tol or shorten --window (do not lower the 16 bar)")
        return 0 if wins else 1

    # ---- run ----
    stats = {"cycles": 0, "full16": 0, "backend_unavailable": 0, "cold503": 0, "cold_ok": 0,
             "post_prewarm_503": 0, "zero_byte": 0, "defects": 0, "leaked": []}
    live = {"sid": None}
    def dispose(sid, reason):
        r = api._req("DELETE", f"/review/mosaic-sessions/{sid}")
        ok = r[0] in (200, 204)
        if not ok:
            r = api._req("DELETE", f"/review/mosaic-sessions/{sid}")   # one retry
            ok = r[0] in (200, 204)
        log({"ev": "dispose", "sid": sid, "http": r[0], "ok": ok, "reason": reason})
        if not ok: stats["leaked"].append(sid)
        live["sid"] = None
    def bail(*_):
        if live["sid"]: dispose(live["sid"], "signal")
        log({"ev": "abort", "stats": stats}); sys.exit(1)
    signal.signal(signal.SIGTERM, bail); signal.signal(signal.SIGINT, bail)

    end = time.time() + a.run_hours * 3600
    last_inv = time.time()
    while time.time() < end:
        cyc_start = time.time()
        if time.time() - last_inv > 3600:            # refresh inventory hourly; windows age out
            api.login()
            inv, t0, t1 = build_inventory(api, a.hours_back, a.gap_tol, log)
            wins = windows_with_coverage(inv, t0, t1, a.window)
            last_inv = time.time()
            log({"ev": "inventory_refresh", "cameras": len(inv), "windows": len(wins)})
        if not wins:
            log({"ev": "no_windows"}); time.sleep(a.pace); continue
        t, covering = random.choice(wins)
        cams = random.sample(covering, 16)
        ws, we = iso(t), iso(t + timedelta(seconds=a.window))
        stats["cycles"] += 1
        cyc = {"ev": "cycle", "n": stats["cycles"], "wall_start": ws, "cams": cams}

        code, ms, body = api._req("POST", "/review/mosaic-sessions",
            {"camera_ids": cams, "wall_start": ws, "wall_end": we,
             "layout": {"cols": 4, "rows": 4}})
        cyc["create_http"], cyc["create_ms"] = code, ms
        if code in BACKEND_UNAVAILABLE:
            stats["backend_unavailable"] += 1; cyc["class"] = "backend-unavailable"
            log(cyc); time.sleep(max(0, a.pace - (time.time() - cyc_start))); continue
        if code != 200:
            stats["defects"] += 1; cyc["class"] = "create-defect"; cyc["detail"] = str(body)[:200]
            log(cyc); time.sleep(max(0, a.pace - (time.time() - cyc_start))); continue
        sid = body.get("session_id"); live["sid"] = sid
        cells = body.get("cells", [])
        frags = (body.get("manifest") or {}).get("fragments", [])
        cyc["sid"], cyc["cells"] = sid, len(cells)
        cyc["frags_ready"] = sum(1 for f in frags if f.get("availability") == "ready")
        if len(cells) == 16: stats["full16"] += 1
        else:
            stats["defects"] += 1; cyc["class"] = "cells<16"
            # every camera passed the continuity proof — a missing cell is a wall defect
            cyc["missing"] = [c for c in cams if c not in
                              {cl.get("camera_id") for cl in cells}]

        # cold GET before prewarm — the known contract gap, tracked not failed
        code, ms, payload = api._req("GET", f"/review/mosaic-sessions/{sid}/seg/0.ts", raw=True, timeout=20)
        cyc["cold_http"], cyc["cold_ms"] = code, ms
        if code == 503: stats["cold503"] += 1
        elif code == 200: stats["cold_ok"] += 1; cyc["cold_bytes"] = len(payload)

        # prewarm (202, async) then POLL
        code, ms, _ = api._req("POST", f"/review/mosaic-sessions/{sid}/prewarm", {"at_frag": 0, "ahead": 2})
        cyc["prewarm_http"] = code
        served, sms, sbytes = None, None, None
        t_poll = time.time()
        while time.time() - t_poll < 90:
            code, ms, payload = api._req("GET", f"/review/mosaic-sessions/{sid}/seg/0.ts", raw=True, timeout=30)
            if code == 200:
                served, sms, sbytes = True, int((time.time() - t_poll) * 1000), len(payload); break
            if code in (404,) or code not in BACKEND_UNAVAILABLE and code != 503:
                served = False; cyc["poll_final_http"] = code; break
            time.sleep(2)
        if served:
            cyc["served_ms"], cyc["seg_bytes"] = sms, sbytes
            if sbytes == 0:
                stats["zero_byte"] += 1; stats["defects"] += 1; cyc["class"] = "zero-byte-segment"
        else:
            stats["post_prewarm_503"] += 1; stats["defects"] += 1
            cyc["class"] = cyc.get("class") or "unserved-after-prewarm"
        dispose(sid, "cycle-end")
        log(cyc)
        time.sleep(max(0, a.pace - (time.time() - cyc_start)))

    log({"ev": "done", "stats": stats})
    print(json.dumps(stats, indent=1))
    return 0

if __name__ == "__main__":
    sys.exit(main())
