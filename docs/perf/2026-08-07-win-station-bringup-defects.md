# Windows station bring-up — seven defects found installing the first real guard station

_Found 2026-08-07 bringing `wt-sm-vnutri-01` (guard booth, Светлый Мир «Внутри»)
up from the `windows-latest` rolling prerelease. D1/D2 are fixed in this commit,
D3 is mitigated here but needs a shared-code fix via PR, D4 is station config,
and D5–D7 were found by the station crashing on its own an hour after install._

**D5 is the one to read first**: the app aborts itself on every sleep/resume
cycle. It is fixed in PR #2.

All four share a failure mode worth naming: **they are silent.** Every one of
them leaves the installer reporting success while something the station depends
on is quietly not there. That is precisely the "green-by-default for unknown
states" our house rules forbid, arriving through the back door.

---

## D1 — WER local crash dumps were written to the wrong registry hive (FIXED)

**Severity: high, and it has been true of every Windows install to date.**

`warden/install-windows.ps1` armed WER LocalDumps at
`HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\watchtower.exe`.
Measured on this box, the key landed at
`HKLM\SOFTWARE\**WOW6432Node**\Microsoft\...\watchtower.exe` instead.

**Why:** `packaging/windows/installer.nsi` builds a **32-bit** PE (confirmed:
`PE32 executable ... Intel i386, Nullsoft Installer`). Its
`ExecWait 'powershell ... install-windows.ps1'` resolves through WOW64
filesystem redirection to **32-bit** PowerShell, and a 32-bit process writing
`HKLM\SOFTWARE\...` is transparently redirected into `WOW6432Node`.
`watchtower.exe` is **x64** (verified by reading the PE machine field: `0x8664`)
and WER is 64-bit, so WER never reads that key.

**Effect:** the belt-and-braces dump for crash classes that bypass the in-app
exception filter (fast-fail, `/GS`) never fired. `minidump_written` in the
station heartbeat block would have stayed false forever, and Warden's collector
would never have had a `.dmp` to consume — on the first real guard station,
during exactly the first week CV said matters most.

**How it hid:** the write *succeeded*. No exception, so `$ErrorActionPreference
= 'Stop'` never tripped, the script printed `WER LocalDumps armed -> ...`, and
the install reported success. The only reason it surfaced was noticing that the
64-bit view showed the key absent *while a later step in the same script had
clearly run* — an ordering that is impossible unless the write went elsewhere.

**Fix:** write through an explicit `Registry64` view
(`RegistryKey::OpenBaseKey(LocalMachine, Registry64)`) and **read the value back
through that same view**, treating a failed read-back as not-armed. A write that
cannot be read back is not a write.

**On this station:** armed and verified out-of-band before the fix was written,
so the booth is protected now; the stray `WOW6432Node` key was deleted.

## D2 — a plain (non-elevated) install left the station with NO supervisor (FIXED)

`installer.nsi` is deliberately per-user, `RequestExecutionLevel user`, no UAC.
But the WER step (D1) is the one step that needs admin, it ran *before* the
Scheduled Task registration, and the script runs `$ErrorActionPreference='Stop'`.

So on a normal double-click install: WER throws → the script aborts → **the
`wt-warden` Scheduled Task is never registered** → the station has no supervisor
at all. NSIS `ExecWait` ignores the exit code, so the installer still reports
success. Registering the task needs no admin (it runs as the current user), so
the one step that genuinely requires elevation was killing the one that did not.

**Fix:** WER is now best-effort — wrapped in `try/catch`, warns loudly, and
execution continues so the supervisor is always installed. The script ends with
an honest summary naming what is armed and what is not:

```
--- wt-warden install summary ---
  supervisor (Scheduled Task) : REGISTERED + STARTED
  WER local crash dumps       : ARMED -> ...   | NOT ARMED (re-run elevated)
  station token               : SET            | MISSING (uploads/heartbeats OFF)
```

## D3 — stopping the Warden task does not stop Warden (MITIGATED; real fix needs a PR)

**Measured, with process IDs.** `warden.exe` is a PyInstaller **onefile** binary:
the Scheduled Task launches the bootloader, which spawns the *real* supervisor
as a child process of the same name.

```
task -> warden.exe 13396 (bootloader)
          └─ warden.exe 13556 (the actual supervisor)
               └─ watchtower.exe
```

`Stop-ScheduledTask -TaskName wt-warden` killed **only 13396**. 13556 was
orphaned (verified: its parent PID no longer existed), kept supervising, and
**respawned watchtower.exe**. Starting the task again then produced a *second*
supervisor and a *second* app: two Wardens and two Watchtowers, both driving the
same iGPU, both writing the same spool and reading the same config.

