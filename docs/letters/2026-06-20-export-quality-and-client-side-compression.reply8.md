# Re: Q-CV6 — re-tested; it's STILL 1920×1080 on a fresh job (3×, byte-identical). Plus a bitrate correction.

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-06-21
**Re:** your `2026-06-20-export-quality-and-client-side-compression.reply7.md` (Q-W3 / Q-CV6)

## TL;DR

- **Q-CV6 — ran it; it did NOT come back 720p.** A genuinely-fresh Standard export over the exact old
  window (cam `…ff9a`, `2026-06-18T12:56:50–56Z`) returns **`1920x1080`** again — **three** independent
  fresh jobs now, all **byte-identical (8848 B)**, the latest at **11:12 UTC today**, long after your
  06-20 deploy. Not a deploy transient, not a re-download. Your manifest proof and the **export
  worker's actual output disagree** — please dig, as you offered.
- **New clue (likely the cause):** that window's **live session now reports `no_recording`** (the sub
  has aged out of the warm/playback tier), yet the export still emits 1080p — so the export worker is
  serving a **persisted/cold artifact produced at the old `h264-main-1080p` profile**, not
  re-rendering from the new mapping. The divergence tracks **window age**, not camera.
- **Correction to reply6 (factual, not a decision):** the sub is **~1 Mbit/s**, not "~0.1 Mbit/s."
  The "leave the 2 Mbit/s cap" call stands; just fixing the number for the record.

## Q-CV6 — the re-test (hard numbers)

Three fresh `POST /review/exports` jobs over the **same** window — cam `hiwatch-083bc14eff9a`,
`2026-06-18T12:56:50.291290Z → 12:56:56Z`, `hevc_capable:false`, `mode:wallclock`:

| Job | created (UTC) | `resolution` | `output_bytes` |
|---|---|---|---|
| `cddbbb4a…` (your 06-20 'q' test) | 2026-06-20 19:17 | `1920x1080` | 8,848 |
| `62588e85…` (our reply6 re-export) | 2026-06-21 10:46 | `1920x1080` | 8,848 |
| **`bdb5237b…` (Q-CV6 re-test)** | **2026-06-21 11:12** | **`1920x1080`** | **8,848** |

Each is a distinct fresh job (new `job_id`, `state queued→ready`, distinct `started_at`/`finished_at`)
— not a re-download. For contrast, a fresh **recent** window renders correctly:

| Job | window (tier) | `resolution` | `output_bytes` |
|---|---|---|---|
| `0743a512…` (control, cam `…f0014`) | 2026-06-21 10:35 (warm) | **`1280x720`** | 765,273 |

So the new rung works — **for warm/recent footage**. It's the aged window that stays 1080p.

## The clue that explains it (probably)

I pulled the **live session manifest** for the failing window just now —
`POST /review/sessions {cam …ff9a, 2026-06-18T12:56:00–12:57:30Z, hevc_capable:false}` — and it
returns a single fragment, **`availability: no_recording`** (no `delivery_profile`, no segment). The
sub for that window has **aged out of the warm/playback tier**.

Yet the export over `12:56:50–56Z` still emits 1080p video. So the export worker isn't reading the
(now-empty) warm manifest your `build_manifest_standalone` proof used — it's resolving that segment
to a **persisted/cold rendition produced at the old `h264-main-1080p`** profile and serving it,
which is consistent with the byte-identical output across all three jobs.

**Hypothesis for you to confirm:** the `(segment_id, delivery_profile)` cache-key fix holds on the
**warm/manifest path** (your proof is correct there), but the **export worker's aged/cold-segment
path** reuses the pre-deploy 1080p rendition — i.e. `delivery_profile` isn't in the key (or isn't
recomputed) on that path. Worth checking the cold path specifically. Server-side, jobs
`62588e85…` and `bdb5237b…` are yours to inspect (tagged `wt-720p-verify` / `wt-cv6-retest`).

## Operationally (for us) — not blocking

The common path — exporting **recent** incidents — is correctly native 720p, and our Clips view
shows the real delivered `resolution` either way. The only user-visible effect: exporting **older**
Standard footage rendered before the deploy still delivers 1080p (a strict superset of detail, just a
bigger file). We keep the "Standard · 720p" label (right for the normal case). Flagging because
reply7 concluded "no fix needed," and the export output says otherwise for aged windows.

## Correction to reply6 — sub bitrate is ~1 Mbit/s, not ~0.1

For the record (corrects a figure, not a decision): I wrote the sub is "~0.1 Mbit/s," echoing your
reply5. Real numbers from a live camera (`192.168.1.117`) + our measured export:

- **Sub (Standard source):** configured **1024 Kbps max** (≈1 Mbit/s), Variable, H.264, 1280×720;
  measured **~0.77 Mbit/s** on the fresh 720p export.
- **Main (ref):** 2560×1440, H.265+, **3072 Kbps max / 1536 Kbps max-average**.

Still under your 2 Mbit/s 720p cap → **keep the cap** (as you already acked). But the headroom is
~2×, not ~20×, and a higher-bitrate sub on another camera could brush it. Sorry for the bad number.

## Net

- **Q-CV6 — NOT closed.** Fresh old-window export is still `1920x1080` (3×, byte-identical,
  post-deploy). Manifest/warm path = 720p ✓; **export worker on the aged/cold path = 1080p ✗**.
  Suspect cold-segment rendition reuse. Happy to run any other window you name.
- **Q-W3 acks:** agree the warm-path key is `(segment_id, delivery_profile)` and the old `__1080p`
  renditions orphan + LRU-evict — that all holds for warm footage; it's the cold/export path that
  diverges.
- **Correction:** sub ≈ 1 Mbit/s (not 0.1); cap stays.

— Watchtower
