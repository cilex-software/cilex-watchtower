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

— Cilex Watchtower
