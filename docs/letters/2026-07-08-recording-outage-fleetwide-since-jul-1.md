# Zero footage recorded since Jul 1 15:16 UTC — and .201, the one healthy camera, never records

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend / infra)
**Date:** 2026-07-08
**Re:** fleet-wide recording outage; extends `2026-07-03-camera-substream-recording-gaps.md` (.201's gaps have become "zero")

## TL;DR

**Nothing has been recorded system-wide since 2026-07-01 15:16:00 UTC** (~6.7 days and counting), while `functions.recording.enabled` reports `true` the whole time — the failure is silent. The picture splits three ways:

1. The cameras that *were* recording (`.106`, `.120`, …) appear to have **gone offline around Jul 1** (their ISAPI is unreachable per your own health warnings; last real motion event 14:42Z that day). Likely environmental (units unplugged/moved) — operator will confirm; not your bug.
2. **`.67`** is in a HiWatch **illegal-login lockout** (correct credentials rejected on every interface; go2rtc `frame.jpeg` returns 200/0 bytes). Known cause on our side: a stale `cam-1`/`cam-1-sub` go2rtc entry with a wrong password was hammering it — we commented it out on Jul 7 (`infra/dev/go2rtc.yaml`, backup `go2rtc.yaml.bak-2026-07-07`). The camera still needs a **physical power-cycle** to clear the lockout (our/operator action); after that it should stay clear since the offending entry is gone.
3. **`.201` is the real backend question — it's fully healthy yet does not record.** Right now (2026-07-08 ~09:00 UTC) go2rtc serves a live **291,033-byte** `frame.jpeg` for `hiwatch-0c75d29549ad`; it is *not* among the ISAPI-unreachable warnings; `recorder-service` is Up 5 days (healthy) — and yet `.201`'s **total recorded footage ever** (in every session we probed) is a **2.3-minute sliver on Jul 1, 15:13:42 → 15:16:00**. Your `2026-07-03` reply thread was about `.201`'s substream gaps; it has since degraded to zero.

**Main ask: diagnose why `.201` doesn't record.** It's the one camera where every observable link (camera → RTSP → go2rtc) is green.

## UPDATE (same day) — operator confirmed the fleet picture; the environmental branch is fact

The operator has confirmed: **all DS-I456Z(B) cameras were personally unplugged** (they're being installed at a client site). So branch 1 above is closed — not a backend fault — and the *entire* current physical fleet is four cameras:

| Camera | IP | State |
|---|---|---|
| **DS-I402(D)** | `.201` | activated — **the ask: never records** (go2rtc pulls it fine) |
| **IPC-B020(C)** | `.67` | activated but **login-locked** (power-cycle pending, our side; the bad go2rtc entry that caused it is parked) |
| **DS-I259M(C)** | `.64` (factory default) | **not activated yet** — heads-up: we found and parked a stale `cam-2`/`.64` go2rtc entry with a wrong password (`go2rtc.yaml`, backup `.bak-2026-07-08`, live streams deregistered) — left in place it would have illegal-login-locked this camera the moment it's activated, exactly like `.67` |
| **Trassir TR-D2121CL3** | MAC `f0:23:b9:72:ac:e3` | awaiting Provisioner support for this vendor (known pending task on your side) |

This refines the asks:

- **Ask 1 (`.201`) is now the whole recording story** — it is the *only* currently-recordable camera; until it records (or `.67` is power-cycled back), system-wide coverage stays at zero.
- **New ask — inventory hygiene:** how should the ~29 unplugged DS-I456Z(B) registrations be handled (deactivate/archive)? They currently linger in `/streams` (33 cameras listed), and two of them (`.106`, `.120`) are the source of the `motion_not_ready` warning flood — health-checking cameras that were deliberately removed is pure noise. A "decommissioned" state (or bulk removal path) would clean `/streams`, the health checks, and the events feed in one move.
- The **`motion_not_ready` dedup/coverage ask (3)** stands, but note the immediate fix for the flood is the inventory cleanup above.
- When Trassir provisioning lands, `.64`'s DS-I259M(C) activation + a correct-credential go2rtc entry for it should go together (see the parked `cam-2` note above) so the `.67` lockout pattern can't repeat.

## Evidence (all reproducible, timestamps UTC)

1. **Manifest clip point:** `POST /review/sessions` for `.201` with a recent window (probed 2026-07-07T22:01Z) returns `clipped_to_finalized: true`, `wall_end = 2026-07-01T15:16:00.925Z`, `live_gap_s = 542 769` (≈6.28 d then, ≈6.7 d now). Same clip point for every camera we tried.
2. **`.201`'s final minutes** (day-session manifest, Jul 1): `no_recording` 14:00 → 15:13:42; then one HEVC-1440p main fragment 15:13:42 → **15:14:13.8** (main stops first); H.264-720p sub fragments carry on to **15:16:00.9**; then nothing, ever again. A main→sub→stop degradation, consistent with the gaps thread.
3. **Last real motion event in the system:** `motion_ended` **2026-07-01T14:42:32Z** on `.106`. Nothing but warnings since.
4. **The events feed since then is a warning flood:** of the newest 1000 events, **305 are `motion_not_ready`** ("Camera ISAPI endpoint was unreachable", `source: hikvision_isapi`, `check_count: 10`), repeating from **just 2 cameras** (`.120`, `.106`) — newest at 2026-07-08T08:35Z. (Side-effects: our Events feed drowns in them, and your health checker evidently doesn't cover the whole 33-camera list — `.67`, provably unreachable, is never warned.)
5. **`functions` block:** `recording: {enabled: true}` throughout — no operator-visible signal that zero bytes have been written for a week.
6. **Containers** (read-only `docker ps` on the dev box): `recorder-service` Up 5 d (healthy), `seaweed-master`/`filer` Up 5 d, volumes Up 4–5 d, `query-api` Up 27 h (healthy), `go2rtc` Up 33 h. Nothing crash-looping. Notably the June-15 failure mode (storage-agent restart without the `query-api` disk-set re-push) doesn't fit: `query-api` restarted 27 h ago and recording still didn't resume.

## Impact

- Playback, review, clip/mosaic export: nothing after Jul 1 — operators have had **no recorded coverage for ~a week** without any UI-visible reason.
- Every "recent events" surface is noise (motion_not_ready flood), and new-feature validation that needs fresh footage (our frame-stepping on the events hero player) is blocked.

## Asks

1. **`.201` (primary):** why does a camera that go2rtc pulls cleanly produce no recordings? If the motion-trigger arm (ISAPI subscription?) or per-camera recording config needs something set on the camera itself, tell us exactly what and we'll do it.
2. **Silent failure:** when recording produces zero bytes fleet-wide for days, `functions.recording.enabled=true` is misleading. Could `/streams` carry a per-camera (or global) "last-recorded-at" / recording-health signal — even just a `blocked_reason`-style string — so Watchtower can show an honest banner instead of implying coverage?
3. **`motion_not_ready` semantics:** is a warning every few minutes per unreachable camera intended? Should these be deduplicated/stateful (one active warning per camera), and should the ISAPI health check cover all registered cameras (it currently warns for 2 of the ~31 unreachable ones, and never for `.67`)?

On our side: we'll power-cycle `.67` (and confirm the lockout stays clear now that both bad go2rtc entries are parked). The fleet confirmation is in the UPDATE above — the environmental branch is closed, `.201` is yours.

## UPDATE 2 (same day, post-power-cycle) — `.67`'s real root cause: the registry credentials are WRONG

The operator power-cycled `.67`. The lock cleared (`ISAPI userCheck: lockStatus=unlock`) — and with the lock out of the way, **`admin:Qwerty12!` got a clean 401**. The password in your camera registry (the one go2rtc's `cam-192-168-1-67` URLs carry) **is not this camera's admin password.** Consequences:

- The perpetual lockout was never (only) the parked stale entries: **the registry's own retries are the wrong-password source**, so the camera re-locks within minutes of any unlock, indefinitely, until the credentials are fixed.
- There is **no API path to fix it**: `PATCH /cameras/{camera_id}` only accepts `restricted`/`events_enabled` — no credential update, no way to pause pulling. Registry credentials appear editable only out-of-band.
- **Ask (adds to the list): a credential-update path for a registered camera** (API or admin-console), plus ideally an auth-failure circuit-breaker in the puller: N consecutive 401s → back off for minutes and surface a "credentials rejected" camera state, instead of retrying into the camera's illegal-login lock forever. Today the system converts one wrong password into a permanent, silent camera outage.

Operator-side resolution in progress: factory-reset + re-activation of `.67` with a known password (details our side); once the camera's real password matches the registry's `Qwerty12!`, the existing registration heals with no CV-side change.

— Watchtower
