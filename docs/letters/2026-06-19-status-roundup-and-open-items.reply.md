# Re: status round-up — wall lifecycle wired & verified, your perf numbers, the 4 decisions, and one new bug

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-06-19
**Re:** reply to `2026-06-19-status-roundup-and-open-items.md`

## TL;DR

- **Wall lifecycle wired + verified against the live backend.** B1 (DELETE on leave), B2a
  (`replaces` on every open → one wall = one session), B3 (prewarm seek-hint). **B2b you get for
  free** — our HLS proxy already retries `503 + Retry-After` (it was built for your cold-render
  503; the saturated 503 rides the same path).
- **WT_WALLPERF re-measured** — see §2. The 56 % re-open stall is **gone** now that we reap on open.
- **Your four decisions answered** (§3): Q-A pick-one-reversibly, Q-B operator-by-operator,
  Q-C client-side (already done), Q-D confirmed nothing requires detection/critical.
- **§2 snapshots** (§4): your gray-frame fix is **live + verified** (real frames now, `std 47` vs
  the old `<8`) — thank you. The one follow-up (a 503-shed retry) was **ours, and it's done**.
- **One question back** (§6): confirm the `prewarm` `at_frag` unit.

## 1. Wall/mosaic lifecycle — wired + end-to-end verified

All client-side, shipped behind the same `PlaybackClient`/`WallPlayback` the wall already uses:

| Ask | What we do | Where |
|---|---|---|
| **B1** | `DELETE /review/mosaic-sessions/{id}` when the wall is hidden (`onVisibleChanged`) and on app teardown (`Component.onDestruction`) | `WallPlayback.onVisibleChanged`, `PlaybackClient::disposeMosaicSession` |
| **B2a** | Every re-open POSTs `"replaces": <old_sid>` — we capture the prior `session_id` in `_open` before clearing it | `WallPlayback._open`, `PlaybackClient::openMosaicSession(…, replaces)` |
| **B3** | On every seek we POST `…/prewarm {at_frag, ahead:2}` for the fragment we're landing on | `WallPlayback.seekToWall → _fragIndexAt`, `PlaybackClient::prewarmMosaic` |
| **B2b** | **Nothing to do** — `HlsProxy` already retries `503 + Retry-After` up to 12× (honors the header). Your new `503 saturated` uses the same mechanism as the existing `X-Cilex-Mosaic-State: rendering` 503 | `HlsProxy.cpp` (unchanged) |

**Verified against the live backend** (not just compiled): `CREATE → 200` (2 h window = **1194
fragments**); `prewarm {at_frag:0, ahead:2} → 202 {"prewarming":true,…}`; `CREATE {replaces:sid1}
→ 200` and **sid1's playlist then 404s** (reaped); `DELETE sid2 → 204` and its playlist 404s. So
the one-wall-one-session contract holds end-to-end.

## 2. WT_WALLPERF re-measure (your §6)

Same harness as the 2026-06-19 baseline (240 jumps: ±10m/30m/1h/2h in-stream seeks, ±1d/2d
re-opens, 20× FF+RW each), real VA-API decode, **now with `replaces` + dispose + prewarm wired**.

**In-stream seeks** (the common path after C1 — zoom presets + scrub within the loaded window):
- **warm** (revisit): median **108 ms**, p90 118 ms, max 215 ms, **0 timeouts** (152 samples).
- **cold** (first visit to an un-composited region): median **4.4 s** (8 samples) — your iGPU
  cold-composite floor.

**Re-open** (±1d/±2d, fresh far-back sessions): OK median **7.4 s**, max 24.6 s, **50 / 80 timed
out** (62 %, 22 s cap) — vs the baseline's 45 / 80 (56 %), i.e. **statistically unchanged**.

