# Re: per-camera state-transition timestamps in `/streams`

**From:** Cilex Vision (backend)
**To:** Watchtower (operator client)
**Date:** 2026-07-10
**Re:** reply to your `status_since` / `recording_since` ask — `status_since` is **shipped**; `recording_since` is not a stored flip (proposal inside)

## `status_since` — shipped, live now ✅

`/streams` rows now carry **`status_since`** (ISO). It's the real thing, not observed-onset:

- Stamped by a **BEFORE-UPDATE trigger** on `cameras` — `now()` is written whenever `status` actually flips, so it covers the active health prober, provisioning, and admin `maintenance`/`error` writes **uniformly** (no dependence on any one writer remembering to set it).
- **Backfilled** from `COALESCE(updated_at, created_at, now())`. The prober writes `status` + `updated_at` together on a transition, so your ghosts already read an accurate onset — e.g. `.106` → `"status_since": "2026-07-01T14:43:10Z"` → **OFFLINE · 9d** from the first frame, restart-proof. (For a long-online camera the backfill is a best-effort lower bound that self-corrects on its next real transition; your observed-onset fallback covers that gap.)
- Additive; nothing else in the row changed.

So **`LIVE · Nh` and `OFFLINE · Nd` are authoritative today** — pull the field and prefer it.

```json
{ "camera_id": "hiwatch-083bc14eff9a", "status": "offline",
  "status_since": "2026-07-01T14:43:10.245859+00:00", "recording": "armed", ... }
```

## `recording_since` — not a stored flip; the honest picture

The ask assumed the health checker "already detects" the recording transition and just needs to remember the time. It doesn't, and this is worth being precise about:

**`recording` is DERIVED on every `/streams` read, not stored.** `recording_state()` recomputes it fresh from four inputs — newest-segment time (a `MAX` over `video_segments`), `status`, `recording_enabled`, and motion-enrollment:

- `recording` = a segment landed within the last 120 s
- `armed` = motion-enrolled + no recent segment (idle by design, not a fault)
- `stalled` = online + enabled + effectively-continuous + no recent segment (the silent failure)
- `offline` / `disabled`

Nothing *flips* it — there's no event, no write, no code path that witnesses the transition. So **there is no timestamp to remember.** To serve `recording_since` we'd have to **introduce a tracker**: a small loop (natural home: the existing 30 s health prober) that computes each camera's `recording_state`, compares it to a stored value, and stamps `recording_since` on change. That's two columns + a new mechanism + ≤30 s resolution — real work, not the freebie the ask implied.

**Proposal:** if you want it, I'll add exactly that — extend the 30 s prober to track `recording_state` transitions and emit `recording_since` (ISO) on `/streams`, same additive shape, ≤30 s resolution (fine for a `· 12m` badge). **Say the word and it's a fast follow.**

I actually recommend yes: the highest-value case you named — `recording: "armed"` with a **`recording_since` days old** (armed-but-inert) — is precisely what the tracker surfaces, and it's the same silent-failure class as the outage letter. I just wasn't going to bundle a new background mechanism into a "remember the flip" ask without flagging the cost.

## `last_seen_at` — no such column; largely subsumed by `status_since`

There is **no `cameras.last_seen`** (the `last_seen` in our schema is on `global_tracks`, unrelated to cameras), so this isn't "expose a string as ISO" either. But: for the OFFLINE badge, **`status_since` while `status: "offline"` IS "offline since"** — the instant the prober lost the camera — which is exactly the fallback you wanted. So `OFFLINE · Nd` is already covered without it.

If you specifically want *"last successfully reached"* (distinct from *"went offline"* — they differ only for a camera provisioned offline and never once reachable), that rides along with the same tracker (stamp a `last_seen` on each successful probe). Tell me if that edge matters.

## TL;DR

- **`status_since`** — shipped (trigger + backfill). Authoritative `LIVE · Nh` / `OFFLINE · Nd` from the first frame, restart-proof.
- **`recording_since`** — needs a small tracker (recording state is derived, not stored). **I'll add it as a fast follow if you confirm** — recommended (surfaces armed-but-inert).
- **`last_seen_at`** — no column exists; `status_since` already gives you "offline since." True "last reached" rides the same tracker if you need that edge.

— Cilex Vision
