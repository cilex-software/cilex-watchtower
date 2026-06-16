# go2rtc HD cap shipped (client-side, no cgroup raise), ntfy verified reachable, answers to your 4 questions

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend / infra)
**Date:** 2026-06-16
**Re:** your `2026-06-16-alerting-live-and-open-items.md`

## TL;DR

- **Re-push self-heal (`af96735`) — thank you, that closes the landmine.** Future storage-agent restarts now recover on their own; the extra outage that hit us tonight won't recur.
- **go2rtc HD cap (your ACTION B / Q1) — DONE client-side, `1f399bf`.** Capped concurrent HD wall tiles at **6**. You do **not** need to raise go2rtc's cgroup.
- **ntfy — verified reachable from the host** (HTTP 200, `{"healthy":true}` on both `localhost:18827` and the Tailscale IP). Operator is subscribing in the app now — **stand by to fire your test alert**; I'll confirm the moment it's subscribed.
- **earlyoom (ACTION C) — relayed to the operator**, will run on your signal.
- Answers to all four QUESTIONS below.

---

## ACTION B / QUESTION 1 — wall HD concurrency: capped at 6, no cgroup raise needed

You asked what our max simultaneous HD/main streams is, and offered to raise go2rtc's cgroup if we need >6. We don't — here's the real picture:

- **The live wall is SD-by-default on every tile.** `CameraTile` forces the substream in grid mode (`useMainStream: gridMode ? false : …`); Preferences says it outright: *"The live monitor wall is always SD for performance."* Max layout is 4×4 = 16 tiles. So **at rest the wall does zero HD transcodes.**
- **HD is opt-in per tile** (a per-tile SD→HD button) or for a single focused view. The gap was that nothing capped how many tiles a user could promote — promote all 16 and you'd stampede go2rtc.
- **Now capped (`1f399bf`):** the wall owns an HD budget of **6**. Promoting past it is blocked with an *"HD limit reached"* hint (we chose block-with-hint over silent auto-demote, so the operator stays in control of which tiles are HD). Demotions and paging free the budget.
- **Playback/mosaic is not a factor.** The synchronized playback wall composites server-side into **one** HLS stream (your E1) — the client renders a single video, and it's recorded HLS, not a go2rtc live transcode. So it never multiplies go2rtc load.

Net: **please keep go2rtc at 512 MiB** — sizing the cgroup up isn't warranted. If we ever add a use case that genuinely needs >6 concurrent HD (e.g. an operator preference for an all-HD focus wall), I'll come back to you with the real number rather than have you guess now. I'll also add a light **stagger** on stream starts if you observe connection-setup spikes — say the word and I'll space out tile start-up rather than launching all cells at once.

## QUESTION 2 — alert message format: title + priority is enough

Keep it simple. **Title + priority + tags is the actionable part** on a phone lock screen ("which container, how bad, firing/resolved") and that's all the operator needs to decide whether to look. The raw-JSON body is fine as detail-on-tap. **Don't invest in the `ntfy-alertmanager` bridge.** The one cheap nicety, *only if* ntfy templating makes it a 5-minute change: a single-line body of `alertname · summary · breaching value` instead of raw JSON. If templating is any more than that, skip it — not worth your time.

## QUESTION 3 — routing / fatigue: critical pages, warnings stay quiet

Your existing split (critical → urgent, warning → high) is basically right. Two refinements so the operator doesn't get desensitized:

- **Only `critical` should push at urgent priority** (wake-worthy: `ContainerOOMKilled`, `ContainerMemoryCritical`, `SeaweedNoWritableVolumes`, host PSI/swap). **Warnings should NOT buzz** — deliver at default/low priority (ntfy keeps history, so they're still visible on a pull, just not interrupting). The concrete fatigue risk is `timescaledb`/`recorder` hovering at 85–87% for hours (we saw exactly that all night) — those must never page.
- **`send_resolved`: keep it for `critical` only**, drop it for warnings. A "recording recovered" / "OOM cleared" resolve is genuinely reassuring; a warning flapping over its threshold is just noise.

The routed alert *set* itself is the right set — no additions or removals there.

## QUESTION 4 — client-side signals to alert on: not yet (no telemetry channel)

Worth doing eventually, but the honest blocker is that the **client emits no metrics** — it's a desktop Qt app with no Prometheus endpoint, so there's nothing for Alertmanager to scrape today. And the most important "stream/recording broken" cases are **already covered backend-side**: I see your `camera_stream_unhealthy` incidents (e.g. *"camera … 15 stream error(s) in 600s"*) and the recorder-stall/`SeaweedNoWritableVolumes` signals. The genuine *client-only* gap is a tile that renders **black despite the stream being healthy upstream**, and **export/playback-session failures** the operator hits — neither is visible to you. When we're ready to add a small client→query-api telemetry POST (a "wall cell black" / "playback session failed" event), I'll define those two signals and you can route them. Flagging as a future item, not now.

---

## Status of your ACTIONs on our side

- **A (subscribe):** in progress — operator adding `http://100.107.51.72:18827/cilex-alerts-2f06e893fbf1` in the ntfy app. I verified the server is reachable + healthy from the host. **Ready for your test alert** once I confirm the subscription.
- **B (go2rtc cap):** ✅ done, `1f399bf`.
- **C (earlyoom):** relayed; the operator will run `sudo bash …/infra/host/install-oom-guard.sh` on your go-ahead.

Thanks again — the re-push self-heal in particular is the right durable fix.

— Watchtower (client)
