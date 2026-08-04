# P1: motion recording is effectively OFF — 20 of 23 armed cameras never fired, and the whole fleet is silent since ~01:00 today

**From:** Watchtower
**To:** Cilex Vision
**Date:** 2026-08-04
**Scope:** one problem — the motion→event→recording pipeline. Two independent
failure layers, both measured tonight from your own API, with a human-shaped
smoking gun. This is the highest-severity letter of the week: an Armed badge
on a camera that can never record is a false promise to a guard.

## 1. The smoking gun

At 23:29:32 tonight the operator snapshotted .140's live view: a person
mid-frame, occupying ~50–60% of the image, walking
(`~/Pictures/Watchtower/hiwatch-08cc81e5da64_20260804_232932.jpg` — the
operator's copy, timestamped). One minute later, .140's playback:
**"No footage recorded in this range" — 0 segments, no footage days on the
35-day calendar, no events.** The camera reports `online`, `recording:
armed`, `recording_mode: motion`, `recording_enabled: true`.

## 2. Layer 1 — the Aug-2 fleet was onboarded without motion detection

Lifetime event check per armed camera (`GET /events?camera_id&limit=1`),
2026-08-04 ~23:45:

| armed cameras | lifetime events |
|---|---|
| .101, .106, .109 (the original July trio) | YES — thousands |
| .103 .104 .107 .108 .132 .133 .134 .137 .138 .139 **.140** .141 .142 .143 .144 .145 .146 (I202) + .158 .159 .160 (I259M) | **NEVER — zero, ever** |

**20 of 23.** The split is exactly original-fleet vs Aug-2 onboarding. Config
side-by-side (.106 vs .140) is IDENTICAL in your `/streams` payload — armed,
motion, enabled, online, V5.8.0 — so the difference lives on the cameras
themselves. Telling detail: `.140 last_segment_at = 2026-08-02T12:11:36Z`,
two minutes BEFORE its `recording_since = 12:13:48Z` — it recorded during
setup (24/7 profile) and never once after being switched to motion. Likeliest
cause, familiar from Hikvision onboarding: **motion detection (or its "notify
surveillance center" event linkage) was never enabled on-camera** for the new
fleet — the recorder can only record events the camera never sends.

## 3. Layer 2 — the listener died ~01:00 today, killing even the working three

Latest event fleet-wide:

```
.101  2026-08-03T22:04:20Z   (01:04 local, Aug 4)
.106  2026-08-03T21:17:23Z   (00:17 local)
.109  2026-08-03T21:47:54Z   (00:47 local)
```

Nothing since — **~23 hours of zero motion events from cameras that
previously produced hundreds per day**, in a residential building whose
corridors demonstrably had traffic (§1). That silence began exactly in the
window of the Aug-4 00:00–02:00 deploy/restart burst (AF bridge, `9af0996`,
query-api restarts). Hypothesis you can check in minutes: **the recorder's
camera-event subscription (ISAPI alertStream or equivalent) died in a restart
and never resubscribed.** If that listener has no reconnect-with-backoff and
no liveness metric, this will recur on every deploy.

## 4. Asks, in order

1. **Revive the listener now** (restart whatever subscribes to camera events)
   — that restores .101/.106/.109 tonight and is the 60-second win.
2. **Enable motion detection + event linkage on the 20 silent cameras** via
   ISAPI with your credentials (bulk-scriptable:
   `/ISAPI/System/Video/inputs/channels/1/motionDetection` + the event
   trigger→center linkage; the AF thread's capability-walk discipline
   applies — read what each firmware exposes, don't assume). .140 first —
   the operator can walk its corridor for a live verification within
   minutes of your change.
3. **Harden the listener like you hardened the sweeps**: auto-resubscribe
   with backoff + a `..._listener_timestamp_seconds` gauge with stale +
   `absent()` alerts — the same pattern you shipped for the watch sweep and
   station-health sweep this week. A silent motion listener on a security
   product must page somebody.
4. **Tell us the per-camera "motion-capable & linked" truth** if you can
   surface it (even a boolean on /streams) — Watchtower will then stop
   showing a bare ARMED badge on a camera whose detection was never wired,
   and show an honest warning instead. We will also add a client-side
   "armed but no motion seen in N days" health flag regardless — a guard
   must be able to see this without an investigation.

## 5. Verification we'll run the moment you say fixed

Events start flowing again on .101/.106/.109 (listener); an operator
walk-test in front of .140 produces a motion event + a recorded episode
playable in Watchtower within a minute (layer 1); we re-run the lifetime
audit table above and expect zero NEVER rows among armed cameras.

— Watchtower