**Effects on a guard station:** "stop the app" does not stop it; any Warden
restart risks doubling the wall's GPU load and doubling RTSP sessions against CV;
and the uninstaller's `schtasks /End` leaves a live supervisor respawning an app
whose files are being deleted underneath it.

**Mitigated here** (Windows-only paths, this commit):
- `warden/install-windows.ps1` sweeps stale `warden` processes before
  re-registering, so an upgrade-in-place cannot leave the old supervisor running.
- `packaging/windows/installer.nsi` adds `taskkill /F /IM warden.exe /T` (and the
  app) to the uninstall section.

**The real fix is a single-instance lock in `warden/warden.py`** — refuse to
start if another supervisor holds the lock, plus a proper `warden.exe stop` verb.
That is shared cross-platform code, which this box cannot verify on Linux, so
per CLAUDE.md it goes via a `win/…` branch and a PR rather than straight to main.
Until then, use the documented sequence: stop task → kill every `warden` → close
the app → start task.

## D4 — the station is off-LAN; both default backend addresses point at the lab (station config)

The booth PC is not on `192.168.1.0/24`. Measured: **no tailnet peer advertises
that subnet** (`tailscale status --json` → no `PrimaryRoutes` on any peer), and
`192.168.1.79:8000/8554/1984` are all unreachable from here. The same three CV
services answer fine over Tailscale at `100.107.51.72`.

Two defaults assume the lab LAN:
- `src/models/AuthController.cpp:47` — `WT_CV_URL` defaults to
  `http://192.168.1.79:8000`, so the sign-in screen offers an unreachable server.
  A guard would get a failed login with no idea why. (Screenshot-confirmed: the
  СЕРВЕР field pre-filled with the lab address on first run.)
- `warden/install-windows.ps1 -Backend` defaults to the same address, so Warden's
  heartbeat/upload target is wrong out of the box.

**Not a code bug** — a dev default meeting the first non-dev station. Handled in
this station's `warden.conf` (`BACKEND_URL` + `APP_ENV=WT_CV_URL=…` both set to
the tailnet address). Worth deciding centrally before station #2: either the
installer should prompt for the backend, or the default should stop being a
lab-local literal.

**Non-issue, checked and cleared:** CV *derives the serving URLs it returns from
the request host*, so `rtsp_url` / `hls_url` / `snapshot_url` all came back as
`100.107.51.72` and are reachable. Only `direct_rtsp_url` (camera-direct, which
Watchtower never uses) stays LAN-absolute.

---

# The station crashed an hour after install — and that found three more

At 16:52:38 local, ~58 min after the production restart, `watchtower.exe` died
and Warden restarted it. Nobody was driving it. Investigating that one crash
produced D5–D7, and validated the D1 fix.

## D5 — the GUI-thread watchdog counts system-suspend time as a hang (FIXED in PR #2)

**This is the important one.** Warden's console capture of the dead instance:

```
[WT-HANG] GUI thread unresponsive for 2947s (watchdog 60s) — aborting for Warden to restart.
```

Windows event log, `Microsoft-Windows-Power-Troubleshooter` id 1:

```
sleep : 2026-08-07T13:03:24.849Z
resume: 2026-08-07T13:52:28.680Z    -> 2943.8 s suspended (S3)
wake source: Intel USB 3.20 host controller
```

**2947 s "unresponsive" vs 2943.8 s actually asleep.** The watchdog was measuring
the suspend. The GUI thread was never wedged — the whole process was frozen by
the OS, which is not the failure CW-08 exists to catch. The flight recorder shows
the matching silence: last line 16:03:24, next line 16:52:29, then abort.

**Root cause, one line.** `src/main.cpp:293` already stated the requirement —
*"CLOCK_MONOTONIC pauses across suspend on Linux, so a resumed laptop doesn't
false-trigger"* — but the Windows branch used `GetTickCount64()`, which is
**biased**: it counts time spent asleep. The protection the comment describes
existed only on Linux. Fixed by switching to `QueryUnbiasedInterruptTime`
("unbiased" = sleep excluded). Windows-only lines; Linux build cannot be
affected. **PR #2**, raised rather than pushed because it touches `src/`.

**Why it matters more than one restart:** Warden restarts the app, so the station
self-heals and a guard sees a flicker. The damage is downstream — **every wake
mints a crash report**, so once this station's token is installed that is a bogus
crash bundle uploaded on *every single resume*. A booth PC that sleeps overnight
would page CV every morning, and poison CW-19's dead-man heartbeat with restart
churn that is not real.

**Station mitigation applied immediately** (independent of the code fix): this
box was on the stock *Сбалансированная* scheme and **suspended itself after ~50
minutes idle**. A guard-booth camera wall that puts itself to sleep is an
operational fault on its own — the wall simply stops watching. Set via
`powercfg` (no elevation needed):

