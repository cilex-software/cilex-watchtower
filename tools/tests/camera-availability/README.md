# Camera availability journal fixtures

This target tests the worker-owned SQLite journal with Qt Core and Qt Sql. It
does not connect to cameras, upload synthetic incidents, or change a running
Watchtower installation.

```sh
cmake -S tools/tests/camera-availability -B build-availability-journal \
  -DCMAKE_PREFIX_PATH=/path/to/Qt -DCMAKE_BUILD_TYPE=Release
cmake --build build-availability-journal --parallel 2
ctest --test-dir build-availability-journal --output-on-failure
```

The executable needs the matching Qt libraries and QSQLITE plugin. Use the
platform's Qt runtime search path, or deploy those files beside the test.

Coverage includes durable UUIDs/sequences and immutable retry envelopes;
condition/source isolation; restart observation gaps; exact-ID and partial ACKs;
413 rebatching and retained poison records; 180-minute scheduling and clock
changes; native import/cursor atomicity; and default indefinite history.

Storage fixtures hold a second SQLite write lock, limit SQLite page capacity,
present corrupt/unsupported/conflicting schemas, and reopen committed data.
One isolated child exits without destructors after committing a WAL transaction.
Failed writes remain failures; a later successful commit preserves the observed
logging-loss counter.

Reusable WAL fixtures preserve history and exact active retry bytes while
reclaiming the allocated tail. Independent readers exercise incomplete
checkpoints and fully backfilled but busy truncation, prompt capacity refusal,
restoration of the normal timeout, and recovery after releasing the reader.
Batch-envelope allocation is covered by the same physical capacity fence.

Capacity checks cover ordinary observations, native imports and monitoring-run
boundaries. Native page refusal leaves both events and cursor unchanged. A
successful write after observation loss commits an explicit gap and a fresh
baseline before allowing another measured incident. History resolves later
local/native recovery references without altering persisted upload payloads;
upstream `unknown` reports retain their original domain and metadata.

For separate validation against the copied backend contract, export an actual
journal-generated **synthetic fixture** without uploading it:

```sh
camera-availability-journal-test --write-protocol-fixture generated-batch.json
```

These tests do not establish installed-package operation, GUI responsiveness,
real media recovery, live backend round trips or production three-hour timing.
