#!/usr/bin/env python3
"""Rock-n-roll soak (operator goal 2026-09-12): random, grouped actions through the REAL app via its
harness hooks, every timing line captured, outliers flagged on the spot.

  rows.jsonl      one row per run: action, group, params, metrics, primary, outcome, build, log
  outliers.jsonl  the flagged rows (kept logs live in logs/)
  events.log      what the operator's agent is woken for: first-seen outlier kinds at once, hourly digests
  queue.txt       action ids to run next (reproductions after a fix) — popped before the random pick
  notes.jsonl     hand-written cause/fix notes, joined into the report by rocknroll-report.py

Read-only against the pilot except review/mosaic sessions (disposed after each run) — no exports,
no acks, no arming, no PTZ (WT_SOAK_NOEXPORT=1 on every run).
"""
import json, os, random, re, statistics, subprocess, sys, time, datetime, signal, urllib.request, urllib.error, http.cookiejar

REPO = "/home/cilex-vision/projects/cilex-watchtower"
OUT = f"{REPO}/docs/perf/2026-09-12-rocknroll-soak"
DEADLINE = datetime.datetime(2026, 9, 12, 11, 0, 0).astimezone()   # local 11:00
INV = json.load(open(sys.argv[1])) if len(sys.argv) > 1 else {}
CRED = os.path.expanduser("~/.config/watchtower-warden/ttff-soak.cred")
USER, PASS = open(CRED).read().split("\n")[:2]
CV = "http://127.0.0.1:8000"
os.makedirs(f"{OUT}/logs", exist_ok=True)

def day(n): return (datetime.date.today() - datetime.timedelta(days=n)).isoformat()
def pick(k): v = INV.get(k) or []; return random.choice(v) if v else "192.168.1.105"

