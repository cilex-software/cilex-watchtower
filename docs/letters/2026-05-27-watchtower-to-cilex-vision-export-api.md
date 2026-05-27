To: Cilex Vision — From: Cilex Watchtower
Re: Export API — functional spec to fully back the S06/P4 export drawer
Date: 2026-05-27

We've built the full Export drawer + confirmation modal from the design handoff
(README §353–363). It's live in the client today, but only part of it can reach
your backend: per your OpenAPI, `POST /review/exports` accepts exactly four
fields and the job response is untyped.

    CreateExportRequest = { camera_id, wall_start, wall_end, mode }   // all required
    GET /review/exports/{job_id} -> 200 with an empty schema ({})

So the drawer collects several operator inputs that have nowhere to go. We are
**not** silently dropping them: the UI marks them "pending Cilex Vision support,"
and on confirm we transmit only the four fields you accept (with `mode:
"continuous"`). This letter is the functional contract we need to make the rest
real. It's ordered video-first, per our current focus.

────────────────────────────────────────────────────────────────────────────
1. Purpose (REQUIRED audit field)  ·  priority: HIGH, cheap
────────────────────────────────────────────────────────────────────────────
Every export in the design carries a mandatory purpose; the confirmation modal
states "This export will be visible to your supervisor," which implies purpose
is a server-persisted audit/compliance fact, not a client cosmetic.

Request — add to CreateExportRequest:
    purpose: string            // REQUIRED; free text, but the client offers a
                               // controlled vocabulary (see below)
Controlled values the UI presents (last is free-text):
    "Incident review" | "Police request" | "Customer complaint"
    | "Internal investigation" | "Maintenance check" | <free text>

Behaviour we need:
  - Persist `purpose` on the export job, immutably, with the requesting user and
    timestamp (for the audit trail / supervisor visibility).
  - Reject (422) a missing/empty purpose so the contract is enforced server-side,
    not just client-side.
  - Return it in the job response and in any future export listing (it becomes the
    "Purpose" column in the Clips & Snapshots library, README §296–304).

────────────────────────────────────────────────────────────────────────────
2. Burn-in overlays: timestamp + camera-name  ·  priority: HIGH, NOT cheap
────────────────────────────────────────────────────────────────────────────
The drawer offers "Include timestamp overlay" and "Include camera-name overlay."
These cannot be honoured by the current pipeline: you told us export is
remux/stream-copy (the HEVC→H.264 transcode path was removed), and burning text
into frames requires a decode → draw → re-encode pass. So this is a real new
server capability, not a field toggle.

Request — add to CreateExportRequest:
    overlays: { timestamp: bool, camera_name: bool }   // default both false

Proposed model — two export modes so the fast path stays fast:
    mode: "stream_copy"   -> current behaviour; overlays MUST be false/ignored
    mode: "rendered"      -> decode + burn-in + re-encode; overlays honoured
We'd drive `mode` from whether any overlay is requested. If you'd rather keep a
single mode and branch on `overlays`, that's fine — we just need the field and a
documented contract for which combinations are valid (e.g. overlays on a
stream_copy export should 422 rather than silently no-op).

When rendered: timestamp overlay = per-frame wall-clock in the camera-site
timezone; camera-name overlay = the camera display name. Position/style your call;
we'll match whatever you standardise.

────────────────────────────────────────────────────────────────────────────
3. Formalize the job response (incl. size + expiry)  ·  priority: MEDIUM
────────────────────────────────────────────────────────────────────────────
The drawer shows "Est. size"; today we estimate client-side (covered duration ×
a rough per-tier bitrate) and label it "~". The confirmation modal and the future
Clips library both want a real number, and we currently read `state` /
`download_url` / `error_msg` out of an untyped 200 body.

Request — give `GET /review/exports/{job_id}` a typed schema:
    {
      job_id: string,
      state: "queued" | "processing" | "ready" | "failed" | "expired",
      progress: number,            // 0..1, optional, for a real progress bar
      download_url: string|null,   // present when ready
      bytes: integer|null,         // actual size when ready; estimate while processing
      duration_s: number|null,
      codec: string|null,          // realised output codec
      resolution: string|null,     // realised output resolution (e.g. "1440p")
      expires_at: string|null,     // ISO; drives the "EXPIRED" status in the library
      error_msg: string|null,
      purpose: string,             // echo of (1)
      created_by: string,
      created_at: string
    }
A pre-flight size estimate (e.g. `POST /review/exports?dry_run=1` or a tiny
`GET .../estimate`) would let us drop the client-side guess entirely — nice to
have, not required.

────────────────────────────────────────────────────────────────────────────
4. Document `mode` + gap semantics  ·  priority: MEDIUM, doc-only
────────────────────────────────────────────────────────────────────────────
`mode` is a required free string with no enum in the spec. We send "continuous"
on faith. Please document the accepted values and their meaning — in particular
the gap behaviour. The drawer warns the operator when a selection crosses a
recording gap ("the export will contain a freeze frame for HH:MM:SS – HH:MM:SS").
We assumed "continuous" = preserve wall-clock, freeze-frame across gaps. Confirm
that, and tell us the alternative (e.g. a "compact" mode that drops gaps), so the
warning text matches reality.

────────────────────────────────────────────────────────────────────────────
5. Audio  ·  priority: LOW (secondary — we are video-first right now)
────────────────────────────────────────────────────────────────────────────
The drawer shows a disabled "Include audio (unavailable — video export only)".
When/if an audio path exists, we'll want:
    audio: bool                    // request audio track in the export
    + a per-camera capability flag (does this camera record audio?) so we can
      enable/disable the control honestly instead of hard-disabling it.
No rush — flag it as a later phase on your side too.

────────────────────────────────────────────────────────────────────────────
Aside (not export, but adjacent): the review-session manifest fragments are
served as an untyped structure richer than the typed `VideoSegment`. The client
reads `codec` and `tier` per fragment; the design and your own hot→warm model
also imply `resolution` and `availability` ("ready"/"hydrating"). If you can
formalize the fragment schema (codec, resolution, tier, availability,
compact_start/end, wall_start/end), we can drive the decoder and the quality
readout from real fields instead of inferring resolution from codec. This pairs
with the mixed-codec timeline you offered to synthesize.

Summary of asks, by priority:
  HIGH   (1) purpose field (+ 422 enforcement, persistence, echo in response)
  HIGH   (2) overlays field + a rendered/stream_copy mode contract (re-encode path)
  MEDIUM (3) typed job response with bytes / resolution / expires_at
  MEDIUM (4) documented `mode` values + gap semantics
  LOW    (5) audio field + per-camera audio capability
  BONUS  (—) typed manifest fragment schema (resolution, availability)

Ping us when (1) and the typed job response (3) land — those unblock the drawer's
purpose enforcement and a real size/progress without any client guesswork. We'll
keep the full UI shipped and switch each control from "pending" to live as the
fields arrive.

— Cilex Watchtower
