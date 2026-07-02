#!/bin/bash
# Calendar + historic-playback soak supervisor. Drives a watchtower build under WT_CAL_STRESS against
# the REAL backend (degraded now: cameras unplugged = the reported condition), samples RSS/CPU, and on
# any crash OR GUI hang (heartbeat stalled >HANG while the process is alive) records the cause + the
# [CAL]/[PBSTOP] actions leading up to it, then relaunches. Self-contained. Arg: end "HH:MM" (default
# 08:00) or END_EPOCH. Env overrides:
#   WT_SOAK_BIN  binary to run           (default ./build/watchtower = Qt 6.12 primary)
#   WT_SOAK_QT   Qt runtime gcc_64 dir   (default ~/Qt/6.12.0/gcc_64; set ~/Qt/6.8.3/gcc_64 for the fallback)
#   WT_SOAK_DIR  output dir              (default /tmp/cal_soak)
# NB: runs on real Wayland (below), NOT offscreen — Qt 6.12's offscreen QPA SIGBUSes under churn
# (offscreen-only bug); the real display is clean.
cd /home/cilex-vision/projects/cilex-watchtower
BIN=${WT_SOAK_BIN:-./build/watchtower}
export WAYLAND_DISPLAY=wayland-0 DISPLAY=:0 XDG_RUNTIME_DIR=/run/user/1000
# Harness: WT_CAL_STRESS (calendar/playback only, default) or WT_GUARD_SOAK (comprehensive —
# Live wall/fullscreen/replace/layouts + Events + playback-wall + the calendar/playback block).
export WT_CV_AUTOLOGIN=1 "${WT_SOAK_HARNESS:-WT_CAL_STRESS}"=1 WT_TRACE=1 WT_SMOOTHTEST=90000
# Pin the Qt runtime (default 6.12; the binary alone loads system Qt otherwise → ABI mismatch).
WT_SOAK_QT=${WT_SOAK_QT:-$HOME/Qt/6.12.0/gcc_64}
export LD_LIBRARY_PATH="$WT_SOAK_QT/lib" QT_PLUGIN_PATH="$WT_SOAK_QT/plugins" \
       QML_IMPORT_PATH="$WT_SOAK_QT/qml" QML2_IMPORT_PATH="$WT_SOAK_QT/qml"

D=${WT_SOAK_DIR:-/tmp/cal_soak}; mkdir -p "$D"
INC="$D/incidents.log"; APP_LOG="$D/app.log"; SUP="$D/supervisor.log"
END=${END_EPOCH:-$(date -d "today ${1:-08:00}" +%s)}
[ "$END" -le "$(date +%s)" ] && END=$(date -d "tomorrow ${1:-08:00}" +%s)
HANG=120         # seconds with no [WT-MEM]/[CAL] heartbeat (proc alive) => GUI wedge
log(){ echo "[$(date '+%m-%d %H:%M:%S')] $*" | tee -a "$SUP"; }

log "CAL SOAK START — $BIN (Qt: ${WT_SOAK_QT:-system}), runs until $(date -d @$END '+%a %H:%M'), hang-detect=${HANG}s"
{ echo "=== BASELINE $(date)  bin=$BIN  qt=${WT_SOAK_QT:-system} ==="; free -m | head -2
  echo "backend login timing:"; curl -s -m 15 -o /dev/null -w "  login HTTP %{http_code} in %{time_total}s\n" \
      -H 'Content-Type: application/json' -d '{"username":"admin","password":"admin"}' \
      http://192.168.1.79:8000/auth/login 2>&1
  echo "go2rtc: $(docker stats --no-stream --format '{{.MemUsage}}' go2rtc 2>/dev/null)"; } >> "$INC"

secs=$(( END - $(date +%s) )); [ "$secs" -lt 1 ] && secs=1
python3 docs/perf/soak-tools/guard_sampler.py "$D/samples.csv" "$secs" > "$D/sampler.log" 2>&1 &
SAMPLER=$!

run=0
while [ "$(date +%s)" -lt "$END" ]; do
  run=$((run+1)); started=$(date +%s); reason=""
  log "launch #$run"
  echo "==== LAUNCH #$run $(date) ====" >> "$APP_LOG"
  "$BIN" >> "$APP_LOG" 2>&1 &
  APP=$!
  last_hb=$(grep -ac -e 'WT-MEM' -e '\[CAL\]' -e '\[GUARD\]' "$APP_LOG"); stall=0
  while [ "$(date +%s)" -lt "$END" ]; do
    sleep 15
    kill -0 "$APP" 2>/dev/null || { reason="crash"; break; }
    hb=$(grep -ac -e 'WT-MEM' -e '\[CAL\]' -e '\[GUARD\]' "$APP_LOG")
    if [ "$hb" -gt "$last_hb" ]; then last_hb=$hb; stall=0; else stall=$((stall+15)); fi
    if [ "$stall" -ge "$HANG" ]; then reason="hang"; break; fi
  done
  if [ -z "$reason" ]; then
    kill -9 "$APP" 2>/dev/null; log "end time reached — clean stop (run #$run healthy)"; break
  fi
  alive=$(( $(date +%s) - started ))
  tag=$([ "$reason" = hang ] && echo "HANG/GUI-WEDGE" || echo "CRASH/KILL")
  { echo ""; echo "########## $tag  run #$run  $(date)  (alive ${alive}s, stall ${stall}s) ##########"
    { [ "$reason" = hang ] && echo "-- cause: heartbeat stalled ${stall}s while process ALIVE => GUI wedge"; }
    tail -12 "$APP_LOG" | grep -aE 'WT-FATAL|signal|Terminated|Killed|CRITICAL|assert' | sed 's/^/   /'
    echo "-- [CAL]/[GUARD] actions leading up to it (most recent last):"; grep -aE '\[CAL\]|\[GUARD\]' "$APP_LOG" | tail -8 | sed 's/^/   /'
    echo "-- last [PBSTOP]:"; grep -a '\[PBSTOP\]' "$APP_LOG" | tail -3 | sed 's/^/   /'
    echo "-- last [WT-MEM]:"; grep -a 'WT-MEM' "$APP_LOG" | tail -1 | sed 's/^/   /'
    echo "-- last 5 app.log lines:"; tail -5 "$APP_LOG" | sed 's/^/   /'
    echo "-- host: $(free -m | awk 'NR==2{print $3" MB used, "$7" MB avail"}')"
  } >> "$INC"
  kill -9 "$APP" 2>/dev/null; pkill -9 -x watchtower 2>/dev/null
  log "$tag run #$run (alive ${alive}s) — recorded; relaunching per scenario"
  sleep 3
done
kill -9 "$SAMPLER" 2>/dev/null; pkill -9 -x watchtower 2>/dev/null
log "DONE — $run launch(es), crashes=$(grep -c 'CRASH/KILL' "$INC" 2>/dev/null), hangs=$(grep -c 'HANG/GUI-WEDGE' "$INC" 2>/dev/null), samples=$(wc -l < "$D/samples.csv" 2>/dev/null)"
echo "CAL_SOAK_COMPLETE"