# ---------------- catalogue ----------------------------------------------------------------
# primary = (tag, key, agg) over the generic "[TAG] ... key=value" extraction; agg: first|median|max|min|count|last
C = [
 # LIVE
 dict(id="live_open_recording", group="LIVE", w=6, t=42, env=lambda: {"WT_FOCUS_IP": pick("wall_recording"), "WT_FOCUS_DELAY_MS": "12000", "WT_FOCUS_CLOSE_MS": "6000"}, primary=("LIVETIME", "playing dt", "first"), target=500),
 dict(id="live_open_armed",     group="LIVE", w=6, t=42, env=lambda: {"WT_FOCUS_IP": pick("wall_armed"), "WT_FOCUS_DELAY_MS": "12000", "WT_FOCUS_CLOSE_MS": "6000"}, primary=("LIVETIME", "playing dt", "first"), target=500),
 dict(id="live_open_offpage",   group="LIVE", w=3, t=42, env=lambda: {"WT_FOCUS_IP": random.choice([pick("offpage_recording"), pick("offpage_armed")]), "WT_FOCUS_DELAY_MS": "12000"}, primary=("LIVETIME", "playing dt", "first"), target=3500),
 dict(id="wall_lightup",        group="STARTUP", w=3, t=30, env=lambda: {}, primary=("STARTUP", "tiles16", "first"), target=5000),
 # PLAYBACK
 dict(id="pb_open_d1",   group="PLAYBACK", w=6, t=75, env=lambda: {"WT_PLAYBACK_IP": pick("wall_recording"), "WT_TTFF_DAYS": day(1)}, primary=("PBTIME", "first_frame dt@day", "first"), target=1000),
 dict(id="pb_open_d3",   group="PLAYBACK", w=3, t=75, env=lambda: {"WT_PLAYBACK_IP": pick("offpage_recording"), "WT_TTFF_DAYS": day(3)}, primary=("PBTIME", "first_frame dt@day", "first"), target=1000),
 dict(id="pb_open_d7",   group="PLAYBACK", w=2, t=75, env=lambda: {"WT_PLAYBACK_IP": pick("wall_recording"), "WT_TTFF_DAYS": day(7)}, primary=("PBTIME", "first_frame dt@day", "first"), target=1000),
 dict(id="pb_open_armed_d1", group="PLAYBACK", w=3, t=75, env=lambda: {"WT_PLAYBACK_IP": pick("wall_armed"), "WT_TTFF_DAYS": day(1)}, primary=("PBTIME", "first_frame dt@day", "first"), target=1000),
 dict(id="pb_cold_boot", group="PLAYBACK", w=2, t=85, env=lambda: {"WT_PLAYBACK_IP": pick("wall_recording"), "WT_PLAYBACK_DAY": day(1), "WT_TTFF_DAYS": day(1)}, primary=("PBTIME", "first_frame dt", "first"), target=3000),
 dict(id="pb_seek",      group="PLAYBACK", w=3, t=130, env=lambda: {"WT_PLAYBACK_IP": pick("wall_recording"), "WT_PLAYBACK_DAY": day(1), "WT_SEEK_TEST": "1", "WT_SEEK_ITERS": "6"}, primary=("SK", ["lat", "act"], "median"), target=4000),
 dict(id="pb_churn",     group="PLAYBACK", w=2, t=160, env=lambda: {"WT_PLAYBACK_IP": pick("wall_recording"), "WT_PLAYBACK_DAY": day(1), "WT_CHURNTEST": "6", "WT_CHURN_ALT": day(2), "WT_FRAME_MODE": "1"}, primary=("CHURN", "switches", "last"), target=None),
 dict(id="pb_rollover",  group="PLAYBACK", w=2, t=95, env=lambda: {"WT_PLAYBACK_IP": pick("wall_recording"), "WT_TTFF_DAYS": day(1), "WT_TTFF_EOS": "1"}, primary=("PBTIME", "first_frame dt@day", "first"), target=1000),
 dict(id="pb_smooth",    group="PLAYBACK", w=3, t=95, env=lambda: {"WT_PLAYBACK_IP": pick("wall_recording"), "WT_PLAYBACK_DAY": day(1), "WT_SMOOTHTEST": "30"}, primary=("WTSMOOTH", "maxStall", "last"), target=2000),
 dict(id="pb_frame_mode",group="PLAYBACK", w=2, t=65, env=lambda: {"WT_PLAYBACK_IP": pick("wall_recording"), "WT_PLAYBACK_DAY": day(1), "WT_FRAME_MODE": "1"}, primary=("STRIP", "lit", "last"), target=None),
 # WALL
 dict(id="wall_live",    group="WALL", w=4, t=125, env=lambda: {"WT_WALL_DAY": "live"}, primary=("WALLTIME", "first_frame dt", "first"), target=None),
 dict(id="wall_day1",    group="WALL", w=2, t=125, env=lambda: {"WT_WALL_DAY": day(1)}, primary=("WALLTIME", "first_frame dt", "first"), target=None),
 # EVENTS
 dict(id="hero",         group="EVENTS", w=3, t=65, env=lambda: {"WT_HERO_TEST": "1"}, primary=("HT", "lat", "median"), target=3000),
 dict(id="events_section", group="EVENTS", w=3, t=60, env=lambda: {"WT_SECTION": "events", "WT_EVENTS_TEST": "1"}, primary=("EV", "lat", "median"), target=1500),
 # UI
 dict(id="tabs",         group="UI", w=2, t=45, env=lambda: {"WT_TABS": ",".join(random.sample((INV.get("wall_recording") or []) + (INV.get("wall_armed") or []), 4)), "WT_TABS_HOME": "1"}, primary=("STARTUP", "tiles16", "first"), target=5000),
 dict(id="group_grid",   group="UI", w=2, t=45, env=lambda: {"WT_GROUP": random.choice(INV.get("groups") or ["Улица"])}, primary=("EVIMG", "ms", "median"), target=3000),
 dict(id="section_health", group="UI", w=1, t=40, env=lambda: {"WT_SECTION": "health"}, primary=("PBTIME", "streams_http ms", "first"), target=5000),
 dict(id="nav",          group="UI", w=2, t=95, env=lambda: {"WT_NAVTEST": "6"}, primary=("NAV", "ui", "max"), target=1500),
 dict(id="resize",       group="UI", w=2, t=65, env=lambda: {"WT_RESIZE_TEST": "1"}, primary=("RT", "n", "last"), target=None),
 dict(id="calstress",    group="UI", w=2, t=125, env=lambda: {"WT_PLAYBACK_IP": pick("wall_recording"), "WT_CAL_STRESS": "1"}, primary=("CAL", "gap", "max"), target=15000),
 # STRESS
 dict(id="guard_soak",   group="STRESS", w=2, t=95, env=lambda: {"WT_GUARD_SOAK": "1", "WT_GUARD_LIVE_MS": "12000", "WT_THUMB_REFRESH_MS": "700"}, primary=("GUARD", "err", "count"), target=0),
 dict(id="fsoak",        group="STRESS", w=2, t=125, env=lambda: {"WT_FSOAK": "1"}, primary=("FSOAK", "violation", "count"), target=0),
 dict(id="wall_churn",   group="STRESS", w=2, t=65, env=lambda: {"WT_WALL_CHURN": "2000"}, primary=("WT-MEM", "rss_growth", "first"), target=150),
 dict(id="night_soak",   group="STRESS", w=2, t=125, env=lambda: {"WT_NIGHT_SOAK": "1"}, primary=("NTIME", "ms", "max"), target=15000),
]
BY_ID = {c["id"]: c for c in C}

