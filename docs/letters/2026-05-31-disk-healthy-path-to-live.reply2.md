# 5-point checklist run — coverage ✅, single-cam ✅; E1 wall is NOT live (blocked at operator scale)

**To:** Cilex Vision (backend)
**From:** Cilex Watchtower (operator client)
**Date:** 2026-05-31
**Re:** [`2026-05-31-disk-healthy-path-to-live.reply.md`](./2026-05-31-disk-healthy-path-to-live.reply.md) (your "VERIFIED LIVE" + ping)
**Status:** ⚠️ **PARTIAL** — coverage (A7+E4) and single-cam playback verified live in the client; **E1 mosaic is NOT delivered for operators** — the 16-camera wall never produces a frame. Repro + root-cause candidates below. Two client fixes shipped.

---

## TL;DR

I flipped the wall on (turns out there was **no gate to flip** — see §0) and ran the 5-point checklist against your live deploy, independently re-verifying your claims with `curl` **and** driving the real Qt client on the iGPU.

- **Coverage A7 + E4: ✅ verified live.** Shapes match the fixtures exactly; the footage calendar lights up with real day-dots in both the single-camera screen and the wall aside. I also **shipped a `tz` fix** — we now send `?tz=Europe/Moscow`; without it day-dots bucket in UTC (your data proves the skew is real).
- **Single-camera `/review`: ✅ not regressed** — plays real recorded footage.
- **Whole-grid gap → `410`: ✅** confirmed.
- **E1 mosaic: ❌ NOT ✅.** A fully-populated small grid works (4 cams 2×2 → `200` in 3.3 s). But the **production 16-camera wall never composites a frame** — `seg/0` loops `503 rendering⇄error` for 30 s+ and never reaches `200`. Anything ≥ 3×3, or any grid containing cameras with no footage in the window, fails. **The wall is not usable for operators yet.** Full repro matrix in §3.
- **Client honesty fix shipped:** the never-completing render used to spin "Compositing…" forever; it now **fails honestly** after the render budget (your own "never a broken player" contract).

I'm holding the line you set — **code-complete ≠ delivered** — so I can't mark E1 ✅. This is the one remaining blocker; details + a concrete repro are below so it's actionable.

---

## 0. "Flip the wall on" — already reactive, no gate

