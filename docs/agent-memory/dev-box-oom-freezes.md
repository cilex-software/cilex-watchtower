---
name: dev-box-oom-freezes
description: "The dev/backend box (cilex-vision-MS-7E06, 15GiB/20-core) freezes due to cilex-vision Docker containers OOM-crash-looping — NOT a Watchtower bug. Recurring."
metadata: 
  node_type: memory
  type: project
  originSessionId: 057dd61f-f06d-42c8-ac7c-9035085a07c1
---

The machine hosts BOTH the Watchtower dev work AND the cilex-vision backend (docker). PC freezes are caused by **container memory limits set too low → relentless OOM-kill crash-loops → host swap-thrash + dockerd/containerd churn → unresponsive → freeze/forced reboot.** Not a Watchtower client bug.

Evidence (investigated 2026-06-15). TWO containers at TWO times, same root cause:
- **VIDEO PIPELINE (ffmpeg) — 06-13→06-14, now DORMANT:** `ffmpeg` OOM kills (HEVC transcoders, ~61 procs / 31 cams). 1,341 on the 06-13 calendar day; 842 in the 48h window — ALL between 06-13 21:00 and **06-14 15:56:20, then STOPPED** (none since; none on 06-15). This was the likely 06-13 freeze cause + a 06-14 contributor.
- **06-14 hard freeze:** ffmpeg storm to 15:56 + SeaweedFS `weed` loop in the evening → dbus/docker health-check timeouts 21:30 → journal halts abruptly 21:31:04, no clean shutdown → forced reboot.
- **STORAGE (weed) — 06-14 evening → STILL ONGOING:** `seaweed-volume-<uuid>` (SeaweedFS volume server) limit=1GiB, ~953MiB (93%), OOM-killed + recreated every ~3 min (most recent 06-15 21:13). THIS is the live problem now (not ffmpeg). `timescaledb` at 89% (768MiB). free ~1.2GiB, swap 2.8GiB/4GiB, load ~18.
- Container memory limits sum to ~9.0 GiB on a 15 GiB host + dev workload → oversubscribed → swap.

Key numbers: host 15.38GiB/20-core; container limits sum ~9GiB; go2rtc limit **512MiB** (ffmpeg parent), seaweed-volume **1024MiB**, timescaledb 768MiB (89%), recorder 3GiB, playback 1.5GiB. seaweed-volume recreated **107×** this boot.

**Fix (backend/infra, NOT applied — pending Cilex Vision):** raise seaweed-volume limit (1→2-3GiB) AND switch SeaweedFS to disk/leveldb index; raise go2rtc 512MiB→1-2GiB + rate-limit ffmpeg respawn; bump timescaledb; add RAM / reduce transcodes; add Prometheus OOM alert.

**LETTER SENT (2026-06-15, commit 95e3b60):** `docs/letters/2026-06-15-host-oom-freezes.md` — full 48h evidence + reasoning + fixes + questions (is each fixed/new/pending?). See [[playback-via-cilex-vision]].

**RESOLVED 2026-06-15 ~23:40 MSK.** Cilex Vision reply (`/home/cilex-vision/projects/cilex-vision/docs/letters/2026-06-15-host-oom-freezes-reply.md`): weed is a **Go** binary → its GC is blind to the cgroup cap, so the 1 GiB cap was "a metronome, not a bound." Real fix `c496920` = **`GOMEMLIMIT=1.5 GiB` (soft, the actual bound) + 2 GiB hard cap**, deployed to `/opt` via `sudo bash /tmp/deploy-weed-oom-fix.sh`. Verified live + holding: weed settles ~1.0 GiB/2 GiB, **0 OOM kills since**, recording resumed. timescaledb 768 m→1 g staged in compose (applies next recreate — do in a calm window).

**OPERATIONAL GOTCHA (cost ~1h20m extra outage; letter `docs/letters/2026-06-15-storage-agent-restart-volume-repush.md`):** restarting **storage-agent alone provisions NO volume servers** → recording stays down. The agent has no DB; query-api pushes the assigned-disk reconcile set **only at query-api's own startup** (`query-api/main.py:202`). A lone agent restart = empty disk set = reconcile starts nothing (logs `no_writable_volume` forever). **RECOVERY: `docker restart query-api`** (no sudo) — its startup hook re-pushes → agent reconcile → `ACTION_START` → volume server boots. **FIXED by Cilex Vision `af96735` (deployed): query-api now re-pushes every 60s, so a lone storage-agent restart self-heals in ~60s.**

**BOX NOW HAS GUARDRAILS (06-16, thread fully closed — letters `2026-06-16-go2rtc-cap-done-and-alerting-answers.md` + `2026-06-16-alerting-confirmed-earlyoom-active-closeout.md`):** (1) **Alerting live:** Prometheus→Alertmanager→self-hosted **ntfy** (host `100.107.51.72:18827`, topic `cilex-alerts-2f06e893fbf1`); operator subscribed + receiving alerts. (2) **earlyoom.service active** = whole-host backstop: SIGTERM mem≤10%/swap≤6%, `--avoid` weed/postgres/python3(storage-agent)/dockerd/containerd/sshd/tailscaled, `--prefer` ffmpeg/chrome. (3) **go2rtc HD storm capped client-side:** live wall is SD-by-default, concurrent HD tiles capped at 6 (`1f399bf`) → keep go2rtc at 512MiB. Still LATER-not-now: timescaledb 768m→1g on next calm recreate; a client→backend telemetry channel so client-only failures can alert.
