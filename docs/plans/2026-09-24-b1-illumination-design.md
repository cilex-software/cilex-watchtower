# B1 — illumination classifier: design, before any code

**Status: DESIGN ONLY.** Operator asked for the scope before implementation
(2026-09-24). Nothing here has been built, no Labs endpoint has been called, no
scan unit has been claimed. Cost figures below are *predictions* and are labelled
as such; §6 is how they get replaced by measurements.

Task from `docs/letters/2026-09-23-b1-illumination-start-and-the-free-ground-truth-you-already-have.md`.

---

## 1. The hazard this design exists to avoid

cilex-vision's A2 shipped a threshold of `2.0` for `median_delta`. Measured on 170
real segments, it sits **below the noise floor on 28 of them (16 %)** — daytime p90
is 2.936. It was tuned on night footage and nobody checked daylight.

**B1 is a classifier made of thresholds, so it is the same hazard with more surface
area.** Worse: B1 is the covariate every later analyser keys off, so a B1 threshold
that fails on some population propagates silently into all of them.

So the design rule for this work, stated before any code: **no constant is chosen by
judgement. Every threshold is derived from a measured distribution, on a named
population, and the derivation is committed with the number.**

## 2. What actually separates day from night — and why "mean luminance" alone is weak

cilex-vision proposed *mean luminance plus colour-saturation collapse*. The second
half is strong. **The first half I expect to be weak, and I want to say why before
building on it rather than after.**

**Auto-exposure fights exactly the signal we would be measuring.** A camera in a
darkening scene raises gain and lengthens exposure until mean luma returns toward its
target. On a well-behaved camera mean Y is therefore *roughly invariant* to ambient
light across a wide range — which is the opposite of what a classifier needs.

**This is a hypothesis, not a measurement, and it is the first thing phase 1 tests.**
The indirect evidence for it is cilex-vision's own byte signature: night segments are
*larger* (6.0–6.4 MB against a 3.2 MB daylight minimum). Larger means less
predictable, which is what gain-boosted sensor noise looks like — a camera that had
simply gone dark would compress *better*, not worse. That supports "the sensor is
being pushed hard at night", which is the same mechanism that flattens mean luma.

Ranked by how robust I expect each discriminant to be:

| signal | separates | expected robustness | why |
|---|---|---|---|
| **chroma energy** — mean \|U−128\|, \|V−128\| | `ir` from everything | **high** | physical: the IR-cut filter is a mechanical swing, and with it closed there is no chroma information to recover. Independent of scene content and exposure. |
| **chroma energy, mid-range** | `night` from `day` | medium | colour desaturates in low light before IR engages; but a sodium-lit scene is strongly coloured at night |
| **luma noise proxy** (σ of Laplacian in flat blocks) | `night` from `day` | medium-high | directly measures the gain boost that the byte signature already shows |
| **mean luma** | `day` from `night` | **low** | fought by auto-exposure; kept only as a tiebreaker |

**Consequence for the contract:** `ir` should be reliable and near-binary.
`day`/`night` will need two agreeing signals. `dusk` and `unknown` carry the rest —
see §4.

## 3. Sampling: two segments, and the second one earns more than cost

cilex-vision's costing says decode is per-frame (r = −0.03 against hour size, 901–902
keyframes every run), so the lever is frames decoded. Their proposal is `limit=2`.

**Taking it, and noting that two segments *far apart* does something their letter
did not claim: it detects the transition hours.** If the hour's first sample reads
`ir`/`night` and its last reads `day`, that hour is not either one — it is the
changeover. That is a principled way to emit `dusk`, rather than carving it out of a
luminance band where it would need exactly the kind of arbitrary constant §1 forbids.

So: **two segments, first and last of the hour**, and:

```
first == last            -> that class
first != last            -> dusk        (the hour contains a transition)
either unreadable        -> unknown
signals disagree within a sample -> unknown
```

**One thing to raise with cilex-vision:** the vocabulary has `dusk` but no `dawn`, so
under this scheme `dusk` means *transitional* in both directions. If they want them
distinguished, the direction is free (compare first against last) but it needs a
vocabulary change and a migration. Asking rather than assuming.

## 4. `unknown` is a real answer and will be emitted often at first

`unknown` is in the CHECK constraint and cilex-vision enabled it. This design uses it
rather than avoiding it:

- both samples unreadable, or the fetch 403s mid-hour → `unknown`
- chroma and noise signals disagree → `unknown`
- the camera has no derived thresholds yet (a new camera, §5) → `unknown`

This is `CLAUDE.md`'s "absent data renders as unknown, never as healthy" applied to a
classifier: a confident wrong `night` on a daylight hour is exactly the A2 failure,
and it would poison every analyser that keys off it. **An honest `unknown` costs a
row; a wrong label costs the covariate.**

## 5. Thresholds: derived per camera, from the camera's own distribution

A fleet-wide constant is what failed for A2. Instead, in phase 1:

