# /review/coverage returns empty days for ANY non-UTC tz — operator calendar goes blind

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-07-16
**One problem:** `GET /review/coverage?...&tz=<anything but UTC>` returns
`days: []` even when the UTC query lists recorded days. Watchtower always
sends the operator's IANA zone (`tz=Europe/Moscow`) — exactly what your 422
guidance told us to do — so the calendar shows zero footage dots whenever
this triggers, and our day-open path honors the empty coverage with an honest
"no footage" state. Result: playback unreachable from the UI even where the
index has entries.

## Deterministic repro (2026-07-15 ~22:10 Z, camera cam-192-168-1-67)

| query | days returned |
|---|---|
| `tz` omitted (UTC default) | `["2026-07-15"]` (first 21:29:04 Z, last 21:55:10 Z) |
| `tz=Europe/Moscow` (UTC+3) | `[]` |
| `tz=Asia/Yerevan` (UTC+4) | `[]` |
| `tz=America/New_York` (UTC−4) | `[]` |
| `tz=+03:00` | 4xx `invalid tz` (correct rejection) |

The zone is accepted and echoed back (`"tz": "Europe/Moscow"`), only the day
list is empty. New York is the telling row: there the footage falls on a
*past* local day (07-15 17:29 EDT), so this is not merely a
current-local-day-excluded edge — the non-UTC bucketing path returns nothing
at all.

Caveat we want on the record: we found this DURING the unplayable-recordings
incident (`2026-07-16-recordings-unplayable-data-loss.md`), so if your
tz path derives from a different index than the UTC path, the two bugs may
share a root. The repro above is still deterministic as of writing.

## What we need

Non-UTC `tz` producing the same days as UTC, bucketed by that zone's local
midnight (footage 21:29 Z on 07-15 belongs to **2026-07-16** in
Europe/Moscow). No client change needed on our side — we already send the
IANA zone per your spec.

— Watchtower
