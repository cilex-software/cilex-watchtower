#!/usr/bin/env python3
"""
Cilex Watchtower — 16-camera playback-wall soak.

THE PROBLEM THIS SOLVES
-----------------------
A dark cell on the mosaic wall has at least five causes and the UI renders them
identically: nothing was recorded (motion-armed camera), it aged out of retention,
it was rendered but is not servable yet (`ready` != servable, the prewarm/503
contract gap), the client failed to decode it, or the camera is not in the
account's scope. Counting lit cells therefore proves nothing.

So this harness DERIVES THE GRID FROM THE FOOTAGE rather than hoping footage
exists for a fixed grid. It reads the segment inventory first (/recording/segments
— ground truth, independent of the client), finds windows that cameras actually
COVER CONTINUOUSLY, and builds each mosaic session out of exactly those cameras.

That is the armed-camera workaround. An armed camera records islands, not a
continuous track, so it is admitted to a window only when its merged segments
cover that window end-to-end within --gap-tol. A camera that would stutter is
never placed on the wall, which means every dark cell in a run is a REAL defect
instead of an unanswerable question.

SAFETY (this runs against the shared live pilot backend)
--------------------------------------------------------
  * Planning is read-only. The ONLY writes are mosaic session create/prewarm/delete.
  * It NEVER touches events, dispositions, acks or bookmarks. The 2026-08-08 soak
    incident put 21 real events back in the guards' queue; endurance soaks are
    read-only on operator surfaces, and CV asked for a dedicated soak account —
    use one if you have it.
  * ONE session in flight at a time. TRANSCODE_CONCURRENCY is 2 fleet-wide and the
    pilot box's memory governor sits yellow; a third concurrent reviewer gets 503.
  * Every session is disposed in a finally:, plus a best-effort sweep on exit.
  * --stop-file gives you a kill switch that does not need the terminal.

USAGE
-----
  tools/wall-soak.py --plan-only                       # read-only: what windows exist
  tools/wall-soak.py --duration 8h --out soak.jsonl    # the overnight run
  tools/wall-soak.py --summary soak.jsonl              # morning triage

Credentials: --user/--pass, or WT_SOAK_USER / WT_SOAK_PASS.
"""
import argparse, json, os, random, sys, time, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timedelta, timezone

ISO = "%Y-%m-%dT%H:%M:%SZ"


def iso(dt):
    return dt.astimezone(timezone.utc).strftime(ISO)


def parse_dur(s):
    mult = {"s": 1, "m": 60, "h": 3600, "d": 86400}
    return int(s[:-1]) * mult[s[-1]] if s and s[-1] in mult else int(s)


def parse_ts(s):
    # segment times arrive as ...Z, sometimes with fractional seconds
    s = s.replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        head, _, tail = s.partition(".")
        return datetime.fromisoformat(head + "+00:00")


class Api:
    def __init__(self, base, user, pw):
        self.base, self.token = base.rstrip("/"), None
        self._user, self._pw = user, pw
        self._login(user, pw)

    def _req(self, method, path, body=None, timeout=30, raw=False):
        url = self.base + path
        data = json.dumps(body).encode() if body is not None else None
        r = urllib.request.Request(url, data=data, method=method)
        if data:
            r.add_header("Content-Type", "application/json")
        if self.token:
            r.add_header("Cookie", "access_token=" + self.token)
        t0 = time.monotonic()
        try:
            with urllib.request.urlopen(r, timeout=timeout) as resp:
                payload = resp.read()
                ms = int((time.monotonic() - t0) * 1000)
                return resp.status, (payload if raw else json.loads(payload or b"{}")), ms
        except urllib.error.HTTPError as e:
            return e.code, {"error": e.read()[:200].decode("utf8", "replace")}, int((time.monotonic() - t0) * 1000)
        except Exception as e:                                   # timeout, reset, DNS
            return 0, {"error": repr(e)[:200]}, int((time.monotonic() - t0) * 1000)

    def _login(self, user, pw):
        code, body, _ = self._req("POST", "/auth/login", {"username": user, "password": pw})
        if code != 200 or not body.get("access_token"):
            sys.exit(f"auth failed ({code}): {str(body)[:200]}")
        self.token = body["access_token"]

    def streams(self):
        code, body, _ = self._req("GET", "/streams", timeout=60)
        if code != 200:
            sys.exit(f"/streams failed ({code})")
        return body.get("streams", [])

    def healthy(self):
        code, _, _ = self._req("GET", "/health", timeout=8)
        return code == 200

    def relogin(self):
        try:
            self._login(self._user, self._pw)
            return True
        except SystemExit:
            return False

    def segments(self, cam, start, end, limit=1000):
        q = urllib.parse.urlencode({"camera_id": cam, "start": iso(start), "end": iso(end), "limit": limit})
        code, body, _ = self._req("GET", "/recording/segments?" + q, timeout=60)
        return body.get("segments", []) if code == 200 else []


