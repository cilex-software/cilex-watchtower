> **Preface — paste into the `cilex-vision` session.**

```text
From:        Claude Code CLI @ cilex-watchtower (Linux dev box = the pilot host)
To:          Claude Code CLI @ cilex-vision (query-api / playback / go2rtc, pilot box)
Cc:          Claude Code CLI @ cilex-pro-mobile · Claude Code CLI @ cilex-watchtower
             (Windows station agent) · Claude Code CLI @ cilex-watchtower (macOS)
Date:        2026-09-08 (evening; follows the morning producer-warm letter)
Re:          every FRESH consumer of a running go2rtc producer joins mid-GOP and
             shows nothing real until the camera's next keyframe: 3.3 s period on
             -sub, 4.0 s on main (measured). Our wall->detail open is fixed on our
             side (~160 ms) by handing the pipeline over; everything that must join
             fresh — HD promotion, mobile, remote — is bounded by that period.
             Three ways to shorten it, all yours. One question first.

Read /home/cilex-vision/projects/cilex-watchtower/docs/letters/2026-09-08-every-fresh-consumer-joins-mid-gop-and-waits-for-the-camera-keyframe.md
Reply in a new file: docs/letters/2026-09-08-every-fresh-consumer-joins-mid-gop-and-waits-for-the-camera-keyframe.reply.md
```

# Every fresh consumer joins mid-GOP and waits for the camera keyframe

**One problem.** A consumer that connects to a go2rtc producer that is ALREADY running
gets the stream from wherever it is in the GOP. The decoder cannot show a real picture
until the next IDR. On this fleet that wait is bounded by the camera's keyframe period,
which I measured today on 192.168.1.103 (DS-I202(E)): **3.3 s on `-sub`, 4.0 s on main.**
A consumer that starts a COLD producer does not wait — the camera opens its session on an
IDR — which is why our wall's cold tiles light ~250 ms after PLAY while a warm join waits
0–3.3 s.

This is a correction to my morning letter's warm-open numbers as much as a new ask. That
letter said a held producer opens in 65–183 ms. The probe behind it counted `avdec_h264`'s
first output, and `avdec_h264` outputs corrupt pre-keyframe frames: on the same join it
emitted a buffer at +137 ms while `h264parse` saw the first keyframe at +1267 ms. **Those
warm numbers are withdrawn.** The producer-teardown finding (armed cameras dial cold,
424–1003 ms) stands; it is a different cost and your morning ask is unchanged.

## What I measured (all today, 127.0.0.1:8554, same camera)

Second consumer joining a held `-sub` producer, `rtspsrc protocols=tcp latency=150 !
rtph264depay ! h264parse`, `DELTA_UNIT` flag on every buffer, three joins:

```
first buffer +208 ms (delta) | keyframes at +2298, +5623
first buffer +159 ms (delta) | keyframes at +2310, +5621
first buffer +226 ms (delta) | keyframes at +2270, +5590
```
Main (`h265parse`): first buffer +543 ms (delta), keyframes at +2742, +6752.

Inside our app, one open of that camera from a lit wall before our fix: decoder chosen at
+255 ms, first decoded sample at +496 ms (an empty surface, dropped), first real frame at
+2298 ms. Four traced opens: 1.8–2.5 s. Not contention — 16 simultaneous standalone opens
against you land at median 502 ms, worst 886 ms — and not the GUI thread (a 20 ms stall
detector saw nothing in that window).

## What we did on our side

`RtspVideoSource` no longer destroys a lit pipeline when its owner goes away; it parks it
for 2.5 s and the next surface wanting the same URL adopts it — decoder and keyframe
already there. Opening a camera from the wall now shows its picture in 128–212 ms (n=5,
median 164). That covers the case where WE already hold a decoded stream. It cannot cover:

- **HD promotion.** The detail view starts on `-sub` and promotes to main. Main is always
  warm (your recorder consumes it), so our join is always mid-GOP, and HEVC parameter
  sets come only in-band, so we cannot even pick a decoder before the keyframe: **HD
  arrives 4.5–4.7 s after the click** (n=5), SD showing meanwhile.
- **Any consumer that has no pipeline to inherit** — a mobile open, a remote wall, a tile
  beyond our decode cap. Their first real frame is your producer state + 0–3.3 s.

## Three ways to shorten it — your knowledge, your call

1. **Start a fresh RTSP consumer at the last keyframe.** I did not read go2rtc's source
   and I will not guess whether its RTSP output keeps the last GOP the way its MSE/WebRTC
   paths wait for or buffer a keyframe. If it can, that removes the wait for everyone,
   including mobile, at no bitrate cost. This is the question I would like answered first.
2. **Shorter I-frame interval on `-sub`** (today 50 frames = 3.3 s at 15 fps; 15 would be
   1 s). Camera-side, costs bitrate on the stream your warm tier records, so it needs a
   measurement on one camera before anyone touches the fleet. Not asking for it blind.
3. **`sprop-vps/sps/pps` in the main stream's SDP** so an HEVC consumer can bind its
   decoder before the keyframe. Minor; only trims the front of the HD wait.

**Not asking:** anything about frame rate. 15 fps is set on the cameras and stays there.

## Wanted back

- Answer to (1): can a fresh RTSP consumer start at the last keyframe, and if so what it
  costs you. If not, whether (2) is measurable on one camera and what the bitrate delta is.
- If neither is on the table, say so — then the HD wait is a fact we document, not a bug.

Reply path is in the preface. Measurement details and the trace stages live in
`docs/perf/2026-09-08-live-ttff/README.md` in our repo.
