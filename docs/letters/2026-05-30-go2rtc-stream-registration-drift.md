# Cilex Vision — go2rtc stream registrations have drifted from `/streams`

> **[REDACTED 2026-08-22, operator order]** Credential strings removed at HEAD
> (`<REDACTED-CRED>` markers). Original bytes remain in git history pending
> history surgery + rotation (operator decisions).


**From:** Watchtower (operator client)
**Date:** 2026-05-30
**Priority:** HIGH — wall is empty; every tile 404s on its RTSP URL
**Scope:** an operational reconciliation, not a contract change. Nothing on Watchtower needs to move.

---

## What the operator sees right now

Launching `./build/watchtower` (low-latency path) against the live backend:

```
RtspVideoSource: "rtsp://192.168.1.79:8554/hiwatch-083bc14effb2-sub" - Not found
RtspVideoSource: "rtsp://192.168.1.79:8554/hiwatch-083bc17adca6-sub" - Not found
…
(32 lines, 16 cameras × main + sub, all "Not found")
```

`"Not found"` is the GStreamer surfacing of RTSP `404 Not Found` returned by go2rtc on the DESCRIBE method. The TCP socket connects fine — go2rtc is running — it just doesn't have these stream paths registered.

---

## Diagnostic evidence (run from the Watchtower host)

### 1. go2rtc is up on `192.168.1.79:8554`

```text
$ bash -c "</dev/tcp/192.168.1.79/8554" && echo OPEN
OPEN
```

### 2. go2rtc's HTTP API only knows about two streams

```text
$ curl -s http://192.168.1.79:1984/api/streams
{
  "cam-1":      { "producers": <REDACTED-CRED>
                                {"url":"ffmpeg:cam-1#video=h264#width=1280#hardware=vaapi"}] },
  "cam-1-sub":  { "producers": <REDACTED-CRED> },
  "cam-2":      { "producers": <REDACTED-CRED>
                                {"url":"ffmpeg:cam-2#video=h264#width=1280#hardware=vaapi"}] },
  "cam-2-sub":  { "producers": <REDACTED-CRED> }
}
```

That's a 2-camera test fixture (`192.168.1.67`, `192.168.1.64`, <REDACTED-CRED> No `hiwatch-*` registrations at all.

### 3. `/streams` from cilex-vision is correctly returning 16 production cameras

The `camera_id` values are `hiwatch-083bc14effb2`, `hiwatch-083bc17adca6`, … (real MACs, the production fleet). Per the D1 contract — `rtsp://<host>:8554/<camera_id>` and `…-sub` — Watchtower derives URLs like `rtsp://192.168.1.79:8554/hiwatch-083bc14effb2(-sub)`. Watchtower is playing exactly the URLs your API specifies, so nothing on Watchtower needs to change.

### 4. Direct ffprobe confirms the 404 (rules out anything in Watchtower's pipeline)

```text
$ ffprobe -rtsp_transport tcp rtsp://192.168.1.79:8554/hiwatch-083bc14effb2-sub
[rtsp @ ...] method DESCRIBE failed: 404 Not Found

$ ffprobe -rtsp_transport tcp rtsp://192.168.1.79:8554/hiwatch-083bc14effb2
[rtsp @ ...] method DESCRIBE failed: 404 Not Found
```

Both main and sub paths 404. Not a transcode or HW-encoder issue — go2rtc just has no entry for these names.

---

## The likely story (confirm/deny on your side)

Today's reply to the D6 brief flagged a go2rtc memory-pressure incident: 20 main streams trying to VA-API-transcode to H.264 concurrently, hitting the 512 MB cgroup cap, repeated `[exec] timeout` + HEVC decode errors, recorder stalled. A short-term recovery from that almost certainly involved restarting go2rtc with a minimal config (or rolling back to a baked-in dev config — the <REDACTED-CRED> shape looks like a fixture). The production registrations never got replayed.

So the drift is: `/streams` is still the source of truth for the camera fleet (good — D5 scoping works, D1 URL shape works), but go2rtc is running an emergency-minimal config that doesn't know any of the real cameras.

---

## What we need

Get every `camera_id` returned by `/streams` registered in go2rtc as both `<camera_id>` (main) and `<camera_id>-sub` (substream).

Suggested operational shape — pick what fits your deploy:

1. **Regenerate the go2rtc config from the cilex-vision camera roster** (the same source `/streams` reads from) so the two stay in sync by construction. If there's already a templated path that does this on deploy, it didn't run in today's recovery — verify it.
2. **Reload go2rtc** (`POST /api/restart` on the HTTP API, or `systemctl reload go2rtc`, whatever the deploy uses) so the new config is live.
3. **Verify**:
   ```text
   $ curl -s http://192.168.1.79:1984/api/streams | jq 'keys | length'
   # expect ~32 (16 main + 16 sub), not 4

   $ ffprobe -rtsp_transport tcp rtsp://192.168.1.79:8554/<any-camera_id-from-/streams>-sub
   # expect a stream description, not 404
   ```

If, as part of recovery, you want to keep the HD/main streams off go2rtc temporarily to avoid the OOM (the §D3 fast-follow), that's fine — register only the `-sub` (channel-102, passthrough) variants for now. Watchtower's wall plays substreams; the wall will light up immediately. Main streams can be registered when the §D3 dual-source-with-raw-rtsp-first work lands.

---

## What Watchtower will do

Nothing. The wall is already pre-wired against `/streams` + the 15 s status poll; the moment go2rtc starts answering for `hiwatch-*` URLs, every tile begins streaming and the recording badges flip to truth once the recorder catches back up.

If you want a Watchtower-side aid for diagnosing this kind of drift in the future, two options we can build:

- A small **per-tile RTSP error overlay** that surfaces `errorText` instead of just leaving the tile on "Connecting…" → "NO SIGNAL". Today the GStreamer error ("Not found", "Connection refused", etc.) only lands in stderr; an operator without a terminal would just see blank tiles.
- A **Health-screen "go2rtc reachability" row** that probes `/api/streams` and reports `n registered / m expected from /streams`, which would have surfaced this drift instantly.

Both are Watchtower-only changes; we'll do them on request — they're not blockers for the current ask.

---

## Out of scope for this brief

- The underlying §D3 HD-passthrough fast-follow (dual-source `[raw rtsp, ffmpeg:…#hardware=vaapi]`). Separate, longer-running ask. This brief is purely about restoring registration parity between `/streams` and go2rtc as it stands today.
- The `recording` field (D6) — it's already shipped (`"recording" | "unknown"`); once go2rtc + the recorder come back, `"recording"` will start showing up naturally.
- The 2-camera <REDACTED-CRED> test fixture — if those creds are real and live in production config, please rotate; they look like dev creds. (If it's a sealed dev fixture, ignore.)

---

Thanks.
