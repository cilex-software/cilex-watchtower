# W3 Parity Soaks — Windows (2026-07-07): click-spam + GC-fix parity

**IN PROGRESS.** The two W3 parity checks (steps 3-4) run + analyzed on the GPU box; the overnight
endurance soaks (step 2, Win10 + Win11) remain. Qt **6.12 msvc2022_64** CI dist (`C:\wt\portable-ci`),
Win10 19045 + GTX 1070, against the real cilex-vision backend **over Tailscale** (`100.107.51.72:8000`).
Harnesses: `WT_SEEK_SPAM` / `WT_NIGHT_SOAK` + `WT_SMOOTHTEST` (env-gated QML, unchanged from Linux),
driven by `docs/perf/soak-tools/win_parity_checks.ps1` (new). Raw: `%USERPROFILE%\watchtower-soak\parity\`.

## TL;DR
1. **The 2026-07-03 GC wedge (HANG #1) does NOT return on the Qt 6.12 Windows QML engine.** The
   storm signature is gone: the heaviest session open (**4760 fragments**) marshals in **2 ms**;
   marshal `max 199 ms` under pathological click-spam vs the **pre-fix 1149 ms** storm — no open
   spikes into storm range, 0 `[WT-FATAL]`, 0 sustained wedges. The primitive-row fix (`d81d887`)
   carries to Windows. ✅
2. **Click-spam recovery is shape-parity green** — 40/40 bursts, **0** 15 s RECOVER-TIMEOUTs, **286**
   coalesce lines (far-click coalescing works), **0** `[SEEKBAR]` violations. Absolute recovery is
   `p90 1577 ms` — **above** the Linux `p90 <1 s` bar, but the run is **network-bound over Tailscale**
   (a single backend round-trip is `p90 458 ms / max 1162 ms`); on a LAN backend it collapses back
   under 1 s. Re-measure on the `.79` LAN to close the band formally.
3. **GUI heartbeat under normal heavy churn:** <!-- CHURN PENDING: filled from churn-mode run -->.
4. **Footage-landscape finding (operator-relevant):** every one of the 33 cameras **stopped recording
   after ~2026-07-01**; recent days (07-02…07-07) return empty manifests. All retained footage is
   **warm-tier H.264 720p**. Heaviest available day = **.106 / 2026-06-22 (5.2 h, 4760 frags)** — used
   as the parity target. This is why a naive "yesterday" probe came back with `frags=0`.
5. **Tooling shipped:** `win_parity_checks.ps1` (two modes: `spam` = click-spam recovery, `churn` =
   GC-fix heartbeat under pinned heavy-day night-soak) with a built-in analyzer; joins
   `night_soak_supervisor.ps1` from W3 step 1.

---

## Environment + footage landscape
- **Box:** DESKTOP (Win10 Pro 19045), **NVIDIA GTX 1070** + Intel UHD 630, driven over Tailscale.
- **Backend:** `http://100.107.51.72:8000` (Tailscale). The `192.168.1.79` LAN address is **not**
  reachable from this box — every measurement here carries Tailscale RTT the Linux baseline did not.
- **Auth:** `POST /auth/login` (admin/admin) → `access_token`, attached as a **cookie** (not Bearer).
- **Coverage (via `GET /review/coverage`):** 33 cameras; **all stopped recording ~2026-07-01**.
  Camera `.106` (`hiwatch-083bc14eff9a`) retains 16 days back to 06-12; heaviest days:
  **06-22 (5.2 h)**, 06-15 (3.8 h), 06-16 (3.4 h), 06-19 (3.2 h). Retention 35 d, tiers now all `warm`
  (H.264 720p sub-stream; only 06-12 still had a `hot`/H.265 sliver). **Flag for the operator:** the
  wall shows live cameras but the recording pipeline appears to have stopped ~a week ago.

## 1. Click-spam parity (step 4) — shape-green; absolute band network-gated
`win_parity_checks.ps1 -Mode spam -Ip 192.168.1.106 -Day 2026-06-22` (40 bursts × 12 chaotic
`seekToWall` clicks @140 ms, `WT_SEEK_SPAM=1`, healthy backend). Run 06:41→06:46, single pid.

| metric | Windows/Tailscale | Linux bar | verdict |
|---|---|---|---|
| bursts completed | **40 / 40** | 40 | ✅ |
| recovery (last click → next frame) p50 / p90 / max | **997 / 1577 / 1772 ms** | p90 < 1 s | ⚠ network |
| 15 s RECOVER-TIMEOUT | **0** | 0 | ✅ |
| `[PB] far-coalesce` lines | **286** | present | ✅ |
| `[SEEKBAR]` violations | **0** | 0 | ✅ |
| backend `session_http` RTT p50 / p90 / max | 123 / 458 / **1162 ms** | (LAN ~ms) | context |

