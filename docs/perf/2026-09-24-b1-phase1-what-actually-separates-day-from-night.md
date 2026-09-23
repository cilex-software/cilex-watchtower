# B1 phase 1 — mean luminance does not work, and chroma does not mean what we assumed

**Measured 2026-09-24** on the pilot fleet, read-only from the SeaweedFS filer. No
Labs endpoint called, no scan unit claimed, nothing written to the backend.
Scripts: `tools/studies/b1_signal_separation.py`, `tools/studies/b1_diurnal_profile.py`,
`tools/studies/b1_byte_step_census.py`. All re-run.

cilex-vision's B1 brief proposed **"mean luminance plus colour-saturation collapse"**.
Phase 1 tested that before building on it. **One half is falsified, the other half is
real but does not mean what the brief assumed.**

## 1. Mean luminance is not a usable discriminant — falsified twice

The design brief predicted this and gave the reason: auto-exposure raises gain until
mean Y returns toward its target, so mean Y is roughly invariant to ambient light.

| test | result |
|---|---|
| 12 continuous cameras, 13:00 vs 02:00 MSK | day 107.0 vs night 103.1, **\|d\| = 0.49** |
| `hiwatch-849459c4f13d`, all 24 hours | range 71.2–80.5, **spread 1.1×**, r = +0.42 vs bytes |
| `hiwatch-04eecdd45e2d`, all 24 hours | range 79.7–120.5, **spread 1.5×**, r = −0.56 vs bytes |

A full day/night cycle moves mean luma by 10–50 %, against a between-camera spread
that is larger. **A fleet-wide threshold on mean Y is the A2 mistake with a different
variable** — it would work on whatever footage tuned it and fail elsewhere.

## 2. Chroma collapse detects `ir` essentially perfectly — and needs no threshold

`hiwatch-04eecdd45e2d`, one main segment per hour, 3 keyframes each:

```
 hr   MB   meanY  chroma        hr   MB   meanY  chroma
  0  7.47   79.7    0.00        12  2.46  120.5   11.32
  1  7.45  109.1    0.00        13  2.03  117.0   11.79
  ...                           ...
  5  6.51  108.4    0.00        18  1.77  107.5   10.59
  6  1.99  107.6   10.68   <--  19  6.55  113.7    0.00   <--
```

**Exactly `0.00` for hours 19–05 and 9–15 for hours 06–18.** Not "low" — zero. The
IR-cut filter is a mechanical swing, so with it closed there is no chroma information
in the frame at all. r = −0.939 against the byte curve, and the transitions land on
06 and 19, which is where the byte census independently put them.

**This is the one place in B1 that needs no tuned constant**, and it is the strongest
result in phase 1. `chroma == 0` is `ir`.

## 3. THE FINDING THAT CHANGES THE DESIGN: chroma polarity is camera-dependent

The brief's model is "saturation collapses at night". That is true only for cameras
that switch to IR. For one that does not:

`hiwatch-849459c4f13d`, same measurement, same day:

```
  night (00-05, 19-23)   chroma 8.1 - 8.7      <-- HIGHER at night
  day   (08-15)          chroma 4.3 - 4.8
  ir                     never; chroma is never 0
```

**Inverted.** This camera sits under coloured artificial light at night (sodium/LED),
so the scene is strongly chromatic in the dark; by day it is neutral light on grey
asphalt and concrete, which is close to achromatic.

So across the fleet, "low chroma" means **`ir` on one camera and `day` on another**.
A single fleet-wide chroma threshold for day/night would be **exactly backwards on a
substantial population**, and — this is the part that matters — it would look right
during tuning, because both cameras separate cleanly *on their own*.

This is the A2 failure shape caught before shipping: not a wrong measurement, a
constant that is correct on the population that produced it.

## 4. The noise-floor metric as implemented is degenerate — reported, not hidden

The third candidate was the 5th percentile of per-8×8-block standard deviation, as a
sensor-noise floor. On `hiwatch-849459c4f13d` it reads **0.00 for 23 of 24 hours**:
at least 5 % of blocks are perfectly flat, so the statistic saturates.

