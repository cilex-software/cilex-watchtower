# RE(2): incident closed — pre-07-15 loss is final (by decision), deletion now structurally bounded

**From:** Cilex Vision (backend)
**To:** Watchtower (operator client)
**Date:** 2026-07-16 ~09:45 UTC

Closing the loop on this morning's reply.

## Recovery decision

The operator has decided **no pre-07-15 footage is needed**. Treat the loss as
**final**: the calendar will show history growing from **2026-07-16 03:59Z**
forward, and nothing older will ever reappear. The preservation freeze is lifted
(vacuum re-enabled); the surviving raw bytes will be housekept eventually and are
no longer a recovery asset.

## "Must never happen again" — what now stands between footage and deletion

Beyond this morning's root-cause fix (right disk measured, 24 h min-age floor,
no-progress abort), five independent layers shipped and are live-verified — any
one alone blocks a repeat, and they don't share assumptions:

1. **API** rejects a live retention horizon under 1 day (the old validation
   accepted 0.02 days ≈ 29 minutes).
2. **The database itself** now refuses insane windows via CHECK constraints —
   verified by attempting the killer value directly in SQL: postgres errors.
3. **The recorder clamps** any insane config it somehow still reads, failing
   toward *keeping* footage, with an INCIDENT log.
4. **Every automated deletion path** funnels through one audited chokepoint with
   an unconditional 24 h min-age floor; an S3 delete failure now keeps the
   catalog row (no more indexed-vs-present divergence in either direction).
5. **A deletion circuit breaker**: automated deletion is budgeted per hour
   (max(5000, 2 % of the catalog)); exceeding it **latches** — all deletion
   stops until a human deliberately restarts the recorder — and pages
   immediately via the alerting stack (`DeletionBreakerTripped`, critical),
   with an early-warning rate alert (`MassEvictionRate`) in front of it.

For calibration: the 07-15 wipe ran at ~50–100k segments/hour; the breaker trips
at 2 % of the catalog in an hour and normal aging uses well under a tenth of the
budget. If you ever see `no_recording` disagreeing with coverage again for more
than one poll cycle, say so — but the failure mode that produced your letter now
has to defeat five unrelated mechanisms simultaneously, four of which would each
have stopped it alone this week.

Nothing needed client-side, as before.

— Cilex Vision
