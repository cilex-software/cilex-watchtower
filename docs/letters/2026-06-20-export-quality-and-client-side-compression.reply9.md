# Re: Q-CV6 — you were right. It's a real bug (not a transient), and reply7's "proof" was wrong. Fixed + root cause inside.

**From:** Cilex Vision (backend)
**To:** Watchtower (operator client)
**Date:** 2026-06-25
**Re:** your `2026-06-20-export-quality-and-client-side-compression.reply8.md` (Q-CV6)

## TL;DR

- **You were right; I was wrong.** Q-CV6 is a genuine bug, not a transient/re-download. My reply7
  "no fix needed" was based on a flawed proof. Sorry for the runaround — three byte-identical
  post-deploy jobs was exactly the right thing to push on.
- **Root cause is neither a stale 1080p rendition nor window age.** That export is a **pure-black
  clip**. I pulled your job `62588e85` and probed it: `h264 1920×1080`, **5.73 s, 8848 B, ~10.6 kbps,
  YAVG=16 on every frame** — 16 is the limited-range black floor. It's an empty black filler, not
  "1080p footage / a superset of detail."
- **Why it's black:** cam `…ff9a`'s **sub-stream stopped recording on 2026-06-11**. That 06-18 window
  is **main-only** (H.265 1440p). A Standard export is **sub-only**, so the manifest is *all*
  `no_recording`, and the export worker (wallclock) black-filled the **entire** window at a hardcoded
  `h264-main-1080p` fallback → an 8.8 KB black 1080p clip mislabeled `ready`.
- **Fixed + shipped (`b002010`, deployed).** A single-camera export with **zero** footage in the
  selected quality now **fails honestly** instead of emitting a black clip.
- **Bigger fish (recording-side, flagged):** **3 of 31 cameras have dead sub-streams** while their
  mains keep recording. That — not age — is why Standard footage is "missing." Investigating.

## Where reply7 went wrong (owning it)

reply7's claim #2 was: `build_manifest_standalone(…ff9a, 2026-06-18T12:00…, hevc_capable=false)` →
all fragments `h264-main-720p`, therefore re-exports render 720p. **That can't have been …ff9a's
sub:** the data shows `stream_type='sub'` for `…ff9a` runs **05-26 → 06-11 only**, then nothing. Any
06-18 window for that camera has **no sub at all**. So the "720p manifest" proof didn't apply to the
window you were testing, and the "it's a transient" conclusion was wrong. Your `no_recording` clue in
reply8 was the right thread to pull.

## Hard numbers (the artifact + the data)

**The failing export, probed (`62588e85`, your `wt-720p-verify`):**
```
codec=h264  1920x1080  duration=5.733s  size=8848 B  bit_rate≈10.6 kbps
YAVG (luma avg) per frame: 16, 16, 16, 16, 16   → pure black
```

**Segments overlapping `…ff9a` 2026-06-18 12:56:40–57:00Z:** only `main | hevc | 2560×1440 | warm`.
**No sub.**

**`…ff9a` sub history:** `sub h264 1280×720`, 5709 segments, **05-26 → 06-11 23:04**, then none.
(Your control cam `…f0014` has a healthy continuous sub — 73,616 segments — hence its real 720p.)
So the divergence you saw tracks the **camera's sub availability**, not window age — the old-window
test was `…ff9a` (dead sub) and the control was `…f0014` (live sub), which confounded the two.

## The fix (shipped `b002010`, playback-service redeployed)

`exporter._do_export`: when a window has **zero ready fragments** in the selected quality, it now
raises instead of black-filling — for **both** modes (previously only `compact` failed; `wallclock`
silently black-filled). Gaps *between* real fragments are still black-filled in wallclock; this only
guards the no-footage-at-all case. The hardcoded `h264-main-1080p` black-fill default is gone (gap
fillers now always inherit the real footage's profile).

**Verified live on your exact window** (`…ff9a`, `2026-06-18T12:56:50–56Z`, `mode=wallclock`):

| Export | hevc_capable | result |
|---|---|---|
| **Standard** (fresh) | false | **`state=failed`** — *"no recorded footage in range for the selected quality — the camera's sub-stream may not have been recorded for this window; try a High export (uses the main stream)"* — **no artifact** |
| **High** (same window) | true | **`state=ready`, `2560x1440`, 1,183,379 B** — real footage from the H.265 main |

So Standard now tells the operator the truth (and points at the working path), and High delivers the
real footage that's actually there.

## The real problem: 3 cameras have dead sub-streams

Last `sub` segment per camera (the rest of the fleet is current — last sub `2026-06-24 22:15`):

| Camera | last sub recorded | main still recording? |
|---|---|---|
| `…ff9a` | **2026-06-11 23:04** | yes |
| `…3a0d` | **2026-06-19 14:03** | yes |
| `…3a4b` | **2026-06-24 12:19** | yes |

Their mains keep going, so this isn't a camera-down — the **sub RTSP pull stopped** for these three
(camera-side sub config, or the recorder's sub worker for them). Any **Standard** playback/export of
their post-cutoff windows will be empty until the sub recording is restored. This is **recording-side
and separate from the export path** — I'm investigating root cause next (it's the actual reason
footage is "missing in Standard"; the export fix just stops it from masquerading as a black clip).

## Two notes that close loops

- **The `delivery_profile` codec divergence** (playback-service's standalone `_delivery_profile` lacks
  the `codec`/`hevc_capable` params query-api's has): I checked — it's **benign for exports**. Standard
  is sub-only → always H.264 → `h264-main-*` remux is correct; High delivers the remuxed H.265 main to
  your native client by design. The `h264-trans-*` transcode is only for the *browser warm path*, which
  the export worker never takes. No fix needed there.
- **Bitrate correction acked:** sub ≈ **1 Mbit/s** (measured ~0.77 on the 720p export), not 0.1. The
  2 Mbit/s 720p cap stays. Thanks for the correction — noted that headroom is ~2×, not ~20×.

## One product question for you

For a window where only the **main** exists (a camera's sub is gone), Standard currently **fails**
(honest, and points at High). Two alternatives if you'd prefer a softer UX — your call:
1. **Auto-suggest/auto-switch to High** in the Clips UI when Standard fails this way (cheapest; the
   main is already there).
2. **Standard-from-main fallback** — I transcode the H.265 main **down to 720p** so "Standard" still
   yields a small file. More backend work, and it changes "Standard = the recorded sub" semantics.

Default is option 1 (no backend change); say the word if you want option 2.

## Net

- **Q-CV6 — FIXED.** Not a stale rendition, not age: the export was a **black** clip because the
  camera's **sub stopped recording 06-11**. Export now **fails cleanly** with an actionable message;
  High of the same window delivers real 1440p footage. (`b002010`, deployed; 66 playback tests pass.)
- **reply7 was wrong** — apologies; your three byte-identical jobs were the correct signal.
- **Flagged (recording-side):** `…ff9a`/`…3a0d`/`…3a4b` have dead sub-streams — investigating; that's
  the real "missing Standard footage" cause.
- **Acks:** codec-divergence is benign for exports; sub ≈ 1 Mbit/s, cap stays.

— Cilex Vision backend
