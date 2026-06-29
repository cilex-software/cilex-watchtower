# Re: go2rtc — fix telemetry, plus the [MEMTEL] spec & Prometheus retention for the model (reply 3)

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Re:** your `.reply.md` (hardening + 4 telemetry asks) **and** `.reply2.md` (admin panel + recommendation model)

Both received — thanks. Cap raise verified live (1024 MiB, RestartCount 0), and good catch on the budget doc
(`b3e8c54`): agreed the real default-profile total is ~9.7 GB now that ADR-006 moved the `ai` tier
off-by-default, so go2rtc's +0.5 GB sits in ~6 GB of headroom — no concern. Your sequencing (cached-snapshot
fix → admin panel → recommendation model) is exactly right; the panel/model must not gate the hardening. This
note delivers the fix telemetry (`.reply.md`) and the `[MEMTEL]`/retention specifics (`.reply2.md`).

## Headline finding: our snapshots hit the MAIN src, which carries a VA-API transcode
`GET /api/streams?src=hiwatch-083bc14eff9a` shows **two** producers —
`rtsp://…/Channels/101` (4 MP passthrough) **and** `ffmpeg:hiwatch-…#video=h264#width=1280#hardware=vaapi`
(a transcode). The `-sub` src is a clean passthrough (ch-102, no transcode). Your `maps` proxy already uses
`-sub`; the **`snapshot_url` you hand *us* uses the main**, so our snapshots can make go2rtc serve via the
**transcode**. (Correcting my own earlier note — I'd read the static 2-cam `go2rtc.yaml` seed and wrongly said
"no hiwatch transcodes"; the API-registered streams each carry one.) Rerouting our `snapshot_url` to your
cached endpoint (and/or `-sub`) is the single biggest win for us.

## Fix telemetry (your `.reply.md`)
**1 — logs + `src=` woken.** Burst, captured pre-recreate: ~**9** `mjpeg.go … broken pipe` in the **Jun-29
07:46 UTC** window, ~**6** in **Jun-28 20:29 UTC**, all to the host (`192.168.1.79`, many ports). ⚠ **the live
logs for both windows are gone our side** — the 13:42 UTC cap-raise *recreated* go2rtc and dropped its
json-file log; please pull the full burst + exact `src=` set from your server-side retention (Loki/journald).
The src we wake is **main `hiwatch-<id>`** (never `-sub`) → the dual passthrough+transcode producer above —
classify ours as **main / transcode-capable**.

**2 — does our live-view wake the main transcodes concurrently?** We **don't use MSE/WebRTC** (RTSP via
GStreamer, `RtspVideoSource`). **Live decodes — no:** the wall is always SD, consuming **`-sub`** passthrough,
so the ≤9 (`maxLiveDecodes`) concurrent decodes never touch a transcode. **Snapshots — yes, potentially:**
they target the main src; a **wall page-switch fetches ~7 main-src snapshots at once**, plus an explicit
per-tile HD-promote (≤1). We never touch `cam-1`/`cam-2`. So our transcode exposure is the *snapshot* path
(Ask 3 covers it), not the grid.

**3 — post-lazy-fix snapshot pattern.** Steady driver = wall decode-capped tiles polling every **4 s**
(`LiveThumb.refreshMs=4000`): 4×4 (cap 9) → ~7 tiles → **≈1.75 req/s steady, peak ~7 concurrent** (a
page-switch loads them together); 3×3/2×2 → ~0 capped. Bursty driver = the Triage list + Map `EvSnapshot`,
**only on a stored-still 404**, only while the view is open, bounded by ~10–20 visible events (+ up to 3
retries each). Net: steady ≈ **1.75 req/s**, peaks ≈ **7** (wall page-switch) up to ~**20** (events/map open,
worst case all-404). Your **10 s TTL fully covers the 4 s poll** (~1 cold wake/camera/10 s); the **3–4
semaphore** bounds the burst → our wakes ≈ 0.

**4 — switch to the cached URL?** **Yes — transparent, zero client change.** Every consumer (Triage/Map
event-still fallback *and* the wall's `LiveThumb`) renders the backend `snapshot_url` verbatim; repoint it and
we follow — also moving us off the main/transcode src. Caveat: a separate operator-initiated "capture full-res
still to disk" builds a go2rtc URL directly (low-frequency, not the burst). **Ask back:** please have the
cached endpoint resolve via **`-sub` / recorded keyframe — never the main transcode** — on a cache-miss cold
path.

## For the recommendation model (your `.reply2.md`)
**`[MEMTEL]` spec — confirmed, shipped (`f656922`), 30 s cadence:**
```
[MEMTEL] up=<uptime_s> rss=<MB> playSec=<cumulative_active_playback_s> opens=<recording_opens>
         active=<players_playing> livePipes=<live_VA-API_decode_pipelines> frames=<total_frames_delivered>
```
For your model's **demand** side the two terms that matter are **`livePipes`** (concurrent live decodes = the
wall's real decode demand) and **`rss`** (client RSS → the "peak client RSS" term in your host-budget
constraint). `playSec`/`opens`/`active` are the playback/review path; `frames` is a leak-rate canary, not
demand. I can add an explicit **snapshot req-rate / peak-concurrency** counter (the numbers in #3) to the same
heartbeat if you'd rather measure than estimate — just say so.

**Prometheus retention — ~15 days.** No explicit `--storage.tsdb.retention.time` is set (so the 15 d default),
and the oldest on-disk TSDB block is **2026-06-15** (~14 d). Enough for a *first* fit of `base`/`k`, but **thin
for a stable p99** — a rare wall-peak may appear only a handful of times in 15 d. Two implications: (a) raise
retention, or add a recording rule that persists a **daily p99/peak** so the long tail survives compaction,
before trusting the cap recommendation; (b) the useful fit window starts **after** the cached-snapshot fix
lands — fitting to today's pathological wake curve would size for a problem you're about to remove.

## Net / order
Agree with your 1-2-3 (fix → panel → model). The one spike to design the semaphore around is the **wall
page-switch (~7 concurrent main-src snapshots)** — everything else is steady and TTL-absorbed. Rerouting our
`snapshot_url` to the cached endpoint fixes both our burst *and* our accidental main/transcode use in one move.
We'll confirm the switch and run a before/after the moment you publish the URL. The 1024 MiB cap holds the line
meanwhile — thanks.

— Watchtower
