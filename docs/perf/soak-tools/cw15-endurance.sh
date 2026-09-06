#!/usr/bin/env bash
# CW-15: 24h endurance under Warden supervision (docs/plans/warden-build-plan.md).
#
# Proves the guard-station promise over a full day: Warden supervises a REAL,
# restore-eligible session; injected faults exercise the whole cycle; the spool
# stays bounded; every restart lands back on the seeded view.
#
# Injection schedule (max 4 new report_ids in any hour — server cap is 30/h):
#   every 2h ....... 1x kill -SEGV            (12 singles over the day)
#   hour ~6 ........ 5 kills, ~75s apart      (3 singles + 1 restart-loop;
#                                              quiet-close proves itself when the
#                                              NEXT 2h single mints fresh)
#   hour ~12 ....... SIGSTOP                  (hang -> warden outer net -> ABRT)
#
# GREEN criteria (evaluated in the final report):
#   G1 warden PID unchanged for 24h, zero warden crashes
#   G2 exactly one report per injected incident (loop folding per policy);
#      0 pending, 0 quarantine at end; no duplicates server-side
#   G3 every restart logs "[RESTORE] applied ... tabs=2 active=1 layout=9"
#   G4 no NON-injected deaths (if one occurs: flag to CV same hour — that is a
#      finding about the app, and Warden handling it correctly is the pass)
#   G5 no hang alarms outside the injected STOP; no 4xx/429 from the backend
#   G6 app RSS < 1500MB throughout; warden RSS flat (<80MB); flightrec <=5 files
#
# SAFETY: kills target ONLY the pid from warden's own "spawned" log line, and
# only after /proc/<pid>/environ confirms CW15_SOAK=1 — the operator's own
# Watchtower can never be hit.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BASE="${1:-$HOME/watchtower-soak/cw15-$(date +%F)}"
HOURS="${2:-24}"
mkdir -p "$BASE/config" "$BASE/data" "$BASE/warden"
LOG="$BASE/driver.log"; STATUS="$BASE/status.csv"; WLOG="$BASE/warden.log"
say() { echo "[cw15] $(date +%FT%T) $*" | tee -a "$LOG"; }

# single-runner lock (netem lesson: two controllers = garbage)
exec 9>"$BASE/.lock"; flock -n 9 || { echo "another cw15 runner holds the lock"; exit 5; }

# ---- 1. seed a view state worth restoring (2 camera tabs, active=1, 3x3) ----
say "seeding view state"
XDG_CONFIG_HOME="$BASE/config" XDG_DATA_HOME="$BASE/data" WT_CV_AUTOLOGIN=1 \
  WT_RESTORE_TEST=seed timeout -k 10 90 "$REPO/run.sh" > "$BASE/seed.log" 2>&1
grep -q "SEEDED" "$BASE/seed.log" || { say "FATAL: seed failed"; exit 3; }

# ---- 2. warden up (detached from this driver's fate) ----
# No default: the pilot token used to be baked in here and was the live station
# secret (audit 2026-09-03, High 07). Supply it from the environment.
: "${WT_WARDEN_STATION_TOKEN:?set WT_WARDEN_STATION_TOKEN — never a literal in this file}"
export WT_WARDEN_STATION_TOKEN
export WT_WARDEN_APP_CMD="$REPO/run.sh"
export WT_WARDEN_APP_ENV="WT_CV_AUTOLOGIN=1,CW15_SOAK=1,XDG_CONFIG_HOME=$BASE/config,XDG_DATA_HOME=$BASE/data"
export WT_WARDEN_DATA_DIR="$BASE/data/Cilex Vision/Watchtower"
export WT_WARDEN_WARDEN_DIR="$BASE/warden"
setsid nohup python3 "$REPO/warden/warden.py" run > "$WLOG" 2>&1 &
WPID=$!; echo "$WPID" > "$BASE/warden.pid"
say "warden pid=$WPID"

apppid() { grep -ao 'spawned watchtower pid=[0-9]*' "$WLOG" | tail -1 | grep -o '[0-9]*'; }
appok()  { local p; p=$(apppid); [ -n "$p" ] && [ -d "/proc/$p" ] \
           && tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -q '^CW15_SOAK=1$' \
           && echo "$p"; }
inject() { local p; p=$(appok) || return 1; [ -n "$p" ] || return 1
           say "INJECT $1 pid=$p"; kill "-$1" "$p"; }

START=$(date +%s); END=$((START + HOURS * 3600))
NEXT_KILL=$((START + 7200)); LOOP_AT=$((START + 6 * 3600)); HANG_AT=$((START + 12 * 3600))
LOOP_DONE=0; HANG_DONE=0
echo "ts,warden_alive,app_pid,app_rss_mb,warden_rss_mb,pending,sent,quar,flightrec_kb" > "$STATUS"

while [ "$(date +%s)" -lt "$END" ]; do
    sleep 300
    NOW=$(date +%s)
    AP=$(appok || echo "")
    ARSS=$([ -n "$AP" ] && awk '/VmRSS/{print int($2/1024)}' "/proc/$AP/status" 2>/dev/null || echo 0)
    WRSS=$(awk '/VmRSS/{print int($2/1024)}' "/proc/$WPID/status" 2>/dev/null || echo 0)
    WALIVE=$([ -d "/proc/$WPID" ] && echo 1 || echo 0)
    P=$(ls "$BASE/warden/pending" 2>/dev/null | wc -l); S=$(ls "$BASE/warden/sent" 2>/dev/null | wc -l)
    Q=$(ls "$BASE/warden/quarantine" 2>/dev/null | wc -l)
    FK=$(du -sk "$BASE/data/Cilex Vision/Watchtower/flightrec" 2>/dev/null | cut -f1)
    echo "$(date +%FT%T),$WALIVE,${AP:-0},$ARSS,$WRSS,$P,$S,$Q,${FK:-0}" >> "$STATUS"
    [ "$WALIVE" = 0 ] && { say "RED: warden died"; break; }

    if [ $LOOP_DONE = 0 ] && [ "$NOW" -ge "$LOOP_AT" ]; then
        say "== kill-loop burst (5x, ~75s apart) =="
        for i in 1 2 3 4 5; do
            for t in $(seq 1 90); do [ -n "$(appok || true)" ] && break; sleep 1; done
            inject SEGV; sleep 75
        done
        LOOP_DONE=1
    elif [ $HANG_DONE = 0 ] && [ "$NOW" -ge "$HANG_AT" ]; then
        say "== hang injection (SIGSTOP; warden outer net recovers) =="
        inject STOP
        HANG_DONE=1
    elif [ "$NOW" -ge "$NEXT_KILL" ]; then
        inject SEGV && NEXT_KILL=$((NEXT_KILL + 7200))
    fi
done

say "24h window over — stopping warden cleanly"
kill -TERM "$WPID" 2>/dev/null; sleep 20
pkill -9 -f "warden.py run" 2>/dev/null
P=$(apppid); [ -n "$P" ] && kill -9 "$P" 2>/dev/null
say "DONE pending=$(ls "$BASE/warden/pending" 2>/dev/null | wc -l) sent=$(ls "$BASE/warden/sent" 2>/dev/null | wc -l) quar=$(ls "$BASE/warden/quarantine" 2>/dev/null | wc -l)"
