#!/bin/bash
# Extended Live-screen guard-usage soak supervisor. Runs watchtower under WT_GUARD_SOAK until 12:00, samples
# RSS/CPU throughout, and on any crash/kill records the death cause + the [GUARD] actions that led to it, then
# relaunches and continues (per the scenario). Self-contained: keeps running even if the launching session ends.
cd /home/cilex-vision/projects/cilex-watchtower
QT=/home/cilex-vision/Qt/6.8.3/gcc_64
export LD_LIBRARY_PATH=$QT/lib QT_PLUGIN_PATH=$QT/plugins QML_IMPORT_PATH=$QT/qml QML2_IMPORT_PATH=$QT/qml
export WAYLAND_DISPLAY=wayland-0 DISPLAY=:0 XDG_RUNTIME_DIR=/run/user/1000
export WT_CV_AUTOLOGIN=1 WT_SECTION=live WT_GUARD_SOAK=1

D=/tmp/guard_test; mkdir -p "$D"
INC="$D/incidents.log"; APP_LOG="$D/app.log"; SUP="$D/supervisor.log"
END=$(date -d 'today 12:00' +%s)
log(){ echo "[$(date '+%m-%d %H:%M:%S')] $*" | tee -a "$SUP"; }

log "GUARD SOAK START — runs until $(date -d @$END '+%a %H:%M')"
{ echo "=== BASELINE $(date) ==="; echo "host mem:"; free -m | head -2
  echo "go2rtc: $(docker stats --no-stream --format '{{.MemUsage}} restarts='"$(docker inspect go2rtc --format '{{.RestartCount}}' 2>/dev/null)" go2rtc 2>/dev/null)"
  echo "earlyoom: $(systemctl is-active earlyoom 2>/dev/null)"; } >> "$INC"

secs=$(( END - $(date +%s) )); [ "$secs" -lt 1 ] && secs=1
python3 /tmp/guard_sampler.py "$D/samples.csv" "$secs" > "$D/sampler.log" 2>&1 &
SAMPLER=$!

run=0
while [ "$(date +%s)" -lt "$END" ]; do
  run=$((run+1)); started=$(date +%s)
  log "launch #$run"
  echo "==== LAUNCH #$run $(date) ====" >> "$APP_LOG"
  ./build68/watchtower >> "$APP_LOG" 2>&1 &
  APP=$!
  while kill -0 "$APP" 2>/dev/null && [ "$(date +%s)" -lt "$END" ]; do sleep 5; done
  if kill -0 "$APP" 2>/dev/null; then
    kill -9 "$APP" 2>/dev/null
    log "end time reached — clean stop (run #$run was healthy)"
    break
  fi
  alive=$(( $(date +%s) - started ))
  { echo ""; echo "########## CRASH/KILL  run #$run  $(date)  (alive ${alive}s) ##########"
    echo "-- death cause (signal / OOM / shed):"
    tail -8 "$APP_LOG" | grep -aE 'WT-FATAL|signal|Terminated|Killed|MEMGUARD|G_IS_OBJECT' | sed 's/^/   /' || echo "   (no explicit fatal line)"
    echo "-- [GUARD] actions leading up to the death (most recent last):"
    grep -a '\[GUARD\]' "$APP_LOG" | tail -8 | sed 's/^/   /'
    echo "-- last [MEMTEL]:"; grep -a MEMTEL "$APP_LOG" | tail -1 | sed 's/^/   /'
    echo "-- last 4 app.log lines:"; tail -4 "$APP_LOG" | sed 's/^/   /'
    echo "-- host at death: $(free -m | awk 'NR==2{print $3" MB used, "$7" MB avail"}')"
  } >> "$INC"
  log "CRASH/KILL run #$run after ${alive}s — recorded to incidents.log; relaunching per scenario"
  sleep 3
done

kill -9 "$SAMPLER" 2>/dev/null; pkill -9 -x watchtower 2>/dev/null
crashes=$(grep -c 'CRASH/KILL' "$INC" 2>/dev/null || echo 0)
log "GUARD SOAK DONE — $run launch(es), $crashes crash(es). samples=$(wc -l < "$D/samples.csv" 2>/dev/null)"
echo "GUARD_SOAK_COMPLETE"
