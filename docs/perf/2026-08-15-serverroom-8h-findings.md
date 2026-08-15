# Overnight server-side run, 2026-08-15 01:30–09:30 UTC+3 — cold opens are 8× FASTER than warm

n = 960 samples, 30 s cadence, 0 errors, 0 stderr. Raw: `2026-08-15-serverroom-8h.jsonl`.
Method: `docs/letters/2026-08-15-paired-reconnect-protocol.md`.

## 1. The assumption we were both working from is wrong

| path | n | median | p25 | p75 | p95 | max |
|---|---|---|---|---|---|---|
| **warm** (producer already connected) | 2876 | **1.83 s** | 1.58 | 2.59 | 2.97 | 3.65 |
| **cold** (no consumer, no producer — fresh RTSP open) | 960 | **0.22 s** | 0.17 | 0.35 | 3.08 | 5.00 |

**A cold open is ~8× faster than reading a warm stream**, sustained over eight
hours and 3836 probes. Zero cold samples were NA — an idle stream always existed.

Connection *establishment* is therefore not the expensive path, and "cameras
waiting for connection" is not a cold-start story. What is slow is fetching a
frame from a stream that **already has consumers**: the three warm probes are
pinned to heavily-consumed streams (peak 64 consumers from a single source),
the cold ones are idle by construction. **Contention on consumed streams, not
setup cost.**

Cold p95 (3.08 s) and max (5.00 s) show the tail still exists — some cold opens
are genuinely slow — but the median case is not where the time goes.

## 2. Continuous consumer churn — real, but the cause is NOT established

Every one of 959 comparable samples showed consumer churn:

- detach events: **3944** total
- attach events: **3943** total
- samples with >0 detach: **959 / 959**

~8 attach+detach pairs per minute, all night, against a quiet fleet.

**What this does NOT prove.** The near-exact balance (3944 vs 3943) is the
signature of short-lived consumers cycling, which is equally consistent with
**periodic snapshot/thumbnail fetches** — each fetch attaches and detaches — as
with stream reconnects. My probe records per-stream consumer *counts*, and a
count delta cannot distinguish "a stream dropped and came back" from "a poller
took one frame".

**Fix for the next iteration:** track consumer **ids** rather than counts, so
consumer *lifetime* is measurable. A reconnect is a long-lived consumer that
died; a snapshot poll is a sub-second one. Until then this number is churn, not
reconnects, and must not be quoted as reconnects.

## 3. Host during the window

swap **12.1 → 13.7 GB** (still climbing overnight), `io full avg60` median
0.67 % / max 8.42 %. Quieter than the evening run, and the warm/cold gap
persisted throughout — so the 1.83 s warm median is not simply load.

## 4. Consumers by source

Peak concurrent consumers: `192.168.1.79` 64 · `10.0.0.1` 26 · `10.0.0.10` 7.
**No booth address appeared** in any of the 960 samples, so the booth wall was
either not running overnight or reaches go2rtc via an address not yet
identified. The paired cross-check in the protocol needs the booth's source IP
before it can attribute anything.
