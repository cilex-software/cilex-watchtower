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

Not yet decided by the operator: starting the launcher at logon (a trigger on that task),
so Labs and its guard survive a reboot. Until then it is started on demand.
