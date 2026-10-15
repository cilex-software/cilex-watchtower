# wt-warden

Supervisor, crash collector, and uploader for Cilex Watchtower on guard
workstations. Plan/tracker: `docs/plans/warden-build-plan.md`. Ingest contract:
`docs/letters/2026-07-26-client-crash-report-ingest*.md` (frozen 2026-07-26).

Naming (operator decision 2026-08-04): the brand is always Latin-script
**Cilex Warden**; the Russian descriptive word is **«Хранитель»** everywhere
(never «надзиратель» — prison register; «супервизор» only deep in tech docs).
UI reference phrasing: «Хранитель Cilex Warden … наблюдает».

## Shape

```
systemd --user (Linux) / Task Scheduler at-logon (Windows, CW-16)
   └─ warden.py run                    ← kept alive by the OS
        └─ Watchtower (run.sh)         ← kept alive by Warden (parent-child:
                                          exit causes captured directly)
```

- **Death** → app back in ~1–2 s (backoff 1→60 s while unhealthy), then a
  forensic bundle is collected in the background and uploaded to Cilex Vision.
- **Crash marker** (`crash/marker-<report_id>.json`, written by the app's
  signal handler) is the authoritative record; a markerless kill (SIGKILL/OOM)
  is synthesized from the wait status. Boot replay collects markers left by a
  power-cycled run.
- **Hang**: the in-app GUI watchdog aborts after `WT_WATCHDOG_S` (60 s) of
  unresponsiveness; Warden's outer net (`HANG_S`, 120 s of flight-recorder
  silence) SIGABRTs a child the in-app watchdog can't save — either way the
  crash is marked, collected as `hang-watchdog`, and restarted. A frozen wall
  must die loudly, never lie quietly.
- **Minting policy** (contractual, reply4): ≤3 single reports per rolling
  10 min, then ONE `restart-loop` report that absorbs further deaths — its
  manifest is re-PUT (≥60 s apart, last-write-wins server-side) with the
  running count; the loop closes after 30 quiet minutes. Ceiling: ≤4 new
  reports/min burst, ≤6/h sustained; the server caps at 10/min + 30/h.
- **Uploads**: two idempotent PUTs (manifest ~KB first — the backtrace is on
  record seconds after the crash — then the raw-body tar.gz). §4 code table:
  400/403 → `quarantine/` + alarm; 401 → freeze everything + alarm; 409 →
  replay manifest; 413 → repack without core + manifest re-PUT; 429/503 →
  honour Retry-After. One report in flight at a time.
- **Bundles carry** marker, flight-recorder logs, `modules.txt` (BuildIDs —
  offline symbolization), `maps.txt`, console tail, core (≤512 MB, truncated
  above). **Never video frames; `access_token` scrubbed from text artifacts.**
  A core inherently may contain app-memory secrets — it travels only to the
  same backend the session cookie belongs to.
- **USB path**: `warden.py export /media/usb` copies manifests+bundles;
  `warden.py reimport <dir>` on any connected box — the manifest PUT answers
  `bundle_state=stored`, so an already-held half-GB never crosses the wire.

## Install (Windows — CW-16)

`warden.exe` (PyInstaller single binary, built by CI into the dist → portable zip
+ NSIS installer) + `install-windows.ps1` (run as admin), which sets up: config
skeleton, **WER LocalDumps** for `watchtower.exe` (the filter-bypassing-crash
net; Warden alarms `no-wer` if the key is missing — the Windows analogue of the
Linux `no-cores` alarm), and the **Scheduled Task** — *never a service* —
at-logon start + restart-on-failure (3×1 min) + a 30-minute resurrection
trigger, so a Warden that dies mid-session is dark ≤30 min (CV's alert text
carries that number). The NSIS installer runs the script automatically;
`STATION_TOKEN` is set at deployment (CW-20, out-of-band), never baked in.

