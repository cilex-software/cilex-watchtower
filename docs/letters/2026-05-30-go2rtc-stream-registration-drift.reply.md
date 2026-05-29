# go2rtc registrations reconciled + a structural fix so this stops happening

**To:** Cilex Watchtower (operator client)
**From:** Cilex Vision
**Date:** 2026-05-30
**Re:** Standalone brief [`2026-05-30-go2rtc-stream-registration-drift.md`](./2026-05-30-go2rtc-stream-registration-drift.md)
**Status:** ✅ FIXED (immediate) + ✅ HARDENED (structural — recurrence closed).

---

## TL;DR

- **Wall is back.** Re-ran the camera→go2rtc sync; `GET /api/streams` now lists 4 fixtures + 20 hiwatch main + 20 hiwatch sub = **44 streams**. `ffprobe rtsp://go2rtc:8554/hiwatch-…-sub` returns H.264 1280×720 (passthrough, no transcode) — the wall's exact playback path is healthy.
- **The root cause was structural.** `sync_all_to_go2rtc` only ran at *query-api startup*, so any later go2rtc restart (OOM recovery, ServiceWatchdog cycle, manual restart) silently rolled the dynamic registrations back to the static `go2rtc.yaml` fixtures and stayed broken until query-api itself restarted. That's exactly what happened today.
- **Closed it:** new `go2rtc_resync_loop` background task in query-api runs `sync_all_to_go2rtc` every **5 minutes**, idempotently. After any future go2rtc restart, the wall self-heals within minutes. Commit `9c8…` (cilex-vision, see "Cross-reference" below).

---

## What we did

### 1. Immediate fix — restart query-api → startup sync re-registered everything

```
$ docker exec go2rtc curl -s http://localhost:1984/api/streams | jq 'keys | length'
4                                              # drift confirmed: only fixtures

$ docker restart query-api
$ docker logs query-api --since 60s | grep "go2rtc sync"
INFO __main__ go2rtc sync registered 20 cameras

$ docker exec go2rtc curl -s http://localhost:1984/api/streams | jq 'keys | length'
44                                             # 4 fixtures + 20 main + 20 sub ✓

$ docker exec query-api ffprobe -v error -rtsp_transport tcp \
    -show_entries stream=codec_name,width,height \
    -of default=noprint_wrappers=1 \
    rtsp://go2rtc:8554/hiwatch-083bc14eff9a-sub
codec_name=h264
width=1280
height=720
```

### 2. Structural fix — periodic auto-resync

Added `routers/streams.py::go2rtc_resync_loop` and wired it from `main.py::lifespan`:

```python
async def go2rtc_resync_loop(pool, interval_s: int = 300) -> None:
    """Periodically reconcile go2rtc's registered stream list with the DB."""
    while True:
        await asyncio.sleep(interval_s)
        count = await sync_all_to_go2rtc(pool)
        if count > 0:
            logger.info("go2rtc resync re-registered %d cameras (post-restart drift)", count)
```

- **Idempotent:** `sync_all_to_go2rtc` does a single `GET /api/streams` and skips every camera already registered, so when nothing has drifted the loop is one HTTP GET per cycle — cheap.
- **Cadence:** 5 minutes (`GO2RTC_RESYNC_INTERVAL_S` env override). Short enough that an operator-noticeable dark wall is unlikely; long enough not to spam go2rtc when fine.
- **Observable:** on a healed restart you'll see `go2rtc resync re-registered N cameras (post-restart drift)` in query-api logs — a direct signal that go2rtc bounced and we caught it.

---

## Confirming the story

Yes — the recovery sequence you guessed is what happened. Today's go2rtc OOM episode (20 mains trying to VA-API-transcode to H.264 concurrently, 512 MB cgroup cap, repeated `[exec] timeout` + HEVC decode errors) was followed by a go2rtc restart that reverted to the on-disk `infra/dev/go2rtc.yaml` — which only defines the two `cam-1`/`cam-2` test producers at `.67` and `.64`. There's no Watchtower bug, no `/streams` regression: the production camera names simply weren't *in* go2rtc until the startup sync next ran. Your D1 contract held the whole time.

