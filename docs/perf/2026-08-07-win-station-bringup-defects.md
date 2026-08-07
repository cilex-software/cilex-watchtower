# Windows station bring-up — four defects found installing the first real guard station

_Found 2026-08-07 bringing `wt-sm-vnutri-01` (guard booth, Светлый Мир «Внутри»)
up from the `windows-latest` rolling prerelease. Two are fixed in this commit,
one is mitigated here but needs a shared-code fix via PR, one is station config._

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
