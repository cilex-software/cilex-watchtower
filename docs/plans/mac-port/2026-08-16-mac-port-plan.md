# Cilex Watchtower — macOS port plan (M0–M4)

**Written 2026-08-16 on the Linux dev box.** Follows the Windows-port pattern
(`docs/plans/windows-port/`, W1–W4): a phased plan the agent on the target
machine executes, with shared-code changes flowing through the Linux box. The
tree was made mac-configurable the same evening this plan landed (see §Audit).

## Ground rules carried over, stated once

- **15 fps is set on the cameras and nowhere else.** Nothing in this port
  touches rate. VideoToolbox decodes what arrives.
- Shared code (`src/`, `qml/`, `CMakeLists.txt`, `i18n/`) changes via the
  Linux box or PRs it reviews — same two-agent rule as Windows, extended to a
  third checkout.
- macOS-only paths (`packaging/macos/**`, `warden/install-macos.sh`, mac perf
  notes) belong to whoever operates the Mac, pushable directly after rebase.
- Evidence discipline unchanged: nothing in this plan is "done" until measured
  on the Mac. Every "should work" below is labelled expected, not verified.

## Audit of 2026-08-16 (measured on this tree, cited)

| site | what | macOS behaviour | action |
|---|---|---|---|
| `src/main.cpp:41,280` | `sys/prctl.h` / `PR_SET_PTRACER` (Yama) | **compile error** | **FIXED — `Q_OS_LINUX`-gated** (the only hard blocker found) |
| `src/models/MemTelemetry.cpp` (rssMb) | `/proc/self/statm` | returns −1 | **mach `task_info` branch ADDED — written on Linux, never compiled on a Mac; M2 verifies** |
| `src/main.cpp:67–78` (signal-safe RSS) | `/proc/self/statm` via raw syscalls | returns −1, honest degrade | M2: mach equivalent is NOT async-signal-safe territory — decide whether −1 is acceptable in the fatal path (recommended: yes) |
| `src/models/FlightRecorder.cpp:277` | `/proc/self/maps` module snapshot | empty list, honest degrade | M2: `_dyld_image_count()` walk, or accept the gap |
| `warden/warden.py:220` | `/proc/sys/kernel/core_pattern` | try/except'd; N/A on mac | M3: crash source is `~/Library/Logs/DiagnosticReports` instead |
| `CMakeLists.txt:264` (WIN32 block) | inert off-Windows | no obstruction | M4 adds an `if(APPLE)` sibling |
| GStreamer via `pkg_check_modules` | — | Homebrew `gstreamer` satisfies it | M0 |
| `run-watchtower.sh` | `LD_LIBRARY_PATH` Qt wiring | wrong var on mac | M1: `run-macos.sh` (`DYLD_FRAMEWORK_PATH`) or rely on rpath |

Everything else platform-conditional (`FlightRecorder.h`, `ClipTranscoder.cpp`)
already splits WIN/else where the else-branch is POSIX-portable.

## M0 — toolchain + first configure (Mac machine, ~half a day)

Qt **6.12** via the Qt online installer (match the reference toolchain; free),
CMake + Ninja + Xcode CLT, `brew install gstreamer` (pulls the plugin sets —
verify `gst-inspect-1.0 vtdec_hw` and `rtspsrc` exist). Then:
`cmake --preset` equivalent pointing at the Qt kit → **configure must succeed
with zero edits**. If it doesn't, every failure is a defect in this plan's
audit and comes back to the Linux box as a list.

## M1 — build, run, first wall (the decisive phase)

`./run` against the pilot (`WT_CV_URL`, tailnet — same as the booth). Gates:

1. Login + camera list + snapshots (pure Qt/HTTP — expected clean).
2. **Live wall decode path**: `WT_TRACE=1` → `[WT-DEC] using <factory>`.
   Expected `vtdec_hw (hardware)`. **Two things to verify on hardware, both
   flagged now**: does decodebin rank vtdec first, and does its factory klass
   contain the literal `Hardware` — the `WT_HW_ONLY` skip and the `dec=` gauge
   both key on that string (`RtspVideoSource.cpp, onAutoplugSelect`).
3. `[MEMTEL]` line sane: `rss=` from the new mach branch (first compile of
   that code happens here), `framesIn`/tile ≈ 15 on LAN.
4. The watchdog clock: `CLOCK_MONOTONIC` on Darwin is expected to pause across
   sleep (mach_absolute_time semantics) — **verify with a lid-close test**, or
   a MacBook that sleeps overnight will abort-on-wake exactly like the booth's
   `GetTickCount64` bug (PR #2). If it counts sleep, the fix is
   `CLOCK_UPTIME_RAW`, one line, same pattern as the Windows fix.
5. Bandwidth reality from day one: a remote Mac is a **booth**, not a dev box —
   the 4.3 Mbit/s lesson applies to any WAN station. On-LAN Macs are exempt.

## M2 — platform gaps (shared code, Linux box ships, Mac verifies)

The audit table's middle rows: mach RSS verification, dyld module list (or
accepted gap), fatal-path RSS decision. Plus whatever M1's gates surface.

## M3 — Warden on macOS

`warden.py` is Python 3 and post-UTF-8-fix; expected near-portable. Needs:
`install-macos.sh` + a **launchd** agent plist (the `systemctl --user`
equivalent), crash collection from `DiagnosticReports` (replaces the
core_pattern/WER logic), and the same single-instance story the booth's D3
demands everywhere. Console capture and upload paths unchanged.

## M4 — packaging + distribution (operator decisions live here)

`macdeployqt` + GStreamer runtime bundled into the `.app` (the W4 problem,
Darwin edition), DMG. **Decision required: signing.** Unsigned apps need
right-click-open or `xattr -d com.apple.quarantine` — fine for one internal
station; signing + notarization needs an Apple Developer account ($99/yr) —
the same class of budget call as the CI one, and it is the operator's.

## The machine (named 2026-08-16, same evening)

Operator's **MacBook Pro 16" 2021, Apple M1 Pro, 32 GB, macOS 26 (Tahoe
26.3.1)** — arm64. Two consequences a desk Mac would not have:

- **It sleeps constantly.** The M1.4 lid-close watchdog test is MANDATORY,
  first session — a laptop that aborts-on-wake is unusable, and that is
  exactly the booth's `GetTickCount64` bug shape.
- **It roams.** On the pilot's LAN it is a dev box; anywhere else it is a
  WAN station and the 4.3 Mbit/s lesson applies in full. Every measurement
  reports which network it was taken on, or it is not a measurement.
- macOS 26 is current-year; Qt 6.12 and Homebrew target it, but any
  Tahoe-specific breakage found at M0 is a finding, not a surprise.

## What this plan does NOT assume
- That macOS CI ever exists (macOS runners bill at 10× Linux — out, given the
  Actions decision; local builds are the channel, like Windows now).
- That the Mac station needs the full Warden day one — M1 runs bare
  (`./run`-equivalent) exactly as Linux did for its first month.

## Open operator decisions, in order of blocking

1. **The machine**: which Mac, where does it live (LAN or WAN matters — see
   M1.5), and does it get its own agent session like the booth.
2. **Signing budget**: unsigned internal vs $99/yr notarized (M4 only; does
   not block M0–M3).
3. Nothing else — toolchain is free, and the port rides the existing pilot.
