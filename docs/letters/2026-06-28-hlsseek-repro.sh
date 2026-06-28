#!/usr/bin/env bash
# Faithful reproducer for the Watchtower playback seek stall, against the SAME demuxer Qt 6.8 uses:
# libavformat's "hls" (hls.c) — NOT GStreamer hlsdemux2. `ffmpeg -ss <T> -i <playlist>` does a
# demuxer-level INPUT seek, which is exactly the path that stalls in our player.
#
# Usage:   ./2026-06-28-hlsseek-repro.sh "<review-playlist .m3u8 URL>"  ["Cookie: access_token=..."]
#
# EXPECT today (one #EXT-X-DISCONTINUITY per fragment, every segment rebased to PTS=0):
#   seeks past the first fragment FAIL or HANG.
# EXPECT on a continuous-timeline build:
#   a frame decodes at every T — until a *genuine* boundary (real gap / epoch / codec / profile / pts-wrap),
#   which is the only place our re-open trick should still be needed.
set -u
PL="${1:?usage: $0 <playlist.m3u8 URL> [auth header]}"; HDR="${2:-}"
HOPT=(); [ -n "$HDR" ] && HOPT=(-headers "${HDR}"$'\r\n')
echo "seek test vs $PL"
for T in 5 30 60 120 300 600 1200; do
  out="/tmp/hlsseek_${T}.png"; err="/tmp/hlsseek_${T}.err"; rm -f "$out"
  timeout 25 ffmpeg -nostdin -loglevel warning "${HOPT[@]}" -ss "$T" -i "$PL" -frames:v 1 -an -y "$out" 2>"$err"
  if [ -s "$out" ]; then echo "  seek ${T}s  -> OK (frame decoded)"
  else echo "  seek ${T}s  -> STALL/FAIL: $(tail -n1 "$err" 2>/dev/null)"; fi
done