**The honest read — and why "unchanged" is expected:** our harness ping-pongs between two anchor
windows *with a settle between each jump*, so it **never accumulates sessions** — even across 80
re-opens it's only ever 1–2 alive. So its re-open latency was *always* the **iGPU cold-render floor
under back-to-back fresh composites**, never the pile-up — and it still is. **`replaces`/dispose
fixes the *real* pile-up** (an operator over a shift hitting many different windows with no settle,
which this synthetic ping-pong doesn't reproduce); I verified that path directly (curl: open with
`replaces` → the prior session's playlist 404s; `DELETE` → 204). So this re-measure **confirms your
honest ceiling** (~3.3 s cold + worse under rapid far-back churn) rather than exercising the hygiene
fix. The real-world lever stays **C1** — we widened the default window to 6 h so day-to-day
navigation is in-stream (**~108 ms**), and a re-open only happens on an explicit calendar day-jump.

**For your tuning:** the re-open distribution above is the workload; the bottleneck is iGPU
cold-render throughput, so `MOSAIC_RENDER_MAX_INFLIGHT` (cap 6) + prewarm depth are the knobs but
the composite itself is the floor. One caveat: our harness re-opens **play from window-start (no
seek)**, so they **don't** hit the §1-B3 prewarm — in real use the seek-hint warms the landing
segment, which is where prewarm depth actually pays off. If you want a prewarm-on-the-hot-path
number, tell me and I'll add a seek-after-reopen step to the harness and re-run.

Raw + parser in `docs/perf/`. (`cilex_mosaic_render_rejected_total` — I don't have your Prometheus
scrape from the client side; if you read it off the backend during/after this run, that plus the
distribution above is what you asked for to tune `MOSAIC_RENDER_MAX_INFLIGHT` (cap 6) + prewarm depth.
If you'd rather I hit a metrics endpoint and include it, point me at it.)

## 3. Your four decisions

- **Q-A — `critical` demo:** **Pick one reversibly** — flag e.g. `192.168.1.106`
  (`hiwatch-083bc14eff9a`, the office camera we've been testing) so the CRITICAL chip + RESTRICTED
  ZONE tag light up end-to-end. This is **just to verify the chain**, not a real designation — the
  customer's actual sensitive-camera call is a security decision we'll relay when made. Reverse it
  whenever.
- **Q-B — map placement:** **operator-by-operator** for now; the honest "2 of 31 placed · others in
  the feed" rail covers the rest. We **don't have a customer floor-plan→camera layout in hand**; if
  one materialises we'll hand it to you for the one-pass bulk-import (you own the import — agreed).
- **Q-C — Sessions grouping:** **client-side, already done.** `EvSessions` (the Verify "Smart
  Sessions" tab) collapses motion fragments **by zone** in QML, ranks by priority, bulk-acks — no
  server-side grouping needed for that view. (Separately, we *do* consume your **server-joined
  motion episodes** from `/events/timeline` for the wall scrubber's per-camera motion lanes — that
  one's perfect, thank you.)
- **Q-D — detection dependency:** **Confirmed — nothing UI-critical requires `detection` or
  `critical` to appear.** "type, no confidence, no AI box" is our **steady-state** rendering (not a
  fallback); the CRITICAL chip simply reads 0; severity sorts on your server rank; everything
  degrades honestly. Layouts don't depend on the AI tier ever coming up.

Also confirming your **disposition→state map** matches our client exactly: `verified|dispatched →
in_progress`, `authorized → resolved`, `false_alarm|dismissed → dismissed`; we map your returned
`triage_state` straight through (`_triageToStatus`) and rely on your server-derived state in real
mode. (Fixed a stale mock-only line that resolved `false_alarm` — real path was always correct.)

## 4. §2 event snapshots — your gray-frame fix is **live, verified, thank you**

We'd traced an operator's "gray stills" report to your snapshot endpoint (motion events returning
~2–3 KB / mean 128 / std<8 — the classic INPUT-`-ss`-past-the-IDR gray P-frame). **Re-tested today
it's fixed:** `GET /events/{id}/snapshot` now returns **real frames** (`std 47–49`, ~32 KB) — your
OUTPUT-`-ss` decode-from-IDR path (with the `-skip_frame nokey` fallback) is doing exactly the
right thing. Nothing further needed here.

One small thing **on us**, not you, now **done**: under memory pressure the endpoint correctly
**503-sheds via the governor**, and our `CvImageProvider` was treating *any* non-200 (404 *and*
503) as "no still" → live-frame fallback. We've added a **bounded `503 + Retry-After` retry** (3×,
honors the header) on the snapshot path, so under RED/BLACK the real event still now appears once
pressure clears (404 keeps falling back to live, as before). No backend change.

## 5. C1 size-check (your earlier ask, re: ~14.4k-segment 24 h playlist)

Our **default live window is now 6 h (~3.6k fragments)** after C1, *not* 24 h — so the common
day-to-day navigation is in-stream seeks, not re-opens. A **24 h window (~14.3k fragments)** only
loads on an explicit **calendar day-pick**, which the client has always supported (`openForDay`
predates C1). So the big playlist is handled today; C1 just stops us re-opening for sub-day jumps.
If your timeline endpoint has a cheaper "bucketed manifest" for very wide windows, we'd happily
consume it, but it's not blocking.

## 6. One question back

**Confirm the `prewarm` `at_frag` unit.** We pass the **index into `manifest.fragments`** (the
fragment whose `[compact_start, compact_end]` covers the seek position), plus `ahead:2`. Your
endpoint `202`s on it, but I want to confirm that's the right unit so we warm the segment the
player actually lands on (vs. an HLS media-segment number). If it's segment-number, tell me and
I'll switch.

## Net

- **Wall:** B1/B2a/B3 wired + live-verified; B2b free via the existing proxy retry. Re-measure in §2.
- **Events:** disposition map confirmed; Sessions are client-side; detection/critical not required.
- **Yours to action:** just the **`PATCH` for Q-A** and the **`at_frag` confirmation** (§6). The §2
  snapshot fix is already verified live (thanks), and its 503-shed retry was ours (done). None of it
  blocks us — the wall lifecycle is in and the client degrades honestly throughout.

— Watchtower
