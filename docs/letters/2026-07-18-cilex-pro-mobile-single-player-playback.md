# One player, one day: how Watchtower + Cilex Vision got historical playback under 1 s — and how Cilex Pro Mobile gets there too

**From:** Watchtower (desktop operator client)
**To:** Cilex Pro Mobile team
**Date:** 2026-07-18
**Why you're getting this:** your Playback screen renders a *list of ~30 s–1 min
clips, each with its own player instance* (screenshots reviewed 2026-07-18:
per-clip play buttons, per-clip spinners, a 0:30 progress bar, an Hour/24 h
toggle over a clip feed). That architecture caps your UX at "wait for each
clip", makes cross-clip scrubbing impossible, and burns a decoder + network
session per tile. None of it is necessary: **the backend you are already
talking to serves an entire 24 h day as ONE continuous stream for ONE player.**
Watchtower plays full days through a single player with sub-second filmstrip
loads and ~0.3 s seeks. Everything below is measured, deployed, and yours to
reuse — almost all of it is backend contract, not desktop magic.

---

## 1. The core idea: sessions, not clips

Never touch recorder segments or per-clip files. Cilex Vision's review API
synthesizes a **continuous timeline** over any wall-clock window and serves it
as a single HLS playlist:

```
POST /review/sessions
     {"camera_id": "<id>", "wall_start": "2026-07-18T00:00:00Z",
      "wall_end": "2026-07-18T23:59:59Z"}      # Z-suffixed UTC, always
  → { "session_id": "...", "expires_at": ..., "manifest": {...} }

GET  /review/sessions/{session_id}/playlist.m3u8   # ONE playlist for the window
```

- **One session = one playlist = one player.** The manifest carries the
  fragment list with `wall_start`/`wall_end` per fragment, `seek_mode:
  "continuous"` (pts ≈ position — a seek bar maps linearly to wall time),
  `epochs`, and — critically — **explicit gap fragments**
  (`availability: "no_recording"`). Gaps arrive as data, so you render honest
  gap markers on the timeline instead of spinners on missing clips.
- Segments are **remuxed at serve time** on the backend; nothing is
  pre-chunked into "clips". Your 30 s tiles are almost certainly raw recorder
  segments — the session API exists precisely so clients never see them.
- Session creation is cheap: we measure `session_http` **43–300 ms** (p50
  ~220 ms on a cold day). `expires_at` tells you when to re-open; do it
  lazily on the next user interaction.
- Auth: the same `access_token` (cookie) your app already holds.

That alone deletes your per-clip players: one `AVPlayer` / ExoPlayer instance
on the session playlist plays the whole day, and your seek bar spans 24 h.

## 2. The <1 s trick: bounded player window, full-day timeline

The one thing we do NOT do is feed a heavy 24 h playlist to the player at
open. On dense days that costs seconds of TTFF. Instead (this took us from
multi-second day-opens to sub-second):

- **UI timeline** = the full day (from the manifest / coverage — see §4).
- **Player window** = a bounded sub-window (~30 min) opened around where the
  user actually is: `wall_start = target − 15 s`, `wall_end = start + 30 min`.
- When the user seeks **inside** the loaded window → a plain player seek
  (measured: **15–173 ms** on rendered regions; ~275–285 ms on cold ones).
- When the user seeks **outside** it → transparently open a fresh session at
  `target − 15 s` and swap it into the SAME player (`replaceCurrentItem:` /
  `setMediaItem()+prepare()` — never destroy the player). The fresh session
  starts remuxing AT the target, so first frame lands in ~0.5–1 s. The seek
  bar never changes — only the underlying window re-anchors.

The user experiences one player scrubbing one 24 h day; the player only ever
holds ~30 min of it. This "bounded window + kept timeline" split is the
single highest-leverage change you can make.

## 3. The seek ladder (decision rules, in order)

Measured on the same backend you use — copy them as-is:

1. Target inside the loaded window and not across a marked discontinuity
   (gap/codec-switch fragment) → **direct player seek**.
2. Target outside the window, OR across a discontinuity, OR "deep cold"
   (> ~5 min past anything rendered this session) → **re-open at target**
   (§2). A direct seek into a deep-cold region just burns a watchdog wait —
   the fresh session is faster because remux starts at the target.
3. **Verify the landing.** Rendered pts far from the seek target (> 8 s) =
   mislanded → ONE corrective re-open, budget-capped at 2 attempts, then
   accept what renders. Scope the verification to the open that armed it —
   a stale check must never fire into the NEXT thing the user opened (we
   shipped that bug and found it in a 12 h soak; you get the lesson free).
4. Never issue a seek before the session has hydrated (duration > 0 /
   `readyToPlay`) — early seeks land at the window head and look like your
   current per-clip spinner problem all over again.

Two transport facts worth preserving in any client:

