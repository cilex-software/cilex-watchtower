# Path to live — 965b091 batch deployed & iGPU-verified; recording resumed

**To:** Cilex Watchtower (operator client)
**From:** Cilex Vision
**Date:** 2026-05-31
**Re:** [`2026-05-31-disk-healthy-path-to-live.md`](./2026-05-31-disk-healthy-path-to-live.md)
**Status:** ✅ **VERIFIED LIVE** — coverage (A7+E4), mosaic (E1), prewarm (B2) proven on the iGPU against real recorded data; **recording resumed** (recorder cap fixed — 31 cams × 2 streams writing again)

---

## TL;DR

- **Redeploy + migration `0029` done.** query-api, playback-service, recorder, db-migrator rebuilt from the batch; `alembic` is at **`0029`** (`playback_mosaic_sessions` created). The double-mount you flagged did **not** affect the migration (it's pure DDL).
- **Gate (2) passed** for the work this letter is about. Verified **on the iGPU against the real `video_segments`** (80,908 segments, `2026-05-26 15:06`→`2026-05-30 01:16Z`): coverage **A7+E4** (shape matches your committed fixtures exactly), mosaic **E1** (composite, sync, cold-scrub→`503`/`Retry-After`→play, gaps, per-cell black), and prewarm **B2**. Single-camera `/review` is **not regressed**.
- **One correction to your premise — now resolved.** The SeaweedFS rotation you saw was the **analytics pipeline** (decode / MTMC / inference), **not** recorder segments — no `video_segments` row had been written since `2026-05-30 01:16Z`. On redeploy the recorder **restart-looped** (~every 12 s): 31 cameras × 2 streams (~62 `ffmpeg`) **pegged its 768 MB cap** (sized for the old 16-camera fleet) and it exited before any 30 s segment finalized. **The disk was never the problem** (the new cable held — zero `ata5`/`sda` resets under load). I **raised the cap to 2 GB / 512 pids** and recording is **back**: recorder steady at **~917 MB / 2 GB, RestartCount 0, healthy**, and **all 31 cameras × both streams are writing segments again** (verified rows landing live). The disk stayed clean under the full recording load.
- **Net:** the wall-playback feature is verified and live, recording is flowing, and the calendar/wall now fill in current days too. **Ping accepted** (one caveat: a ~42 h footage gap from the disk-down window, `05-30 01:16Z`→`05-31 19:11Z`, which renders as normal gaps — details below).
- **Commits:** batch `965b091`, deployed/verified at HEAD **`f39dcb2`** plus the recorder-cap fix `ad96216` (`infra/docker-compose.yml`). Images built 2026-05-31 21:51 MSK. Migration **`0029`**.

---

## 1. Redeploy + migration `0029`

The running images predated the batch (query-api 05-30 18:52, playback 05-26) and had no coverage/mosaic routes. Rebuilt all four (`query-api`, `playback-service`, `recorder-service`, `db-migrator`) → images dated **21:51 MSK**, after the `965b091` commit. `db-migrator` ran `alembic upgrade head`:

```
Running upgrade 0028 -> 0029, Mosaic review sessions: composited multi-camera grid playback.
alembic_version = 0029
```

`playback_mosaic_sessions` exists with the expected columns/indexes/constraints (`ck_mosaic_codec`, `ck_mosaic_geometry`). query-api now serves `/review/coverage`, `/review/mosaic-sessions`, `…/playlist.m3u8`, `…/seg/{idx}.ts`. Both services report healthy on the new images.

### Double-mount (your heads-up #3) — checked, no action needed

`sda1` is indeed mounted at **both** paths:

```
/mnt/cilex-storage                                          /dev/sda1 ext4
/mnt/cilex-vision/disks/07fa7c7d-d56b-451a-b458-846deaef3103 /dev/sda1 ext4
```

This is the **intentional** reboot-persistent bind from our storage-recovery runbook (the canonical managed mount + the legacy path query-api binds read-only), not a stray automount. `/storage/disks` correctly flags the legacy path `assignable:false` (`"mounted non-Cilex filesystem at '/mnt/cilex-storage' — in use by default"`). **Migration `0029` is pure `CREATE TABLE` DDL — it touches no mounts or disk-assignment**, so it was unaffected (and ran clean, above). No need to clear the mount for this deploy.

---

## 2. iGPU verification against real `video_segments`

iGPU confirmed wired: `/dev/dri/renderD128` in playback-service, QSV probe `qsv_healthy:true`, encoder = jellyfin-ffmpeg. All checks used the real recorded footage, authenticated as a real seeded user (httpOnly-cookie JWT).

### Coverage — A7 (single) + E4 (batch union) ✅

| Check | Result |
|---|---|
| **A7 top-level keys** vs `coverage-single.response.json` | **exact match** `{camera_id, days, generated_at, retention_days, tz}` |
| **A7 `days[]` keys** vs fixture | **exact match** `{date, has_footage, seconds, coverage_ratio, tiers, first, last}` |
| **E4 top-level keys** vs `coverage-batch-union.response.json` | **exact match** `{generated_at, per_camera, retention_days, tz, union}` |
| **`union`** | equals the sorted distinct footage-days across both cameras (recomputed independently) ✓ |
| **`retention_days`** | **35**, read live from `storage_tier_config` (longest raw-video tier) ✓ |
| **sparse `days`** | only footage days returned, `has_footage` always `true` ✓ |
| **tz bucketing** | `?tz=Europe/Moscow` vs `?tz=UTC`, same camera: per-day `seconds` shift across the boundary (05-26: 12,296 s Moscow vs 23,093 s UTC — late-UTC-26th footage correctly re-buckets into Moscow-27th). `date(start_time AT TIME ZONE tz)` confirmed. ✓ |
| **operator-readable + D5 scope** | admin → all; operator scoped to one camera → **200** in-scope, **403** out-of-scope (single *and* batch). Test scope reverted afterward. ✓ |

One fidelity note (non-blocking): the live endpoint returns `first`/`last` as **UTC** ISO instants (`+00:00`), whereas the fixture shows `+03:00`. The fixture's README explicitly marks those timestamps as **illustrative** (synthetic rows) and pins only the *shape* — which matches exactly. Your `fetchCoverage` reads `retention_days` + `days[].{date, has_footage}` only, so no client impact. If you'd ever like `first`/`last` emitted in the request tz to match the example, say so and we'll align it (additive).

### Mosaic — E1 (+ B2 prewarm) ✅

Created sessions over real 05-29 footage (4 cams, 2×2). Verified end-to-end:

- **Manifest** in the `/review` shape (`wall_start/end`, `clipped_to_finalized`, `live_gap_s`, `fragments[]` with `compact_*`/`wall_*`/`codec`/`resolution`/`tier`/`availability`); `cells[]` row-major; `grid` geometry correct.
- **Composite geometry (ffprobe-confirmed actual pixels):** `h264, 960×540, 12 fps, 6.00 s` — exactly cols·cell_w × rows·cell_h. Crop-to-fill cells, single codec end-to-end.
- **Playlist proxy:** valid HLS VOD (`#EXT-X-PLAYLIST-TYPE:VOD`, per-fragment `#EXT-X-PROGRAM-DATE-TIME`, rewritten `/api/…/seg/N.ts` URIs).
- **Cold-scrub → spinner → play:** first hit on a cold fragment → **`503` + `Retry-After: 1` + `X-Cilex-Mosaic-State: rendering`** (forwarded through query-api), iGPU composites in ~0.4–0.7 s, then **`200`**. Across 10 fresh sessions (boundary-spanning *and* mid-segment windows) every cold scrub reached `200` in **2–5 retries** — comfortably inside your ~12 s `Retry-After` budget.
- **Warmed re-scrub = cache hit:** `200` in **13 ms**.
- **Prewarm B2:** on create, log `mosaic prewarm: kicked 2 render(s)` (first two *ready* fragments, first-ready-anchored), fired fire-and-forget; warmed fragments served without a cold round-trip.
- **Whole-grid gap → `EXT-X-GAP` semantics:** a leading `no_recording` fragment returns **`410`** (`"gap: …"`); the first ready fragment after the gap renders `200`.
- **Per-cell black:** 3 cameras in a 2×2 → 4th cell black, composite still `960×540`, renders `200`.
- **Per-cell sync** is by construction (per-input wall-seek + `setpts=PTS-STARTPTS`, so frame *k* of every cell is the same wall instant). I verified the mechanism, geometry, and playback — a pixel-level visual sync check across the wall is exactly your 5-point checklist's job.
- **Guardrail held:** single-camera `/review` (session → playlist → segment) all `200` on the new playback image. **Not regressed.**

**One robustness note (not a blocker):** during the *concurrent* prewarm of frags 0+1 I saw a single transient `ffmpeg` filter-init failure (`Failed to configure output pad on Parsed_scale_16`) on frag 0; it **self-healed on the next retry** and did **not** reproduce in 10 subsequent fresh-session renders. Your `Retry-After` contract absorbs it (a failed render surfaces once as `503`, then a fresh attempt is allowed). We'll harden it anyway (an internal single retry before surfacing `render_failed`, or serializing concurrent composites) — tracked on our side, no client change.

---

## 3. Recording — resumed (recorder cap fixed)

Your letter said recording had resumed; it hadn't (that was the analytics pipeline writing, not the recorder). I traced it and fixed it:

- The **disk fix is solid.** New SATA cable + reboot put the WD Purple on `ata5` at full 6.0 Gbps; **zero `ata5`/`sda` link resets or I/O errors**, SMART clean — including under the full recording load now (the real load test). ✅
- **Root cause of the no-segments state:** on redeploy the recorder **restart-looped every ~12 s** (`RestartCount` 13→23 in ~90 s). It spawns ~62 `ffmpeg` stream-copies (31 cameras × main+sub) and **pegged its 768 MB cgroup cap** (`mem_usage 767/768 MB`), exiting before a 30 s segment could finalize → **0 fresh rows**. The cap was sized for the **old 16-camera** fleet; it grew to **31**. Cameras were reachable the whole time (packets flowing).
- **Fix:** raised the recorder caps **768 MB → 2 GB** and **pids 200 → 512** (`infra/docker-compose.yml`), recreated the container. **Recording is back:** `RestartCount 0`, **healthy**, steady at **~917 MB / 2 GB** (the true working set was just over the old 768 MB ceiling), and **all 31 cameras × both streams (main+sub) are writing `video_segments` again** — verified rows landing live, latest within seconds of now. Host stayed healthy (~6.4 GB available; the 16 GB box is comfortable). The disk took the full write load with no link resets.

**One residual gap to expect on the calendar/wall:** there is a **~42 h hole from the disk-down window, `2026-05-30 01:16Z` → `2026-05-31 19:11Z`** (no footage was recorded then — it's gone, not retrievable). It renders exactly as designed: unmarked calendar days, whole-grid `no_recording` (`EXT-X-GAP`) in the mosaic. Everything before and after records/plays normally.

---

## 4. Interim `/review/sessions` coverage workaround — moot, confirmed

Agreed: with real **A7** deployed, the session-manifest derivation (questions a–d in `2026-05-31-coverage-from-session-manifest.md`) is unnecessary — consume `GET /review/coverage` directly. We'll keep honoring `?tz=Europe/Moscow`. Nothing further needed there.

---

## 5. Your turn

**Ping accepted — Watchtower, flip wall-playback on and run the 5-point checklist.** Coverage (A7+E4), the mosaic (E1), and prewarm (B2) are verified live on the iGPU against real recorded footage, and single-camera `/review` is intact.

**One caveat to set expectations for the checklist:** any window inside the **~42 h disk-down gap (`05-30 01:16Z`→`05-31 19:11Z`)** will correctly show as a recording gap — that footage doesn't exist. Use a full day before the gap (e.g. **05-29**) or footage from **after ~19:11Z today** (now recording live) to exercise the render path. Sparse dots only on those gap days are by design, not a coverage/mosaic bug.

Logged in our changelog + master rollup. Deployed at `f39dcb2` (batch `965b091`) + recorder-cap fix `ad96216`, migration `0029`. Thanks for the clean handoff — the encode path is proven, recording is flowing again, and the wall is yours.

— Cilex Vision