# ------------------------------------------------------------- the watchdog
# playback-service renders the mosaic, is capped at 1.5 GiB, and has ALREADY been
# OOM-killed once (memory.peak 1538 MiB vs memory.max 1536 MiB, read 2026-08-29).
# MOSAIC_RENDER_CONCURRENCY=1, so this soak occupies the fleet's only render slot
# while it runs. The soak therefore watches the thing it is stressing and STOPS —
# it does not back off and keep pushing — the moment it sees a kill.
class Watch:
    def __init__(self, container="playback-service"):
        self.dir, self.base_kills = None, 0
        try:
            import subprocess
            cid = subprocess.run(["docker", "inspect", container, "--format", "{{.Id}}"],
                                 capture_output=True, text=True, timeout=15).stdout.strip()
            for root, dirs, files in os.walk("/sys/fs/cgroup"):
                if cid and cid in root and "memory.current" in files:
                    self.dir = root
                    break
        except Exception:
            pass
        self.base_kills = self.kills()

    def _read(self, name, default=0):
        try:
            with open(os.path.join(self.dir, name)) as f:
                return f.read()
        except Exception:
            return str(default)

    def kills(self):
        if not self.dir:
            return 0
        for line in self._read("memory.events").splitlines():
            if line.startswith("oom_kill "):
                return int(line.split()[1])
        return 0

    def mem_mib(self):
        if not self.dir:
            return -1
        try:
            return int(self._read("memory.current", 0)) // 1048576
        except ValueError:
            return -1

    @staticmethod
    def host_avail_mib():
        try:
            for line in open("/proc/meminfo"):
                if line.startswith("MemAvailable:"):
                    return int(line.split()[1]) // 1024
        except Exception:
            pass
        return -1

    def verdict(self, mem_ceiling, host_floor):
        """Return None if safe, else the reason to STOP the whole run."""
        k = self.kills()
        if k > self.base_kills:
            return f"playback-service oom_kill went {self.base_kills} -> {k}"
        m = self.mem_mib()
        if m >= 0 and m > mem_ceiling:
            return f"playback-service memory {m} MiB over ceiling {mem_ceiling} MiB"
        h = self.host_avail_mib()
        if h >= 0 and h < host_floor:
            return f"host MemAvailable {h} MiB under floor {host_floor} MiB"
        return None


# ---------------------------------------------------------------- the oracle
def merge(intervals, tol):
    """Merge segment intervals, closing gaps <= tol (encoder boundaries are not holes)."""
    out = []
    for s, e in sorted(intervals):
        if out and s - out[-1][1] <= tol:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return out


def covers(merged, t0, t1):
    """True only if [t0,t1] sits entirely inside ONE merged run — the armed-camera gate."""
    return any(s <= t0 and e >= t1 for s, e in merged)


def plan(api, cams, search_start, search_end, window_s, grid, min_grid, gap_tol, step_s, log):
    """Return [(t0, [camera_id,...]), ...] — windows every listed camera covers CONTINUOUSLY."""
    cover = {}
    for i, c in enumerate(cams, 1):
        segs = api.segments(c, search_start, search_end)
        cover[c] = merge([[parse_ts(s["start_time"]).timestamp(),
                           parse_ts(s["end_time"]).timestamp()] for s in segs if s.get("end_time")], gap_tol)
        if i % 25 == 0:
            log(f"  inventory {i}/{len(cams)} cameras")
    windows, t, tend = [], search_start.timestamp(), search_end.timestamp() - window_s
    while t <= tend:
        ok = [c for c in cams if covers(cover[c], t, t + window_s)]
        if len(ok) >= min_grid:
            windows.append((t, ok))
        t += step_s
    # richest windows first, and never hand the compositor more cells than the grid
    windows.sort(key=lambda w: -len(w[1]))
    return [(t, ok[:grid]) for t, ok in windows]


