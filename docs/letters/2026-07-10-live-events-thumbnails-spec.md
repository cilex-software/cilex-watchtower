# Spec + prompt: mid-event still thumbnails for the Live Events feed

**From:** Cilex Vision (backend / web console)
**To:** Watchtower (operator client)
**Date:** 2026-07-10
**Re:** replicate the Cilex Vision "Live events" thumbnail look in Watchtower's Live Events section — self-contained; the backend contract is already live

## Prompt / intent (read first)

**What Cilex Vision did:** we reworked the Home **"Live events"** feed so each row shows a **real still from the MIDDLE of the motion incident** (past the pre-roll, where nothing has moved yet — not the first frame, and never a black tile), the thumbnails are **bigger and legible**, and the camera **IP is shown first and un-clipped**. We also collapsed each motion incident to **one row** (with a real still) instead of three, and made the still-loading robust so a feed of thumbnails never comes up black.

**What the user wants:** make Watchtower's **Live Events** section look **similar** — adopt the **substance and behaviour** (real mid-event thumbnails that load reliably, the IP-first camera line, one row per incident) — **WITHOUT changing Watchtower's existing UI style.** Keep your own theme, colours, spacing, fonts, corner radii and layout language. **The pixel sizes and CSS in this document are Cilex Vision's and are illustrative, not prescriptive** — match the *idea*, render it in *your* style. Nothing here should restyle your feed; the only real changes are (1) the thumbnail becomes a real mid-event still that loads without ever going black, (2) the camera line leads with the un-clipped IP, and (3) the feed shows one row per incident.

The rest of this document is the technical contract: the shared backend endpoint, the load-pacing behaviour you must implement so thumbnails don't shed to black, and which event types to show.

## TL;DR

Cilex Vision's Home "Live events" feed now shows a **real still from the middle of each motion incident** as the row thumbnail (not the pre-roll first frame, not a black tile), bigger and legible, with the camera **IP shown un-clipped**. The user wants the same look in Watchtower's **Live Events** section. Everything you need is on the shared query-api — no new backend work. This letter describes exactly what we did, then gives a ready-to-paste prompt.

## The backend contract you can use right now

`GET /events/{event_id}/snapshot?pos=mid`

- Returns a **JPEG** (`image/jpeg`), scaled to 640px wide, extracted from recorded video at the **middle of the incident** (`start_time + duration/2`, capped at 60 s) — i.e. past the pre-roll where nothing has moved yet.
- `pos` is optional: `pos=start` (default) = the exact event-moment frame (unchanged, what you get today); `pos=mid` = the middle-of-incident frame we added for thumbnails. Cache key is pos-aware.
- **Cached** server-side by `event_id` (+pos); response is `Cache-Control: private, max-age=3600`. An event's moment is immutable, so it's a one-time extract then instant.
- Auth: the usual `access_token` cookie (same as every query-api call). Same RBAC/scope as `/events`.
- **404** when no recorded video covers the moment (retention expired, cold-tiered, recorder was down) → fall back to a glyph/live frame, never a black tile.

### ⚠️ The one thing you must get right: it sheds under a burst

The snapshot handler shells out to ffmpeg and is gated by a **memory-pressure governor** — it admits only **~2 concurrent extractions** and **sheds the rest with `503` + `Retry-After`** (we measured: 8 concurrent → 2×200, 6×503). This is deliberate: a thumbnail wall must not OOM the box.

So a naive "set `<img src>` on every visible row" **will leave black/blank tiles** on first load. The fix (what we did) is to **pace the client to the server**:

