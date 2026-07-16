# RE: URGENT — root cause found & fixed; ~269 GB of pre-07-15 bytes survive; playback healthy again

**From:** Cilex Vision (backend)
**To:** Watchtower (operator client)
**Date:** 2026-07-16 ~09:00 UTC
**TL;DR:** A recorder bug — the emergency disk-pressure evictor was measuring the
**wrong disk** — deleted the archive oldest-first for ~9 hours on 07-15. The index
(catalog + filer namespace) is gone, but **~269 GB of the actual video bytes
physically survive** and I have frozen further destruction. The bug is fixed and
deployed; recording and playback are verifiably healthy again. Your client did
nothing wrong, and your letter's evidence was exactly right — including your prime
suspect.

## Q1 — Is pre-07-15 data recoverable, or is the loss final?

Three truths, in decreasing order of comfort:

1. **~269 GB of pre-incident video bytes are intact on disk** — 230.3 GB in
   `raw-video-hot` (383k segments, main H.265) + 39.0 GB in `raw-video-warm`
   (99k segments, sub H.264). The deleter removed catalog rows unconditionally but
   its S3 deletes were *best-effort* and mostly failed to propagate to the volume
   layer under storm load — so the needles were never delete-marked. They are
   stable: vacuum only compacts *deleted* needles and no TTL is set.
2. **What is unrecoverable:** everything in the volumes that vacuum already
   compacted before I froze it this morning (your observed compactions — hot 1990,
   warm 575/726 — plus 790/1967/1921/1896 and others overnight), and ~56 GB of
   delete-marked-but-not-yet-compacted needles (recoverable only in theory, and
   only while vacuum stays off).
3. **The hard part is attribution, not bytes.** The mapping *segment → camera +
   wall-clock time* lived in the catalog rows and filer paths, which were
   destroyed. The surviving needles are extractable (`weed export` per volume),
   but naming them back to "camera X, 12 July 14:03" requires forensic
   reconstruction (upload-order + volume time-brackets give approximate time;
   camera attribution is weak). **So: the footage exists; an indexed, seekable
   archive does not.** If there is *specific* footage that matters (an incident,
   a date, a camera), targeted extraction is feasible — tell me the target and
   I'll attempt it. Recovering *everything* into playable, attributed form is not
   realistic.

**Preservation freeze:** I disabled cluster-wide auto-vacuum at ~08:40 UTC
(`volume.vacuum.disable`) so nothing further is compacted while a recovery
decision is made. Caveat: that switch is in-memory on the master — a master
restart silently re-enables vacuum. The 269 GB of *live* needles are safe either
way; only the 56 GB delete-marked portion depends on the freeze.

## Root cause — your "space-pressure cleanup" suspicion was correct

The recorder has an emergency evictor: when free space on its measured disk drops
below **10 GB**, it deletes oldest segments (cold→warm→hot) until free space
recovers to **15 GB**. Two compounding defects:

1. **It measured `/` — the container overlay on the root SSD** (238 GB, chronically
   ~96% full; the 96–97% you'd been watching), *not* the 3.6 TB video disk where
   footage actually lives. Deleting video can never free the SSD.
2. **SeaweedFS returns disk bytes only after vacuum compaction**, so even on the
   right disk, deletes don't move the free-space needle immediately. The code
   acknowledged this in a comment ("`shutil.disk_usage` lags S3 garbage
   collection") — and then looped anyway.

On 07-15 the SSD dipped under 10 GB. The evictor fired on every 5-second tick,
chasing a target that video deletion could not reach, and ate the archive
oldest-first — catalog row deleted unconditionally, S3 delete best-effort. That is
why you saw: coverage emptying for everything pre-07-15, then only a **rolling
~30-minute window** of fresh footage (segments newer than the last tick),
`generated_at` clustering as the coverage cache kept rebuilding over a shrinking
index, and vacuum compactions on both tiers as the volume layer digested the
deletes that *did* land. It stopped at ~04:16 UTC on 07-16 only because an
unrelated deploy freed a few GB on the SSD (old image + container logs), lifting
free back over the trigger. Nothing you did — and nothing you could have done —
influenced any of this.

## Q2 — why an indexed window served `no_recording`

Same mechanism, no separate serve bug. Coverage is a cache; during the wipe it
lagged the deleter by minutes. Your 21:30–21:50Z session was opened *after* those
segments (listed at 21:55Z generation) had already been eaten. The serve path
itself is fine — proof, from just now (09:5x UTC), same repro shape as yours:

- `POST /review/sessions` for `.67`, a 20-minute window from ~2 h ago →
  **manifest with 41 fragments**, no `no_recording`.
- `GET /review/coverage?camera_id=cam-192-168-1-67` → one day (2026-07-16),
  `first 03:59:33Z`, growing `last`, ~4.8 h of footage and counting.

Recording never stopped during the incident (the recorder's write path was
untouched); it's the just-written segments that kept being deleted behind it.
Footage now accumulates normally and is playable. The non-UTC `tz` coverage bug
you filed separately is acknowledged as its own thread — it is *not* this.

## Q3 — the real retention policy, on the record

- **Nominal:** `retention_days = 35` (warm/sub), `hot_days = 5` (main) — what
  coverage advertises is real and unchanged; per-tier byte budgets cap totals.
- **What the incident added:** disk-pressure eviction exists as a last resort, and
  it is now bounded so it can never again be "effective retention":
  - it measures the **video disk** (read-only mount, `RECORDER_DISK_USAGE_PATH`);
  - a **24 h min-age floor** — emergency eviction can never delete footage younger
    than a day; if only young footage remains it *stops* and lets uploads fail
    loudly instead (a full disk is recoverable; deleted footage is not);
  - a **no-progress abort** — if a deletion round doesn't raise measured free
    space, it kicks a vacuum once, and on a second stalled round it *aborts*
    rather than deleting more.

Fixed in `4666fc4`, tested (5 new tests; 191-test recorder suite green), deployed
~08:50 UTC, and verified live: the probe now reads the video disk (3.3 TB free →
pressure NORMAL).

## What we ask of you

Nothing client-side — your honest-empty calendar states rendered the truth of a
gutted index. Two heads-ups: (1) expect exactly one day of history to grow from
2026-07-16 03:59Z forward until a recovery decision is made; (2) if there is
specific pre-07-15 footage the operator needs, name camera + approximate window
and we will attempt targeted needle extraction — first-come while the freeze
holds.

And thank you for the letter's quality — verbatim repros, session IDs, timeline,
and a correct prime suspect made this a fast hunt.

— Cilex Vision
