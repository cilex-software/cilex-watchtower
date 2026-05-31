To: Cilex Vision — From: Cilex Watchtower
Re: Outstanding API requests (living doc)

This is Watchtower's single backlog of backend gaps — the things we need from
cilex-vision to fully back features we've already built to the design. We build
the complete UI, send only what your API accepts today, mark the rest "pending"
honestly (never silent no-ops), and track the contract here. Updated as we build;
supersedes the separate export-API (2026-05-27) and events-API (2026-05-28)
letters. Changelog at the bottom.

════════════════════════════════════════════════════════════════════════════
BACKEND RESPONSE — Cilex Vision, 2026-05-28  (statuses below are their reply)
════════════════════════════════════════════════════════════════════════════
Two corrections we were building to a bad contract on — fixed on our side now:
  • `mode` is an ENUM {compact, wallclock}, NOT free text — "continuous" was being
    400'd. Fixed: the export drawer sends "wallclock" (preserve timeline, gaps as
    freeze — matches our gap-warning). "compact" = drop gaps (future option).
  • event_type vocab corrected to the authoritative enum: entered_scene |
    exited_scene | stopped | loitering | motion_started | motion_ended (EventState:
    new|active|stopped|exited|closed). offline/online are NOT events (separate
    camera-status feed if needed). Updated our descriptions + icon/colour mapping.

Status per item:
  A1 purpose .......... ACCEPTED (free-text server-side; 422 on empty; echoed in A3/A6)
  A2 overlays/render .. ACCEPTED; biggest lift, sequenced last. Shape is an
                        orthogonal `overlays:{timestamp,camera_name}` (NOT via mode);
                        overlays + stream_copy ⇒ 422. Gated on playback transcode infra.
  A3 typed job resp ... PARTIAL — endpoint already returns most fields (the "{}" was a
                        missing response_model); they'll declare the schema + add
                        purpose/created_by/progress/codec/resolution/duration_s.
                        (bytes=output_bytes, expires_at=download_expires_at exist.)
  A4 mode semantics ... RESOLVED (correction above) — done on our side.
  A5 audio ............ DEFERRED (no audio path yet) — agreed.
  A6 exports LIST ..... ACCEPTED; ships with A1/A3 (one schema) — unblocks the library.
  B1 acknowledge ...... ACCEPTED (POST /events/{id}/acknowledge + acknowledged* +
                        filter). Switch our ack off local-per-machine once it lands.
  B2 empty feed ....... CONFIRMED — real pipeline gap on their side (detections=0 ⇒ no
                        tracklets ⇒ no events; recording is a separate, working
                        pipeline). Keep our honest empty state.
  B3 /detections 500 .. ✅ FIXED + DEPLOYED (commit 079d0b7). Re-tested from our side:
                        GET /detections now 200 (was 500). CLOSED.
  C1 manifest schema .. ACCEPTED, lower priority.
  C2 denormalized cam . ACCEPTED, cheap, low priority.

Newly live (unsolicited): GET /health/storage → { status, degraded,
storage_agent_reachable, circuit_open, last_error, reason } (ok now). WIRED on our
side — a storage-subsystem status strip on the Health screen (StorageHealth client,
refreshed while the screen is visible; shows Operational/Degraded/Unreachable).

Their sequencing: [done] B3 + A4 → first batch A1+A3+A6 + B1 → B2 investigation →
A2 (after playback transcode infra) → A5 → C1/C2. (Contract + order, not dates —
backend is mid-incident-recovery.)

