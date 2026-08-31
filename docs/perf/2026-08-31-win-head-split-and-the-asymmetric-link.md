# head_split cuts segment 0 by 5x, and the wire is directionally asymmetric — booth measurements

    Station:  wt-sm-vnutri-01 (guard booth, Win 11), offscreen harness, WT_TRACE=1
    Build:    1.1.262 / 1.1.263 (head_split default-on, deployed)
    Backend:  http://192.168.1.79:8000 over the direct LAN link
    Date:     2026-08-31, 03:30-04:30 local
    Camera:   192.168.1.126

Second half of the night. The first half is
`2026-08-31-win-session-creation-server-timing.md`; this covers what changed after CV
answered, and it contains the two numbers that now matter.

## 1. head_split — it works, and it is the largest single win of the night

`head_split` is a boolean on `POST /review/sessions` that CV shipped 2026-07-18 for
Cilex Pro Mobile. A window whose head lands **mid-segment** gets fragment 0 served as a
trimmed ~1.2 s piece instead of a whole ~24 s segment. Watchtower had never sent it; the
Linux dev box found it and argued it should be measured before any transfer-framing work.
They were right.

### 1a. First attempt: it engaged and then 503'd forever

    head_split ON    frag0s= 1.200   seg/0.ts -> 503 x13, 64-byte bodies, NO first frame
                     frag0s= 1.200   seg/0.ts -> 503 x11, NO first frame
                     frag0s=33.223   seg/0.ts -> 200, first_frame 27,754 ms
    head_split OFF   frag0s=20.927   seg/0.ts -> 200, first_frame 27,873 ms
                     frag0s= 9.927   cached,   first_frame 18,143 ms
                     frag0s=27.924   seg/0.ts -> 200, first_frame 20,202 ms

`frag0s` is fragment 0's duration, added to the `session_ready` line so engagement is
observable rather than inferred. **The failure tracked the TRIM, not the flag** — the
third run had the flag on, happened to land on a boundary so nothing was trimmed, and
played normally. Every open where `frag0s=1.200` died; every open where it did not, lived.

CV root-caused it from that one signal within the hour: a single ffmpeg running **two
libx264 encoders at source resolution**, and review sources are 2560×1440 HEVC, so the
cgroup killed it — memcg OOM, anon-rss 1,276,060 kB against a 1,536 MB cap, surfacing as
`head-pieces failed rc=-9`. It had only ever been exercised on the mobile ladder, where
the source is a small rendition and two encoder contexts fit. They now run two sequential
passes.

**This is why it was not shipped default-on when it first "worked".** Enabling it during
that window would have taken historic playback away from the guards entirely.

### 1b. Re-measured after their fix — and shipped

Six instant opens, arms alternating:

| arm | frag0 duration | seg0 | bytes |
|---|---:|---:|---:|
| head_split | 1.200 s | **1,307 ms** | 1,419,776 |
| head_split | 1.200 s | **742 ms** | 1,168,420 |
| control | 18.927 s | 5,159 ms | 7,432,016 |
| control | 7.927 s | 5,693 ms | 7,425,248 |
| control | 25.924 s | 4,315 ms | 7,160,920 |

**2/2 engaged opens clean, zero 503s. Segment 0 falls from ~5,050 ms to ~1,000 ms.**

Throughput was identical in both arms — 12.9 Mbit/s on the head_split body, 12.8 on the
control's — so the win is purely fewer bytes and does not depend on the link improving.

### 1c. CORRECTION: the trimmed piece has to be BUILT, and that cost is the new variable

The two samples above (742 and 1,307 ms) happened to catch a warm head piece. A wider run
with `hdr=` separated out — `hdr` is our time to response headers, which contains CV's
build — shows the real shape:

    seg0 total 4,802 ms  =  BUILD 4,229 ms  +  transfer   573 ms   (1,326,904 B @ 18.5 Mbit/s)
    seg0 total 1,409 ms  =  BUILD   572 ms  +  transfer   837 ms   (1,437,448 B @ 13.7 Mbit/s)

**head_split trades a ~4,600 ms transfer for a ~700 ms transfer PLUS a 572-4,229 ms
server-side build.** CV measured the same shape on their bench: 5.4 s cold, then 40 ms.

So the honest statement is not "segment 0 falls to ~1,000 ms". It is:

- **warm head piece → a large win** (~1,400 ms against ~5,050 ms)
- **cold head piece → roughly a wash** (~4,800 ms against ~5,050 ms)

A guard opening a moment nobody has opened before pays the build. A guard re-opening,
or opening near a previously-opened instant, does not. Whether that is a good trade in
production depends on how often review opens are novel — unmeasured here, and worth
knowing before anyone calls this a four-second win.

It also relocates the problem rather than removing it: the build is CV-side ffmpeg work
with the same cold/warm character as their session `index`, which is the other thing
holding this path up.