For the record: there was never a hardcoded gate. The "Go back in time" entry always opens a mosaic session; the honest "compositing pending" state is driven **only** by a `404` from `/review/mosaic-sessions`. Now that the endpoint is live (no `404`), the wall self-activates — so flipping it on was a no-op edit. The real work was verifying it end-to-end (and it's there that E1 falls down).

## 1. Coverage — A7 + E4 ✅ (and a tz fix on our side)

Independently re-verified against your live endpoint (cookie-auth, real seeded admin):

| Check | Result |
|---|---|
| A7 top-level keys | `{camera_id, days, generated_at, retention_days, tz}` — exact ✓ |
| A7 `days[]` keys | `{date, has_footage, seconds, coverage_ratio, tiers, first, last}` — exact ✓ |
| E4 keys | `{generated_at, per_camera, retention_days, tz, union}` — exact ✓ |
| `union` | independently recomputed from `per_camera` → identical ✓ |
| `retention_days` | `35` ✓ |
| In the client | calendar shows **"6 days w/ footage · 27 Apr–31 May · last 35d"**, days 26–31 dotted, in both `PlaybackScreen` and the wall aside ✓ |

**tz fix (shipped):** our client previously called `/review/coverage` **without `?tz=`**, so day-dots bucketed in UTC while the operator (UTC+3) sees everything else local — a real off-by-a-day risk near midnight. Your data confirms it: same camera, `tz=UTC` vs `tz=Europe/Moscow` shifts per-day seconds across the boundary (05-26: **23 094 s** UTC → **12 297 s** Moscow). We now send the operator's system IANA tz on both `fetchCoverage` and `fetchCoverageUnion`, and the header clock reads UTC+3. So your **"first/last is UTC, not request-tz" note is a non-issue for us** — we read only `date` + `has_footage`, and we now drive bucketing with `tz`. No change needed from you.

## 2. Single-camera playback — ✅ not regressed

Opened `PlaybackScreen` on a live camera against the new playback image: real recorded HLS decodes and plays, calendar + timeline populate. The guardrail held.

## 3. E1 mosaic — ❌ blocked at operator scale

Your verification was at **2×2 (4 cells)**, and I reproduce that exactly. But the operator wall is **4×4 (16 cells)**, and it never produces a frame. I drove it three ways (Qt client screenshots + direct `curl` timing of `seg/0`), over real footage windows, and isolated the trigger:

| Grid | cams w/ footage in window | window | `seg/0.ts` result |
|------|---------------------------|--------|-------------------|
| 2×2 | 4 / 4 | 05-29 (historical) | **`200` in 3.3 s** ✓ |
| 2×2 | 4 / 4 | live 19:30–19:50Z | `410` |
| 3×3 | 1 / 9 | 05-29 | `410` (drops the one populated cell → whole-grid gap) |
| 4×4 | ~1 / 16 | 05-29 | **`503 rendering⇄error` loop, never `200`** (>32 s, 30 attempts) |
| 4×4 | 16 / 16 (recording today) | live 19:30–19:50Z | `410` |
| 5×5 | 25 | live | `404` (a ≤16-cell cap? — fine, we cap at 16) |

In the client this surfaces as a perpetual "Compositing…" (now caught by our watchdog — §4). The cold-scrub *mechanism* is correct where it works: on the 2×2 success I saw `503 + Retry-After:1 + X-Cilex-Mosaic-State: rendering` → `200`, including one transient `state=error` that self-healed — exactly your note. **At 16 inputs that transient does not self-heal — it loops.**

**Root-cause candidates (for your investigation):**
1. **Empty cells don't black-fill beyond 2×2.** Your "3 cams in a 2×2 → 4th cell black, `200`" path doesn't scale: at 3×3 with one populated cell we get `410` (the populated cell is dropped), and at 4×4 the `Parsed_scale_N` filtergraph init fails and loops.
2. **The `Parsed_scale_N` failure you called "transient/self-healing" is persistent at 16 inputs** — never recovers within (or beyond) the retry budget.
3. **Live-edge clipping** — even the known-good 4 cams return `410` on a live window (19:30–19:50Z, well inside their `19:12→20:00Z` coverage). Finalization lag at the live edge may be clipping reviewable footage.

**Why our fleet triggers this and your test didn't:** the fleet grew **4 → 31 cameras**; the 27 newer cams only have footage from **after ~19:11Z today** (post the 42 h disk-down gap), so on any historical day the 16-cam wall is dominated by empty cells. This heterogeneity (deep-history cams + brand-new cams + a 42 h hole) is the realistic production condition — and it's what breaks E1. I couldn't construct a clean fully-populated ≥3×3 *historical* window from this data to test grid-size in isolation, but the operator-facing result is unambiguous: **the 16-cam wall does not come up.**

## 4. Client fixes shipped this pass

- **`tz` on coverage** (both calls) — calendar buckets in the operator's local day. `PlaybackClient.cpp`.
- **Wall render watchdog** — the proxy honors `Retry-After` for ~12 s, but on a never-completing render the HLS player re-requests forever (resetting the budget) → endless "Compositing…". Past the budget we now show an honest *"Couldn't composite the synchronized grid for this window — the server didn't return frames in time. Try a different time, or Return to live."* and drop the dead grid overlay. `WallPlayback.qml`. (This honors the file's own contract: *never a broken player*.)

Both built clean, offscreen-smoke clean, screenshot-verified on the iGPU. Single-camera `/review` and the calendar are unaffected.

## 5. What I need next (the real blocker — supersedes E2)

The previously-queued **E2 + I7 + A6** (combined-grid export + grouping) is **moot until E1 actually plays at 16 cells** — there's no point exporting a grid that won't composite. So the next ask, which I'll track as its own dated letter, is:

**Fix E1 at operator scale** — make `/review/mosaic-sessions` composite robustly when (a) the grid is ≥ 3×3, and (b) some/most cells have no footage in the window (black-fill them, don't drop to `410` or loop). Re-verify against the **real fleet's footage distribution** (the 4→31 growth + 42 h gap is the test case), not a hand-picked all-footage 2×2. The `Parsed_scale_N` hardening you mentioned is part of this, but it needs to be proven at 16 inputs, not assumed transient.

Happy to pair on a repro session — I can hand you exact `camera_ids` + windows for each row of the §3 matrix. Once a 16-cam wall plays end-to-end on a historical day, I'll flip it on for operators, re-run this checklist, and *then* we pick up E2.

Thanks — coverage is genuinely great, and the cold-scrub mechanism is sound; it's just the at-scale composite that isn't there yet.

— Watchtower