Windows specifics baked into `warden.py` (all platform-gated, Linux behaviour
unchanged): station identity `sha256("wt1|SMBIOS_UUID|MachineGuid|station-seed)`
per the reply letter §3a (vendor-blank SMBIOS detected; seed = first-run UUID
file; identity cached — the SMBIOS read shells out); crash exit codes classify
as `exception-<ntstatus>` (e.g. `exception-c0000005`, stored+flagged server-side
like `sigkill` was); the hang outer net terminates rather than SIGABRTs (the
in-app watchdog owns marker-writing there); `CTRL_BREAK`/`SIGBREAK` is a clean
stop; `cores_available` is always `false` with `minidump_written` as the
per-report analogue. Runtime chaos validation on a real VM = CW-18.

## Install (Linux)

```
warden/install-linux.sh                      # user-level: unit + config skeleton
$EDITOR ~/.config/watchtower-warden/warden.conf   # STATION_TOKEN, APP_CMD
systemctl --user enable --now wt-warden
sudo warden/setup-root.sh                    # optional: kernel cores into the crash dir
loginctl enable-linger $USER                 # kiosk: start at boot, not first login
```

## Verified (2026-07-26, real chaos vs the pilot backend — the store's first uploads)

kill −SEGV single → `sigsegv` 201/201 · kill −9 → synthesized `sigkill`
(unknown-trigger flagged server-side, by design) · 4th death in 10 min →
`restart-loop` OPEN (deaths=4) · SIGSTOP → outer-net ABRT → `hang-watchdog` ·
manifest re-PUT → server `manifest_revisions=2` · re-import dedup → "bundle
already held", 0 bytes resent · clean SIGTERM → no report · fake-core included
in bundle · export → USB layout. Read side confirmed as admin:
5 reports, all `stored`.

## Darwin supervision (generic macOS deployment)

The generic installer uses packaged `cilex-warden run` in the intended user's
Aqua LaunchAgent. It launches the literal `APP_CMD` executable directly; do not
use `open -a`, shell-quote the value, or run the GUI supervisor as root. The
existing Windows and Linux entry points retain their spawn behavior.

The Darwin install supplies these `WT_WARDEN_` environment values (or the same
keys in `WT_WARDEN_CONFIG_FILE`):

| Key | Meaning |
| --- | --- |
| `APP_CMD` | Absolute `watchtower.app/Contents/MacOS/watchtower` path |
| `APP_WORKING_DIR` | Absolute working directory |
| `SPAWN_GATE` | Absolute packaged `cilex-spawn-gate` helper path |
| `INSTALLATION_ID` | Stable installation/account identity, never station credentials |
| `WARDEN_DIR` | Private per-installation Application Support state |
| `DATA_DIR` | Existing Qt AppDataLocation, normally `~/Library/Application Support/Cilex Vision/Watchtower` |
| `LOG_DIR` | Private `~/Library/Logs/CilexWatchtower/<installation>` directory |
| `MAINTENANCE_FILE` | Optional private owned regular-file marker suppressing GUI restarts |

The extra config is read after `/etc/watchtower-warden.conf` and
`~/.config/watchtower-warden/warden.conf`. Generated config must not contain
`STATION_TOKEN`: Watchtower still enrolls and refreshes the token in its existing
legacy config, and Warden rereads that file. The Qt preferences file
`~/Library/Preferences/com.cilex-vision.Watchtower.plist` remains authoritative
for the saved backend. Darwin reads Qt's native `auth.baseUrl` key, with the
older `auth/baseUrl` form accepted only when the native key is absent. An empty
native value stays empty. No preference, credential or session migration occurs.
When no `WARDEN_DIR` is supplied, an existing legacy
`~/.local/share/watchtower-warden` remains in use; otherwise Darwin defaults to
Application Support. Linux and Windows defaults are unchanged.

New unenrolled Darwin stations persist a SHA-256-derived IOPlatformUUID identity
under `~/Library/Application Support/CilexWatchtower/Identity`. Raw hardware UUIDs
are not logged or stored. A legacy enrolled station with a token and no new
identity record retains its old empty machine-key contract, allowing backend
host-based enrollment identity to remain intact. The new installer must never
copy another station's credentials or identity state.