Shipped default-on in 1.1.263 and deployed. `WT_PB_NO_HEAD_SPLIT=1` reverts; if historic
playback ever dies with repeated 503s on `seg/0.ts`, that is this.

**Scope, so nobody over-expects it:** head_split only applies to a window head landing
mid-segment — event opens and scrub-to-moment. A plain day click starts at
`firstMs - 2000`, before the first footage, where the head lands on a boundary and there
is correctly nothing to trim. CV also cautioned that piece A is 1.17-1.42 MB at 1440p,
not the 26 KB measured on the mobile ladder in July. The gain is ~5x on bytes, not 500x.

## 2. The wire is directionally asymmetric — and this was not predicted

CV's §5 objection was correct and is accepted: session bodies are ≤92 KB, segments are
6-14 MB, and a 92 KB body over an 8 ms RTT never leaves TCP slow-start. Comparing them
compared two different measurements, and the "31-41 vs 12-15 Mbit/s asymmetry" reported
earlier in the night is **withdrawn as framed**.

They asked for an app-independent number. Their iperf3 server was already listening:

    CV -> booth (the direction segments travel)   30.6 Mbit/s   618 retransmits
    booth -> CV                                   93.0 Mbit/s     0 retransmits

10 s each way, no HTTP, no proxy, no application code.

**Neither of us predicted this.** CV expected raw bulk near 13 Mbit/s, which would have
exonerated every layer both sides own and closed the question. Instead:

- The wire is capable of **93 Mbit/s**, so it is not a duplex mismatch, not the cable,
  and not a 100 Mbps line-rate ceiling. (Local NIC: 100 Mbps full duplex, 14 receive
  errors lifetime, 0 outbound discards.)
- Toward us it manages **30.6 Mbit/s and loses enough to trigger 618 retransmits in ten
  seconds.** Loss is what holds a single TCP stream down, and it is strictly directional.

So the split is three ways, not two:

    93.0 Mbit/s    what the wire can do
    30.6 Mbit/s    what it does toward us, with loss       <- infrastructure, not code
    12-15 Mbit/s   what an HTTP segment body achieves      <- still ~2x below even that

The remaining 2x is not attributed here. It could be congestion control reacting to the
same loss, since a lossy path punishes a fresh connection harder than iperf's warmed
stream. What is established is that **the 30.6-vs-93 gap is real, directional, and
outside both codebases.** Raised with the operator as an infrastructure item — a switch
port, a cable, or a duplex mismatch upstream of this NIC.

## 2a. Current-state run, 8 opens — and head_split is a WASH at this hour

Eight instant opens with everything tonight in place (FAST OPEN, read-ahead hold, CV's
Q1 bound, head_split default-on), 04:40-05:10:

    session   12,664  15,194   5,235  11,728      -  11,333  11,126   9,899   median ~11,300 ms
    TTFF      21,556  20,270  22,191  14,460  22,104  25,336  17,830  20,398   median ~20,900 ms

**CV is far colder now than it was at 03:30**, when the same code produced sessions of
900-1,700 ms and one open at 828 ms. This run measures their current state, not ours.

head_split segment 0, engaged opens (`frag0s=1.200`):

    491   1,409   4,802   6,431   6,472 ms      median 4,802 ms

against a control of ~5,000 ms for a full ~7.4 MB segment. **At this hour head_split is a
wash** — the build cost (§1c) has swallowed the transfer saving, and two samples (6,431,
6,472) are worse than a plain full-segment fetch.

Left ON because the cold case is roughly parity and the warm case is a large win
(491 ms), and because the fix for the build is a packaging change on CV's side rather
than anything we can tune. But **"~4 seconds off the open" was wrong twice** — first from
a lucky warm pair, and it is not recoverable by re-measuring until the head piece is
precomputed. Anyone quoting a head_split number should quote the range, not a point.

## 3. What is left

    session creation   2,387 - 12,664 ms   CV — the largest remaining item
    segment 0          1,409 -  4,802 ms   improved, but see §1c: the win depends on
                                           whether the head piece is already built
      of which transfer   573 -    837 ms   (was ~4,642 — this part IS reliably fixed)
      of which CV build   572 -  4,229 ms   (new, and the reason the total still varies)
    decode                     ~220 ms     ours, already fast

With session creation at 300 ms this lands at ~1.3 s. With the download path also running
at its available 30 Mbit/s, ~870 ms — under the operator's bar.

**`shared_buffers` is the whole ballgame.** Still 128 MB against a `video_segments` table
that has grown to 4,473 MB, 58.7 % heap cache hit ratio — by CV's own numbers worse than
when they first raised it. They have said twice it is an operator decision they cannot
take. That, and the 618-retransmit download path, are the only two items left between a
guard and a first frame in under a second, and **neither of them is code.**
