# Warden cannot be stopped cleanly on Windows — CTRL_BREAK is not deliverable to a task-launched supervisor

_Measured 2026-08-10, 17:00–17:08 local, on `wt-sm-vnutri-01` (guard booth) while
updating the station from build `4fcb90cd` to `0af06c0` and taking it down for a
hand-over to a different Windows user. Written by the Windows station agent._

**The short version:** `warden/warden.py:917` calls CTRL_BREAK "the deliverable
stop" on Windows. It is not deliverable. Three attempts against a live
task-launched Warden all failed with `ERROR_INVALID_PARAMETER` (87), including
one with the process-group leader still alive. **There is no working clean-stop
path for Warden on this platform** — so no run that ends by operator intent can
emit the final `stopped_expected/warden_stopping` heartbeat the CW-19 contract is
built around, and every deliberate stop looks to CV like a station that died.

This is the measured half of the `stop`-verb gap that
[`2026-08-07-win-station-bringup-defects.md`](2026-08-07-win-station-bringup-defects.md)
D3 predicted from the process tree alone. Three further findings came with it, and
finding 3 is a new defect that affects every non-elevated upgrade-in-place.

---

## What the code claims

- `warden/warden.py:917` — `if hasattr(signal, "SIGBREAK"): # Windows: CTRL_BREAK is the deliverable stop`,
  registering a handler that sets `self.stopping`.
- `warden/warden.py:699` — the app is spawned with `CREATE_NEW_PROCESS_GROUP`
  "(so a `CTRL_BREAK` aimed at Warden never hits the app)". This is the right
  intent and it is exactly why a group-targeted break is the only safe form.
- `warden/warden.py:731-736` — with `stopping` set, `watch()` calls
  `proc.terminate()` and returns `"stopped"`; `:940` logs
  `supervisor stopping (SIGTERM) — no report for a clean stop` and breaks the run
  loop **without minting a report**; `:974-977` then sends one final beat carrying
  `app_state=stopped_expected`, `app_state_reason=warden_stopping`.
- `warden/warden.py:1049-1061` — the CLI dispatch. Verbs are `run`,
  `bundle-now`, `export`, `reimport`, `status`. **There is no `stop`.** Delivering
  the signal by hand is the only stop the product offers on Windows.

## What was measured

`warden.exe` **does** have a console — `packaging/windows/build-warden.ps1:10`
runs PyInstaller with `--onefile` and no `--noconsole`, and `AttachConsole(pid)`
against the supervisor succeeded on every attempt below. The failure is purely
the process-group argument.

| # | target group | leader state | result |
|---|---|---|---|
| 1 | `9840` (bootloader) | dead — see the correction below | `GenerateConsoleCtrlEvent` → `False`, err **87** |
| 2 | `14480` (supervisor's own pid) | n/a — not a group leader | `False`, err **87** |
| 3 | `10300` (bootloader of a fresh task-launched instance) | **ALIVE** | `False`, err **87** |

Attempt 3 is the decisive one. In all three, `AttachConsole` returned OK first,
so the console was reachable and only the group id was rejected.

**Why:** Task Scheduler does not launch the task's process in a new process
group, so the bootloader is not a group leader and its pid is not a valid
`dwProcessGroupId`. `warden.exe` is PyInstaller **onefile**: the bootloader
spawns the real supervisor as a same-named child *without*
`CREATE_NEW_PROCESS_GROUP`, so the supervisor inherits the bootloader's group and
is not a leader either. Neither pid names an addressable group, and the group
that does exist belongs to Task Scheduler.

**Correction to my own record.** Attempt 1 was contaminated by my own step: I ran
`Stop-ScheduledTask` before it, which (per D3) killed only the bootloader — so I
destroyed the sole plausible group leader before testing against it, and err=87
there proved nothing. Attempt 3 was run specifically to repair that, against a
fresh instance with the leader alive, and failed identically. The conclusion
stands on attempt 3, not on attempt 1.

### The remaining trick was refused, deliberately

`GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, 0)` broadcasts to every process
sharing the console. `watchtower.exe` shares Warden's console (`spawn()` at
`:700-702` redirects stdout to a file but does not detach the console), and its
own process group does not protect it from a group-0 broadcast. A Qt GUI process
with no console handler is terminated by the default handler, and `watch()` at
`:723-724` returns `"died"` from a blocking `proc.wait()` before Python can run
the queued SIGBREAK handler on the main thread — so the run loop at `:955-960`
would classify a deliberate stop as `crashed`, **mint a bundle and upload it to
CV's crash store**. Not attempted: manufacturing junk evidence on a shared
backend is the thing the 08-10 soak-writes policy exists to prevent.

### What was done instead, and what it cost