Darwin Warden stays in the foreground and keeps the launchd process group. Its
LaunchAgent must set `AbandonProcessGroup=false`; this is supplemented by a pipe
guardian and exact native process-creation records, not assumed sufficient by
itself. The tiny compiled gate waits before `execv`. Warden releases it only
after the guardian has durably recorded PID, UID, creation time, executable and
session. Parent death before that point closes the gate; afterward pipe EOF
instructs the guardian to clean the recorded process tree. The app's parent
remains Warden after `execv`. If the guardian fails, Warden stops its child and
exits unsuccessfully for launchd recovery. A new Warden refuses to spawn while
a previous owner or cleanup guardian still lives. No global process-name kill
is used. The lock includes installation ID, account and session.

The guardian also records observed descendants that have entered a separate
session. Arbitrary helpers that double-fork and detach entirely between the
0.5-second observations are **not proven contained**. This limitation must not
be presented as complete process containment or production acceptance; test the
actual bundled multimedia/export helpers as part of the final artifact's
runtime acceptance.

The app watchdog measures observed flight-recorder changes with a monotonic
clock, including the case where the log never appears. Wake, large scheduling
gaps and wall-clock jumps grant a new grace interval. This behavior has injected
clock tests; it does not establish real sleep/wake acceptance. Child-failure
backoff remains 5, 15, 60, 60 seconds for short-lived failures, resetting to one
second after 120 seconds of operation. Guard detection polls once per second;
cleanup allows 5 seconds for TERM and 2 seconds for KILL. launchd's configured
throttle and application startup time must be added to the recovery budget.
The initial guardian handshake allows 30 seconds for cold frozen-runtime startup;
later track/cleanup acknowledgements remain bounded to 10 seconds. A failed
initial handshake closes the pipe and reaps the exact guardian before returning
failure. No application is released before its guardian has acknowledged it.
Registration does not establish startup verification.

For a recorded process whose native identity is temporarily unavailable, Warden
retries for at most 0.5 seconds before the existing bounded zombie-status check.
A persistently unreadable live process remains a cleanup failure; it is never
silently considered gone or signalled using only its PID. Explicit supervisor
shutdown and a private maintenance marker take precedence when a child's exit
races the next poll. Closing the GUI normally retains the existing kiosk restart
policy; its clean exit and operator-quit marker are not crash evidence.

CPU uses Mach aggregate tick deltas. Memory is an explicitly approximate used
percentage (`physical - free - inactive`), not Activity Monitor memory pressure.
Unavailable measurements remain null. macOS crash diagnostics remain under the
system's DiagnosticReports policy; Warden bundles its existing app markers and
logs without promising a core dump or changing crash/security settings.

Inherited Qt, QML, DYLD, GStreamer and Python overrides are removed from the
child environment. Bundled GStreamer plugins/scanner and FFmpeg are selected
from the app, with the registry under the intended user's Library/Caches.
Explicit `APP_ENV` remains a deliberate configuration override. Warden runtime
logs rotate at 5 MiB with three backups. LaunchAgent diagnostic logs and each
app-console capture are bounded with a 5 MiB retained tail; old console tails
are pruned along with the five retained console captures.

Run isolated native tests on a designated Mac with developer tools:

```sh
/usr/bin/python3 tools/tests/warden-darwin.py
/usr/bin/python3 tools/tests/warden-app-version.py
# Reuse the final packaged binaries for the process tests:
CILEX_TEST_WARDEN_EXECUTABLE="$APP/Contents/Resources/warden/cilex-warden" \
CILEX_TEST_SPAWN_GATE="$APP/Contents/Resources/warden/cilex-spawn-gate" \
  /usr/bin/python3 tools/tests/warden-darwin.py
```

These tests compile only temporary fixture children and do not register launchd
jobs, contact a backend, or use the real Watchtower application. Build-host
Python/compiler use is not a runtime-target dependency claim. Native API
references: [Apple launchd guidance](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html),
[Apple launchd.plist manual](https://github.com/apple-oss-distributions/launchd/blob/main/man/launchd.plist.5),
[Apple libproc structures](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info.h).