Its headline `r = +0.971` against bytes on that camera is therefore **a two-point
correlation** driven by one hour, and is not evidence of anything. Recorded because a
number that looks like the best result in the table is exactly the one that should be
labelled when it is an artefact. A higher percentile (p25) is the obvious repair and
is untested.

## 5. A sampling error of mine, since it nearly became the conclusion

Part 2 sampled "12 continuous cameras" and found almost no separation in **any**
signal, including chroma. That was true of the sample and false of the fleet: the
cameras were taken in `camera_id` order, not drawn from the population the byte
census says has a day/night signature at all. Cameras under constant artificial light
have no transition to find, and averaging them in flattened the cameras that do.

Caught by noticing that the one camera showing chroma collapse in part 2
(`hiwatch-04eecdd45e2d`) was also in the census's sharpest-step list — a coincidence
that should not have been one. **The population was never named in part 2, which is
the error this repo has now recorded five times in two days.**

## 6. What this means for the classifier

1. **`ir`: `chroma_energy == 0`.** Universal, physical, no tuned constant. Ship it.
2. **`day` / `night` on non-IR cameras: per-camera, and the POLARITY must be learned
   per camera, not assumed.** A camera's own chroma distribution is bimodal in both
   populations; which mode is "day" is what differs.
3. **Mean luma: drop it as a discriminant.** Keep it only as a diagnostic.
4. **Cameras with neither an IR transition nor a bimodal chroma distribution get
   `unknown`**, and the census says how many that is.

## 7. Cost, measured but NOT the figure cilex-vision asked for

```
part 2   24 segments   14.7 CPU-s
part 3   24 segments   14.1 CPU-s   (0.59 CPU-s/segment)
part 3   24 segments   18.1 CPU-s   (0.75 CPU-s/segment)
```

**This is not `cost_cpu_s_per_camera_hour` and must not be quoted as it.** It is
per-segment cost at 3 keyframes including the filer fetch, which the registry column
explicitly excludes. The camera-hour figure needs the sampling strategy fixed first,
because at `limit=2` the answer depends on how many keyframes each of the two
segments contributes. That measurement comes after the classifier design settles.

Observed ~0.6–0.75 CPU-s per segment at 3 keyframes. Two segments per camera-hour
would put the decode cost near **1.2–1.5 CPU-s/camera-hour**, which is in the region
the brief predicted — but it is an extrapolation from a different sampling shape and
is labelled as one.

---

# Part 4 — the polarity census, and a join bug that moved numbers on both sides

cilex-vision shipped `site_solar_times` (migration 0090) while part 3 was running, so
the ground truth stopped being a bitrate proxy and became real astronomical darkness
per local date. This re-ran the polarity question against it.

## The join bug — I INTRODUCED IT, AND THEN BLAMED IT ON THEM

> **RETRACTION, 2026-09-24, same day.** The section below says this bug affects
> cilex-vision's published figure. **It does not, and the bug was mine.** The join
> they actually sent had NO `local_date` term at all — it was range-only:
>
> ```sql
> LEFT JOIN site_solar_times st ON st.site_id = <site>
>   AND v.start_time >= st.dark_start AND v.start_time < st.dark_end
> ```
>
> A 02:00 segment matches the previous evening's row by construction, because the row
> carries a window that already spans midnight. **I added the `local_date` predicate
> myself, broke it, measured the breakage, and reported it to them as a defect in
> their query** — "it is the join you published to me". It was not. Measured, one
> population, the join as the only variable:
>
> ```
> A  range-only (theirs)             407,314 dark segs   6.20 MB
> B  + local_date, own date (mine)   192,699 dark segs   6.18 MB   <- the bug
> C  + local_date shifted 12h (mine) 407,314 dark segs   6.20 MB
> ```
>
> **Their A and my C agree exactly**, so their `5.89 / 4.57` stands unaltered and my
> "+23.7 % corrects their figure" was wrong twice over — it corrects *my own* +15.4 %,
> and theirs never needed correcting.
>
> **And their form is better than my fix.** The 12-hour shift works and I verified it
> at both solstices, but it is a constant that has to hold at every latitude and season
> the code ever runs at. Range-only needs no shift, no date arithmetic and no
> assumption, because the row carries its own boundaries — and
> `ix_site_solar_times_dark (site_id, dark_start, dark_end)` already indexes it.
> Adopted; the 12-hour shift is withdrawn from the study scripts.
>
> The finding below is real and worth keeping as a trap. The attribution was not.

