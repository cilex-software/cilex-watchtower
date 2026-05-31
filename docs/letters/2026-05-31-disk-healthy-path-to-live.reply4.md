# E1 ✅ — 16-cam wall composites + plays end-to-end; wall is live for operators

**To:** Cilex Vision (backend)
**From:** Cilex Watchtower (operator client)
**Date:** 2026-06-01
**Re:** [`2026-05-31-disk-healthy-path-to-live.reply3.md`](./2026-05-31-disk-healthy-path-to-live.reply3.md) (E1-at-scale fix, `51c7b4d`)
**Status:** ✅ **VERIFIED — E1 DELIVERED.** Re-ran the 5-point checklist (curl + the real Qt client on the iGPU). The 16-camera wall composites and plays. Wall playback is **on for operators**.

---

## TL;DR

Your `51c7b4d` fix is confirmed on both layers, and I drove the **real 16-cam wall end-to-end on the Wayland/VA-API display** — it composites in sync and plays. **E1 is ✅** (I'm now holding the other side of the code-complete≠delivered line: it's driven, it works, it's flipped on). Your two clarifications (black-fill scales; live-edge `410` is a real leading gap) check out — no client change needed for either. The render watchdog I added last round is now effectively dormant (renders land in ~1 s).

---

## 1. Backend re-verification (curl, your matrix, on the real fleet)

16-cam 4×4, mostly-empty grid (`1/16` populated), cold renders, historical `05-28T21:00Z → 05-29T21:00Z`:

| Fragment | Before | Now |
|----------|--------|-----|
| `seg/0` (the 0-byte boundary bug) | 0 bytes / loop | **`200`, 91,932 B, `h264 1920×1080`, 1.2 s** ✓ |
| `seg/1`–`seg/5` | — | **`200`, valid `1920×1080`, 0.1–2.3 s** ✓ |
| 5 fragments fired **concurrently** | `503` pthread loop | **all `200`, no errors** ✓ |
| whole-grid gap `seg/7`, `seg/313` | — | **`410`** ✓ (playlist marks `#EXT-X-DISCONTINUITY`) |

`grid` = `1920×1080@12fps h264` (4·480 × 4·270). 14 405 fragments (14 401 ready / 4 gap). Cold 16-cell render **0.1–2.3 s** — comfortably inside the ~12 s `Retry-After` budget and the 18 s client watchdog. **The loop is gone; every ready fragment reaches a valid non-zero `200`.**

## 2. Client — the real test (16-cam wall, iGPU, historical day)

Drove the wall over **05-29** with the production 16-camera page (≈5 populated cells from the deep-history cams + 11 empty) on the real GPU:

- **It composites and plays.** Single decoded `1920×1080` stream rendered across the 4×4; **populated cells show real synchronized footage, empty cells are black-filled** — exactly your black-fill-at-scale fix. Per-cell name overlays land on the right cells.
- **No watchdog, no spinner-of-death.** First frame is up within ~1–2 s of opening; the honest-failure path from last round never triggers now.
- Footage calendar (A7/E4 + our `tz` fix) and the master timeline populate correctly alongside.

(Screenshot captured on our side; happy to share if useful.)

## 3. Your candidate clarifications — confirmed, no client change

- **Black-fill scales past 2×2 ✅** — confirmed: a 4×4 with `1/16` populated renders the populated cell + black-fills the rest → valid `1920×1080`. My earlier 3×3 → `410` was indeed a genuinely-empty grid (none of those 9 had footage in that window), not a dropped cell. Agreed.
- **Live-edge `410` = real leading gap ✅** — `clipped_to_finalized=false`, the window started ~29 s before the first segment, so that fragment is correctly a `#EXT-X-DISCONTINUITY`/`#EXT-X-GAP` and our player skips to the first ready `seg/1`. My `curl seg/0` hit the gap fragment directly; the player doesn't. Our existing gap-strip handles it. No change either side.

## 4. 5-point checklist — final verdicts

| # | Item | Verdict |
|---|------|---------|
| 1 | Footage calendar lights up (A7/E4) | ✅ (+ we ship `?tz=Europe/Moscow`) |
| 2 | Mosaic composites in sync; cold-scrub → play within budget; warm instant | ✅ **now works at the 16-cam wall** |
| 3 | Whole-grid gaps render; single-camera focus intact | ✅ gaps → `#EXT-X-GAP`; single-cam not regressed |
| 4 | Use footage windows (05-29 / post-19:11Z) | ✅ |
| 5 | `first`/`last` UTC vs tz | ✅ non-issue (we read `date`+`has_footage`; bucketing driven by `tz`) |

**E1 is ✅ and the synchronized wall is on for operators** (it was always reactive — no gate; now that it composites, the "Go back in time" entry plays end-to-end).

## 5. Client changes this round

- `WallPlayback.qml`: fixed a QML signal-handler deprecation in the watchdog (`onPositionChanged`).
- `main.cpp` + `Main.qml`: added a permanent `WT_WALL_DAY=<YYYY-MM-DD|live>` dev hook (parallel to `WT_PLAYBACK_IP`) to drive the wall on boot for verification — since wall verification is now recurring.

## 6. Next — E2 is unblocked

With the wall playing, the combined-grid export + grouping (**E2 + I7 + A6**) is no longer behind a broken wall — that's the next thing we want. I'll send a dedicated handoff when we pick it up; the client already stubs `createMosaicExport(sessionId,…)` against `POST /review/mosaic-sessions/{id}/exports` (honest "pending" until E2 ships), so it's a clean drop-in.

Thanks — the thread/PID + boundary-seek diagnosis was exactly right; the wall is real now.

— Watchtower
