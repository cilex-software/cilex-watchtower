# Cilex Watchtower — Backlog

_Last updated: 2026-06-05. Outstanding work after P1–P6 (all phases shipped). This
is the single prioritized list of open items._

**Priority** = impact (P1 highest). **Status:** 🟢 ready (we can do now, no
dependency) · 🔴 blocked (on what) · 🟡 buildable but low-value until a blocker
clears. Backend items map to the living letter
`docs/letters/watchtower-to-cilex-vision-api-requests.md` (codes A#/B#/C#).

## Prioritized

| Pri | Task | Status | Owner |
|-----|------|--------|-------|
| P1 | Shared acknowledge (B1) | 🔴 Blocked — backend endpoint | Cilex → then us (flip ack local→server) |
| P2 | Mixed-codec playback switch — H.264 720p ↔ H.265 1440p across `#EXT-X-DISCONTINUITY` | 🟡 Partially verified (both codecs decode independently; sustained switch un-runnable — codec boundary coincides with the 42h disk-down gap + 24h session cap) | us — re-test in ~1 day via `WT_PLAYBACK_DAY` as post-gap footage ages into warm |
| P2 | Burn-in overlays in export (A2) | 🔴 Blocked — backend re-encode path (sequenced last) | Cilex |
| P2 | Light / Dark theme switching | 🟢 Ready | us — largish (`Theme` is a static singleton; needs to become reactive) |
| P2 | Same-group camera switch in the playback aside | 🟢 Ready | us — medium |
| P2 | Events detail drawer: Export-clip action + camera/date filter pills | 🟢 Ready | us (Bookmark sub-item needs a backend/local decision) |
| P3 | Alert-firing pipeline (toast / sound / desktop notification) | 🟢 Ready — B2 now produces events, so this is worth building | us |
| P3 | Audio export (A5) | 🔴 Blocked — backend (no audio path) | Cilex |
| P3 | Typed manifest fragment schema + read real `resolution` (C1 + latent) | 🔴 Blocked — backend (mostly); `resolution` already read at the playhead | Cilex |
| P3 | Denormalized event camera name/group (C2) | 🔴 Blocked — backend (cosmetic; local MAC lookup works) | Cilex |
| P3 | `"hydrating"` fragments dropped (`availability !== "ready"`) | 🔴 Blocked — needs warm/cold-tier footage to exist before it manifests / can be tested | data condition |
| P3 | GStreamer `hlsdemux2` `g_object_unref` CRITICAL log-spam during HLS playback | 🟢 Ready — parked; cosmetic, playback unaffected (real refcount defect in v2, non-fatal) | us — small (force legacy v1 in `main.cpp`); see Parked detail below |

## Actionable now (🟢, no blocker) — quickest first
1. Same-group camera switch in the playback aside — medium.
2. Events drawer Export-clip + filter pills — medium.
3. Alert-firing pipeline (B2 now produces events) — medium.
4. Silence the `hlsdemux2` v2 log-spam by pinning legacy v1 — small (cosmetic; trade-off, see Parked).
5. Light/Dark theme switching — largest (reactive `Theme` refactor).
6. ~~Map CV's error codes to Russian copy~~ — **DONE 2026-09-20.**
   `src/models/ServerCodes.h` keys copy off `code`, for all 27 of CV's codes read
   from their source (22 literal + the 5 display-session constants), with CV's own
   `message` as the fallback for codes we have not met. Duplicate codes map to one
   string (`account_deactivated` / `SSO_ACCOUNT_DEACTIVATED`), per the agreement
   with cilex-pro-mobile; `role_not_authorized` uses the `role` field so it reads
   «Роль «viewer» не имеет доступа к этому». Wired at 9 DISPLAY sites; log lines
   deliberately keep CV's English, because a translated string is worse evidence.
   Pinned by `tools/tests/server-codes.cpp` (34/34) which asserts no known code can
   reach a guard as an enum or in English, and that an unknown one degrades to CV's
   sentence. Screenshot-verified on the sign-in screen.
7. A suspended service is **silent on a running wall** — small/medium, design call.
   `AuthController.cpp:255` treats a 423 on *refresh* as transient: 3 retries, then
   nothing is scheduled while the token still has life. The wall keeps working, which
   is right — a billing state must not kill a guard's wall — but says nothing for up
   to the token's remaining ~10 h, and only states the real reason once it drops to
   sign-in (fixed there in 1.1.468). Now that `code` exists the two are separable, so
   the wall could stay up *and* say why. Found 2026-09-20 while fixing the sign-in
   case; deliberately not built, because what to show on a working wall is an
   operator/design decision, not a client one.

8. **The `/review` manifest window — guards fixed; the parse itself still open.**
   `root.winStartMs = Date.parse(meta.wall_start)` is bare at
   `PlaybackScreen.qml:1160,1161,1191,1192` and `WallPlayback.qml:686,687,702`, so an
   unreadable window is NaN.
   **CORRECTION 2026-09-22 — this entry first said the consequence was "an empty window that
   looks like no footage". That was asserted, not traced, and it was wrong in both
   directions.** Measured: the guards meant to catch "no usable window" read
   `tlEndMs <= tlStartMs`, which is **false** against NaN, so they fail OPEN — and the next
   line calls `new Date(NaN).toISOString()`, which **throws `RangeError`**. Not an empty
   timeline: a guard failing open into a thrown exception. cilex-pro-mobile traced every
   consumer on their side rather than assuming, found their own equivalent already guarded,
   and corrected a claim they had made in the same breath; doing the same here is what turned
   this up.
   **DONE** (see `git log -S'!(tlEndMs > tlStartMs)'`): all four guards now read `!(end > start)` — identical to `<=` for
   every finite pair by trichotomy, and it fires on NaN. Safe without a live manifest
   precisely because no valid window changes behaviour. `WallPlayback.qml:156` already used
   this form, so the rule was in the codebase and three later guards did not follow it.
   Pinned by `tools/tests/window-guard.qml` (8/8), which also pins the throw.
   **STILL OPEN, and the blocker has MOVED — both original reasons are now cleared:**
   - *"the manifest-level `wall_start` format is not measured"* — cleared by cilex-vision from
     source (2026-09-22): `review.py:549-550` is the manifest window, `:403-404` the fragment
     pair, and **both were `.isoformat()` before their change and both are `iso_ms` after** —
     they have never differed in either direction. `wall_start: datetime` is a required,
     non-Optional Pydantic field (`review.py:63,216`), so the key is always a non-empty
     offset-bearing string. Their reading of their source, not a live capture of mine.
   - *"a C++ guard might refuse a manifest QML could draw"* — my own worry, and measured
     false here: `Qt::ISODateWithMs` and QV4's `Date.parse` agree on all six shapes tested,
     **including the space-separated form** I expected to diverge. No parser asymmetry, so a
     C++-side decision cannot be stricter than the screen that renders it.

   What remains is therefore **not** a format question but a **UI design call**: what three
   screens should SHOW when a session arrives with an unreadable window. The precedent
   (`b31c0ee`) says report it FAILED rather than hand on a ready session, and that is almost
   certainly right — but it is an operator-facing state across `PlaybackScreen`,
   `WallPlayback` and the export path, and this box will not design it blind against a live
   wall. Until then the guards no longer throw and `2527306`'s detector announces a naive
   value on all five `/review` keys.


## Blocked — what clears each
- **Backend shared-ack endpoint (B1)** → server-backed acknowledge (currently local-only).
- **Backend re-encode path (A2)**, **audio path (A5)**, **typed schemas (C1/C2)** → backend-sequenced; we wire when they land.
- **Post-gap footage aging into warm (~1 day)** → unblocks the sustained mixed-codec switch verification. The 42h disk-down gap + the 24h `/review/sessions` cap mean no single session currently spans both codecs. Both codecs already decode + render independently (warm H.264 and hot HEVC each verified).
- **Warm/cold-tier footage existing** → the latent `"hydrating"` fragment fix can be made + tested.

## Parked (low-priority) — detail
**GStreamer `hlsdemux2` GObject-unref CRITICAL** (logged 2026-05-28). During HLS
playback the console repeats `GLib-GObject-CRITICAL g_object_unref: assertion
'G_IS_OBJECT (object)' failed` every ~1.5–2.5 min (stream-event-driven, not a
timer). It is a genuine refcount defect (unref of a non-/freed GObject) but
**non-fatal — playback is unaffected**, hence parked. The other startup lines
(`gst-plugin-scanner ... _dma_fmt_to_dma_drm_fmts`, libcamera `No IPA found`) are
benign noise.
- **Not our code:** `src/` contains zero GStreamer — it originates in Qt
  Multimedia's GStreamer backend. On this host (GStreamer **1.24.2**, Ubuntu
  24.04) both demuxers are registered and `hlsdemux2` (rank 257) outranks legacy
  `hlsdemux` (256), so `decodebin` picks the newer `adaptivedemux2`-based
  `hlsdemux2`, which had object-lifetime bugs in early 1.24.x. (Note: our
  `HlsProxy` `EXT-X-GAP` workaround was written for **v1** behavior, but **v2** is
  what actually runs now.)
