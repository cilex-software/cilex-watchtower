# Labs API error contract, enumerated from source

**Generated 2026-09-23 by parsing `cilex-vision/services/query-api/routers/labs.py`
with `ast`, not by grepping it.** Regenerate the same way; do not hand-edit.

## Why this file exists

The Labs error contract has now been stated wrongly three times in one evening, by
two systems, and every one of those errors was **grep-shaped**:

- cilex-vision's register said "unleased segment 403" — correct.
- They then "corrected" it to *no 403 exists*, because `grep 'CodedError(40[0-9]'`
  cannot match a call whose status code sits on the next line. Every multi-line
  raise in that module was invisible to it.
- **This box verified that correction against their source and confirmed it** — using
  `grep -E 'status_code=40[349]|HTTPException\(40[349]'`, which has the identical
  blind spot. Checking someone's claim with the same method that produced it is not
  a check.

A worker built on the middle version would have treated a **dead lease** as a hard
failure. The antidote is to parse the module rather than search it, which is what
produced the table below.

## The full table

33 `CodedError` raises, 7 distinct status codes.

| route / helper | code | detail | meaning for a worker |
|---|---|---|---|
| any station route | 401 | `station_token_not_recognised` | credential is not a per-station token |
| `_require_analyzer` | 404 | `unknown_analyzer` | stop |
| `_require_analyzer` | **409** | **`analyzer_disabled`** | **STOP — do not re-claim** |
| `_lease_for` (list) | 404 | `scan_unit_not_claimed` | never claimed — claim first |
| `_lease_for` (list) | **409** | `scan_unit_held_by_another_station` | **re-claim** |
| `_lease_for` (list) | **409** | `scan_unit_not_open` | **re-claim** |
| `list_segments` | 422 | `unknown_stream_type` | must be `main` or `sub` |
| `fetch_segment` | **403** | **`segment_outside_lease`** | lease died mid-hour — stop fetching, re-claim |
| `fetch_segment` | 404 | `segment_not_found` | not in that camera-hour |
| `fetch_segment` | **503** | `object_storage_unavailable` | **RETRYABLE — wait, do not abandon the unit** |
| `submit_results` | 400 | `hour_not_aligned` | hour_start must be on the hour |
| `submit_results` | 404 | `scan_unit_not_claimed` | lease gone |
| `submit_results` | 409 | `scan_unit_held_by_another_station` | lease stolen |
| `submit_results` | 422 | `too_many_observations` · `unknown_object_class` · `unknown_shape_class` · `shape_without_confidence` · `class_without_confidence` · `unknown_scene_light` · `observation_ends_before_it_starts` · `observation_outside_claimed_hour` | malformed payload |
| `_clean_metrics` | 422 | `metrics_not_an_object` · `too_many_metrics` · `bad_metric_key` · `metric_value_too_long` · `metric_value_not_scalar` | malformed `metrics` |
| `list_observations` / `list_events` | 403 | `camera_not_in_scope` | operator read paths; a worker never calls these |

## The two traps

**1. The two footage calls refuse differently.** The *list* call resolves the lease and
answers 404/409. The *byte fetch* re-checks it and answers **403**. A worker needs both
branches; they are not interchangeable.

**2. `409` means three unrelated things, and one of them is fatal.**
`scan_unit_held_by_another_station` and `scan_unit_not_open` both mean *re-claim*.
`analyzer_disabled` means *the operator switched this analyser off* — and a worker that
branches on the status code alone will **re-claim for ever against a disabled analyser**.
Branch on the `detail` slug. Never on the status code, and never on the prose.
