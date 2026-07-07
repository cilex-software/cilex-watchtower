# Wired the `playback` key — thanks; two keys is the right model, no roll-up needed

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend / infra)
**Date:** 2026-07-07
**Re:** the `live_view` → `live_view` + `playback` split in the `/streams` `functions` block (your reply, migration 0052)

## TL;DR

Done on our side, same day. We now gate **playback/timeline/export on the new `playback` key** and keep **live tiles/snapshots on `live_view`** — so "live off, playback on" (and vice-versa) render correctly. **We don't need the `viewing` roll-up** — two independent keys are exactly the model we want. Backward-compatible for us too: `playback` is read fail-safe (missing key ⇒ enabled), so older backends without it keep working.

## What we changed (client)

- `CameraModel` now parses `functions.playback` into a `playbackEnabled` property, alongside the existing `recordingEnabled` / `liveViewEnabled`. Same fail-safe rule you specified: a function is **on unless explicitly `{enabled:false}`** — a missing `playback` key, missing `enabled`, or a garbled `functions` blob all read as enabled, so a backend hiccup can never dark the UI.
- Re-pointed the gates exactly as you asked:
  - **Live tiles + right-click picker thumbnails (`snapshot_url`)** → still `live_view`. ✅ unchanged.
  - **Playback timeline scrubbing + clip export** → now `playback`. When `playback.enabled == false`, the Playback screen shows a calm **"Playback is switched off — recorded playback and export are paused. This is an operator setting, not a fault."** overlay (mirrors the live "off" state), instead of a spinner or a fault, and it auto-recovers: when `playback` flips back on we re-create the review session on the next `functions` poll.
  - **Recording badges + timeline advancing** → still `recording`. ✅ unchanged.
- Verified: with `playback` enabled, historic playback opens normally (no regression); the gate defaults open on a backend that doesn't emit the key.

One scope note: the **synchronized multi-camera mosaic wall** (a later/less-used surface) isn't yet wired to the calm overlay — if `playback` is off it currently degrades via its existing session-failed/"pending" path rather than the dedicated message. We'll fold it into the same `playback` gate when we finish wiring that surface; flagging so it's not a surprise.

## Your question: the `viewing` roll-up

Not needed — please keep the two clean keys. Reading two booleans is trivial and we specifically want to distinguish the two states for the operator (e.g. "live off but you can still review recordings"). A merged `viewing` signal would actually lose the distinction we just wired.

## On the go2rtc re-registration note (your "bonus")

Good to hear the ~15 s re-register + drift-heal is in — it matches what we see. Our live players already run a reconnect/retry watchdog, so a go2rtc restart recovers within that window on its own; we haven't seen permanent give-ups from a restart. The one "player never recovers" case we hit recently turned out to be **camera-side** — a HiWatch illegal-login lockout on `.67` (correct creds rejected on all interfaces until a power-cycle), not a go2rtc reconnect issue — so no bounded-reconnect-on-visible needed on our side for now. We'll ping you if that changes.

— Watchtower
