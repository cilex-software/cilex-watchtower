# Heads-up: `live_view` split into `live_view` + `playback` in the `/streams` functions block

**From:** Cilex Vision (backend / infra)
**To:** Watchtower (operator client)
**Date:** 2026-07-07
**Re:** this thread — the `functions` object you consume in `GET /streams`

## TL;DR

An operator needed to turn **live view** and **historic playback** on/off independently (they were one function before). So the `functions` block you poll now carries a **new key `playback`**, and **`live_view` has narrowed to live streaming only**. Shape is unchanged, no key was removed → **backward-compatible**. **One change on your side** (when you get to it): gate playback/timeline/export on the new `playback` key instead of `live_view`. Details below.

## What changed

Previously `live_view` was "Live View & Playback" — a single toggle that stopped/started **both** go2rtc (live) **and** playback-service (recorded footage). Operators couldn't disable one without the other. As of today (migration 0052) they're two independent functions:

| `functions` key | Covers | Service | Meaning when `enabled: false` |
|---|---|---|---|
| `recording` | Motion/continuous capture | recorder-service | (unchanged) recording is off |
| `live_view` | **Live streaming only** | go2rtc | live tiles / snapshots dark |
| `playback` **(NEW)** | **Historic playback + export** | playback-service | timeline scrubbing, clips, mosaic export unavailable |

The object shape is exactly what you asked for and unchanged — every function is `{ "enabled": <bool> }` (plus an optional `"blocked_reason"` on a memory-gated function like `ai_analytics`). So the block now looks like:

```json
{
  "streams": [ … ],
  "functions": {
    "recording":    { "enabled": true },
    "live_view":    { "enabled": true },
    "playback":     { "enabled": true },
    "ai_analytics": { "enabled": false, "blocked_reason": "needs ~8 GB free (…)" }
  }
}
```

`playback` inherited `live_view`'s previous enabled state on migration, so nothing flipped on deploy — on your next poll you'll simply see the extra key.

## The one action for you

In your original letter you wrote:

> **`live_view.enabled == false`** → live tiles, the right-click picker thumbnails (snapshot_url), **and playback/mosaic export** show *"Live View is off."*

That last clause is now the stale bit. Please re-point it:

- **Live tiles + right-click picker thumbnails (`snapshot_url`)** → keep gating on **`live_view`** (its meaning is unchanged — it's the live/go2rtc path). ✅ no change.
- **Playback timeline scrubbing, clip/mosaic export** → gate on the **new `playback`** key. When `playback.enabled == false`, playback-service is stopped, so your HLS / review / export requests will get connection-refused / 5xx — show the same calm *"Playback is off"* state you already show for live, **not** a fault.
- **Recording badges + timeline advancing** → still `recording`. ✅ no change.

The net effect for operators: they can now, say, turn **live view off** (dark tiles) while **playback stays on** (they can still review recorded footage) — which your current code would mis-render as "playback also off." And vice-versa. Wiring the `playback` key fixes both directions.

## Backward-compatibility / urgency

- **Nothing breaks if you do nothing right now.** `live_view` still exists and still correctly gates live tiles; you'll just occasionally mis-gate playback/export by the old assumption (e.g. show "off" for playback when only live is off). Unknown-key-safe as always.
- No new endpoint, no auth change, same 15 s poll, non-admin read — all as before.

## Bonus (related, already shipped)

Re-enabling **Live View** from the admin console now brings live video back within **~15 s** (previously it could take 5+ minutes and needed a Watchtower restart). go2rtc holds stream registrations in memory only, so on any go2rtc restart (re-enable, OOM, watchdog cycle) we now re-register all cameras as soon as it answers, plus a 15 s drift-heal loop. So your players' normal reconnect/retry should recover on their own inside that window — if you find they give up permanently instead, tell us and we'll look at whether a bounded reconnect-on-visible helps.

Ping back if you'd like the object to also expose a coarser `viewing` roll-up (live_view AND/OR playback) — happy to add one if a single "any viewing off" signal is more convenient than reading two keys. Otherwise the two keys are the clean model.

— Cilex Vision (backend)
