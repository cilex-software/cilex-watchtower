# Re: continuous-timeline validated in the Qt pipeline — GO, boundary fields wired, leak gated on caching

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-06-28
**Re:** your reply4 (route B live) — Qt harness results + go/no-go + boundary wiring

## TL;DR — **GO**

Validated both halves in the Qt FFmpeg pipeline (libavformat `hls.c`). **Continuous makes direct seeks land**,
confirming your `ffmpeg -ss` result end-to-end. **Please flip `continuous` to the default** — though our
client already requests it explicitly (committed `8dadde2`), so we're not blocked on the flip. The §4-ii
boundary fields are **wired and working**. The 48 h cap is **confirmed live**. One honest caveat: the
**un-cached** serve-time remux makes continuous seeks slow right now, so our freeze-watchdog still re-opens
~18 % — the scrubbing-leak relief lands when you cache the offset (your pending step).

## 1. Harness results (`WT_HERO_TEST`, on-screen, aged real sessions)

**A — Direct seeks, re-open DISABLED — the core "does the Qt pipeline seek land?"**

| jump | legacy (direct) | continuous (direct) |
|---|---|---|
| ±1 s  | froze | **land** (median 27 ms) |
| ±10 s | froze | land |
| ±30 s | froze | land |
| ±1 m  | froze | land |
| ±5 m  | froze | land |
| **ALL** | **0 % land — 100 % froze** | **81 % land** (87/108, median 27–574 ms) |

On legacy a direct seek **never** lands (every fragment is a discontinuity the demuxer can't cross); on
continuous **81 % land directly**. Your `hls.c` result holds in the Qt player.

**B — Production logic (continuous default + boundary-only re-open + freeze-watchdog):**

| metric | result |
|---|---|
| froze % | **0 %** |
| seek **re-open rate** | ~100 % (our prior seek-fix) → **18 %** |
| seek latency (un-cached) | median up to ~1.8 s, p90 ~2.3 s |

0 % froze — the watchdog re-opens the slow/flaky tail. The re-open rate drops from ~100 % to 18 %.

## 2. Go/no-go: **GO** — flip `continuous` to default

Recommend it. Our client requests `seek_mode:"continuous"` explicitly now and falls back gracefully
(`WT_SEEK_MODE=legacy` still works), so the flip is robust either way.

## 3. Boundary fields — wired + confirmed (§4-ii, §4-i)

We probed the manifests directly (login → `POST /review/sessions` both modes):
- **The marking is semantic and mode-independent.** A 10-min contiguous clip = **1** `discontinuity:true`
  (`boundary:"start"`); a 4 h motion window = **56** (1 `start` + 55 `gap`) — **identical** in legacy and
  continuous. So the client can trust the manifest field regardless of mode.
- **§4-i holds:** `compact_start`/`compact_end`/`wall_start` are byte-identical between modes — our mapping
  is untouched. (Confirmed `media_epoch` is correctly **not** a boundary.)

Wiring (`EvHeroPlayer`): on a continuous session `seekToWall` seeks **directly** and only re-opens when the
jump steps over a `discontinuity:true` fragment (`_crossesBoundary`). For a single contiguous episode that's
just the leading `start` (never mid-clip), so the hero re-opens **only** on the watchdog tail — exactly your
"re-open should never fire inside a continuous recording."

## 4. The one caveat: the scrubbing-leak relief is gated on your offset-caching

Un-cached, the serve-time remux makes continuous seeks slow (median up to ~1.8 s, p90 ~2.3 s), so the
freeze-watchdog (2.8 s) still re-opens **~18 %** of seeks → the per-scrub re-open (and its ~8 MB/open Qt
decode cost) isn't gone yet. **Once you cache the offset variant** (you flagged this before flipping the
default), seeks go fast → the watchdog rarely fires → seek re-opens → **~0**, and the scrubbing-driven growth
vanishes as you predicted. We'll **re-test and tighten the watchdog** once caching is in. (The separate
per-event open leak is the Qt-internal one from our earlier letter — unaffected by this; it's the *scrub*
re-opens that continuous removes.)

## 5. Ask 2 — 48 h cap confirmed live

`POST /review/sessions`: 24 h / 36 h / **48 h → 200**; 49 h / 72 h → **400 "Window exceeds 48h maximum"**.
No client change needed (we never capped client-side). Multi-day (= retention) remains the later follow-up.

## 6. The Playback wall (`WT_SEEK_TEST`)

The hero exercises the same Qt MediaPlayer + `hls.c` demuxer as the wall, so this validation generalizes. The
wall already requests continuous (same `PlaybackClient`); wiring its `seekFar` to boundary-only is the same
mechanical change, which we'll land + run `WT_SEEK_TEST` on next.

## What we need from you
1. **Cache the offset variant** — then we re-test the leak + tighten the watchdog; we expect the seek
   re-open rate → ~0 and the scrubbing leak gone.
2. **Flip `continuous` to default** when ready (we already opt in explicitly).

Validation logs committed under `docs/perf/2026-06-28-continuous-validation.*`.

— Watchtower client team
