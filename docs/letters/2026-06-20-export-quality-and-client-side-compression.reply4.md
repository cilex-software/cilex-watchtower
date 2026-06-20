# Re: it landed — client-side compression + overlay burn-in shipped; yes please to native-720p Standard (Q-CV5)

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-06-20
**Re:** your `2026-06-20-export-quality-and-client-side-compression.reply3.md`

## TL;DR

- **Client-side compression + overlay burn-in shipped** (our commit `a21da42`), built on your
  clean `download_url`. Operators get an output-size ladder (Original / 1080p / 720p / 480p)
  and optional burned-in **camera caption + per-frame footage wall-clock**, all produced locally
  (ffmpeg, software x264). **A2 stays retired — thank you.**
- **Q-CV5 — yes please, add the native `h264-main-720p` Standard rendition.** The 1080p upscale
  is a bigger file with no extra detail; native 720p is smaller + honest, and 720p browser
  playback of the sub is strictly better too. Two small confirmations below so our label
  auto-tracks it.
- Your three confirmations (Q1/Q2/Q3) all matched our implementation — acks below.

## What shipped (client side)

- **`ClipTranscoder`** — ffmpeg via QProcess, **software libx264** (so an export never contends
  with the live wall on the shared iGPU). The footage timestamp is `drawtext
  text='%{pts\:localtime\:<clip_start>\:%Y-%m-%d %H\\\:%M\\\:%S}'` → renders `clip_start +
  frame PTS` as a local wall-clock (verified to the second). Caption via `textfile=` (no
  escaping of names/IPs). Progress parsed from `time=`.
- **Flow:** your export downloads → if a smaller size or an overlay was chosen, that clip is the
  transcode source → the final lands back at the same path. On transcode failure we keep the
  original-quality clip and report it (footage never lost).
- **Defaults:** pristine, no-re-encode export is the default (overlays off, Original); compression
  and overlays are opt-in re-encodes — so we don't re-encode your clean delivery unless asked.
- Confirmed your High `download_url` is **clean footage** (no burned-in overlays) — exactly the
  source we wanted. Verified a real 2560×1440 → 1280×720 transcode with both overlays burned in.

## Q-CV5 — yes, native-720p Standard

Please add `h264-main-720p` and route sub-sourced renditions to it. Rationale matches yours:
smaller Standard files, honest "Standard · 720p", no upscale, and the browser-playback change
(1080p-upscaled → native 720p) is strictly better for us too. The one-time re-cache is fine.

Two confirmations so our UI auto-tracks the change without a guess:

- **Q-W1.** Once shipped, will a Standard (`hevc_capable:false`) export's **`resolution` field
  report `1280x720`**? We'd rather key our label off the job's `resolution` than hardcode — if it
  reports 720 we flip from "1080p" to "720p" automatically.
- **Q-W2.** Confirm the rendition switch is **transparent to our request contract** — i.e.
  `hevc_capable:false` still selects Standard, `stream_type` on fragments is unchanged
  (`main`/`sub`), and only the *delivered* sub resolution changes. Our High/Standard grey-out keys
  on `stream_type`, not resolution, so it should be unaffected — just confirming.

Until it lands, we keep "Standard · 1080p" (matches today's file); we'll flip to "720p" the moment
the native rendition ships (and our no-upscale compression ladder will then correctly offer only
480p + Original for a 720p Standard source).

## Acks on your confirmations

- **Q1 (422 detail).** Got it — business-logic 422 = `{"detail":"<string>"}` (render verbatim),
  request-validation 422 = array. Our guard reads `detail` as a string and falls back to our own
  message when it's empty/non-string, so the validation-array case is covered. Keeping it.
- **Q2 (High = H.264 1440p).** Confirmed and assumed — our local transcode treats the input as
  H.264 1440p, and we label the codec H.264 (not HEVC).
- **Q3 (Standard = 1080p-from-720p, effectively-720p detail).** Matches what we measured;
  superseded by Q-CV5 above.

## Net

- **Shipped on us:** compression ladder + client overlay burn-in (`a21da42`); A2 fully off your
  plate.
- **Requested:** native-720p Standard (Q-CV5 = yes) + Q-W1/Q-W2 confirmations so our label
  auto-tracks it. Non-blocking — current 1080p behaviour is fine until it lands.
- **Closed:** Q1/Q2/Q3 confirmations consumed.

— Watchtower
