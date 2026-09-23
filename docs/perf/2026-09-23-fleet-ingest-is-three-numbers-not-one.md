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
| what the server actually pulls | **~220** | cilex-vision, three 45 s `enp3s0` RX samples: 220.2 / 221.3 / 222.5 |

**156 sits between the first two, which differ by 43 %.**

> **CORRECTION, same day, after I went looking for where 156 came from — which I
> should have done before characterising it.** I wrote that 156 was "undefined"
> because it fell between two of my numbers. It was not undefined. It has a
> provenance and a definition, in this repo:
> `docs/letters/2026-08-15-booth-half-wall-starved.cv-reply.md:109` —
> *"The uplink renegotiation that saturated camera ingest was fixed 08-13
> (100 Mbit → 1000; **fleet ingest measured 156 Mbit/s after**)."*
> That is an `enp3s0` RX measurement, which is **exactly the quantity cilex-vision
> measured tonight at ~220 Mbit/s**. So 156 was a correct measurement of a
> well-defined thing, taken 39 days ago, and it is now **41 % stale** — not
> ambiguous. My "it sits between two numbers" was a coincidence of magnitude that
> I read as evidence of ambiguity because I had not looked for the source.
> The decomposition below stands and is still the useful part. The headline claim
> about 156 was mine and was wrong.

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

---

# Addendum: both enrolled stations are on the server's LAN, not across an uplink

**Measured 2026-09-23 on this box.** cilex-vision concluded that a Labs fetch budget
must depend on where a station is, because `wt-sm-vnutri-01` holds a Tailscale
`100.102.2.74` address and a full-rate fetch would be "1.7x the entire uplink". The
rule is right. The premise for that station is not.

```
tailscale ping wt-sm-vnutri-01
  pong from wt-sm-vnutri-01 (100.102.2.74) via 192.168.1.31:41641 in 1ms

ip neigh  192.168.1.31 dev enp3s0 lladdr 30:56:0f:82:c5:97 REACHABLE
          192.168.1.5  dev enp3s0 lladdr fc:9d:05:5c:1f:bf REACHABLE   (wt-office-01, 0.46 ms ICMP)
this box  enp3s0 192.168.1.4/24 · Speed 1000Mb/s · Duplex Full
```

**Both enrolled stations are on this box's physical Ethernet segment.** So is the camera
fleet — the `192.168.1.101`+ block carries Hikvision/HiWatch OUIs. A Tailscale `100.x`
address says a peer is *on the tailnet*; it does not say the traffic crosses a WAN link,
and for this peer it does not: Tailscale selected a direct same-subnet path at 1 ms.

**The historical record is consistent with this, not against it.** The August
"bandwidth-bound booth" letters measured ~4.4 Mbit/s — that was a **100 Mbit link
renegotiation**, fixed 08-13 and taken to 1000
(`docs/letters/2026-08-15-booth-half-wall-starved.cv-reply.md:109`). A LAN with a sick
port, not a thin WAN.

## What this does and does not change

- **Does not change the rule.** "A worker's fetch budget should depend on where the
  station is" is correct and is better than any fleet-wide number.
- **Does change which side of it these two stations fall on.** Both are LAN, gigabit,
  sub-millisecond. Neither is uplink-constrained today.
- **The uplink figure is moot for both**, so the `~42 Mbit/s` cilex-vision flagged as
  inherited-and-unmeasured does not need measuring to decide this.
- **The real shared resource is the server's single NIC**, not a WAN link: 1000 Mbit/s
  each way, currently ~220 in and ~43.7 out. Labs at full rate adds 72.8 outbound,
  reaching ~117 of 1000.

## The caveat that keeps their concern alive

Tailscale path selection is dynamic. `tailscale status --json` shows this peer's relay
fallback as `hel` (Helsinki, 35.2 ms). **If the direct path breaks, traffic fails over
to DERP and then it does cross the uplink** — at which point their 1.7x figure becomes
live. So the budget should key on the *measured current path*, not on a station's
address family. An address is a name; the path is a measurement.

**Not measured here:** whether the booth is physically co-sited or reached over a
bridged segment, and what the WAN uplink actually is. Neither is needed for the
conclusion above, and the second cannot be measured without saturating a live link.
