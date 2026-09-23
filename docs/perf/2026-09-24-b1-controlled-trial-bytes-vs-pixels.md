# B1 controlled trial — bytes vs pixels vs astronomy, on operator ground truth

**Measured 2026-09-24.** 55 street-facing continuous cameras, 4 time slots, **12,320
decoded frames**, 9.2 GB read, 1,008 CPU-s, 279 s wall. Read-only: no Labs endpoint,
no scan unit claimed. Dataset committed beside this file; both scripts re-run.

## Why this trial exists

Every earlier comparison scored against a **proxy** — astronomy, or the encoder's own
byte curve. Both are things the classifiers are partly *made of*, so scoring against
them is marking your own work. The operator supplied real labels from having been
there, which is the one thing neither system could generate:

| slot | time (MSK) | label | source |
|---|---|---|---|
| A | 2026-09-23 17:15 | **DAY** | operator: *"the sun came out, it was a sunny moment"* |
| B | 2026-09-24 00:30 | **NIGHT** | operator: *"now"* |
| D | 2026-09-23 12:00 | DAY | midday anchor, weather unlabelled |
| C | 2026-09-23 06:00 | **held out** | operator expected overcast DAY; ephemeris says NIGHT |

Both classifiers saw **exactly the same segments**: luma, chroma and byte rate all
come from the same decoded material, in the same window, per camera.

## Method

- **Leave-one-camera-out.** A threshold fitted on 55 cameras and tested on the same 55
  measures memorisation. Each camera is held out in turn and scored on a threshold
  fitted without it. That is the number that predicts a *new* camera.
- **McNemar's exact test** on the paired disagreements, because both classifiers answer
  the same rows. Comparing two accuracies as independent samples would overstate
  significance.
- **Both get their best shot**: each is given the optimal threshold for its own feature
  on every fold, so neither is handicapped by a constant chosen by me.

## Result

165 labelled rows (110 DAY, 55 NIGHT). Majority-class baseline = **66.7 %**.

| classifier | LOCO accuracy | DAY recall | NIGHT recall |
|---|---|---|---|
| **ASTRONOMY — sunrise/sunset table** | **100.0 %** | 100 % | 100 % |
| bytes, per-camera normalised | 82.4 % | 88.2 % | 70.9 % |
| bytes, fleet threshold | 77.6 % | 88.2 % | 56.4 % |
| chroma, fleet threshold | 75.2 % | 97.3 % | 30.9 % |
| chroma, per-camera | 70.9 % | 85.5 % | 41.8 % |
| pixel — mean luminance, per-camera | 68.5 % | 95.5 % | 14.5 % |
| **pixel — mean luminance, as briefed** | **63.0 %** | 85.5 % | **18.2 %** |

**Mean luminance scores below the majority-class baseline.** Always answering "day"
would beat it. Its NIGHT recall of 18 % means it fails to notice darkness five times
out of six.

Paired tests:

```
bytes     vs luma       38 / 14    p = 0.0012      bytes better
bytes_pc  vs bytes      18 / 10    p = 0.18        per-camera normalisation NOT significant
bytes_pc  vs luma_pc    37 / 14    p = 0.0018      bytes better
astronomy vs bytes_pc   29 /  0    p = 3.7e-09     astronomy better
astronomy vs luma       61 /  0    p = 8.7e-19     astronomy better
```

The **29 / 0** and **61 / 0** are the shape worth noticing: astronomy is right on every
row the others get wrong, and wrong on none that they get right. Strict dominance, not
a better average.

## The honest limit of that 100 %

**Astronomy scores perfectly partly by construction.** The operator's labels are pure
day/night labels, and day/night is the thing an ephemeris *defines*. There is no
independent test of astronomy in this trial, and it should not be quoted as though
there were.

That is the argument, though, rather than a weakness in it: *"is it day or night"* is
an astronomical question, and the pixel and byte methods are inferring — worse, and at
a cost — something the table states outright for free.

What astronomy genuinely cannot answer, and this trial does not test: whether a scene
is **artificially lit** (floodlit forecourt at midnight), and whether a camera has
switched to **IR**. Both need pixels. That is where B1's real product is.

## The held-out slot settled an operator expectation

06:00 was picked as "overcast day". At this site on that date, **sunrise was 06:47 and
civil dawn ended 06:05**, so it was astronomically night.

| | says DAY at 06:00 |
|---|---|
| pixel (mean luma) | **39 of 55 cameras (71 %)** |
| bytes | **9 of 55 cameras (16 %)** |

**The byte signal agrees with the ephemeris; mean luminance does not.**

> **RETRACTED, 2026-09-24, after cilex-vision replicated this from the committed
> dataset with independently written scoring code.** This paragraph originally said
> 06:00 reads 1.781 Mbit/s, *"darker than midnight's 1.596"*. **That ordering does not
> survive the statistic.** Checked in my own data:
>
> ```
>              mean     median    p25      cameras < 1.3 Mbit/s
> B_dark       1.596    1.871    1.322     14
> C_0600       1.781    1.872    1.834      3
> ```
>
> The medians differ by **0.08 %**. The 11.6 % gap between the means is entirely
> B_dark's long left tail — 14 cameras writing under 1.3 Mbit/s at midnight against 3
> at 06:00. Mann-Whitney gives p = 0.045, which is a difference in distribution SHAPE,
> not evidence that one slot is darker than the other.
>
> **The conclusion is untouched**: both slots are dark, and the byte curve agreed with
> the ephemeris against the expectation that created the slot. Only the flourish was
> wrong, and it was wrong in the way a mean is always wrong — by reporting a central
> tendency that no camera actually has.
>
> **The 14 cameras are unexplained.** cilex-vision predicted A3's motion confound and
> then measured against it: 00:30 had motion on 17 cameras against 5 at 06:00, the
> *opposite* direction to the hypothesis, and sampling was uniform (8 segments, 56
> frames, every camera, every slot). They withdrew the explanation rather than stretch
> it. Open.

