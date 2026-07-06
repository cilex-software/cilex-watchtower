# W2 on-hardware runtime bring-up — results (2026-07-06)

First confirmation that the Windows port **runs**, not just builds. Executed on the Windows box
(`desktop--alienware`, Windows 10 Pro 19045, **NVIDIA GTX 1070** + Intel UHD 630) against the
live cilex-vision backend. Two packaging/source defects had to be fixed to get a green harness;
each has its own note (linked below).

## How W2 was driven without being on the site LAN

The runbook assumes the box sits on `192.168.1.x` next to the backend + cameras. This box was on a
different LAN (`192.168.0.104`), so `192.168.1.79:8000` was unreachable. Instead the backend was
reached **over Tailscale**: peer `cilex-vision-server` = `100.107.51.72`, `active; direct`, RTT
**6–16 ms**. Everything ran with `WT_CV_URL=http://100.107.51.72:8000` (admin/admin autologin).

Key finding: **live video streams proxy through the backend**, so reaching only `:8000` over
Tailscale is sufficient — no direct `192.168.1.x` camera access is needed. Remote W2 testing is
therefore fully possible; only the wall-clock TTFF timing gates are internet-bandwidth-sensitive.

## Result — W2 automated harness GREEN

`packaging/windows/w2-bringup.ps1 -Dist C:\wt\portable -BackendUrl http://100.107.51.72:8000`:

| check | result |
|---|---|
| window rendered (screenshot) | **PASS** — full Watchtower UI paints (LIVE/GROUPS/EVENTS chrome, 4×4 layout, live-events feed) |
| launched without crash | **PASS** — `[WT-FATAL] count=0` |
| LIVE wall hardware-decodes (d3d11) | **PASS** — `hardware=2 software=0`, `[WT-DEC] using d3d11h264dec (hardware)` |
| live pipelines built | **PASS** — `live_pipelines>=1`, frames climbing (462 in a 45 s manual run) |
| RSS bounded | **PASS** — plateau ~330–346 MB, stable |

The bring-up required two fixes before this was green:
- **GStreamer d3d11 decode bundle** — `docs/perf/2026-07-06-win-gstreamer-d3d11-bundle.md`
- **Compress/burn export encoder** — `docs/perf/2026-07-06-win-export-encoder.md`

## Harness portability fix (PowerShell 5.1)

`w2-bringup.ps1` was UTF-8-without-BOM containing em-dash (`—`) characters. The docs tell operators
to run it with `pwsh` (PS7, UTF-8 default), but a no-toolchain Windows box may only have **Windows
PowerShell 5.1**, which mis-decodes the file (mojibake `â€"`) and fails to parse. Folded all
non-ASCII punctuation to ASCII; it now parses + runs under both 5.1 and pwsh. (`deploy.ps1` and
`fetch-gstreamer-windows.ps1` share the same em-dashes but run via `pwsh`/GitHub Actions, so they
are not a live blocker — left as-is for now.)

## Remaining W2 gates (eyes-on, not yet done)

- Multi-camera wall visual + Task Manager → GPU → Video Decode engine active.
- Heavy-day playback (.106): TTFF, scrub, roll-over (QMediaPlayer/FFmpeg D3D11VA path).
- Export matrix through the UI: STD/HIGH (direct) + compress/burn (the libopenh264 fix).
- Fullscreen / mixed-DPI, sleep→resume, 30-min `WT_SMOOTHTEST` heartbeat.

Note: over Tailscale the camera-list load is slower than on-LAN — the 6 s bring-up screenshot
caught the "Loading cameras…" spinner before the grid populated; the decode run right after
confirmed streams flow. On the site LAN this load is not a concern.