```
standby-timeout-ac/dc   = 0 (never)
hibernate-timeout-ac/dc = 0 (never)
```

Display blanking (`VIDEOIDLE`, 5 min AC) was **deliberately left alone** — a dark
panel wakes on input and never freezes the process.

## D6 — a deliberate `abort()` on Windows is filed as memory corruption

Warden recorded `"trigger": "exception-c0000409"` for this crash.
`0xC0000409` is `STATUS_STACK_BUFFER_OVERRUN`, which reads like a `/GS` stack
smash — a security-relevant memory-corruption bug. It was nothing of the kind:
the MSVC CRT implements `abort()` via `__fastfail(FAST_FAIL_FATAL_APP_EXIT)`,
which raises exactly that code. So **our own intentional watchdog abort is
indistinguishable, in the report, from real stack corruption.**

Every `[WT-HANG]` abort on Windows will be misfiled this way, and the misfiling
points triage at the most alarming possible root cause. Warden should classify a
crash whose console tail carries `[WT-HANG]` as a hang trigger, the way the Linux
side distinguishes SIGABRT-after-watchdog. Not fixed here — `warden/warden.py`
is shared code and needs a PR.

## D7 — the minidump was written but the bundle says there is none, and does not carry it

The manifest for this crash says:

```
"minidump_written": false,
"artifacts": ["manifest.json", "flightrec/watchtower.log", "flightrec/modules.txt", "console.log"]
```

But `%APPDATA%\Cilex Vision\Watchtower\crash\watchtower.exe.2948.dmp` exists —
**38,590,869 bytes, timestamped 16:52:38, the crash instant**, a valid minidump
(`MDMP`, 15 streams), matching the dead pid.

Warden minted the manifest at the moment of death, while WER was still writing
38 MB of dump. So the flag was evaluated too early and the dump missed the
artifact list. Net effect: **the bundle CV receives declares "no minidump" and
does not carry the dump** — the exact evidence D1 just made possible would not
reach the server. Warden needs a post-crash settle/rescan for `.dmp`s before
sealing a bundle (it already does a boot-replay pass; this wants the same idea on
a short delay). Shared code → PR.

## What this crash proves about D1

**The WER fix paid for itself within the hour.** `c0000409` is a fast-fail
exception: it bypasses `SetUnhandledExceptionFilter`, so our in-app handler
(`wtUnhandledException`) never ran and wrote nothing. WER LocalDumps was the
*only* mechanism that could capture this crash — and until this morning it was
armed in a registry hive WER never reads. The first real crash on the first real
guard station was precisely the class D1 had silently disabled.

---

## One observation for CV, not a Watchtower defect

`GET /streams` returns `direct_rtsp_url` / `direct_rtsp_sub_url` with **camera
credentials in cleartext** (`rtsp://admin:<password>@192.168.1.x:554/...`), to
any authenticated client. Watchtower never talks to cameras directly so it does
not consume these, but it means the fleet's camera password is readable by every
operator session. Flagged to CV in
`docs/letters/2026-08-07-station-wt-sm-vnutri-01.reply2.md`; their call whether
that is intended for the Provisioner's benefit or worth scoping down.

## Verification status — what is proven and what is not

| item | status |
|---|---|
| D1 64-bit WER write + read-back | **verified on this box** (armed, read back, stray key removed) |
| D1/D2 edited `install-windows.ps1` | parses clean; control flow checked (task registration reachable after a WER failure). **End-to-end elevated run NOT performed** — the UAC prompt was declined; it will be exercised by the next real install. |
| D3 orphan behaviour | **verified** (PIDs above) |
| D3 mitigations | `install-windows.ps1` sweep not yet exercised; `installer.nsi` change **untested** — no NSIS toolchain on this box, so it ships unbuilt until CI |
| D4 reachability | **verified** both directions (LAN unreachable, tailnet reachable) |
| D5 suspend→abort causation | **verified**: 2947 s reported vs 2943.8 s measured suspend, from two independent sources (Warden console capture + Windows Power-Troubleshooter event) |
| D5 code fix (PR #2) | **NOT compile-verified** — no MSVC/Qt toolchain on the station. CI on the PR is the first build. Do not merge on a red run. |
| D5 station mitigation | **verified**: `STANDBYIDLE` and `HIBERNATEIDLE` now read `0x0` on AC and DC |
| D6 `c0000409` == `abort()` | trigger value **observed** in the manifest; the CRT `__fastfail` mechanism is stated from documentation, not instrumented here |
| D7 dump written but unreported | **verified**: manifest says `minidump_written:false`; a valid 38,590,869-byte `MDMP` exists at the crash timestamp |
| whether D5 recurs | **not yet observed a second time** — one occurrence, and sleep is now disabled, so it should not recur on this box |
