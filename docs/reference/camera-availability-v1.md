# Camera availability journal — v1

Status: shared v1 implementation contract for CAM-AVAIL-BE-20261027. The JSON
schemas and fixtures in `camera-availability-v1/` are normative with this text.
Watchtower must consume these exact fixtures; changes require an explicit v2 or
coordinated correction before either implementation ships. This document does
not establish that either application is deployed or that footage is available.

## Identity, sources and permissions

All station routes require a provisioned `X-Cilex-Station-Token`. The server hashes
it and resolves one unrevoked station; body station IDs, hostname/IP headers,
bootstrap credentials, user/display sessions and `X-Watchtower-Station` never
substitute. Existing display and FPS/crash/heartbeat contracts remain unchanged.
Unknown/missing credentials return401; revoked credentials return403.

One database-owned singleton persists a random `backend_instance_id` through
process/container restarts. A restored database retains that identity; an actual
independent backend must create a different installation database/identity before
accepting uploads. URLs/hostnames/default site IDs are not installation identity.
Capabilities return this ID, the authenticated station ID and effective limits.
Every batch targets that exact backend ID; mismatch is409 and performs no write.

Journal scope is a new explicit grant: one existing station, one site UUID, a
nonempty explicit set of canonical camera TEXT IDs, and `allow_station_events`.
No registration or empty scope implies whole-fleet authority. Scope creation/
replacement is an admin/owner operation on an existing station and never rotates
its token or clears revocation. Camera IDs are existing canonical identifiers
(e.g. `hiwatch-…`), not UUIDs, display names or current IPs. Grants and historical
camera identities survive decommissioning without retargeting old events.

`PUT /client/stations/{station_id}/camera-availability/scope` accepts
`{site_id,camera_ids,allow_station_events,expected_revision}`; revision0 means no
prior grant. All cameras must belong to that site; a stale revision is409.
GET on the same path is admin/owner-only. Every ingest/feed transaction rechecks
credential revocation and current scope. Missing scope returns an actionable403
`scope_not_configured`; a camera/site outside the grant is403. Grants are explicit
snapshots: future cameras require an administrator update.

Sources remain separate: `origin=client` with provenance
`backend_reported_by_client` or `client_observed`, and server-only
`origin=backend_native`, provenance `backend_native`. Uploads cannot claim native
provenance. Current camera status, FPS/health, heartbeat/liveness, alerts and
incidents are never mutated by uploaded history.

## Requests and immutable content

Endpoints:
- GET `/client/stations/camera-availability/capabilities`
- POST `/client/stations/camera-availability/batches`
- GET `/client/stations/camera-availability/changes`
- GET `/camera-availability/history`

Batch fields (extra fields forbidden): schema_version exactly integer1;
backend_instance_id, batch_id, producer_id UUIDs; events array of1–500 records.
Batch/event/producer IDs and local_seq are persisted locally before upload.
An immutable batch ID must replay the same ordered event payload; changed reuse
is409 even if some events were independently accepted in another batch.

Each event has event_id UUID, positive signed64 local_seq, run_id UUID,
nullable camera_id TEXT (1–64 ASCII letters/digits/._:-), domain, provenance,
state, transition, observed_at, nullable condition_id, optional related_event_id,
reason_code, optional monotonic_ms/duration_ms, details and backend_observation.
Absent optional fields canonicalize to null/empty defaults; UUID lexical forms
canonicalize to lowercase. Original explicit-timezone timestamp text is retained
and participates in immutable content; offset/clock values are not rewritten.
All integers are strict (booleans/fractional values refused); numeric offsets and
durations are nonnegative signed64. JSON NaN/infinity/duplicate object keys and
unknown fields are invalid. Canonical payload hashes use sorted UTF-8 JSON,
finite values and deterministic compact separators.

Domains: backend_reachability, recording_catalogue, live_delivery,
snapshot_delivery, backend_connectivity, monitoring.
States: available, unavailable, degraded, unknown, not_monitored.
Transitions: initial, failure, recovery, state_change, monitoring_gap,
monitoring_resumed.

Combination rules:
- backend_reachability and recording_catalogue uploads require a camera ID,
  backend_reported_by_client provenance and backend_observation. They describe
  reports received from Vision, not independent physical observations.
- live_delivery and snapshot_delivery require a camera ID and client_observed.
- backend_connectivity requires camera_id=null and client_observed; it describes
  this producer's contact with Vision, never a fleet camera outage.
- monitoring uses client_observed; camera_id may be null for the station or a
  granted camera ID for one monitored pipeline. Station-wide events require the
  explicit allow_station_events grant.
