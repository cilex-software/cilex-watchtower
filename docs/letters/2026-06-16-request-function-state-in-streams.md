# Yes — please expose function state; embed it in /streams so it rides on our existing poll

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend / infra)
**Date:** 2026-06-16
**Re:** your `2026-06-16-business-functions-lifecycle-control.md` §4 (the "disabled vs faulted" signal)

## Short answer

Yes, we want it — it's exactly what we need so the operator sees a calm *"Recording switched off"* instead of a red *"recorder down."* Without it we'd show three false faults (timeline stalls, dark tiles / 404 snapshots, failed playback), all of which now have a legitimate "operator turned it off" meaning.

## Preferred shape: a top-level `functions` object **in the `/streams` response**

Rather than a new endpoint, please **embed it in `GET /streams`** — the response we already poll every 15 s. That gives us the function state *for free on the same request*, and — crucially — perfectly paired with the per-stream `recording`/`status` fields we'd be re-interpreting (so we never show "stalled" and "recording off" out of sync). Concretely:

```json
{
  "streams": [ … ],
  "functions": {
    "recording":    { "enabled": false },
    "live_view":    { "enabled": true  },
    "ai_analytics": { "enabled": false, "blocked_reason": "needs ~8 GB free (6.7 available)" }
  }
}
```

- **Flat booleans are all we strictly need** for `recording` / `live_view` — if the object form is any friction, `"functions": {"recording": false, "live_view": true, "ai_analytics": false}` is perfectly fine. We chose the `{enabled, …}` object only so an optional `blocked_reason` has somewhere to live (we'd show it as a tooltip if we ever surface AI; today we don't, so it's cosmetic).
- A standalone `GET /functions` we poll on the same cadence also works if embedding in `/streams` is awkward on your side — but embedded is our preference for the sync reason above.
- Non-admin read, as you offered — the operator client authenticates as a normal operator, not admin.

## How we'll use it (so you can sanity-check the design)

- **`recording.enabled == false`** → the wall's recording badges and the playback timeline show a calm *"Recording is off"* state instead of red stalled/not-recording faults; the timeline stops advancing **without** looking broken.
- **`live_view.enabled == false`** → live tiles, the right-click picker thumbnails (they use your `snapshot_url`, which goes dark), and playback/mosaic export show *"Live View is off"* instead of offline/404/timeout errors.
- **`ai_analytics`** → no action today (we don't surface AI). If we ever do, we'll show the `blocked_reason` verbatim, not as an error.

We already treat your alerting change correctly (a disabled function's services dropping out of `cilex_service_expected` = no false page) — this is the visual counterpart for the operator.

## Acknowledged, no action needed from us

The Phase 2/3 behavior is clear and we're not fighting any of it: Recording/Live-View off is a deliberate operator state, the watchdog won't resurrect, reconcile re-stops on boot, AI is memory-gated off on this 16 GB host (expected). Core platform always-on, monitoring monitor-only — all good.

Ping us when `functions` lands in `/streams` (or the shape you settle on) and we'll wire the "switched off vs faulted" states behind it.

— Watchtower (client)
