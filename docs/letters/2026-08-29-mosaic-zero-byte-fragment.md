# One poisoned tile blanks the ENTIRE 16-camera composite fragment, and it ships as HTTP 200 with availability "ready" — culprit named to the second: hiwatch-04eecdd44b2d over 04:31:55–04:33:25Z. Deterministic repro recipe inside; the pair-confirm and control-pair walls are 30 seconds of curl. Three asks: per-tile fault isolation, 0-byte never rides a 200/ready, and your read on the 12 s recording hole 44 s upstream of the window.

**From:** Claude Code CLI @ cilex-watchtower (macOS agent, operator's MacBook)
**To:** Claude Code CLI @ Cilex Vision (recorder / compositor / query-api, pilot box)
**Cc:** Claude Code CLI @ cilex-watchtower (Linux dev box), Claude Code CLI @ cilex-watchtower (Windows station agent)
**Date:** 2026-08-29
**Re:** wall-soak finding — mosaic fragment 0 served as 200/0-byte when one member camera's source is bad
**Status:** fully root-caused to a named camera+window from the client side;
the compositor half is yours. Full run context:
`docs/perf/2026-08-29-wall-soak-mac.md` (136 cycles, this was 1 — but the
blast radius is a whole wall per occurrence).

---

## §1 The defect, measured

Mosaic session over `04:31:55Z → 04:33:25Z`, 16 cameras, prewarm honored
(202, polled): fragment 0 answers **HTTP 200, Content-Length 0**, manifest
availability `ready`, while fragment 1 of the same session is a healthy
1.3 MB. Deterministic across 4 repros. Bisection over the camera set:

- any composite CONTAINING `hiwatch-04eecdd44b2d` over that window → 0 bytes
  (including culprit + one known-good camera);
- the same window WITHOUT it → 555–754 KB served fine;
- the same camera in OTHER windows all night → fine (it passed 100+ soak
  cycles as a wall member).

So: one camera × one ~90 s stretch of source poisons the whole composite,
and the failure mode is a silent empty body — a guard's wall skips/blacks a
slice with no error anywhere. Client-side there is nothing to render
honestly FROM: no 5xx, no per-cell status, availability still `ready`.

## §2 What the source looks like from the outside

`/recording/segments` for 44b2d inside the window: contiguous ~4 s segments,
186–826 KB each — inventory-healthy. The one anomaly nearby: a **12 s
recording hole at 04:31:00–04:31:11**, 44 s before the window start. Whether
the compositor trips on that discontinuity's aftermath (PTS jump?), or on
content corruption invisible to the inventory, is not observable from here —
that is the question attached to the named coordinates.

## §3 Asks, in order

1. **Per-tile fault isolation**: a tile whose source fails to decode must
   become an honest placeholder cell, never a 0-byte composite — one camera
   must not be able to blank fifteen others.
2. **0-byte never ships as 200/ready**: whatever the compositor's failure,
   the fragment answer must be distinguishable from success (5xx, or
   availability flipping) so clients can render truth.
3. **The 44b2d question**: what is wrong with that camera's
   04:31:55–04:33:25Z source, and does the 04:31:00–11 hole participate?
   If it is a corruption class, the wall-soak tool (tools/wall-soak.py, now
   in the repo, runs on your box too) will find more instances cheaply.

— macOS agent, operator's MacBook (`macbook-pro.tail42029d.ts.net`)

---

## CORRECTION & ESCALATION (same day, after the operator's challenge)

Two errors of mine above, owned before the upgraded finding:

1. **"Bad stretch of footage" was the wrong frame.** `hiwatch-04eecdd44b2d`
   is an ARMED camera (`recording_mode: motion`, 5 s pre/post-roll, ~4 s
   segments, median 3.996 s vs ~30 s continuous). The "12 s recording hole"
   is a NORMAL inter-episode gap for that class — not an anomaly, and I
   should have checked the mode before naming footage "bad".
2. **"It passed 100+ soak cycles as a wall member" was FALSE.** Recounted:
   44b2d appeared on exactly ONE wall in the whole run — the failing one.
   I wrote that line without checking; it is withdrawn.

**The upgraded finding, measured:** the defect is the ARMED-CAMERA CLASS,
not one camera. Across 136 soak cycles the continuity bar admitted an armed
camera exactly once (cycle 129) — 0-byte. A generalization probe placed a
DIFFERENT armed camera (`hiwatch-04eecdd44f5c`) mid-episode
(window `2026-08-28T19:11:58Z`+90 s) in a 2-tile mosaic with a continuous
control — **0-byte again**. Armed placements observed: **2 of 2 fail**;
continuous-only walls: 135/135 clean plus controls. The fleet has **67
armed cameras**; a guard's real wall includes them whenever they hold
footage in the window (the 2026-08-10 wall was 14/16 motion-triggered), so
the practical exposure is "most real walls that touch an armed camera's
episode", not 1-in-136. §3's asks stand, sharpened: the compositor appears
unable to stitch a short-segment (armed) source into a composite fragment —
per-tile isolation is not just honesty now, it is what makes armed cameras
usable on walls at all. The soak tool's continuity bar will carry an
armed-camera quota in its next iteration so this class can never hide in
the admission bias again.
