# Prompt — Investigate & reduce the Triage-hero per-open memory leak (~6 MB per playback open)

## Problem
Opening a recording in the Triage hero (`qml/EvHeroPlayer.qml`) leaks memory. Measured with `WT_HERO_TEST`
(commit `6357b80`, graph `docs/perf/2026-06-28-triage-hero-latency-graph.png`): over **168 event-opens in
~12 min, RSS climbed 263 → 1354 MB** (+10.3 MB/min after the initial view-load ramp, **no plateau**) —
roughly **~6 MB leaked per open**. Every RSS spike in the run (+42 … +245 MB) and most CPU spikes (to
120 %) coincide with an event-open. In normal triage (clicking play on event after event) this accumulates
over a shift.

## What's already known
- **A2 (`b61474d`)** found Qt's FFmpeg MediaPlayer leaks ~2 MB of decode context per **source-change**, not
  freed on source-clear — a Qt-internal leak it could not fully fix client-side. A2 made playback
  on-demand (poster + play-tap) so *browsing* leaks nothing, but **each actual play-open still pays the
  per-source leak**. This test shows the real per-open cost is ~6 MB (more than the bare ~2 MB — the
  session + buffered fragments + stuck/frozen players add to it).
- **heaptrack is UNUSABLE** on this VA-API/GStreamer/Qt stack (freezes on-screen, SIGSEGVs offscreen) — do
  NOT re-attempt. Localize by **structural bisection + the external `/proc` sampler** (the A2 method).
- `PlaybackClient` **never sends `DELETE /review/sessions/<id>`** — review sessions accumulate server-side
  and the client may hold per-session state.
- `HlsProxy`'s segment cache is LRU-bounded (`kCacheBudget ≈ 160 MB`) — probably NOT the leak, but verify
  it is **global**, not per-session-unbounded.

## Task
Localize and reduce the per-open leak. Reuse/extend `WT_HERO_TEST`, or add a focused **open-only** variant
(select events + open, NO seeks, measure RSS slope). Bisect:
1. **Open without play** — open the session (HlsProxy + manifest fetch) but never set `player.source`.
   Isolates the session/proxy/HTTP path from the decode path.
2. **Open + play, then tear down properly** — on re-open, before opening the next: `player.stop()`;
   `player.source = ""`; AND `DELETE /review/sessions/<oldSid>` (new method); compare the slope.
3. **Reuse one session** — for the same camera, reuse the existing session/source instead of re-opening.

Likely fixes to land (whichever the bisection implicates):
- Add `PlaybackClient::closeSession(sid)` → `DELETE /review/sessions/<sid>`, and call it from EvHeroPlayer
  on re-open and `Component.onDestruction` (server sessions are never reaped today).
- Audit the hero's player teardown on re-open — does `player.stop()` + `source=""` free the FFmpeg decode
  context, or does Qt retain it? If source-clear doesn't free it, try destroying + recreating the
  `MediaPlayer` via a `Loader`. (Note: A2's recreate-*hero* experiment leaked MORE, but that was about the
  hero **object** lifecycle interleaved with tab-switches, not the **session/source** path — re-test for
  this path specifically.)
- Audit `HlsProxy` per-session buffers — confirm the 160 MB LRU cache is global, not per-session.

## Files
- `qml/EvHeroPlayer.qml` — `_open`, `_reset`, `onSessionReady`, `Component.onDestruction`.
- `src/models/PlaybackClient.cpp/.h` — `openSession` + the session lifecycle (add close/DELETE); `m_proxy`
  (HlsProxy), `m_nam` (shared QNAM).
- `src/models/HlsProxy.cpp/.h` — the segment cache.

## Verify
`WT_HERO_TEST` (or the open-only variant) + the `/proc` sampler; analyse the RSS slope with
`docs/perf/2026-06-28-triage-hero-latency-analyzer.py`. **PASS** = the +10.3 MB/min open-loop slope flattens
toward ~0 (bounded RSS across hundreds of opens). **Regression-guard:** re-run the events-browsing stress
(Test 3, `WT_EVENTS_TEST`) and confirm it stays flat — don't undo A2.

## Note
This pairs with `2026-06-28-hero-frozen-seek.prompt.md` — the proposed far-seek fix RE-OPENS the session per
far seek, multiplying this leak. Do this leak fix first, or together.
