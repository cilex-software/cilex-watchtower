# Handoff prompt → Cilex Vision (build E2 + I7 + A6 — combined-grid export, now unblocked)

*Paste this into the Claude Code session running in the **cilex-vision** backend repo.*

---

You are Claude Code working in the **cilex-vision** backend repo (`/home/cilex-vision/projects/cilex-vision`). The **Watchtower** operator client (sibling repo `/home/cilex-vision/projects/cilex-watchtower`) green-lights the combined-grid export you queued. Read it, build E2+I7+A6, and reply. Paths are on this machine under the Watchtower repo root — read from local disk.

## 1. Read, in this order
1. **The green-light + exact client contract** — `docs/letters/2026-06-01-mosaic-export-e2.md`.
2. **The wall is verified live (why it's unblocked)** — `docs/letters/2026-05-31-disk-healthy-path-to-live.reply4.md`.
3. **Your own E2 plan + accepted status** — `docs/letters/2026-05-31-multicam-synchronized-review.reply.md` (E2 section), `docs/letters/2026-05-31-mosaic-integration-next-actions.reply2.md` ("E2+I7+A6 queued"), and `docs/letters/watchtower-to-cilex-vision-api-requests.md` (A6 LIST + I7 group_id = ACCEPTED/CONFIRMED).

## 2. What to build (all three ship together — one schema)

**E2 — mosaic export.** `POST /review/mosaic-sessions/{session_id}/exports`, body **exactly** `{ "wall_start": ISO, "wall_end": ISO, "mode": "wallclock"|"compact" }` (the client already sends this). The `session_id` carries the grid/cameras/layout. Render that window of the mosaic session to one file via the **same compositor** (now fixed at scale) and the **same `export_jobs` pipeline** as single-camera export. Respond `{ "job_id": … }`; the client then polls `GET /review/exports/{job_id}` → token `download_url` (identical flow). The client fires this **alongside** N per-camera `/review/exports` from one operator action — separate firing is fine (their Q5 answer), no combined single-action endpoint needed.

**I7 — `group_id`.** Accept an optional `group_id` on **both** `POST /review/exports` and the mosaic export above; persist it on the job and echo it in the job response + the A6 list. The client sends one `group_id` across the N+1 dual-archive jobs so the list renders them as one grouped row.

**A6 — exports LIST.** `GET /review/exports` returning the operator's exports with the agreed one-schema fields: A1 `purpose`, A3 typed `state`/`output_bytes`/`resolution`/`download_expires_at`/`download_url`, plus `group_id`. Per-user scoped (D5). This unblocks Watchtower's Clips & Snapshots library (today it only enumerates local snapshots).

## 3. Guardrails
- Reuse the **existing `export_jobs` flow + token download** shape — don't fork a new export pipeline; single-camera `/review/exports` must stay unchanged.
- Don't regress the now-working mosaic playback compositor (`51c7b4d`) or coverage/single-cam playback.
- `mode` enum stays `{wallclock, compact}` (same as `/review/exports`).
- Single-problem: combined-grid export + grouping + list only. (The recorder per-stream stall is a separate handoff: `2026-06-01-recorder-per-stream-stall.prompt.md`.)

## 4. How to reply
Reply into the Watchtower letters dir:
- **File:** `/home/cilex-vision/projects/cilex-watchtower/docs/letters/2026-06-01-mosaic-export-e2.reply.md`
- Header: `To: Cilex Watchtower` / `From: Cilex Vision` / `Date:` / `Re:` the green-light / `Status:`.
- Report: the E2 endpoint (confirm it accepts the exact body above + returns `job_id` on the shared flow), I7 `group_id` on both export requests + echoed in A6, the A6 list schema, commit hash, and whether you verified an actual grid export downloads + plays. Then Watchtower wires `group_id` + the Clips library and drops the "E2 pending" stub.
