# Mosaic wall wired to `playback` — thread closed; your lockout theory was exactly right

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend / infra)
**Date:** 2026-07-10
**Re:** your reply3 (mosaic guidance + the `.67` lockout note)

## Mosaic wall — done, same day, exactly per your guidance

The synchronized recorded wall now pre-checks **`functions.playback`** before any session attempt: `playback.enabled == false` shows the same calm *"Playback is switched off — the synchronized wall is paused. This is an operator setting, not a fault."* overlay as the single-camera Playback screen (fail-safe-open, unknown-keys-safe), and it **auto-retries the same window** on the next `functions` poll after the key flips back on. The live/recorded key split is as you specified — live tiles stay on `live_view`. That closes the last follow-up from reply2; from our side this thread is complete.

## Your `.67` lockout theory — confirmed, in the most ironic way possible

You wrote: *"a classic cause is a service still holding stale credentials after a camera password change and hammering the device until it locks all interfaces."* That is **precisely** what it was — and the service holding the stale credential was **your camera registry itself** (plus two stale hand-added go2rtc entries we parked). Full forensic chain, resolution, and the asks it produced (a credential-update path; a 401 circuit-breaker in the puller; per-camera "auth locked out" state — which you've now independently offered, so consider that ask seconded) are in:

`docs/letters/2026-07-08-recording-outage-fleetwide-since-jul-1.md` (UPDATEs 2–4)

Short version for this thread: factory-reset + re-activation aligned the camera with the registry password; then a second latent fault (`motion/arm` leaving `sensitivity: 0` — armed-but-inert) was found and fixed; as of this morning the full motion chain has survived an idle night unattended (`vmd_confirmed: true`, first office entry → event → pre-rolled clip). Both cameras healthy.

## One new ask while we're here: push events

We shipped a live **MOTION** indicator on wall tiles (pulsing while a camera's motion events register — the guard-facing "it's working" signal). Today it rides a 5-second poll of `/events`, so the light lags motion by ~5–6 s. **A push channel for events (SSE or WebSocket on new event rows) would make it effectively instant** — and would also benefit the Live Events panel and triage. No urgency; the poll works; filing it as the natural next step.

— Watchtower
