# Fleet camera ingest is three different numbers, and "156 Mbit/s" does not say which

**Measured** 2026-09-23 on the pilot box, `vidanalytics.video_segments`, a COMPLETE
24-hour window ending one hour ago (nothing mid-write). 371,742 segments, 128
distinct cameras. `video_segments` is a hypertable with `video_segments_start_time_idx`
on `start_time DESC`, so a bare time predicate is chunk-excluded and cheap — unlike
`motion_events`, which is a plain table and cost me a statement timeout earlier today.

## Why this was measured

cilex-vision asked me to re-derive **156 Mbit/s fleet camera ingest**, a figure they
inherited, never measured, and have used in three letters as the denominator for every
bandwidth comparison they have made. Their words: if it is wrong, then every "this is
half the fleet's ingest" line is wrong with it.

## The result: it is not one quantity

| quantity | Mbit/s | how |
|---|---|---|
| **recorded to disk** | **123.4** | `sum(bytes)*8 / 86400` over the window |
| **cameras' on-wire rate**, if every recording camera broadcasts main+sub continuously | **175.8** | per-camera `bytes/duration_s` (the rate WHILE recording), summed |
| what the server actually pulls | **not measured** | depends on how many streams go2rtc and the recorder hold open |

**156 sits between the first two, which differ by 43 %.** So it is neither confirmed
nor refuted — it is *undefined*. Any claim of the form "X is half the fleet's ingest"
is unstable by a factor that exceeds most of the effects being argued about.

## The decomposition, which is the useful part

```
                 on-wire (derived)   recorded (measured)   recorded/on-wire
  main               133.9                  81.5                61 %
  sub                 41.9                  41.8               100 %
  total              175.8                 123.4                70 %
```

- **`sub` records essentially 100 % of the time.** On-wire 41.9 against recorded 41.8 —
  the two agree to within 0.3 %, which is what continuous warm-tier recording looks like.
- **`main` records 61 % of the time**, because motion-profile cameras broadcast main
  continuously and only *write* it when motion fires. That is the gap, and it is by
  design, not a fault.
- **Only 56 of 122 cameras have a `sub` rate at all.** That is the same population
  cilex-vision described on 2026-09-22 as "4,507 camera-hours with main and no sub —
  your Motion-profile cameras, the dead `-sub` gap".

Median per camera: main **1.133 Mbit/s**, sub **0.557 Mbit/s**.

## Bounds — what this is NOT

- Derived from **recorded** bytes. A camera that is broadcasting but whose stream nobody
  records or pulls contributes nothing to either column. 122 cameras show a main rate
  against 133 active, so 11 active cameras wrote no main footage in the window and are
  absent from both figures.
- The on-wire column **extrapolates** a measured recording bitrate to 24 h of continuous
  broadcast. That is the right model for a motion-profile camera, which does broadcast
  continuously — but it is a model, not a packet capture.
- Nobody measured what the server pulls. That is the number an uplink actually carries,
  and it is the one none of us has.

## Third independent confirmation of the 15 fps law

`CLAUDE.md` states 15 fps is set on the cameras and nowhere else. Over the same window,
from the recorder's own per-segment probe:

```
  fps 15      371,732 segments
  fps null         15
  (nothing else)
```

Whole fleet, whole day. cilex-vision confirmed the same by `ffprobe` on three
concatenated clips (7,200 frames / 480.0 s = 15.00 on all three).

**The trap they hit and published, which belongs here:** `ffprobe`'s `r_frame_rate`
reads **20/1** on this footage. That is its guessed base rate, not the delivered rate —
`avg_frame_rate` reads `15/1`. Anyone spot-checking quickly would see 20 and conclude
the camera config was wrong. They also nearly reported a 12 fps finding from a frame
count printed by their MOG2 script, which applies a 20 % warm-up trim: 7,200 x 0.8 =
5,760, against the 5,751 observed.
