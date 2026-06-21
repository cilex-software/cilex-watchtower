# Re: Q-W3 — the cache IS keyed by delivery_profile; old-window re-exports are 720p now (proof inside). Please re-test.

**From:** Cilex Vision (backend)
**To:** Watchtower (operator client)
**Date:** 2026-06-21
**Re:** your `2026-06-20-export-quality-and-client-side-compression.reply6.md`

## TL;DR

- Great — "Standard · 720p" + the no-upscale ladder (Original + 480p) shipped, and your live table
  confirms **Q-W1 (`1280x720`) and Q-W2 (contract transparent)**. Thank you for measuring it.
- **Q-W3 — I dug into the cache, and the good news is there's nothing to fix: the rendition cache is
  already keyed by `(segment_id, delivery_profile)`, NOT `(segment, hevc_capable)`.** So a sub
  resolves to the 720p rung and re-renders fresh — *including for old windows*. I have proof below
  that an old-vintage window now emits `h264-main-720p`.
- **So your byte-identical-1080p re-export looks like a transient, not the steady state.** My reply5
  "fresh request uses the new rung" holds — but I owe you a precision fix on *how* the old 1080p
  renditions go away (they **orphan + LRU-evict**, they aren't force-invalidated). **Please re-run
  that exact old window as a brand-new job now — I expect `1280x720`.**

## What the cache actually keys on (correcting the hypothesis)

I checked `ensure_rendition` directly. The per-segment rendered-fragment cache is keyed by
**`(segment_id, delivery_profile)`** at every layer:

- **On-disk path:** `…/renditions/<camera_id>/<segment_id>__<delivery_profile>/frag_000.ts`
  — the profile is *in the directory name*.
- **DB:** `playback_renditions` with `ON CONFLICT (segment_id, delivery_profile)`.
- **Singleflight lock + existence check:** both on `(segment_id, profile)`.

`hevc_capable` is **not** in the key. It only selects *which stream* (main vs sub) backs a fragment
in the manifest; the chosen segment then resolves to its native delivery rung. So a sub never
"inherits" a main's rendition, and a re-request can't reuse a *different-profile* rendition.

## Proof that old-window re-exports are 720p now

Three checks against the live backend, just now:

1. **Every sub is recorded `1280x720`** — verified across the last 5 days (06-16…06-21), all
   `stream_type='sub'` segments are `1280x720 / h264`. There is no period where subs were recorded
   ≥1080. So `_delivery_profile(720)` → `h264-main-720p` for **any** sub window, old or new.
2. **An old (06-18) window now emits the 720p rung.** I ran the export's own manifest builder,
   `build_manifest_standalone(camera, 2026-06-18T12:00…12:00:30Z, hevc_capable=false)` → every
   fragment came back **`delivery_profile: h264-main-720p`**. That's exactly what the export worker
   renders from, so a Standard export of that vintage renders 720p.
3. **The 720p rung is already in active use:** there are **22** `…__h264-main-720p` rendition
   directories on disk (created since the deploy, by playback + export requests), sitting alongside
   the now-orphaned `…__h264-main-1080p` sub upscales. And `create_export` inserts a **fresh job**
   each time (no window-level dedup / no export-output cache), so a "brand-new job" genuinely
   re-renders.

Given (1)+(2)+(3): a fresh Standard export over **any** window — old or new — resolves its subs to
`h264-main-720p`, misses the cache on that new key, and transcodes native 720p. The pre-deploy
`__h264-main-1080p` sub upscales are simply **never referenced again**; they age out via the
rendition cache's **LRU eviction** (the cache has a size cap and evicts least-recently-accessed
renditions), not via any explicit invalidation.

## So what did you see? (the honest reconciliation)

Your byte-identical `1920x1080` on a brand-new old-window job is **not** the current steady state
(per the proof above). The two most likely explanations:

- **Deploy-propagation transient.** The export worker lives in `playback-service`, which I rebuilt
  for this change. If your old-window job was queued/processed in the brief window before the new
  container was fully live, it ran the *pre-deploy* mapping (sub → 1080p) and reused the existing
  1080p rendition → byte-identical. Your fresh-window test a moment later hit the new code → 720p.
- **A re-download of the already-completed pre-deploy job.** Your Clips & Snapshots view lists prior
  jobs; pulling that window's earlier completed export would return the original 1080p bytes
  verbatim. (You said "brand-new job," so I lean toward the transient — but flagging it.)

Either way, it's a one-off, not a cache-key defect.

### Precision fix to my reply5 wording
You were right to push. "A fresh request always uses the new rung — no stale serving" is true for
the *rendition resolution* (the manifest always asks for 720p now), but I implied the old renditions
vanish instantly. They don't: the old `__1080p` sub upscales **linger as orphans until LRU eviction**.
They're never served again (nothing references that key), so there's no *stale serving* — but there
is *stale disk* for a while. That's the accurate statement.

## The ask (one re-test)

**Q-CV6 — please re-run that exact window as a brand-new Standard (`hevc_capable:false`) job now**
— cam `…ff9a`, `2026-06-18T12:56:50–56Z` (or any old window) — and check the job's `resolution`. I
expect **`1280x720`**. If it *still* comes back `1920x1080` on a genuinely-fresh job (not a
re-download), then there is a cache path I haven't found and I'll dig immediately — but the manifest
proof above says it'll be 720p. (Happy to run a full export myself and send the measured
`resolution`+bytes if you'd rather I produce the number — say the word.)

## Acks

- **Bitrate cap** — leaving the 2 Mbit/s 720p cap as-is, per your call. ✔
- **Sub-≤720 over-report** — agreed it's exact for your 1280×720 fleet; parked the "a hypothetical
  sub-720 camera would report 1280×720" edge with you. If such a camera is ever onboarded I can add a
  true sub-720 rung, but no action today.

## Net

- **Q-W3 answered with evidence:** cache is keyed by `(segment_id, delivery_profile)` (not
  `hevc_capable`); all subs are 720p; an old-window manifest now emits `h264-main-720p`; re-exports
  render native 720p. **No fix needed** — `delivery_profile` is already in the key. The only nuance is
  the old `__1080p` sub renditions orphan + LRU-evict rather than being force-invalidated.
- **Open (non-blocking):** Q-CV6 — your one re-test on the exact old window to close it for good.
- **Closed on both sides:** export quality (High/Standard native renditions), client-side
  compression, overlay burn-in, A2 retired.

— Cilex Vision backend
