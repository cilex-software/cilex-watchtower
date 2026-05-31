# Handoff prompt → Cilex Vision (E1 mosaic fails at operator scale — fix at-scale compositing)

*Paste this into the Claude Code session running in the **cilex-vision** backend repo. It points to Watchtower's checklist reply, the concrete repro, the candidates, and how to respond.*

---

You are Claude Code working in the **cilex-vision** backend repo (`/home/cilex-vision/projects/cilex-vision`). The **Watchtower** operator client (sibling repo `/home/cilex-vision/projects/cilex-watchtower`, GitHub `romayankin/cilex-watchtower`) ran your 5-point path-to-live checklist against the live `965b091` deploy and found a blocker: **the mosaic (E1) works at 2×2 but never composites the real 16-camera wall.** Read their reply, reproduce it, fix the at-scale compositing, and reply. All paths are on **this machine** under the Watchtower repo root `/home/cilex-vision/projects/cilex-watchtower/` — read from local disk (may not be pushed).

## 1. Read, in this order

1. **The trigger (their checklist run + the blocker)** — `docs/letters/2026-05-31-disk-healthy-path-to-live.reply2.md` (has the full repro matrix + root-cause candidates).
2. **Your deploy/verify reply it responds to** — `docs/letters/2026-05-31-disk-healthy-path-to-live.reply.md` (you verified E1 at 2×2 + flagged a "transient" `Parsed_scale_N` filter-init error).
3. **The mosaic contract** — `docs/letters/2026-05-31-multicam-synchronized-review.reply.md` (E1: grid/cells/manifest, per-cell black, `503`/`Retry-After`/`X-Cilex-Mosaic-State`) + `…reply2.md`.
4. **Coverage spec (must stay intact)** — `docs/letters/2026-05-30-footage-coverage-calendar-api.md` + fixtures `docs/letters/fixtures/2026-05-31-coverage/`.

## 2. The problem (Watchtower verified — curl + the real Qt client on the iGPU)

E1 composites a **2×2 grid of cameras that all have footage** in ~0.4–0.7 s/segment (`200`). But the production wall is **4×4 (16 cameras)**, and after the disk-down gap the fleet is **heterogeneous**: 4 old cameras have deep history; 27 newer cameras only have footage from **after ~19:11Z 2026-05-31** (they didn't exist earlier). So on any historical day the 16-cam wall is mostly **empty cells**, and the composite **never produces a frame** — `seg/0.ts` loops `503 rendering ⇄ error` for 30 s+ and never reaches `200`.

**Concrete repro matrix** (all `seg/0.ts`, cookie-auth as admin; the `503` carries `X-Cilex-Mosaic-State`):

| Grid | `camera_ids` | window (`wall_start`→`wall_end`) | result |
|------|--------------|----------------------------------|--------|
| 2×2 | `hiwatch-083bc14eff9a, hiwatch-083bc14eff9d, hiwatch-083bc14effb2, hiwatch-083bc17adca6` (all have footage) | `2026-05-28T21:00:00Z`→`2026-05-29T21:00:00Z` | **`200` in 3.3 s** ✓ |
| 3×3 | first 9 of the 16 below | same window | **`410`** (drops the populated cell → whole-grid gap) |
| 4×4 | `hiwatch-083bc1df3a0d, hiwatch-083bc1df39ec, hiwatch-083bc1df39e9, hiwatch-083bc1df39e4, hiwatch-083bc14effd4, hiwatch-083bc1df39d7, hiwatch-083bc1df39d1, hiwatch-083bc1df39cc, hiwatch-083bc1df39c7, hiwatch-083bc1df39aa, hiwatch-083bc14f004a, hiwatch-083bc14effb8, hiwatch-083bc14f0014, hiwatch-083bc1df39fa, hiwatch-083bc1df3a4b, hiwatch-083bc1df39cf` (~1/16 have footage) | same window | **`503 rendering⇄error` loop, never `200`** (>32 s, 30 attempts) |
| 2×2 | the 4 originals (known-good) | **live** `2026-05-31T19:30:00Z`→`2026-05-31T19:50:00Z` | **`410`** — even known-good cams, inside their `19:12→20:00Z` coverage |
| 5×5 | 25 cameras | live | `404` (a ≤16-cell cap? — fine, Watchtower caps at 16) |

## 3. What to do — fix E1 at operator scale

Make `/review/mosaic-sessions` composite **robustly** when the grid is **≥ 3×3** and **some/most cells have no footage in the window**. Investigate and fix these candidates (Watchtower's, from the matrix):

1. **Empty-cell black-fill doesn't scale past 2×2.** Your verified "3 cams in a 2×2 → 4th cell black, `200`" path collapses at 3×3 (→ `410`, dropping the populated cell) and 4×4 (→ loop). A grid with *any* footage in *any* cell at the instant should render that cell + black-fill the rest, not `410` and not loop.
2. **The `Parsed_scale_N` filter-init failure is persistent at 16 inputs**, not transient/self-healing as it appeared at 4 inputs. Harden the filtergraph build (serialize concurrent composites, internal retry, or fix the scale-pad config) so a 16-input graph initializes deterministically.
3. **Live-edge `410`** — known-good cams return `410` on a live window well inside their coverage (`19:30–19:50Z` vs coverage `19:12→20:00Z`). Check whether live-edge finalization (`clipped_to_finalized`) is clipping reviewable footage.

**Re-verify against the REAL fleet footage distribution** — the 4→31 growth + the 42 h gap (`05-30 01:16Z`→`05-31 19:11Z`) is the test case, not a hand-picked all-footage 2×2. Prove a **16-cam wall** composites and plays for a historical day.

## 4. Guardrails (honor these)

- **Don't regress** the working paths: 2×2 full-footage compositing, coverage A7+E4 (shapes are fixtured), single-camera `/review`.
- **Client-side budget:** Watchtower honors `Retry-After` for ~12 s, and **now has an 18 s render watchdog** — if a cold render doesn't produce frames by then it surfaces an honest failure (no more infinite "Compositing…"). So a fixed cold **16-cell** render must come up **well under ~12 s**; if a pathological case needs longer, raise `Retry-After` (they back off) but it must eventually `200`, not loop.
- **Confirm the supported max grid** (the `404` at 5×5 implies ≤16 / 4×4 — Watchtower caps at 16, so 4×4 is the target; just confirm it's intended).
- **Single-problem:** this is the E1-at-scale fix only. The combined-grid export (**E2 + I7 + A6**) is **deferred behind it** — don't build export for a grid that won't composite. New unrelated asks get their own dated letter.

## 5. How to reply

Do the fix in **this** (cilex-vision) repo, then write your reply **into the Watchtower letters dir**, house convention:

- **File:** `/home/cilex-vision/projects/cilex-watchtower/docs/letters/2026-05-31-disk-healthy-path-to-live.reply3.md`
- **Header:** `To: Cilex Watchtower` / `From: Cilex Vision` / `Date:` / `Re:` the `.reply2.md` / `Status:`.
- Open with a **TL;DR**, then report: what was broken and the fix; a **re-verification matrix at 3×3 and 4×4 with empty/missing-footage cells** (not just 2×2), each reaching `200` within budget; cold 16-cell render timing; the live-edge `410` finding; and the **commit hash(es)**.
- If it's fixed: **say "re-run the 5-point checklist"** so Watchtower drives the wall end-to-end and flips it on for operators.
- Keep it single-problem (E1 at scale). E2+I7+A6 stays queued behind a working wall.
