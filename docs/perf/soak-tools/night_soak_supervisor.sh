#!/bin/bash
# Overnight NIGHT-SOAK supervisor (Qt 6.12 / build, real Wayland). Drives WT_NIGHT_SOAK
# (historic-playback timing + export matrix + seek-land + Esc/cancel), samples RSS/CPU,
# and on any crash/hang records the cause + the actions leading up to it, then relaunches.
# A sidecar stat's + deletes exported clips (logging their sizes) so disk doesn't fill.
# Arg: end "HH:MM" (default 07:00) or END_EPOCH.
set -u
cd /home/cilex-vision/projects/cilex-watchtower
QT=${WT_QT:-$HOME/Qt/6.12.0/gcc_64}
BIN=${WT_BIN:-./build/watchtower}
export LD_LIBRARY_PATH="$QT/lib" QT_PLUGIN_PATH="$QT/plugins" QML_IMPORT_PATH="$QT/qml" QML2_IMPORT_PATH="$QT/qml"
export WAYLAND_DISPLAY=wayland-0 DISPLAY=:0 XDG_RUNTIME_DIR=/run/user/1000 MALLOC_ARENA_MAX=2
export WT_CV_AUTOLOGIN=1 WT_NIGHT_SOAK=1 WT_TRACE=1 WT_SMOOTHTEST=999999   # smoothtest never self-quits

D=${WT_SOAK_DIR:-/tmp/night_soak}; mkdir -p "$D"
INC="$D/incidents.log"; APP_LOG="$D/app.log"; SUP="$D/supervisor.log"; XSZ="$D/export_sizes.log"
EXPORT_DIR="${WT_EXPORT_DIR:-$HOME/Videos/Watchtower}"
END=${END_EPOCH:-$(date -d "today ${1:-07:00}" +%s)}
[ "$END" -le "$(date +%s)" ] && END=$(date -d "tomorrow ${1:-07:00}" +%s)
HANG=150         # seconds with no [NTIME]/[WT-MEM] heartbeat while the process is alive => GUI wedge
log(){ echo "[$(date '+%m-%d %H:%M:%S')] $*" | tee -a "$SUP"; }

log "NIGHT SOAK START — $BIN (Qt $($QT/bin/qmake6 -query QT_VERSION 2>/dev/null)), until $(date -d @$END '+%a %H:%M'), hang=${HANG}s"
{ echo "=== BASELINE $(date) ==="; free -m | head -2; } >> "$INC"

# RSS/CPU sampler (comm=='watchtower')
secs=$(( END - $(date +%s) )); [ "$secs" -lt 1 ] && secs=1
python3 docs/perf/soak-tools/guard_sampler.py "$D/samples.csv" "$secs" > "$D/sampler.log" 2>&1 &
SAMPLER=$!

# Export sidecar: every 20s, stat any new *.mp4, record size vs the [XRESULT] line, then delete
# it (we only need the size, not the bytes). Keeps a running size log for the report.
( while [ "$(date +%s)" -lt "$END" ]; do
    for f in "$EXPORT_DIR"/*.mp4; do
      [ -e "$f" ] || continue
      sz=$(stat -c%s "$f" 2>/dev/null); [ -z "$sz" ] && continue
      # only once the file is quiescent (not still being written): mtime > 3s ago
      age=$(( $(date +%s) - $(stat -c%Y "$f" 2>/dev/null || echo 0) ))
      [ "$age" -lt 3 ] && continue
      echo "$(date '+%H:%M:%S') size=${sz} bytes=$(numfmt --to=iec $sz 2>/dev/null) file=$(basename "$f")" >> "$XSZ"
      rm -f "$f"
    done
    sleep 20
  done ) &
XSIDE=$!

run=0
while [ "$(date +%s)" -lt "$END" ]; do
  run=$((run+1)); started=$(date +%s); reason=""
  log "launch #$run"
  echo "==== LAUNCH #$run $(date) ====" >> "$APP_LOG"
  "$BIN" >> "$APP_LOG" 2>&1 &
  APP=$!
  last_hb=$(grep -ac -e 'NTIME' -e 'WT-MEM' "$APP_LOG"); stall=0
  while [ "$(date +%s)" -lt "$END" ]; do
    sleep 15
    kill -0 "$APP" 2>/dev/null || { reason="crash"; break; }
    hb=$(grep -ac -e 'NTIME' -e 'WT-MEM' "$APP_LOG")
    if [ "$hb" -gt "$last_hb" ]; then last_hb=$hb; stall=0; else stall=$((stall+15)); fi
    if [ "$stall" -ge "$HANG" ]; then reason="hang"; break; fi
  done
  if [ -z "$reason" ]; then kill -9 "$APP" 2>/dev/null; log "end time reached — clean stop (run #$run)"; break; fi
  alive=$(( $(date +%s) - started ))
  tag=$([ "$reason" = hang ] && echo "HANG/GUI-WEDGE" || echo "CRASH/KILL")
  { echo ""; echo "########## $tag  run #$run  $(date)  (alive ${alive}s, stall ${stall}s) ##########"
    { [ "$reason" = hang ] && echo "-- cause: heartbeat stalled ${stall}s while process ALIVE => GUI wedge"; }
    tail -20 "$APP_LOG" | grep -aE 'WT-FATAL|signal|Terminated|Killed|CRITICAL|assert' | sed 's/^/   /'
    echo "-- last actions:"; grep -aE '\[NTIME\]|\[NSEEK\]|\[XSOAK\]|\[XRESULT\]' "$APP_LOG" | tail -10 | sed 's/^/   /'
    echo "-- last [WT-MEM]:"; grep -a 'WT-MEM' "$APP_LOG" | tail -1 | sed 's/^/   /'
    echo "-- last 6 app.log lines:"; tail -6 "$APP_LOG" | sed 's/^/   /'
    echo "-- host: $(free -m | awk 'NR==2{print $3" MB used, "$7" MB avail"}')"
  } >> "$INC"
  kill -9 "$APP" 2>/dev/null; pkill -9 -x watchtower 2>/dev/null
  log "$tag run #$run (alive ${alive}s) — recorded; relaunching"
  sleep 3
done
kill -9 "$SAMPLER" "$XSIDE" 2>/dev/null; pkill -9 -x watchtower 2>/dev/null
log "DONE — $run launch(es), crashes=$(grep -c 'CRASH/KILL' "$INC" 2>/dev/null), hangs=$(grep -c 'HANG/GUI-WEDGE' "$INC" 2>/dev/null), samples=$(wc -l < "$D/samples.csv" 2>/dev/null), exports_sized=$(wc -l < "$XSZ" 2>/dev/null)"
echo "NIGHT_SOAK_COMPLETE"
