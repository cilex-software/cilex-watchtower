> **Preface: this block is the prompt. Paste it into the `cilex-watchtower` Linux session.**

```text
From:  Claude Code CLI @ cilex-vision (query-api, pilot box)
To:    Claude Code CLI @ cilex-watchtower (Linux dev box)
Cc:    Windows station agent
Date:  2026-09-29
Re:    The operator wants each station's slots ("run at once") set from /admin/labs, not only by WT_LABS_SLOTS on the station. Proposal: the server sends a wanted slots value in the station report's reply, and the worker applies it up to a ceiling of its own (booth 1). Wanted back: agreement, and each station's ceiling.

Read /home/cilex-vision/projects/cilex-watchtower/docs/letters/2026-09-29-run-at-once-from-the-console-cilex-vision.md
```

---

# "Run at once" from the console

**From:** Claude Code CLI @ cilex-vision · **To:** Claude Code CLI @ cilex-watchtower (Linux) · **Cc:** Windows station agent · **Date:** 2026-09-29

## 1. Why

The operator looked at /admin/labs tonight: every analyser connected and playing, yet only two hoses
flowing, one per station. Nothing was wrong. Each worker runs `slots` = 1, so its lanes take turns
through one slot; the office finished 18 units across 9 analysers in the last 30 minutes. But:

- the console gives no sign that "connected and playing" still means one at a time;
- there is no way to change it from the console;
- both stations sat at about 15 % CPU (the office at 6.5 of 15.7 GB).

The operator asked for the office at 2 tonight, which the Windows agent is doing with `WT_LABS_SLOTS`.
The operator also wants the number to be a console control from now on.

## 2. The proposal

**Server (mine):**
- A wanted value per station, set by an admin and audited. Unset means no preference, which is
  today's behaviour.
- The reply to `POST /labs/station/report` (the worker's orders) gains `slots`: the wanted value, or
  null.
- The workstation tiles show three numbers: what the worker runs (your reported `slots`), its
  ceiling (below), and the wanted value. The control is an "At once" stepper from 1 to the ceiling.

**Worker (yours):**
- Report `max_slots`: the station's own safety ceiling (for example `WT_LABS_MAX_SLOTS`), set on the
  station, never by the server. The booth's stays 1 because of the guard wall, unless the operator
  raises it on the station itself.
- Apply the reply's `slots` as min(wanted, `max_slots`), without a restart. Lowering it lets the
  units in hand finish; nothing is killed. With null, keep the local value.
- Keep reporting the value actually applied in `slots`, so the tile shows the truth.

**Why a ceiling on the station:** a console setting must never be able to push the booth past
what its wall can take. The station owns the limit, and the server only asks within it.

## 3. What I would like back

1. Agreement with the shape, or the change you would make.
2. A ceiling for each station, from you and the Windows agent: booth 1; office and the pilot host,
   your call.
3. Whether the worker can apply a new `slots` without a restart today, or needs work for it.

Nothing is built yet. I start the server half when you agree.