────────────────────────────────────────────────────────────────────────────
Open asks, by priority (across domains)
────────────────────────────────────────────────────────────────────────────
  HIGH    A1  Export: `purpose` field (+ 422 enforcement, persistence, echo)
  HIGH    A2  Export: burn-in overlays + a rendered/stream_copy `mode` contract
  HIGH    A6  Clips: a LIST endpoint for exports (Clips & Snapshots library)
  HIGH    B1  Events: POST /events/{id}/acknowledge + acknowledged fields/filter
  MEDIUM  A3  Export: typed job response (bytes / resolution / expiry)
  MEDIUM  A4  Export: documented `mode` values + gap semantics
  CONFIRM B2  Events: is the events pipeline producing? + event_type/state vocab
  LOW     A5  Export: audio field + per-camera audio capability
  BUG     B3  GET /detections 500
  BONUS   C1  Typed review-session manifest fragment schema
  NICE    C2  Denormalized camera_name/group on EventResponse
  HIGH    D1  /streams: go2rtc RTSP restream url (rtsp_url + rtsp_sub_url)
  MEDIUM  D2  /streams: surface mac/vendor/model/firmware (from config_json)
  INFRA   D3  go2rtc: passthrough + on-demand config; RTSP reachable; tokenized url
  CONFIRM D4  Playback HLS served from pre-segmented storage (no per-request transcode)
  HIGH    D5  /streams conn-config scoped per-user; admin-only direct_rtsp_url+creds
  HIGH    D6  /streams: per-camera recording state (so "REC ?" stops being universal)
  MED-HI  A7  GET /review/coverage: per-camera days-with-footage + retention_days
              (drives the new playback footage calendar; see dated letter
              2026-05-30-footage-coverage-calendar-api.md for the full spec)
  HIGH    E1  Server-composited synchronized GRID MOSAIC stream (one HLS of the
              whole wall, time-synced) — blocks synchronized multi-camera review.
              Client-side N-way HLS sync was spiked and proven infeasible
              (~2–3 stream ceiling on the iGPU). + E2 combined grid export,
              E3 scrub poster frames, E4 coverage union, E5 latent confirms
              (hydrating playable / resolution / live-edge / codec switch).
              Full spec: 2026-05-31-multicam-synchronized-review.md.

════════════════════════════════════════════════════════════════════════════
A. Export & Clips  (/review/exports)
════════════════════════════════════════════════════════════════════════════
Backs the Export drawer (P4) + the Clips & Snapshots library (P6). Today, per
your OpenAPI, `POST /review/exports` accepts exactly four fields and the job
response is untyped:

    CreateExportRequest = { camera_id, wall_start, wall_end, mode }   // all required
    GET /review/exports/{job_id} -> 200 with an empty schema ({})

The drawer collects more than that; we send only the four and mark the rest
pending. The asks:

A1. Purpose (REQUIRED audit field) · HIGH, cheap
  Every export carries a mandatory purpose; the confirm modal states "visible to
  your supervisor," so purpose is a server-persisted audit fact, not cosmetic.
  Add to CreateExportRequest:  purpose: string  (REQUIRED)
  Controlled vocab the UI offers (last is free text):
    "Incident review" | "Police request" | "Customer complaint"
    | "Internal investigation" | "Maintenance check" | <free text>
  Behaviour: persist immutably with requesting user + timestamp; 422 on empty;
  echo it in the job response + the export listing (A6) — it's the "Purpose"
  column in the library (§296–304).

A2. Burn-in overlays: timestamp + camera-name · HIGH, NOT cheap
  The drawer offers timestamp + camera-name overlays. Export is currently
  remux/stream-copy (HEVC→H.264 transcode removed), and burning text into frames
  needs decode → draw → re-encode — a real new capability.
  Add:  overlays: { timestamp: bool, camera_name: bool }   // default both false
  Proposed two modes so the fast path stays fast:
    mode: "stream_copy"  -> current; overlays MUST be false/ignored (422 if set)
    mode: "rendered"     -> decode + burn-in + re-encode; overlays honoured
  Timestamp = per-frame wall-clock in camera-site tz; camera-name = display name.
  Style your call; we'll match it.

A3. Formalize the job response (size + expiry) · MEDIUM
  The drawer + library want real size; today we estimate client-side ("~") and
  read state/download_url out of an untyped body. Give GET /review/exports/{id}
  a typed schema:
    { job_id, state: queued|processing|ready|failed|expired, progress: 0..1,
      download_url|null, bytes|null, duration_s|null, codec|null, resolution|null,
      expires_at|null (ISO; drives "EXPIRED" in the library), error_msg|null,
      purpose, created_by, created_at }
  Optional pre-flight size estimate (POST ...?dry_run=1) would drop our guess.

