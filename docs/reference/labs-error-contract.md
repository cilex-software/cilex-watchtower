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

## SOURCE, NOT DEPLOYED — check before you probe

Everything here is parsed from `routers/labs.py` **in the repository**. As of
2026-09-23 the running `query-api` is an older image: `grep -c 'retryable=' ` returns
**0 inside the container against 30 in the repo**, confirmed here. So a live call will
not carry the flag until cilex-vision rebuilds, and finding it absent is a deploy gap,
not a disagreement. Their deploy is held deliberately — the host was reaping processes
for memory and they will not start a container build on a box that was just OOM-killed.

## SUPERSEDED 2026-09-23, same evening: branch on `retryable`

cilex-vision shipped a `retryable` boolean on every station-facing refusal in response
to the 409 finding below. **That is a better answer than the advice this file gave.**
Verified by AST: 21 station-facing raises, all carry it, all assigned correctly —

    analyzer_disabled                  409  retryable=False   <- stop
    scan_unit_held_by_another_station  409  retryable=True    <- re-claim
    scan_unit_not_open                 409  retryable=True    <- re-claim
    segment_outside_lease              403  retryable=True    <- re-claim
    object_storage_unavailable         503  retryable=True    <- wait
    station_token_not_recognised       401  retryable=False
    every submit_results 422           422  retryable=False

**A worker should branch on `retryable` and needs to know neither a slug nor a status
code.** The three raises without the flag are `camera_not_in_scope` (operator read
paths a worker never calls) and `nothing_to_update` (admin), so station coverage is
complete.

The table below stays because the slugs remain the right thing to LOG, and because the
reasoning that produced `retryable` is worth keeping visible.

## The two traps

**1. The two footage calls refuse differently.** The *list* call resolves the lease and
answers 404/409. The *byte fetch* re-checks it and answers **403**. A worker needs both
branches; they are not interchangeable.

**2. `409` means three unrelated things, and one of them is fatal.**
`scan_unit_held_by_another_station` and `scan_unit_not_open` both mean *re-claim*.
`analyzer_disabled` means *the operator switched this analyser off* — and a worker that
branches on the status code alone will **re-claim for ever against a disabled analyser**.
Branch on `retryable` (above). Log the `detail` slug. Never branch on the status code,
and never on the prose.

That progression is the point: the contract went prose -> status code -> slug ->
a boolean that states the only thing a worker actually needs. Each step was forced by
someone getting the previous one wrong.
