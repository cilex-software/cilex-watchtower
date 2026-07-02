#!/bin/bash
# Extended Live-screen guard-usage soak supervisor (v2 — now HANG-AWARE). Runs watchtower under WT_GUARD_SOAK
# until the end time, samples RSS/CPU, and on any crash/kill OR GUI hang (heartbeat stalled while the process
# is still alive — the wedge the first run hit) records the death/hang cause + the [GUARD] actions that led to
# it, then relaunches and continues. Self-contained. Args: optional end "HH:MM" (default 12:00) — or set END_EPOCH.
cd /home/cilex-vision/projects/cilex-watchtower
# Primary Qt 6.12 / build (override WT_QT + BIN for the 6.8.3 fallback). Runs on real
# Wayland (below) — NOT offscreen, where Qt 6.12 SIGBUSes; that bug is offscreen-only.
QT=${WT_QT:-/home/cilex-vision/Qt/6.12.0/gcc_64}
BIN=${WT_BIN:-./build/watchtower}
export LD_LIBRARY_PATH=$QT/lib QT_PLUGIN_PATH=$QT/plugins QML_IMPORT_PATH=$QT/qml QML2_IMPORT_PATH=$QT/qml
export WAYLAND_DISPLAY=wayland-0 DISPLAY=:0 XDG_RUNTIME_DIR=/run/user/1000
export WT_CV_AUTOLOGIN=1 WT_SECTION=live WT_GUARD_SOAK=1

D=/tmp/guard_test; mkdir -p "$D"
INC="$D/incidents.log"; APP_LOG="$D/app.log"; SUP="$D/supervisor.log"
END=${END_EPOCH:-$(date -d "today ${1:-12:00}" +%s)}
[ "$END" -le "$(date +%s)" ] && END=$(date -d "tomorrow ${1:-12:00}" +%s)
HANG=120         # seconds with no MEMTEL/[GUARD] heartbeat (proc alive) ⇒ GUI wedge
log(){ echo "[$(date '+%m-%d %H:%M:%S')] $*" | tee -a "$SUP"; }

log "GUARD SOAK v2 START — runs until $(date -d @$END '+%a %H:%M'), hang-detect=${HANG}s"
{ echo "=== BASELINE $(date) ==="; free -m | head -2
  echo "go2rtc: $(docker stats --no-stream --format '{{.MemUsage}} restarts='"$(docker inspect go2rtc --format '{{.RestartCount}}' 2>/dev/null)" go2rtc 2>/dev/null)"; } >> "$INC"

secs=$(( END - $(date +%s) )); [ "$secs" -lt 1 ] && secs=1
python3 /tmp/guard_sampler.py "$D/samples.csv" "$secs" > "$D/sampler.log" 2>&1 &
SAMPLER=$!

run=0
while [ "$(date +%s)" -lt "$END" ]; do
  run=$((run+1)); started=$(date +%s); reason=""
  log "launch #$run"
  echo "==== LAUNCH #$run $(date) ====" >> "$APP_LOG"
  "$BIN" >> "$APP_LOG" 2>&1 &
  APP=$!
  last_hb=$(grep -ac -e MEMTEL -e '\[GUARD\]' "$APP_LOG"); stall=0
  while [ "$(date +%s)" -lt "$END" ]; do
    sleep 15
    kill -0 "$APP" 2>/dev/null || { reason="crash"; break; }
    hb=$(grep -ac -e MEMTEL -e '\[GUARD\]' "$APP_LOG")
    if [ "$hb" -gt "$last_hb" ]; then last_hb=$hb; stall=0; else stall=$((stall+15)); fi
    if [ "$stall" -ge "$HANG" ]; then reason="hang"; break; fi
  done
  if [ -z "$reason" ]; then
    kill -9 "$APP" 2>/dev/null; log "end time reached — clean stop (run #$run healthy)"; break
  fi
  alive=$(( $(date +%s) - started ))
  tag=$([ "$reason" = hang ] && echo "HANG/GUI-WEDGE" || echo "CRASH/KILL")
  { echo ""; echo "########## $tag  run #$run  $(date)  (alive ${alive}s, stall ${stall}s) ##########"
    echo "-- cause:"; { [ "$reason" = hang ] && echo "   heartbeat stalled ${stall}s while process ALIVE ⇒ GUI wedge"; }
    tail -10 "$APP_LOG" | grep -aE 'WT-FATAL|signal|Terminated|Killed|MEMGUARD|G_IS_OBJECT' | sed 's/^/   /'
    echo "-- [GUARD] actions leading up to it (most recent last):"; grep -a '\[GUARD\]' "$APP_LOG" | tail -8 | sed 's/^/   /'
    echo "-- last [MEMTEL]:"; grep -a MEMTEL "$APP_LOG" | tail -1 | sed 's/^/   /'
    echo "-- last 5 app.log lines:"; tail -5 "$APP_LOG" | sed 's/^/   /'
    echo "-- host: $(free -m | awk 'NR==2{print $3" MB used, "$7" MB avail"}')"
  } >> "$INC"
  kill -9 "$APP" 2>/dev/null; pkill -9 -x watchtower 2>/dev/null
  log "$tag run #$run (alive ${alive}s) — recorded; relaunching per scenario"
  sleep 3
done
kill -9 "$SAMPLER" 2>/dev/null; pkill -9 -x watchtower 2>/dev/null
log "DONE — $run launch(es), crashes=$(grep -c 'CRASH/KILL' "$INC" 2>/dev/null), hangs=$(grep -c 'HANG/GUI-WEDGE' "$INC" 2>/dev/null), samples=$(wc -l < "$D/samples.csv" 2>/dev/null)"
echo "GUARD_SOAK_COMPLETE"
