# Prompt W1 — GitHub Actions CI: a Windows .exe + installer on every code change

## Status
**DONE 2026-07-04.** `.github/workflows/windows.yml` builds `watchtower.exe` on `windows-2022`
(Qt 6.12.0 msvc2022_64 + GStreamer 1.26.11) and uploads `watchtower-portable` (144.6 MB) +
`watchtower-setup` (107 MB NSIS installer) on every push. This PROVED the W0 MSVC compile:
`main.cpp` + `MemTelemetry.cpp` compile and link under cl.exe. Non-obvious fixes needed to get
green (all documented in commits):
1. **aqtinstall 3.3.0 can't resolve Qt 6.12.0** — its `all_extensions('6.12.0')` returns `['']`,
   so it builds the pre-arch-split path `qt6_6120/qt6_6120/Updates.xml` (404). Fixed by pinning
   install-qt-action `aqtsource` to git master (`3.3.1.dev`, knows the split layout). **Revert to
   a pinned release once one ships with the fix.**
2. **GStreamer silent `/i` install landed nothing** — switched to `/a` administrative-extract to a
   known dir, then discover the real `lib/pkgconfig` and export PKG_CONFIG_PATH + GSTREAMER_ROOT.
3. **Duplicate manifest at link** (CVT1100) — Qt 6.12 auto-generates its own RT_MANIFEST; stopped
   embedding ours via the .rc (dropped `/MANIFEST:NO` too). Custom manifest extras (long-path,
   UTF-8 CP) deferred to W4.
4. **GStreamer plugins are `gst*.dll` on Windows** (no `lib` prefix) — deploy.ps1 tries both.

Remaining W1-adjacent follow-ups for later phases: verify the login-screen launch on a clean
Win11 VM (W2 does this with hardware); the GStreamer plugin bundle completeness is validated on
the GPU box in W2; caching of the GStreamer MSIs works but the download re-ran across the
early failed runs (cache saves on the green run). Original prompt below.

---

OPEN. Depends on W0 (MSVC-compilable source). **No Windows hardware needed** — this phase
IS the Windows build machine. Deliverable: every push to `main` produces downloadable
`watchtower.exe` artifacts.

## Context
- **Qt 6.12 msvc2022_64 MANDATORY** (plan ground rule). Install in CI via aqtinstall:
  `aqt install-qt windows desktop 6.12.0 win64_msvc2022_64 -m qtmultimedia qtshadertools`.
  (If 6.12.0 is not yet on the aqt mirror for windows desktop at execution time, use the
  latest 6.12.x available and note it — do NOT fall back to 6.8.x, the mandate stands.)
- GStreamer: MSVC **runtime + devel** MSIs (devel needed so `pkg_check_modules(GST …)` in
  `CMakeLists.txt` resolves at configure). `packaging/windows/fetch-gstreamer-windows.ps1`
  fetches the runtime; extend or complement it for devel in CI. Pin a version; cache it.
- `deploy.ps1` has a **TODO copy step**: finish it — `windeployqt` (Qt DLLs/QML/plugins for
  our qml/ imports) + the GStreamer **LGPL-only** plugin subset for the live pipeline
  (`rtspsrc ! decodebin(d3d11h264dec/d3d11h265dec) ! appsink` chain + core libs) + an
  **`ffmpeg.exe`** (official LGPL shared build) beside the exe — `ClipTranscoder` invokes
  plain `"ffmpeg"` and Windows resolves the app dir first (`ClipTranscoder.cpp:128`).
- The qmlcachegen bytecode-only workaround is version-gated in CMake
  (`Qt6_VERSION >= 6.12`, `CMakeLists.txt:61-62`) → active on Windows automatically. If
  the WINDOWS qmlcachegen ALSO crashes even in bytecode mode, that's new signal — record
  it, try `-DWT_ENABLE_AOT=OFF` explicitly (already default), and escalate in the plan doc.

## Task
1. `.github/workflows/windows.yml` on `windows-2022`:
   - Triggers: `push` to `main` + `pull_request`, with `paths-ignore:` for `docs/**` and
     memory/letters-only changes (a Windows run costs ~15–25 min; docs must not burn it).
   - Steps: checkout → cache+install Qt (aqtinstall) → cache+install GStreamer MSIs →
     configure with the W0 `windows` preset → build → `deploy-windows` target
     (`deploy.ps1`) → `makensis packaging/windows/installer.nsi` → upload TWO artifacts:
     `watchtower-portable.zip` and `watchtower-setup.exe`.
   - Optional: a `release` job on tags (`v*`) attaching the installer to a GitHub Release.
2. Iterate until green. Expect the first runs to surface mechanical MSVC issues W0
   asserted away (missing guards, narrowing warnings) — fix them at the source, keeping
   Linux byte-identical.
3. Add a CI badge + a "Windows build" section to `packaging/windows/README.md`
   (how to fetch artifacts from a run).

## Answering the operator's standing question (keep true in the workflow)
**Yes — every code change = a freshly built .exe.** Each push/PR run uploads the portable
zip + installer to that run's page (90-day default retention); tagged releases publish
permanent versioned installers. Private-repo caveat: Windows runners bill at 2× minutes.

## Verify
- CI green on a trivial commit; artifacts download; `watchtower-portable.zip` unpacks and
  `watchtower.exe` **launches to the login screen on a clean Windows 11 VM** (no GPU
  required for this gate — software rendering of the login UI is acceptable HERE ONLY).
- The zip contains: exe, Qt runtime, our QML, GStreamer LGPL subset, ffmpeg.exe, licenses
  dir (stub ok until W4).
- No Linux regression: `./run.sh` + a playback smoke after any source fixes.

## Gotchas
- Loopback HlsProxy needs no firewall rule (loopback-exempt) — do not add one.
- Keep GStreamer subset LGPL-only (exclude ugly/restricted) — W4 formalizes; don't create
  a violation in W1.
- windeployqt needs `--qmldir <repo>/qml` to scan our imports.
- Auto-commit + push when verified, per the working agreement.
