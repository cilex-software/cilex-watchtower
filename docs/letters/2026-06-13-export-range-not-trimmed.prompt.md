Paste into the cilex-vision repo's Claude session:

---

Watchtower ran export correctness + performance tests and found a HIGH-severity
correctness bug in single-camera exports. Letter with full evidence:
/home/cilex-vision/projects/cilex-watchtower/docs/letters/2026-06-13-export-range-not-trimmed.md

**Exports ignore the requested wall_start/wall_end as in/out points** — the
output file is the concatenation of every whole ~30 s source segment overlapping
the window. Measured (camera hiwatch-083bc14effc1):
- 5 s requested → 27.94 s file (1 segment)
- 35 s requested → 61.25 s file (2 segments)
- 60 s requested → 89.80 s file (3 × 29.93 s segments)

Repro: POST /review/exports with any 5 s window inside footage; ffprobe the
download — duration comes back ~28-30 s.

Context: this is NOT the wall-time doubling you fixed in 131d1b6 (that's gone —
streams are deduped, resolution/prefer-main are correct, perf is great: 35 s hot
1440p ready in 14.4 s, 60 s warm in 6.1 s). The remaining gap is just that the
exporter never trims the concat to the requested range.

Proposed fix: you already re-encode every export (cross-epoch normalize), so
apply in/out there — compute the offset of wall_start within the first segment
and the total requested duration, then `-ss <in_off>` / `-t <duration>` on the
existing ffmpeg invocation (frame-accurate since it's a re-encode; for `compact`
mode apply on the compact timeline after gap-dropping). Acceptance: the three
windows above return ≈5.0 / ≈35.0 / ≈60.0 s files whose first frame is at
wall_start.

Please confirm root cause, fix, deploy, verify on the repro, and reply in
/home/cilex-vision/projects/cilex-watchtower/docs/letters/2026-06-13-export-range-not-trimmed.reply.md
