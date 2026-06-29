# Extended Live-screen guard-usage soak tooling

Emulates a security guard's normal usage over a long run, measuring RSS/CPU, attributing spikes to actions,
and recovering from crashes. Used 2026-06-30 (overnight, until 12:00).

- **In-app driver:** `WT_GUARD_SOAK=1` (env; see `qml/Main.qml`) — periods on Live (~15-20 min,
  `WT_GUARD_LIVE_MS`) interspersed with human-paced click-throughs of Events (triage/situation-map/timeline),
  Groups, Views, Health, and the playback wall, then back to Live. Logs `[GUARD] t=<epoch> step=<name>`.
- **guard_sampler.py** `<out.csv> <secs>` — RSS+CPU every 2s, epoch-stamped, re-resolves the pid (survives
  crash/relaunch; logs rss=0 in the gap).
- **guard_supervisor.sh** — launches watchtower under WT_GUARD_SOAK until 12:00, runs the sampler, and on any
  crash/kill records the death cause + the [GUARD] actions that led to it (incidents.log), then relaunches.
- **guard_analyze.py** — mean/stdev (overall + per-action) of RSS & CPU, top spikes (+ action), crash count,
  and a CPU/RSS graph (`guard_soak.png`) with action regions + crash markers.

Outputs land in `/tmp/guard_test/` (samples.csv, app.log, incidents.log, supervisor.log, guard_soak.png).
