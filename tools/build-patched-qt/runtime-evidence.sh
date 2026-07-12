#!/usr/bin/env bash
# Prove which Qt artifacts a RUNNING watchtower actually loaded.
# Usage: runtime-evidence.sh [pid]   (defaults to the newest watchtower pid)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID="${1:-$(pgrep -nx watchtower)}"
echo "pid=$PID cmdline=$(tr '\0' ' ' < /proc/$PID/cmdline)"
echo
printf "%-72s %s\n" "loaded library" "BuildID"
for pat in libQt6Multimedia.so libffmpegmediaplugin.so libQt6Core.so libQt6Qml.so libavutil.so; do
    path=$(grep -m1 "$pat" /proc/$PID/maps | awk '{print $6}')
    [[ -z "$path" ]] && { printf "%-72s %s\n" "($pat NOT LOADED)" "-"; continue; }
    bid=$(readelf -n "$path" 2>/dev/null | awk '/Build ID/{print $3}')
    printf "%-72s %s\n" "$path" "$bid"
done
echo
if [[ -s "$HERE/BUILDIDS.txt" ]]; then
    echo "verdict vs tools/build-patched-qt/BUILDIDS.txt:"
    ok=1
    while read -r f want; do
        base=$(basename "$f")
        path=$(grep -m1 "${base%%.so*}.so" /proc/$PID/maps | awk '{print $6}' | head -1)
        [[ -z "$path" ]] && continue
        have=$(readelf -n "$path" 2>/dev/null | awk '/Build ID/{print $3}')
        if [[ "$have" == "$want" ]]; then echo "  MATCH  $base $have"
        else echo "  DIFFER $base loaded=$have patched=$want"; ok=0; fi
    done < "$HERE/BUILDIDS.txt"
    [[ $ok == 1 ]] && echo "  => RUNNING ON PATCHED ARTIFACTS" || echo "  => NOT (fully) on patched artifacts"
else
    echo "(BUILDIDS.txt not present yet — run build.sh first)"
fi
