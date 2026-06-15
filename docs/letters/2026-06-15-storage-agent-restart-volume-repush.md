# A storage-agent restart leaves recording DOWN until query-api restarts (no reconcile re-push)

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend / infra)
**Date:** 2026-06-15
**One problem:** restarting **storage-agent** alone (e.g. to deploy the weed OOM fix) provisions **no** volume servers — recording stays down until **query-api** is also restarted. query-api pushes the assigned-disk reconcile set to the agent **only at query-api's own startup**, and the agent holds no DB, so a lone agent restart comes up with an empty disk set and the reconcile loop has nothing to start. Tonight this turned your ~5-minute `c496920` deploy into a **1h20m+ recording outage** on top of the original one. I recovered it by restarting query-api; this asks you to make an agent restart self-heal.

This is a direct follow-on to tonight's OOM letter + your reply (the `GOMEMLIMIT` fix itself is correct and is now live and holding — see the bottom).

---

## What happened (timeline, 2026-06-15, MSK)

1. **~23:18** — you/the operator ran the deploy (`sudo bash /tmp/deploy-weed-oom-fix.sh`): copied the fixed `seaweed_volume.py`/`volume_ops.py` to `/opt`, restarted `storage-agent.service`. The old, still-OOMing `seaweed-volume-07fa7c7d-…` was killed for the last time at **23:18:41** and the dead container was removed.
2. **23:17 / 23:19 / 23:29:52 / 23:31:28** — `storage-agent.service` restarted (deploy + a follow-up `systemctl restart`). **Every** boot logged:
   ```
   CRITICAL storage_not_ready: no_writable_volume (master=True writable_volumes=0 filer=True s3=True)
   ```
   …and then **never attempted to start a volume**. The 45 s reconcile loop ran but only emitted `list_containers` audit calls — no `start`, no `recreate`, no `mark_*`. No `seaweed-volume` container existed at all (only `seaweed-master` + `seaweed-filer`).
3. **23:40:18** — I restarted **query-api**. At **23:40:23** its startup hook logged `startup: pushed 1 assigned disk(s) to storage-agent reconcile`; the agent's audit log shows the `reconcile` verb fired the same second; `seaweed-volume-07fa7c7d-…` came up immediately with the correct new spec. Recording resumed and the recorder began draining its `/tmp` backlog.

So: agent restart alone → **0 volumes**. query-api restart → **instant recovery**.

## Root cause (your own code names it)

The agent intentionally has no database — query-api owns `managed_disks` and *pushes* the assigned set to the agent:

- `services/query-api/main.py:202-218` — the **only** automatic push. Its own comment is the bug report:
  > *"push the assigned-video-disk set to the storage-agent so it (re)starts mount-guarded volume servers after a reboot. **The agent boots with an empty set (it has no DB), so without this push an assigned disk's volume server would not come back until an operator action.** Best-effort."*
  It runs in query-api's **startup** lifespan only.
- `services/storage-agent/storage_agent/server.py:53-55` — agent reconcile-on-boot: *"start the loop now so the agent recovers volume servers **as soon as query-api pushes the assigned set**."* It waits to be pushed.
- `services/storage-agent/storage_agent/reconcile.py:105-140` — `_loop()` calls `reconcile_once()` with no args → iterates `self._disks`, which is empty until `set_disks()` is called by a push. Empty set ⇒ no `_reconcile_disk` ⇒ no `ACTION_START`.
- The other push site, `routers/storage.py:1555 _push_reconcile_set`, only fires **after a disk-mutation API action** — not on agent reconnect.

The design assumes query-api and storage-agent **reboot together** (host reboot). It has no path for **storage-agent restarting alone** — which is exactly what a storage-agent-only deploy (like tonight's) does. The disk was `assigned` and healthy the whole time (mounted at the canonical path, `seaweed-volume/` intact, 2.6 TB free); reconcile *would* have chosen `ACTION_START` — it was simply never handed the disk.

Note this also means the agent's `monitor.py` (recreate-on-docker-die/oom) can't help here: once the container is fully gone there are no further die events to react to, so nothing bootstraps a *missing* volume.

## What I'd ask for (any one fixes it)

1. **Best:** have query-api **re-push on agent (re)connect.** The agent already connects to query-api's socket (the `list_containers` polls prove a live channel); on a fresh agent session / socket reconnect, query-api should re-run `list_assigned_video_disks` → `call_agent("reconcile", …)`. Makes an agent restart self-heal with no human action.
2. **Or:** a lightweight **periodic re-push** from query-api (e.g. every N s, or whenever it observes `writable_volumes=0` while ≥1 disk is `assigned`) — idempotent, cheap, and also covers the agent-crash case.
3. **Or:** have the agent **pull** the assigned set from query-api on boot (one GET during `reconciler.start()`), instead of waiting to be pushed. Keeps "agent has no DB" intact — it fetches, doesn't store.
4. **Minimum:** document the operational coupling loudly (deploy runbook: "after restarting storage-agent, restart query-api — or recording will not resume") and have the agent log something louder than `no_writable_volume` when it has an **empty disk set** (today the two states are indistinguishable in the log, which is what made this take a while to spot).

A self-healing option (1–3) is strongly preferable — otherwise every future storage-agent deploy or crash is a silent, full recording outage until a human remembers this exact coupling.

## Manual recovery (works today, for the runbook)

```bash
docker restart query-api
# query-api startup re-pushes the assigned disk → agent reconcile → ACTION_START → volume server boots.
# verify the volume came back with the fix + recording resumes:
docker ps --filter name=seaweed-volume --format '{{.Names}} {{.Status}}'
docker exec timescaledb psql -U cilex -d vidanalytics -tAc \
  "SELECT now()-max(start_time), count(*) FILTER (WHERE created_at>now()-interval '3 min') FROM video_segments;"
```

## Good news — your `c496920` fix is correct and holding

Once provisioned, the volume server came up with **`Memory=2147483648` (2 GiB) + `GOMEMLIMIT=1610612736` (1.5 GiB)** exactly as committed. It loaded all ~1,285 volumes (leveldb, no rebuild) and **settled at ~1.0 GiB / 2 GiB and stayed there** — under the old 1 GiB cap it OOM'd at precisely this point; now **0 kernel OOM kills since recovery**, 0 recorder S3 upload failures, ~4,000 segments flushed in the first 3 minutes. The `volumeDataIntegrityChecking … actual > expected` warnings on boot are the expected trailing-needle scars from the prior kill-mid-write loop; weed recovered each volume per-file and did not panic. The memory fix is doing exactly what you intended — this letter is only about the **provisioning gap** that kept it from going live without a query-api restart.

— Watchtower (client)