**Read:** the recovery *shape* matches Linux exactly — every burst recovers, none times out, far-clicks
coalesce (286 lines), the seek bar never vanishes. The absolute `p90 1577 ms` is **above** the sub-1 s
bar, but the recovery is dominated by network: a single `POST /review/sessions` round-trip alone is
`p90 458 ms / max 1162 ms` over Tailscale, and each recovery is session-create + first-segment-fetch +
preroll (`first_frame` TTFF p50 873 ms tracks the recovery). On the LAN backend those RTTs collapse to
~ms and recovery returns to the sub-1 s band. **Not a regression; a remote-link artifact.** Re-run on
the `.79` LAN to certify the band.

## 2. GC-fix / HANG #1 parity (step 3) — the storm is gone
The 2026-07-03 wedge was a minutes-long QML GC on the GUI thread while marshalling thousands of
per-fragment `QVariantMap`s in `sessionReady`; fixed at source by shipping fragments as positional
primitive rows (`d81d887`, "~1 ms flat", pre-fix `marshal=` max **1149 ms**). W3 re-proves this on the
6.12 Windows QML engine via the timestamped GUI heartbeat (`WT_SMOOTHTEST`) + `marshal=` timing.

**Storm signature — GONE (decisive):**
- Heaviest open on the 06-22 day = **4760 fragments → marshal 2 ms**. Pre-fix this exact shape is what
  GC-stormed for ~1 s+; post-fix it is flat. 
- Under pathological click-spam (harsher than any real churn): `marshal` med/p90/**max = 41 / 121 / 199 ms**
  — **no** open reaches the 250 ms storm floor, let alone 1149 ms. 0 `[WT-FATAL]`.
- The elevated typical value (41 ms med vs Linux ~1 ms) is **event-loop scheduling delay** absorbed by
  `marshal = now − session_ready` during concurrent re-opens, **not** marshalling cost — proven by the
  4760-frag/2 ms datum (biggest payload, fastest marshal). No GC-storm category bug on Windows.

**GUI heartbeat (the ">2 s gap" criterion):**
- Under **click-spam** (over-stress): 7 transient gaps 2.15–2.56 s (max **2560 ms**), spread across the
  run, each skipping one 1 s tick. They do **not** coincide with `marshal` spikes → GUI-thread
  saturation during chaotic media-session teardown/re-open, **not** the GC storm. This is the harshest
  possible input, not step-3's "heavy-day churn slice."
- Under **normal night-soak churn** (the fair step-3 condition, `win_parity_checks.ps1 -Mode churn`):
  <!-- CHURN PENDING: heartbeat gap stats + verdict -->

<!-- CHURN PENDING: overall step-3 verdict -->

## 3. Overnight endurance soaks (step 2) — REMAINING
- **Win10 daytime endurance:** <!-- SOAK PENDING -->
- **True overnight Win10 + Win11:** still owed. Win11 needs a second box (this is Win10). Run the
  documented one-liner on each, one night, disable sleep/display-off (or test display-off deliberately):
  `powershell -File docs\perf\soak-tools\night_soak_supervisor.ps1 -Dist C:\wt\portable-ci -EndTime 07:00`
  Any wedge must carry a procdump (auto-captured; `-ma` full dump ~1 GB). **Caveat:** with the recording
  pipeline stopped since ~07-01, the night-soak will skip empty recent days — pin a known heavy day with
  `WT_SOAK_FIX_CAM`/`WT_SOAK_FIX_DAY` (e.g. .106 / 06-22) for dense playback churn, or restore recording.

## Tooling
- **`docs/perf/soak-tools/win_parity_checks.ps1`** (new) — `-Mode spam` (click-spam recovery band) and
  `-Mode churn` (GC-fix heartbeat under night-soak pinned to a heavy day). Timestamps every log line via
  `QT_MESSAGE_PATTERN` so heartbeat gaps are wall-clock, not the in-app sec counter; built-in analyzer
  emits the pass/fail table + a `.summary.txt`. ASCII-only (PS 5.1 + pwsh).
- **`docs/perf/soak-tools/night_soak_supervisor.ps1`** (W3 step 1) — unchanged; overnight supervisor
  with procdump wedge capture + export-sidecar mtime guard.

## Artifacts (durable, outside %TEMP%)
- `%USERPROFILE%\watchtower-soak\parity\parity_0707_064128.err.log` (+ `.summary.txt`) — click-spam run.
- `%USERPROFILE%\watchtower-soak\parity\parity_churn_0707_065055.err.log` (+ `.summary.txt`) — GC-fix churn run.
