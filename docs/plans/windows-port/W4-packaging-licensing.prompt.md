# Prompt W4 — Installer polish, LGPL/notice compliance, signing decision

## Status
OPEN. Depends on W1 (artifacts) — can run in parallel with W2/W3. Build-machine work only
(CI + any Windows box/VM). **Qt 6.12 msvc2022_64 MANDATORY.**

## Context
- `packaging/windows/installer.nsi` is a skeleton. The June decision parked legal/NOTICE
  work "per operator" — **first distribution makes it mandatory.** The compliant shape is
  already chosen: Qt, GStreamer, FFmpeg all **dynamically linked / separate executables**
  (LGPL-satisfiable), H.264/HEVC patent exposure mitigated by hardware/OS decode
  (`WT_HW_ONLY` enforceable).
- CI exes are unsigned → SmartScreen "unknown publisher" on machines that haven't seen
  them. Fine for internal ops; a decision point for anything wider.

## Task
1. **Installer**: finish `installer.nsi` — install/uninstall, Start Menu entry, upgrade-
   in-place (version from `watchtower.rc`), install-dir layout matching the portable zip,
   optional desktop shortcut, per-user (asInvoker — no elevation) install to
   `%LOCALAPPDATA%` by default. MSIX noted as a later alternative, not built now.
2. **Licensing/notices** (the load-bearing half of this phase):
   - `licenses/` in both artifacts: Qt LGPLv3 text + module list, GStreamer LGPL plugin
     inventory (EXACTLY the shipped subset — generate from the deploy.ps1 copy list, keep
     them in lockstep), FFmpeg LGPL notice for the bundled ffmpeg.exe (must be an official
     **LGPL** build — verify no GPL components), and a top-level `THIRD-PARTY-NOTICES.txt`.
   - **Source offers**: pin the exact Qt/GStreamer/FFmpeg versions in a
     `licenses/SOURCES.md` with upstream source URLs (LGPL written-offer satisfied by
     hosted sources + our pinned versions).
   - An "About → Third-party licenses" surface in-app is a NICE-TO-HAVE — if it needs UI
     work, file it as a follow-up prompt rather than scope-creeping here.
3. **Signing decision memo** (one page, in this file or the plan doc): internal-only →
   stay unsigned (document the SmartScreen bypass for ops); wider → Authenticode
   (OV vs EV tradeoff, cert lead time). Get the operator's call; implement only if "sign".
4. Wire `makensis` + license assembly into the W1 workflow so every CI run ships the
   compliant installer, not just a raw zip.

## Verify
- Fresh Win10 + Win11 VMs: install → launch → uninstall clean (no leftovers beyond user
  data dirs); upgrade over a previous version preserves settings (QSettings + SQLite
  CameraStore live under the user profile — confirm untouched).
- `licenses/` inventory mechanically matches the shipped DLL/plugin set (script the check
  in CI — a drifted plugin list is a compliance bug).
- Operator has explicitly decided the signing question (record the decision here).

## Gotchas
- Keep the GStreamer subset LGPL-only — adding a decoder later (W2/W5 driver findings)
  must go through the same license gate.
- Do NOT commit fetched runtimes or procdump/ffmpeg binaries to the repo — fetch scripts
  + pinned versions only (existing `.gitignore` in packaging/windows covers dist/).
- Auto-commit + push when verified, per the working agreement.
