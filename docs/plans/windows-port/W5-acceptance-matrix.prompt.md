# Prompt W5 — OS/GPU acceptance matrix + ship sign-off

## Status
OPEN. Final phase; depends on W2–W4 all green. Needs the widest hardware access of any
phase (borrow/rotate machines — full parallel ownership not required).
**Qt 6.12 msvc2022_64 MANDATORY.**

## The matrix
| Axis | Points |
|---|---|
| OS | Windows 10 22H2 (final servicing) · Windows 11 (current + previous release, e.g. 24H2/23H2) |
| GPU | Intel iGPU (UHD/Iris/Arc) · NVIDIA (GTX/RTX, current driver) · AMD (RDNA, current driver) |
| Display | single 1080p · dual mixed-DPI (100 % + 150 %) · a 4K panel |
| Power | always-on · display-off during soak · sleep→resume mid-session |

Per cell (a ~45 min scripted pass, checklist in this file's Appendix when executed):
1. Install via the W4 installer (upgrade path on at least one cell).
2. Live wall @ cap: `[WT-DEC]` = d3d11 hardware on ALL decoding tiles; `WT_HW_ONLY=1`
   stays green (patent/perf invariant).
3. Playback loop: heavy-day open (TTFF <1 s), scrub storm (coalescing — no dead-video
   tail >2.5 s healthy), far-seek, roll-over at window end.
4. Export matrix: HIGH (recent), STD-vs-policy behavior, compression/burn-in (ffmpeg.exe),
   drawer Esc/cancel.
5. 30 min `WT_SMOOTHTEST` heartbeat: max GUI gap <2 s; RSS plateau sane for the tile count.
6. Resume-from-sleep: wall reconnects, playback session recovers or fails HONESTLY
   (no zombie UI).

## Task
1. Execute the matrix; one results row per cell in
   `docs/perf/2026-…-windows-acceptance.md` (pass/fail + `[WT-DEC]` evidence + RSS + notes).
2. Every failure: dated finding doc, triaged fix-now (small) vs follow-up prompt
   (structural) — the Linux discipline.
3. **16-tile wall perf check** on the strongest GPU cell vs the Linux reference numbers
   (decode cap semantics identical; snapshot tiles at sourceSize — the memory-sweep
   invariants hold cross-platform).
4. Ship sign-off: a final section in the plan doc — versions (app, Qt 6.12.x, GStreamer,
   FFmpeg, driver set), known limitations, the signing decision, and the operator's GO.

## Verify
Matrix green (or consciously-waived cells recorded with rationale), sign-off section
merged, and the W1 CI still producing installable artifacts at the signed-off versions.

## Gotchas
- Driver variance IS the point of this phase — record exact driver versions in every row;
  a cell that fails on driver N but passes on N+1 is a documented support-floor, not a fix.
- Windows 10 EOL horizon: note supported-until dates in the sign-off (W10 22H2 servicing
  status at execution time) so ops knows the support window they're buying.
- Auto-commit + push results + sign-off, per the working agreement.
