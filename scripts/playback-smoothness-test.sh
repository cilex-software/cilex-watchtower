#!/usr/bin/env bash
# Playback smoothness + timer/frame-sync test.
#
# Verifies that recorded playback for a camera plays SMOOTHLY (video frames keep
# arriving while the playhead advances — never a frozen frame while the timer
# ticks) and that the playhead timer stays IN SYNC with the presented frames.
#
# Mechanism: launches Watchtower with the in-app smoothness probe
# (WT_SMOOTHTEST=<seconds>, see qml/PlaybackScreen.qml). The probe counts
# presented video frames vs. the playhead position every 100 ms; a "stall" =
# playing + position advancing + NO new frame (the exact desync bug where the
# timer free-runs over dead air / a PTS reset). Asserts stalls == 0.
#
# Needs a real display (decodes video) and a reachable backend. For a
# motion-triggered camera it auto-picks the latest motion event (footage exists
# there); for a continuous camera pass an instant or it uses ~2h ago.
#
# Usage:
#   scripts/playback-smoothness-test.sh                      # .106 (motion) + .108 (continuous)
#   scripts/playback-smoothness-test.sh 192.168.1.106        # one camera, auto-pick time
#   scripts/playback-smoothness-test.sh 192.168.1.108 2026-06-14T10:00:00
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/build/watchtower"
CV="${WT_CV_URL:-http://192.168.1.79:8000}"
USER="${WT_CV_USER:-admin}"; PASS="${WT_CV_PASS:-admin}"
SECS="${WT_SMOOTHTEST_SECS:-35}"
COOKIE="$(mktemp)"; trap 'rm -f "$COOKIE"' EXIT
curl -s --max-time 8 -c "$COOKIE" -X POST "$CV/auth/login" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$USER\",\"password\":\"$PASS\"}" -o /dev/null || { echo "login failed"; exit 2; }

cam_id() { curl -s --max-time 8 -b "$COOKIE" "$CV/streams" | python3 -c "import sys,json;d=json.load(sys.stdin);a=d if isinstance(d,list) else d.get('streams',d.get('items',[]));print(next((c.get('camera_id') or c.get('id') for c in a if c.get('ip')=='$1'),''))" 2>/dev/null; }

# latest motion-clip start (local 'YYYY-MM-DDTHH:MM:SS') for a camera, else ""
latest_motion_local() {
  local cid; cid="$(cam_id "$1")"; [ -z "$cid" ] && return
  curl -s --max-time 10 -b "$COOKIE" "$CV/events?camera_id=$cid&event_type=motion_started&limit=1" \
    | python3 -c "
import sys,json,datetime
d=json.load(sys.stdin); evs=d.get('events') or []
if not evs: sys.exit()
t=evs[0].get('start_time') or evs[0].get('start') or ''
try:
    dt=datetime.datetime.fromisoformat(str(t).replace('Z','+00:00')).astimezone()
    print((dt+datetime.timedelta(seconds=15)).strftime('%Y-%m-%dT%H:%M:%S'))   # +15s: openAt rewinds 15s
except: pass" 2>/dev/null
}

run_one() {  # $1=ip $2=instant(optional)
  local ip="$1" inst="$2"
  [ -z "$inst" ] && inst="$(latest_motion_local "$ip")"
  [ -z "$inst" ] && inst="$(date +%Y-%m-%dT%H:%M:%S -d '2 hours ago')"
  local out; out="$(mktemp)"
  WT_CV_AUTOLOGIN=1 WT_CV_URL="$CV" WT_CV_USER="$USER" WT_CV_PASS="$PASS" \
  WT_PLAYBACK_IP="$ip" WT_PLAYBACK_DAY="$inst" WT_SMOOTHTEST="$SECS" \
  timeout $((SECS + 25)) "$BIN" >/dev/null 2>"$out"
  local sum; sum="$(grep -hE 'WTSMOOTH SUMMARY' "$out" | sed -E 's/.*qml: //' | tail -1)"
  local stalls; stalls="$(echo "$sum" | grep -oE 'stalls=[0-9]+' | cut -d= -f2)"
  echo "  $ip @ $inst -> ${sum:-<no summary — see $out>}"
  if [ "${stalls:-1}" = "0" ]; then echo "    PASS"; rm -f "$out"; return 0
  else echo "    FAIL (log: $out)"; return 1; fi
}

[ -x "$BIN" ] || { echo "build first: cmake --build build"; exit 2; }
echo "Playback smoothness test (${SECS}s each):"
rc=0
if [ $# -ge 1 ]; then run_one "$1" "${2:-}" || rc=1
else run_one 192.168.1.106 "" || rc=1; run_one 192.168.1.108 "" || rc=1; fi
echo; [ $rc -eq 0 ] && echo "ALL PASS" || echo "FAILURES"; exit $rc
