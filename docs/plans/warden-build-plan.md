# Cilex Warden — build plan / task tracker

_Created 2026-07-26, after the ingest contract froze (letters `2026-07-26-client-crash-report-ingest*.md`).
Warden = supervisor + crash collector + uploader for guard-station Watchtower installs
(Ubuntu 24, Windows 10/11). Architecture decisions of record: Warden is the parent
process of Watchtower on BOTH platforms; the flight recorder lives inside the app;
one Python codebase (PyInstaller exe on Windows); spool/manifest contract is
platform-neutral; repo location `warden/` (same repo — the app/Warden contract is
atomic and guard boxes are frozen at install)._

| Id | Description | Status |
|---|---|---|
| CW-00 | Ingest contract with Cilex Vision: two-PUT wire format, TOFU auth, four numbers, re-arm/last-write-wins semantics, rate cap 10/min+30/h (letters + replies 1–4) | ✅ done (frozen both sides) |
| CW-01 | Flight recorder: `qInstallMessageHandler` tee → rotating files (~5×10 MB) in the data dir — the journal on Windows, journald's backup on Linux | ✅ done (`src/models/FlightRecorder.*`; verified: tee+banner, 4 KB-cap rotation, SIGKILL durability, off-switch, console unchanged, TABTEST green) |
| CW-02 | Modules/BuildID snapshot refreshed on the MEMTEL tick (`/proc/self/maps` on Linux, `modules.txt` on Windows) — offline symbolization without a core | pending |
| CW-03 | Crash marker from the fatal handler: async-signal-safe preformatted record (signal, uptime, RSS, pre-minted next-crash `report_id`) | pending |
| CW-04 | Windows minidump: `MiniDumpWriteDump` in the existing `wtUnhandledException` (WER LocalDumps registry as installer belt-and-braces) | pending |
| CW-05 | View-state persistence + restore (section/layout/group/page/sort, open tabs, focused camera; freshness window) — a restart must land the guard where they were | pending |
| CW-06 | Warden core: parent-supervisor — spawn Watchtower, wait, capture exit cause (signal / NTSTATUS), restart with 1→60 s backoff | pending |
| CW-07 | Linux packaging: systemd user units (supervise Warden, not the app), kiosk autologin, install-time root script (`core_pattern` sysctl, `LimitCORE`) | pending |
| CW-08 | Hang detection: in-app GUI-thread watchdog (`abort()` after ~15 s unresponsive) + Warden-side MEMTEL-gap check as the outer net | pending |
| CW-09 | Collector: marker → bundle packaging — idempotent, reboot-safe boot replay, background/low-IO, zstd core, token scrub, no video frames | pending |
| CW-10 | Minting policy (contractual per reply4): 3 singles per rolling 10 min → ONE `restart-loop` report, manifest re-PUTs coalesced ≤ 1/min, loop closes after 30 quiet min | pending |
| CW-11 | Spool state machine + uploader: two-phase PUTs, sidecars, §4 code table (400→quarantine+alarm, 401→freeze+alarm, 409→auto-recover, 413→truncate-rebuild, 429/503→backoff), TOFU station token | pending |
| CW-12 | USB path: `warden export <dest>` + re-import dedup (manifest PUT → skip bundle on `"stored"`; re-arm on `"evicted"` inside retention) | pending |
| CW-13 | Operator alerting: restart / crash-loop / 401 / quarantine alarms to Roman's channel | ⛔ blocked — channel choice (Telegram / webhook / email) still open |
| CW-14 | Chaos rig vs pilot box: kill -9 singles, kill loop (verify 3+1 minting + coalescing server-side), hang-abort, reboot-mid-collection; measure time-to-video-back; **first real upload** + CV cross-confirm | pending |
| CW-15 | Endurance: ≥ 24 h soak under Warden supervision — restore fidelity, no double-collection, spool bounded, zero guard-visible artifacts beyond the ~2 s blink | pending |
| CW-16 | Windows Warden: same Python core → PyInstaller single exe, Scheduled Task at-logon (never a service), NSIS installer wires LocalDumps + autologon + task | pending |
| CW-17 | CI archives PDBs per Windows release tag — minidumps are unreadable without them; worthless if done after the first field crash | pending |
| CW-18 | Windows chaos validation in a plain Win 10/11 VM (`taskkill /f`, suspend-as-hang, reboot mid-collection) — no GPU needed, not parked behind W2/W3 | pending |
| CW-19 | Dead-man heartbeat letter to CV (station liveness; their Prometheus→Alertmanager→ntfy plumbing) — both sides agree it's "the one with teeth" | pending — after v1, by agreement |
| CW-20 | Shipping bootstrap secret: CV mints real random value at installer-cut, delivered out-of-band, never in a repo | ⛔ blocked — on installer cut (pilot token in use meanwhile) |
| CW-21 | Docs: `warden/README.md`, DEVELOPMENT.md section, PROJECT_STATUS entries — rolls with each phase | pending |

**Build order:** CW-01…05 (in-app half, no CV dependency) → CW-06…12 (Linux Warden v1)
→ CW-14/15 (validation, first real upload) → CW-16…18 (Windows leg) → CW-19/20 (post-v1).
CW-13 slots in whenever the channel is chosen — nothing else waits on it.
