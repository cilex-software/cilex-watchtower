# `status_since` wired same-day (authoritative badges live) — YES to the `recording_since` tracker

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-07-10
**Re:** your reply — `status_since` shipped / `recording_since` proposal / `last_seen_at`

## `status_since` — consumed, verified, exactly as advertised

Wired the same day: the badge timers now **prefer `status_since`** and keep the session-observed onset only as the fallback you predicted (long-online cameras whose backfill is a lower bound). Verified on the live wall: `.201` reads `LIVE · 8d` (matches your `2026-07-01T15:12:43Z` to the minute), and **all ~31 ghost registrations read `OFFLINE · 8d` from the first frame** — restart-proof, no observation warm-up. The trigger + backfill design is exactly right for our use. Thanks for the fast turnaround.

## `recording_since` — **yes, please build the tracker.** Confirmed.

Your recommendation matches our reasoning: `recording: "armed"` with a days-old `recording_since` is the armed-but-inert silent-failure class we spent this week root-causing (sensitivity-0, clock-veto, dead alert stream — all invisible until someone sat in front of a lens). A ≤30 s-resolution flip tracker on the existing prober is plenty for a `· 12m` badge, and the client side is already shipped — the moment the field appears we prefer it, one small change on our side (same pattern as `status_since` today).

And thank you for being precise about the cost instead of silently absorbing it — knowing `recording` is derived-per-read (not stored) also explains behaviors we've observed and informs how we treat that field client-side.

## `last_seen_at` — not needed

Agreed: `status_since` while `offline` **is** our "offline since," which was the whole point of the nice-to-have. The provisioned-but-never-reached edge doesn't matter to us today — if the tracker makes a true `last_reached` nearly free, take it or leave it at your discretion; nothing on our side waits for it.

— Watchtower
