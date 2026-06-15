# Host freezes — cilex-vision containers OOM-crash-looping (go2rtc/ffmpeg, then seaweed-volume)

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend / infra)
**Date:** 2026-06-15
**One problem:** the shared host froze on 2026-06-13 and hard-rebooted 2026-06-14 21:31. Root cause is **cilex-vision Docker containers exceeding their memory-cgroup limits in a relentless OOM-kill → recreate loop**, which thrashes the host (heavy swap + dockerd/containerd churn) until it becomes unresponsive. One of the two offenders is **still looping right now**. None of this is a Watchtower (client) bug — it's backend container sizing / SeaweedFS tuning — but it runs on the box we both use, so we investigated and are handing you the evidence.

---

## Environment (at time of investigation, 2026-06-15 ~21:30 MSK)

- **Host:** `cilex-vision-MS-7E06` · Ubuntu 24.04 · kernel `6.17.0-35-generic` · 20 cores · **15.38 GiB RAM** · 4.00 GiB swap.
- **Live pressure:** MemFree **1.00 GiB**, MemAvailable 7.90 GiB, **swap 2.77 GiB used**, load average **~18**.
- **Per-container memory limits** (`docker inspect … {{.HostConfig.Memory}}`):

  | container | image | limit | live use (≈) |
  |---|---|---|---|
  | **seaweed-volume-`<uuid>`** | seaweedfs:4.25 | **1024 MiB** | **953 MiB (93%)** ⚠ |
  | **go2rtc** | go2rtc:latest-hardware | **512 MiB** | (spawns ffmpeg) |
  | **timescaledb** | — | 768 MiB | **683 MiB (89%)** ⚠ |
  | s3 (seaweed) | seaweedfs:4.25 | 512 MiB | 375 MiB (73%) |
  | seaweed-filer | seaweedfs:4.25 | 512 MiB | 357 MiB (70%) |
  | seaweed-master | seaweedfs:4.25 | 384 MiB | 41 MiB |
  | recorder-service | infra-recorder-service | 3072 MiB | 437 MiB (14%) |
  | playback-service | — | 1536 MiB | 166 MiB (11%) |

  Sum of container limits ≈ **9.0 GiB on a 15.38 GiB host** — plus the dev workload (builds/browser). The box is memory-oversubscribed, which is why it lives in swap.

All OOM kills below are **`constraint=CONSTRAINT_MEMCG`** — i.e. a container hitting *its own* cgroup limit, **not** a host-wide out-of-memory. That distinction matters (see "why this freezes the whole host").

---

## Finding 1 — Video pipeline (go2rtc/ffmpeg): 06-13 → 06-14, now DORMANT

The HEVC transcoders (`ffmpeg`, ~61 processes for the 31 cameras, spawned under **go2rtc**, limit **512 MiB**) repeatedly overflowed the cgroup and were OOM-killed and respawned.

**Counts (journal):**
- **1,341** `ffmpeg` kills on the 06-13 *calendar* day (00:02 → 23:58).
- **842** `ffmpeg` kills in the trailing **48 h** (181 on 06-13, 661 on 06-14) — **all between 06-13 21:00 and 06-14 15:56:20, then it STOPPED.** Zero ffmpeg OOM kills since 06-14 15:56 (none on 06-15).

**Verbatim evidence:**
```
Jun 14 15:04:17 kernel: Memory cgroup out of memory: Killed process 2823727 (ffmpeg)
                        total-vm:881520kB, anon-rss:31200kB, file-rss:6044kB ...
Jun 14 15:56:20 kernel:  ? __pfx_i915_gem_execbuffer2_ioctl+0x10/0x10 [i915]   ← GPU/VA-API in the OOM stack
```

**Reasoning:** ~31 MB resident per ffmpeg × dozens of concurrent transcoders easily exceeds **go2rtc's 512 MiB** cgroup. The `i915` frame in one OOM stack shows the VA-API HEVC path is implicated under pressure. This window (06-13 evening → 06-14 afternoon) is the most likely cause of the **06-13 freeze** and a contributor to the 06-14 reboot.

**It is currently quiet** (now ~61 ffmpeg at only ~230 MiB total). We don't know *why* it stopped at 06-14 15:56 — see the questions below.

## Finding 2 — Storage (SeaweedFS `seaweed-volume`): 06-14 evening → STILL ONGOING

The SeaweedFS **volume server** (`weed`, container limit **1024 MiB**) grows to ~1.0 GiB and is OOM-killed; the container is then **recreated with a fresh UUID** and the cycle repeats.

**Counts (journal, current boot since 06-14 21:31):**
- **107 distinct `seaweed-volume-<uuid>` containers** have OOM'd this boot (~24 h) — i.e. it's been recreated ~107 times.
- Killed roughly **every ~3 minutes** in bursts; **most recent kill 06-15 21:32:22** (live).

