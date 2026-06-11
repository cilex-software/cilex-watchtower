Paste into the cilex-vision repo's Claude session:

---

Watchtower measured wall-playback (mosaic) seek latency end-to-end and the
compositor's cold render dominates everything. Letter with full numbers:
`cilex-watchtower/docs/letters/2026-06-11-mosaic-cold-render-latency.md`.

Headline measurements (16-cam 4×4 day session, 6 s segments, 2026-06-11):
- Cold segment at playlist head: ~15 s (curl); ~44–54 s to first frames in the client.
- Seek to a cold region (+10 min / +1 h): the landed-on segment takes ~25–35 s.
- Adjacent next segment: another ~17 s ⇒ the compositor renders ~0.36× realtime,
  so playback after a cold seek stalls every segment until it catches up.
- Already-rendered regions serve in 50–130 ms and resume in ~0.3 s — perfect.

The client has done what it can (watchdog no longer false-fails; its proxy answers
each request chain under GStreamer's hard ~15 s per-request timeout and the
player's fragment-retry loop paces the wait). The remaining 25–55 s is render time.

Asks (in priority order — pick what fits the architecture):
1. **Prewarm at the seek target**: when a cold `seg/N` is requested, start/move the
   render head to N immediately and continue forward from there.
2. **Faster-than-realtime rendering** for the active window — target ≥1.5×
   sustained (parallel per-cell decode, ultrafast encode preset, and/or drop the
   mosaic to 12–15 fps — cells are 480×270, it's a review grid).
3. **Render-ahead horizon** past the last-requested segment so steady playback
   never starves once started.
4. **Start rendering at `wall_start` on session create**, not on the first GET.

Reply in `cilex-watchtower/docs/letters/2026-06-11-mosaic-cold-render-latency.reply.md`.
