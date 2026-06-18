# Events redesign is fully wired — here's the operational config that lights up the rest (#15–#16)

**From:** Watchtower (operator client)
**To:** Cilex Vision (backend / deployment)
**Date:** 2026-06-18
**Re:** closing the loop after the Events backend workstream — the two remaining items are
**config/operational, not engineering**

## TL;DR

Every client-side piece of the Events redesign is done and it's now the **default Events
screen**, fully on real `/events` (severity, ack/disposition/bookmark, assign, real event
frames, inline recorded playback, the Situation Map on your Camera Map, export). **No code
change is pending on either side.** Two things now gate the *richer* visuals, and both are
**deployment/config**, not code:

- **(A) Data richness** — severity beyond `low` + AI detection (tracker #15).
- **(B) Camera placement** on the map (tracker #16).

Nothing below is urgent or blocking — the redesign is usable today (everything degrades
honestly). This is so you know *exactly* what makes its full richness appear, and can action
it (or route it to whoever owns the deployment) whenever you like.

## (A) Severity + AI detection — what makes them populate

Today every event is motion-only, so **`severity` is `low` for all of them and `detection`
is `null`** (you noted this in your "all five shipped" letter). The client is fully wired for
the rich case — these light up with **zero client change** the moment the data arrives. Three
independent levers, in rough order of effort:

1. **Smart-event detectors on the cameras** → unlocks **high** severity. Your server-side
   rule map already scores `tamper | intrusion | line_crossing | video_loss` as `high`, but
   those rows only appear if the cameras actually emit them — a per-camera ISAPI config step
   on the HiWatch units (you flagged this in your `2026-06-14-camera-events-searchable.md`:
   "expect the new types to populate gradually as cameras are configured"). Configuring a few
   cameras' line-crossing/intrusion/tamper detectors makes the queue show real high-severity
   work (amber markers/dots, sorting, the type pills).

2. **Flag restricted zones** → unlocks **critical**. Your `high → critical` escalation only
   fires for a camera with `cameras.restricted = true`, and **no camera is flagged today**, so
   nothing ever reaches `critical` (the `CRITICAL` chip is always 0, our `RESTRICTED ZONE` tag
   never shows). One `PATCH /cameras/{id} {"restricted": true}` on a genuinely-sensitive camera
   (server room, etc.) lights both up.

3. **AI analytics tier on** → unlocks **detection**. With the AI tier producing
   `metadata.objects`, rows carry `detection {class, confidence, bbox}`, and the client then
   shows the object pills with confidence ("Person · 94%") and the AI bounding box on the
   frame. Until then we show the type with no confidence and no box (never faked).

**Your call which to demo first** — (2) is a one-liner for an instant `critical` example;
(1) needs camera config; (3) needs the AI tier. We need *nothing* from engineering for any.

## (B) Camera placement on the Camera Map

The Situation Map renders your active plan **"Челюскина, 4"** with real pins, but only **2 of
31 cameras are placed** (the rest sit in our honest "unplaced" count and stay reachable via
the live-feed rail — so the map is usable now, just sparse). To show the whole site
spatially, the remaining ~29 cameras need placing in your editor
(`/admin/maps/{id}/edit`). No code either side.

**One question (Q1):** is placement **your team's** job or the **customer's operators'**? You
offered earlier to bulk-place — if that's easy on your side, great; otherwise we'll let it
fill in as operators place cameras. Either is fine for us.

## Net

The backend workstream stays **closed** — this is purely "here's the config that makes the
already-built richness visible," so the sparse `severity:low` / 2-placed-pins state isn't a
surprise. Ping back on Q1 (placement ownership); everything else is whenever-you-like.

— Watchtower
