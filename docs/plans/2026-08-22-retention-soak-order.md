# OPERATOR ORDER (2026-08-22, verbatim) — retention/vacuum soak, EXECUTES ON THE UBUNTU BOX

> Committed verbatim by the macOS agent so the box-side agent runs this text,
> not a paraphrase. The Mac cannot reach the box (SSH denied, no ports beyond
> :8000 — probed and recorded 2026-08-22 00:0x); its complementary
> client-observable half is already running 00:16–12:46 (see
> `docs/letters/2026-08-22-retention-soak-pilot-half.md`): segment-landing
> breadth per 5 min, storage-agent trajectory, hourly cold session-open probes
> from the CLIENT side. One T0 flag the box agent must resolve first:
> `/health/storage` reports the storage-agent unreachable since before T0
> (socket missing, 332 consecutive failures) — if the deletion loop rides that
> agent, Phase 2's clocks have not started.

---

Soak: retention deletion + vacuum unwind (commits f33f156, 17dd65f)

Run on the Ubuntu box. Total ~9h wall clock, ~1h of my attention. Deliverable: docs/perf/2026-08-22-retention-soak.md + a verdict per gate.

Phase 0 — Baseline, 15 min, BEFORE anything else

Capture, don't infer. Every "after" number needs its own "before" or the comparison is worthless.

backlog: SELECT COUNT(*) FROM video_segments WHERE start_time < now() - interval '5.5 days'
arrivals/h: COUNT(*) WHERE start_time > now() - interval '1 hour'
disk free: df -B1 /mnt/cilex-storage (bytes, not human)
load / PSI: uptime; /proc/pressure/io; /proc/pressure/memory
breaker: cilex_deletion_breaker_tripped
volume CPU: 3 samples of docker stats, 3s apart (it swings 130-590%)
cold open: build_manifest probe, 4 runs, on a camera+day NOT touched today
Known reference points from 2026-08-21 (mine, measured): backlog 39,141 | arrivals 16,332/h | load 26.62 | io PSI full avg300 18.23 retention step ~91 seg/s | cold session-open 6,533ms | S3 delete failures ~10%

Phase 1 — Sampler, arm once, runs 12h unattended

Write to /home/cilex-vision/soak-2026-08-22/ (durable — NOT $CLAUDE_JOB_DIR/tmp, that gets reaped). Two cadences, deliberately different:

every 60s -> backlog, breaker, load, io PSI, disk free bytes, segments landed in last 60s, volume-server CPU every 30m -> cold session-open probe, ROTATING camera+day each time

The rotation is load-bearing. Probing the same camera+day measures warm buffer cache and will report a fake improvement. Pick the camera+day at probe time from what still exists — retention will delete 08-16 out from under the probe overnight, so a hardcoded day starts returning empty manifests around 04:00 and looks like a latency win.

Continuously, from recorder logs: every "Deleted N segments past retention" line (count + timestamp), every "Delete failed in" line WITH ITS KEY, every "throttled" line, any "breaker".

Phase 2 — Gates. Do not sleep through these.

T+1h — is it draining at all? EXPECT backlog strictly below baseline, breaker 0. IF backlog flat/up -> the batch limit or tick cadence is the binding constraint, not throughput. Raise RECORDER_RETENTION_BATCH_LIMIT 2000->5000, restart recorder, restart the clock on this gate. IF breaker == 1 -> STOP. Read what asked for the budget. A retention-path trip means my reason-split is wrong; a pressure-path trip is a real disk problem and is louder than this soak.

T+4h — is it converging or just oscillating? EXPECT backlog monotonically down, approaching ~1-2h of arrivals (the steady state floor: rows cross the cutoff continuously, so 0 is not the target). IF backlog is sawtoothing around a fixed mean -> deletion == arrivals exactly; it is keeping up but will never drain the surplus. Raise the batch limit.

T+8h (~06:00) — overnight verdict, and the LEAST interesting one. Record it, then keep running. Do not call the soak passed here.

T+11h (~09:30) — THE REAL GATE, through the morning ramp. EXPECT backlog stays flat or falls while arrivals roughly double. IF backlog climbs during the ramp -> overnight pass was an artefact of low arrivals. This is the failure mode that matters and it is the one an overnight-only soak is designed to miss.

Phase 3 — Analysis, 30 min

Drain curve: backlog vs time, with arrivals/h overlaid. Report the NET rate (deletions minus arrivals), not the deletion rate — the deletion rate alone looks great and says nothing about whether it keeps up.

S3 failures — the question is NOT the rate, it is whether they are STUCK. Take the failed keys from hour 1 and check whether they appear again in hours 2-12. Retried-and-succeeded is fine and expected. The same key failing all night is a permanent orphan: bytes that no path will ever reclaim, with a catalog row that will never retire. Report count of keys failing >3 times.

Safety audit — the one that must be clean, not merely good:

every video_segments_history row written tonight has start_time < (deleted_at - retention). Any row failing that means we deleted footage inside the retention window. Non-negotiable.
tombstone count == sum of "Deleted N" lines. A shortfall means segments vanished without a durable record — the exact 07-15 orphan class.
MIN(start_time) in video_segments never younger than now() - retention - 24h floor.
Disk free trend. Deletion frees NOTHING until compaction. So the honest question for the vacuum unwind is: did free space stay flat or rise while 14k+/h of needles were being delete-marked at 0.15/2? If free space FELL all night, I under-tuned and garbage is outrunning reclaim -> step garbageThreshold back toward 0.08 and re-soak. Do not judge this before T+8h; compaction is lumpy.

Recording integrity — segments landed/min against the same clock last night. A drop means this work cost recording, which outranks every other result here.

Cold session-open across the night, load overlaid. Expect it to IMPROVE as the box quiets and to REGRESS during the morning ramp, and expect it to stay in seconds either way — no fix shipped for it. This is the baseline for the shared_buffers + Q1 work, nothing more. If it is fast at 03:00 and slow at 09:00 that CONFIRMS contention over cold pages and tells us which fix to do first.

Phase 4 — If a gate fails

Fix ONE variable, restart the affected service, restart the clock on that gate. Do not stack two changes into one observation window — the soak stops being able to attribute anything.

Roll back and stop if: recording drops, the safety audit in (3) is not clean, or the pressure-path breaker latches. Those three are worth more than the performance result.

Report

Every cell measured or written "not measured". No cell filled by symmetry with the row above it. Numbers I did not observe do not get written down.
