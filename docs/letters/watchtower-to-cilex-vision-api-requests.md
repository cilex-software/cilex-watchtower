To: Cilex Vision — From: Cilex Watchtower
Re: Outstanding API requests (living doc)

This is Watchtower's single backlog of backend gaps — the things we need from
cilex-vision to fully back features we've already built to the design. We build
the complete UI, send only what your API accepts today, mark the rest "pending"
honestly (never silent no-ops), and track the contract here. Updated as we build;
supersedes the separate export-API (2026-05-27) and events-API (2026-05-28)
letters. Changelog at the bottom.

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

A4. Document `mode` + gap semantics · MEDIUM, doc-only
  `mode` is a free string with no enum; we send "continuous" on faith. Document
  the accepted values + gap behaviour. The drawer warns when a selection crosses
  a recording gap ("freeze frame for HH:MM:SS – HH:MM:SS"); we assumed
  "continuous" = preserve wall-clock + freeze gaps. Confirm, and name the
  alternative (e.g. "compact" drops gaps) so our warning text matches.

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

────────────────────────────────────────────────────────────────────────────
Most-unblocking, if you're prioritizing: A1 + A3 (export purpose + typed job
response) unblock the export drawer and the library's server side together with
A6; B1 turns acknowledge into a real shared-ops feature.

Changelog
  2026-05-27  Raised export asks A1–A5 (+ C1 aside).
  2026-05-28  Raised events asks B1–B3 (+ C2); added Clips list endpoint A6;
              consolidated the two dated letters into this living doc.

— Cilex Watchtower
