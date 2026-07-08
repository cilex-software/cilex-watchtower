# Windows W2/W3 session-2 — results (2026-07-08)

Second on-hardware Windows session (after the 2026-07-06 W2 bring-up + 2026-07-07 W3 parity). Ran
against the **fresh `f725784` CI artifact** (run `28944878755` — the i18n + frame-step + VIEW-ISSUE
build), on Win10 Pro 19045, **GTX 1070** + Intel UHD 630, backend cilex-vision over **Tailscale**
(`http://100.107.51.72:8000`; the `192.168.1.79` LAN is not reachable from this box — Wi-Fi AP
client-isolation, TCP 8000 + ICMP both fail; Tailscale peer `active; direct`).

## TL;DR
| Task | Result |
|---|---|
| **A. W2 core gates re-baseline** | ✅ GREEN — launch, d3d11 HW decode, live pipelines, bounded RSS (same as 07-06) |
| **B. Frame-stepping on d3d11** | ✅ GREEN — `[STEPT] wrongWay=0 fails=0 back p50=0ms` on HEVC 1440p. `docs/perf/2026-07-08-frame-step-windows.md` |
| **C. Russian i18n** | ✅ EN OS-default + RU renders & persists (embedded `.qm` loads on the MSVC build) |
| **D. Export (known-issue #1)** | 🔧 FOUND + FIXED a real regression — ffmpeg 7.1.3 rejects the drawtext path escaping. `docs/perf/2026-07-08-win-export-drawtext-ffmpeg71.md` |
| **E. W3 overnight soak** | ▶ launched (see §E) |

## A. W2 core gates — re-baseline GREEN
`w2-bringup.ps1 -Dist C:\git\portable\2026-07-08 -BackendUrl http://100.107.51.72:8000`:
- window rendered — **PASS** (confirmed by a direct OS screenshot; the in-app `grabWindow()` hook
  didn't fire on this dual-GPU box, a cosmetic Qt grab quirk — the wall paints fine, see below)
- launched without crash — **PASS** (`[WT-FATAL] count=0`)
- **LIVE wall hardware-decodes** — **PASS** (`[WT-DEC] using d3d11h264dec (hardware)`, hardware=4 software=0)
- live pipelines built — **PASS** (22 samples `live_pipelines>=1`, frames→1023 in the 45 s run)
- RSS bounded — **PASS** (max 324 MB)

**HW decode double-confirmed at the GPU-counter level** (the Task-Manager-GPU eyes-on gate): sampling
`\GPU Engine(*)\Utilization Percentage` for the watchtower pid during the live wall →
**Video-Decode engine max 5.33% / avg 3.6%** (2 live H.264 720p tiles). Not just the log — the GPU's
decode engine is actually busy.

**Wall paints** (OS screenshot, `w2-out-2026-07-08/wall-live.png`): full UI, build tag `f725784e`,
header **ONLINE 2 / OFFLINE 31 / NOT REC 1**, two live tiles decoding real video (`.201` DS-I402 and
`.67` with the new **RECORDING STALLED → VIEW ISSUE** banner rendering — the `f725784` feature), the
rest NO SIGNAL (the unplugged fleet). Matches the real fleet state.

## C. Russian i18n — EN default + RU render/persist verified
- **EN OS-default**: registry has no `ui/language` override → app follows `QLocale::system()`
  (Windows display language `en-US`/`en-GB`) → English chrome. Confirmed on the wall screenshot.
- **RU renders + persists**: set the persisted override (`HKCU\Software\Cilex Vision\Watchtower\ui
  \language = ru`, exactly what the in-app selector writes via `QSettings`) → relaunch → Cyrillic
  chrome (`w2-out-2026-07-08/wall-ru.png`): **ОНЛАЙН · ГРУППЫ · ВИДЫ · СОБЫТИЯ · СОСТОЯНИЕ**, header
  **ОНЛАЙН 2 / НЕ В СЕТИ 31 / НЕТ ЗАПИСИ 0**, search **Поиск камер…**. No `[i18n]` fallback warning —
  the embedded `.qm` loads on the MSVC build. Partial-translation state as documented (some chrome
  still English). Removing the key reverts to English (OS default) on next launch — persistence path
  proven both directions.
- **Live in-app switch (no restart)**: the `Language.setLanguage()` → `engine.retranslate()` path is
  OS-independent Qt, already Linux-verified, and writes the same `ui/language` key exercised above.
  Not re-driven via the avatar→menu→Preferences popup here (the autologin avatar monogram isn't a
  reliable blind-click target); the two **Windows-specific** unknowns (OS-locale default, `.qm` loads
  on MSVC) are both closed.

## D. W2 eyes-on gates
- **HW decode / GPU engine** — ✅ (see §A).
- **Playback path (QMediaPlayer/FFmpeg D3D11VA)** — exercised via the frame-step run (task B): day
  open `session_ready dt=512ms frags=1813`, bounded window 252 frags, HEVC 1440p ~20fps stepped clean
  (0 fails). Historic playback opens fast even over Tailscale. Click-spam scrub parity was covered
  2026-07-07 (`2026-07-07-windows-soak-results.md`, shape-green).
- **Export STD/HIGH (direct download)** — unaffected by the ffmpeg issue; the soak dispatches backend
  HIGH exports cleanly (`[XSOAK] started job=…`).
- **Export compress/burn (libopenh264)** — 🔧 **found a real regression + fixed it.** The CI bundle
  moved to **FFmpeg 7.1.3**, whose filtergraph parser rejects the single-backslash drive-letter escape
  `escFilterPath()` emitted (`fontfile=C\:/… → exit -22`), silently breaking every overlay export.
  Measured the app's exact full filtergraph fail on 7.1.3 and the two-level escape `\\:` succeed
  (overlays render correctly — `w2-out-2026-07-08/burn-frame.png`). Fixed in
  `src/models/ClipTranscoder.cpp` (`bacfe48`); details in
  `docs/perf/2026-07-08-win-export-drawtext-ffmpeg71.md`. **App-UI drawer re-test owed after the CI
  rebuild.**
- **Multi-monitor / mixed-DPI, sleep→resume** — genuinely eyes-on / hands-on; not run this session
  (single-display remote box). Owed at the box.
- **30-min `WT_SMOOTHTEST`** — the overnight soak runs a continuous `WT_SMOOTHTEST=999999` heartbeat
  (supersedes the standalone 30-min gate); heartbeat health is judged over the whole night (§E).

## E. W3 overnight soak
Launched `night_soak_supervisor.ps1` on the fresh build, pinned to the heavy historical day
(`WT_SOAK_FIX_CAM=192.168.1.106 WT_SOAK_FIX_DAY=2026-06-22`, ~5.2 h / 4760 frags — the dense
open/seek/export churn that stresses the 2026-07-03 GC-wedge path). procdump present
(`C:\wt\procdump\procdump64.exe`) for wedge capture; AC sleep already disabled (standby idle = never).
4-min smoke first (`crashes=0 hangs=0 samples=16 exports_sized=7`, RSS 541→686 MB, no incidents),
then the **overnight run is live** (spawned detached, `until Thu 07:00`, ~15.5 h; armed + heartbeating
on the 06-22 footage, RSS ~614 MB). Logs: `%USERPROFILE%\watchtower-soak\night_soak\`
(`supervisor.log`, `incidents.log`, `samples.csv`, `export_sizes.log`).
Endurance verdict + morning triage: <!-- SOAK PENDING: crashes/hangs/RSS-trend/heartbeat-gaps from incidents.log + samples.csv -->

Note: the export sidecar sweep only touches clips created at/after supervisor start (the operator's
pre-existing clips are safe). Backend recording resumed on `.67`/`.201` today ("OUTAGE OVER" — Linux
session), but `.106` stays unplugged, so the pinned historical day remains the right dense target.

## Tooling (this session, next to the portable dir — not in the repo)
`C:\git\portable\` : `capture-app.ps1` (OS screenshot of the wall), `run-steptest.ps1`
(`WT_STEPTEST`/`WT_STEPSPIKE` runner), `gpu-decode-check.ps1` (per-pid GPU Video-Decode sampling).
Artifacts under `C:\git\portable\w2-out-2026-07-08\`.
