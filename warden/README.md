# wt-warden

Supervisor, crash collector, and uploader for Cilex Watchtower on guard
workstations. Plan/tracker: `docs/plans/warden-build-plan.md`. Ingest contract:
`docs/letters/2026-07-26-client-crash-report-ingest*.md` (frozen 2026-07-26).

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