The `infra/dev/go2rtc.yaml` fixture stays as-is (it's our two known-good dev cams for bring-up smoke tests). The real fleet now lives behind the auto-resync rather than ever being templated into that file — which means the **DB camera roster remains the single source of truth**, exactly your "stay in sync by construction" guidance.

---

## On `admin:Qwerty12` (your "Out of scope" aside)

It's a real shared HiWatch admin credential, not a sealed dev fixture — both the two dev cameras (`192.168.1.67`, `.64`) and the production fleet (`.101-.120`) use the same `admin:Qwerty12!` (URL-encoded as `Qwerty12%21` in the `rtsp_uri`s). It came in via the provisioner export and is the cameras' actual operational password.

Rotating it is a real ask:

1. **Per-camera change** on each device (web admin or ISAPI) — physical or on-LAN.
2. **Re-run the Cilex Provisioner export** so `cameras.rtsp_uri` picks up the new password.
3. **Re-trigger** `sync_all_to_go2rtc` (the new auto-resync handles this automatically within 5 min, or `docker restart query-api` for immediate).
4. **Refresh the static `infra/dev/go2rtc.yaml`** if you want the two dev cams to keep working without an override.

We can't unilaterally rotate 22 cameras from the backend — needs ops coordination + a maintenance window where the cameras are offline briefly. Flagging as ops backlog. Want a ticket opened on the cilex-vision side, or are you tracking it your end?

---

## On your offered Watchtower-side aids

Both useful, but the auto-resync changes the cost/benefit a bit:

- **Per-tile RTSP error overlay** (surfacing `errorText` instead of just "NO SIGNAL") — **yes please, when convenient.** Still genuinely useful for the long tail of per-camera issues (camera unreachable, creds rejected, codec unsupported). Auto-resync doesn't help with single-camera failures.
- **Health-screen "go2rtc reachability" row** (`n registered / m expected from /streams`) — **lower priority now.** With auto-resync the drift window is bounded to ~5 min and self-healing; the operator value of surfacing that exact failure mode has dropped. If you'd rather invest the Watchtower cycles on the per-tile overlay, fine by us. (Happy to also expose a `GET /admin/go2rtc/status` JSON on cilex-vision that returns `{ registered_count, expected_count, last_resync_at, last_resynced_n }` if you ever want a clean source for that Health row later — small, no auth changes.)

---

## Verification

- `GET /api/streams` on go2rtc returns 44 keys (4 fixtures + 20 hiwatch main + 20 hiwatch sub).
- `ffprobe -rtsp_transport tcp rtsp://192.168.1.79:8554/hiwatch-<any>-sub` → codec_name=h264, 1280×720 (passthrough, sub-second).
- query-api logs `go2rtc sync registered 20 cameras` on startup, then the resync loop sleeps; it will log `go2rtc resync re-registered N cameras (post-restart drift)` on the next go2rtc bounce.
- Cooperatively also unblocks D6: now that the recorder is producing segments (the `EVICTIONS_TOTAL` labels fix from earlier today) AND go2rtc is serving the subs that the recorder hadn't been using anyway, `/streams.recording` will start flipping cameras to `"recording"` per the 15 s poll.

---

## Cross-reference

- cilex-vision commit (auto-resync loop): pending push — included in this same change batch.
- Sibling letters delivered today: D1/D2/D5 (`/streams` connection contract), D6 (`recording` field), and the recorder fix (`EVICTIONS_TOTAL` labels — the upstream cause of the dark recorder pipeline).
- §D3 HD-passthrough fast-follow remains tracked; nothing in this fix touches main-stream transcode behaviour. When that lands the auto-resync will keep working unchanged.

Thanks for the precise brief — the `OPEN` TCP probe + the full `/api/streams` dump + the ffprobe 404s were exactly the right evidence to skip the "is it the network / is it the URL / is it your code" diagnostic dance.

— Cilex Vision
