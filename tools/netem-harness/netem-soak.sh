#!/usr/bin/env bash
# Impairment matrix runner: for each profile, apply -> verify -> S1 playback+strip
# -> S2 churn -> clear -> append a row to the matrix report. See README.md.
# netem-soak.sh [--baseline-only] [--profiles "a b"] [--out <md>] [--force]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
QT="${WT_QT:-$HOME/Qt/6.12.0-patched-beta1}"
DATE=$(date +%F)
OUT="$REPO/docs/perf/${DATE}-netem-matrix.md"
WORK="$HOME/watchtower-soak/netem-$DATE"
PROFILES="baseline lan-jitter wan50 wan200 loss1 loss5 burst-ge reorder corrupt bw4m bw1m mobile3g worst"
FORCE=0; BASELINE_ONLY=0
while [ $# -gt 0 ]; do case "$1" in
  --baseline-only) BASELINE_ONLY=1; PROFILES="baseline";;
  --profiles) PROFILES="$2"; shift;;
  --out) OUT="$2"; shift;;
  --force) FORCE=1;;
  *) echo "unknown arg $1"; exit 2;;
esac; shift; done

[ -x "$REPO/build/watchtower" ] || { echo "FATAL: build/watchtower missing"; exit 3; }
curl -so /dev/null --connect-timeout 4 "http://192.168.1.79:8000/" || { echo "FATAL: backend not reachable"; exit 3; }
# refuse to impair an operator's live session (baseline-only never impairs)
if [ $BASELINE_ONLY = 0 ]; then
  for p in $(pgrep -x watchtower); do
    if ! tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -q "netem-$DATE"; then
      [ $FORCE = 1 ] || { echo "FATAL: non-harness watchtower pid=$p is running — impairment would hit it. Close it or --force."; exit 3; }
    fi
  done
fi
mkdir -p "$WORK"
trap '"$HERE/impair.sh" off >/dev/null 2>&1' EXIT INT TERM

wtenv() { # $1 profile-dir
  echo "MALLOC_ARENA_MAX=2 LD_LIBRARY_PATH=$QT/lib QT_PLUGIN_PATH=$QT/plugins \
QML_IMPORT_PATH=$QT/qml QML2_IMPORT_PATH=$QT/qml \
WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-wayland-0} DISPLAY=${DISPLAY:-:0} XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/1000} \
XDG_CONFIG_HOME=$1/config XDG_DATA_HOME=$1/data WT_CV_AUTOLOGIN=1 WT_TRACE=1"
}
# Footage discovery — hardcoded days rot (2026-07-16: every day that served the
# 07-14 soak was already pruned). Builds S1_PLAN + churn pair from live coverage.
DISC=$(python3 "$HERE/discover-plan.py" "http://192.168.1.79:8000" \
       "${WT_CV_USER:-admin}" "${WT_CV_PASS:-admin}") || { echo "FATAL: $DISC"; exit 3; }
eval "$DISC"
echo "footage discovery: $DISC_NOTE"
echo "S1 plan: $S1_PLAN"
echo "S2 churn: $CHURN_IP $CHURN_DAY <-> $CHURN_ALT"

[ -f "$OUT" ] || cat > "$OUT" <<EOF
# netem impairment matrix — $DATE

Harness: \`tools/netem-harness\` (port-scoped lo shaping, per-direction values).
S1 = playback+strip 300s (fsoak mini-plan .201/07-10 + .106/06-14). S2 = churn 10 switches.
RTT column = measured TCP connect through the shaped path at apply time.

| profile | RTT ms | ttff p50 | strip p50/p95 (n) | >1s | http p50 | misl | giveup | S2 churn | crashes |
|---|---|---|---|---|---|---|---|---|---|
EOF

for PR in $PROFILES; do
  D="$WORK/$PR"; mkdir -p "$D/config" "$D/data"
  echo "=== profile $PR ==="
  if [ "$PR" = baseline ]; then "$HERE/impair.sh" off >/dev/null 2>&1; RTT="-"
  else
    "$HERE/impair.sh" apply "$PR" || { echo "| $PR | SKIPPED (not authorized — run setup-root.sh) | | | | | | | | |" >> "$OUT"; continue; }
    RTT=$("$HERE/impair.sh" verify | grep -oE '[0-9.]+ ms' | head -1 | tr -d ' ms')
    echo "   measured connect RTT: ${RTT}ms"
  fi
  # S1 playback+strip
  env $(wtenv "$D") WT_FSOAK=1 WT_FSOAK_PLAN="$S1_PLAN" \
    timeout -k 20 300 "$REPO/build/watchtower" > "$D/s1.log" 2>&1
  # S2 churn
  env $(wtenv "$D") WT_PLAYBACK_IP="$CHURN_IP" WT_PLAYBACK_DAY="$CHURN_DAY" \
    WT_CHURN_ALT="$CHURN_ALT" WT_CHURNTEST=10 WT_FRAME_MODE=1 \
    timeout -k 20 240 "$REPO/build/watchtower" > "$D/s2.log" 2>&1
  "$HERE/impair.sh" off >/dev/null 2>&1

  TTFF=$(grep -ao 'first_frame dt=[0-9]*' "$D/s1.log" | cut -d= -f2 | sort -n | awk '{a[NR]=$1} END{print NR?a[int((NR+1)*.5)]:"-"}')
  read SP50 SP95 SN <<< $(grep -ao 'strip_ms=[0-9]*' "$D/s1.log" | cut -d= -f2 | sort -n | \
    awk '{a[NR]=$1} END{if(NR)print a[int((NR+1)*.5)], a[int((NR+1)*.95)], NR; else print "-","-",0}')
  OVER=$(grep -ao 'strip_ms=[0-9]*' "$D/s1.log" | cut -d= -f2 | awk '$1>1000{n++} END{print n+0}')
  HTTP=$(grep -ao 'session_http ms=[0-9]*' "$D/s1.log" | cut -d= -f2 | sort -n | awk '{a[NR]=$1} END{print NR?a[int((NR+1)*.5)]:"-"}')
  MISL=$(grep -ac 'seek MISLANDED' "$D/s1.log")
  GUP=$(grep -ac 'GIVE-UP' "$D/s1.log")
  CHURN=$(grep -ac '\[CHURN\] SUMMARY.*PASS' "$D/s2.log")/1
  CR=$(( $(grep -acE 'received signal SIGSEGV|killed by signal 11' "$D/s1.log") + $(grep -acE 'received signal SIGSEGV|killed by signal 11' "$D/s2.log") ))
  echo "| $PR | $RTT | $TTFF | $SP50/$SP95 ($SN) | $OVER | $HTTP | $MISL | $GUP | $CHURN | $CR |" >> "$OUT"
  echo "   row: ttff=$TTFF strip=$SP50/$SP95 n=$SN over1s=$OVER http=$HTTP misl=$MISL churn=$CHURN crashes=$CR"
done
echo "" >> "$OUT"
echo "Raw logs: $WORK" >> "$OUT"
echo "MATRIX DONE -> $OUT"
