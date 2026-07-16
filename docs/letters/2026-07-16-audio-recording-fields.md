# Per-camera audio-recording state — two fields on /streams (client already shipped)

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-07-16
**One problem:** operators can't tell whether a camera records audio. We've
shipped the UI (ear = recording audio, struck-through ear = supported but
disabled, nothing = can't/unknown) on the live wall tiles and the camera
detail view — it renders from two per-camera fields we ask you to add.
Checked today: no audio fields or endpoints exist anywhere in your OpenAPI
(165 paths) or the /streams payload.

## Requested shape

On each camera object in **`GET /streams`** and in the **status-poll
payload** (both — the client parses both, and a toggle should surface within
one ~15 s poll):

```json
"audio": {
  "supported": true,          // camera HAS a usable audio input (hardware truth)
  "recording_enabled": true   // audio track is included in recordings
}
```

Semantics we rely on (frozen once you ship):

- **Key absent** → unknown: the client keeps prior state and shows NO ear —
  honest absence, so you can roll this out camera-by-camera.
- `supported: false` → no ear ever, regardless of `recording_enabled`.
- `supported: true, recording_enabled: false` → struck-through (muted) ear.
- `supported: true, recording_enabled: true` → ear.

Please derive `supported` from the DEVICE (e.g. Hikvision/HiWatch ISAPI
`/ISAPI/System/Audio/AudioIn/channels` or the `<Audio><enabled>` block under
`/ISAPI/Streaming/channels/<n>`; ONVIF `GetAudioEncoderConfigurations`), not
from model-name heuristics — we deliberately kept model-string guessing out
of this feature (naming hints like the "M" in DS-I259M are suggestive but
not contractual).

## Explicitly out of scope (but design for it)

Toggling audio recording from Watchtower is a likely follow-up ask — if you
add `POST /cameras/{id}/audio` later, these two read fields stay exactly as
above. Nothing else changes client-side.

## Client status

Shipped and live: model fields parse forward-compatibly at both payload
sites (roster fetch + status poll, per-row change signals), wall tile ear +
detail-view ear with tooltips + an "Audio" row in the status aside, RU
localization, honest no-ear default today. The moment the fields appear,
the ears go truthful with zero client changes.

— Watchtower
