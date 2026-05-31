# Handoff prompt → Cilex Vision (footage-coverage / `/review/sessions` window)

*Paste this into the Claude Code session running in the **cilex-vision** backend repo. It points to the letter, the read order, the context, the ask, the guardrails, and how to reply.*

---

You are Claude Code working in the **cilex-vision** backend repo (`/home/cilex-vision/projects/cilex-vision`). The **Watchtower** operator client (sibling repo `/home/cilex-vision/projects/cilex-watchtower`, GitHub `romayankin/cilex-watchtower`) has filed a new backend request. Read it, do the work in this repo, and write a reply letter back.

All paths below are on **this machine** under the Watchtower repo root `/home/cilex-vision/projects/cilex-watchtower/`. The new files may **not** be pushed to GitHub yet — read them from local disk.

## 1. Read, in this order

1. **The request** — `docs/letters/2026-05-31-coverage-from-session-manifest.md`
2. **The canonical spec it builds on (A7)** — `docs/letters/2026-05-30-footage-coverage-calendar-api.md` (full `GET /review/coverage` schema, tz handling, scoping, acceptance)
3. **The exact JSON shapes the client parses (authoritative)** — `docs/letters/fixtures/2026-05-31-coverage/` → `coverage-single.response.json`, `coverage-batch-union.response.json`, `README.md`
4. **The client's implementation plan, for alignment** — `docs/letters/2026-05-31-coverage-from-session-manifest.client-prompt.md` (how Watchtower will derive coverage from the manifest in the interim)
5. **Background / prior commitments** — `docs/letters/2026-05-31-mosaic-integration-next-actions.reply.md` (you agreed to build **A7 + E4 first**, gated on disk health) and `docs/letters/2026-05-31-multicam-synchronized-review.reply2.md` (E4 batch `?camera_ids=` shape confirmed)

## 2. Context you need

- Watchtower is a **read-only operator client**; cameras have **no storage of their own** — every byte of recording/playback comes from cilex-vision. Playback = `POST /review/sessions` → HLS manifest assembled from `video_segments`.
- The footage **calendar** shows **"availability pending"** on *every* playback open (single-camera `PlaybackScreen` **and** the `WallPlayback` aside) because **`GET /review/coverage` (A7) isn't deployed** — it 404s, and the client deliberately **refuses to fabricate** coverage (standing product rule).
- **The new evidence in the letter:** loading a **24H** window paints the seek bar **solid green** end-to-end — and that green is drawn from the `/review/sessions` manifest fragments (`wall_start`/`wall_end`). So the coverage facts the calendar needs are the **same `video_segments` you already serve**, just bucketed by day: a `GROUP BY date(start_time AT TIME ZONE :tz)`.

## 3. What the letter asks — do both

**(A) Decide / ship A7.** `GET /review/coverage?camera_id=<id>[&tz=][&days=]` → `{ retention_days, days:[{ date, has_footage, … }] }`, **operator-readable** (NOT admin-only), days bucketed in the request `tz` (pilot operator = **UTC+3 / Europe/Moscow**), matching the fixtures exactly. The letter's case: it's a thin aggregation over data you already serve, so it should be low-effort / high-visibility.

**(B) Answer the interim questions (a)–(d)** so the client can derive coverage from `/review/sessions` until A7 lands:
- **(a) Window width** — does `POST /review/sessions` accept a ~**35-day** window and return the **complete, uncapped** fragment list? (`/recording/segments` caps at 1000 rows with no cursor — does the session path have a similar cap?)
- **(b) Create cost** — is creating such a session **cheap** (manifest assembly only), or does it kick off remux / HLS prep? (The client reads the manifest JSON and **discards** — never fetches the playlist or any segment.)
- **(c) Lifecycle** — anything to clean up for an **open-and-discard** session, or do they expire on their own?
- **(d) Max window** — if wide windows are discouraged, what window should the client **chunk** to (e.g. 7-day pages)?

## 4. Guardrails (from prior letters — honor these)

- **Do NOT regress single-camera `/review` playback** — it is live in Watchtower today.
- Keep the single-`camera_id` `/review/coverage` response shape **exactly** as the *shipped* client parser expects — `{ retention_days, days:[{ date, has_footage }] }` (the fixtures are authoritative). If A7 + E4 ship together, the batch `?camera_ids=` form may add `per_camera`/`union`, but the single-camera form must stay parseable by the existing client path.
- **Operator-readable**, per-user scoped (D5): scoped users get only their cameras; `403`/`404` for others is fine.
- `retention_days` = longest **sub-stream** raw-video tier retention (~30–35 d), the policy max — **not** the currently-fitting capacity.

## 5. How to reply

Do the backend work in **this** (cilex-vision) repo, then write your reply **into the Watchtower letters dir**, following the house convention:

- **File:** `/home/cilex-vision/projects/cilex-watchtower/docs/letters/2026-05-31-coverage-from-session-manifest.reply.md`
- **Header:**
  ```
  # <title> — <status>

  **To:** Cilex Watchtower (operator client)
  **From:** Cilex Vision
  **Date:** 2026-05-31
  **Re:** [`2026-05-31-coverage-from-session-manifest.md`](./2026-05-31-coverage-from-session-manifest.md) (A7 follow-up)
  **Status:** ✅ DELIVERED | 🔜 PLANNED | …
  ```
- Open with a **TL;DR**, then answer **(a)–(d)** concretely.
- If you **ship A7**: include the **commit hash**, confirm the response **matches the fixtures**, and confirm operator-readability + tz bucketing. If you **defer**: say exactly what you'll ship and when, and confirm whether the client's interim session-derivation (one manifest-only wide-window session, discarded) is **safe to run** in the meantime.
- Keep it **single-problem** — coverage + the session-window questions only; new unrelated asks get their own dated letter.
