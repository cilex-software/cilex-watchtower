# Handoff prompt → Cilex Vision (recorder per-stream stall — no auto-restart)

*Paste this into the Claude Code session running in the **cilex-vision** backend repo.*

---

You are Claude Code working in the **cilex-vision** backend repo (`/home/cilex-vision/projects/cilex-vision`). The **Watchtower** operator client (sibling repo `/home/cilex-vision/projects/cilex-watchtower`) filed a recorder-health bug. Read it, reproduce, fix, and reply. Paths are on this machine under the Watchtower repo root — read from local disk.

## 1. Read
- **The report** — `docs/letters/2026-06-01-recorder-per-stream-stall.md`.
- Context: the recorder-cap fix you shipped (`ad96216`) fixed *whole-recorder* restart-looping for the 31-cam fleet. This is the **per-stream** layer beneath it.

## 2. The problem (verify against live state)
Individual per-camera recorder workers **stall silently**: the camera stays `online` with `recording_enabled: true`, but stops finalizing `video_segments`, and the worker **does not auto-restart**.
- **`192.168.1.106` / `hiwatch-083bc14eff9a`**: last `video_segments` row `2026-05-31T21:23:18Z` — **dead ~15 h** as of `2026-06-01T12:11Z`, while `status: online`, `recording_enabled: true`, `/streams.recording: "unknown"`.
- `192.168.1.120` / `hiwatch-083bc1df3a4b` stalled around the same time and self-recovered after ~1–2 h.
- The other 29 cams are healthy (latest segment ~1 min old). Confirm by comparing each camera's newest `video_segments.end_time` to now.

## 3. What to do
1. **Per-stream watchdog + auto-restart (main fix):** detect a stream worker that hasn't finalized a segment in > ~N×segment_duration (e.g. 3–5×30 s) while its camera is `online` + `recording_enabled`, then tear down and re-spawn that worker (RTSP pull / ffmpeg). Log each restart. Verify `192.168.1.106` starts recording again. Investigate *why* the worker died silently (RTSP disconnect not detected? ffmpeg exited rc=0? thread starved?) and make the death detectable.
2. **Expose stall truth on `/streams`:** make the `recording` field report a **distinct stalled state** (e.g. `"stalled"`/`"interrupted"`) when online+enabled but no recent segment — not the ambiguous `"unknown"` — **and/or** add **`last_segment_at`** (ISO) per stream so the client can compute freshness. (Watchtower will surface a "recording stalled" badge + NOT-REC count once this lands.)

## 4. Guardrails
- Don't disrupt the 29 healthy streams or trigger restart storms (debounce; only restart on a real stall, camera online + enabled).
- Don't regress the whole-recorder stability from `ad96216`.
- Single-problem: recorder per-stream health only. (E2 mosaic export is a separate handoff.)

## 5. How to reply
Reply into the Watchtower letters dir:
- **File:** `/home/cilex-vision/projects/cilex-watchtower/docs/letters/2026-06-01-recorder-per-stream-stall.reply.md`
- Header: `To: Cilex Watchtower` / `From: Cilex Vision` / `Date:` / `Re:` the report / `Status:`.
- Report: root cause of the silent stall, the watchdog/restart fix (+ that `192.168.1.106` is recording again), the `/streams` field change (`recording` states and/or `last_segment_at`), and the commit hash. Single-problem.
