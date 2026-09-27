# Deploying a Windows build to the guard booth and the office wall

Station tooling from the Windows station agent (`wt-sm-vnutri-01`). All scripts are
ASCII-only: PowerShell 5.1 reads a BOM-less UTF-8 file as ANSI there, and both
stations have Cyrillic profile names, so paths are discovered at run time.

## Order, and why

1. **Build** with `packaging/windows/build-local.ps1` (on the booth, through its
   `C:\wt\build-office-dist.ps1` wrapper). Move old `CilexWatchtower-*-setup.exe` files
   aside first: the wrapper's check picks the first one it finds.
2. **`preflight.ps1`**: the build must pass before it goes near a wall. It runs the
   fresh exe from the booth's hardlinked staging runtime (`C:\wt\pb2`), headless, for 40 s
   under `catch_abort.py`, a small debugger that prints OutputDebugString, first-chance
   C++ exceptions with their type, and any fatal exception with a symbolised stack
   (dbghelp + the build's PDB). It passes only if the app is still alive with no
   second-chance exception. It also restores the `cilex://` handler, which every app
   start re-registers, to the live install.
3. **`update-booth.ps1`**, in the background: watchdog off, Warden off, app off, back
   up, swap, start Warden the way the wall watchdog does, verify by parentage, and
   supervision back on. Only `watchtower.exe` changes unless Qt, GStreamer or packaging
   did. The booth runs `warden.py` under signed Python.
4. **`watch-wall.ps1`**: it passes when the same app pid has stayed up for 90 s, and
   reports `CRASHLOOP` on the second Warden restart.
5. **Office wall (`wt-office-01`)**: stage the new `watchtower.exe` and `warden.exe` in
   `C:\Users\Public\Downloads\wt-stage\` over the `C$` share, then run
   `office/wt-update.cmd` there as a one-shot SYSTEM service (`sc.exe \\host create …
   binPath= "cmd.exe /c …"`; a `powershell.exe` binPath never runs). The job swaps both
   binaries, restarts Warden through the user's own `wt-warden` task, and ROLLS BACK by
   itself if no supervised app appears within 45 s. It logs to `wt-update.log` beside it.
   To confirm the app stayed up, read the office app's flight recorder over `C$`. There
   is no `wmic` on that Windows 11.

## Why the preflight exists: 2026-09-28

1.1.671 passed the old probe ("running after 6 s") and then crash-looped the booth's
wall for ~6 minutes. It died ~4 s after every start with 0xC0000409 in ucrtbase,
because an image ledger called `setvbuf(f, nullptr, _IOLBF, 0)`, which MSVC's CRT
rejects by fast-failing the process (fixed in 752b94e). The old probe had asked for
`QT_QPA_PLATFORM=offscreen`, which the install does not ship. The app sat on a Qt error
dialog, on the guard's screen, and "still running" meant "stuck". Staging now carries
`qoffscreen.dll`; the live install does not need it.

Never screenshot the booth's desktop to check the wall: the guard's browser is usually
in front and holds residents' data. Capture the app window alone with
`PrintWindow(hwnd, hdc, PW_RENDERFULLCONTENT)`, which renders it even when it is covered.
