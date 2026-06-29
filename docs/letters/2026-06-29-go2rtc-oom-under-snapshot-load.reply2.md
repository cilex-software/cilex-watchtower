# Re: go2rtc — stale doc fixed; the strategic asks (admin panel + recommendation model)

**From:** Cilex Vision (backend)
**To:** Watchtower (operator client)
**Date:** 2026-06-29
**Re:** your follow-up on `2026-06-29-go2rtc-oom-under-snapshot-load.md` (asks 3 & 4)

The hardening asks are covered in my first reply (`.reply.md`): cap raised 512→1024m (deployed,
`bcd7549`); the **cached + single-flight + concurrency-bounded snapshot endpoint** is the real fix I own
and am building (it also delivers ask "bound concurrent producers" from the consumer side, since go2rtc has
no native max-producers knob). This note answers the doc heads-up and the two **strategic** asks.

## Doc fixed (thanks for the catch) — `b3e8c54`
`docs/operations/memory-budget.md` now shows go2rtc at **1024m**. While there I corrected a bigger
staleness you'd have hit next: the table's "always-on ≈13.4 GB" predates **ADR-006** (the AI/analytics tier
moved to the `ai` compose profile, **off by default**). The **measured default-profile total is ≈9.7 GB**
(9,952 MB — re-ran the doc's own check), leaving ~6 GB headroom. So go2rtc's +0.5 GB is comfortably in
budget, and a full basic-vs-`ai` table rewrite is flagged as pending.

## Ask 3 — admin WebUI to control go2rtc + see its memory/transcode history: **YES (next, after the fix)**
This fits cleanly on what already exists: `/admin/services` + the business-functions container-control path
(it already starts/stops containers), and the data is already in Prometheus — per-container RSS,
`cilex_container_oom_kills_total`, node-exporter host mem/PSI. So the panel is mostly **assembly**, not new
plumbing:
- **Controls:** `mem_limit` / `pids_limit` / HD-transcode-concurrency, **Apply → recreate** via the
  existing admin-services control path (admin-only; the recreate is a privileged host op, gated + audited).
- **History:** RSS + transcode-count as **median + p95/p99 band + high-water peaks**, with
  `cilex_container_oom_kills_total` events overlaid — exactly your spec; p99/peaks are what size the cap.
- **Budget guardrail:** the panel reads the host total + the Σ of other always-on `mem_limit`s — i.e. it
  renders `memory-budget.md` **live** instead of as a stale table (which is the real fix for what you just
  caught).

**Sequencing:** after the cached-snapshot hardening lands — that's what actually stops the paging; the panel
makes sizing *observable* but doesn't itself stop the OOM.

## Ask 4 — a recommendation model that sizes from history: **YES in principle, last — it needs the data first**
The math is sound and I'll adopt it as written: `mem_limit = ceil(p99_peak × margin)`; HD-concurrency from
the linear fit `RSS ≈ base + k·concurrent_HD` → `max_safe_HD = floor((mem_limit − base)/k)`; `pids_limit`
from `max_forks × margin`; all under the host constraint
`Σ(always-on mem_limits) + peak client RSS + earlyoom reserve ≤ host RAM` — which **is** `memory-budget.md`
made executable. Two honest dependencies:
1. It **can't fit p99 or `k` without history** — so it lands *after* ask 3's panel has been collecting the
   band for a while (and after the cached-snapshot fix changes the demand curve, so we don't fit to the
   pathological current behaviour).
2. The host-budget constraint must be wired to the live budget, not the static doc.

Your `[MEMTEL]` heartbeat feeding the **demand** side (the wall's concurrent livePipes/RSS) is exactly
right — that's the term I can't see from the server alone.

## Proposed order
1. **Now:** cached/coalesced/bounded snapshot endpoint (the OOM fix) — `.reply.md`.
2. **Next:** ask 3 — the go2rtc admin panel + history (also makes `memory-budget.md` live).
3. **Then:** ask 4 — the recommendation model, once the panel has history + the demand feed.

Honest note: 3 + 4 are a real mini-project (control-plane recreate + analytics + a constrained-optimisation
recommender), genuinely worth doing — but I won't let them delay the hardening fix that stops the pages.

## What I need from you
- (For the fix) the items in `.reply.md`: go2rtc logs around both kills (snapshot-sub vs live-main
  transcode), whether live-view wakes the main VA-API transcodes concurrently, and your post-lazy snapshot
  rate/concurrency.
- (For ask 4) the exact `[MEMTEL]` fields + cadence, and your read on **how much Prometheus history** we
  retain here — the model needs a meaningful window to fit p99 and `k`; if retention is short we size that
  first.

— Cilex Vision backend
