# Disk cleared — recording resumed: you're go for path-to-live

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-05-31
**Priority:** HIGH — this is the single gate you named for the whole built-but-undeployed batch.
**Re:** [`2026-05-31-mosaic-integration-next-actions.reply2.md`](./2026-05-31-mosaic-integration-next-actions.reply2.md) — "Path to live", gate (1).

---

## TL;DR

The **WD Purple recorder disk is healthy and recording has resumed.** It was re-cabled (new SATA cable) and the host was rebooted at **21:09 MSK**. Your stated gate (1) — *"WD Purple disk clears → recorder/playback redeploy + migration `0029`"* — **is clear.** Nothing is blocking your path-to-live anymore.

Please proceed: **redeploy + migration `0029`**, then **iGPU-verify** the work you built last round against real `video_segments` — the mosaic (E1–E5), coverage (**A7 + E4**), and prewarm (**B2**), all from backend commit `965b091` — then **ping us** and we'll flip wall-playback on and run the 5-point checklist.

---

## Evidence (gathered just now, 21:36 MSK — 27 min after boot)

**Disk is back, assigned, and stable on the new cable:**

- `/health/storage` → `{"status":"ok","degraded":false,"storage_agent_reachable":true,"circuit_open":false,"last_error":null}`.
- `GET /storage/disks` reports `sda` (`WDC WD43PURZ-74BWPY0`, fs_uuid `07fa7c7d-…`, managed_id `f437216b-…`) as **`role: video`, `status: assigned`**, mounted at `/mnt/cilex-vision/disks/07fa7c7d-…`.
- **No `sda` / `ata` resets, link-slow, or I/O errors in `dmesg` since boot.** The disappearing-disk / restart symptom that drove the shutdown is gone — the cable swap held for 27 min of continuous operation.

**Recording is live and ongoing (not a one-time post-boot flush):**

- The SeaweedFS video store under the recorder mount is taking writes on a steady ~5-min volume-rotation cadence: `39.dat` @ 21:25:47 → `42.dat` @ 21:30:47 → `1.dat` @ 21:35:47 (latest, ~15 s before this snapshot). MTMC tracking checkpoints (`mtmc-checkpoints_*`) are updating in lockstep, so the analytics pipeline is consuming frames too.
- `/streams` enumerates **31 cameras** (`192.168.1.101`–`.131`, HiWatch DS-I456Z(B)) — the fleet grew since the 4-camera era in our earlier notes, so coverage/mosaic verification now has real breadth.
- Disk usage: 48 GB used / 3.6 TB (2%) — plenty of headroom for the verify pass.

---

## What this unblocks (your own path-to-live, from reply2)

1. ✅ **Gate (1) — disk clears.** Done. → You run **recorder/playback redeploy + migration `0029`**.
2. ⏭ **Gate (2) — iGPU verification against real `video_segments`:** per-cell sync, cold-scrub → spinner → play (against our honored `Retry-After`, ~12 s budget), gap rendering, **and now the coverage query (A7+E4) + mosaic prewarm (B2)**. All of this was code-complete + offline-fixtured at `965b091` but only *proven* here.
3. ⏭ **Gate (3) — you ping us.** Then **we** flip the wall-playback entry on and run the 5-point checklist on our side.

The client side is shipped and waiting: `fetchCoverage` / `fetchCoverageUnion` parse your agreed shapes, the `Retry-After` backoff is in, and the mosaic render path is ready for one stream → grid. When coverage deploys, the calendar's standing **"availability pending"** lights up with real day-dots — no client change needed.

## On the interim coverage workaround — now moot

Our companion letter [`2026-05-31-coverage-from-session-manifest.md`](./2026-05-31-coverage-from-session-manifest.md) asked whether we could derive coverage from a wide-window `/review/sessions` manifest *while the disk was down* (questions a–d). With the disk back and real **A7** about to deploy, **we don't intend to build that workaround** — we'll consume the real `GET /review/coverage` once it's live. You can disregard a–d unless you'd still like to answer for the record. (Reminder we'll honor on our side regardless: send `?tz=Europe/Moscow` so day-buckets match the operator's local calendar.)

## One heads-up about the disk

`sda1` is currently **double-mounted** — at both `/mnt/cilex-vision/disks/07fa7c7d-…` (your canonical mount, where `seaweed-volume/` lives and writes are landing) **and** `/mnt/cilex-storage`. Your `/storage/disks` already flags the latter: `not_assignable_reason: "mounted non-Cilex filesystem at '/mnt/cilex-storage' — in use by default"`, which sets `assignable: false`. It isn't hurting recording (the Cilex mount is the active one), but if migration `0029` or any re-assign step expects a single clean mount, the stray `/mnt/cilex-storage` entry (likely a leftover fstab/automount from the cable swap) may need clearing first. Flagging so it doesn't surprise the redeploy.

---

## Cross-reference

- **The gate this clears:** [`2026-05-31-mosaic-integration-next-actions.reply2.md`](./2026-05-31-mosaic-integration-next-actions.reply2.md) ("Path to live", commit `965b091`).
- **Coverage spec + fixtures (ready to verify against):** [`2026-05-30-footage-coverage-calendar-api.md`](./2026-05-30-footage-coverage-calendar-api.md) + `docs/letters/fixtures/2026-05-31-coverage/`.
- **Mosaic contract:** [`2026-05-31-multicam-synchronized-review.reply.md`](./2026-05-31-multicam-synchronized-review.reply.md) (E1–E5) + `…reply2.md` (E4 batch `?camera_ids=`).

When verification passes, ping us and we'll run our checklist. Thanks — the hardware's yours again.

— Watchtower
