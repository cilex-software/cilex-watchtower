#!/usr/bin/env python3
"""Pins warden.app_version() — and specifically that it does NOT cache a MISS forever.

THE DEFECT THIS EXISTS FOR (2026-09-23). app_version() reads the Watchtower startup
banner out of the flight-recorder log and matches it on the pid Warden supervises,
caching the result because a version cannot change for a given pid. It cached
UNCONDITIONALLY — so one call made before the app had flushed its banner stored
(pid, None), and every later call short-circuited on the pid guard and returned None
for the life of that process. A single early read made the field permanently null.

It was found on a live guard station by the Windows station agent, from an asymmetry
no unit test would have produced: wt-office-01 and wt-sm-vnutri-01, identical Warden
1.4.8 on identical Windows, one reporting 1.1.548 and one null. The office box's
Warden is started by `schtasks /run` from a SYSTEM job and beats almost immediately;
the booth's was started by hand. Same code, opposite outcome — which is what a
timing-dependent cache looks like.

Case 1 is the regression. Cases 2-4 pin the reasons the fix is bounded rather than
simply `if found:` — a station whose build predates the banner must not re-read a
multi-megabyte log on every beat for ever.

  python3 tools/tests/warden-app-version.py
"""
import importlib.util
import pathlib
import sys
import tempfile
import time

PID = 9796
BANNER = ("2026-09-23T17:45:01 I [x] === watchtower start v1.1.548 pid=%d "
          "build=55ae6457 qt=6.12.0 os=Windows ===\n" % PID)

spec = importlib.util.spec_from_file_location(
    "warden", pathlib.Path(__file__).resolve().parents[2] / "warden" / "warden.py")
w = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(w)
except SystemExit:
    pass

fails = 0


def ok(cond, what):
    global fails
    if not cond:
        fails += 1
    print("%s %s" % ("PASS" if cond else "FAIL", what))


def fresh(spawned_ago=0.0):
    """A throwaway flightrec dir and a cold cache, so nothing real is touched."""
    d = pathlib.Path(tempfile.mkdtemp())
    w.FLTREC = d
    w._APP_VER.update(pid=None, ver=None)
    w.HB["app_pid"] = PID
    w.HB["app_spawned"] = None if spawned_ago is None else time.time() - spawned_ago
    return d / "watchtower.log"


# 1. THE REGRESSION
log = fresh(spawned_ago=0)
log.write_text("early lines, no banner yet\n", encoding="utf-8")
first = w.app_version()
log.write_text("early lines, no banner yet\n" + BANNER, encoding="utf-8")
ok(first is None and w.app_version() == "1.1.548",
   "a miss BEFORE the banner is flushed does not poison the pid for ever")

# 2. a settled miss stops re-reading: no banner and the app is long past the grace
log = fresh(spawned_ago=w.BANNER_GRACE_S + 60)
log.write_text("a build that emits no banner\n", encoding="utf-8")
w.app_version()
ok(dict(w._APP_VER) == {"pid": PID, "ver": None},
   "a SETTLED miss is cached, so a bannerless build stops re-reading the log")

# 3. a hit is still cached — the property that made the cache correct in the first place
log = fresh(spawned_ago=0)
log.write_text(BANNER, encoding="utf-8")
ok(w.app_version() == "1.1.548" and dict(w._APP_VER) == {"pid": PID, "ver": "1.1.548"},
   "a hit is cached: a version cannot change for a given pid")

# 4. Warden did not spawn this app, so it cannot judge the banner's age
log = fresh(spawned_ago=None)
log.write_text("no banner\n", encoding="utf-8")
w.app_version()
ok(dict(w._APP_VER) == {"pid": PID, "ver": None},
   "unknown spawn time accepts the miss rather than scanning for ever")

# 5. no app at all
w._APP_VER.update(pid=None, ver=None)
w.HB["app_pid"] = None
ok(w.app_version() is None, "no app pid -> None, never a guess")

print("%d FAILED" % fails if fails else "all passed")
sys.exit(1 if fails else 0)