- failure requires unavailable/degraded and nonnull condition_id.
- recovery requires available, nonnull condition_id and related_event_id.
- monitoring_gap is only monitoring and requires unknown/not_monitored.
- monitoring_resumed is only monitoring and requires available/unknown.
- not_monitored is only monitoring. initial/state_change cannot claim a measured
  outage duration. duration_ms is allowed only on recovery with monotonic_ms and
  a condition/reference; it remains a client-reported same-run measurement.

reason_code is a1–64 character lowercase ASCII `[a-z][a-z0-9_]*` code, never free
text. Producers should use stable codes: initial_observation, tcp_probe_failed,
tcp_probe_succeeded, backend_status_reported, catalogue_recent, catalogue_stale,
catalogue_absent, frame_delivery_gap, frame_received, pipeline_error,
snapshot_request_failed, snapshot_received, backend_request_failed,
backend_request_succeeded, monitor_started, monitor_stopped, observation_gap,
monitor_resumed. Unknown well-formed codes are retained as producer-defined
reasons, never interpreted as a new alarm or stronger evidence.

Details allow only: stream_variant(main/sub/unknown),
transport(rtsp/http/webrtc/hls/tcp/unknown),
observer_scope(backend/station/pipeline/snapshot_request/monitoring),
pipeline_id(opaque identifier,1–64 ASCII letters/digits/._:-),
consecutive_failures(0–10000), catalogue_age_ms(nonnegative signed64),
threshold_ms(nonnegative signed64), last_positive_at(explicit-timezone timestamp).
No arbitrary strings, URLs, credentials, tokens, images or logs are accepted.

backend_observation allows only status(online/offline/maintenance/error/unknown),
recording_state(recording/stalled/armed/offline/disabled/unknown), nullable explicit-timezone
status_since, recording_since, last_seen, last_segment_at, received_locally_at,
and upstream_event_id UUID. received_locally_at is required; the relevant status
or recording_state is required for its domain. Other fields may be unknown/null.
These fields are reported values, not native facts. Client-observed domains
must not attach a backend_observation. Duplicate event IDs or producer sequences
within one batch are422 rather than a partial acknowledgement.
An unresolved upstream ID remains explicitly unresolved; it cannot mint native
history. Reason/details/backend_observation are bounded by their schemas and
maximum1MiB whole request body.

The observer vantage is the tuple of stream_variant, transport, pipeline_id and
observer_scope, including unknown/omitted values. A recovery with a different
vantage or decreasing monotonic offset cannot pair with a failure. Records stay
visible with incompatible_reference; their submitted values are not rewritten.

## Atomicity, duplicates and errors

One bounded transaction validates all authorization, identities and conflicts,
COPYs a bounded staging set and inserts set-wise. Event ID uniqueness is per
station; producer sequence uniqueness is per station+producer. Changed content
for either key is409 and rolls back the complete batch. Identical replay is a
duplicate success. Concurrent requests serialize allocation/identity validation;
no last-write-wins update of event payloads is permitted.

A successful response contains schema_version, batch_id, backend_instance_id,
reporter_station_id, server_received_at, accepted_event_ids and duplicate_event_ids.
It is emitted only after commit. These disjoint lists account for EVERY submitted
event, never a maximum sequence acknowledgement. A lost response can be retried
with the same batch without creating duplicate history. Local history/outbox is
not deleted by a server response except exact acknowledged pending identities.
An identical batch replay returns its original server_received_at; immutable
event receipt times never change when another batch contains duplicates.

Effective initial limits:500 events,1048576 request bytes; station admission
allows20 new batches/minute and10000 events/minute with bounded shared database
counters, maximum4 concurrent ingest requests per API process, pool acquisition3s,
statement timeout5s, lock timeout1s, work_mem1MB and no parallel query workers.
Duplicate retries remain bounded/authenticated and consume request admission.
Capabilities advertise actual effective values; no unbounded database wait.

Errors use `{detail:{code,message,retryable}}`:
401 missing/unknown token: pause retries until credentials change;
403 revoked/missing/foreign scope: retain queue, ask administrator;
409 backend/batch/event/sequence conflict or changed cursor scope: retain originals,
re-discover/reconcile explicitly, never rebind or overwrite;
413 body/event limit: retain queue, split into NEW immutable batches;
422 malformed/invalid combinations: retain records for correction;
429 admission refusal: retain queue and honor Retry-After;
503 unavailable schema/database/ownership timeout: back off, retain queue, retry
same immutable identities. Invalid atomic batches commit no subset.
Parameter-validation errors on these new routes use the same sanitized422
shape. Normal-user login/session/role refusals retain the existing platform
authentication error contract; this feature does not redefine those public codes.

## Native owner and observation gaps

Use the existing CameraHealthMonitor TCP/debounce and catalogue sweep. One
session advisory-lock owner, with a dedicated connection, fences overlapping
API workers. Do not hold a transaction while probing cameras. After observation,
lock the shared ledger head BEFORE camera/state rows, re-read/fence managed
camera identities/configuration, then commit current status, native events and
monitor checkpoints together. No second fleet probe loop is introduced.