**Verbatim evidence:**
```
Jun 15 21:32:22 kernel: Memory cgroup out of memory: Killed process 2145023 (weed)
                        total-vm:3014620kB, anon-rss:1025760kB ...   ← 1,025,760 kB ≈ 1.0 GiB = the 1024 MiB limit
```

**Reasoning:** a SeaweedFS volume server's RAM scales with its **needle index** (grows with the number of stored files). As motion clips accumulate, the in-memory index outgrows **1 GiB**, so it dies at the limit, restarts, reloads the index, regrows, dies again. The **new-UUID-per-restart** pattern implies a controller (recorder-service?) recreates the volume container on crash, which *amplifies* the churn (full container teardown/recreate, not just a process restart).

## The 06-14 hard freeze (mechanism, reconstructed)

```
20:13 / 20:49 / 21:11  weed OOM-killed (escalating)
21:30:24               dbus: org.freedesktop.resolve1 activation TIMED OUT (25s)
21:30:50–21:30:57      dockerd: container health-checks TIMED OUT (×4)   ← host going unresponsive
21:31:04               journal stops abruptly — NO clean-shutdown sequence
21:31:33               kernel boot (forced power-cycle / hard reset)
```
No `systemd Stopping…/Reached target Shutdown` lines precede the gap — the classic signature of a **hard freeze followed by a forced reboot**.

## Why a *per-container* OOM freezes the *whole* host

These are cgroup OOMs, so no single container exhausts host RAM — but the **kill → recreate → reload → regrow** loop (a) burns `containerd`/`dockerd` CPU recreating containers (107×/day), (b) reloads large state (the volume index, transcoder buffers) back into RAM each cycle, and (c) keeps the host pushing **~2.8 GiB into swap**. Under a sustained storm (06-13 all day, 06-14 evening) the host thrashes into unresponsiveness. The ~9 GiB of limits on 15 GiB + dev work is the underlying squeeze.

---

## How we'd approach the fixes (recommendations, in priority order)

1. **`seaweed-volume` (LIVE, do first):** raise the limit **1 GiB → 2–3 GiB**, *and* prefer a **disk-backed / leveldb volume index** (`-index=leveldb`/`leveldbLarge`) so RAM stays bounded as storage grows — otherwise any fixed limit is just a slower fuse. Also check what recreates the container with a new UUID on each crash; a plain restart-policy would churn less.
2. **`go2rtc` / ffmpeg (prevent recurrence):** 512 MiB is too small for N HEVC transcoders. Raise to ~1–2 GiB sized to the camera count, and/or cap concurrent transcodes and confirm HW (VA-API) decode is actually engaged so per-stream RAM is bounded. Ensure one OOM doesn't trigger a respawn *storm* (rate-limit/backoff).
3. **`timescaledb`:** 768 MiB → ~1 GiB (it sits at 89%; it's the next likely casualty).
4. **Right-size the host:** add RAM, or reduce concurrency (fewer simultaneous transcodes / lighter dev load). Consider per-container `mem_reservation` in addition to limits.
5. **Alerting:** you already run Prometheus + Grafana — add a `container_oom_events_total` / `container_memory_usage / limit > 0.9` alert so this is caught *before* a freeze rather than forensically after.

## Questions for you (please confirm status — fixed / new / pending)

1. **go2rtc/ffmpeg storm:** is this a **known/already-fixed** issue? Something appears to have changed at ~06-14 16:00 that stopped it — was that a config/limit change on your side, or did it merely pause after the 21:31 reboot and **will it recur**?
2. **seaweed-volume 1 GiB loop:** is this **new to you or already tracked**? It is actively risking another freeze **right now** (latest kill 21:32, ~107 recreations today).
3. **Container recreation:** what recreates `seaweed-volume-<uuid>` with a new UUID on each crash — intended (per-volume lifecycle) or a crash-restart artifact?
4. **Limits:** are these memory limits **intentionally tuned** or defaults from the compose file? Are you OK with us (or you) **raising them on this host**, and is there a canonical compose we should edit rather than `docker update` live?
5. Is any of this **already addressed in a newer build/compose** we should pull?

## How to reproduce / verify (read-only)

```
journalctl --since '48 hours ago' | grep 'Killed process' \
  | grep -oE 'Killed process [0-9]+ \([^)]+\)' | sed -E 's/.*\(([^)]+)\)/\1/' | sort | uniq -c    # by process
docker inspect --format '{{.Name}} {{.HostConfig.Memory}}' <container>                            # the limit
docker stats --no-stream                                                                          # live use vs limit
free -h ; uptime                                                                                  # swap + load
journalctl -b -1 | tail -30                                                                       # the 06-14 freeze edge
```

— Watchtower (operator client)
