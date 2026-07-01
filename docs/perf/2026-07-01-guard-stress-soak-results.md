# Guard-usage ENDURANCE + STRESS soak — results (2026-06-30 23:57 → 2026-07-01 12:00, 12 h)

Rich `WT_GUARD_SOAK` harness on the wedge-fixed build (`42231e0`), hang-aware supervisor v2.

## Verdict: clean — no crash, no hang, no wedge, **no leak**
- **1 launch, 0 crashes, 0 hangs, 0 wedges** — `run #1 healthy` for the entire 12 h. 21,585 samples.
- **RSS: mean 618 MB, max 702 MB, trend +4.2 MB/hour ≈ flat.** Rises to ~620 MB in the first ~30 min then
  holds for 12 h. Well under the 5 GB RSS-shed valve (never fired).
- **CPU: mean 31 %, max 127 %** (multi-core during interaction bursts); steady sawtooth, no drift.

## Stress actually applied (from the [GUARD] action log — 2,612 actions, 104 full cycles)
| interaction | count | note |
|---|---|---|
| **camera replaces / swaps** | **~840** | `assignToCell` into random tiles — the historical swap-leak / OOM-under-swap-pressure path |
| **playback-wall re-arranges (swaps)** | **~1,040** | `swapSlots` → re-composites the mosaic |
| fullscreen open/close | 315 | `focusedCamera` |
| layout changes | 210 | 16 ↔ 4 ↔ 9 |
| event videos played | 416 | all 4 Events tabs; hero player → exercises the threaded HLS proxy |
| Live / Events / Wall / Groups-Views-Health | 244 / 275 / 104 / 99 min | grouped dwell |

## Reading it
- **The old camera-swap leak did not reappear.** ~840 replaces + ~1,040 wall-swaps over 12 h and RSS stayed
  flat (+4.2 MB/h) and bounded (≤702 MB). (For contrast, the earlier basic-nav re-run drifted +41 MB/h over
  5 h — that was the initial ramp to the ~600 MB working set, which this longer run shows then plateaus.)
- **RSS peaks (~700 MB) land on `live-fs-exit`** — returning from fullscreen rebuilds the whole wall (16
  pipelines) → transient peak. **CPU peaks on `live-replace` (72 %) and `live-fs-exit` (67 %)** — pipeline
  build/teardown churn. Both recover; no accumulation.
- **The playback-wall ↔ Live wedge fix held** through 104 wall opens + ~1,040 in-wall swaps.
- One cosmetic `GStreamer-CRITICAL` seqnum assertion recurs under rapid pipeline churn (fullscreen/layout/swap)
  — non-fatal, app unaffected. Worth a follow-up to silence, not a stability risk.

## Artifacts
- Graph: `docs/perf/2026-07-01-guard-stress-soak.png` (RSS + CPU over 12 h + first-25-min zoom).
- Raw: `/tmp/guard_test/` (samples.csv, app.log with every `[GUARD]` action, incidents.log).
- Tooling: `docs/perf/soak-tools/` (harness driver in `qml/Main.qml`, sampler, hang-aware supervisor, analyzer).
- Prior clean wedge-fix validation (basic nav, 5 h): `/tmp/guard_test_rerun_simple/`.
