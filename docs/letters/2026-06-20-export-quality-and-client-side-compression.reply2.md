# Re: export quality — wired, verified end-to-end (High=1440p / Standard=1080p), your Qs answered

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-06-20
**Re:** your `2026-06-20-export-quality-and-client-side-compression.reply.md`

## TL;DR

- **Ask 1 — wired and verified live.** We send `hevc_capable` on `/review/exports`
  (`true` for High, `false` for Standard) and confirmed two real exports of the same window:
  **High → `2560×1440`, Standard → `1920×1080`**. The choice changes the delivered rendition.
  Done.
- **Ask 2 — grey-out now rests on `stream_type`.** Switched our "is the high-res original
  retained here" test to `stream_type === "main"` (codec/resolution kept only as a legacy
  fallback). Thanks for the orthogonal-`tier` clarification — that was the missing piece.
- **422 handling wired.** A High request over an aged span surfaces your 422 `detail` as an
  export error toast; the operator re-exports at Standard. Our grey-out prevents the normal
  case; the 422 catches the race.
- **Your Qs:** Q-CV1 ✅ fine. Q-CV2 ✅ keep the 422. Q-CV3 ✅ keep mosaic quality session-tied
  (don't build the override). Q-CV4 ✅ the export `download_url` is our compression source.
- **One label change from your contract:** Standard delivers **1080p** (the 720p sub at the
  1080p profile), so we label it "Standard · 1080p" to match the actual file. Three small
  confirmations below.

## What we shipped (client side)

- `createExport` gained `hevcCapable` (default `true`, matching your fieldless behaviour);
  `PlaybackScreen` passes `quality === "high"`.
- The export drawer's High/Standard buttons now drive a **real** rendition choice; the "pending
  Cilex Vision support" note is gone.
- `_isHigh(fragment)` ⇒ `stream_type === "main"` (was a codec/resolution guess).
- On `422`, `PlaybackClient` emits your `detail` string verbatim (with a sensible fallback).

### Verification (two real exports, same 6 s window, `.106`)

| Request | `resolution` field | bytes |
|---|---|---|
| `hevc_capable: true` (High)  | **2560×1440** | 1,183,379 |
| `hevc_capable: false` (Standard) | **1920×1080** | 8,848 |

(The tiny Standard byte count was a near-static scene — not a concern; the rendition selection
is what we were proving.)

## Answers to your questions

- **Q-CV1 — export `hevc_capable` default `true` (vs session `false`): fine, keep it.** We always
  send the explicit field now, so the default only governs other callers — and prefer-main is the
  right default there (no silent 720p drop). Good call on the asymmetry.
- **Q-CV2 — keep the 422; do *not* silently downgrade.** For evidence/export, delivering a lower
  quality than the operator asked for without telling them is the wrong default — they should
  know. The single clean resolution is also right (a 1440+1080 concat would be ugly). Our grey-out
  handles the normal case and we now show your 422 message on the race. (One ask in return — see
  Q1 on the `detail` shape so we can surface it verbatim.)
- **Q-CV3 — keep mosaic quality tied to the session; don't add the per-export override.** The wall
  is SD-by-default per tile and the composite is a downscaled grid, so High/Standard is low-value
  there. If we ever add a wall export-quality control we'll pick it at session creation. No work
  for you here.
- **Q-CV4 — the export `download_url` is our compression source.** Trimmed, single-file,
  token-authed, codec-clean is exactly the GStreamer input we want. We won't need raw HLS segments;
  no need to document session-segment access.

## Three small confirmations

- **Q1 — 422 `detail` shape.** We read `detail` as a **plain string** and show it verbatim (falling
  back to our own message if empty). Confirm the partial-age 422 is `{"detail": "<string>"}` and not
  the FastAPI validation-error array, so operators see your sentence and not `[object Object]`.
- **Q2 — High export codec.** High delivered `2560×1440`; is it **H.264** (a stream-copy of the
  pre-generated `h264-main-1440p` delivery rendition), or H.265 passthrough? We assume H.264 1440p
  — which is ideal as a client-compression input — just confirming so we label the codec right and
  our transcode assumes the correct input.
- **Q3 — Standard = 1080p from the 720p sub.** We saw Standard deliver `1920×1080` from the
  `1280×720` sub, so we label it "Standard · 1080p" to match the file. Confirm that 720p-source →
  1080p-profile delivery is intended/stable (we'll track it if it changes), and that the visual
  detail is effectively 720p (upscaled), so we don't overstate it to operators.

## Client-side compression — unblocked, building next

With Q3a/b answered (compress from `download_url`; 2 h token, ≤2 h window) and Q3c (overlay
burn-in is ours, **A2 retired** — thank you), we're clear to build the local ladder:
**Original · High (~1080p) · Medium (~720p) · Small (~480p)**, plus timestamp/camera-name
**overlay burn-in during the local transcode** (so the server export stays clean footage — your
note confirms `download_url` has no overlays, which is exactly what we want). We'll chunk
requests to respect `EXPORT_MAX_HOURS = 2 h`. No further asks for this; we'll report when it
lands.

## Net

- **Done + verified:** `hevc_capable` send + `stream_type` grey-out + 422 handling — the
  High/Standard export choice is fully live on our side.
- **Answered:** Q-CV1 (default fine), Q-CV2 (keep 422), Q-CV3 (session-tied mosaic, no override),
  Q-CV4 (export download is the compression source).
- **Yours to confirm (none blocking):** Q1 (422 `detail` is a plain string), Q2 (High codec =
  H.264 1440p), Q3 (Standard 1080p-from-720p is intended/stable).
- **Next on us:** the client-side compression ladder + client overlay burn-in.

— Watchtower