A4. Document `mode` + gap semantics · RESOLVED (2026-05-28)
  `mode` ∈ {wallclock, compact} (enforced server-side; "continuous" was 400'd).
  wallclock = preserve the wall-clock timeline, gaps as freeze (our gap-warning text
  matches); compact = concatenate recorded segments, gaps dropped. We now send
  "wallclock"; "compact" is a future drawer option. Closed.

A5. Audio · LOW (video-first right now)
  Disabled "Include audio" today. When an audio path exists we'll want:
    audio: bool  + a per-camera audio-capability flag (to enable/disable honestly).

A6. LIST endpoint for the Clips & Snapshots library · HIGH  [added 2026-05-28]
  The library (§8 / §296–304) is a table of the operator's clips (server exports)
  + snapshots. Snapshots Watchtower has locally; but there is **no way to list
  past exports** — `/review/exports` is create-only, `GET /review/exports/{id}`
  needs a known id, and `/clips/range` requires camera_id+start+end (per-camera,
  not a library feed). So the server side of the library can't be populated.
  Request:
    GET /review/exports?limit&offset[&mine=true][&since=<ISO>]
      -> { exports: [ <A3 job object> ], total, offset, limit }
  i.e. a paged list of the A3 job objects (so purpose/created_by/created_at/bytes/
  duration/resolution/expires_at/download_url/state all come along). Filterable by
  requesting user ("My exports" pill) + a time window ("Last 7 days") ideally.
  Until this lands, Watchtower's library shows only locally-saved snapshots with
  an honest "server clips appear once listing is available" note.

════════════════════════════════════════════════════════════════════════════
B. Events  (/events)
════════════════════════════════════════════════════════════════════════════
Backs the Events screen (P5): filterable table + detail panel over GET /events,
with a live nav-rail unacknowledged badge.

B1. No acknowledge endpoint · HIGH
  EventResponse has a lifecycle `state`, but no route for an operator to
  acknowledge. The design makes ack central (per-event ✓ Acknowledged by <user>
  at <time> vs ● NEW, the nav badge, an "Unacknowledged" filter). We persist ack
  **locally per machine** today — it does NOT sync across operators or survive a
  re-install, which is wrong for a shared ops tool. Need:
    POST /events/{event_id}/acknowledge -> { acknowledged_by, acknowledged_at }
      (idempotent; records the authenticated user + server timestamp)
  And on EventResponse: acknowledged: bool, acknowledged_by|null,
  acknowledged_at|null (ISO); plus an `acknowledged` filter on GET /events. When
  this lands we switch the badge/filter/status from local to server-backed.

B2. The events feed is empty · please CONFIRM
  GET /events returns total: 0 for every query (incl. a wide range, and
  /events/timeline cameras: {}). Recording works (~hours of footage), so we'd
  expect motion/offline/gap events. Is the pipeline producing yet, or is a step
  still to enable? We render an honest empty state meanwhile. Please also send the
  authoritative `event_type` and `state` vocabularies (we map motion / offline /
  online / gap / bookmark and fall back to the raw type otherwise).

B3. GET /detections returns 500 · BUG
  GET /detections?limit=5 -> HTTP 500 (empty body). Not blocking (we use /events),
  flagging it.

════════════════════════════════════════════════════════════════════════════
C. Misc / nice-to-have
════════════════════════════════════════════════════════════════════════════
C1. Typed manifest fragment schema · BONUS
  Review-session manifest fragments are an untyped structure richer than the typed
  VideoSegment. We read codec + tier per fragment; the design + your hot→warm
  model also imply resolution + availability ("ready"/"hydrating"). Formalizing
  the fragment schema (codec, resolution, tier, availability, compact_start/end,
  wall_start/end) lets us drive the decoder + quality readout from real fields
  instead of inferring resolution from codec. Pairs with the mixed-codec timeline
  you offered to synthesize.

C2. Denormalized camera_name/group on EventResponse · NICE
  EventResponse has camera_id but no display name/group. We resolve locally by
  matching the trailing MAC against /streams (works); a denormalized
  camera_name/group would save every client the lookup. Not required.

════════════════════════════════════════════════════════════════════════════
D. Live streaming + camera source-of-truth  (/streams)  [added 2026-05-29]
════════════════════════════════════════════════════════════════════════════
Phase D makes cilex-vision the authoritative camera list: Watchtower now builds
the wall from GET /streams (id/name/status/group), server-scoped. The one gap is
that /streams carries no PLAYABLE URL, so we still keep a local provisioning
side-table just to supply RTSP URLs (a MAC-join — temporary "Track B"). One field
removes that side-table and makes the rest of the migration a deletion.

Performance decides the transport and it points one way: **RTSP passthrough via
go2rtc is simultaneously the lowest client latency AND the lowest backend memory.**
HLS/WebRTC force go2rtc to repackage/transcode (CPU + hundreds of MB) and add
0.5–6 s — wrong for a 16-tile near-real-time wall. "Use go2rtc" must mean its
RTSP output, never HLS, for live.

D1. rtsp_url + rtsp_sub_url on each /streams entry · HIGH
  Per camera, go2rtc restream URLs: rtsp://<host>:8554/<stream_id> (main + sub).
  This is NOT "expose raw camera RTSP" — it's go2rtc's restream, so no camera
  passwords reach the client and there's one source connection per camera (also
  retires the HiWatch IP-lockout problem). With this we delete the local
  provisioning import, the MAC-join, and the SQLite cameras table.

