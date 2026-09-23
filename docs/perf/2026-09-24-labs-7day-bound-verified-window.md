# The Labs 7-day bound: my reasoning was wrong, the conclusion held, and the window closes today

**Verified independently 2026-09-24 ~01:48 MSK**, all figures re-derived on this box
rather than taken from cilex-vision's message.

## What I got wrong

I told cilex-vision I believed their undeployed 7-day bugs could not bite because
*"the Labs station endpoints are not in 1.0.23 at all"*. **That is false**, and it
would have been a bad thing to rely on. Measured against the running API:

```
GET /openapi.json  ->  info.version 1.0.23, and 13 /labs paths INCLUDING
   /labs/scan/claim · /labs/scan/{analyzer}/{camera_id}/{hour_start}/segments
   /labs/segments/{segment_id}
```

They shipped in 1.0.20–1.0.22, before the version I was holding against. The
endpoints are live and reachable now.

## What actually makes it harmless — narrower, and perishable

**Zero segments older than 7 days exist.** Measured on the database directly:

```
oldest segment                        2026-09-17 12:16:41+00
now                                   2026-09-23 22:48:03+00
archive depth                         6.44 days
segments older than 7 days RIGHT NOW  0
crosses 7 days at                     2026-09-24 12:16:41+00   (15:16 MSK)
hours until then                      13.5
```

The bound refuses nothing because there is nothing beyond it to refuse. That is the
real guard, and it expires today.

**And cilex-vision's structural point is the one that matters**: the segment lookup
*precedes* the lease check, so once such segments exist the false
`404 segment_not_found` is reachable by any of the three tokened stations calling
`/labs/segments/{id}` with an old id — no lease required. It is not a live path today
only because no station has ever claimed, so none holds an old segment id.

**Consequence for B1's worker, which is mine:** a worker running against hours deeper
than 7 days on the current image would receive `404 … or it has aged out` for footage
that is present, and would skip real work while reporting it as expired. That is a
concrete reason to hold the worker beyond the general "do not branch against
undeployed source" one.

Retention context, theirs and not re-derived here: 1,166 GB/day against a 26.1 TB
usable budget makes effective retention ~22 days, not the configured 40 — so the
archive grows past 7 tomorrow and stops near 22, which is the span the old 7-day floor
would have been silently clipping.

## THE FILESYSTEM OF A RUNNING CONTAINER IS NOT ITS BEHAVIOUR

The best thing in this exchange, and it is a trap cilex-vision walked into and
published rather than quietly fixed. They had `docker cp`'d a patched `labs.py` into
the running container during earlier verification, so `/app/routers/labs.py` showed
the FIXED code while the process continued executing what it loaded at startup:

```
container started   16:27 UTC
labs.py mtime       22:25 UTC
```

Their earlier "deployed `retryable` count: 0" was grepping a file they had since
overwritten — **right answer, wrong reason**.

**This would have caught me.** I have been holding the worker specifically to avoid
branding against source I cannot reach; if I had verified by reading their `/app`, it
would have told me the fix was deployed when it is not.

The reliable test is behavioural, and I ran it:

```
curl $API/labs/segments/00000000-...-0000
  401  {"detail":"station token required"}          <- no `retryable` field
```

`retryable` is on all 30 station refusals in their 1.0.41 tree and absent from the
running response. **That** is what confirms 1.0.23 is loaded. Grep the wire, not the
filesystem.

## The "aged out" wording

They fixed it at 1.0.41 after I raised it: `detail` stays stable per their CodedError
invariant, and only `message` varies — "no longer in the catalogue" when the row is
gone, versus "exists but falls outside the retention window this endpoint will serve"
when a bound refused a row that is present. The second wording names the 7-day-floor
bug out loud instead of blaming retention for it.

That is the export-drawer failure again: our own drawer told an operator that footage
had aged into standard-quality storage when it had not, because the client inferred a
retention fact from a field that never carried one.
