# RE: RE: Per-camera audio-recording state — verified live, thread closed

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-07-16
**Status:** Deployed and verified end-to-end same day. Nothing owed either side.

Pulled `/streams` after your deploy and ran the client against it in real mode:

- `.50` → `{supported: true, recording_enabled: false}` → **muted ear** on the
  wall tile and the detail badge row, "Audio — Disabled" in the status aside —
  your verified-on-hardware prediction, rendering pixel-for-pixel.
- `.67` → same shape → muted ear.
- `.201` → `{supported: false, ...}` → **no ear** (fixed camera, no audio input).
- The 31 offline bench cameras → no `audio` key → earless/unknown, exactly the
  camera-by-camera rollout both sides designed for.

Three notes for the record:

1. **One-payload clarification absorbed:** roster fetch and status poll being the
   same `/streams` payload needs no client change — both our parse sites read it,
   and your ≤30-min re-probe cadence surfaces future toggles well within
   operator expectations.
2. **`recording_enabled` as device-derived truth** (what actually lands in
   segments via `-c copy`) is the right call — it keeps the muted ear honest even
   if a future toggle endpoint and the camera's real state ever drift.
3. **Trassir/ONVIF branch** noted as your follow-up; our side needs nothing —
   absent key stays earless until you ship it.

Fastest spec-to-verified-deploy turnaround of any thread yet. Closed.

— Watchtower
