# Windows 10/11 Port Plan — Cilex Watchtower (2026-07-04)

**Goal:** ship the existing native Qt/QML client on Windows 10 and 11, same repo, no fork.
**Qt: 6.12 (msvc2022_64) — MANDATORY** (operator directive 2026-07-04; matches the Linux
primary `build/`). 6.8.3 remains a **Linux-only** fallback (`build68`) — it is NOT a Windows
target. Execution is split into six **independently runnable phase prompts** in
`docs/plans/windows-port/` (W0–W5); each is self-contained in the house
`docs/perf/*.prompt.md` style.

## What already exists (do not rebuild)
- `packaging/windows/` scaffold (`9b192de`): `app.manifest` (Win10/11 compat, long paths,
  PerMonitorV2 DPI, UTF-8, UAC asInvoker), `watchtower.rc`, `fetch-gstreamer-windows.ps1`,
  `deploy.ps1` (windeployqt + GStreamer LGPL subset — **copy step TODO**), `installer.nsi`,
  README. `.ico` still TODO.
- `CMakeLists.txt` `if(WIN32)` block (`:222-246`): RC embed, `WIN32_EXECUTABLE`,
  `/MANIFEST:NO`, `deploy-windows` custom target. Inert on Linux.
- The qmlcachegen **bytecode-only workaround is version-gated, not platform-gated**
  (`CMakeLists.txt:61-62`, `Qt6_VERSION >= 6.12`) → carries to Windows 6.12 automatically.
- HW-decode instrumentation + enforcement: `WT_TRACE` → `[WT-DEC]` decoder log,
  `WT_HW_ONLY=1` refuses software decoders. Windows decoders = `d3d11h264dec`/`d3d11h265dec`
  (GStreamer d3d11, rank-based via decodebin — no code change needed).
- All soak/QA harnesses are env-gated QML → run unmodified on Windows
  (`WT_NIGHT_SOAK`, `WT_SEEK_SPAM`, `WT_GUARD_SOAK`, `WT_CAL_STRESS`, `WT_SMOOTHTEST`).

## Measured porting surface (audited 2026-07-04)
- **Only two files contain Linux-only code:** `src/main.cpp` (glibc `mallopt`/`malloc_trim`,
  `sys/prctl`, `execinfo` crash handler, `sys/resource`, `/proc/self/statm`) and
  `src/models/MemTelemetry.cpp` (`/proc` readers). Everything else is Qt/QML.
- `ClipTranscoder` invokes plain `"ffmpeg"` via QProcess (`ClipTranscoder.cpp:128`) →
  bundle `ffmpeg.exe` beside the app (Windows resolves the application dir first).
- Artifact paths already use `QStandardPaths` (Movies/Pictures) → `Videos\Watchtower` /
  `Pictures` on Windows with zero changes.
- `HlsProxy` listens on 127.0.0.1 only → loopback is exempt from Windows Firewall prompts.

## Qt 6.12-on-Windows: known carry-overs from the Linux migration
1. **qmlcachegen AOT SIGSEGV** → already neutralized cross-platform (bytecode-only, above).
2. **QML GC pathology (the 2026-07-03 HANG #1)** → a Qt ≥6.10-line issue, **mitigated at
   source level** (`d81d887`: primitive-row fragment payload). Windows inherits the fix;
   W3 re-verifies with the GUI-heartbeat method on Windows.
3. **Offscreen QPA SIGBUS** was Linux-offscreen-only; Windows offscreen behavior is
   UNKNOWN → no runtime gate in this plan relies on offscreen. CI (W1) gates on
   build+deploy artifacts; all runtime gates are on-hardware (W2+).
4. Per-open decode leak: same on both lines, bounded (~600 MB plateau) — not a port item.

## Phases (each = one prompt file, independently runnable)

| Phase | Prompt | Needs Windows HW? | Effort |
|---|---|---|---|
| W0 — MSVC compilability + preset + icon ✅ DONE 2026-07-04 | `windows-port/W0-msvc-compilability.prompt.md` | no | ~1 day |
| W1 — GitHub Actions CI → .exe/installer artifacts ✅ DONE 2026-07-04 (green; W0 MSVC compile proven) | `windows-port/W1-ci-pipeline.prompt.md` | no | ~2–3 days |
| W2 — Runtime bring-up (both video paths, HW decode) 🟡 CORE GATES GREEN 2026-07-06 on GTX 1070 (launch, d3d11 HW decode, live pipelines, RSS bounded; harness PASS, driven over Tailscale — see docs/perf/2026-07-06-win-w2-bringup-results.md). 2 fixes landed: gstd3d11 decode bundle + libopenh264 export. Remaining: eyes-on wall/playback/export-matrix/DPI/sleep + 30-min smoothtest | `windows-port/W2-runtime-bringup.prompt.md` | **yes (GPU)** | 1–2 wks |
| W3 — Parity soaks + PowerShell supervisor (procdump) ⏸ PARKED (after W2) | `windows-port/W3-parity-soaks.prompt.md` | yes | ~1 wk elapsed |
| W4 — Installer, LGPL/notices, signing decision ✅ DONE 2026-07-04 (installer + notices shipped; signing = operator decision, SIGNING.md) | `windows-port/W4-packaging-licensing.prompt.md` | build only | 2–3 days |
| W5 — OS/GPU acceptance matrix + sign-off | `windows-port/W5-acceptance-matrix.prompt.md` | yes | matrix-bound |

Total ≈ 4–6 weeks elapsed. The only genuinely uncertain phase is W2 (GStreamer D3D11
behavior across GPU drivers). W0–W1 need no Windows machine at all.

## Does CI build an .exe on every code change? — YES (W1 makes it so)
The W1 workflow (`windows-2022` runner) triggers **on every push** (and optionally every
PR); each run compiles `watchtower.exe` against Qt 6.12 msvc2022_64 and uploads two
downloadable artifacts: a **portable zip** (exe + Qt/GStreamer/ffmpeg runtime via
`deploy.ps1`) and the **NSIS installer**. Practical notes:
- **Path filters** (`paths-ignore: docs/**`, memory files) so docs-only commits don't burn
  a ~15–25 min Windows build.
- Artifacts live on the run page (default 90-day retention). A tagged **Release** step can
  additionally publish versioned installers on demand.
- Caching (aqtinstall Qt + GStreamer MSIs) cuts steady-state runs to ~10–15 min.
- If the GitHub repo is private: Windows runners bill at a 2× minutes multiplier.
- CI exes are **unsigned** (SmartScreen warning on strangers' machines) — signing is a W4
  decision; irrelevant for internal ops testing.

## Dependencies / risks
- **One physical Win10/11 machine with a real GPU** (Intel/NVIDIA/AMD — ideally rotate all
  three by W5) — the plan's single external dependency, first needed at W2.
- GStreamer-MSVC d3d11 HEVC decode across driver generations = the main technical risk
  (mitigated: rank-based decodebin + `WT_HW_ONLY` verification is already built).
- First distribution makes the parked LGPL/NOTICE work mandatory (W4) — Qt/GStreamer/FFmpeg
  all dynamically linked/exe-separate, which is the compliant shape already chosen.
- H.264/HEVC patent posture unchanged: hardware/OS decode carries the licence; keep
  `WT_HW_ONLY` enforceable in production configs.

## Out of scope (unchanged by the port)
Backend/cilex-vision contract, QML UI, the 2026-07-03 fixes (GC payload, far-seek
coalescing, empty-manifest retry) — all cross-platform by construction.
