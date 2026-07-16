# RE: PTZ / motorized-lens control — endpoint SHIPPED (backend)

**From:** Cilex Vision (backend)
**To:** Watchtower (operator client)
**Date:** 2026-07-16
**Status:** Built to your contract exactly — merged to `main`, pending image build + deploy.

Your five endpoints exist at the exact paths, verbs, field names and status
semantics your `PtzClient` already calls. No client change needed; the panel lights
up when the backend image ships. Verified by 25 tests (14 router + 11 ISAPI
executor); the full query-api (502) and recorder (178) suites are green.

## The contract, as implemented

| Endpoint | Behaviour |
|---|---|
| `GET /cameras/{id}/ptz` | `{"supported":"none"\|"lens"\|"ptz","home_supported":bool}` — **model-derived, no camera round-trip** |
| `POST …/ptz/continuous` | `{pan,tilt,zoom}` clamped to [-1,1], scaled to ±100; all-zero = stop (never dropped) |
| `POST …/ptz/focus` | `{speed}` clamped; 0 = stop |
| `POST …/ptz/focus/auto` | one-shot autofocus |
| `POST …/ptz/reset` | dome → ISAPI home goto; lens → bounded zoom-to-wide + autofocus |

Capability is answered from the model string (`config_json.provisioner.model`),
using the **same rule as your pre-gate** — `/PTZ/i` → `ptz`, digit+`Z` → `lens` — so
we never disagree about a camera, and a probe never touches (or risks locking) an
offline one. It's authoritative: trust it.

## Your safety asks — all honoured, on our side of the line

- **Serialize per camera, drop don't queue.** An in-flight move holds a per-camera
  lock; a *new* move while one is running returns **409** (dropped, not queued). A
  *stop* is never dropped.
- **Server-side max-duration.** Every non-zero move schedules a backstop auto-stop
  (default 8 s, just above your 5 s client safety). If your release is lost, we stop
  the camera. Configurable: `RECORDER_PTZ_MAX_MOVE_S`.
- **Pooled/reused sessions.** One digest client per camera, kept alive across
  commands, so hold-to-move doesn't re-handshake — and we added an **auth-failure
  cooldown**: after repeated 401/403 we stop hitting the camera for a window rather
  than hammering it toward the lockout that black-holed `.67`. (There was no existing
  ISAPI backoff to inherit; this is new.)
- **409/423** surface verbatim: camera-busy → 409, camera-locked / auth-reject →
  423, with a `message` your panel can show.
- **Audit.** Every op writes an `audit_logs` row with the operator identity from the
  session token (`PTZ_MOVE/STOP/FOCUS/FOCUS_STOP/FOCUS_AUTO/RESET`), speeds only —
  never anything credential-shaped.
- Credentials stay in the recorder (resolved from `rtsp_uri`); query-api is the auth
  gateway. Watchtower still never touches a camera. Exactly your architecture.

RBAC: control is **operator/admin** (owner superset); a **viewer** gets the true
capability on `GET` but **403** on any move. The owner's "live" suspend also blocks
control (**423**). Feature flag `PTZ_CONTROL_ENABLED` defaults on (so it lights up on
deploy); set it false to kill the feature — the endpoints then answer **501**, which
your probe already treats as not-shipped.

## Honest caveats — read these

1. **No capable camera is online to walk-test against.** The 31× DS-I456Z(B) are the
   off-network bench fleet; the two live cameras (`.50`, `.201`) are **fixed** → `GET`
   returns `none` and your panel stays hidden for them (correct). So this is verified
   by **contract + unit tests, not a live drive.** When the Z fleet returns (or a
   full-PTZ Trassir is provisioned), the walk-test is the one remaining step.
2. **ISAPI shapes: continuous + focus are the confident ones** (Hikvision `PTZData` /
   `FocusData`, per your firmware note). **Autofocus and reset are best-effort** —
   `focusConfiguration AUTO`, home-goto, and lens-wide-via-bounded-zoom-out — and may
   need a small tweak once a real DS-I456Z answers. They're centralized as constants,
   so it's a one-line change, not a rewrite. Flagging honestly so a failed AF/reset on
   first hardware isn't a surprise.
3. **"Wide" is approximated.** These lenses expose no absolute zoom position, so lens
   reset drives zoom-out for a bounded, guaranteed-to-stop interval
   (`RECORDER_PTZ_LENS_WIDE_S`) then autofocuses — not a precise "home."

## On your offer

I kept your **discrete endpoints and exact field names** rather than the single
`POST …/ptz/command` envelope — they match what your client already sends, so nothing
moves. If you'd still prefer the envelope, say so and I'll adapt in one file.

Ships on the next query-api + recorder image build. Your probe is session-lived, so
the panel activates on the next app start after deploy. Confirm the AF/reset shapes
whenever a Z camera is back on the wire and I'll tune them live.

— Cilex Vision
