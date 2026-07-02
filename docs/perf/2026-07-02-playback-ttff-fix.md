# Historic-playback start latency ("~14 s TTFF") — root cause + fix (2026-07-02)

The comprehensive soak (`2026-07-02-comprehensive-soak-results.md`) left one open item: opening a
day for a heavy-footage camera sat on the spinner ~14 s before video appeared (the user's
"historic playback is awfully slow" report, degraded state: all cameras unplugged but .201).
The soak doc attributed it to "the FFmpeg backend prerolling the full 24 h playlist" — that
hypothesis is **falsified below**. The real cause is client-side HTTP queueing; fixed same day.

## Elimination chain (each step measured, scripts in the session scratchpad)

1. **Backend?** No. Full heavy-day session create (.106 / 2026-07-01, 1518 fragments): **0.25 s**
   via curl. Playlist: 0.04 s (207 KB, 1446 segments). Segments: 0.03–0.22 s, no 503s.
2. **FFmpeg preroll ∝ playlist length?** No. `ffmpeg -frames:v 1` through a cookie-injecting
   local proxy (faithful to our HlsProxy path): **0.16 s at 15, 60, 240, 480 and 1446 segments** —
   flat. Also flat with the proxy's per-segment `#EXT-X-DISCONTINUITY` injection replicated
   (the GStreamer PTS-reset safety net is innocent for startup latency, at least on FFmpeg 7.1).
3. **In-app staged timing** (new `[PBTIME]` logs): the media pipeline (source-set → first frame)
   is **0.2–0.7 s at every playlist size**. The dominant stage is `session_http` — the
   `POST /review/sessions` round-trip *inside the app*: 3.9 s at boot, 2.6–2.8 s on day switches,
   while a parallel curl of the *same endpoint at the same moments* stayed 0.1–0.8 s and the GUI
   loop kept ticking (WT-MEM timers) → not the server, not a GUI block.
4. **Dose-response, before the fix**: `[PBTIME] session_dispatch` counted in-flight requests to the
   backend host on the shared QNAM at POST time — `inflight=12 → 2282 ms`, `inflight=6 → 537 ms`,
   `inflight=0 → 171 ms`. Perfect correlation.

## Root cause

`PlaybackClient` shared `AuthController`'s `QNetworkAccessManager` with **everything else** that
talks to the backend — `CvImageProvider` (event-snapshot thumbnails), `EventModel`, `CameraModel`,
`StorageHealth`, `SiteMapModel`. Qt's QNAM opens at most **6 concurrent connections per host**, so
a calendar day-open's session POST queued behind the Events screens' thumbnail storm. Under real
churn the shared pool carried **63–68 in-flight requests** to :8000 (measured in a 10-min
WT_GUARD_SOAK slice) — a POST entering that queue waits >10 s. That is the soak's "14 s TTFF" and
the operator's "clicking calendar days is awfully slow": every open fires events/snapshot traffic
that throttles the *next* open.

## Fix (`src/models/PlaybackClient.cpp`)

`PlaybackClient` now creates its **own `QNetworkAccessManager`** (own 6-connection pool) and
mirrors the `access_token` cookie from `AuthController` (same pattern as `HlsProxy::setAuthToken`),
refreshed on `authenticatedChanged`/`baseUrlChanged`. All playback control-plane calls (sessions,
coverage, timeline, exports incl. downloads, mosaic) ride the private pool; thumbnails can no
longer starve them. No behavioral change anywhere else; the Qt 6.4/GStreamer HlsProxy playlist
workarounds are untouched.

## Result (build68 + Qt 6.8.3, real degraded backend)

| scenario | before | after |
|---|---|---|
| session POST, quiet app | 174 ms – 4.1 s (pool-dependent) | **82–436 ms** |
| day-open TTFF, quiet app (heavy .106 days) | 0.8 – 4.2 s | **0.46 – 1.1 s, mean 734 ms** |
| single day-open TTFF under full churn (shared pool at 67 in-flight) | ~14 s (soak measurement) | **~1.0 s** (POST 495 ms) |
| empty day (2026-06-20) | honest empty state | unchanged (honest empty state) |

10-min WT_GUARD_SOAK churn slice after the fix: 0 `[GUARD] ERR`, no crash, RSS ~488 MB normal.
(The slice's one 4.8 s first-frame is the cal-sweep harness firing 4 *simultaneous* day-opens with
2.4 MB manifests — self-contention on our own pool, not an operator pattern.)

## Kept instrumentation

- `[PBTIME]` stage logs (open → dispatch+inflight → HTTP → marshal → mediaStatus → first frame),
  active under `WT_TRACE=1` or the harness.
- `WT_TTFF_DAYS="d1,d2,…"` harness: opens each day in turn, logs `[TTFF]` per open + a summary,
  quits. Pair with `WT_PLAYBACK_IP`. This is the before/after tool for any future TTFF work.

## Follow-ups (not done here)

- ~~The Events screens' own queries still share the auth NAM with the thumbnail storm~~ — **done
  same day**: the thumbnail storm (CvImageProvider) was evicted to its own NAM, un-starving the
  events queries and every other shared-NAM consumer. See `2026-07-02-events-nam-split.md`.
- The backend session POST itself is ~0.15–0.4 s; if sub-300 ms TTFF is ever wanted, next lever is
  overlapping the session POST with pipeline spin-up, not playlist windowing.
