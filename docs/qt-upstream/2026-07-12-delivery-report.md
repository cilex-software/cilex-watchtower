# Delivery report — Qt FFmpeg-backend crash owned end-to-end, Watchtower on patched binaries

_2026-07-12. Completes the ownership directive: diagnosis, Qt patch series,
application hardening, from-source patched-Qt build, packaging, runtime proof,
and the validation matrix. Watchtower runs against OUR patched Qt binaries, not
merely the application guard._

## 1. Root cause (proven, not inferred)

`QFFmpegVideoBuffer::map()` (Qt 6.12) commits `m_swFrame` **before**
`av_hwframe_transfer_data()`. On transfer failure the blank frame is retained;
every later `map()` of that buffer skips the transfer and returns a *successful*
MapData with `planeCount > 0` and null plane pointers. A **single** `toImage()`
crashes by itself — `qImageFromVideoFrame` maps once for the RHI texture path
(fails gracefully) then again for the CPU-converter fallback (fake success →
walks the null planes) → SIGSEGV. Full analysis + field backtraces:
`2026-07-12-qffmpegvideobuffer-blank-swframe.md`.

## 2. Deliverables

| # | deliverable | location |
|---|---|---|
| 1 | Application cleanup (guard checks every plane; repro hook removed from release; comments corrected; storm damper = load-only) | `src/models/FrameCache.{h,cpp}` (commits 53543d6, e47a5c8) |
| 2 | Internal Qt patch series (5 patches) | `third_party/qt-patches/6.12/0001..0005*.patch` + README |
| 3 | Reproducible build scripts + exact revisions | `tools/build-patched-qt/` (`build.sh`, `make-dev-sysroot.sh`, `apply-anchored.py`, `REVISIONS`) |
| 4 | Patched runtime artifacts + checksums + BuildIDs | `~/Qt/6.12.0-patched-beta1/` ; `ARTIFACTS.sha256`, `BUILDIDS.txt` |
| 5 | Standalone pre/post reproducer + results | `docs/qt-upstream/repro/` ; §4 below |
| 6 | Validation matrix + raw logs | `tools/build-patched-qt/VALIDATION.md` ; `~/qtpatch-work/validation/` |
| 7 | Deploy / rollback | §6 below |
| 8 | Adjacent defects proven + separate patches | 0003 (RHI frame balance), 0004 (vaSyncSurface), 0005 (corrupt flags) |

### Patch series

- **0001** `qffmpegvideobuffer` — transactional: commit `m_swFrame` only after a
  successful transfer. The root fix; also restores transfer retryability.
- **0002** `qvideoframe::map` — reject a "successful" map whose planes are
  null/negative-stride/negative-size (defense-in-depth at the narrowest layer,
  all planes checked).
- **0003** `qvideoframeconverter` — balance `beginOffscreenFrame()` with
  `endOffscreenFrame()` on the createTextures/updateTextures fallbacks (the
  poisoned-frame path hit exactly this; left the shared RHI stuck recording).
