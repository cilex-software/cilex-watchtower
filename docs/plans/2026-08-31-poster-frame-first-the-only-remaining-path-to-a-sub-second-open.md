# Poster-frame-first: the only remaining path to a sub-second open, and it needs an operator decision

    Author: Claude Code CLI @ cilex-watchtower (Windows station agent, wt-sm-vnutri-01)
    Date:   2026-08-31
    Status: PROPOSAL. Not built. Needs the operator's call on the product question in
            §4, and eyes on a real window, which this booth does not have.

## §1 Why this exists

The operator's goal is "start playing video immediately, ideally like YouTube, in less
than a second." Every client-side lever has now been tested and the remaining budget is
server-side (`docs/perf/2026-08-31-win-session-creation-server-timing.md` §14):

    session creation   0.1 - 14 s   CV, cold PostgreSQL pages
    segment 0 body     ~4.0 s       6.7 MB at the measured ~11-15 Mbit/s upstream cap
    decode             ~0.22 s      ours, already fast

Segment 0 cannot be made smaller from here (§10), cannot be parallelised (§14, three
connections bought 19 %), and cannot be pre-warmed (§8). **So no arrangement of segment
fetching reaches one second while a segment is 6.7 MB.**

## §2 What YouTube actually does, which is not what we assumed

YouTube does not decode video in 200 ms either. It puts the **correct still frame** on
screen immediately and starts playback behind it. The perceived "instant" is a poster
frame; the video arrives when it arrives.

We have the pieces already:

- The app knows the target instant **before** it opens the session — that is the whole
  point of FAST OPEN (`openForDay(dateStr, targetMs)`, and `first` from
  `/review/coverage` for a plain day click).
- `PlaybackClient::fetchThumbnails` is intact and still serves the events hero player;
  its UI consumers were removed from the playback screen, not the client
  (`PlaybackScreen.qml` ~654-659).
- `FrameCache` / the filmstrip harvester already manage decoded stills.

**The arithmetic that makes it worth doing:** a keyframe is ~50-100 KB against segment
0's 6.7 MB — roughly a fortieth of the bytes, over the same link that is the bottleneck.
At the measured ~11-15 Mbit/s that is **~40-70 ms of transfer**. Even with CV's ~335 ms
per-request overhead (§12) and a warm session, a correct frame on screen inside one
second is arithmetically comfortable. It is the only path here that is.

## §3 Shape of the change

1. On open, once the target instant is known, request the still at that instant in
   parallel with the session request. Two requests, not serialised.
2. Show it as the player's poster the moment it lands, with an honest indicator that
   this is a still and video is loading.
3. When the first real frame renders, swap. `_ttffPending` already marks that point.
4. Never show a still from a different instant or camera than the one requested — the
   `[[house rule]]` about one camera's frame under another camera's name applies
   exactly. The session-ownership generation check (1.1.241) is the pattern to copy.

Cost: moderate. Risk: it touches the open path and the player's surface, which is where
tonight's correctness bug lived.

## §4 THE OPERATOR DECISION, and it is not a technical one

**Is a correct still frame at the requested instant, followed by video, an acceptable
reading of "start playing video in less than a second"?**

Arguments for: it is real footage at the real instant, it is what YouTube does, and it
is the only thing that reaches the bar without CV. A guard checking "what happened at
14:32" gets their answer in under a second instead of six.

Arguments against: it is a still, not playback. If the operator means *moving video* in
under a second, this does not deliver it and the honest answer stays "blocked on CV's
segment send rate and cold session path". A guard who expects motion and gets a frozen
frame may read it as a fault — and "honest UI states" means the still must be visibly
labelled, which slightly undercuts the illusion the feature is chasing.

I am not making this call. It changes what the product promises, not just how fast it
is.

## §5 What must NOT be done

Do not show the still without labelling it, and do not hold the still after the first
real frame is available. Both would trade a measured latency problem for an honest-UI
violation, which this repo treats as the more serious fault.

## §6 If the answer is no

Then the goal is blocked on CV until the two numbers in
`docs/letters/2026-08-31-session-creation-is-fourteen-seconds-of-your-own-serve-time.md`
move, and the honest position is ~6 s median with the client work already shipped
(12,454 -> 6,128 ms, best open 614 ms).
