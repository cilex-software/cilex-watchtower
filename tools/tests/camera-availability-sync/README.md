# Availability synchronization integration checks

This suite runs the shipping worker and SQLite journal through real Qt HTTP
requests to a disposable loopback-only protocol fixture. It uses the copied
Vision v1 contract. It never reads station credentials, contacts real cameras,
uploads synthetic production incidents or changes the running applications.

Build in a provisioned developer shell:

```powershell
cmake --fresh -S tools/tests/camera-availability-sync -B C:/wt/availability-sync-test `
    -G Ninja -DCMAKE_BUILD_TYPE=Release `
    -DCMAKE_PREFIX_PATH=C:/wt/Qt/6.12.0/msvc2022_64
cmake --build C:/wt/availability-sync-test --clean-first --parallel 2
$env:PATH = "C:/wt/Qt/6.12.0/msvc2022_64/bin;$env:SystemRoot/System32;$env:SystemRoot"
$env:QT_PLUGIN_PATH = 'C:/wt/Qt/6.12.0/msvc2022_64/plugins'
& C:/wt/availability-sync-test/camera-availability-sync-test.exe `
    -o C:/wt/availability-sync-test/results.xml,junitxml `
    -o C:/wt/availability-sync-test/results.txt,txt
```

The injected clock and one-millisecond fixture pacing do not alter production's
180-minute schedule or 3.5-second batch pacing. Cases cover native pagination,
immutable lost-ACK replay, exact/partial/malformed acknowledgements, 413 splitting,
422 poison isolation, credential/scope/conflict/rate-limit responses, manual and
scheduled single-flight operation, history access/logout, destination pinning,
credential-change isolation and restart persistence. A locked-database context
change must hide the old history and refuse old-context observations until the
new context is selected. A backend reconnect catches up native history without
uploading early or moving the three-hour upload time.

Use a fresh build directory or `--clean-first` when verifying changed C++
headers. On this machine the Russian compiler include-prefix probe is decoded
incorrectly, so Ninja does not track C++ header dependencies; incremental
builds alone do not establish that all objects match the current headers.

This fixture is not a real Vision/PostgreSQL integration result. An authorized
durable round trip against the implemented server remains a separate rollout gate.

## Offline shared-schema validation

In an isolated Python environment install `validator-requirements.txt`, then run:

```powershell
python tools/tests/camera-availability-sync/validate-wire.py `
    --batch C:/wt/availability-journal-core-build-20261029/generated-batch.json `
    --result C:/wt/availability-wire-validation.json
```

This checks all shared fixture SHA-256 hashes, eight positive contract fixtures
and any generated batches supplied. It resolves schema references locally and
checks UUID/timestamp formats. Semantic protocol behavior is covered separately
by the HTTP/journal tests. `--dependency-dir` can select a private installed
dependency directory without modifying normal Python packages.
