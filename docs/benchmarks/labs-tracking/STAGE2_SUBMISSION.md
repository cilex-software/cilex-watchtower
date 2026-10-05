# Cilex Watchtower - Labs Temporal Tracking Stage 2 Integration Report

**Participant:** Gemini  
**Checkout:** `/home/cilex-vision/projects/cilex-watchtower-gemini`  
**Branch:** `benchmark/gemini-labs-tracking`  
**Base Revision:** `f442cb5b7092406d3f026d54d8791d5afaec4586`  
**Stage 1 Submission Commit:** `fd90cd431980af27ea99fa43d7076e5dc3d77d4e`  
**Date:** 2026-10-05  

---

## 1. Summary of Changes & Architecture

In Stage 2, the offline temporal tracking engine and adapter developed during Stage 1 were integrated directly into Cilex Watchtower's user interface within the **Labs** screen. The integration strictly adheres to product boundaries, operator workflows, and isolated launch conventions.

### File Modifications & Additions

1. **`src/models/LabsTrackingController.h` & `src/models/LabsTrackingController.cpp`**:
   - Registered QML C++ controller (`LabsTrackingController`) exposed as a `QML_ELEMENT`.
   - Asynchronously coordinates helper processes (`QProcess`) to stream structured JSON events without blocking the main GUI thread.
   - Manages state machine (`idle`, `running`, `completed`, `failed`, `cancelled`), progress (0.0–1.0), and cancellation.
   - Exposes reactive properties for test cases, performance summaries, detected tracks, selected track trajectories, recording status, and local evidence management.
   - Implements local evidence save and load functionality (`saveEvidence`, `loadEvidence`, `refreshSavedRuns`) writing formatted JSON snapshots to `~/.local/share/Cilex Vision/Watchtower/labs_tracking_evidence`.

2. **`qml/LabsTracking.qml`**:
   - Custom QML interface embedded in `LabsScreen.qml`, organized into three sub-views:
     - **In-App Verification**: Interactive test runner for contract test cases, regression suites, resource workload, and deliberate failure control. Features live progress, summary stat cards, and an evidence export button.
     - **Recording Analysis**: Manual recording analysis interface with path input, live MOG2 background subtraction + tracker progress, honest `NOT VERIFIED` reporting on missing footage, track selection sidebar, interactive `Canvas` overlay for 2D trajectories and bounding boxes, and QtMultimedia video playback controls.
     - **Evidence Archive**: Local run history browser displaying saved runs with timestamps, filenames, and file sizes, allowing operators to reload and review prior runs in-app.

3. **`tools/labs/run_tracking_verification.py`**:
   - Standalone CLI verification runner emitting newline-delimited JSON events.
   - Executes all 8 public contract test cases, 2 adapter wire cases, rubric mutation invariants, existing Labs regressions (`labs-worker.py`, `selftest_shape_observations.py`, `selftest_object_profile.py`), and Section 13 100k batch workload.
   - Implements `--failure-control` flag to trigger an intentional negative test verifying that failures are accurately reported in the UI without greenwashing.
   - Implements `--skip-workload` flag to provide sub-second (0.01s) fast verification in the interactive UI while retaining full workload coverage on demand.

4. **`tools/labs/run_tracking_analysis.py`**:
   - Standalone recording analysis helper using OpenCV (`cv2.VideoCapture` + `cv2.createBackgroundSubtractorMOG2`) and core `temporal_tracks.Tracker`.
   - Streams progress events and final track metadata.
   - Honestly reports `status: "not_verified"` when recordings or camera feeds are missing or unreadable.

5. **`qml/LabsScreen.qml`**:
   - Added `"Temporal Tracking"` (`tracking`) to the top `LabsSeg` segmented control.
   - Supported `WT_LABS_VIEW=tracking` environment variable for automated screenshot and test routing.
   - Instantiated `LabsTracking` component inside the main layout.

6. **`qml/Main.qml`**:
   - Enabled demo mode shell display and gated login gate under `WT_DEMO=1`.
   - Routed `section` to `"labs"` when `wtLabsView` is provided.

7. **`src/main.cpp`**:
   - Exposed `wtTrackingSubView`, `wtTrackingAutoRun`, and `wtTrackingFailControl` QML context properties for verification and review screenshot captures.

