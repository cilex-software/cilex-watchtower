#!/usr/bin/env bash
# Full validation matrix for the patched-Qt overlay (directive §6).
# Produces VALIDATION.md next to this script + raw logs under $OUT.
# Prereqs: build.sh completed (PREFIX exists); repro built for BOTH prefixes;
#          interposer compiled; a hw-decodable clip.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SDK="${QTPATCH_SDK:-$HOME/Qt/6.12.0/gcc_64}"
PREFIX="${QTPATCH_PREFIX:-$HOME/Qt/6.12.0-patched-beta1}"
OUT="${QTPATCH_VALOUT:-$HOME/qtpatch-work/validation}"
SCRATCH="${QTPATCH_SCRATCH:?set QTPATCH_SCRATCH to a dir containing clip.mp4 + xfer-interpose.so}"
CLIP="$SCRATCH/clip.mp4"
SEAM="$SCRATCH/xfer-interpose.so"
R="$HOME/watchtower-soak/fsoak-2026-07-10"
mkdir -p "$OUT"
PASSES=0; FAILS=0
row() { printf "| %-46s | %-9s | %s |\n" "$1" "$2" "$3" >> "$HERE/VALIDATION.md"; }
verdict() { if [ "$1" = PASS ]; then PASSES=$((PASSES+1)); else FAILS=$((FAILS+1)); fi; }

qtenv() { # $1=prefix
  echo "LD_LIBRARY_PATH=$1/lib QT_PLUGIN_PATH=$1/plugins QML_IMPORT_PATH=$1/qml QML2_IMPORT_PATH=$1/qml"
}
wtenv="MALLOC_ARENA_MAX=2 XDG_CONFIG_HOME=$R/a/config XDG_DATA_HOME=$R/a/data WT_CV_AUTOLOGIN=1 WT_PLAYBACK_IP=192.168.1.201 WT_PLAYBACK_DAY=2026-07-10 WT_FRAME_MODE=1"

cat > "$HERE/VALIDATION.md" <<EOF
# Patched-Qt overlay — validation matrix ($(date -u +%FT%TZ))