Supervisor force-stopped first (nothing left watching, so no bundle can be
minted for the app's death — spool verified `pending=0` afterwards), then the app
closed with `CloseMainWindow()` so Qt ran `Window.onClosing`: it exited cleanly
and wrote a real `shutdown-intent` marker at **17:04:21**.

Cost, and it is the whole point of the contract this breaks: **no final beat.**
CV's row kept `app_state=running` from the 17:05 beat, and per the CW-19 live
handshake (kill −9 paged at exactly +10 min) the operator's phone was exposed to
a false page around 17:15 for a stop that was entirely intentional.

## Finding 2 — the station cannot be held down without elevation

`Disable-ScheduledTask -TaskName wt-warden` → **`Access is denied` (0x80070005)**
for the very user the task runs as, non-elevated. `Stop-ScheduledTask` on the
same task **succeeds**. The task's ACL grants Administrators, a group not enabled
in a filtered admin token, so the two verbs land on opposite sides of the same
denial.

Measured consequence, not hypothetical: the 30-min resurrection trigger
(`warden/install-windows.ps1:95-96`) fired **at 17:03:29, in the middle of this
work**, relaunching Warden (pids 10300/18480) and a fresh app (15368) seconds
after the station had been taken down.

The task's `LogonType` is `InteractiveToken` (from `Export-ScheduledTask`), which
is the escape hatch: **logging `localadmin` off** stops the trigger from being
able to run at all, with no elevation needed. Fast-user-switching does not —
localadmin's session stays logged on, and at the next tick the station gets a
second Warden and a second wall on one iGPU.

## Finding 3 — a non-elevated upgrade-in-place leaves the station dark for up to 30 minutes, silently (NEW)

`installer.nsi:68-69` ends the install by running
`warden/install-windows.ps1`, which at `:102-103` stops and **unregisters** the
task, at `:114-119` force-sweeps every `warden` process, at `:121` re-registers,
and at `:126` calls `Start-ScheduledTask`. Non-elevated, `:103`/`:121` hit the
same denial as finding 2 — and the script runs under
`$ErrorActionPreference = "Stop"` (`:22`), so it **throws at `:121` and never
reaches `Start-ScheduledTask` at `:126`**. NSIS `ExecWait` ignores the exit code,
so the installer still reports success.

Measured here, and the mechanism is pinned by elimination rather than assumed:

- the script **did** run — `install-windows.ps1` is shipped into
  `$INSTDIR\warden\` and was rewritten by this install (8,000 bytes, 14:04:30);
- the task was **not** re-registered — after a silent `/S` install that exited
  **0**, `Get-ScheduledTaskInfo` still read `LastRunTime 17:03:29` /
  `NextRunTime 17:33:28`, unchanged. Had `:103` succeeded, `:121` would have
  minted a fresh task and `NextRunTime` would have been ~now+2 min;
- the blocker is **not** task creation in general — a scratch probe
  (`Register-ScheduledTask -TaskName wt-perm-probe … -User $env:USERNAME`, then
  `Unregister`) **succeeded** on this same non-elevated token and was cleaned up.
  So this user can create and delete tasks it owns; what it cannot touch is the
  admin-created `wt-warden` object, exactly as in finding 2;
- therefore `:103` failed silently (`-ErrorAction SilentlyContinue`), the old task
  survived, `:121` threw registering over a surviving name, and `:126` was never
  reached — which is what "nothing was running afterwards" measures. For this hand-over that was convenient. On a real
upgrade of a working station it means **the guard's wall does not come back until
the next 30-min resurrection tick**, with an installer that said success. Same
shape as D2, arriving by a different door: the honest-summary lines at
`install-windows.ps1:130-137` are never printed either, because the throw is
above them.

It also means a **second Windows user cannot install this app non-elevated
without ending up with no supervisor at all** — `wt-warden` already exists under
the first user's registration and cannot be replaced. A second user must run the
installer **elevated**, which rebinds the task (and its at-logon trigger) to
them.

## Finding 4 — what an upgrade does and does not preserve (verified, no defect)

Worth recording because the station token is the one irreplaceable thing on this
box, and `installer.nsi:45` does `RMDir /r "$INSTDIR"`:

- `warden.conf` — **untouched**, token intact (48 chars). `install-windows.ps1:32-46`
  only writes a skeleton `if (-not (Test-Path $conf))`; the file lives in
  `%USERPROFILE%\.config\`, outside `$INSTDIR`.
- WER LocalDumps — **still armed**, `DumpFolder` correct, read back through the
  64-bit view. The uninstaller's `DeleteRegKey HKLM` (`installer.nsi:84`) fails
  non-elevated, and so would the re-arm, so the D1 fix survives by symmetry.
- Crash spool — `pending=0 sent=1`, no junk bundle from any of the above.
- Binary actually changed: 7,059,968 → **7,664,640** bytes, new sha256, and the
  string `0af06c0` is embedded in `watchtower.exe` (the build it claims).

## The fix that is owed

D3 already names it: a **single-instance lock plus a `stop` verb** in
`warden/warden.py` — shared code, so it goes via a `win/<topic>` branch and a PR,
not from this box. What today's measurement adds is that **console signals are
the wrong mechanism on Windows** and a `stop` verb must not be built on them.

Proposal, marked as design and not measured: have `warden stop` write a
`stop-request` file (pid + epoch) into the Warden home, and have the existing
`watch()` loop — which already wakes every 10 s at `:723` — treat it as
`self.stopping`. That reuses the current cadence, needs no signal delivery, and
behaves identically on Linux and Windows, where SIGTERM already works on one and
nothing works on the other. The single-instance lock is what makes `stop`
unambiguous about which supervisor it is stopping, and it is the same lock D3
needs to stop an upgrade leaving two Wardens on one iGPU.

Until that ships: **do not quote `warden.py:917` as a stop path**, and expect
every deliberate Windows stop to cost either a false dead-man page or a fake
crash bundle. Those are the only two options the product currently offers.