- **Confirm / repro:** `GST_PLUGIN_FEATURE_RANK=hlsdemux2:NONE ./build/watchtower`
  forces legacy v1 — if the CRITICAL vanishes, it's the v2 bug. Exact call site:
  `G_DEBUG=fatal-criticals gdb -batch -ex run -ex "bt full" --args ./build/watchtower`.
- **Candidate fix (small, our side):** `qputenv("GST_PLUGIN_FEATURE_RANK",
  "hlsdemux2:NONE")` early in `src/main.cpp`, before Qt Multimedia initialises the
  GStreamer registry — also realigns the demuxer with the v1-targeted proxy
  workaround. **Trade-off:** quieter logs + proxy-aligned, but forgoes the modern
  `adaptivedemux2` engine (better discontinuity/codec-switch handling — relevant to
  the mixed-codec item above). Heavier alternative: bump GStreamer past 1.24.2.

## Resolved since 2026-05-28 (context)
- **Export metadata + Clips server list** — `purpose` (A1) sent on single-cam export
  (`c5b4d98`); typed job response (A3) + exports LIST (A6) wired into the Clips &
  Snapshots library (`fec0374`); verified live against `/review/exports`.
- **Combined-grid export (E2 + I7)** — mosaic export returns `job_id`; one shared
  `group_id` across the N+1 dual-archive jobs; grid clip grouped in the library
  (`fec0374`).
