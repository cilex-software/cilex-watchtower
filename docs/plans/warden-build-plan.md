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
| CW-02 | Modules/BuildID snapshot (30 s timer, rewrite on change): `modules.txt` (base+BuildID/PE-key+path, atomic QSaveFile) + raw `maps.txt` on Linux — offline symbolization without a core | ✅ done (verified: 173 modules, Qt6Quick BuildID matches `file -L`; Windows PE/RSDS parse compile-guarded, validation = CW-18) |
| CW-03 | Crash marker from the fatal handler: async-signal-safe `crash/marker-<report_id>.json` — JSON header (signal/epoch/uptime/rss/pid/build/qt) + backtrace lines; report_id pre-minted at install; SIGTERM mints nothing | ✅ done (verified: live SIGSEGV → marker with backtrace; arming unconditional, not killable by WT_FLIGHTREC_OFF) |
| CW-04 | Windows minidump: `MiniDumpWriteDump` in the existing `wtUnhandledException` + marker JSON; CONTINUE_SEARCH kept so WER LocalDumps stays belt-and-braces | ✅ built (dbghelp linked; compile-guarded — live validation on the Windows VM = CW-18) |
| CW-05 | View-state persistence + restore (section/layout/group/page/sort, open tabs, focused camera; freshness window) — a restart must land the guard where they were | ✅ done (Settings.viewState + Main.qml blob binding/debounce; eligibility gate keeps dev hooks from polluting; 24 h freshness; verified: seed→verify PASS ×2 processes, kill -9 durability, TABTEST green) |
| CW-06 | Warden core: parent-supervisor — spawn Watchtower, wait, capture exit cause (signal / NTSTATUS), restart with 1→60 s backoff | ✅ done (`warden/warden.py`; verified live: restarts, exit-cause capture, clean-stop mints nothing) |
| CW-07 | Linux packaging: systemd user unit + install-linux.sh + setup-root.sh (`core_pattern` sysctl; `LimitCORE` in the unit) | ✅ done (files shipped; enablement is per-box at deploy — not enabled on the dev machine by design) |
| CW-08 | Hang detection: in-app GUI-thread watchdog (`WT_WATCHDOG_S`, default 60 s → abort → marked SIGABRT) + Warden flightrec-silence outer net (`HANG_S` 120 s → SIGABRT/CONT/KILL ladder) | ✅ done (verified: SIGSTOP → `[WT-HANG]` abort + marker; outer net → `hang-watchdog` report 201/201) |
| CW-09 | Collector: marker → bundle — idempotent, reboot-safe boot replay, token scrub, console tail, core inclusion w/ cap | ✅ done (verified incl. fake-core inclusion + markerless SIGKILL synthesis; cores on guard boxes need setup-root.sh) |
| CW-10 | Minting policy (contractual per reply4): 3 singles / 10 min → ONE `restart-loop`, coalesced ≥60 s manifest re-PUTs, quiet-close 30 min | ✅ done (live: 4th death opened loop deaths=4; quiet-close bug found+fixed — loop now closes on time, not on next death) |
| CW-11 | Spool state machine + uploader: two-phase PUTs, §4 code table, TOFU station token | ✅ done (live 201/201s ×5; re-PUT → server `manifest_revisions=2`; stored-skip dedup live; 4xx/413 paths coded — provoked-error runs pending on CV's side or a fault-injection pass) |
| CW-12 | USB path: `warden export <dest>` + `reimport` (manifest-first dedup) | ✅ done (export verified; reimport shares the proven stored-skip path) |
| CW-13 | Operator alerting: restart / crash-loop / 401 / quarantine alarms to Roman's channel | ⛔ blocked — channel choice (Telegram / webhook / email) still open |
| CW-14 | Chaos rig vs pilot box: kill singles, kill loop (3+1 minting), hang-abort, reboot-mid-collection; **first real upload** + CV cross-confirm | ✅ done (5 first-contact reports CV-confirmed byte-for-byte, rev=2, zero rejections — reply6; reboot-replay proven `d1c185f4` 201/201; core gap → self-announcing `cores_available` annotation + startup alarm; cores on THIS box await `sudo warden/setup-root.sh`) |
| CW-15 | Endurance: ≥ 24 h soak under Warden supervision — restore fidelity, no double-collection, spool bounded, zero guard-visible artifacts beyond the ~2 s blink | 🟡 RUNNING since 2026-07-26 16:58 (`docs/perf/soak-tools/cw15-endurance.sh`, base `~/watchtower-soak/cw15-2026-07-26`): 12×2-hourly SEGV singles + hour-6 kill-loop burst + hour-12 SIGSTOP hang; ≤4 new ids in any hour (cap 30); injector pid+marker-safe vs the operator's own app; first checkpoint green (seed → restore `tabs=2 active=1 layout=9`) |
| CW-16 | Windows Warden: same Python core → PyInstaller single exe, Scheduled Task at-logon (never a service), NSIS installer wires LocalDumps + autologon + task | pending |
| CW-17 | CI archives PDBs per Windows release tag — minidumps are unreadable without them; worthless if done after the first field crash | pending |
| CW-18 | Windows chaos validation in a plain Win 10/11 VM (`taskkill /f`, suspend-as-hang, reboot mid-collection) — no GPU needed, not parked behind W2/W3 | pending |
| CW-19 | Dead-man heartbeat letter to CV (station liveness; their Prometheus→Alertmanager→ntfy plumbing) — both sides agree it's "the one with teeth" | pending — after v1, by agreement |
| CW-20 | Shipping bootstrap secret: CV mints real random value at installer-cut, delivered out-of-band, never in a repo | ⛔ blocked — on installer cut (pilot token in use meanwhile) |
| CW-21 | Docs: `warden/README.md`, DEVELOPMENT.md section, PROJECT_STATUS entries — rolls with each phase | ◐ rolling (README + dev-hook rows + PROJECT_STATUS 07-26 entry done; DEVELOPMENT.md architecture paragraph pending) |

**Build order:** CW-01…05 (in-app half, no CV dependency) → CW-06…12 (Linux Warden v1)
→ CW-14/15 (validation, first real upload) → CW-16…18 (Windows leg) → CW-19/20 (post-v1).
CW-13 slots in whenever the channel is chosen — nothing else waits on it.
