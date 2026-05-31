# Handoff prompt → Cilex Vision (disk healthy — run path-to-live)

*Paste this into the Claude Code session running in the **cilex-vision** backend repo. It points to the trigger letter, the context, what to do, and how to reply.*

---

You are Claude Code working in the **cilex-vision** backend repo (`/home/cilex-vision/projects/cilex-vision`). The **Watchtower** operator client (sibling repo `/home/cilex-vision/projects/cilex-watchtower`, GitHub `romayankin/cilex-watchtower`) reports that the hardware blocker you named has cleared. Read the letter, do the deploy/verify work in this repo, and write a reply.

All paths below are on **this machine** under the Watchtower repo root `/home/cilex-vision/projects/cilex-watchtower/`. New files may **not** be pushed to GitHub yet — read them from local disk.

## 1. Read, in this order

1. **The trigger** — `docs/letters/2026-05-31-disk-healthy-path-to-live.md` (disk healthy + recording resumed; gate (1) clear).
2. **Your own plan it unblocks** — `docs/letters/2026-05-31-mosaic-integration-next-actions.reply2.md` (the "Path to live" you wrote; the built-but-undeployed batch at commit `965b091`: A7+E4 coverage, B2 prewarm, mosaic E1–E5).
3. **Coverage spec + the exact JSON the client parses** — `docs/letters/2026-05-30-footage-coverage-calendar-api.md` and `docs/letters/fixtures/2026-05-31-coverage/` (`coverage-single.response.json`, `coverage-batch-union.response.json`, `README.md`).
4. **Mosaic contract** — `docs/letters/2026-05-31-multicam-synchronized-review.reply.md` (E1–E5) + `…reply2.md` (E4 batch `?camera_ids=`).

## 2. Context you need

- The WD Purple recorder disk was re-cabled and the host rebooted at **21:09 MSK**. As of 21:36 MSK: `/health/storage` is `ok`/not-degraded, `sda` is `assigned`/`role: video`, **no `sda`/`ata` resets in `dmesg` since boot**, and the SeaweedFS video store is taking writes on a steady ~5-min cadence across **31 cameras**. The disappearing-disk symptom is gone.
- This is the **single gate** your reply2 put on everything: *"WD Purple disk clears → recorder/playback redeploy + migration `0029`"*, then iGPU verification, then you ping Watchtower.
- Watchtower is a **read-only operator client**; all recording/playback comes from cilex-vision. The footage calendar shows **"availability pending"** until `GET /review/coverage` (A7) actually deploys — the client refuses to fabricate coverage.

## 3. What to do

1. **Redeploy** recorder/playback and **run migration `0029`** against the now-healthy disk.
2. **Verify on the iGPU against real `video_segments`** — the items you listed: per-cell mosaic sync, cold-scrub → spinner → play (against Watchtower's honored `Retry-After`, ~12 s budget), gap rendering, **the coverage query (A7 single + E4 batch union)**, and **mosaic prewarm (B2)**.
   - Confirm the deployed `GET /review/coverage` responses still **match the committed fixtures** exactly (single: `{retention_days, days:[{date, has_footage, …}]}`; batch: `{per_camera, union}`), are **operator-readable** + per-user scoped (D5), and bucket days in the request `tz` (pilot = `Europe/Moscow`).
3. **Heads-up to check during redeploy:** `sda1` is **double-mounted** (`/mnt/cilex-vision/disks/07fa7c7d-…` *and* a stray `/mnt/cilex-storage`); your `/storage/disks` flags the latter (`assignable: false`). Confirm migration `0029` / any re-assign step tolerates this, or clear the stray mount first.
4. The interim `/review/sessions` coverage-derivation questions (a–d) in `2026-05-31-coverage-from-session-manifest.md` are now **moot** — Watchtower will consume the real A7 instead of building the workaround. Answer for the record only if useful.

## 4. Guardrails (honor these)

- **Do NOT regress single-camera `/review` playback** — it's live in Watchtower today.
- Keep the single-`camera_id` `/review/coverage` shape **exactly** as the shipped client parser expects (fixtures are authoritative).
- `retention_days` = longest sub-stream raw-video tier retention (the policy max, ~35 d), read live from `storage_tier_config` — not current capacity.

## 5. How to reply

Do the work in **this** (cilex-vision) repo, then write your reply **into the Watchtower letters dir**, house convention:

- **File:** `/home/cilex-vision/projects/cilex-watchtower/docs/letters/2026-05-31-disk-healthy-path-to-live.reply.md`
- **Header:**
  ```
  # <title> — <status>

  **To:** Cilex Watchtower (operator client)
  **From:** Cilex Vision
  **Date:** 2026-05-31
  **Re:** [`2026-05-31-disk-healthy-path-to-live.md`](./2026-05-31-disk-healthy-path-to-live.md)
  **Status:** ✅ VERIFIED LIVE | 🔜 IN PROGRESS | …
  ```
- Open with a **TL;DR**, then report: redeploy + migration `0029` outcome; iGPU verification results per item (mosaic sync, cold-scrub, gaps, coverage A7+E4, prewarm B2) **against real recorded data**; the double-mount check; and the **commit hash(es)**.
- If verification passes, **explicitly say "ping accepted — Watchtower, flip wall-playback on and run the 5-point checklist"** so we know it's our turn.
- Keep it **single-problem** — the deploy/verify of the `965b091` batch only; new unrelated asks get their own dated letter.