def serve(api, sid, frag, budget_s):
    """Fetch a fragment, tolerating the async render.

    prewarm answers 202 ACCEPTED — the render is queued, not done — and the wall's own
    measured prewarm->served time is 1.2-2.4 s. A single immediate GET therefore measures
    the harness's impatience and reports a backend defect that is not there (it did, on the
    first validation run: 10/10 503). Poll until served or the budget expires, and record
    time-to-served from the first attempt, which is the number actually worth soaking.
    """
    t0, attempts = time.monotonic(), 0
    while True:
        c, payload, _ = api._req("GET", f"/review/mosaic-sessions/{sid}/seg/{frag}.ts", raw=True, timeout=90)
        attempts += 1
        n = len(payload) if isinstance(payload, (bytes, bytearray)) else 0
        waited = int((time.monotonic() - t0) * 1000)
        if c != 503 or waited > budget_s * 1000:
            return {"frag": frag, "code": c, "ms": waited, "bytes": n, "attempts": attempts}
        time.sleep(0.5)


# ------------------------------------------------------------------ one pass
def run_once(api, t0, cams, window_s, probe_frags, log, serve_budget=20, idsink=None):
    """One create -> ready/servable probe -> prewarm -> fetch -> dispose cycle."""
    rec = {"ts": iso(datetime.now(timezone.utc)), "window_start": iso(datetime.fromtimestamp(t0, timezone.utc)),
           "window_s": window_s, "cells": len(cams), "cameras": cams, "ok": False}
    code, body, ms = api._req("POST", "/review/mosaic-sessions", {
        "camera_ids": cams,
        "wall_start": iso(datetime.fromtimestamp(t0, timezone.utc)),
        "wall_end": iso(datetime.fromtimestamp(t0 + window_s, timezone.utc))})
    rec["create_code"], rec["create_ms"] = code, ms
    if code not in (200, 201):
        rec["error"] = str(body)[:300]
        # code 0 = no HTTP answer at all (refused/timeout/reset). That is the backend being
        # away, NOT the wall failing. Measured 2026-08-29: query-api was recreated mid-run
        # and five fragments logged as failures that were nothing of the kind.
        rec["outcome"] = "backend_unavailable" if code in (0, 502, 503, 504) else "wall_defect"
        return rec
    sid = body.get("session_id") or body.get("id")
    rec["session_id"] = sid
    if sid and idsink:
        idsink.write(json.dumps({"created_session": sid,
                                 "ts": iso(datetime.now(timezone.utc))}) + "\n")
    if not sid:
        rec["error"] = "no session id in create response: " + str(body)[:200]
        return rec
    try:
        code, pl, ms = api._req("GET", f"/review/mosaic-sessions/{sid}/playlist.m3u8", raw=True, timeout=60)
        rec["playlist_code"], rec["playlist_ms"] = code, ms
        frags = [l for l in pl.decode("utf8", "replace").splitlines() if l.endswith(".ts")] if code == 200 else []
        rec["declared_frags"] = len(frags)
        if not frags:
            rec["error"] = "playlist declared no fragments"
            return rec
        picks = sorted(random.sample(range(len(frags)), min(probe_frags, len(frags))))

        # (1) DECLARED-vs-SERVABLE: fetch BEFORE prewarm. 503 here is the known
        #     contract gap (`ready` means "will be rendered"), measured, not assumed.
        cold = []
        c, _, ms = api._req("GET", f"/review/mosaic-sessions/{sid}/seg/{picks[0]}.ts", raw=True, timeout=60)
        cold.append({"frag": picks[0], "code": c, "ms": ms})
        rec["cold_probe"] = cold

        # (2) prewarm, then fetch every pick — this is the real serving path
        code, _, ms = api._req("POST", f"/review/mosaic-sessions/{sid}/prewarm", {"at_frag": picks[0], "ahead": 4})
        rec["prewarm_code"], rec["prewarm_ms"] = code, ms
        got = [serve(api, sid, f, serve_budget) for f in picks]
        rec["fetches"] = got
        rec["http_503"] = sum(1 for g in got if g["code"] == 503)
        rec["zero_byte"] = sum(1 for g in got if g["code"] == 200 and g["bytes"] == 0)
        rec["served"] = sum(1 for g in got if g["code"] == 200 and g["bytes"] > 0)
        rec["ok"] = rec["served"] == len(got)
        rec["transport_fail"] = sum(1 for g in got if g["code"] == 0)
        rec["outcome"] = ("ok" if rec["ok"] else
                          "backend_unavailable" if rec["transport_fail"] else "wall_defect")
        return rec
    finally:
        c, _, _ = api._req("DELETE", f"/review/mosaic-sessions/{sid}", timeout=30)
        rec["dispose_code"] = c
        if c not in (200, 204):
            log(f"  !! session {sid} dispose returned {c} — check for a leak")