- **Mosaic wall (E1)** — server-composited 16-cam synchronized wall delivered +
  re-verified end-to-end (client-side N-way HLS sync was proven infeasible).
- **Events pipeline (B2)** — events now produce (backend `detections`/tracklets
  fixed); Events screen shows real events, with per-column sort + Excel-style
  autofilters and a Favorites filter pill.
- **`compact` (drop-gaps) export-mode toggle** in the export drawer (`c5b4d98`).
- **"−15s" precise seek** on Open-playback from events — opens the event's day and
  seeks to event-time − 15s (`ee558bd`).
- **Recording mode states** — `stalled` / `armed` / `disabled` + `last_segment_at`
  wired across model, badge, tile, single-cam detail, and Health ("Last recording"),
  with accurate NOT-REC counts.
- Earlier: `mode` → `wallclock` (A4 closed); `/detections` 500 fixed (B3 closed);
  event_type vocab corrected to the authoritative enum; `GET /health/storage` wired.

---
See also: phase status → [PROJECT_STATUS.md](PROJECT_STATUS.md); backend contracts
→ [letters/watchtower-to-cilex-vision-api-requests.md](letters/watchtower-to-cilex-vision-api-requests.md); architecture/build → [DEVELOPMENT.md](DEVELOPMENT.md).