# ---------------- backend ---------------------------------------------------------------
cj = http.cookiejar.CookieJar(); OP = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj)); TOK = ""
def api(m, path, data=None, timeout=60):
    r = urllib.request.Request(CV + path, data=json.dumps(data).encode() if data is not None else None, headers={"Content-Type": "application/json", "Cookie": f"access_token={TOK}" if TOK else ""}, method=m)
    t = time.monotonic()
    try: x = OP.open(r, timeout=timeout); b = x.read(); return x.status, int((time.monotonic() - t) * 1000), b, x.headers.get("Server-Timing", "")
    except urllib.error.HTTPError as e: return e.code, int((time.monotonic() - t) * 1000), b"", ""
    except Exception as e: return 0, int((time.monotonic() - t) * 1000), b"", str(e)[:60]
def login():
    global TOK
    c, ms, b, _ = api("POST", "/auth/login", {"username": USER, "password": PASS})
    if c == 200: TOK = json.loads(b).get("access_token", "")
    return c
def dispose(log_text):
    for sid in set(re.findall(r"\[WALL\] session=([0-9a-f-]{36})", log_text)):
        c = api("DELETE", f"/review/mosaic-sessions/{sid}")[0]
        if c == 401 and login() == 200: c = api("DELETE", f"/review/mosaic-sessions/{sid}")[0]
def docker_cpu():
    try:
        o = subprocess.run(["docker", "stats", "--no-stream", "--format", "{{.Name}} {{.CPUPerc}}"], capture_output=True, text=True, timeout=20).stdout
        return {l.split()[0]: float(l.split()[1].rstrip("%")) for l in o.splitlines() if l.split()[0] in ("timescaledb", "query-api", "recorder-service", "go2rtc")}
    except Exception: return {}
def backend_probe():
    m = {}
    for name, path in (("health", "/health"), ("events", "/events?limit=50"), ("streams", "/streams"), ("coverage", f"/review/coverage?camera_id=hiwatch-083bc17adca6")):
        c, ms, b, st = api("GET", path)
        if c == 401 and login() == 200: c, ms, b, st = api("GET", path)
        m[f"{name}_ms"] = ms; m[f"{name}_code"] = c
    m.update({f"cpu_{k}": v for k, v in docker_cpu().items()})
    return m