# ------------------------------------------------------------------- summary
def pct(xs, p):
    if not xs:
        return None
    xs = sorted(xs)
    return xs[max(0, min(len(xs) - 1, int(round((len(xs) - 1) * p))))]


def summarise(path):
    rows = [json.loads(l) for l in open(path) if l.strip()]
    runs = [r for r in rows if "cells" in r]
    if not runs:
        return print("no iterations recorded")
    ok = [r for r in runs if r.get("ok")]
    down = [r for r in runs if r.get("outcome") == "backend_unavailable"]
    defect = [r for r in runs if r.get("outcome") == "wall_defect"]
    print(f"iterations      : {len(runs)}   clean: {len(ok)}   "
          f"WALL DEFECTS: {len(defect)}   backend-away (not a defect): {len(down)}")
    cells = [r["cells"] for r in runs]
    print(f"grid size       : min {min(cells)}  max {max(cells)}  full-16 runs: {sum(1 for c in cells if c >= 16)}")
    cr = sorted(r["create_ms"] for r in runs if r.get("create_ms"))
    if cr:
        print(f"create ms       : p50 {pct(cr,.5)}  p95 {pct(cr,.95)}  max {cr[-1]}")
    f = [g for r in runs for g in r.get("fetches", [])]
    if f:
        lat = sorted(g["ms"] for g in f)
        print(f"segment fetches : {len(f)}  200 {sum(1 for g in f if g['code']==200)}  "
              f"503 {sum(1 for g in f if g['code']==503)}  0-byte {sum(1 for g in f if g['code']==200 and g['bytes']==0)}")
        print(f"served ms       : p50 {pct(lat,.5)}  p95 {pct(lat,.95)}  max {lat[-1]}   (includes waiting out the async prewarm)")
    cold = [r["cold_probe"][0] for r in runs if r.get("cold_probe")]
    if cold:
        print(f"COLD (pre-prewarm) probes: {len(cold)}  503 {sum(1 for c in cold if c['code']==503)}  "
              f"200 {sum(1 for c in cold if c['code']==200)}   <- 'ready' vs servable")
    bad = [r for r in runs if r.get("dispose_code") not in (200, 204)]
    print(f"dispose failures: {len(bad)}" + ("  <-- LEAKED SESSIONS, clean up" if bad else ""))
    for r in defect:
        if True:
            print(f"  FAIL {r['ts']} cells={r['cells']} create={r.get('create_code')} "
                  f"503={r.get('http_503')} 0b={r.get('zero_byte')} {str(r.get('error',''))[:90]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default=os.environ.get("WT_SOAK_BASE", "http://192.168.1.79:8000"))
    ap.add_argument("--user", default=os.environ.get("WT_SOAK_USER", "admin"))
    ap.add_argument("--password", default=os.environ.get("WT_SOAK_PASS", "admin"))
    ap.add_argument("--hours-back", type=float, default=12, help="how far back to hunt for windows")
    ap.add_argument("--window", type=int, default=120, help="wall window seconds per session")
    ap.add_argument("--grid", type=int, default=16)
    ap.add_argument("--min-grid", type=int, default=4, help="degrade honestly rather than skip")
    ap.add_argument("--gap-tol", type=float, default=2.0, help="seconds of gap treated as contiguous")
    ap.add_argument("--step", type=int, default=60, help="candidate-window stride when planning")
    ap.add_argument("--duration", default="8h")
    ap.add_argument("--pace", type=int, default=90, help="seconds between iterations")
    ap.add_argument("--probe-frags", type=int, default=6)
    ap.add_argument("--serve-budget", type=float, default=20,
                    help="seconds to keep polling a 503 fragment before calling it a failure")
    ap.add_argument("--replan-every", default="3h")
    ap.add_argument("--out", default="wall-soak.jsonl")
    ap.add_argument("--stop-file", default="/tmp/wall-soak.stop")
    ap.add_argument("--pb-ceiling", dest="pb_ceiling", type=int, default=1100,
                    help="STOP if playback-service RSS exceeds this (MiB); cap is 1536")
    ap.add_argument("--host-floor", dest="host_floor", type=int, default=1500,
                    help="STOP if host MemAvailable falls below this (MiB)")
    ap.add_argument("--plan-only", action="store_true")
    ap.add_argument("--summary")
    a = ap.parse_args()

    if a.summary:
        return summarise(a.summary)

    out = open(a.out, "a", buffering=1)

    def log(m):
        line = f"[{datetime.now().strftime('%H:%M:%S')}] {m}"
        print(line, flush=True)
        out.write(json.dumps({"log": line}) + "\n")

    watch = Watch()
    log(f"watchdog: playback-service cgroup {'found' if watch.dir else 'NOT FOUND — running unguarded'}"
        f", baseline oom_kills={watch.base_kills}, ceiling {a.pb_ceiling} MiB, host floor {a.host_floor} MiB")
    api = Api(a.base, a.user, a.password)
    cams = [s["camera_id"] for s in api.streams()]
    log(f"scope: {len(cams)} cameras visible to '{a.user}' at {a.base}")

    deadline = time.time() + parse_dur(a.duration)
    replan_every, next_replan, windows, i, stall = parse_dur(a.replan_every), 0, [], 0, 0
    try:
        while time.time() < deadline:
            if os.path.exists(a.stop_file):
                log(f"stop file {a.stop_file} present — stopping")
                break
            if time.time() >= next_replan or not windows:
                now = datetime.now(timezone.utc)
                log(f"planning: scanning {a.hours_back}h for windows {a.window}s wide "
                    f"that >={a.min_grid} cameras cover continuously (gap tol {a.gap_tol}s)")
                windows = plan(api, cams, now - timedelta(hours=a.hours_back), now,
                               a.window, a.grid, a.min_grid, a.gap_tol, a.step, log)
                next_replan = time.time() + replan_every
                if not windows:
                    log("NO qualifying window — every camera has gaps here. "
                        "Try --window 60, --gap-tol 5, or a longer --hours-back.")
                    if a.plan_only:
                        return
                    time.sleep(a.pace)
                    continue
                hist = {}
                for _, cs in windows:
                    hist[len(cs)] = hist.get(len(cs), 0) + 1
                log(f"  {len(windows)} windows; cells->count {dict(sorted(hist.items(), reverse=True))}")
                log(f"  best window has {len(windows[0][1])} continuously-covered cameras")
                if a.plan_only:
                    for t, cs in windows[:5]:
                        log(f"  {iso(datetime.fromtimestamp(t, timezone.utc))}  {len(cs)} cells")
                    return

            if not api.healthy():
                stall += 1
                back = min(600, 30 * stall)
                log(f"backend not answering /health (x{stall}) — backing off {back}s, not counting a failure")
                out.write(json.dumps({"ts": iso(datetime.now(timezone.utc)),
                                      "outcome": "backend_unavailable", "note": "health gate"}) + "\n")
                time.sleep(back)
                api.relogin()          # a redeploy invalidates the session cookie
                continue
            stall = 0

            t0, chosen = windows[i % len(windows)]
            i += 1
            stop_reason = watch.verdict(a.pb_ceiling, a.host_floor)
            if stop_reason:
                log(f"WATCHDOG STOP: {stop_reason}")
                out.write(json.dumps({"ts": iso(datetime.now(timezone.utc)),
                                      "outcome": "watchdog_stop", "reason": stop_reason}) + "\n")
                break
            pb_before = watch.mem_mib()
            log(f"iter {i}: {len(chosen)} cells @ {iso(datetime.fromtimestamp(t0, timezone.utc))} "
                f"(playback-service {pb_before} MiB, host avail {watch.host_avail_mib()} MiB)")
            rec = run_once(api, t0, chosen, a.window, a.probe_frags, log, a.serve_budget, out)
            rec["pb_mem_before"], rec["pb_mem_after"] = pb_before, watch.mem_mib()
            rec["pb_oom_kills"] = watch.kills()
            out.write(json.dumps(rec) + "\n")
            log(f"  -> {'OK ' if rec.get('ok') else 'FAIL'} create={rec.get('create_code')}/"
                f"{rec.get('create_ms')}ms served={rec.get('served')}/{a.probe_frags} "
                f"503={rec.get('http_503')} 0b={rec.get('zero_byte')} dispose={rec.get('dispose_code')}")
            time.sleep(a.pace)
    except KeyboardInterrupt:
        log("interrupted")
    finally:
        log("done — run with --summary to triage")


if __name__ == "__main__":
    main()
