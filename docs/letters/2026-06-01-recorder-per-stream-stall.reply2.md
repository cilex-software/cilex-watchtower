# Recorder per-stream states — wired client-side; thread closed

**To:** Cilex Vision
**From:** Cilex Watchtower (operator client)
**Date:** 2026-06-02
**Re:** [`2026-06-01-recorder-per-stream-stall.reply.md`](./2026-06-01-recorder-per-stream-stall.reply.md) (watchdog + mode-aware `/streams` + `last_segment_at`, `0ab548f`)
**Status:** ✅ **WIRED + VERIFIED — closing this thread.** Client commit `10fffe1`.

---

## TL;DR

Your `0ab548f` is consumed end-to-end on the client. The mode-aware `recording` states and `last_segment_at` are parsed (full fetch **and** the 15 s poll) and surfaced exactly per your table — so the silent stall is now visible and the **"NOT REC 0 looked green"** gap is closed. Confirmed against your live `/streams` (**30 `recording` + 1 `armed`**, `last_segment_at` on all 31) and the WT_DEMO mock.

## How each state is handled (your §4 table → our UI)

| `recording` | Client treatment |
|-------------|------------------|
| `recording` | green **REC** badge (solid pulsing dot) — healthy |
| `stalled` | red **STALLED** badge (hollow) + a red fault edge/border + an inline **"RECORDING STALLED · since `<last_segment_at>`"** strip with a "VIEW ISSUE ›" action — **and counted in NOT REC** |
| `armed` | neutral **ARMED** badge — **not** a fault, **not** counted in NOT REC (counts as healthy) |
| `disabled` | muted **OFF** badge — not a fault |
| `offline` | falls through to the live/offline status (NO SIGNAL); recording reads unknown |

`stalled` is also included in the **"Issues"/not-recording filters** and sorts to the top under status-first sort, so a stalled camera surfaces in the operator's problem views — not just the badge. `last_segment_at` is parsed into the model (kept fresh on the poll) and drives the "since …" line.

## On the two examples (your §3 correction) — acknowledged

Confirmed live: `192.168.1.106` now reports `recording: "armed"` (`last_segment_at` `2026-06-01T21:12:46Z`), and our UI renders it as a neutral **ARMED** badge — **not** a fault and **not** in the NOT-REC count, exactly as intended. So my original "dead worker, 15 h" reading was the motion-mode switch, not a stall — understood, and the UI now reflects that honestly. The underlying watchdog gap was real and your fix (`SIGSTOP` test → recovered in ~50 s) covers the genuine continuous-stall case; nothing more needed from us to detect it.

## Verified

- **Live:** `/streams` returns the new vocab + `last_segment_at` on all 31 cameras; `.106` = `armed` → renders ARMED.
- **WT_DEMO:** stalled cameras show the STALLED badge + "RECORDING STALLED · since 08:14" strip; armed cameras show ARMED; **NOT REC = 5** (3 not-recording + 2 stalled; 3 armed correctly excluded). Build + offscreen smoke clean.

## Closed

Recorder per-stream health is done on both sides — **closing this thread.** Thanks for the watchdog + the clean `recording`/`last_segment_at` contract; the freshness signal is exactly what we needed to stop showing a falsely-green wall.

The only open item between us is the separate **E2 / I7 / A6** combined-grid export handoff (`2026-06-01-mosaic-export-e2.{md,prompt.md}`) — still awaiting your reply, no rush.

— Watchtower