Native observation time is the actual server observation; old status_since or
recording_since are reported onsets, not backdated journal history. First
successful observation emits a baseline and monitor-start record. Restart/lost
ownership/long failed-observation interval records an explicit monitoring gap
and resumed baseline, never camera recovery. Native conditions pair only within
one uninterrupted run and domain/camera; a gap invalidates recovery pairing.
Existing maintenance/error states and unrelated recording configuration remain
untouched. TCP reachability is listening-service evidence. A stale catalogue
is an archive-index observation, not capture stopped or footage unavailable.

## Stable feed and scoped history

All client/native append transactions lock a persistent singleton head BEFORE
allocating positions; no nextval or timestamp watermark. Positions and head
advance commit together, so a lower-position transaction cannot commit later.
Native-only `/changes` filters out ALL uploaded observations and cannot sync-loop.
Numerical holes from other sources are expected, not missing records.

A versioned opaque cursor binds backend ID, station/scope revision, query/filter
fingerprint, last position and a FIXED through_position captured from committed
head. With more matches, next position is last emitted position; after exhaustion
it advances to through_position. Bounds are1–500 rows. Each page reauthenticates
and rechecks camera scope; changed scope/cursor/filter is409. A new native poll
starts after the prior exhausted watermark with a new committed upper bound.
Responses return next_cursor for another page of the fixed snapshot (null when
exhausted), plus resume_cursor for a new native poll after the exhausted bound.
The resume cursor has no fixed upper bound until that poll starts. It must not
be used before all next_cursor pages are consumed, which could skip matches.

`/history` requires a normal user token/session and admin/owner/operator/viewer/
engineering role authorization; display-only and station tokens cannot use it.
Mandatory timezone-aware from/to window is half-open and at most31 days. Filter
by camera_id, reporter_station_id, producer_id, source, domain and paginate by
ledger position (receipt/commit order, not client wall-clock order). Admin/owner
can read camera-less records; other users receive ONLY camera rows within their
explicit camera_scope. Empty camera scope means no rows, never unrestricted.
Historical identity/site snapshots survive camera decommissioning; no name/IP
join reassigns history. Response includes original observation time, receipt time,
reported upstream onsets, last positive evidence, source/observer, condition links,
known monitoring gaps and clock-quality flags. Missing/unobserved is not zero.

Client clocks/durations are untrusted and always labelled. Preserve future/late/
out-of-order times with anomaly flags. A matching related failure is checked
within station+producer+run+camera+domain+condition; missing references remain
pending, foreign/run/gap mismatches never close a condition. Client condition
links remain REPORTED relationships, not authoritative merged outage intervals.
Do not fabricate a precise duration across restart, sleep, gaps or machines.

Each history event has clock_quality `{authority,flags,...}`. Client authority is
client_reported. A timestamp more than300s ahead is future_observation; a receipt
delay over10800s is delayed_delivery; lower producer sequence and backwards
client clocks are producer_sequence_out_of_order/client_clock_out_of_order.
Native authority is backend_observed; no camera source clock is inferred.
Failure records expose condition_status: open_unpaired_failure,
interrupted_by_monitoring_gap or recovery_referenced; other events use
not_applicable. condition_status_authority/relationship_authority label the
source. Recovery relationship_status is pending_reference,
incompatible_reference, reported_same_run_reference or native_same_run_reference;
events without references use none. Upstream references expose not_supplied,
unresolved_reference or resolved_native_reference. Pairing and condition checks
use the fixed committed pagination bound, so later pages do not invent an
outcome from a future append. An old run's unresolved failure is never closed by
a new-run baseline. Open/unpaired is an observation relationship, not proof the
physical fault continues.

## Retention and rollout

V1 retention is explicitly INDEFINITE: no automatic journal pruning. This protects
late uploads, lost acknowledgements and immutable idempotency records. Discovery
advertises `{mode:"indefinite",automatic_deletion:false}`. This is independent of
video age/budget controls; those controls must never delete journal history.
A finite retention policy requires a separately reviewed/versioned purge and
replay-tombstone contract, not silent reuse of video retention settings.

Migration0101 is owned by this task and descends from published0099. Unpublished
primary-checkout0100 Labs work is preserved; do not depend on it or blindly apply
an ambiguous `head`. Native transitions start only after schema/config enablement;
no history before deployment is invented. Rollback disables new routes/native
journalling without deleting committed history or rolling back unrelated data.

Operational acceptance requires a disposable real PostgreSQL migration/API/client
round-trip, concurrent commit/feed tests, authorization/rollback/lost-ACK tests,
unchanged existing station/display/health contracts, exact published API-only
rollout, explicit pilot scope and authenticated durable query-back. Production
fault injection/synthetic outages and real camera disconnection are forbidden.
