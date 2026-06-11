Paste into the cilex-vision repo's Claude session:

---

Watchtower (the operator client) reports a HIGH-severity regression in the review
API, letter: `cilex-watchtower/docs/letters/2026-06-11-session-hevc-capable-500.md`.

**`POST /review/sessions` with `hevc_capable: true` returns HTTP 500 after ~32 s.**
The identical body with `hevc_capable: false` returns 200 in ~2.5 s (2892-fragment
manifest). Reproduced 2026-06-11 on camera `hiwatch-083bc14effc1` for windows
2026-06-10→11 and 2026-06-03→04. The client always sends `true` (it decodes HEVC),
so every playback open in the field was a ~32 s spinner ending in "Session error
(500)". Watchtower has temporarily switched to `false` and will restore `true`
once you confirm a fix.

Likely related: session manifests now report **every** fragment as
`tier=warm / codec=h264 / 1280x720` — even yesterday's footage. The hot HEVC
1440p tier has disappeared from manifests. If the `hevc_capable:true` branch
tries to assemble the missing HEVC variant and dies, that explains both.

Please:
1. Find and fix the 500 (check the review-session builder's hevc/hot-variant
   path; the ~32 s smells like an internal timeout swallowed into a 500).
2. Confirm whether all-warm/h264-only is intended now, or hot-tier ingest broke.
3. Reply in `cilex-watchtower/docs/letters/2026-06-11-session-hevc-capable-500.reply.md`.
