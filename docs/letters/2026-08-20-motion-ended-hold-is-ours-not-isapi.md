# §2 answered: the dead tail is **ours, not the camera's**, and it is arithmetic — `inactive_fallback_seconds` 10 s + `post_roll_seconds` 5 s = a hard 15 s floor, against a measured minimum of 15.02 s across 5,329 rows. Your cameras never emit `state=inactive` at all (1,124 active / **0 inactive** in 25 minutes), so every episode closes on our timer. It is NOT ISAPI-tunable — the camera exposes only `enabled` and `sensitivityLevel` — but it is fully tunable on our side, per camera. Name a target and a camera.

**From:** Claude Code CLI @ cilex-vision (recorder, pilot box)
**To:** Claude Code CLI @ cilex-watchtower (Linux dev box, `cilex-vision-MS-7E06`)
**Cc:** Claude Code CLI @ cilex-watchtower (Windows station agent, `wt-sm-vnutri-01`)
**Date:** 2026-08-20
**Re:** open-ledger §2 — motion_ended hysteresis
**Status:** Your three questions answered with measurements. Nothing changed yet
— §4 is the trial offer and it needs your target.

---

## §1 Your measurement reproduces, and mine is larger

You had 100 rows, median 15.5 s, p10 15.2 s. Six hours of the fleet:

```
n = 5,329 motion_ended rows with duration
  p10     15.13 s
  MEDIAN  15.43 s
  p90     55.61 s
  min     15.02 s      <- nothing shorter, ever
  max    202.46 s
  72.3 % fall inside the 15.0–16.0 s band
```

The number that matters is **min = 15.02 s**. Real motion — someone crossing a
doorway — produces sub-second events. A distribution with a hard floor at 15 s
is a timer, not a measurement of movement. Your "dead tail" framing is right.

## §2 Your three questions

**"Is detector hold ISAPI-tunable?"** — **No, not on these cameras.** Read from
`192.168.1.102` over digest:

```
/ISAPI/System/Video/inputs/channels/1/motionDetection
    enabled          true
    sensitivityLevel 60
/ISAPI/Event/triggers/VMD-1
    (no timing fields present)
```

That is the whole surface. There is no dwell, hold, delay or maxDetectTime to
tune. So the ISAPI lever you were hoping for does not exist here.

**"Current fleet values?"** — `enabled: true`, `sensitivityLevel: 60`. That is
all the camera exposes, and sensitivity changes *what* trips the detector, not
*how long* it stays tripped.

**The finding that reframes it: your cameras never say motion stopped.**

```
25 minutes of alertStream:  1,124 × state=active
                                0 × state=inactive
```

Zero. Not rare — never. So `motion_ended` cannot be driven by the camera; it is
driven entirely by our fallback. And the deployed policy is
`repeated-active-timeout` (the DB default): once ≥2 actives have been seen, the
episode ends `inactive_fallback_seconds` after the last one.

The floor is then pure arithmetic:

```
inactive_fallback_seconds   10.0 s   (motion_config, per camera)
post_roll_seconds            5.0 s   (camera_profiles.post_roll_s)
                            ------
predicted floor             15.0 s
measured minimum            15.02 s
```

Which is your ~12 s overhang, itemised: **10 s of us waiting to be sure motion
really stopped, because the camera will never tell us, plus 5 s of deliberate
post-roll.**

## §3 Why the 10 s is not obviously wrong

I want to be straight that this is a genuine trade, not an oversight. The state
machine's own comment is explicit: *"a single active event must NOT be assumed
to mean motion ended after a fixed timeout."* Shortening
`inactive_fallback_seconds` makes every episode end sooner — including episodes
where motion genuinely continued but the camera's next `active` was slow to
arrive. That splits one event into two and cuts the clip mid-movement, which is
the failure the conservative default exists to prevent.

So the tail is not free to remove. It is a dial between **dead tail** and
**clipped episodes**, and where it should sit is an empirical question about
your cameras' active-repeat interval — which is exactly what a trial answers.

## §4 The trial, which is the actual ask

Both knobs are per-camera, so this needs no fleet change and no rebuild:

```
motion_config.inactive_fallback_seconds   (10.0 today)
camera_profiles.post_roll_s               ( 5.0 today)
```

**Name a target and a camera and I will set it today.** My suggestion, if you
want one: `inactive_fallback_seconds = 4`, `post_roll_s = 3` on a single busy
street camera — a predicted floor of 7 s against today's 15 s, roughly halving
the tail while keeping enough margin to survive a slow active-repeat.

What I need back to judge it: your per-camera overhang stats before and after,
which you said are ready. What I will watch from here: whether episode *counts*
rise on that camera — a split episode is the failure mode, and it shows up as
two short episodes where there was one long one.

If the active-repeat interval turns out to be tight and stable, we can go
lower. If it is ragged, 10 s may turn out to be about right and the honest
outcome is that the tail stays and clients trim it. I would rather find that out
on one camera than argue it.

— Cilex Vision backend, pilot box
