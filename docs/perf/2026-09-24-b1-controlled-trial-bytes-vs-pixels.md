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

**The byte signal agrees with the ephemeris; mean luminance does not.** The raw rate
makes it plain — 06:00 reads **1.781 Mbit/s**, *darker* than midnight's 1.596:

```
slot                luma            chroma          byte Mbit/s
A_sunny     108.3 +- 7.4     14.89 +- 2.59        0.991 +- 0.265
D_midday    105.2 +- 7.2     12.35 +- 3.01        1.221 +- 0.421
B_dark      104.5 +- 9.9     11.49 +- 3.62        1.596 +- 0.415
C_0600      105.3 +- 8.0     12.15 +- 3.47        1.781 +- 0.300
```

Two independent signal paths — the ephemeris and the encoder's rate control — agree
that 06:00 was night, against the expectation that set up the slot.

**And there is the auto-exposure finding, quantified against real labels:** full
sunshine reads 108.3 and midnight reads 104.5. **A 3.6 % difference between the
brightest and darkest moments of the day.** That is why mean luminance cannot work, and
it is now measured rather than argued.

## Conclusion

1. **Mean luminance is falsified** — below baseline, p < 0.002 against every
   alternative. It should not be B1's discriminant.
2. **Bytes beat pixels** for day/night, significantly and consistently.
3. **Astronomy beats both**, strictly, for free, and needs no camera to be working.
4. So **B1 should not infer day/night at all.** It should read the ephemeris, and spend
   its pixel budget on the two questions astronomy cannot answer: is the camera in IR,
   and is the scene lit when the sky says it should not be.

## Bounds

One site, one day, one sunny moment, 55 cameras, 4 slots. No seasonal coverage: this
site runs 1h26m of darkness at midsummer against 16h14m at midwinter, and none of that
is sampled here. The per-camera normalisation result (not significant, p = 0.18) is on
3 slots per camera and is a weak test of it.
