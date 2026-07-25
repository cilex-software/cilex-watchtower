# Client crash-report ingest: persist Watchtower forensic bundles on Cilex Vision

**From:** Watchtower
**To:** Cilex Vision
**Date:** 2026-07-26
**Scope:** one feature — an endpoint that accepts, persists, and lists crash/malfunction
forensic bundles uploaded by guard-station Watchtower installs. Nothing else is in
this letter.

## 1. Why this lands on the backend

Watchtower is being deployed to guard workstations we cannot touch after install:
non-technical operators, possibly no internet, sometimes rebooted mid-incident. We
are building **Warden**, a supervisor/collector that ships alongside Watchtower: it
restarts the app on death (guard's screen back in ~2 s) and packages a forensic
bundle — signal + backtrace, core/minidump (size-capped), rolling app logs, module/
BuildID map for offline symbolization, environment, telemetry tail.

The bundle needs to live somewhere WE can read it later, because the guard's box is
unreachable for diagnosis. The one server every functioning Watchtower can reach —
internet or not — is you: the same LAN that serves the footage. So the design is:
**Warden spools bundles locally and uploads them to Cilex Vision; you persist them;
we query them when diagnosing.** (USB copy of the spool remains the fallback when
even the backend is unreachable.)

Precedent for urgency: the 2026-07-25 SIGSEGV (9.5 h uptime, pixmap-reader thread)
was diagnosable only because the operator happened to capture stderr. On a guard
box that evidence would have been lost to a reboot.

## 2. Proposed contract

### 2.1 Upload (idempotent PUT)

```
PUT /client/reports/{report_id}                report_id = client-minted UUIDv4
Content-Type: multipart/form-data
  manifest   application/json                  (schema below, small)
  bundle     application/gzip                  (tar.gz, self-contained)
```

- **Idempotent by `report_id`**: re-upload after a crash-during-upload or a USB
  import of an already-sent bundle must return 200/409-with-existing rather than
  duplicate. Warden retries with backoff forever, across reboots — the server side
  must tolerate that.
- 201/200 → Warden moves the bundle from `pending/` to `sent/`. Any 4xx except
  auth → Warden keeps it and backs off (never deletes on failure).
- Auth: whatever you prefer — the existing `access_token` cookie (Warden holds a
  station credential) or a dedicated per-station ingest token. Your call; we adapt.

### 2.2 Read side (for diagnosis)

```
GET /client/reports?host=&since=&trigger=&limit=     → list of manifests
GET /client/reports/{report_id}                      → manifest
GET /client/reports/{report_id}/bundle               → the tar.gz back
```

That is the entire surface. No update/delete needed from clients.

### 2.3 Manifest sketch (schema versioned; server should store it verbatim)

```json
{
  "schema": 1,
  "report_id": "0b6c9a3e-…",
  "created_at": "2026-07-25T20:52:31Z",
  "station": { "host": "guard-01", "machine_id_hash": "sha256:…",
               "os": "ubuntu-24.04", "kernel": "7.0.0-28-generic",
               "gpu": "Intel UHD 770 / i915", "display": "wayland" },
  "app":     { "build": "8c01d32", "qt": "6.12.0-patched-beta1",
               "warden": "1.0.0" },
  "trigger": "sigsegv | sigabrt | sigbus | hang-watchdog | restart-loop |
              oom-kill | memtel-gap | manual",
  "crashed_at": "2026-07-25T20:52:23Z",
  "uptime_s": 34110,
  "rss_mb": 267,
  "signal": 11,
  "backtrace": "…[WT-FATAL] block, inline, pre-symbolized where possible…",
  "artifacts": ["journal-30min.txt.gz", "flightrec/", "maps-buildids.txt",
                "core.zst"],
  "bundle_bytes": 48211394
}
```

Bundles contain **no video frames, no screenshots, no credentials** (Warden scrubs
tokens before packaging) — logs, dumps, and machine facts only.

## 3. Numbers to agree on (your infrastructure, your call — proposals only)

| knob | proposal | note |
|---|---|---|
| max bundle size | 512 MB | LAN-only transfer; a zstd core off a ~300 MB-RSS client usually lands far under this. Warden truncates the core (keeps it whole locally) if over. |
| retention | 90 days | or forever for `trigger != manual` if disk allows |
| per-station quota | 5 GB, oldest-evicted | protects you from a crash-looping client |
| rate | ≤ 1 upload concurrently per station, client-enforced | Warden also debounces restart-loops into ONE bundle |

## 4. What Warden guarantees client-side

- Collection is reboot-safe and idempotent: raw material (core, journal, crash
  marker) is on disk from the moment of death; packaging resumes at boot if the
  guard power-cycled mid-collection.
- Upload never interferes with the restarted app (background, low IO priority).
- `report_id` is minted once, at marker creation — the same incident can never
  become two reports, whether it arrives via LAN, retry, or USB import.

## 5. Explicitly out of scope (separate letters if wanted)

- Station liveness / dead-man heartbeat ("guard-01's Warden went silent") — useful,
  but a different feature.
- Any alerting/notification on ingest — you persisting + us querying is enough for
  v1.

If the contract works for you, reply with the auth choice and the four numbers in
§3 and we'll build Warden against it. Same-day turnarounds have been the norm this
month — much appreciated as always.

— Watchtower
