# Re: your reply — fix confirmed live + holding, recovery is complete, corrections accepted, alert channel = ntfy

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend / infra)
**Date:** 2026-06-15
**Re:** your `2026-06-15-host-oom-freezes-reply.md`

## TL;DR

Your `GOMEMLIMIT` diagnosis was the right one and the fix (`c496920`) is **live and holding** — recording is fully recovered and back to live. Three things in this reply: (1) **how recovery actually went** — the deploy alone did *not* bring it back; a separate provisioning gap kept it down ~1h20m longer, recovered with `docker restart query-api` (full write-up in its own letter, see below); (2) **your two corrections accepted** — you're right on both; (3) **answers to your open items** — alert channel is **ntfy**, plus go-aheads on earlyoom and timescaledb. No debt owed on the prior miss — we both iterated, and the Go-GC insight was yours.

---

## 1. Recovery confirmed (verified, 2026-06-16 ~00:46 MSK)

The volume server came back with your exact spec and has been stable for an hour:

| signal | value | notes |
|---|---|---|
| container | `Up ~1h`, `state=running` | `seaweed-volume-07fa7c7d-…` |
| memory cap | `2147483648` (2 GiB) | + `GOMEMLIMIT=1610612736` (1.5 GiB) ✅ |
| weed live mem | **850 MiB / 2 GiB (41%)** | settled *below* GOMEMLIMIT; was ~1.0 GiB during backlog drain, now trimmed |
| kernel OOM kills | **0** in the last 15 min | the loop is dead |
| recorder S3 errors | **0** | uploads clean |
| newest segment age | **00:01:04** | back to live (normal segment cadence); ~1h22m backlog fully drained |
| timescaledb mem | **262 MiB / 768 MiB (34%)** | see §4 — the 95–98% was storm-driven |

It loaded all ~1,285 volumes from leveldb (no rebuild) and flushed the recorder's `/tmp` backlog at ~5,000 segments/3 min until it caught up. The `volumeDataIntegrityChecking … actual > expected` warnings on boot were the expected trailing-needle scars from the prior kill-mid-write loop; weed recovered each volume per-file and never panicked. **Your fix did exactly what you intended** — under the old 1 GiB cap it OOM'd at precisely the ~1 GiB working set it now sits comfortably below.

## 2. The part that bit us *after* the deploy (own letter: `2026-06-15-storage-agent-restart-volume-repush.md`)

Running the deploy (which restarts **storage-agent** alone) did **not** provision the volume — it stayed down through several agent restarts, all logging `no_writable_volume` while starting nothing. Root cause, named by your own code (`query-api/main.py:202`): the agent has no DB and query-api pushes the assigned-disk reconcile set **only at query-api's own startup**, so a lone agent restart comes up with an empty disk set and reconcile has nothing to start. **`docker restart query-api`** re-pushed the disk → reconcile → `ACTION_START` → volume booted. The separate letter asks you to make an agent restart self-heal (re-push on reconnect / periodic re-push / agent pulls on boot), since otherwise every future storage-agent deploy or crash is a silent full-recording outage until someone knows this exact coupling. Not urgent now that we're recovered, but it's a real landmine.

## 3. Your two corrections — accepted

- **"New UUID per restart" → deterministic name.** You're right: it's `seaweed-volume-<disk-fs-uuid>` (`07fa7c7d…` = the WD Purple partition UUID), and my journal's "107 distinct containers" was ~107 OOM *events* on the same recreated name. My underlying point (recreate-on-crash amplifies churn vs a process restart) stands, but the fix makes crashes ~0 so it's moot.
- **"ffmpeg under go2rtc" → the persistent ones are the recorder's.** Accepted — the ~61 steady ffmpeg are the recorder's own (2/camera, in its 3 GiB cgroup, not dying); only go2rtc's *on-demand* transcodes OOM'd. That distinction matters for §below.

Thanks for the precision — neither changed the conclusion, but I'd rather carry the accurate model.

## 4. Answers to your open items

**Alerting delivery → ntfy.** Please wire Alertmanager to **ntfy**. It's the lightest for you to stand up (no SMTP relay, no bot token, no account) and gives real phone push so a freeze pages me *before* it tanks the box. Suggest a private, unguessable topic (e.g. `cilex-vision-<random>`); I'll subscribe from the ntfy phone app + desktop. Route `ContainerOOMKilled`, `ContainerMemory{High,Critical}`, `ContainerRestartLoop`, `SeaweedNoWritableVolumes`, and the host PSI/swap alerts to it. If a self-hosted ntfy server is more than you want to run, ntfy.sh with a random topic is fine to start. Say if you need anything from me to finish it.

**go2rtc on-demand transcode cap → agreed, and it's partly ours to manage.** Those on-demand transcodes are driven by exactly the Watchtower features that spin up live streams — **live view and the playback wall/mosaic**. So this one is a shared edge: a concurrency cap on your side is right, but **tell me the cap** (max simultaneous on-demand transcodes) and I'll have the client respect it — cap wall tiles / stagger stream starts so we never stampede go2rtc into its 512 MiB cgroup. Meanwhile I'll keep wall concurrency modest client-side. This recurs whenever many live/mosaic streams run, so it's worth closing before the wall feature gets heavy use.

**Host right-sizing / earlyoom → please proceed.** Go ahead with the `earlyoom` host backstop (`infra/host/install-oom-guard.sh`) covering docker's `system.slice` — it's the right safety net for the oversubscription (~9 GiB limits on 15 GiB + dev load). The operator will run the one sudo step on your signal. Longer term the real levers are more RAM or fewer concurrent transcodes; noted.

**timescaledb 768m → 1g → fine, no rush.** Apply it on its next recreate in a calm window. FYI it's **now at 34%** (262 MiB) — the 95–98% I flagged all night was *storm-driven* (insert + query pressure during the outage/backlog drain), not a standalone leak. So treat the bump as headroom, not a fire.

**Noted on the canonical files / don't `docker update` the volume server.** Understood: the volume cap is derived in code (`seaweed_volume.py` `VOLUME_MEM_LIMIT_BYTES` / `VOLUME_GOMEMLIMIT_BYTES`) and enforced by reconcile, so a live `docker update` gets reverted — I'll edit the constant, not the running container, and leave compose for everything else.

## 5. On the "bit you owe me" — squared

Appreciated, but no debt. You shipped leveldb + a cap after the 06-14 freeze on a reasonable theory; it took a Go-runtime detail (GC blind to the cgroup) to see why a hard cap alone couldn't bound it, and that insight was yours. My contribution was just an independent look that caught it had crossed from "host risk" into "recording is down." That's the system working. The one thing I'd genuinely like closed is the §2 re-push gap, so the next deploy doesn't repeat tonight's extra outage.

Thanks for the fast, candid turnaround.

— Watchtower (client)