8. **`CMakeLists.txt`**:
   - Added `qml/LabsTracking.qml` to `QML_FILES`.
   - Added `src/models/LabsTrackingController.h` and `src/models/LabsTrackingController.cpp` to `SOURCES`.

---

## 2. Build & Launch Instructions

### Prerequisites
- Toolchain: Qt 6.12.0 (`CMAKE_PREFIX_PATH="$HOME/Qt/6.12.0/gcc_64"`), GCC 13, CMake 3.28+, Ninja.
- Python 3.12+ with OpenCV (`python3-opencv` / `cv2`), NumPy, and psutil.

### Building
```bash
cd /home/cilex-vision/projects/cilex-watchtower-gemini
cmake --preset default
cmake --build build -j$(nproc)
```

### Launching Watchtower
Always launch Watchtower using `./run.sh` with `WT_NO_SCHEME_REG=1`:

1. **Standard Launch (Offline/Demo Mode):**
   ```bash
   WT_DEMO=1 WT_NO_SCHEME_REG=1 ./run.sh
   ```
2. **Direct Launch to Labs Temporal Tracking:**
   ```bash
   WT_DEMO=1 WT_NO_SCHEME_REG=1 WT_SECTION=labs WT_LABS_VIEW=tracking ./run.sh
   ```
3. **Headless Verification with Automated Screenshot:**
   ```bash
   WT_DEMO=1 WT_NO_SCHEME_REG=1 WT_SECTION=labs WT_LABS_VIEW=tracking WT_TRACKING_AUTORUN=1 \
   WT_SCREENSHOT=/tmp/labs_tracking_verified.png WT_SCREENSHOT_MS=2000 QT_QPA_PLATFORM=offscreen timeout 10 ./build/watchtower
   ```

---

## 3. Operator Walkthrough in Watchtower UI

1. **Open Temporal Tracking**:
   - Select **Labs** on the left navigation rail.
   - Click the **Temporal Tracking** tab in the segmented header.
   - Note the `WT_DEMO / VERIFICATION` badge indicating demo/offline mode.

2. **In-App Verification**:
   - Click **Run Verification** to execute contract test cases.
   - Individual test results stream live into the table with execution time in milliseconds, category family, and description.
   - Summary stat cards display total pass rate (14/14 in fast mode, 18/18 with full workload), elapsed time, peak checkpoint size, and failure control status.
   - Click **Save Evidence** to snapshot the current verification run to the local archive.
   - Check **Deliberate Failure Control** and click **Run Verification**:
     - The deliberate failure test triggers.
     - Pass rate updates to `14 / 15` (highlighted in orange/red).
     - The `deliberate-failure-control` test displays a red `FAIL` badge with an explanatory error message.
     - Summary stat card displays `VERIFIED` in green, proving the UI truthfully reports genuine failures without greenwashing.
   - Check **Section 13 Workload (100k batches)** to run the full endurance workload (100,250 batches across multiple trackers, verifying < 2MB snapshot ceiling and no memory leaks).

3. **Recording Analysis**:
   - Switch to the **Recording Analysis** sub-tab.
   - Enter a recording file path (e.g., `.mp4`, `.ts`, `.mkv`).
   - If no recording exists, the status callout displays:
     `Status: NOT VERIFIED - No recording selected. Genuine missing recording access is reported as NOT VERIFIED.`
   - When a valid video file is processed, detected tracks appear in the left list. Selecting a track renders its trajectory polyline (cyan) and bounding box (amber) on the video canvas, synchronized with the playback scrubber.

4. **Evidence Archive**:
   - Switch to the **Evidence Archive** sub-tab.
   - View previously saved runs with filenames, timestamps, and sizes.
   - Click **Load** on any archived entry to restore and inspect previous run metrics and test case logs.

---

## 4. Verification Results & Measurements

### Synthetic Verification
| Suite | Total Tests | Passed | Failed | Elapsed Time | Peak Net RSS | Max Snapshot |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Fast In-App Suite** | 14 | 14 | 0 | 0.01 s | +0.41 MiB | 0 bytes |
| **Full Workload Suite** | 18 | 18 | 0 | 48.32 s | -19.24 MiB | 52,948 bytes |
| **Deliberate Failure Control** | 15 | 14 | 1 | 0.01 s | +0.38 MiB | 0 bytes |