- a **process-wide load queue capped at ~2 concurrent** (matches the server's admission → nothing sheds; we measured 2 concurrent → 0×503),
- **patient retry on 503** with backoff (respect `Retry-After`),
- **load only thumbnails scrolled near view**, and **load once** (immutable — never auto-refresh the still),
- a **light placeholder** (shimmer while loading, muted camera glyph on 404/failure) — **never a black square**.

## What we did, exactly (so you can mirror the behaviour)

1. **Feed content = one row per motion INCIDENT.** We show `motion_detected` (the deduped operator-incident event, which is the one that carries the clip) and **exclude** `motion_started` / `motion_ended` (clipless lifecycle bookends of the same incident) and `motion_not_ready` (readiness diagnostic — see the separate 2026-07-10 note). We do it with a new additive `exclude_types` CSV param on `GET /events` (`exclude_types=motion_not_ready,motion_started,motion_ended`), so the top-N feed is real incidents, each of which has a still. Use `hasClip = clip_url != null` to decide whether to even attempt a still.

2. **Thumbnail = mid-event still.** `GET /events/{id}/snapshot?pos=mid`, rendered 16:9, ~116 px wide, `object-fit: cover`, rounded, 1 px border. Big enough to actually read the scene.

3. **Never a black tile.** Placeholder is a light neutral tile; a subtle shimmer while the queued fetch is in flight; a muted **camera glyph** on genuine no-video. The dark "video-glass" placeholder is gone.

4. **Camera line: IP first, un-clipped.** The provisioner bakes the IP into the camera name (`HiWatch DS-I456Z(B) (192.168.1.130)`), and in a narrow row the long name truncated *before* the IP — leaving a useless `192...`. We now render the **IP first** (monospace, `flex: none` so it never clips) and the **model name** after it (truncates with ellipsis), stripping the redundant `(ip)` from the name. We also moved the **relative time onto the title row** (right-aligned) so the camera line gets the full width. Net row: `● Motion            1 hr ago` / `192.168.1.201  HiWatch DS-I40…`.

## Ready-to-paste prompt for the Watchtower session

> Cilex Vision reworked its Home **"Live events"** feed — each row now shows a real still from the **middle** of the motion incident (past the pre-roll, never a black tile), bigger and legible, with the camera IP shown first and un-clipped, one row per incident. I want Watchtower's **Live Events** section to look **similar in substance** — adopt the real mid-event thumbnails, the IP-first camera line, and one-row-per-incident — **without changing Watchtower's existing UI style** (keep your own theme, colours, spacing, fonts and layout; treat any sizes/CSS below as illustrative, not prescriptive). Read the full spec first: `/home/cilex-vision/projects/cilex-watchtower/docs/letters/2026-07-10-live-events-thumbnails-spec.md`.
>
> Concretely — replace the Live Events row thumbnails with **real stills from the middle of each motion incident**, using the shared query-api (no backend changes needed):
>
> **Thumbnail source:** `GET /events/{event_id}/snapshot?pos=mid` → a 16:9 JPEG from the middle of the incident (past the pre-roll). It's auth'd by the normal session cookie and cached server-side (immutable per event). Render it ~2× your current size, `cover`-cropped, rounded, 1 px border.
>
> **Critical — the endpoint is memory-governed and sheds a burst with HTTP 503 (`Retry-After`), admitting only ~2 extractions at once.** Do NOT fire a request per visible row. Instead: (a) load stills through a **client-side queue capped at 2 concurrent**; (b) **retry 503 patiently** with backoff, honoring `Retry-After`; (c) load a thumbnail **only when its row is near the viewport**, and **only once** (the still never changes, so don't refresh it on the 15 s poll); (d) show a **light placeholder with a camera glyph** (and a shimmer while loading) — **never a black/blank tile** — and use the same glyph on a 404 (no recorded video).
>
> **Feed content:** show one row per motion **incident** — request `/events` with `exclude_types=motion_not_ready,motion_started,motion_ended` so you get the deduped `motion_detected` events (each carries a clip → each has a still), not the three clipless lifecycle rows per incident. Only attempt a still when `clip_url` is present.
>
> **Row layout:** put the relative time on the **title row** (right-aligned, next to the event label), and on the camera line show the **IP first** (monospace, never truncated) followed by the model name (truncating with ellipsis) — strip the redundant `(<ip>)` the provisioner bakes into the camera name, so the IP isn't printed twice and is always fully legible.
>
> Keep it a single, non-scrolling-past-the-card feed with your existing severity/triage affordances; the only changes are the thumbnail (real mid-event still, paced + never-black) and the IP-first camera line.

## Notes / gotchas

- `pos=start` is unchanged — if you use `/events/{id}/snapshot` anywhere else for the *event-moment* frame, that behaviour is preserved; only `pos=mid` is new.
- `duration_ms` on the event tells you the incident length if you want your own offset logic, but `pos=mid` already does the seek server-side (and caps it), so you don't need to compute anything.
- If you'd like a server-side batch/prewarm endpoint (extract N stills in one governed call) to make the first paint snappier, say the word — happy to add it. For now the client-side queue is enough and keeps the box safe.

— Cilex Vision
