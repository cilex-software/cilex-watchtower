# Camera availability history

The availability log records what this station and Vision actually observed.
It separates camera reports, live video, snapshots, the recording catalogue and
loss of contact with the server. A problem on one station does not prove a
camera is down everywhere.

## View or send the log

1. Open **Health → History and sync**.
2. Select a camera, period, observation type or source.
3. Check the observation time, reported onset and delivery label. **Baseline**
   is an initial reading; **Observation gap** means that interval was unobserved.
4. If permitted, choose **Sync availability log now**. The panel shows pending
   records, the oldest pending age, the last successful upload and the next attempt.

Administrator, owner and engineering sessions can request a sync. Display-only
sessions cannot open operator history. Other users see only permitted cameras;
administrators and owners can also inspect station-wide and removed-camera history.
Blocked authentication or conflicting replies leave records saved and pause sending.

New observations are saved immediately. Automatic sending runs every **three
hours while Watchtower is running**. After a restart, saved records remain and
an overdue upload resumes. Successful sending does not delete local history.
The view shows up to 1,000 observations; narrow its filters if that limit appears.

## Understand the limits

- A snapshot with unknown age/source is **unknown**, even if an image arrived.
  The current server's snapshot metadata does not establish live-image freshness.
- RTSP and HLS delivery use their media-frame observation boundaries. Cached
  images do not prove recovery or a current camera sensor timestamp. Native HLS
  verification is tracked separately in the evidence record.
- A gap, restart or sleep cannot establish an exact continuous outage duration.
- Local history begins when this feature runs. Older Vision records appear only
  when the server supplies them; earlier local events are not reconstructed.

## Setup and storage

Sending requires this station's own provisioned credential, a matching server
address and an explicit camera-journal grant. An administrator must fix a missing
grant or rejected credential. Never copy another station's credential.

The database is `availability/availability.sqlite3` under the application's data
directory. History is retained indefinitely by default. The default local storage
budget is 256 MiB. Pending/rejected records are not silently removed; storage
failure or capacity exhaustion is shown as incomplete logging and needs attention.
Do not delete the database to clear an upload problem.

Deployment and real-server acceptance must be checked separately. See the
[verification record](../verification/2026-10-29-camera-availability/ui-and-runtime-checks.md)
for measured checks and outstanding work.

## Implementation references

- [Shared v1 contract and fixtures](../reference/camera-availability-v1.md).
- [Worker and synchronization](../../src/models/CameraAvailabilityWorker.cpp).
- [Durable journal and capacity policy](../../src/models/CameraAvailabilityJournal.cpp).
- [Operator authorization](../../src/models/CameraAvailabilityService.cpp).
- [History panel](../../qml/AvailabilityHistory.qml).
- [HLS media-frame observation](../../src/models/MediaDeliveryObserver.cpp).
- [HTTP integration checks](../../tools/tests/camera-availability-sync/README.md).
