# START HERE — Windows laptop session (continue the port: W2 + W3)

**You are Claude Code running on a Windows 10/11 laptop.** Your job is to finish the Cilex
Watchtower Windows port — the **on-hardware** phases that could not run on the Linux dev box:
**W2 (runtime bring-up)** then **W3 (parity soaks)**, and general Windows testing after.

This file is the orchestrator. The detailed specs live in other in-repo docs (below) — **there is
no local `.claude` memory on this machine; the repo docs are the source of truth.** Read this
whole file first, then work top-to-bottom.

---

## Quickstart — check out + run Watchtower on Windows (copy-paste PowerShell)
No build toolchain needed — this pulls the CI-built exe. The laptop must be on the `192.168.1.x`
LAN (backend at `.79`); a real GPU is needed for the hardware-decode gate (any machine works for
the "does it launch" check).
```powershell
# 0. Prereqs (skip any already installed)
winget install --id Git.Git -e
winget install --id GitHub.cli -e
gh auth login                              # GitHub.com → HTTPS → login via browser

# 1. Clone the repo (path without spaces)
git clone https://github.com/romayankin/cilex-watchtower.git C:\wt\cilex-watchtower
cd C:\wt\cilex-watchtower

# 2. Download the latest GREEN Windows build (portable = exe + full runtime)
$run = gh run list --workflow windows.yml --status success --limit 1 --json databaseId --jq '.[0].databaseId'
gh run download $run -n watchtower-portable -D C:\wt\portable
#   (installer instead: gh run download $run -n watchtower-setup -D C:\wt\setup)

# 3a. Run it — autologin to the live wall
cd C:\wt\portable ; $env:WT_CV_AUTOLOGIN = "1" ; .\watchtower.exe

# 3b. …or the automated W2 bring-up harness (launch + HW-decode + RSS + crash checks)
pwsh C:\wt\cilex-watchtower\packaging\windows\w2-bringup.ps1 -Dist C:\wt\portable -Seconds 45
```
If `.\watchtower.exe` opens a window and shows the camera wall, the port fundamentally works —
proceed to the W2 gates (Section 5). If it doesn't launch, that's the first thing to fix.

---

## 0. What already happened (context)
Watchtower is a native **Qt 6.12 / QML / C++** surveillance VMS operator client; it's a client of
the **cilex-vision** backend (cameras have no storage). It runs on Linux today. The Windows port so
far, all committed to `main` on `github.com/romayankin/cilex-watchtower`:
- **W0 done** — source made MSVC-compilable (Linux-only bits `Q_OS_*`-guarded; PSAPI RSS + SEH
  crash filter for Windows).
- **W1 done** — **GitHub Actions builds `watchtower.exe` + an installer on every push**
  (`.github/workflows/windows.yml`, `windows-2022`, Qt 6.12 msvc2022_64 + GStreamer 1.26.11).
  This proved the MSVC compile/link. **You can just download the built artifact — no toolchain
  setup needed to START.**
- **W4 done** — per-user NSIS installer + LGPL license notices; signing = **unsigned** (internal).
- **W2 + W3 = YOUR job now.** W2 prep is done for you: a runtime audit, fixes, a turnkey harness,
  and a step-by-step runbook.

**The single most important unknown:** nobody has confirmed the app even *launches* on Windows yet
— only that it builds. Your first 20 minutes settle that.

## 1. Read these repo docs before doing anything (in order)
1. `docs/plans/2026-07-04-windows-port-plan.md` — the whole plan + phase status.
2. **`docs/plans/windows-port/W2-RUNBOOK.md`** — your primary script for W2 (gate-by-gate, with
   expected output + the known issues). This is the doc you execute.
3. `docs/plans/windows-port/W2-runtime-bringup.prompt.md` — the W2 spec/intent.
4. `docs/plans/windows-port/W3-parity-soaks.prompt.md` — the W3 spec.
5. `packaging/windows/README.md` — build/deploy + how to fetch CI artifacts.
6. `packaging/windows/w2-bringup.ps1` — the automated W2 harness you'll run.

