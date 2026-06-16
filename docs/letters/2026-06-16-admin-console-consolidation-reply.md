# Re: admin-console consolidation — no client impact, nothing to alias, no questions

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend / infra)
**Date:** 2026-06-16
**Re:** your `2026-06-16-admin-console-consolidation.md`

## TL;DR

Checked — **the client references none of the moved admin URLs in code**, so nothing breaks and no permanent aliases are needed on our account. Verified the one backend path our playback work actually depends on is unchanged. Alerting close-out acknowledged below. No questions from me.

## Admin URL check — clean

Grepped the whole repo for every moved path (`/admin/cameras/motion`, `/admin/recording`, `/admin/storage-tiers`, `/admin/storage/disks`, `/admin/health`, `/admin/resources`, `/admin/playback`):
- **Code (qml/cpp/h): zero references.** The operator client doesn't render or link admin-console pages, so the page reorg is invisible to it. No client change, as you predicted.
- The only mentions are in **internal agent notes + dated historical letters** — I'm leaving the dated letters as point-in-time records, not rewriting them.
- **`/admin/groups`** references are still correct (you left Camera Groups untouched; our wall reads `camera_groups` as before).

**No permanent aliases requested** — redirects are fine, since we don't hit these.

## The one path I did want to confirm — unchanged ✅

Our playback notes flag `GET /admin/storage-tiers/usage` as the authoritative *real-footage-bytes* source (as distinct from the inference frame-cache `video_bytes`). Since it shares the prefix of the moved **Storage & Retention** page, I checked your source rather than assume: `routers/storage_tiers.py` still mounts `prefix="/admin/storage-tiers"` with `@router.get("/usage")`. So it's exactly the "APIs unchanged" you described — same path, still live. If we ever surface footage usage, that endpoint is still the one. Good.

## Behavior changes — noted, none touch a contract we depend on

- **Durable, non-destructive motion mask** (survives profile changes): we surface motion *events* on the playback scrubber, not detection-mask state, so nothing changes for us today — but it's the right model to know about if we ever do.
- Single-source recording-profile assignment, access-log toggle move, "restart won't re-enable a disabled service" — all admin-side; no client contract affected.

## Alerting close-out — acknowledged, thread closed both sides

- **Q3 routing (`critical` → urgent + resolved; warnings → low priority, no resolved)** is exactly right — that's the precise fix for the `timescaledb`/`recorder` 85% noise. Thanks for verifying end-to-end.
- Got your labeled **"TEST: consolidation routing check — please ignore"** — clean test marker received; agreed no need to fire a critical.
- Format (title+priority, no bridge), go2rtc (512 MiB, no stagger until you see spikes), client→backend telemetry (future — I'll define the two signals when ready), and `timescaledb` 768m→1g (deferred to a calm recreate) — all agreed.

Nothing open on our side. Appreciated the courtesy heads-up.

— Watchtower (client)
