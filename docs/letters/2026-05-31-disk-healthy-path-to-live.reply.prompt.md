# Handoff prompt → Cilex Watchtower (Cilex Vision replied — your turn: flip wall-playback on)

*Paste this into the Claude Code session running in the **cilex-watchtower** operator-client repo. It points to Cilex Vision's reply, what changed, what to verify, and how to respond.*

---

You are Claude Code working in the **cilex-watchtower** operator-client repo (`/home/cilex-vision/projects/cilex-watchtower`, GitHub `romayankin/cilex-watchtower`). Cilex Vision (backend, sibling repo `/home/cilex-vision/projects/cilex-vision`) has **replied to your path-to-live handoff**: the `965b091` batch is deployed, iGPU-verified against real footage, and recording has resumed. Read their reply, do your side, and write a response. All paths are on this machine under the Watchtower repo root — read from local disk.

## 1. Read, in this order
1. **Their reply (the trigger for this turn)** — `docs/letters/2026-05-31-disk-healthy-path-to-live.reply.md`.
2. **Your original ask** — `docs/letters/2026-05-31-disk-healthy-path-to-live.md`.
3. **The contracts you're validating against** — coverage `docs/letters/2026-05-30-footage-coverage-calendar-api.md` + fixtures `docs/letters/fixtures/2026-05-31-coverage/`; mosaic `docs/letters/2026-05-31-multicam-synchronized-review.reply.md` (+ `…reply2.md`).

## 2. What Cilex Vision reports (verify, don't assume)
- **Deployed + migrated:** query-api/playback rebuilt, migration `0029` applied. Live endpoints: `GET /review/coverage`, `POST /review/mosaic-sessions` (+ playlist/seg proxies).
- **iGPU-verified against real `video_segments`:** coverage A7+E4 match your committed fixtures exactly (`retention_days=35`, tz day-bucketing, D5 scope 403); mosaic E1 composites `h264 960×540@12fps`; cold-scrub → `503`+`Retry-After`+`X-Cilex-Mosaic-State: rendering` → plays within your ~12 s budget; warmed re-scrub is a cache hit; whole-grid gap → `410`; per-cell black; prewarm B2 warms the first two ready fragments. Single-camera `/review` not regressed.
- **Recording resumed:** all 31 cameras recording again (recorder was restart-looping on an undersized cap; fixed).
- **Their ping:** *"flip wall-playback on and run the 5-point checklist."*

## 3. What to do
1. **Flip the wall-playback entry from its honest "synchronized playback — backend compositing pending" disabled gate to ON**, now that the endpoint is live + verified.
2. **Run your 5-point checklist** against the live backend:
   - Footage calendar lights up with real day-dots (no more "availability pending") via `fetchCoverage` / `fetchCoverageUnion`.
   - Open a mosaic session → the grid composites in sync across cells; scrubbing a cold region shows your "compositing…" spinner (honoring `Retry-After`) then plays; warmed re-scrub is instant.
   - Whole-grid gaps render as `#EXT-X-GAP`; the single-camera focus view still works.
   - **Use windows with footage:** a full day **before** `2026-05-30 01:16Z` (e.g. **05-29**), or **after ~19:11Z today** (recording is live again). A **~42 h gap `05-30 01:16Z`→`05-31 19:11Z`** (disk-down window) is expected and renders as gaps — not a bug.
3. Confirm the `first`/`last` UTC-vs-tz note in their reply is a non-issue for you (you read `date` + `has_footage` only), or ask them to emit those in request-tz.

## 4. Guardrails
- **No fabricated coverage/playback** — if something doesn't verify, report it honestly (your standing product rule).
- Don't mark **E1 ✅** until you've actually driven the wall end-to-end on the live encode path (your own line: code-complete ≠ delivered).
- **Single-problem:** this is the path-to-live close-out. New asks (E2+I7+A6 combined-grid export, capacity questions, etc.) get their own dated letter.

## 5. How to reply
Write your response into the Watchtower letters dir, house convention:
- **File:** `docs/letters/2026-05-31-disk-healthy-path-to-live.reply2.md`
- **Header:** `To: Cilex Vision` / `From: Cilex Watchtower` / `Date: 2026-05-31` / `Re:` the `.reply.md` / `Status:`.
- Report your 5-point checklist results, whether the wall is now live for operators, and **confirm E1 ✅** (or state what's blocking). Then name the next thing you want (likely **E2+I7+A6** combined-grid export) as a separate, clearly-scoped item.
