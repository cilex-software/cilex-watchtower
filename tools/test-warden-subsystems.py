#!/usr/bin/env python3
"""Contract tests for Warden's `subsystems` / `app_last_beat_at` beat fields.

    python3 tools/test-warden-subsystems.py [path/to/warden.py]

stdlib only, no network, no station token, safe on a live station: it points the
module's FLTREC at a temp dir and writes synthetic flight-recorder lines, so nothing
real is read or touched.

Why this exists rather than a manual check: the fields encode CV's contract from
`docs/letters/2026-08-10-p0-silent-playback-loss.reply.md` — the name grammar, the
8-subsystem cap, and "ok" being the ONLY healthy string. Those are easy to break
silently. And test 9 guards the failure mode that actually bit us: a throw inside
payload() propagates out of the heartbeat thread and kills it with no log at all,
which is how Warden 1.3.1 stopped beating for two days without anyone noticing.
"""

import importlib.util
import os
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT = HERE.parent / "warden" / "warden.py"
target = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT
if not target.is_file():
    print("warden.py not found at %s" % target)
    sys.exit(2)

spec = importlib.util.spec_from_file_location("warden_under_test", target)
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)

w.FLTREC = Path(tempfile.mkdtemp(prefix="wt-subsys-"))
logf = w.FLTREC / "watchtower.log"
now = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime())
fails = 0


def check(label, got, want):
    global fails
    ok = got == want
    if not ok:
        fails += 1
    print("  %-52s %s" % (label, "PASS" if ok else "FAIL got=%r want=%r" % (got, want)))


def write(lines):
    logf.write_text("\n".join(lines) + "\n", encoding="utf-8")


print("warden %s — %s\n" % (w.WARDEN_VERSION, target))

print("1. app running, fresh tick")
write(["%s I [1] [MEMTEL] up=1s" % now])
w.HB["app_state"] = "running"
s = w.subsystems()
check("watchtower state", s["watchtower"]["state"], "ok")
check("carries 'since' = when Watchtower last beat", "since" in s["watchtower"], True)

print("2. app running but the recorder is silent = FROZEN wall")
os.utime(logf, (time.time() - 300, time.time() - 300))
s = w.subsystems()
check("watchtower state", s["watchtower"]["state"], "fault")
check("reason", s["watchtower"].get("reason"), "no_beat")

print("3. app stopped on purpose")
os.utime(logf, None)
w.HB["app_state"] = "stopped_expected"
w.HB["app_state_reason"] = "warden_stopping"
s = w.subsystems()
check("watchtower state", s["watchtower"]["state"], "fault")
check("reason carries app_state", s["watchtower"].get("reason"), "stopped_expected")

print("4. playback FAULT declared by the app")
w.HB["app_state"] = "running"
write(["%s I [1] [MEMTEL] up=1s" % now,
       "%s W [2] [WT-DEGRADED] subsystem=playback reason=auth state=FAULT "
       "detail=Token expired" % now])
s = w.subsystems()
check("playback state", s["playback"]["state"], "fault")
check("playback reason", s["playback"].get("reason"), "auth")
check("playback detail", s["playback"].get("detail"), "Token expired")

print("5. CLEARED wins over an earlier FAULT (newest-wins)")
write(["%s W [2] [WT-DEGRADED] subsystem=playback reason=auth state=FAULT detail=x" % now,
       "%s I [2] [WT-DEGRADED] subsystem=playback state=CLEARED" % now])
check("playback state", w.subsystems()["playback"]["state"], "ok")

print("6. the refresh-and-retry breadcrumb is NOT a verdict")
write(["%s W [2] [WT-DEGRADED] subsystem=playback reason=auth "
       "action=refresh-and-retry attempt=1" % now])
check("no entry from a state-less line", "playback" in w.subsystems(), False)

print("7. a hostile subsystem name cannot mint label cardinality")
write(["%s W [2] [WT-DEGRADED] subsystem=Evil/Name;DROP state=FAULT" % now])
check("bad name rejected", [k for k in w.subsystems() if k != "watchtower"], [])

print("8. CV's cap of 8 subsystems per beat")
write(["%s W [2] [WT-DEGRADED] subsystem=s%d state=FAULT" % (now, i) for i in range(12)])
check("at most 8", len(w.subsystems()) <= 8, True)

print("9. subsystems() NEVER raises — a throw would kill the beat (the 1.3.1 defect)")
w.FLTREC = Path("Z:/does/not/exist")
try:
    check("returns a dict on a broken path", isinstance(w.subsystems(), dict), True)
except Exception as e:                                   # noqa: BLE001
    check("returns a dict on a broken path", "raised %r" % e, "no raise")

print("\nFAILURES: %d" % fails)
sys.exit(1 if fails else 0)
