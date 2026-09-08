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
while [ $# -gt 0 ]; do case "$1" in --cycles) CYCLES=$2; shift 2;; --out) OUT=$2; shift 2;; --pause) PAUSE=$2; shift 2;; *) shift;; esac; done
: "${WT_CV_USER:?export WT_CV_USER}"; : "${WT_CV_PASS:?export WT_CV_PASS}"
export WT_CV_URL=${WT_CV_URL:-http://127.0.0.1:8000} WT_CV_AUTOLOGIN=1 WT_TRACE=1
log(){ printf '{"ts":"%s","cycle":%d,"surface":"%s","dt_ms":%s,"note":"%s"}\n' "$(date -u +%FT%TZ)" "$1" "$2" "$3" "$4" >> "$OUT"; }
DAY=$(date -d yesterday +%F)
for ((c=1;c<=CYCLES;c++)); do
  # 1) single-camera playback: WT_TTFF_DAYS drives openForDay and prints [TTFF] day=… ttff=…ms
  L=$(mktemp); WT_PLAYBACK_IP=$CAM WT_PLAYBACK_DAY=$DAY WT_TTFF_DAYS="$DAY" timeout 70 ./run.sh >"$L" 2>&1 || true
  v=$(grep -oE '\[TTFF\] day=[^ ]+ ttff=-?[0-9]+' "$L" | tail -1 | grep -oE '[-0-9]+$' || echo -1); log $c playback "$v" "day=$DAY cam=$CAM"
  # 2) 16-cell wall: WT_WALL_DAY=live opens the mosaic; [WALLTIME] first_frame dt=…
  L=$(mktemp); WT_WALL_DAY=live timeout 70 ./run.sh >"$L" 2>&1 || true
  v=$(grep -oE '\[WALLTIME\] first_frame dt=[0-9]+' "$L" | head -1 | grep -oE '[0-9]+$' || echo -1)
  cells=$(grep -oE 'cells=[-0-9]+' "$L" | head -1 | cut -d= -f2 || echo "?"); log $c wall "$v" "cells=$cells"
  # 3) live open from the wall: WT_FOCUS_IP shows the detail view for one camera; [LIVETIME] playing dt=…
  L=$(mktemp); WT_FOCUS_IP=$CAM timeout 45 ./run.sh >"$L" 2>&1 || true
  v=$(grep -oE '\[LIVETIME\] playing dt=[0-9]+' "$L" | head -1 | grep -oE '[0-9]+$' || echo -1); log $c live "$v" "cam=$CAM"
  rm -f "$L"; sleep "$PAUSE"
done
echo "done -> $OUT"