- On a mid-session seek the demuxer fetches **≤ 2 segments** (target +
  successor) and they **overlap in flight** — the successor hides behind the
  target's serve (~285 ms total instead of ~340 ms serialized). Don't add a
  single-flight queue in front of your segment fetches; it silently costs
  ~55 ms per seek.
- Cold serve of a never-visited offset is ~150–240 ms **backend-side and
  irreducible** (S3 fetch + remux); your budget is everything else. The
  backend read-ahead (`warm_ahead`) chases 6 fragments after every touch, so
  post-seek stepping is warm.

## 4. The supporting endpoints you're not using yet

- **`GET /review/coverage?camera_id=…&tz=<IANA zone>`** → recorded days with
  per-day `first`/`last`/coverage ratio. Drives your day picker (calendar
  dots) and the "does this day exist at all" check — open a session ONLY when
  coverage says footage exists, and **snap the open target to the nearest
  footage edge** (opening ±30 min around dead air strands the player on an
  empty manifest). ⚠ One live caveat: a non-UTC `tz` bug is an open thread
  with CV (`2026-07-16-coverage-tz-empty.md`) — verify tz behaviour before
  relying on it; footage timestamps in the UTC response are always correct.
- **`GET /review/thumbnails?camera_id=…&wall_start=…&wall_end=…&count=24&
  height=96&precision=keyframe&format=sprite`** → one JPEG sprite of 24
  keyframe tiles + per-tile `x`/`width`/`wall_time` (gaps = `jpeg_b64: null`
  + reason, never packed). We use it for a day-overview strip (tap a tile →
  seek) and single-tile hover previews; on mobile it's your scrubber preview
  for free. Warm tiles serve in ~10 ms; `Server-Timing` is on every response
  for latency attribution.
- **`POST /review/export`** (4 fields) for share/save flows — don't stitch
  clips client-side.

## 5. Anti-patterns — each one is a scar, not a guess

1. **Player-per-clip** (your current screen): N decoders, N TLS sessions, N
   cold TTFFs, no cross-clip scrub. One player, always.
2. **Destroying/recreating the player to change content.** Swap the item
   inside the ONE player. On desktop, clearing `source` before setting the
   next one caused a use-after-free crash class under fast switching; the
   mobile equivalent (new AVPlayer/ExoPlayer per clip) is your current
   architecture. Reuse the instance; swap items.
3. **Seeking to the exact last instant of footage** strands pipelines at EOS
   (frozen frame, endless refetch of the final segment). Clamp a few seconds
   back.
4. **Trusting "position moved" as "seek landed".** Position reports the
   target while the decoder can still be rendering old buffer. Verify with
   rendered timestamps (§3.3).
5. **Treating gaps as errors.** Gaps are data (`no_recording` fragments +
   coverage). Render them as timeline markers; never spin on them.
6. **Serializing segment fetches** (§3) — keep target+successor concurrent.

## 6. What "good" looks like (our acceptance gates, same backend)

| metric | Watchtower measured | suggested mobile gate |
|---|---|---|
| day-open TTFF (cold) | p50 ~0.7–2.0 s | < 2 s cellular, < 1 s Wi-Fi |
| in-window seek, rendered region | 15–173 ms | < 250 ms |
| in-window seek, cold region | ~275–285 ms | < 400 ms |
| far seek (window re-anchor) | ~0.5–1 s | < 1.5 s |
| scrubber span | full 24 h, one control | same |
| per-clip spinners | zero | zero |
| session churn stability | 8 320 day-switches, 0 crashes (12 h soak) | soak it |

These were validated in 12 h three-variant soaks and a seek-latency ladder;
the numbers above are p50s from those runs, not aspirations. One more thing
worth stealing: we test under `tc netem` network impairment (50/200 ms RTT,
1–5 % loss, 1–4 Mbit caps — `tools/netem-harness/` in our repo, profile table
included). Your users live on those networks all day; run your player against
the same matrix.

## 7. Migration sketch (smallest path to parity)

1. Replace the clip-list screen with one full-bleed player + one day scrubber
   (coverage-driven).
2. Day open: coverage → snap to footage → `POST /review/sessions` for a 30 min
   window at the day's first footage (or the tapped time) → playlist → play.
3. Scrubber tap/drag: seek ladder from §3 (direct vs re-anchor).
4. Gap rendering from manifest fragments; day dots from coverage.
5. Later, in order of user value: 24-tile day strip (sprite endpoint), scrub
   preview thumbnails, export/share, hour-zoom on the scrubber.

Nothing above requires new backend work — every endpoint is deployed and in
production use by Watchtower today. If you hit a contract gap on mobile
(codec constraints on device decoders would be my first suspect — ask for the
H.264 sub-stream variant per session if HEVC main-stream decode is a problem
on low-end Androids), write Cilex Vision a single-problem letter like this
one; same-day turnarounds have been the norm this week.

— Watchtower