SDK prefix: \`$SDK\`  ·  patched prefix: \`$PREFIX\`
| test | verdict | evidence |
|---|---|---|
EOF

# ---------- 1. standalone repro: UNPATCHED expect crash ----------
env $(qtenv "$SDK") LD_PRELOAD="$SEAM" XFER_FAIL_AFTER=60 XFER_FAIL_COUNT=1 \
    timeout 60 "$OUT/repro-sdk/qvf-repro" "$CLIP" 300 > "$OUT/repro-unpatched.log" 2>&1
rc=$?
if [ $rc -ge 128 ]; then v=PASS; else v=FAIL; fi; verdict $v
row "standalone repro on UNPATCHED (expect crash)" $v "exit=$rc (signal) repro-unpatched.log"

# ---------- 2. standalone repro: PATCHED expect graceful + retry ----------
env $(qtenv "$PREFIX") LD_PRELOAD="$SEAM" XFER_FAIL_AFTER=60 XFER_FAIL_COUNT=1 \
    timeout 60 "$OUT/repro-patched/qvf-repro" "$CLIP" 300 > "$OUT/repro-patched.log" 2>&1
rc=$?
# Patched Qt re-attempts the transfer (often within the same toImage double-map),
# so toImage may never return null. PASS = clean exit, no crash, no fake-success.
ok=$([ $rc -eq 0 ] && grep -q "\-> CLEAN" "$OUT/repro-patched.log" \
     && ! grep -q "FAKE SUCCESS\|DEFECT-SIGNATURE" "$OUT/repro-patched.log" && echo yes)
v=$([ "$ok" = yes ] && echo PASS || echo FAIL); verdict $v
row "standalone repro on PATCHED (graceful + retry)" $v "exit=$rc repro-patched.log"

# ---------- 3. Watchtower on patched prefix: runtime evidence ----------
env $(qtenv "$PREFIX") $wtenv timeout 45 "$REPO/build/watchtower" > "$OUT/wt-evidence-run.log" 2>&1 &
wtpid=$!
sleep 20
"$HERE/runtime-evidence.sh" "$(pgrep -nx watchtower)" > "$OUT/runtime-evidence.txt" 2>&1
wait $wtpid 2>/dev/null
v=$(grep -q "RUNNING ON PATCHED ARTIFACTS" "$OUT/runtime-evidence.txt" && echo PASS || echo FAIL); verdict $v
row "runtime evidence: patched artifacts loaded" $v "runtime-evidence.txt"

[ -x "$REPO/build/watchtower" ] || { echo "FATAL: $REPO/build/watchtower missing — run this script IN PLACE from the repo"; exit 3; }
wt() { # name env-extra timeout
  env $(qtenv "$PREFIX") $wtenv $2 LD_PRELOAD="$SEAM" timeout $3 "$REPO/build/watchtower" > "$OUT/wt-$1.log" 2>&1
  grep -cE "received signal SIGSEGV|\[WT-FATAL\] killed by signal 11" "$OUT/wt-$1.log"
}
guardcount() { grep -cE "first map|poisoned buffer" "$OUT/wt-$1.log"; }

# ---------- 4-7. failure matrix on full app (patched Qt) ----------
c=$(wt single "XFER_FAIL_AFTER=300 XFER_FAIL_COUNT=1 WT_NO_POISON_LATCH=1" 60); g=$(guardcount single)
v=$([ "$c" = 0 ] && [ "$g" -ge 1 ] && echo PASS || echo FAIL); verdict $v
row "app+patched: single forced failure" $v "crashes=$c guard=$g"

c=$(wt burst60 "XFER_FAIL_AFTER=300 XFER_FAIL_COUNT=60 WT_NO_POISON_LATCH=1" 75); g=$(guardcount burst60)
v=$([ "$c" = 0 ] && [ "$g" -ge 1 ] && echo PASS || echo FAIL); verdict $v
row "app+patched: 60-failure burst" $v "crashes=$c guard=$g"

c=$(wt burst80 "XFER_FAIL_AFTER=250 XFER_FAIL_COUNT=80 WT_NO_POISON_LATCH=1" 75); g=$(guardcount burst80)
v=$([ "$c" = 0 ] && [ "$g" -ge 1 ] && echo PASS || echo FAIL); verdict $v
row "app+patched: 80-failure burst" $v "crashes=$c guard=$g"

c=$(wt torture "XFER_FAIL_AFTER=1 XFER_FAIL_COUNT=999999 WT_NO_POISON_LATCH=1" 70); g=$(guardcount torture)
v=$([ "$c" = 0 ] && [ "$g" -ge 1 ] && echo PASS || echo FAIL); verdict $v
row "app+patched: every-transfer-fails torture" $v "crashes=$c guard=$g"

# recovery: forced window ends; captures must resume (seam logs first REAL transfer)
# Reachable window: a normal-decode run makes FEW hwframe transfers (RHI render is
# zero-copy; transfers happen on capture), so fail transfers 3-4, then any later
# transfer proves recovery.
c=$(wt recovery "XFER_FAIL_AFTER=3 XFER_FAIL_COUNT=2 WT_NO_POISON_LATCH=1" 75)
rec=$(grep -c "first REAL transfer after forced window" "$OUT/wt-recovery.log")
v=$([ "$c" = 0 ] && [ "$rec" -ge 1 ] && echo PASS || echo FAIL); verdict $v
row "app+patched: failure→recovery" $v "crashes=$c realTransferAfterWindow=$rec"

# ---------- 8. decoder-recreation on persistent damage ----------
c=$(wt bounce "XFER_FAIL_AFTER=200 XFER_FAIL_COUNT=200 WT_NO_POISON_LATCH=1 WT_TRACE=1" 75)
b=$(grep -c "persistent decoder damage" "$OUT/wt-bounce.log")
v=$([ "$c" = 0 ] && [ "$b" -ge 1 ] && echo PASS || echo FAIL); verdict $v
row "app+patched: state-driven decoder recreation" $v "crashes=$c bounces=$b"

# ---------- 9-10. HW-textures off / SW decode ----------
c=$(wt notex "QT_DISABLE_HW_TEXTURES_CONVERSION=1 XFER_FAIL_AFTER=200 XFER_FAIL_COUNT=1 WT_NO_POISON_LATCH=1" 55)
v=$([ "$c" = 0 ] && echo PASS || echo FAIL); verdict $v
row "app+patched: HW textures disabled + failure" $v "crashes=$c"

c=$(wt swdec "QT_FFMPEG_DECODING_HW_DEVICE_TYPES=, XFER_FAIL_AFTER=50 XFER_FAIL_COUNT=5" 50)
x=$(grep -c "\[XFER\] call" "$OUT/wt-swdec.log")
v=$([ "$c" = 0 ] && [ "$x" = 0 ] && echo PASS || echo FAIL); verdict $v
row "app+patched: software decode (class absent)" $v "crashes=$c transfers=$x"

# ---------- 11. churn gauntlet on patched prefix ----------
env $(qtenv "$PREFIX") MALLOC_ARENA_MAX=2 XDG_CONFIG_HOME="$R/a/config" XDG_DATA_HOME="$R/a/data" \
    WT_CV_AUTOLOGIN=1 WT_PLAYBACK_IP=192.168.1.201 WT_PLAYBACK_DAY=2026-07-10 \
    WT_CHURN_ALT=2026-07-08 WT_CHURNTEST=20 WT_FRAME_MODE=1 WT_TRACE=1 \
    LD_PRELOAD="$SEAM" XFER_FAIL_AFTER=300 XFER_FAIL_COUNT=60 WT_NO_POISON_LATCH=1 \
    timeout 260 "$REPO/build/watchtower" > "$OUT/wt-churn.log" 2>&1
p=$(grep -c "SUMMARY.*PASS" "$OUT/wt-churn.log"); c=$(grep -cE "received signal SIGSEGV|killed by signal 11" "$OUT/wt-churn.log")
v=$([ "$p" = 1 ] && [ "$c" = 0 ] && echo PASS || echo FAIL); verdict $v
row "app+patched: churn gauntlet + 60-fail storm" $v "churnPASS=$p crashes=$c"

# ---------- 12. healthy-stream perf parity (strip gate) ----------
env $(qtenv "$PREFIX") MALLOC_ARENA_MAX=2 XDG_CONFIG_HOME="$R/a/config" XDG_DATA_HOME="$R/a/data" \
    WT_CV_AUTOLOGIN=1 WT_FSOAK=1 \
    WT_FSOAK_PLAN='[{"ip":"192.168.1.201","days":["2026-07-10","2026-07-09"]},{"ip":"192.168.1.67","days":["2026-07-10"]}]' \
    timeout 420 "$REPO/build/watchtower" > "$OUT/wt-perf.log" 2>&1
p50=$(grep -oE "strip_ms=[0-9]+" "$OUT/wt-perf.log" | cut -d= -f2 | sort -n | awk '{a[NR]=$1} END{print (NR?a[int(NR*.5)]:-1)}')
n=$(grep -c "strip_ms=" "$OUT/wt-perf.log")
v=$([ -n "$p50" ] && [ "$p50" -ge 0 ] && [ "$p50" -le 1000 ] && echo PASS || echo FAIL); verdict $v
row "app+patched: healthy-stream strip p50 (baseline ~715ms)" $v "p50=${p50}ms n=$n"

echo "" >> "$HERE/VALIDATION.md"
echo "**Totals: $PASSES PASS / $FAILS FAIL**" >> "$HERE/VALIDATION.md"
echo "Raw logs: $OUT" >> "$HERE/VALIDATION.md"
echo "validation done: $PASSES PASS / $FAILS FAIL"
