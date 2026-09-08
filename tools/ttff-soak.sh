#!/usr/bin/env bash
# Overnight time-to-first-frame soak (operator goal 2026-09-08).
# Three surfaces, three targets: single-camera playback 1 s · 16-cell wall 2 s · live open 500 ms.
# Each cycle launches the REAL app under the real harness hooks, captures the timing lines,
# and appends one JSON row per measurement. Read-only against the backend except review/mosaic
# sessions, which the app disposes itself.
#
#   WT_CV_USER / WT_CV_PASS must be exported (an OPERATOR account; never admin/admin).
#   tools/ttff-soak.sh --cycles 40 --out /tmp/ttff-soak.jsonl
set -euo pipefail
cd "$(dirname "$0")/.."
CYCLES=20; OUT=/tmp/ttff-soak.jsonl; PAUSE=45; CAM=${WT_TTFF_CAM:-192.168.1.126}
WALL_TIMEOUT=${WT_SOAK_WALL_TIMEOUT:-70}   # the mosaic can take >60 s to its first frame today; a cut run logs -1, not its true number
BUILD="$(git rev-parse --short HEAD 2>/dev/null || echo ?)+bin@$(date -r build/watchtower +%H:%M 2>/dev/null || echo ?)"   # which binary produced the row
while [ $# -gt 0 ]; do case "$1" in --cycles) CYCLES=$2; shift 2;; --out) OUT=$2; shift 2;; --pause) PAUSE=$2; shift 2;; *) shift;; esac; done
# Keep the app log of every run that MISSED its target or produced no number — "investigate
# reasons" needs the [PBTIME]/[WALLTIME]/[LIVETIME] stages, and a JSON row alone cannot say why.
LOGDIR=${OUT%.jsonl}-logs; mkdir -p "$LOGDIR"
keep(){ if [ -n "${WT_SOAK_KEEP_ALL:-}" ] || [ "$2" -lt 0 ] || [ "$2" -gt "$3" ]; then mv "$1" "$LOGDIR/c${c}-$4.log"; else rm -f "$1"; fi; }   # WT_SOAK_KEEP_ALL=1 keeps every log
export WT_CV_URL=${WT_CV_URL:-http://127.0.0.1:8000} WT_CV_AUTOLOGIN=1 WT_TRACE=1
# Credential: env, or a 0600 file handed over out of band (two lines: user, then password).
CRED=${WT_TTFF_CRED:-$HOME/.config/watchtower-warden/ttff-soak.cred}
if [ -z "${WT_CV_USER:-}" ] && [ -r "$CRED" ]; then
  [ "$(stat -c %a "$CRED")" = "600" ] || { echo "refusing $CRED: mode must be 600" >&2; exit 2; }
  WT_CV_USER=$(sed -n 1p "$CRED"); WT_CV_PASS=$(sed -n 2p "$CRED"); export WT_CV_USER WT_CV_PASS
fi
: "${WT_CV_USER:?export WT_CV_USER or provide $CRED}"; : "${WT_CV_PASS:?export WT_CV_PASS}"
case "$WT_CV_USER" in admin) echo "refusing to soak as admin — use an operator/soak account" >&2; exit 2;; esac
# prove the credential BEFORE a 6-hour run, not 45 s into it
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H 'Content-Type: application/json'   -d "{\"username\":\"$WT_CV_USER\",\"password\":\"$WT_CV_PASS\"}" "$WT_CV_URL/auth/login" 2>/dev/null || echo 0)
[ "$code" = "200" ] || { echo "login as $WT_CV_USER -> HTTP $code; not starting" >&2; exit 3; }
# Dispose a mosaic session the killed app could not: its 6 h render chase otherwise runs on until
# the NEXT cycle's wall open reaps it — through the next playback measurement, on a pilot database
# that is already the bottleneck (overnight cycles 15-21, 2026-09-08). Password via stdin, never argv.
dispose_mosaic(){
  # The token from the login BODY as an explicit Cookie header: curl's jar replay of the HttpOnly
  # cookie answered 401 here (measured 2026-09-08 18:5x), the header answers 204.
  local tok; tok=$(printf '{"username":"%s","password":"%s"}' "$WT_CV_USER" "$WT_CV_PASS" | curl -s -H 'Content-Type: application/json' -d @- "$WT_CV_URL/auth/login" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
  echo "disposed mosaic $1 -> $(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: access_token=$tok" -X DELETE "$WT_CV_URL/review/mosaic-sessions/$1")"
}
log(){ printf '{"ts":"%s","cycle":%d,"surface":"%s","dt_ms":%s,"note":"%s"}\n' "$(date -u +%FT%TZ)" "$1" "$2" "$3" "$4" >> "$OUT"; }
DAY=$(date -d yesterday +%F)
for ((c=1;c<=CYCLES;c++)); do
  # 1) single-camera playback: WT_TTFF_DAYS drives openForDay and prints [TTFF] day=… ttff=…ms
  # No WT_PLAYBACK_DAY: that boot-opens the day COLD (whole-day manifest, 12-17 s of server index,
  # measured 2026-09-08) and the harness's measured click 12 s later lands on top of it. A guard
  # clicks a loaded calendar; the TTFF click at tick 12 is that click, with the coverage cache in.
  L=$(mktemp); WT_PLAYBACK_IP=$CAM WT_TTFF_DAYS="$DAY" timeout 70 ./run.sh >"$L" 2>&1 || true
  v=$(grep -oE '\[TTFF\] day=[^ ]+ ttff=-?[0-9]+' "$L" | tail -1 | grep -oE '[-0-9]+$' || echo -1); log $c playback "$v" "day=$DAY cam=$CAM build=$BUILD"; keep "$L" "$v" 1000 playback
  # 2) 16-cell wall: WT_WALL_DAY=live opens the mosaic; [WALLTIME] first_frame dt=…
  L=$(mktemp); WT_WALL_DAY=live timeout "$WALL_TIMEOUT" ./run.sh >"$L" 2>&1 || true
  v=$(grep -oE '\[WALLTIME\] first_frame dt=[0-9]+' "$L" | head -1 | grep -oE '[0-9]+$' || echo -1)
  cells=$(grep -oE 'cells=[-0-9]+' "$L" | head -1 | cut -d= -f2 || echo "?"); log $c wall "$v" "cells=$cells build=$BUILD"
  sid=$(grep -oE '\[WALL\] session=[0-9a-f-]{36}' "$L" | head -1 | sed 's/.*session=//'); keep "$L" "$v" 2000 wall
  [ -n "$sid" ] && dispose_mosaic "$sid"
  # 3) live open from the wall: WT_FOCUS_IP shows the detail view for one camera; [LIVETIME] playing dt=…
  # WT_FOCUS_DELAY_MS: click only once the wall is lit — a guard's open, not a cold one the instant /streams lands
  L=$(mktemp); WT_FOCUS_IP=$CAM WT_FOCUS_DELAY_MS=12000 timeout 45 ./run.sh >"$L" 2>&1 || true
  v=$(grep -oE '\[LIVETIME\] playing dt=[0-9]+' "$L" | head -1 | grep -oE '[0-9]+$' || echo -1); log $c live "$v" "cam=$CAM build=$BUILD"; keep "$L" "$v" 500 live
  sleep "$PAUSE"
done
echo "done -> $OUT"
