# Labs tracking — stage 2 (product integration) submission

Participant: Qwen. Branch: `benchmark/qwen-labs-tracking`.
Original-stage implementation commit: **`9ee195abdbd4283d7fef38c0dea12c251f86815a`**
(pushed to `origin/benchmark/qwen-labs-tracking`; record in
`docs/benchmarks/labs-tracking/SUBMISSION.md`, untouched by this stage).
Integration starting revision: the same `9ee195a`. This stage works forward from
it; nothing was amended, reset or squashed.

The stage-2 commit is identified in the conversation's final response, not here,
because this file is part of that commit.

## 1. What changed on top of the original submission

| File | Kind | Purpose |
|---|---|---|
| `tools/labs/temporal_tracks_clip.py` | new | The helper process the app drives: local recording → repo decode pass → repo foreground analyser → stage-1 engine → JSON line protocol |
| `src/models/LabsTrackJob.{h,cpp}` | new | QProcess controller: launch, progress, cancel, child cleanup, state machine |
| `src/models/LabsTrackRuns.{h,cpp}` | new | Local run-evidence store + local recording listing (the product's export directory) |
| `src/models/LabsVerify.{h,cpp}` | new | In-app runner for the repository's real check commands, streaming their output |
| `qml/LabsTracking.qml` | new | Labs → Temporal tracks: input, run, review beside the recording, saved runs |
| `qml/LabsVerify.qml` | new | Labs → Verification: groups, live log, integration self-checks, failure control |
| `qml/LabsScreen.qml` | edit | Two new segments in the existing view switch + the two views + `WT_LABS_VIEW=tracks|verify` |
| `src/main.cpp` | edit | Three context properties (`LabsTrack`, `LabsTrackRuns`, `Verify`) and two dev hooks (`WT_LABS_TRACK_TEST`, `WT_LABS_VERIFY_TEST`) |
| `CMakeLists.txt` | edit | New sources and QML files |
| `i18n/watchtower_en.ts`, `i18n/watchtower_ru.ts` | edit | `update_translations` after adding 96 new `qsTr` strings |
| `tools/tests/labs-temporal-tracks-clip.py` | new | 27 hermetic checks of the helper process's protocol |
| `tools/tests/fixtures/temporal_tracks/mock_cv_server.py` | new | Dev-only mock backend so the sign-in gate lifts on a box with no reachable backend |

Protected things stayed protected: `tools/tests/labs-worker.py`, the two
self-tests and every vendored `labs_*.py` are unmodified; `run_worker.py`'s
default registry and the plugin defaults are untouched; B6 remains the default
track linker; no analyser was enabled, replaced or started; no Warden, station,
server or deployment change; nothing writes to the backend.

## 2. Build and launch (exact)

```sh
cd <checkout>
git config core.hooksPath tools/git-hooks        # once per clone, repo convention

# primary toolchain (Qt 6.12)
cmake --preset default && cmake --build build
# fallback used for headless/offscreen verification (Qt 6.8.3 LTS)
cmake --preset qt68   && cmake --build build68

./run.sh                                          # the repository's launcher
```

Isolated development instance (used for every run in this report; the operator's
real settings, camera store and run evidence are untouched):

```sh
XDG_CONFIG_HOME=/tmp/wt-iso/config XDG_DATA_HOME=/tmp/wt-iso/data \
XDG_CACHE_HOME=/tmp/wt-iso/cache WT_NO_SCHEME_REG=1 WT_RESTORE_OFF=1 ./run.sh
```

`WT_NO_SCHEME_REG=1` is mandatory for any test run (the app otherwise repoints
the operator's `cilex://` handler at the test binary); `WT_RESTORE_OFF=1` stops
the persisted shell state from overriding `WT_SECTION`/`WT_LABS_VIEW`.
Headless screenshots use the documented hook on the 6.8.3 build
(`QT_QPA_PLATFORM=offscreen WT_SCREENSHOT=… WT_SCREENSHOT_MS=…`), because Qt
6.12's offscreen QPA is unstable; real-session screenshots use the 6.12 build on
Wayland.

On a box with no reachable backend (this one: the local cilex-vision Query API
refuses the dev-default credentials), the sign-in gate can be lifted for UI
verification only with the dev fixture:

```sh
python3 tools/tests/fixtures/temporal_tracks/mock_cv_server.py --port 8123 &
WT_CV_URL=http://127.0.0.1:8123 WT_CV_AUTOLOGIN=1 ./run.sh
```

The fixture binds 127.0.0.1, mints an unsigned token whose payload it prints,
answers five endpoints and 404s everything else; the product then shows its own
honest "the server refused" states for the Labs server views. No product code
knows it exists.

## 3. Operator walkthrough (Watchtower UI only)

1. Sign in as usual. Open **Labs** in the nav rail.
2. The view switch now has four segments: *Statistics*, *Analyser Settings*,
   **Temporal tracks**, **Verification**.
3. **Temporal tracks**:
   - *Recording* lists the product's own export directory
     (`Artifacts.exportDir`, i.e. `~/Videos/Watchtower` by default) newest first;
     *Choose file…* opens a file dialog for any other local recording. Name,
     size and modification time come from the filesystem; duration, resolution,
     codec and frame rate are probed from the container when a run starts.
   - *Camera* and *Footage starts* are optional and empty by default. The export
     file name's camera text is shown as a label only; the timestamp in an
     export name is the SAVE time (`Artifacts::newExportPath` stamps
     `currentDateTime()`), so it is never used as the footage clock. With no
     origin entered, every time in the run is **clip-relative** and the banner
     says so; entering an ISO wall clock switches the basis and the document
     carries both.
   - *Window s* bounds the analysed span (default 60). *Run tracking* starts the
     child process; the status row shows frame/detection/live-track progress and
     a progress bar; *Cancel* terminates it and the run is reported
     **cancelled**, with whatever partial evidence it had.
   - On completion the banner distinguishes **Completed** (with counts),
     **Completed with no detections**, **Cancelled**, **Failed** (with the
     helper's message) and **Missing prerequisite** (no tools tree / no
     `python3`). The track list shows id, observation count, span, close reason
     and an **UNCERTAIN** badge where `ambiguous_batches > 0`. Selecting a track
     seeks the recording to that track's first observation; the player, slider
     and pause/play are the product's QtMultimedia path.
   - Boxes are drawn only for the instants an accepted observation covers
     (solid amber, labelled with the track id). *interpolate* adds a dashed grey
     outline between observations, labelled "dashed outlines are INTERPOLATED,
     not evidence", off by default. *show every track* toggles between the
     selected track and all tracks. The detail pane lists the episode's
     evidence and its path samples with their ACTUAL observation timestamps.
   - Completed runs are saved automatically and *Saved runs* lists, reopens and
     (in the store) removes them; a reopened run is labelled with its saved run
     id and never presented as the current run.
4. **Verification**: each row runs a real command as a child process and streams
   its output into the log on the right — the contract suite (full and
   no-workload), `tools/tests/labs-worker.py`, both analyser self-tests, the
   streaming workload, the integration self-checks and the failure control.
   *Run all (no workload)* queues the first four plus integration. A row reads
   NOT RUN until it has run; green/red come from the child's exit status; the
   log shows the suites' own PASS/FAIL lines. *Save evidence* writes the group
   outcomes and the log tail into the same local store.

## 4. What was verified, with real results

Environment: this development box (20 CPUs, shared, load average 15–22 during
these runs), Ubuntu 24.04, Python 3.12.3, numpy 2.4.4 (user site-packages),
opencv-python 4.13.0, system ffmpeg 6.1.1, Qt 6.12.0-patched-beta1 (primary)
and Qt 6.8.3 (offscreen verification). Timings are diagnostic, not controlled.

### 4.1 Repository checks (terminal, current tree)

| Command | Exit | Result |
|---|---:|---|
| `python3 tools/tests/labs-temporal-tracks.py` | 0 | `all passed (613 checks)`, 11.9 s |
| `python3 tools/tests/labs-temporal-tracks-clip.py` | 0 | `all passed (28 checks)`, 10.5 s |
| `python3 tools/tests/labs-worker.py` | 0 | `all passed`, 436 assertions, 28.9 s |
| `python3 tools/labs/selftest_shape_observations.py` | 0 | `79/79 checks passed`, `all good` |
| `python3 tools/labs/selftest_object_profile.py` | 0 | `40/40 checks passed`, `all good` |
| `git diff --check` | 0 | clean |

### 4.2 Real-footage analysis through the product

Input: `~/Videos/Watchtower/HiWatch_DS-I456Z_B___192.168.1.106__20260619_202134.mp4`
—an existing Watchtower export on this box, read through the product's own
export directory. sha256 `61df28c49cd84499a27268ae4cd5a3a147aeb1e0287a86578013618c295b7be2`,
10 928 474 B, 2560×1440 h264, 15.18 fps, 25.75 s.

Run through `LabsTrackJob` inside Watchtower (headless 6.8.3 and Wayland 6.12
alike): **completed, 43 tracks from 757 detections, 167 ambiguous assignments,
coverage 100 %, ~15 s**, clip-relative basis, engine revision recorded from the
build (`9ee195ab-dirty` while the tree carried uncommitted stage-2 work).
Four independent in-app runs of this same clip produced identical counts
(run ids `dfd229ce…`, `2e48510b…`, `d4c427c3…`, `78fa3dd5…`, `1e5507d0…`,
`67581aff…` in the evidence store), which is the in-product determinism check.
Three of the 43 tracks carry `UNCERTAIN` badges from real `ambiguous_batches`;
the detail pane shows e.g. t00000002 with 8 observations, 5 ambiguous batches,
span 0–461 ms and path samples at 0/66/132/198/264/329/395/461 ms — actual
observation times, not an equal spacing.

Other exports were analysed the same way; two of the nine are static scenes and
correctly complete with **no detections** (the UI says so rather than showing an
empty track list as a pass).

### 4.3 Synthetic verification (labelled, never footage)

The integration self-checks generate a 6 s 320×240 clip locally with ffmpeg
(`overlay` of a white rectangle moving across black — `drawbox`'s coordinates
are not per-frame on ffmpeg 6.1, measured), sha256
`77d8f187906fad98…`, and run the real engine over it: **2 tracks from 84
detections**, observations monotonic per track and inside the clip, repeat run
identical under a distinct run id, cancellation reported as cancelled both at
spawn and mid-decode of a real 1440p recording, and the evidence document saved,
listed and reopened byte-identical. Every surface that shows this input labels
it SYNTHETIC; it never appears as a camera finding and no accuracy claim is
made from it.

### 4.4 In-app verification (Labs → Verification)

Screenshot evidence (local paths; `build/shots/` is gitignored, so nothing here is
committed and no footage or run artifact enters the repository):

| File | Shows |
|---|---|
| `build/shots/F2-wayland.png` | Primary Qt 6.12 build on a real Wayland session: the export's picture rendered under observed boxes at clip-relative 0 ms, track list with UNCERTAIN badges, selected-track evidence with actual path-sample timestamps, run identity with sha256 and 100 % coverage |
| `build/shots/F-t-run.png` | The same completed run headless (Qt 6.8.3, offscreen): 43 tracks / 757 detections / 167 ambiguous |
| `build/shots/F2-t-saved.png` | The saved-runs pane with the reuse note for the selected recording |
| `build/shots/F-v-all.png` | *Run all* mid-flight: the suites' own PASS lines streaming (contract 590→613 as the suite grew, worker 436, self-tests 79/40) |
| `build/shots/F-v-int.png` | Integration self-checks all green, including both cancellation checks and the evidence round-trip |
| `build/shots/F-v-fail.png` | The failure control: a nonexistent input shown as **Failed** with the helper's message |
| `build/shots/F-v-workload.png` | The streaming workload group run in-app: 9.394 s, 10 671 batches/s, every invariant held |
| `build/shots/verify-int4.png` | A genuine in-app FAIL (the cancellation race before it was fixed), kept as proof the view can display failure |
| `build/shots/base-labs.png` | With no backend and no credential the app stops at its normal sign-in screen — unchanged product behaviour |

The workload group runs the declared section-13 workload inside the app and
reports its measured elapsed time, throughput and peak RSS in the log; on this
shared host it is diagnostic. In-app it measured 9.394 s for both streams
(10 671 batches/s, 86 012 detections/s) with every invariant held; its
"additional peak RSS" reads 0.0 MiB because the app process has already imported
NumPy and OpenCV, so the post-import baseline exceeds the workload's own
footprint — the meaningful figure is the standalone fresh-process measurement in
stage 1's SUBMISSION.md (3.30 MiB additional, 7.22 s median). A group left NOT
RUN is neither a pass nor a zero.

### 4.5 Failure controls

- The *Failure control* group (4.4) proves the interface displays a real failure.
- The integration group's two cancellation checks prove cancellation is visible
  and distinct from completion.
- `tools/tests/labs-temporal-tracks-clip.py` pins the helper's refusal paths:
  missing input → `input_missing` exit 3; out-of-range engine config →
  `invalid_config`; non-JSON config → `invalid_input`; unknown subcommand →
  exit 2; SIGTERM → status `cancelled`, exit 130; a bounded window reports its
  coverage and a "not analysed" problem; 1500 fps input produces
  `dropped_same_ms > 0` and those frames feed no detection.
- The stage-1 mutation harness (58 planted defects, all killed) still passes
  against the unchanged engine.

## 5. Limitations and unverified acceptance items

- **Backend-sourced playback was not exercised.** This box's cilex-vision Query
  API refuses the dev-default credentials and no operator credential was
  supplied, so review sessions, HLS playback and server Labs findings were never
  opened. The verified recording path is the product's own local export
  directory plus an explicit file choice; that is what the assignment asked the
  workflow to support without a backend change. Real-footage analysis IS
  verified (4.2); real-footage *playback through the backend* is NOT.
- **Offscreen screenshots show a black picture area.** Qt's offscreen QPA does
  not render decoded video frames; the Wayland screenshot (`wl-tracks3.png`) is
  the evidence that the recording renders under the overlay on a real session.
- **Analysis latency on high-resolution clips.** The analyser's prime mode
  buffers the window before the first scored frame, so a 1440p clip shows no
  progress for its first seconds and cancellation during priming falls back to
  the controller's 3 s grace kill (both paths report *cancelled*, verified).
- **numpy/cv2 come from the user's site-packages.** A launch environment with a
  different `HOME` (as in my first isolated attempt) has no numpy and the run
  fails with a visible `ModuleNotFoundError` rather than silently. Documented
  here because it is a real deployment consideration for the helper process.
- **Translations**: 96 new strings were extracted; Russian translations for them
  are unfinished (11 came across by the same-text heuristic) and fall back to
  English, exactly as the repository's i18n flow behaves for any new string.
- **Windows and macOS were not built or run** for this stage; nothing here is
  platform-conditional except the ffmpeg/`python3` lookup, which reports
  *missing prerequisite* when absent.
- The mock backend is a test fixture for the sign-in gate only. With it absent
  and no credential, the app stops at its normal sign-in screen — unchanged
  product behaviour.
