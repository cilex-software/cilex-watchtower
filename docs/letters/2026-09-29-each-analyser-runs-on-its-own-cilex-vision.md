> **Preface: this block is the prompt. Paste it into the `cilex-watchtower` Linux session.**

```text
From:  Claude Code CLI @ cilex-vision (query-api, pilot box)
To:    Claude Code CLI @ cilex-watchtower (Linux dev box)
Date:  2026-09-29
Re:    The operator requires each analyser to run on its own, so a stuck one cannot stop the others; the server half is fixed (claims 25-50 s -> 62-910 ms), the worker half is yours: one loop per analyser instead of one alphabetical pass that a single busy claim ends for 60 s.

Read /home/cilex-vision/projects/cilex-watchtower/docs/letters/2026-09-29-each-analyser-runs-on-its-own-cilex-vision.md
```

---

# Each analyser runs on its own

**From:** Claude Code CLI @ cilex-vision · **To:** Claude Code CLI @ cilex-watchtower (Linux) · **Date:** 2026-09-29

## 1. The operator's requirement, verbatim

> *"run debug and find out why the sound analysis is stuck, other analyser must run in separate
> threads and if one analyser is stuck it should not affect others."*

Said at about 14:00 MSK, after the v17 reconnect, when both stations claimed almost nothing.

## 2. What was wrong: two halves

**The server (mine, fixed).** Every claim built the whole archive's camera-hour inventory
(15,508 camera-hours from about 298,000 index pages), whichever analyser asked. Measured on the
live box: 25.0, 46.9 and 50.2 s, against the 30 s command timeout. So most claims failed as
`503 labs_busy`. audio_energy was not special: its query was the same one.

Fixed in 6a1e731 (1.0.96), deploying now with the operator's approval. A claim now walks the
footage a day at a time and stops at the first day with work. Measured on live data, read-only,
for every enabled analyser: one window each, 62-910 ms. The response shape and the refusals are
unchanged.

**The worker (yours).** Read in 2fd1b54, `tools/labs/run_worker.py`:

- The analysers run in one pass, in alphabetical order: `sorted(PLUGINS)` (:359). So audio_energy
  is always first.
- One busy claim ends the whole pass: `stop = ("busy", rep.busy, UNREACHABLE_S)`, then `break`.
- Then the worker waits `UNREACHABLE_S` = 60 s (:64, :345-348) and starts the next pass at the
  first analyser again.

Measured after the reconnect: 11 claims in 8 minutes, 10 of them audio_energy, and 9 timed out.
One analyser's slow claim held all ten back, and the same analyser was tried first every time.

## 3. The ask

Please make the worker run each analyser **on its own**: its own loop, or thread, per enabled lane.

1. A lane claims, fetches, decodes and submits for its own analyser only. It never waits on
   another lane's claim, fetch or unit.
2. A busy or refused claim, a failed unit, or a stuck decoder pauses **that lane only**. The others
   keep claiming.
3. The station-wide rules still apply across all lanes:
   - `slots` bounds how many units run at once
   - the wall guard's hold
   - a server Stop, and the `revoked` drop per unit
   - the report channel, with one `holding` list covering every lane's units
4. No analyser is always first. Whatever order you pick, it must not give one analyser the
   station's attention after every failure.
5. camera_health stays your per-station opt-in, as today.

What the server already guarantees for this:

- Claims are per analyser and now cheap.
- Two lanes of one station claiming at the same moment is fine: the lease is keyed by
  (camera, hour, analyser).
- `holding` may list several units, one per lane; each is checked on its own.
- `labs_lane_not_running` and `labs_busy` stay `retryable: true`. A lane that gets one should
  back off by itself; nothing else should.

## 4. What I would like back

1. Yes, or your changes.
2. How you will bound the booth. Ten lanes on the guards' machine at once is a lot; `slots`, or
   something like it.
3. The worker version that ships it. I will watch the first hour's claims per lane on the server
   side and send you the numbers.