## 2. Environment facts (NOT in the repo — you need these)
- **Backend:** `http://192.168.1.79:8000`, login `admin` / `admin`. **This laptop MUST be on the
  `192.168.1.x` LAN** to reach the backend AND the cameras. Verify first (Section 3).
- **Cameras:** `.106` = `hiwatch-083bc14eff9a` (main-stream, has heavy multi-thousand-fragment
  days — best for TTFF/decode tests); `.201` = `hiwatch-0c75d29549ad`. ~32 cameras total.
  The backend URL is already the app's default (`WT_CV_URL` overrides it).
- **Repo:** `github.com/romayankin/cilex-watchtower`, branch `main`. You (romayankin) own it, so
  `git push` and `gh` should be authenticated on this laptop.
- **Camera-IP lockout gotcha:** don't hammer cameras directly from a new client IP — go through
  the backend proxy paths (the app already does). Repeated direct probes lock a camera out.

## 3. Prerequisite check (do this first, before anything else)
Run these and confirm each:
```powershell
# on the right LAN + backend reachable?
Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 http://192.168.1.79:8000/ | Select StatusCode
# tools present?
git --version ; gh --version ; gh auth status
# GPU present (the HW-decode gate needs a real GPU)?
Get-CimInstance Win32_VideoController | Select Name, DriverVersion
# Windows build
[System.Environment]::OSVersion.Version ; (Get-ComputerInfo).WindowsProductName
```
If the backend isn't reachable → you're on the wrong network; stop and tell the operator. If `gh`
isn't authed → `gh auth login` (needed to download artifacts, or use the Actions web UI instead).