1. Sample N hours across ≥3 days per camera (cheap — two segments each).
2. For each camera build the distribution of chroma energy over those hours.
3. **`ir` cut:** expected to be strongly bimodal. Take the antimode. If the
   distribution is *not* bimodal — an indoor camera on constant artificial light —
   that camera has **no `ir` state**, and saying so is the correct output.
4. **`day`/`night` cut:** derived from the same window, cross-checked against §6.
5. Commit the per-camera cut points with the sample size and date they came from,
   because they are measurements and will go stale — see the retention figure and the
   156 Mbit/s figure, both of which were correct when written.

Cameras with too few hours to derive a cut → `unknown` until they have them.

## 6. Validation: the encoder's own labelling, on a genuinely different path

cilex-vision's byte signature (fleet mean, 56 continuous outside cameras) shows two
sharp steps, 06:00→07:00 and 18:00→19:00, each 30–45 %, opposite directions.

**This is the right kind of check and it is the only kind that has caught anything
between the two boxes recently: a second measurement by an independent path.** Pixel
chroma and encoder bitrate share no code, no library and no failure mode. A second run
of my own classifier would agree with itself forever; this will not.

**Used per camera, not fleet-mean.** Their own caveat is the reason: individual
cameras switch at different lux and an indoor camera shows no step at all. So:

1. For each camera compute its own hourly mean segment size over ≥7 days.
2. Classify each camera as *has a step* / *has no step*, and **report the count** —
   "how many of the fleet even have a day/night signature" is itself a finding.
3. On the step cameras, compare the classifier's `ir` transition hour against the
   byte step hour. **Agreement is the acceptance criterion. Disagreement means one of
   the two is wrong and neither gets published until it is resolved.**
4. On the no-step cameras, the byte check cannot adjudicate; those are reported as
   unvalidated rather than as passing.

## 7. Cost: predicted here, measured before it is quoted anywhere

**PREDICTION, NOT A MEASUREMENT.** From cilex-vision's 79–106 CPU-s/camera-hour at
901 keyframes, and ~8 keyframes per 30 s segment:

```
2 segments/hour x ~8 keyframes = ~16 frames, against 901       ~1/56 of the decode
88.4 CPU-s median / 56                                         ~1.6 CPU-s/camera-hour
```

I expect the real figure to be **higher than 1.6**, because per-invocation container
parsing and process startup do not scale down with frame count, and at 16 frames that
fixed cost stops being negligible. **That is a reason to measure rather than divide.**

Method when it runs, so it is re-derivable from their side:
- `getrusage` `RUSAGE_CHILDREN` for ffmpeg + `RUSAGE_SELF` for the arithmetic; CPU
  time, not wall.
- One long-lived software decoder, no `-hwaccel` (their §5, and this box's own
  creation-rate finding).
- Fetch measured separately and **excluded** — it is real but it is network, and the
  registry column is CPU.
- ≥5 whole camera-hours spanning both day and night, since the whole point is that
  the two are different.
- Report the range and the median, and lead with any structural invariant found
  rather than with the median — the median is true this month.

`cost_cpu_s_per_camera_hour` stays `null` on their side until this is measured. It
does not get a guess, and §7 of their letter is explicit that the operator's budget
page prefers `null` to one.

## 8. Blocked-on and not-assumed

- **`retryable` is COMMITTED, NOT DEPLOYED** on their side, as is the retention-window
  fix. **Do not build branching against it yet.** Earlier today this box reported
  their Labs error contract from source without distinguishing it from the running
  image — `retryable` appears 30× in their repo and 0× in the deployed container. The
  worker branches on `detail` slugs until they confirm deployment.
- **403 `segment_outside_lease` exists** on `GET /labs/segments/{id}` (they corrected
  this) — the byte fetch re-checks the lease and refuses differently from the list
  call. Needs its own branch: 409 on the list means re-claim, 403 on a fetch means the
  lease died mid-hour.
- **Stream, never buffer.** `analyse()` takes an iterable of chunks. A raw-bytes
  signature OOM-killed their container at ~450 MB/hour doubled by a join.
- **Station identity.** Any fetch is lease-scoped and station-authenticated. This box
  enrols as `cilex-vision-MS-7E06` and its `last_seen_ip` is the docker bridge
  `10.0.0.1`, which identifies nobody — a known wart, not a blocker for B1, but the
  reason a station-scoped debug trace here is hard to attribute.

## 9. What phase 1 delivers (no scan units claimed)

1. The auto-exposure test of §2 — does mean luma actually separate day from night on
   this fleet, or is it flattened? **This decides whether the classifier cilex-vision
   described is the right one**, and it is ~30 minutes of decoding on footage already
   on disk.
2. The per-camera chroma distributions of §5, and the bimodality count.
3. The per-camera byte-step census of §6 — how many cameras have a day/night
   signature at all.
4. A measured cost figure with its method (§7).

None of that touches a Labs endpoint or claims a unit. Implementation of the worker
follows once the thresholds are derived rather than chosen.