- **Contract Tests**:
  - `one-object-unique-and-bounded-path`: PASS (0 ms)
  - `maximum-cardinality-before-nearest-edge`: PASS (0 ms)
  - `distinguishable-crossing`: PASS (0 ms)
  - `explicit-cost-tie-and-recovery`: PASS (0 ms)
  - `possible-merge-takes-precedence`: PASS (0 ms)
  - `strict-gap-span-and-reset-boundaries`: PASS (0 ms)
  - `bounded-replay-conflict-and-atomic-capacity`: PASS (1 ms)
  - `checkpoint-undrained-outbox-and-exact-continuation`: PASS (2 ms)
  - `pixel-blob-normalization-and-run-reset`: PASS (0 ms)
  - `labs-wire-preview`: PASS (0 ms)
- **Mutation & Rubric Tests**:
  - `association-non-greedy`: PASS (0 ms)
  - `strict-time-boundaries`: PASS (0 ms)
  - `snapshot-tamper-rejection`: PASS (0 ms)
  - `config-type-invariants`: PASS (0 ms)
- **Existing Labs Regressions**:
  - `labs-worker-regressions` (`tools/tests/labs-worker.py` - 79 checks): PASS (28.6 s)
  - `labs-shape-observations` (`tools/labs/selftest_shape_observations.py`): PASS (2.7 s)
  - `labs-object-profile` (`tools/labs/selftest_object_profile.py` - 40 checks): PASS (0.5 s)
- **Section 13 Workload**:
  - 100,250 streaming batches across trackers `resource-a` and `resource-b`: PASS (15.77 s, max snapshot 52,948 bytes vs 2 MB limit).

### Deliberate Failure Control
- **Status**: VERIFIED
- **Behavior**: Injecting a deliberate negative test (`deliberate-failure-control`) resulted in an exact test failure event:
  - Error: *"Deliberate failure control triggered: verified that test harness and UI accurately display genuine failures without greenwashing."*
  - UI displayed `14 / 15 PASS RATE` in warning color and marked failure control as `VERIFIED`.

### Evidence Locations & Screenshots
- Saved run evidence directory: `~/.local/share/Cilex Vision/Watchtower/labs_tracking_evidence/`
- Verification screenshots captured and validated:
  - `/tmp/labs_tracking_fast_done.png`: Completed fast in-app verification (14/14 PASS, summary cards, save button).
  - `/tmp/labs_tracking_failure_control.png`: Deliberate failure control test (14/15, 1 FAIL, VERIFIED status).
  - `/tmp/labs_tracking_recording.png`: Recording Analysis view with NOT VERIFIED status and video overlay canvas.
  - `/tmp/labs_tracking_evidence_populated.png`: Evidence Archive view with loaded runs.

---

## 5. Limitations & Real-Footage Status

1. **Real Recording Acceptance: NOT VERIFIED**
   - In accordance with the prompt ("handle missing access honestly... report real-footage acceptance as NOT VERIFIED"), no local recording files or live backend camera streams were available in the test environment.
   - The recording analysis pipeline (`tools/labs/run_tracking_analysis.py`), file selector, MOG2 background subtractor, and track visualization canvas are fully implemented and verified against unit data, but end-to-end acceptance against production recordings remains `NOT VERIFIED`. No synthetic footage results were fabricated to claim completion.
2. **Workload Gating**:
   - The Section 13 100k batch workload and full `labs-worker.py` regressions take ~48 seconds. To preserve interactive UI responsiveness, they are gated behind an optional checkbox in the in-app verification tab (`Section 13 Workload (100k batches)`), allowing operators to select either instant sub-second verification (0.01s) or full soak verification.

---

## 6. Repository Integrity & Submission

- `git diff --check`: Passed cleanly with zero whitespace or formatting errors.
- Stage 1 files and report (`docs/benchmarks/labs-tracking/SUBMISSION.md`) preserved without modification.
- Local commits and pushes performed strictly to assigned branch `benchmark/gemini-labs-tracking` at `origin`. No pushes to `main` or deployment actions taken.