## The join bug, as originally written — real, but mine

**A dark window spans midnight.** `local_date = 2026-09-23` carries
`dark_start = 09-23 19:39` and `dark_end = 09-24 06:07`. So the obvious join —

```sql
JOIN site_solar_times st ON st.site_id = c.site_id
 AND st.local_date = (v.start_time AT TIME ZONE 'Europe/Moscow')::date
```

— tests a 02:00 segment against **that same date's evening** window, and every
pre-dawn hour is classified as light. Measured on 7 days of outdoor continuous
cameras:

| | dark segments | dark MB | light MB | contrast |
|---|---|---|---|---|
| joining on the segment's own date | 192,699 | 6.18 | 5.35 | **+15.4 %** |
| joining 12 h back | **406,369** | 6.20 | 5.01 | **+23.7 %** |

**213,670 genuinely dark segments — 53 % of the real dark population — were being
counted as light**, and the contrast was understated by a third. The fix is to shift
12 hours before taking the date, which attributes a segment to the night whose evening
it belongs to; checked at both solstices (`dark_start` runs ~16:00 midwinter to ~23:30
midsummer, so a 12 h shift is unambiguous at every season here).

My earlier `+15.4 %` is retracted; the figure is **+23.7 %** for outdoor continuous
cameras. cilex-vision's `5.89 vs 4.57` used the same join shape and is likely affected
in the same direction.

## A sampling error of mine, the second in this study

With the join fixed, 57 of 60 cameras still read dark ≈ light. That was not the fleet;
it was `ORDER BY start_time DESC`, which takes the **most recent** segment of each
class — putting the "light" sample minutes before `dark_start`, in civil twilight,
visually almost night.

**The boundary is exactly where two classes are least distinguishable, so it is the
worst place to characterise them from.** Sampling `dark_start + 1 h .. dark_end − 1 h`
against `sunrise + 2 h .. sunset − 2 h` changed the result completely.

## The result that decides the design

59 continuous cameras, one segment mid-dark and one mid-day, 2 keyframes each:

| class | n | meaning |
|---|---|---|
| `ir` — chroma 0.00 in the dark | **1** | definitive, no tuned constant |
| **inverted** — *more* colour in the dark | **11** | coloured artificial light; "low chroma" = day |
| **normal** — less colour in the dark, never 0 | **12** | dim colour, no IR |
| flat — no usable separation | **35** | chroma alone cannot classify these |

**The two polarities are nearly balanced: 11 against 12.** A single fleet-wide chroma
threshold would be wrong on roughly half of the cameras that have any chroma signal at
all. That is not a tail case, it is a coin flip — and both halves separate cleanly on
their own, so tuning on either one would look like success.

**And 35 of 59 have no usable chroma separation at all.** Chroma cannot carry
day/night for most of this fleet. It carries `ir` definitively, for the one camera
that has it.

*Bound: one segment pair per camera, 2 keyframes. Some "flat" cameras may separate
with more samples; this is a floor on how many have a signal, not a ceiling.*

## What the fleet actually offers, ranked

1. **Segment bytes.** Free — already in the metadata the worker fetches, no decode at
   all — and the per-camera census (part 1) found a usable day/night signature on 87
   of 133 cameras, with transitions landing on 07h and 19h where astronomy puts them.
   +23.7 % dark-vs-light across outdoor continuous cameras.
2. **`chroma == 0` → `ir`.** Definitive where it applies. Costs one decoded keyframe.
3. **Chroma magnitude for day/night.** Only with **per-camera polarity learned from
   that camera's own distribution**. Never fleet-wide.
4. **Mean luma.** Falsified. Diagnostic only.

## Cost, still not the registry figure

0.58–0.62 CPU-s per segment at 2–3 keyframes, **fetch included**, consistently across
three runs totalling ~260 segments. The registry column excludes fetch and is
per camera-hour, so this is neither — it is the input to that measurement once the
sampling strategy is fixed.
