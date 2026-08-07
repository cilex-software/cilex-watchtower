# Windows station bring-up — Intel UHD 730 decode baseline (`wt-sm-vnutri-01`)

_Measured 2026-08-07 on the guard-booth station itself. Every number below was
observed on this box; the one piece of arithmetic is labelled as arithmetic._

Our only prior Windows HW-decode measurement was on a discrete GTX 1070
(`docs/perf/2026-07-08-win-w2w3-session2-results.md`). The booth PC has no
discrete card, so the 16-stream wall on an iGPU was genuinely untested. It is
now measured.

## The box

| | |
|---|---|
| host | `wt-sm-vnutri-01` (hostname matches CV's station row exactly) |
| OS | Windows 11 Pro, `10.0.26200` |
| CPU | Intel i5-12400, 12 logical cores |
| RAM | **2 × 16 GB in `DDR4-A1` + `DDR4-B1` → dual-channel populated**, Kingston `KF3200C16D4/16GX`, `ConfiguredClockSpeed = 2400` |
| GPU | Intel UHD Graphics 730, driver `32.0.101.6129` (2024-10-18) |
| display | 1920×1080 @ 60 Hz |

**The RAM is dual-channel — but the DIMMs are 3200-rated parts running at
2400 MT/s.** That matters for an iGPU, which has no VRAM of its own and eats
system memory bandwidth: dual-channel DDR4-2400 is ~38.4 GB/s where the same
sticks at their rated 3200 would give ~51.2 GB/s. It is headroom left on the
table, not a fault, and nothing below is bandwidth-starved — so this is a lever
to remember only if the wall ever does become bandwidth-bound.

## Build under test

`windows-latest` rolling prerelease asset `CilexWatchtower-0.1.0-setup.exe`,
sha256 `bd9a1f3c872d42b972ee613b4bff89660edd18153a4bd689b68c3d9983ce3dd2`,
release body: *"Rolling CI build of `4fcb90cd8dfaf1d283b19fee962d53b130b81419`"*.
The app's own footer renders `build 4fcb90cd`, so the running binary is
confirmed visually, not just by release metadata.

## What the fleet actually serves (measured, not assumed)

Probed with the bundled `ffmpeg.exe` against go2rtc over the tailnet, camera
`hiwatch-083bc14effd1` (`DS-I456Z(B)`, 192.168.1.147):

| rendition | codec | resolution | fps |
|---|---|---|---|
| main | **HEVC (Main)** | 2560×1440 | 15 |
| sub  | H.264 (Main) | 1280×720 | 15 |

Fleet: 39 cameras online — 20× `DS-I202(E)`, 8× `DS-I456Z(B)`, 4× `DS-I453M(C)`,
4× `DS-I402(D)`, 3× `DS-I259M(C)`.

**The wall is never HEVC.** `qml/CameraTile.qml:132` reads
`useMainStream: gridMode ? false : Settings.defaultStreamHd`, so grid tiles are
hard-wired to the sub stream. Main-profile HEVC is reached only via single-camera
detail / fullscreen with HD selected, or a merged-cell HD promotion —
i.e. exactly the "promotions" CV flagged, and never the baseline 16 tiles.

## Measurement 1 — the 16-tile wall (16 × H.264 720p sub)

4×4 layout, "1–16 of 39", all tiles decoding real video (screenshot-verified: no
green tiles, no black). App window 1440×900. `WT_TRACE=1`.

| metric | value |
|---|---|
| GPU **VideoDecode** engine | **9.2 %** avg (min 9.0, max 9.5) |
| GPU **3D** engine | **35.7 %** avg (min 34.4, max 36.8) |
| process CPU | 34.8 % of one core = **2.9 % of 12 logical cores** |
| system-wide CPU | 5.4 % |
| RSS | 804 MB |
| threads / handles | 124 / 2462 |
| `[WT-MEM]` | `live_pipelines=16`, ~220 frames/s aggregate (~13.8 fps/tile) |

## Measurement 2 — one main-profile HEVC 1440p stream

Same box, single-camera detail forced to HD (`Settings.defaultStreamHd`, stored
as `REG_DWORD` at `HKCU\Software\Cilex Vision\Watchtower\video`), `WT_HW_ONLY=1`.

| metric | value |
|---|---|
| GPU **VideoDecode** engine | **2.5 %** avg (min 1.6, max 2.8) |
| GPU **3D** engine | **21.3 %** avg (min 17.5, max 22.8) |
| process CPU | 30.2 % of one core = 2.5 % of 12 logical |
| RSS | 465 MB |

## Decoder binding — hardware, proven twice

```
[WT-DEC] video/x-h264 candidate d3d11h264dec (hardware) -> try
[WT-DEC] using d3d11h264dec (hardware)
[WT-DEC] video/x-h265 candidate d3d11h265dec (hardware) -> try
[WT-DEC] using d3d11h265dec (hardware)
```

- **94 `[WT-DEC]` lines, every one `(hardware)`. Zero `(SOFTWARE)` lines.**
- Both runs were under **`WT_HW_ONLY=1`**, which makes `decodebin` *refuse* any
  non-hardware decoder rather than fall back. **Zero refusals, zero
  `not-negotiated`, zero missing-plugin errors** — so there was never a silent
  software fallback hiding behind a healthy-looking wall.
- Log lines alone would not have been proof, so it is confirmed at the GPU
  counter level too: the VideoDecode engine is measurably busy (9.2 % / 2.5 %),
  i.e. the fixed-function block really is doing the work.

## The conclusion that matters

**Decode is not the constraint on this iGPU — compositing is.**

The expectation going in (letter §3) was that a 16-stream wall might be
decode-bandwidth-bound. Measured, the decode engine sits at **9.2 %** while the
**3D engine runs ~4× higher at 35.7 %**. Quick Sync is barely awake.

Consequence for the planned lever: `WT_MAX_DECODES` (fewer live tiles +
snapshots for the rest) does reduce both engines, but it is aimed at the engine
that is not under pressure. If this wall ever does struggle, **look at the 3D /
scene-graph cost first** — tile count and rendered pixel area — not at decode.

**Arithmetic, NOT measured:** one HEVC 1440p stream costs 2.5 % of the decode
engine, so 16 simultaneous main-profile HEVC tiles would be ~40 % of it. That
is a straight multiplication and assumes perfect linearity; it has not been run.
What *is* measured is that a single promotion is nearly free.

## Caveats — read these before quoting the numbers

1. **These cameras are 15 fps.** A 25–30 fps fleet would roughly double the
   decode figures.
2. **The wall was measured in a 1440×900 window, not fullscreen 1920×1080.**
   The 3D number is the pixel-bound one, so it will rise fullscreen. The decode
   number will not.
3. Sub streams are ~106 kbps (CV's figure, not re-measured here).
4. Single-station measurement; no second box to cross-check against.

## Reproducing

```
# in %USERPROFILE%\.config\watchtower-warden\warden.conf
APP_ENV=WT_CV_URL=http://100.107.51.72:8000,WT_TRACE=1,WT_HW_ONLY=1
```
then restart through Warden and read `[WT-DEC]` / `[WT-MEM]` from
`%APPDATA%\Cilex Vision\Watchtower\flightrec\watchtower.log`.

`WT_TRACE` is deliberately **off** in this station's production config: `[WT-MEM]`
every 2 s is ~43k lines/day, which would churn the flight recorder's 10 MB × 5
ring and evict the lines that actually matter after a crash.
