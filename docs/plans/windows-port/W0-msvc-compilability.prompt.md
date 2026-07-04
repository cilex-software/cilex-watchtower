# Prompt W0 — Make the source MSVC-compilable (Linux-side, zero behavior change)

## Status
OPEN. First phase of `docs/plans/2026-07-04-windows-port-plan.md`. **Runs entirely on the
Linux box — no Windows machine needed.** Every change must leave the Linux build
byte-identical in behavior (guards only, no logic changes).

## Context (audited 2026-07-04 — re-verify, don't re-audit from scratch)
**Qt for Windows = 6.12 msvc2022_64, MANDATORY** (operator directive; matches Linux
primary). Only TWO source files contain Linux-only code; everything else is Qt/QML:

1. `src/main.cpp`:
   - `#include <malloc.h>` + `mallopt(M_MMAP_THRESHOLD/M_TRIM_THRESHOLD)` + the 15 s
     `malloc_trim(0)` timer (glibc arena retention control, ~line 143-149) — glibc-only;
     the Windows heap doesn't need it. Guard with `#ifdef Q_OS_LINUX`.
   - `#include <sys/prctl.h>` + the `WT_PTRACE_ANY` prctl block (~line 129-135, added
     `d81d887`) — Linux Yama-specific. Guard.
   - `installCrashHandlers()` / `wtFatalHandler` — uses `<csignal>`, `<execinfo>`
     (`backtrace`), `<unistd.h>`, `/proc/self/statm` (`readRssMb`). Guard the whole
     handler `Q_OS_LINUX`; add a minimal Windows counterpart ONLY if cheap
     (`SetUnhandledExceptionFilter` logging the exception code + RSS via
     `GetProcessMemoryInfo`) — otherwise leave Windows with default fatal behavior and a
     `// W3 uses procdump` note. Do NOT block W0 on a polished Windows crash handler.
   - `#include <sys/resource.h>`, `<fcntl.h>`, `<unistd.h>` — audit each use, guard.
   - `readRssMb()` (also feeds `[WT-MEM]`) — add a PSAPI (`GetProcessMemoryInfo`,
     WorkingSetSize) variant so `[WT-MEM]`/`WT_TRACE` telemetry works on Windows.
2. `src/models/MemTelemetry.cpp` — `/proc` readers → same PSAPI variant (share a small
   helper; keep it header-local or a tiny `src/platform/` unit, whichever is smaller).
3. `gst/gst.h` in `main.cpp` + `RtspVideoSource` — cross-platform APIs, no guards needed;
   they need the GStreamer dev package at configure time (W1's job on CI).

Also in W0:
4. `CMakePresets.json` — add a `windows` configure preset (msvc2022_64, Ninja,
   `CMAKE_PREFIX_PATH` for Qt 6.12 msvc2022_64; GStreamer via `PKG_CONFIG_PATH` or
   `GST_ROOT` env passthrough matching `pkg_check_modules(GST …)`).
5. `packaging/windows/watchtower.ico` — generate from `assets/images/cilex-logo.png`
   (ImageMagick multi-size: 16/24/32/48/64/128/256), then enable the commented icon line
   in `packaging/windows/watchtower.rc`.
6. Stale-docs sweep: `packaging/windows/README.md` and the `deploy-windows` comment in
   `CMakeLists.txt` (~line 238) still say **Qt 6.8.3** — update both to **6.12**
   (msvc2022_64) per the mandate. Keep the aqt command line in the README accurate:
   `aqt install-qt windows desktop 6.12.0 win64_msvc2022_64 -m qtmultimedia qtshadertools`.

## Task
1. Guard/port the two files as above (`Q_OS_LINUX` / `Q_OS_WIN`; MSVC has no
   `__attribute__` etc. — keep additions warning-clean under `/W3` mentally, CI verifies).
2. Add the `windows` preset; generate the .ico; fix the stale 6.8.3 references.
3. Grep-sweep for stragglers the audit may have missed:
   `grep -rn "unistd.h\|sys/\|/proc/\|execinfo\|malloc.h" src/` — every hit either
   guarded or provably cross-platform (Qt headers).

## Verify (Linux — the only box available in W0)
- `cmake --build build -j` (Qt 6.12) clean; `./run.sh` launches; playback opens a day;
  `[WT-MEM]` still logs under `WT_TRACE=1`; `WT_PTRACE_ANY=1` still takes effect
  (supervisor gdb path unbroken).
- `cmake --build build68 -j` (6.8.3 fallback, CLEAN env — see the LD_LIBRARY_PATH gotcha
  in memory) still builds.
- MSVC compile-ability is *asserted* here, *proven* in W1 CI — don't hand-wave: keep the
  guards strictly `Q_OS_*`-symmetric so the first CI run's failures are mechanical.

## Gotchas
- Do NOT touch behavior inside the guards (the mallopt tuning is load-bearing on Linux —
  see the 2026-06-29 leak deep-dive).
- `Q_OS_LINUX` not `__linux__`; `Q_OS_WIN` not `_WIN32` (house style: Qt macros).
- Auto-commit + push when verified (Conventional Commits + Co-Authored-By/Claude-Session
  trailers), per the working agreement.
