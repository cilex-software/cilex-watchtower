# PTZ / motorized-lens control — endpoint request (client UI already shipped)

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend)
**Date:** 2026-07-16
**One problem:** operators need pan/tilt/zoom/focus control and a one-click
"restore defaults" for cameras whose hardware supports it. Watchtower cannot
(and must not) talk to cameras directly — you own the credentials and the
lockout backoff — so this needs a small backend surface. Everything below is
already implemented and verified client-side against these exact shapes; the
feature lights up on your deploy with **no client release**.

## Fleet reality (from your /streams payload, 2026-07-16)

| model | count | class |
|---|---|---|
| DS-I456Z(B) | 31 | motorized lens (2.8–12 mm zoom + focus) — `lens` |
| DS-I402(D) (.201), DS-I259M(C) (.50) | 2 | fixed — `none` |
| Trassir (pending provisioner) | — | TBD, some may be full `ptz` |

The client pre-gates the button on the backend-reported model string (Z
designator / "PTZ"), then trusts only your capability answer.

## Requested contract (the client calls these today)

1. `GET /cameras/{id}/ptz`
   → `200 {"supported": "none"|"lens"|"ptz", "home_supported": bool}`
   The client currently receives 404 and renders an honest "backend pending"
   panel state; 404/405/501 are treated as not-shipped-yet (cached per
   session), anything else as transient.
2. `POST /cameras/{id}/ptz/continuous` `{"pan":-1..1,"tilt":-1..1,"zoom":-1..1}`
   All-zero = **stop**. Hold-to-move UX: we send one start on press, one stop
   on release, plus a client-side 5 s auto-stop safety. Please also enforce a
   server-side max-duration (camera must never be left moving if our stop is
   lost).
3. `POST /cameras/{id}/ptz/focus` `{"speed": -1..1}` — 0 = stop.
4. `POST /cameras/{id}/ptz/focus/auto` `{}` — one-shot autofocus.
5. `POST /cameras/{id}/ptz/reset` `{}` — **the one-button restore**:
   - `ptz` class: go to home/default preset (ONVIF GotoHomePosition);
   - `lens` class: lens to default (wide) + autofocus;
   - idempotent, safe to repeat.

## Mapping notes (for your bridge)

- DS-I456Z(B) (HiWatch/Hikvision): ISAPI `PUT /ISAPI/PTZCtrl/channels/1/continuous`
  (pan/tilt/zoom fields; zero = stop) and
  `PUT /ISAPI/System/Video/inputs/channels/1/focus` for focus; ONVIF Imaging
  `Move`/`Stop` also works on this firmware (V5.7.2).
- Full-PTZ (future Trassir): ONVIF PTZ `ContinuousMove` / `Stop` /
  `GotoHomePosition` map 1:1 to (2) and (5).

## Safety asks (your side of the line)

- Serialize commands per camera; clamp speeds; drop, don't queue, stale moves.
- `409`/`423` when the camera is busy/locked — the client surfaces the message
  verbatim in the panel.
- Remember the fleet lockout behaviour (cameras black-hole after auth storms):
  pooled/reused sessions on your bridge, please — one more reason this must
  not live in the client.
- Audit-log PTZ ops with the operator identity from the session token.

## What's already live client-side (verified 2026-07-16)

Maximized live view → PTZ button (only on capable models) → panel with
pan/tilt pad (`ptz` class only), zoom/focus rows, **Restore defaults** button,
keyboard drive (arrows / + / −), hold-to-move with guaranteed stop on
release/cancel/focus-loss, per-camera capability cache, RU localization, and
the honest pending banner your 404 currently produces. Probe result is
session-lived, so your deploy activates the panel on the next app start.

Confirm the shape or counter-propose — field names are cheap to change until
you ship. If you prefer a single `POST /cameras/{id}/ptz/command` envelope,
say so and we'll adapt in one file.

— Watchtower
