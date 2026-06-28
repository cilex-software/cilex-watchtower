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

---

## Investigation result (2026-06-28)

Bisected with an open-only harness (`WT_HERO_OPENONLY` loops event-opens with no seeks; `WT_HERO_NOPLAY`
opens the session but skips the decode — both inert unless set) + the `/proc` sampler. Raw data + graph:
`docs/perf/2026-06-28-hero-leak-bisect.{play,noplay,recreate}.csv` + `…-bisect.png`.

### The leak is the DECODE path — not the session/proxy
| variant (open-only loop) | RSS slope |
|---|---|
| open **+ play** (decode) | **+66 MB/min** (~8 MB/source-change → 1.2 GB) |
| open, **NO play** (session + manifest + HlsProxy + QNAM only) | **−0.3 MB/min — FLAT** |
| open + play **+ recreate the MediaPlayer** per open (Loader destroy+recreate) | **+59 MB/min** |

- **No-play is FLAT** → opening sessions does **not** leak. So **`DELETE /review/sessions` will not reduce
  the client RSS** (worth adding as server hygiene — sessions are never reaped — but it is *not* this leak).
  `HlsProxy`'s cache is confirmed **global + LRU-bounded (160 MB)**, not per-session.
- **Play leaks +66 MB/min** → the leak is the Qt-FFmpeg decode pipeline created on `player.source`.
- **Recreating the MediaPlayer does NOT free it** (+59 ≈ +66). So the context is freed by **neither**
  source-clear (already known from A2) **nor** destroying the player. This re-confirms A2: **the leak is
  Qt-internal and cannot be fixed from QML/C++.**

### Conclusion + mitigations
The per-open leak is the **Qt-FFmpeg per-source-change decode-context leak (~8 MB)**, Qt-internal. No
client-side teardown frees it. Realistic mitigations, in order:
1. **Backend continuous-timeline HLS (the A3 letter).** One continuous session per episode means the
   frozen-seek fix no longer re-opens per far seek — removing the **seek-driven** source-changes, which are
   the bulk of the leak during active scrubbing. The per-event open (one source-change per event watched)
   remains. **This is the highest-leverage action and is already requested.**
2. **A Qt upgrade** is the only true fix for the residual per-event leak. The `WT_HERO_OPENONLY` bisect
   harness is kept specifically to re-run this against a newer Qt and confirm.
3. *(Not pursued)* switching the QtMultimedia backend (FFmpeg → GStreamer) — large change, untested.

The Loader-wrap/recreate experiment was **reverted** (no benefit, added per-recreate null-deref churn). The
bisect harness (`WT_HERO_OPENONLY` + `WT_HERO_NOPLAY`) was kept.