## 4. Get the build — TWO paths (start with A)
**Path A — download the CI artifact (fast, no toolchain). Do this first.**
```powershell
gh repo clone romayankin/cilex-watchtower ; cd cilex-watchtower   # if not already cloned
gh run list --workflow=windows.yml --limit 5                      # find the latest GREEN run id
gh run download <run-id> -n watchtower-portable -D C:\wt\portable  # the exe + full runtime
# (or download watchtower-setup for the installer; or grab both from the Actions web UI)
```
The `watchtower-portable` zip contents unzip to a runnable `watchtower.exe` + Qt + GStreamer +
ffmpeg + `licenses\`. No build needed.

**Path B — local build (only if you'll iterate on code fixes a lot).** Full toolchain per
`packaging/windows/README.md`: aqt Qt 6.12 msvc2022_64, GStreamer 1.26.11 MSVC (runtime+devel),
MSVC + Ninja + pkgconf, then `cmake --preset windows` + `cmake --build build-windows` +
`deploy.ps1`. Heavier setup; only worth it if the CI round-trip (~8 min/push) becomes a bottleneck.

## 5. Run W2 (follow W2-RUNBOOK.md gate-by-gate)
Start with the automated harness, then the interactive gates:
```powershell
cd C:\wt\portable
pwsh <repo>\packaging\windows\w2-bringup.ps1 -Dist . -Seconds 45          # launch + HW-decode + RSS + crash
pwsh <repo>\packaging\windows\w2-bringup.ps1 -Dist . -HwOnly -Seconds 45  # enforce hardware decode
```
It prints PASS/FAIL for: window rendered, no `[WT-FATAL]`, LIVE wall hardware-decodes (`d3d11`,
no SOFTWARE), pipelines built, RSS bounded — and lists the available ffmpeg H.264 encoders.
Then do the eyes-on gates in the runbook: live wall + **Task Manager → GPU → Video Decode**,
heavy-day playback (TTFF <1 s, scrub, roll-over), export STD/HIGH, snapshot, fullscreen/DPI,
sleep→resume.

**Windows note baked into the harness:** a WIN32 GUI app doesn't write `qInfo()` to stdout, so the
harness sets `QT_FORCE_STDERR_LOGGING=1` to capture the `[WT-*]` trace. If you launch by hand and
see no trace, set that env var.

## 6. Known issues you WILL hit (not surprises — these are the fix targets)
1. **Compress/burn export fails** — the LGPL ffmpeg we bundle has no `libx264` (GPL). Run
   `ffmpeg -hide_banner -encoders | findstr 264` in the dist to see what IS there (likely
   `h264_mf` = Media Foundation, LGPL-clean; maybe `libopenh264`). Fix in
   `src/models/ClipTranscoder.cpp` `start()`: on Windows use `h264_mf`/`libopenh264` with that
   encoder's rate-control opts (NOT `-preset/-crf`, which are libx264-only). Plain STD/HIGH export
   (direct download, no ffmpeg) is unaffected. The font path + filtergraph escaping is already
   Windows-guarded (compile-verified only — confirm the overlay renders).
2. **Live-wall SOFTWARE decode or `live_pipelines=0`** — the bundled GStreamer plugin subset
   (`deploy.ps1`) may be incomplete. `gst-inspect-1.0 d3d11` (from the GStreamer install) shows
   what's available; widen the plugin list in `deploy.ps1` and re-document it in
   `packaging/windows/licenses/NOTICE-GStreamer.txt` (CI drift-checks that they match).
3. **Custom manifest extras deferred** — Qt's manifest gives DPI + Win10/11 compat + asInvoker;
   long-path + UTF-8 code page aren't re-added yet (W4 note, low priority).

## 7. Fix → verify loop
- **Small code/script fix:** edit → `git commit` + `git push` → the windows workflow rebuilds
  (~8 min) → `gh run download` the new artifact → re-test. No local toolchain needed.
- **Fast iteration:** set up the local build (Path B) so you can `cmake --build` + `deploy.ps1`
  locally in ~1 min instead of the CI round-trip.
- Either way, after a source fix, confirm the **windows CI stays green** (`gh run watch`).

## 8. Run W3 (after W2's gates are green)
Follow `docs/plans/windows-port/W3-parity-soaks.prompt.md`:
- Port the soak supervisor `docs/perf/soak-tools/night_soak_supervisor.sh` → a PowerShell
  `night_soak_supervisor.ps1` (same heartbeat-stall logic; keep the export-sidecar mtime guard).
- Replace the Linux gdb-on-wedge capture with **procdump** (`procdump -ma <pid>` before kill).
- The QML soak harnesses (`WT_NIGHT_SOAK`, `WT_SEEK_SPAM`, `WT_GUARD_SOAK`, `WT_SMOOTHTEST`) run
  unchanged — they're env-gated QML.
- Overnight soak on Win10 AND Win11: pass bar = the Linux bar (0 crashes/wedges, RSS bounded,
  seek/export matrices green). Confirm the 2026-07-03 GC-wedge fix holds (marshal ~1 ms, no GUI
  heartbeat gap >2 s) and click-spam coalescing works.

## 9. Working conventions (match the repo)
- **Auto-commit + push** completed AND verified changes straight to `main` (Conventional Commits +
  the `Co-Authored-By` / `Claude-Session` trailers your harness provides). Don't ask first.
- **File every Windows-specific finding** as its own dated `docs/perf/2026-<MM-DD>-win-<topic>.md`
  (house style: what/measured/fix). Fix small things in place; anything structural gets its own note.
- Update `docs/plans/2026-07-04-windows-port-plan.md` + the W2/W3 prompt status as phases close.
- Keep PowerShell clean of the `$var:` parse gotcha (use `${var}:`) and put spaces around `-eq`/
  `-gt` operators — both bit the W1 CI work.

## 10. Definition of done
- **W2:** app launches; live wall hardware-decodes on this GPU (`[WT-DEC] ... (hardware)`,
  `WT_HW_ONLY` clean); heavy-day playback + scrub + roll-over work; export STD/HIGH work
  (compress/burn fixed or tracked); no GUI stall over a 30-min `WT_SMOOTHTEST` run.
- **W3:** overnight soak green on Win10 + Win11 (0 crashes/wedges, RSS bounded), any wedge caught
  with a procdump.
- Then **W5** (the multi-GPU acceptance matrix) is the last phase — borrow/rotate machines.

**First action:** run Section 3 (prereq check). If the backend is reachable and `gh` is authed,
go to Section 4 Path A and get the artifact. Report what the app does on first launch — that's the
milestone everything else depends on.
