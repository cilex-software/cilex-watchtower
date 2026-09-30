# Labs on a Windows wall station: the wall guard

`guard3.ps1` is the wall's safety check for the Labs worker (worker-0.3 onward). It runs
**on the machine it guards**, hidden, and writes nothing but its own log and CSV.

- **Harm sets a HOLD** (`tools/labs/station.py` `write_hold`, `by = "wall-guard"`): the
  worker drops the unit in hand within a second, claims nothing, and reports the reason to
  the admin page. A restarted worker stays held, and a server Start does not override it.
  Harm is judged by failure signals only (errored or dark streams for 90 s, watchdog
  rebuilds or reconnects on a steady full wall, a freeze of 2 s or more or three of 1 s or
  more in 10 min, an app restart, the full-wall frame rate under 70% of normal for 90 s),
  never by what is on screen. A guard opening one camera parks the wall's tiles, and
  returning from it rebuilds 9-13 streams by itself; neither is harm (measured
  2026-09-28, see the script header).
- **A clock step is not a freeze** (2026-09-30). Windows Time steps the booth's clock
  forward about 3.8 s every night (00:03-00:34, System log Kernel-General event 1), and
  apps before 1.1.749 timed `gui_stall` on the wall clock, so every step read as a
  3.8 s freeze; at 00:11 that night one held Labs. The guard subtracts any forward step
  the System log recorded inside a stall before judging it. The freeze signal exists only
  where the app runs with `WT_TRACE` (the booth). The office app logs no `gui_stall` at
  all, so its guard has no freeze signal there.
- **Release** only after 15 min with no harm, and only a hold whose `by` is `wall-guard`
  at that moment; an admin's hold is never touched.
- **`-StartWorker`**: the guard also starts the worker when none is running (hidden, Idle
  priority) and restarts it if it dies, at most 3 times an hour. **Start the guard, never
  the worker alone**: a worker beside a wall must never run without its guard.
- It counts processes in its own desktop session only: the office update's SAC probe runs
  a second `watchtower.exe` in session 0 for 8 s, and that is not a second wall.
- `-TestDir <dir>` replays `<dir>\fr.log` and writes the hold into `<dir>\control.json`
  through the same `station.py` code. Replay real navigation plus synthetic faults before
  trusting any change to the rules.

Operator rule (2026-09-28): Labs is a background programme. Nothing about it may be shown to
anyone who is not an admin, so there is no window, toast or tray icon.

## wt-office-01

`start-labs-office.ps1` is the office's launcher, installed there as
`C:\wt-labs\start-labs.ps1`, beside its copy of `tools/labs` and `guard3.ps1`. It starts
the guard with the office's baseline (12.3 frames/s on 1 stream), its per-user
Python 3.12, and winget's ffmpeg, which has no command link, so its folder goes on the
worker's PATH. Running it twice is refused. Since 2026-09-29 01:47 the office guards
itself; before that, a booth-side `-Office` guard watched it over `C$` and left it
unguarded whenever the booth rebooted.

**Restarting it remotely (2026-09-29).** The booth cannot start a process in the office
user's session directly. A one-shot SYSTEM job can register an on-demand scheduled task
for the console user (`wt-labs-start`: LogonType Interactive, RunLevel Limited, **no
trigger**, no time limit), whose action is `wscript //B //NoLogo
C:\wt-labs\start-labs.vbs` (`start-labs-office.vbs` here). wscript has no console, so
nothing flashes on screen; it runs the guard hidden and waits, so the task stays Running
with it. Order matters: stop the old worker FIRST, then release any hold, then start the
task. A broken worker released from a hold would claim again. That is how the office
got off worker-0.3.2 after its Stop killed the worker's own console host (0xC0000142 on
every later ffmpeg): the guard now launches workers through `cmd start /low /b`, so the
console belongs to cmd, and worker-0.3.3 kills decoders only.

**Fill (worker-0.3.10, 2026-09-30).** The operator asked for the office to run Vehicles
"to the full capacity of this PC". `start-labs-office.vbs` puts `WT_LABS_FILL=1` into its own
process environment, and the guard and the worker it starts inherit it. The worker then adds
Vehicles units one at a time while the machine measures room for them: an idle logical CPU,
free memory of at least 2x the largest unit, and no unit near its lease. The ceiling is the
logical CPU count. On any hold the extra units go back, and after it the lane refills from
one unit. The booth's launcher never sets the variable. psutil (7.2.2 on the office) is what
lets fill measure a unit's memory on Windows; without it, fill adds nothing and says why.

Not yet decided by the operator: starting the launcher at logon (a trigger on that task),
so Labs and its guard survive a reboot. Until then it is started on demand.