# ---------------- extraction --------------------------------------------------------------
TS = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})")
def ts(l):
    m = TS.match(l)
    return int(datetime.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S.%f").timestamp() * 1000) if m else None
KV = re.compile(r"([A-Za-z_][A-Za-z_ ]{0,24}?)[=:]\s*(-?\d+(?:\.\d+)?)(?:ms)?\b")
def extract(text):
    """metrics[(tag,key)] -> list of numbers; plus derived STARTUP / WT-MEM / counts."""
    M = {}
    def add(tag, key, v): M.setdefault((tag, key.strip()), []).append(float(v))
    first_pipe = None; delivers = []; rss = []; opens = []
    for l in text.splitlines():
        t = ts(l)
        mt = re.search(r"\[([A-Z][A-Z-]+)\]", l) or re.search(r"\b(WTSMOOTH)\b", l)
        if mt:
            tag = mt.group(1); body = l[mt.end():]
            for k, v in KV.findall(body):
                k = k.strip()
                last = k.split()[-1] if k else ""
                if k and not k[0].isdigit() and last not in ("t", "req", "pos", "gen", "status", "off", "frac", "code", "bytes"): add(tag, k, v)
            if " FAIL" in body or "-> FAIL" in body: add(tag, "fail", 1)
            if " PASS" in body: add(tag, "pass", 1)
            if tag == "PBTIME" and "tag=" in l:            # per-open-kind keys: first_frame dt@day / @span60 / @seekfar …
                kind = re.search(r"tag=([a-z0-9]+)", l).group(1)
                for k, v in KV.findall(body):
                    k = k.strip()
                    if k and k.split()[-1] in ("dt",) : add(tag, f"{k}@{kind}", v)
            if tag == "LIVETIME" and "pipeline_playing" in l and first_pipe is None and t: first_pipe = t
            if tag == "LIVETIME" and "first_deliver" in l and t: delivers.append(t)
            if tag == "LIVETIME" and "[LIVETIME] open" in l and t: opens.append(t)
            if tag == "LIVETIME" and "hd_promoted" in l and t and opens: add("LIVETIME", "hd_dt", t - opens[-1])
            if tag == "WT-MEM":
                r = re.search(r"rss=(\d+)MB", l);  rss.append(int(r.group(1))) if r else None
            if tag == "GUARD" and " ERR" in l: add("GUARD", "err", 1)
            if tag == "FSOAK" and "VIOLATION" in l: add("FSOAK", "violation", 1)
            if tag == "STRIP":
                r = re.search(r"lit=(\d+)/", l); add("STRIP", "lit", r.group(1)) if r else None
            if tag == "CAL" and t:
                M.setdefault(("CAL", "_t"), []).append(t)
    if first_pipe and len(delivers) >= 16: add("STARTUP", "tiles16", sorted(delivers)[15] - first_pipe)
    elif first_pipe and delivers: add("STARTUP", "tiles_lit", len(delivers))
    if rss: add("WT-MEM", "rss_growth", max(rss) - rss[0]); add("WT-MEM", "rss_last", rss[-1])
    if ("CAL", "_t") in M:
        tt = M.pop(("CAL", "_t")); gaps = [b - a for a, b in zip(tt, tt[1:])]
        for g in gaps: add("CAL", "gap", g)
    counts = {"corrupt": text.count("Packet corrupt"), "vasync": text.count("vaSyncSurface failed"), "swd": text.count("[WT-SWD]"), "tier_down": text.count("[TIER] step down"), "http5xx": len(re.findall(r'" 5\d\d ', text)), "evpoll_backoff": text.count("[EVPOLL]"), "gui_stall_max": max([int(x) for x in re.findall(r"gui_stall (\d+) ms", text)] or [0])}
    crash = re.search(r"killed by signal (\d+) \(([A-Za-z ]+)\)", text)
    return M, counts, (crash.group(1) + " " + crash.group(2)) if crash and crash.group(1) != "15" else None

def primary_value(M, spec):
    tag, key, agg = spec
    keys = key if isinstance(key, list) else [key]
    vals = []
    for want in keys:                       # first key that has values wins; a key may carry the word before it
        for (tg, k), v in M.items():
            if tg == tag and (want == "*" or k == want or k.endswith(" " + want)): vals += v
        if vals: break
    if not vals: return 0.0 if agg == "count" else None   # a count with nothing to count is 0, not "no metric"
    return {"first": vals[0], "last": vals[-1], "median": statistics.median(vals), "max": max(vals), "min": min(vals), "count": len(vals)}[agg]

# ---------------- run loop ----------------------------------------------------------------
BUILD = subprocess.run(["git", "-C", REPO, "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
def build_stamp():
    try: return f"{BUILD}+bin@{datetime.datetime.fromtimestamp(os.path.getmtime(REPO + '/build/watchtower')).strftime('%d%H%M')}"
    except Exception: return BUILD
def event(line):
    with open(f"{OUT}/events.log", "a") as f: f.write(f"{datetime.datetime.now().strftime('%H:%M:%S')} {line}\n")
def run_app(env, timeout, logpath):
    e = dict(os.environ); e.update({"WT_TRACE": "1", "WT_HLS_LOG": "1", "WT_CV_URL": CV, "WT_CV_AUTOLOGIN": "1", "WT_CV_USER": USER, "WT_CV_PASS": PASS, "WT_SOAK_NOEXPORT": "1"}); e.update(env)
    with open(logpath, "w") as lf:
        try: subprocess.run(["timeout", str(timeout), "./run.sh"], cwd=REPO, env=e, stdout=lf, stderr=subprocess.STDOUT, timeout=timeout + 30)
        except subprocess.TimeoutExpired: pass
    subprocess.run(["pkill", "-f", f"^{REPO}/build/watchtower"], capture_output=True)

hist = {}; seen_kinds = set(); digest = {"runs": 0, "outliers": 0, "kinds": {}}; last_action = None
n = sum(1 for _ in open(f"{OUT}/rows.jsonl")) if os.path.exists(f"{OUT}/rows.jsonl") else 0   # restarts continue the numbering
login(); event(f"START rocknroll soak until {DEADLINE:%H:%M} local; build {build_stamp()}; {len(C)} actions in {len({c['group'] for c in C})} groups")
next_digest = time.time() + 3600
while datetime.datetime.now().astimezone() < DEADLINE:
    n += 1
    # 1. what to run: queued reproduction first, else weighted random, never the same twice in a row
    q = f"{OUT}/queue.txt"; forced = None
    if os.path.exists(q):
        lines = [l.strip() for l in open(q) if l.strip()]
        if lines: forced = lines[0]; open(q, "w").write("\n".join(lines[1:]) + ("\n" if lines[1:] else ""))
    forced_params = None
    if forced and " " in forced:                        # "action {json}" pins the parameters of a reproduction
        forced, js = forced.split(" ", 1)
        try: forced_params = json.loads(js)
        except Exception: forced_params = None
    if forced in BY_ID: c = BY_ID[forced]
    else:
        pool = [c for c in C if c["id"] != last_action]
        c = random.choices(pool, weights=[c["w"] for c in pool])[0]
    last_action = c["id"]
    if n % 8 == 0:   # 2. a backend probe row between app runs
        m = backend_probe(); pv = m.get("events_ms")
        row = {"ts": datetime.datetime.now().isoformat(timespec="seconds"), "n": n, "group": "BACKEND", "action": "api_probe", "params": {}, "metrics": m, "primary": pv, "outcome": "ok", "build": build_stamp()}
        bad = [k for k, v in m.items() if k.endswith("_ms") and v > {"events_ms": 2000, "coverage_ms": 5000, "streams_ms": 5000, "health_ms": 1000}.get(k, 5000)] + [k for k, v in m.items() if k.endswith("_code") and v != 200]
        if bad: row["outcome"] = "outlier"; row["reason"] = "slow_or_failed:" + ",".join(bad)
        open(f"{OUT}/rows.jsonl", "a").write(json.dumps(row, ensure_ascii=False) + "\n")
        if bad:
            open(f"{OUT}/outliers.jsonl", "a").write(json.dumps(row, ensure_ascii=False) + "\n"); digest["outliers"] += 1
            kind = "api_probe:" + row["reason"]; digest["kinds"][kind] = digest["kinds"].get(kind, 0) + 1
            if kind not in seen_kinds: seen_kinds.add(kind); event(f"OUTLIER first-seen {kind} metrics={m}")
        digest["runs"] += 1
    # 3. the app run
    params = c["env"]()
    if forced_params: params.update(forced_params)
    logpath = f"{OUT}/logs/n{n:04d}-{c['id']}.log"
    t0 = time.time(); run_app(params, c["t"], logpath); dur = int(time.time() - t0)
    text = open(logpath, errors="replace").read(); dispose(text)
    M, counts, crash = extract(text); pv = primary_value(M, c["primary"])
    metrics = {f"{tg}.{k}": (round(statistics.median(v), 1) if len(v) > 1 else v[0]) for (tg, k), v in M.items() if tg in (c["primary"][0], "STARTUP", "WT-MEM", "LIVETIME", "PBTIME", "WALLTIME", "TTFF")}
    metrics.update({f"count.{k}": v for k, v in counts.items() if v})
    reason = None
    h = hist.setdefault(c["id"], [])
    if crash: reason = "crash:" + crash
    elif (c["primary"][0], "fail") in M: reason = "harness_fail"
    elif pv is None: reason = "no_metric"
    elif c["target"] is not None and ((c["primary"][2] == "count" and pv > c["target"]) or (c["primary"][2] != "count" and pv > c["target"])): reason = f"over_target:{pv}>{c['target']}"
    elif len(h) >= 5 and pv > 2.5 * statistics.median(h) and pv > 200: reason = f"over_2.5x_median:{pv}>{2.5*statistics.median(h):.0f}"
    if pv is not None and not crash: h.append(pv)
    row = {"ts": datetime.datetime.now().isoformat(timespec="seconds"), "n": n, "group": c["group"], "action": c["id"], "params": params, "dur_s": dur, "primary": pv, "metrics": metrics, "outcome": "outlier" if reason else "ok", "reason": reason, "build": build_stamp(), "forced": bool(forced), "target": c["target"], "primary_spec": "%s.%s.%s" % (c["primary"][0], c["primary"][1] if isinstance(c["primary"][1], str) else "|".join(c["primary"][1]), c["primary"][2])}
    if reason: row["log"] = os.path.relpath(logpath, OUT)
    else: os.remove(logpath)
    open(f"{OUT}/rows.jsonl", "a").write(json.dumps(row, ensure_ascii=False) + "\n"); digest["runs"] += 1
    if reason:
        open(f"{OUT}/outliers.jsonl", "a").write(json.dumps(row, ensure_ascii=False) + "\n"); digest["outliers"] += 1
        kind = f"{c['id']}:{reason.split(':')[0]}"; digest["kinds"][kind] = digest["kinds"].get(kind, 0) + 1
        if kind not in seen_kinds or forced: seen_kinds.add(kind); event(f"OUTLIER {'reproduced' if forced else 'first-seen'} n={n} {c['id']} reason={reason} primary={pv} log={row.get('log')} params={params}")
    elif forced: event(f"REPRO-OK n={n} {c['id']} primary={pv} (no outlier after the fix)")
    if time.time() >= next_digest:
        event(f"DIGEST runs={digest['runs']} outliers={digest['outliers']} kinds={digest['kinds']}"); digest = {"runs": 0, "outliers": 0, "kinds": {}}; next_digest = time.time() + 3600
    time.sleep(4)
event(f"FINISHED at {datetime.datetime.now():%H:%M}; runs={n}; see rows.jsonl")
