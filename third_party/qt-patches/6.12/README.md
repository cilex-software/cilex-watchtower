# Internal Qt patch series — 6.12 line

Applies to qtmultimedia (and qtbase for 0002) at the revisions recorded in
`tools/build-patched-qt/REVISIONS` (SDK SBOM revisions when publicly
reachable, otherwise the closest consistent public revision — see the build
script). Root-cause record: `docs/qt-upstream/2026-07-12-qffmpegvideobuffer-
blank-swframe.md`; deterministic reproducer: `docs/qt-upstream/repro/`.

| patch | target | purpose |
|---|---|---|
| 0001-qffmpegvideobuffer-commit-swframe-on-success.patch | qtmultimedia | The root fix: commit `m_swFrame` only after `av_hwframe_transfer_data()` succeeds. A retained blank frame made every later map of the buffer skip the transfer and report fake-success MapData (planeCount>0, null planes) → SIGSEGV in the CPU converter, inside a single toImage(). Also restores legitimate retry: the next map re-attempts the transfer. |
| 0002-qvideoframe-reject-invalid-successful-mapdata.patch | qtmultimedia (core lib) | Defense-in-depth at the narrowest safe layer: `QVideoFrame::map()` validates every reported plane (non-null data, non-negative stride/size) and fails the map instead of propagating fake success. Hunk offsets in this file are illustrative (`@@ -xx`); the build script applies it fuzzily and fails loudly if context drifts. |

Regression coverage: Qt-tree unit tests would need Qt's hw-frame mocking; the
required scenarios are covered end-to-end by the standalone harness
(`docs/qt-upstream/repro/`) run against unpatched AND patched builds:
failed transfer → second map of same buffer; single toImage double-map
(texture path + CPU fallback); failure-then-successful-retry; repeated
failure without invalid successful MapData; valid conversion immediately
after a poisoned frame. See the validation matrix in the root-cause record.
