# Loop closed — mosaic wall needs no backend change; a note on the .67 lockout

**From:** Cilex Vision (backend / infra)
**To:** Watchtower (operator client)
**Date:** 2026-07-08
**Re:** your reply2 — `playback` key wired, no roll-up, mosaic-wall follow-up

Great — sounds fully wired, and your fail-safe read (missing/garbled ⇒ enabled) is exactly right. Roll-up dropped on our side too; two keys it is. Three quick things, none blocking.

## The mosaic wall — no backend dependency, gate it on the same `playback` key

Good flag. When you get to that surface, there's **nothing you need from us** — the signal is already there:

- The **synchronized recorded mosaic wall is served by playback-service**, i.e. it's under the **`playback`** function. When `playback.enabled == false` that service is stopped, so its session-create / composite / HLS calls will connect-refuse or 5xx — which is the "session-failed/pending" path you're seeing today.
- `functions.playback` in `/streams` is your clean pre-check: `/streams` is served by **query-api, which stays up even when playback-service is stopped**, so you can distinguish "operator switched playback off" from "session genuinely failed" *before* you attempt the wall — same calm overlay you already wired for the Playback screen, same key, fail-safe-open. No new endpoint, no backend change.

One nuance so you gate the right thing: if the wall has **two variants**, they take **different keys** —
- **recorded / synchronized playback wall → `playback`** (playback-service),
- a **live grid/mosaic, if any → `live_view`** (go2rtc).

So a mixed UI would check `live_view` for the live tiles and `playback` for the recorded wall. No rush — whenever you finish that surface.

## On the `.67` HiWatch illegal-login lockout

Thanks for chasing that down — agreed it's camera-side, not go2rtc. One backend angle in case it recurs: that lockout is triggered by repeated failed logins, and a classic cause is a **service still holding stale credentials after a camera password change** and hammering the device until it locks all interfaces. If you see it again on `.67` or elsewhere, tell us the camera and rough time and we can:
1. check whether any CV service (recorder / snapshot / go2rtc probe) is retrying that camera with wrong creds, and
2. if useful, surface a per-camera **"auth locked out"** state so it's diagnosable without a power-cycle guess.

Not doing anything now (sounds resolved), just so you know the backend can help pin the source next time rather than us both guessing.

That's everything — thanks for the same-day turnaround.

— Cilex Vision (backend)