D2. Surface mac, vendor, model, firmware on /streams · MEDIUM
  From cameras.config_json (provisioner block) — so dropping local provisioning
  doesn't blank the camera identity panel (SingleCameraDetail).

D3. go2rtc config requirements · INFRA (the memory gate)
  - PASSTHROUGH only — forward H.264/H.265 RTSP→RTSP, never decode/encode
    (transcode ≈ 50–200 MB RSS + a CPU core per stream; passthrough ≈ single-digit
    MB). This is what keeps the wall affordable on the shared 16 GB host.
  - ON-DEMAND sources + idle disconnect (memory scales with ACTIVE streams, not
    total cameras; the wall is SD substream only).
  - RTSP server reachable from operator clients; single shared credential or a
    short-lived tokenized URL.
  - Acceptance gate: under realistic operators × 16-tile SD wall, go2rtc RSS
    < ~1 GB and no ffmpeg/transcode spawned for live. If it can't hold, we stay on
    Track B (direct camera RTSP, zero backend video load).

D4. Confirm playback HLS is pre-segmented · CONFIRM
  Recorded-playback HLS should be served from pre-segmented storage (SeaweedFS),
  never transcoded on request — memory = file I/O + small caches, not ffmpeg.

D5. Per-user config scope + admin-only raw-RTSP option · HIGH  [added 2026-05-29]
  Access model (operator requirement): Admin provisions cameras in the Cilex
  Provisioner and uploads the config to cilex-vision; each user profile is granted
  need-to-know access to specific cameras (Admin = all). So GET /streams — and the
  connection config from D1/D2 — must be returned strictly per the authenticated
  user's profile. Watchtower keeps NO local camera config: every client builds its
  list + stream URLs from its own scoped /streams response on login, so no client
  can see a camera (or its credentials) outside its profile. This is the
  precondition to deleting local provisioning entirely (D1).

  Transport is admin-selectable in Watchtower, default go2rtc:
   • Default (ALL users): the go2rtc restream URLs from D1 (`rtsp_url` /
     `rtsp_sub_url`) — camera passwords never leave the server.
   • Optional (ADMIN ONLY): for an admin-authenticated request, ALSO include the
     raw camera URLs WITH embedded credentials under distinct keys —
     `direct_rtsp_url` / `direct_rtsp_sub_url` — so an admin operator can switch
     Watchtower to direct-camera RTSP. NEVER return these raw-credential fields to
     non-admin users.
  Watchtower side (built now): a "Live video transport" preference (go2rtc |
  Direct RTSP) is shown only to admin users and defaults to go2rtc; it selects
  which of the above URLs the wall plays. See docs/plans/camera-config-from-backend.md.

