#!/usr/bin/env bash
# Per-camera frame-rate sweep, measured SERVER-SIDE. No client involved.
#
#   ./fps-sweep.sh [seconds-per-camera] < stream-names.txt
#   printf 'hiwatch-x-sub\nhiwatch-y-sub\n' | ./fps-sweep.sh 10
#
# Why this exists: the operator needs every camera averaging under 10 fps
# reported to Health. A client-side measurement only covers tiles a station is
# actively decoding — with a 131-camera fleet and a 32-slot decode budget, most
# cameras are never measured by any wall. This box runs go2rtc, so it can
# measure any stream whether a guard is watching it or not.
#
# Deliberately uses RTSP on :8554, NOT the go2rtc API on :1984 — that port
# exposes camera credentials in every producer URL and CV is closing it
# (2026-08-15 credential-exposure letters).
#
# Cost: one transient consumer per camera for `secs`, serialised. A sweep is
# therefore ~ (fleet x secs) and adds exactly one consumer at a time to the
# server, which is why it is sequential and not parallel.
#
# Emits TSV: stream <TAB> fps <TAB> frames <TAB> seconds <TAB> verdict
# fps is "NA" when the stream could not be opened — never 0, because "no
# measurement" and "no frames" are different faults.
set -u
SECS="${1:-10}"
HOST="${HOST:-192.168.1.79}"
FLOOR="${FLOOR:-10}"          # operator spec: under 10 fps average is a fault
EXPECTED="${EXPECTED:-15}"    # the rate the cameras are configured for

printf 'stream\tfps\tframes\tsecs\tverdict\n'
while read -r s; do
  [ -z "$s" ] && continue
  out=$(timeout $((SECS + 15)) ffmpeg -nostdin -hide_banner -rtsp_transport tcp \
        -i "rtsp://$HOST:8554/$s" -t "$SECS" -f null - 2>&1)
  fr=$(printf '%s' "$out" | grep -oE 'frame=\s*[0-9]+' | tail -1 | grep -oE '[0-9]+')
  tm=$(printf '%s' "$out" | grep -oE 'time=[0-9]{2}:[0-9]{2}:[0-9.]+' | tail -1 | cut -d= -f2)
  if [ -z "${fr:-}" ] || [ -z "${tm:-}" ]; then
    printf '%s\tNA\tNA\tNA\tunreachable\n' "$s"; continue
  fi
  sec=$(awk -F: '{print $1*3600+$2*60+$3}' <<<"$tm")
  fps=$(awk -v f="$fr" -v s="$sec" 'BEGIN{printf (s>0)? "%.2f" : "NA", f/s}')
  v=$(awk -v f="$fps" -v fl="$FLOOR" -v e="$EXPECTED" \
        'BEGIN{ if (f+0 < fl) print "DEGRADED"; else if (f+0 < e*0.9) print "below-expected"; else print "ok" }')
  printf '%s\t%s\t%s\t%s\t%s\n' "$s" "$fps" "$fr" "$sec" "$v"
done
