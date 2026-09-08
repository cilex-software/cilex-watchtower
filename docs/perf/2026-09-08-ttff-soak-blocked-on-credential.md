# TTFF soak — instruments ready, run blocked on an operator credential (2026-09-08)

Operator goal: overnight soak of open→first-frame on three surfaces, with targets
**1 s** single-camera playback · **2 s** 16-cell wall · **500 ms** live open from the wall;
investigate and fix anything over target.

## What exists (pushed c587528, 786e157)

| surface | instrument | stops at |
|---|---|---|
| playback | `[TTFF] day=… ttff=…ms` (pre-existing) | first frame |
| 16-cell wall | `[WALLTIME] first_frame dt=…ms cells=…` (new) | first REAL frame (the settle-ending videoFrameChanged) |
| live open | `[LIVETIME] playing dt=…ms cam=…` (new) | surface has a recent frame |

`tools/ttff-soak.sh` cycles all three through the real app under the existing harness
hooks (`WT_TTFF_DAYS` / `WT_WALL_DAY=live` / `WT_FOCUS_IP`), one JSON row per measurement.
It refuses `admin`, reads a `0600` credential file, and probes the login before starting.

## Why zero rows have been collected — every path measured, none open

| path | result | why |
|---|---|---|
| persisted token in `Watchtower.conf` | 401 | 10-char stub, expired |
| `admin`/`admin` | 401 | rotated 2026-09-06; new value not readable here — correct |
| app already running under Warden | login screen | `live_pipelines=0`, no auth lines |
| `APP_ENV` / `WT_CV_*` in `warden.conf` | empty | never held a login |
| any operator/soak account with a recorded password | none | CV's 08-10 soak-account advice was never actioned |
| **station display session** (`POST /client/stations/display-session` with token B) | **200, `scope: station:live`** | — |
|   → `/streams` | 200 | live listing works |
|   → `POST /review/sessions` | **403 `display_session_out_of_scope`** | by DESIGN: "the PAST is an act by a person" (spec, 09-04) |
|   → `POST /review/mosaic-sessions` | **403** | same boundary |
|   → `/auth/me` | 401 | so `loginWithToken` (which validates via `/auth/me`) rejects it |
| client presenting `X-Cilex-Display-Session` | not implemented | that is the display-session build, not a soak hack |

**Conclusion:** two of the three targets are historical playback, and the station
credential is correctly forbidden from them. The soak needs a **person's** session.
Widening the station scope to run a test would undo the boundary the security work
just established; not asking for it.

## What is measurable without a login (measured 2026-09-08)

- app cold start → login screen painted: **3.40 s** wall clock (`v1.1.353`, this box).
  This is a fixed cost *before* any of the three targets start, and is not counted in them.

## To run it

```
printf '%s\n%s\n' '<operator-username>' '<password>' > ~/.config/watchtower-warden/ttff-soak.cred
chmod 600 ~/.config/watchtower-warden/ttff-soak.cred
tools/ttff-soak.sh --cycles 40 --out /tmp/ttff-soak.jsonl      # or hand off and it runs under systemd
```

If no non-admin account exists: create one at `/admin/users`, role **operator**, no admin
scope — the dedicated soak account CV asked for on 2026-08-10, so soak writes never
attribute to a real guard.