- **0004** `qffmpeghwaccel_vaapi` — check `vaSyncSurface()` status before import
  (was ignored right under Qt's own `### Check` comment).
- **0005** `qffmpegstreamdecoder` — surface `AV_FRAME_FLAG_CORRUPT` /
  `decode_error_flags` (log; opt-in drop via `QT_FFMPEG_DROP_CORRUPT_FRAMES`).

## 3. Build provenance

One consistent public revision across the runtime overlay (SDK SBOM revisions
are Coin-internal / not publicly reachable — verified; recorded in-script):

| module | revision (v6.12.0-beta1) |
|---|---|
| qtbase | 313846bb49852402b386a37b8062100e6b801135 |
| qtshadertools | 78fcb10241ba10e411b44addcccb7df236f8fe14 |
| qtdeclarative | b9050de3339da6227fbc286787f6599869a3ced5 |
| qtwayland | 08db0f34af2e0fa942398942f62ca7dba11ecfec |
| qtmultimedia | 552f05856a44b0f19e175975a171f628d9a3a032 |

Toolchain: gcc 13.3.0 / GNU ld 2.42. FFmpeg headers n7.1.1
(db69d06e), runtime libs SDK-shipped (libavcodec 61.19.101 — byte-identical
version to the SDK). libva headers 2.20.0 + system runtime. Built root-free via
`make-dev-sysroot.sh` (apt-get download + dpkg -x; no sudo). The app links only
public Qt ABI (0 private-header includes), so the SDK-built `watchtower` runs on
this overlay unchanged.

Patched artifact BuildIDs:
- `libQt6Multimedia.so.6.12.0` — `afa36e2e7a624e5a0bb6d9ae948c3e1931fd2917`
- `plugins/multimedia/libffmpegmediaplugin.so` — `dc12cddb807cdf463ca57cb69069e49deffcdc5f`
- `libQt6Core.so.6.12.0` — `e068399e28c3fd02ff97d7e195f651ca07d6a542`
- `libQt6Qml.so.6.12.0` — `e8b6ade2b42bfe8471df0151d60ff732874a286c`

(Full 143-artifact SHA-256 manifest: `tools/build-patched-qt/ARTIFACTS.sha256`.)

## 4. The decisive proof — reproducer, unpatched vs patched (real Wayland/VA-API)

One forced `av_hwframe_transfer_data` failure via the LD_PRELOAD seam, same clip,
same platform, only the Qt prefix differs:

| build | result |
|---|---|
| **UNPATCHED SDK** | `[XFER] call#60 FORCED_FAIL` → `Cannot map a video frame in ReadOnly mode!` → **SIGSEGV (exit 139)** |
| **PATCHED overlay** | `[XFER] call#60 FORCED_FAIL` → `call#61 first REAL transfer after forced window ret=0` → **exit 0, `nullImages=0 fakeSuccessProbes=0 -> CLEAN`** |

The patched build not only doesn't crash — it **re-attempts the transfer on the
next map and succeeds**, i.e. a transient failure is no longer sticky. Logs:
`~/qtpatch-work/validation/repro-{unpatched,patched}-wl.log`.

## 5. Runtime evidence (Watchtower actually loads the patched artifacts)

`runtime-evidence.sh` against the live process (`WT_QT_PREFIX=<patched> ./run.sh`):
all four tracked libraries' BuildIDs **MATCH** the patched manifest →
`=> RUNNING ON PATCHED ARTIFACTS`; the FFmpeg plugin (`dc12cddb`) is loaded, 0
unresolved deps, HW decode active. A compile is not trusted as proof — this reads
`/proc/<pid>/maps`. (`runtime-evidence.txt`.)

## 6. Deploy / rollback

- **Deploy:** `WT_QT_PREFIX=~/Qt/6.12.0-patched-beta1 ./run.sh` — the prefix is
  self-contained (patched Qt + bundled FFmpeg runtime + FFmpegStub dlopen shims).
  For a persistent switch, set `WT_QT_PREFIX` in the environment/launcher.
- **Rollback:** plain `./run.sh` (SDK prefix, untouched on disk). Instant, no
  rebuild. The application guard remains in the binary either way, so even on the
  unpatched SDK the crash is intercepted — the patched Qt removes the defect at
  the source; the guard is defense-in-depth.

## 7. Sanitizers

App built `-fsanitize=address,undefined` (`buildasan/`), run through a 40-failure
forced-burst in frame mode: **0 ASan/UBSan findings**, every forced failure caught
by the guard. (`~/qtpatch-work/validation/wt-asan.log`.) The null-plane deref
itself lives in Qt's converter and is characterized by the deterministic
reproducer above.

## 8. Reconciliation with the 07-10 UAF postmortem

07-10 removed one *trigger* (queued raw frames converted after decoder death);
this work removes the *amplifier* that turned any transfer failure — stale
lifetime, corrupt input, VA sync failure — into a deterministic crash. Both
stand; see the root-cause record's reconciliation section.