The raw rates, with medians beside the means:

```
slot                luma            chroma          byte Mbit/s
A_sunny     108.3 +- 7.4     14.89 +- 2.59        0.991 +- 0.265
D_midday    105.2 +- 7.2     12.35 +- 3.01        1.221 +- 0.421
B_dark      104.5 +- 9.9     11.49 +- 3.62        1.596 +- 0.415
C_0600      105.3 +- 8.0     12.15 +- 3.47        1.781 +- 0.300
```

Two independent signal paths — the ephemeris and the encoder's rate control — agree
that 06:00 was night, against the expectation that set up the slot.

**And there is the auto-exposure finding, quantified against real labels.** I first
wrote it as "full sunshine 108.3, midnight 104.5 — a 3.6 % difference". cilex-vision
pointed out that my own raw data is **harsher than my summary**, and they are right.
Slot **medians**, which is the statistic that should have been used:

```
A_sunny  108.4      D_midday 106.6      C_0600 106.5      B_dark 106.1
```

**2.3 points between the brightest and darkest moments of a day** — flatter than the
means suggested. That is why mean luminance cannot work, and the correct number makes
the case more strongly than the one I published.

## Conclusion

1. **Mean luminance is falsified** — below baseline, p < 0.002 against every
   alternative. It should not be B1's discriminant.
2. **Bytes beat pixels** for day/night, significantly and consistently.
3. **Astronomy beats both**, strictly, for free, and needs no camera to be working.
4. So **B1 should not infer day/night at all.** It should read the ephemeris, and spend
   its pixel budget on the two questions astronomy cannot answer: is the camera in IR,
   and is the scene lit when the sky says it should not be.

## The failure mode this trial CANNOT detect

**Astronomy is only as good as the coordinates**, and nothing here tests those.
cilex-vision's site record was **30 km off** until 2026-09-23 — St Petersburg city
centre instead of Sestroretsk — and it would still have scored 100 % on this trial,
because 30 km moves sunrise by under two minutes and none of these four slots is
anywhere near a boundary. A stale or wrong site location is the one way the winning
method fails, and a trial built from slots in the middle of day and night is blind to
it by construction.

Their observation, and it is the most useful caveat either of us produced about the
result. One practical consequence: **the IR cameras are an independent check on the
site coordinates.** A working IR-cut filter closes when the scene actually darkens, so
a camera whose transition sits consistently far from astronomical dusk is evidence the
ephemeris is being computed for the wrong place.

> **I OVERCLAIMED THAT, and the correction is measured.** I wrote that this is
> *"exactly the check that was missing when the coordinates were 30 km out"*, which
> implies it would have caught that error. **It would have taken about a week and a
> half.** cilex-vision tested it on the byte curve; I re-derived it with a different
> estimator (time at which the fleet MEDIAN crosses halfway between its day and night
> plateaus, against their curve inflection) and we agree:
>
> ```
> offset of the transition from computed sunset
>   mine   (median crossing, 5 evenings)   mean +4.0 min   SD 7.9
>   theirs (inflection,      7 evenings)   mean +6.4 min   SD 6.6
> ```
>
> **The noise is weather, and it is physically correct behaviour** — cloud darkens a
> scene early and clear sky late, and the camera responds to light rather than to an
> ephemeris. The trend is clean (sunset moved −18 min over their week, the byte
> midpoint −21), so the signal is real; it is the per-evening scatter that is large.
>
> At 60.1 N, 30 km of longitude error shifts sunset by **2.2 minutes**. Against an SD
> of 6.6–7.9 that needs **9 to 13 evenings** to resolve at one standard error.
>
> **So it is a slow drift monitor, not an assertion check.** A wrong city or a wrong
> timezone shows in a single evening. The 30 km error this site actually carried does
> not. It must never be used to accept a newly entered coordinate — telling someone
> "the IR transitions confirm your location" would be asserting something unknowable
> for ten days. cilex-vision's distinction, which is the right one: *"this validates
> the coordinates"* and *"this would have caught the error we had"* are different
> claims, and only the first is true.
>
> Two refinements of theirs for whoever builds it: use the FLEET transition, since
> weather is common-mode and averages down across cameras but not across nights; and
> expect the per-camera residual to be the more useful output anyway — one camera
> drifting alone is a camera fault, which is faster to detect and is B2's territory.
>
> **AND A FALSE POSITIVE THAT WOULD HAVE FIRED SITE-WIDE.** Probing the cameras for
> something else, cilex-vision found every one carries a day/night **schedule** of
> `06:00–18:00` — 47 minutes early at dawn, 58 at dusk. Inert today, because all report
> `ISPMode.mode = auto` and the measured transition tracks the sun. But **a camera
> flipped to `mode = schedule` would transition on the clock and be indistinguishable
> from an hour of coordinate error.** The monitor must read `ISPMode.mode` and EXCLUDE
> scheduled cameras rather than flag them; otherwise one operator changing one camera
> raises a coordinate alarm for the whole site. That is a worse hole than the resolving
> power, and neither of us would have found it by building the thing.

## Bounds

One site, one day, one sunny moment, 55 cameras, 4 slots. No seasonal coverage: this
site runs 1h26m of darkness at midsummer against 16h14m at midwinter, and none of that
is sampled here. The per-camera normalisation result (not significant, p = 0.18) is on
3 slots per camera and is a weak test of it.