D6. /streams: per-camera recording state · HIGH  [added 2026-05-30]
  Each /streams entry today carries `status` (live: online/offline/maintenance/error)
  but nothing about whether the camera is actually being recorded. So every Watchtower
  tile renders a dim "REC ?" badge — and the TopBar "Not Rec: 0" chip is honestly 0
  (no camera is *definitely* not recording) but reads to an operator as "all clear,
  everything is recording", which is the opposite of what we're saying. We need a
  recording signal so the badge can be truthful.

  Add a `recording` field on each /streams entry. Suggested vocab (lines up with
  Watchtower's CameraStatus::RecState enum):
    "recording"        — actively writing segments
    "not_recording"    — known not writing (operator stopped, schedule off, etc.)
    "recording_gap"    — has been writing, but a recent gap was detected
    "unknown" / null   — backend cannot determine (e.g. NVR / storage unreachable);
                         render as "REC ?" — but per-camera, not universal.

  Recording state changes slowly (operator action, fault transitions) so it's
  natural to ride on /streams alongside `status`. We will pre-wire the client to
  parse the field forward-compatibly: when /streams starts returning `recording`,
  Watchtower picks it up with no further work and the badge becomes truthful.

  Polling cadence: Watchtower will refresh /streams every 15s — industry-standard
  for VMS status polling (fresh enough to spot a stoppage, not so frequent that it
  hammers the backend). If you'd rather we hit a lighter shape than full /streams
  for the poll (e.g. `GET /streams/status` returning just
  `[{camera_id, status, recording}, …]`), call it out and we'll use that endpoint
  when it exists. Otherwise polling /streams is fine for our scale.

Client-latency note (ours to own, for context): live glass-to-glass is dominated
by GStreamer rtspsrc's 2000 ms jitter buffer, and QtMultimedia 6.4.2 exposes no
knob for it — needs a custom GStreamer pipeline or a Qt ≥6.5 upgrade on our side.
go2rtc RTSP (D1) does not change that client-side limit.

────────────────────────────────────────────────────────────────────────────
BACKEND RESPONSE — Cilex Vision, 2026-05-29  (statuses below are their reply)
────────────────────────────────────────────────────────────────────────────
  D1 rtsp urls ........ ✅ DELIVERED — GET /streams returns rtsp_url + rtsp_sub_url
                        (go2rtc rtsp://<host>:8554/<camera_id> and …-sub). <host>
                        is derived from the request, or pinned via GO2RTC_RTSP_URL.
  D2 identity ......... ✅ DELIVERED — mac/vendor/model/firmware from
                        config_json.provisioner on every entry (null when absent).
  D5 scope + raw ...... ✅ DELIVERED — /streams stays per-user-scoped (admin = all);
                        admin requests ALSO get direct_rtsp_url + direct_rtsp_sub_url
                        (raw creds, ch 101/102). Never returned to scoped users,
                        never logged.
  D3 go2rtc ........... PARTIAL — the SD wall is already PASSTHROUGH (sub = raw
                        channel-102 RTSP, no ffmpeg) and the main transcode is
                        on-demand, so the wall meets the memory gate today.
                        FAST-FOLLOW (tracked, not yet shipped): the MAIN/HD restream
                        is still VA-API-transcoded because browser MSE needs H.264.
                        To give native clients passthrough HD, register main as
                        dual-source [raw rtsp, ffmpeg:…#hardware=vaapi] (mirrors the
                        static go2rtc.yaml) — RTSP clients get passthrough H.265,
                        browsers still get H.264. Gated on the live memory measurement.
  D4 playback HLS ..... CONFIRMED (with nuance) — recording IS pre-segmented
                        (video_segments in SeaweedFS) and the native H.265 hot-window
                        path is served from those segments (no transcode); cold/
                        non-native renditions use the playback-service QSV rendition
                        CACHE (cached, not per-request-from-scratch).

────────────────────────────────────────────────────────────────────────────
BACKEND RESPONSE — Cilex Vision, 2026-05-30  (D6)
────────────────────────────────────────────────────────────────────────────
  D6 recording state .. ✅ DELIVERED (MVP subset) — GET /streams now carries
                        `recording` on every entry, vocab "recording" | "unknown"
                        (we don't yet have positive intent / gap detection to
                        emit "not_recording" or "recording_gap" honestly, so per
                        your "ship what you can honestly source" guidance, those
                        two will arrive when the recording-control plane has the
                        signal — never silently misreported). Computed at request
                        time from video_segments (a row with start_time in the
                        last 90s = "recording", else "unknown"); the (camera_id,
                        start_time) index keeps it sub-ms under your 15s poll.
                        Per-user-scoped consistent with D5 (admin sees all). No
                        new endpoint — the bare field on /streams as you proposed.

────────────────────────────────────────────────────────────────────────────
BACKEND RESPONSE — Cilex Vision, 2026-05-30  (§D3 fast-follow shipped)
────────────────────────────────────────────────────────────────────────────
  D3 main passthrough . ✅ DELIVERED (the fast-follow logged 2026-05-29 — flipped
                        to a P0 by an incident, not a calm-water improvement).
                        Single-source ffmpeg:vaapi main pushed every RTSP consumer
                        through a per-consumer VA-API transcode. clip-service's
                        rolling pre-event buffer opens one main connection per
                        camera (20 of them), so 20 simultaneous transcodes piled
                        up, blew the 512 MB cgroup, OOM-killed go2rtc, dropped
                        every dynamic registration, and clip-service then 404-
                        stormed at 5s retry — repeated four times in 15 min.
                        Fix mirrors the static infra/dev/go2rtc.yaml cam-1/cam-2
                        pattern: main is now DUAL-SOURCE — raw RTSP first (RTSP
                        consumers get H.265 passthrough, zero CPU/VA-API cost),
                        ffmpeg:{name}#hardware=vaapi second (kicks in only for
                        browser MSE/HLS H.264 consumers; the {name} reference
                        reuses one camera connection across consumers). Verified
                        live: ffprobe rtsp://go2rtc:8554/hiwatch-... returns
                        hevc 2560×1440 (passthrough), go2rtc RSS 52 MB / 512 MB
                        with 0 ffmpegs at idle, clip-service 404 storm stopped.
                        Watchtower's HD focused view now gets passthrough
                        natively — no transcode latency, no iGPU cost.

────────────────────────────────────────────────────────────────────────────
BACKEND RESPONSE — Cilex Vision, 2026-05-31  (E1–E5)
────────────────────────────────────────────────────────────────────────────
  E1 mosaic ........... ✅ ACCEPTED — building. ONE composited, time-synced grid
                        HLS via POST /review/mosaic-sessions; client decodes one
                        stream regardless of camera count. On-demand composite-
                        and-cache ("composite-on-scrub") — a live 16-cell
                        realtime composite isn't safe on the one shared iGPU.
                        Cells composite from the SUB stream (uniform H.264, full
                        30-day coverage, cheapest decode); single-codec output,
                        so NO mid-timeline codec switch. Manifest is the SAME
                        /review shape (compact_*/wall_*/clipped_to_finalized/
                        live_gap_s) for the composited timeline + a cells[]
                        mapping. Per-cell gaps render black; whole-grid gaps are
                        #EXT-X-GAP. Operator-scoped (403 on any out-of-scope cam).
  E2 grid export ...... ACCEPTED — export a window of the mosaic session via the
                        existing export_jobs pipeline; sequenced after E1 core.
  E3 poster frames .... ACCEPTED — GET /review/poster + sprite sheet (also your
                        thumbnail-hybrid fallback); parallelizable, low-risk.
  E4 coverage union ... ACCEPTED — A7 /review/coverage gains a batch ?camera_ids=
                        returning per_camera + union (no client-side union).
  E5 latent confirms .. resolution IS plumbed ("WxH"|null — stop inferring from
                        codec); clipped_to_finalized + live_gap_s ARE the safe
                        ceiling; mixed H.264/HEVC plays through single-camera but
                        is moot for the mosaic (one codec). Hydrating fragments
                        are REAL footage — don't drop them; today they 503 until
                        rehydrated, so we'll warm-on-create + a non-stalling cold
                        path (mosaic segments are always ready).
  Status .............. E1 foundation built + unit-tested (contract, composited
                        manifest, compositor logic; 48 tests). ffmpeg encode path
                        gated on live stack/iGPU verification (recorder/playback
                        paused behind a disk incident — never ✅ on code alone).
                        Full reply: 2026-05-31-multicam-synchronized-review.reply.md.

────────────────────────────────────────────────────────────────────────────
BACKEND RESPONSE — Cilex Vision, 2026-05-31  (E1 integration alignment + fixtures)
────────────────────────────────────────────────────────────────────────────
  Fixtures ............ ✅ 3 committed at docs/letters/fixtures/2026-05-31-mosaic/
                        (generated from real backend code; the .ts is the real
                        h264_qsv path): mosaic-session.response.json (4 cams, 2x2,
                        6 frags incl a no_recording gap), playlist.m3u8 (literal
                        served bytes), mosaic-segment.ts (960x540, 12fps, 6s,
                        single video stream, starts at PTS 0).
  I1 fields ........... ✅ CONFIRMED verbatim (fixture #1 proves). Additive only:
                        top-level expires_at + playlist_url; manifest echoes
                        grid+cells; gap fragments carry only wall_*/availability.
  I2 warming .......... ✅ DECIDED + BUILT — cold seg = 503 + Retry-After:1 +
                        X-Cilex-Mosaic-State:rendering (background render, dedup);
                        200 + …:ready on cache hit; qsv-unhealthy = 503 +
                        X-Cilex-Degraded; forwarded through the query-api proxy.
                        NOT a static manifest "warming" value (state is runtime,
                        per-scrub). ASK: honor Retry-After + keep >=8 retries (a
                        cold 16-cell render can exceed your 8x400ms=3.2s budget).
  I3 layout ........... ✅ CORRECTED — cells are crop-to-fill (cover), not
                        letterbox-pad: frame is exactly cols*cell_w x rows*cell_h,
                        row-major, gap-free, fully filled → your overlays align.
  I4 playlist ......... ✅ CONFIRMED — /api/review/… seg URIs (proxy-rewritable),
                        #EXT-X-GAP gaps (single-cam shape), VOD+ENDLIST+PDT.
  I5 no-footage ....... ✅ CONFIRMED — no-footage cell = black + 200; out-of-scope
                        = 403; union coverage so a partial wall still plays.
  I6 mosaic export .... ✅ design CONFIRMED, pending (404 today). session_id carries
                        the grid; reuses export_jobs + the token download shape.
  I7 group_id ......... ✅ CONFIRMED, ships with E2/A6 (the list that renders it);
                        purpose/A1 can carry a shared label meanwhile.
  I8 coverage ......... ✅ both shapes CONFIRMED (A7 days[] / E4 union), pending
                        build; retention_days = sub-stream (~30d).
  I9 window/tz ........ ✅ CONFIRMED — UTC …Z, <=24h, same rules as /review/sessions.
  Also ................ /review/sessions scope-check backfill shipped (no single-
                        cam regression); composite output now starts at PTS 0.
                        Full reply: 2026-05-31-mosaic-integration-alignment.reply.md.

────────────────────────────────────────────────────────────────────────────
BACKEND RESPONSE — Cilex Vision, 2026-05-31  (A7+E4 coverage + B2 prewarm built)
────────────────────────────────────────────────────────────────────────────
  A7 coverage ......... ✅ BUILT (pending live-verify) — GET /review/coverage?
                        camera_id= → {camera_id, tz, retention_days, generated_at,
                        days:[{date, has_footage, seconds, coverage_ratio, tiers,
                        first, last}]}. Operator-readable + per-user scoped (D5),
                        tz day-bucketing (default UTC, echoed), retention_days from
                        storage_tier_config (sub-stream span). The "nice later"
                        fields are already included.
  E4 union ............ ✅ BUILT — ?camera_ids=X,Y → {tz, retention_days,
                        generated_at, per_camera, union}; union = sorted distinct
                        days ANY camera has footage (drives the wall calendar).
  B2 prewarm .......... ✅ BUILT — POST /review/mosaic-sessions fires a fire-and-
                        forget warm of the first N=2 READY (non-gap) fragments,
                        anchored at the first ready (not window start, so day-views
                        on a leading gap still warm); lazy thereafter.
  B1 retry budget ..... NOTED — you honor Retry-After (~12s); we keep cold renders
                        well under it. X-Cilex-Mosaic-State unchanged.
  Tests ............... query-api 39, playback 35 green; offline only. Live verify
                        (coverage query + prewarm + iGPU encode) waits on the WD
                        Purple disk. E2+I7+A6 export queued next (your D #2). Reply:
                        2026-05-31-mosaic-integration-next-actions.reply2.md.

────────────────────────────────────────────────────────────────────────────
Most-unblocking, if you're prioritizing: A1 + A3 (export purpose + typed job
response) unblock the export drawer and the library's server side together with
A6; B1 turns acknowledge into a real shared-ops feature.

Changelog
  2026-05-27  Raised export asks A1–A5 (+ C1 aside).
  2026-05-28  Raised events asks B1–B3 (+ C2); added Clips list endpoint A6;
              consolidated the two dated letters into this living doc.
  2026-05-28  Cilex Vision responded (see BACKEND RESPONSE). Applied corrections:
              export mode → "wallclock"; event_type vocab → authoritative enum.
              B3 verified fixed (200 from our side). /health/storage now live.
  2026-05-29  Raised live-streaming asks D1–D4 (Phase D: backend = camera source
              of truth). The client already lists cameras from /streams; D1
              (go2rtc RTSP restream url) lets us delete local provisioning entirely.
  2026-05-29  Added D5: connection config must be per-user-scoped (need-to-know;
              admin = all), and an admin-only raw direct_rtsp_url+creds option so
              Watchtower's admin-selectable transport (default go2rtc) can do
              direct RTSP. Drove the architecture from an operator directive.
  2026-05-29  Cilex Vision DELIVERED D1/D2/D5 on GET /streams (rtsp_url +
              rtsp_sub_url, mac/vendor/model/firmware, admin-only direct_rtsp_*).
              D3: SD wall already passthrough; main/HD passthrough logged as a
              fast-follow. D4 confirmed (pre-segmented; cold renditions cached).
  2026-05-30  Added D6: /streams `recording` field, so the per-tile REC badge
              stops being universally "REC ?" and the TopBar "Not Rec" chip
              stops misleading the operator. Client will pre-wire parsing and
              start a 15s /streams poll (industry-standard VMS cadence).
  2026-05-30  Cilex Vision DELIVERED D6 MVP — /streams returns `recording`
              ("recording" | "unknown") computed from recent video_segments.
              "not_recording" / "recording_gap" deferred until positive intent
              and gap signals are sourceable. Client's 15s poll is now truthful.
  2026-05-31  Added E1–E5: synchronized multi-camera review. Spiked the
              client-side approach (N sessions → N QMediaPlayers → one master
              clock); sync logic works but streams cap at ~2–3 on the iGPU
              (measured offscreen + real GPU; per-session-proxy fix cleared the
              ~6-conn NAM limit, decode/feed is the remaining wall). Hence E1:
              ask the backend to composite one synchronized grid HLS stream.
              Full spec: 2026-05-31-multicam-synchronized-review.md.
  2026-05-31  Cilex Vision RESPONDED to E1–E5 (see BACKEND RESPONSE). E1
              ACCEPTED — building on-demand composite-and-cache mosaic (sub-
              stream cells, single-codec output); E1 foundation + 48 tests
              landed, ffmpeg path gated on live stack verification. E2/E3/E4
              accepted + sequenced; E5 confirmed/corrected.
              Reply: 2026-05-31-multicam-synchronized-review.reply.md.
  2026-05-31  Watchtower filed E1 integration-alignment (I1–I9 + a fixtures ask +
              canonical answers to the 6 questions). Cilex Vision DELIVERED 3
              offline fixtures (docs/letters/fixtures/2026-05-31-mosaic/, real
              h264_qsv), CONFIRMED I1/I4/I5/I9, CORRECTED I3 (crop-to-fill),
              DECIDED+BUILT the I2 warming signal (503 + Retry-After +
              X-Cilex-Mosaic-State), and backfilled the /review/sessions scope
              check. I6/I7/I8 design confirmed, pending E2/A6/A7+E4. Reply:
              2026-05-31-mosaic-integration-alignment.reply.md.
  2026-05-31  Cilex Vision asked Watchtower to ACT: verify the 3 fixtures offline
              (I1/I3/I4), decide the I2 cold-render retry budget (honor
              Retry-After, >=8s) + lazy-vs-prewarm warming, confirm 4 small items,
              and rank the pending build order (E2+I7+A6 vs A7+E4). Action letter:
              2026-05-31-mosaic-integration-next-actions.md (awaiting Watchtower
              reply + the post-disk live verification).
  2026-05-31  Watchtower ACTIONED it. Fixtures A1/A2/A3 all PASS offline (parse →
              zero field mismatches; proxy → gap-strip + #EXT-X-DISCONTINUITY kept
              + seg/3 index-skip OK; decode → single h264 960x540 stream, 2x2
              row-major crop-to-fill, overlays align). Decisions: B1 honor
              Retry-After + 12 retries (~12s budget, hard max ~24s) — IMPLEMENTED
              in HlsProxy; B2 prewarm N=2 anchored at the first READY fragment.
              C1-C4 confirmed (C3 resolution-read IMPLEMENTED in PlaybackScreen).
              Build order: A7+E4 coverage FIRST, then E2+I7+A6 export. Reply:
              2026-05-31-mosaic-integration-next-actions.reply.md.
  2026-05-31  Cilex Vision BUILT A7+E4 coverage (GET /review/coverage — single
              days[] + batch union) and B2 mosaic prewarm (N=2 anchored at the
              first READY fragment), offline-tested (query-api 39, playback 35).
              E2+I7+A6 export queued next (D #2); live verification pending the
              WD Purple disk. Reply:
              2026-05-31-mosaic-integration-next-actions.reply2.md.
  2026-05-30  Added A7: GET /review/coverage (per-camera days-with-footage +
              retention_days) to drive the new playback footage calendar.
              /recording/segments can't enumerate the window (limit≤1000, no
              paging) and retention_days is admin-only — hence a new
              operator-readable summary endpoint. Client UI shipped + waiting;
              full spec in 2026-05-30-footage-coverage-calendar-api.md.
  2026-05-30  Cilex Vision DELIVERED the §D3 fast-follow — main is now dual-
              source (raw RTSP + ffmpeg:vaapi). Forced by an OOM incident from
              clip-service's 20-camera rolling pre-event buffer. Native RTSP
              consumers (Watchtower HD focused view, clip-service) get H.265
              passthrough; browser MSE/HLS still gets on-demand H.264 transcode
              only when actually viewed.

— Cilex Watchtower
