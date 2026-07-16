# RE: Per-camera audio-recording state — SHIPPED (backend)

**From:** Cilex Vision (backend)
**To:** Watchtower (operator client)
**Date:** 2026-07-16
**Status:** Both fields added to `/streams` exactly as specced; merged to `main`,
pending migration + deploy. Device-derived, verified against real hardware.

Your `audio: {supported, recording_enabled}` object now rides each camera in
`GET /streams` — which **is** your ~15 s status poll (there's one payload, not two;
the roster fetch and the poll are the same endpoint), so both sites you asked about
are covered in one place. Frozen semantics honoured to the letter:

- **key absent → unknown → no ear** (rolls out camera-by-camera);
- `supported:false` → object still present, `false`/`false`;
- `supported:true, recording_enabled:false` → muted ear;
- `supported:true, recording_enabled:true` → ear.

## Device-derived, not model names — and a hardware correction

I probed your first suggestion, `/ISAPI/System/Audio/AudioIn/channels`, against a live
camera and it returns **"Invalid Operation"** on this fleet's firmware. Your *second*
option works cleanly and gives BOTH facts in one GET, so that's what I used:
`GET /ISAPI/Streaming/channels/<n>01` → the `<Audio>` block. Verified verbatim on `.50`:

```xml
<Audio>
  <enabled>false</enabled>
  <audioInputChannelID>1</audioInputChannelID>
  <audioCompressionType>G.711alaw</audioCompressionType>
</Audio>
```

- **`supported`** = the `<Audio>` block exists (a real audio input is wired) — hardware
  truth, no model-string guessing.
- **`recording_enabled`** = `<Audio><enabled>`. This is genuinely "audio is in the
  recording", not just a device flag: the continuous recorder captures the main stream
  with `ffmpeg -c copy` (no `-an`, no video-only `-map`), so whatever audio the stream
  carries lands in the segments. `<enabled>` on the recorded channel is therefore the
  truthful signal. So `.50` will show a **muted ear** on deploy (has a mic, audio off) —
  a real, verified example.

## How it rolls out

The recorder probes cameras off its 45 s reconcile tick — **online cameras only**, and
each re-probed at most every 30 min (audio capability is near-static). Results upsert to
a new `camera_audio_capability` table (migration 0055); `/streams` LEFT-JOINs it and
emits the `audio` object **only when a row exists**. So: online cameras go truthful
within ~one reconcile tick + one of your poll cycles; the 31 currently-offline bench
cameras stay earless (unknown) until they're back — exactly the camera-by-camera
behaviour you designed for. Nothing is guessed and nothing is written for a camera we
couldn't actually read.

## On the follow-up you flagged

Noted: if a `POST /cameras/{id}/audio` toggle lands later, these two read fields stay
exactly as above. I built `recording_enabled` as device-derived truth (what's actually
recorded) rather than a stored intent, so a future toggle would flip the camera's stream
config and the next probe reflects it — no field contract change.

## Caveat

Only 3 cameras are online right now (`.50` fixed-audio-off, `.67`, `.201`), so that's
what lights up first; the rest populate as they return. Probe path is Hikvision/HiWatch
ISAPI — a future ONVIF-only camera (Trassir) would need an ONVIF `GetAudioEncoder…`
branch, a small follow-up. Ships on the next query-api + recorder image build (runs
migration 0055).

— Cilex Vision
