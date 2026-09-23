import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C
import QtMultimedia
import Watchtower

// Synchronized wall playback (E1). The whole visible wall rewinds to one instant
// and plays back in lock-step. Because the backend composites the grid into ONE
// HLS stream (server-side, perfectly synced), the client renders a single video
// surface (which visually *is* the grid) + per-cell label overlays placed from
// the backend's cells[] mapping, plus a master timeline/transport and the
// union-coverage calendar. One decode, one timeline — no client-side sync.
//
// Until the backend ships POST /review/mosaic-sessions this lands on an honest
// "compositing pending" state (never a broken player, never fabricated frames).
Item {
    id: root

    property var cameras: []          // the wall page's camera maps (≤16), in display order
    property var client: null         // PlaybackClient
    property var cameraModel: null

    signal returnToLive()

    // session/composited-timeline state
    property string sessionId: ""
    property var grid: ({})           // {cols,rows,cell_w,cell_h,width,height,fps,codec}
    property var cells: []            // [{index,camera_id,row,col}]
    property var frags: []            // composited fragments {cs,ce,ws,we,avail}
    property double compactDuration: 0
    property double winStartMs: 0
    property double winEndMs: 0
    property int zoomMin: 60           // current VIEW preset (chips + window label): 15/60/360/720/1440
    // Span of the loaded composite window. Zoom presets that fit inside it move the
    // VIEW only (in-stream, instant) instead of re-compositing; the window grows
    // (one re-composite) only when a preset is wider. Default wide (6 h) so the common
    // ±minutes/hours navigation never re-opens (15m/1h/6h presets are in-stream view-
    // changes). Entry plays from the window start (~3.8 s; a recent-edge seek render-
    // chases the recording frontier to ~9 s). See docs/perf/2026-06-19.
    // 2026-09-08 soak: the 6 h window is NOT what a slow open costs. The same 16-camera,
    // 3,595-fragment session was created in 275 ms with the database idle and in 19.8-22.4 s
    // with two orphaned render chases and IO-bound coverage scans on it (baseline cycles 1-4,
    // docs/perf/2026-09-08-ttff-soak/). A 15-minute entry window was tried and withdrawn.
    property int loadedSpanMin: 360
    property string selectedDay: ""
    property bool loading: false
    property string errorText: ""     // honest pending/error message
    Connections {
        target: cameraModel
        function onFunctionsChanged() {
            if (root.visible && root.cameraModel && root.cameraModel.playbackEnabled !== false
                    && root.errorText.indexOf(qsTr("Playback is switched off")) === 0
                    && root.winEndMs > root.winStartMs && root.winStartMs > 0)
                root._open(root.winStartMs, root.winEndMs);
        }
    }
    property bool pending: false      // true = backend compositing not available yet

    // In/Out clip selection on the master timeline (wall ms; -1 = none)
    property double selStartMs: -1
    property double selEndMs: -1
    readonly property bool hasSelection: selStartMs >= 0 && selEndMs > selStartMs
    // timeline view window (a zoomable subset of [winStartMs, winEndMs])
    property double viewStartMs: 0
    property double viewEndMs: 0
    property bool customZoom: false   // true after a free-form mouse-wheel zoom (vs a clean preset)
    function resetView() { viewStartMs = winStartMs; viewEndMs = winEndMs; selStartMs = -1; selEndMs = -1; zoomMin = loadedSpanMin; customZoom = false; }
    function fmtSpan(ms) {
        var m = Math.max(1, Math.round(ms / 60000));
        if (m < 60) return m + " min";
        var h = Math.floor(m / 60), mm = m % 60;
        return mm ? (h + "h " + mm + "m") : (h + "h");
    }

    // coverage (union) for the calendar
    property int retentionDays: 35
    property var footageDays: []
    property bool coveragePending: true
    // Quiet 60s refresh while the wall is shown — footage accrues during review
    // and today's dot must appear without re-entering (see PlaybackScreen's note).
    Timer {
        interval: 60000; repeat: true
        running: root.visible && root.client !== null
        onTriggered: { var ids = root.camIds(); if (ids.length > 0) root.client.fetchCoverageUnion(ids); }
    }

    // ---- user-assigned wall cameras (picker) -------------------------------
    // The wall is seeded from the live page on entry, but the operator can
    // assign any ≤16 cameras from the full roster; Apply re-composites the same
    // wall window and restores the playhead.
    property bool pickerOpen: false
    property var pickIds: ({})           // camId -> true (picker working set)
    property string pickSearch: ""
    property double _pendingSeekMs: -1   // restore playhead after re-open (applied when seekable)
    readonly property int pickerCount: { var n = 0; var m = pickIds; for (var k in m) n++; return n }
    readonly property var pickerRows: {
        var out = [];
        var n = cameraModel ? cameraModel.total : 0;
        var q = pickSearch.toLowerCase();
        for (var i = 0; i < n; i++) {
            var c = cameraModel.get(i);
            if (!c || !c.camId) continue;
            if (q !== "" && ("" + c.name).toLowerCase().indexOf(q) < 0
                         && ("" + c.ip).indexOf(q) < 0
                         && ("" + c.groupName).toLowerCase().indexOf(q) < 0) continue;
            out.push(c);
        }
        return out;
    }
    signal resetToLiveRequested()        // picker "Use live wall" → Main reseeds from the live page

    // Quick group switch: the wall holds an arbitrary ≤16 set (custom), or a
    // camera group's cameras. wallGroupLabel shows the active group ("" = custom).
    property string wallGroupLabel: ""
    // Counts come from groupList()'s `total` — computed from OUR roster, never the
    // backend's /groups camera_count (which counts cameras this client cannot see).
    // A group with 0 cameras cannot be composited into a wall at all, so here the
    // row is shown with its count and made inert rather than silently swallowing
    // the click (operator-reported 2026-08-10: "nothing happens").
    readonly property var groupOpts: {
        var out = [{ id: "", name: "All cameras", count: cameraModel ? cameraModel.total : 0 }];
        if (cameraModel) {
            cameraModel.total;   // refresh dependency
            var gs = cameraModel.groupList();
            for (var i = 0; i < gs.length; i++)
                out.push({ id: gs[i].id, name: gs[i].name, count: gs[i].total });
        }
        return out;
    }

    // Entry seeding: prefer the operator's persisted wall layout (assigned +
    // arranged cameras, in grid order), falling back to the given live-page
    // cameras. Ids that no longer resolve (camera removed) are skipped.
    function seedCameras(liveCams) {
        var saved = Settings.wallLayout();
        if (saved && saved.length > 0 && cameraModel) {
            var out = [];
            for (var i = 0; i < saved.length && out.length < 16; i++) {
                var c = cameraModel.cameraByBackendId(saved[i]);
                if (c && c.camId) out.push(c);
            }
            if (out.length > 0) { cameras = out; return; }
        }
        cameras = liveCams;
    }
    function persistLayout() {
        var ids = [];
        for (var i = 0; i < cameras.length; i++)
            if (cameras[i].camId) ids.push(cameras[i].camId);
        Settings.setWallLayout(ids);
    }
    // Re-composite the same wall window over the (changed) camera set and
    // restore the playhead once the new pipeline is seekable.
    function reopenSameWindow() {
        var keepMs = frags.length ? playheadMs : -1;
        if (winEndMs > winStartMs && winStartMs > 0) _open(winStartMs, winEndMs);
        else openFor(loadedSpanMin);
        _pendingSeekMs = keepMs;         // set AFTER _open (which resets it)
    }
    function openPicker() {
        var m = ({});
        for (var i = 0; i < cameras.length; i++)
            if (cameras[i].camId) m[cameras[i].camId] = true;
        pickIds = m; pickSearch = ""; pickerOpen = true;
    }
    function togglePick(id) {
        var m = ({});
        for (var k in pickIds) m[k] = true;
        if (m[id]) delete m[id];
        else { if (pickerCount >= 16) return; m[id] = true; }   // hard cap: 16 cells
        pickIds = m;
    }
    function applyPick() {
        var out = [];
        var n = cameraModel ? cameraModel.total : 0;
        for (var i = 0; i < n && out.length < 16; i++) {
            var c = cameraModel.get(i);
            if (c && c.camId && pickIds[c.camId] === true) out.push(c);
        }
        if (out.length === 0) return;
        pickerOpen = false;
        cameras = out;
        wallGroupLabel = "";          // hand-picked set → no longer a named group
        persistLayout();
        reopenSameWindow();
    }
    // Load a camera group's cameras onto the wall (first 16 if the group is larger).
    function loadGroup(groupId, label) {
        if (!cameraModel) return;
        var list = cameraModel.page(groupId, "", "default", 1, 16);
        var out = [];
        for (var i = 0; i < list.length && out.length < 16; i++)
            if (list[i] && list[i].camId) out.push(list[i]);
        // A group that resolves to nothing cannot become a wall. The dropdown
        // already renders such a group with a 0 and refuses the click, so this is
        // the backstop for the other way in (every camera in the group failed to
        // resolve) — and it says so instead of returning in silence, which is what
        // the operator hit on 2026-08-10.
        if (out.length === 0) {
            root.errorText = qsTr("“%1” has no cameras to play back.").arg(label);
            return;
        }
        cameras = out;
        wallGroupLabel = label;
        persistLayout();
        reopenSameWindow();
    }
    // Open over an EXPLICIT camera set (Situation-Map "play selected"). Bypasses the
    // persisted-layout preference in seedCameras and does NOT persist — a transient
    // view of the chosen cameras; the operator's saved wall layout stays untouched.
    function openWithCameras(camObjs) {
        var out = (camObjs || []).slice(0, 16);
        if (out.length === 0) return;
        cameras = out;
        wallGroupLabel = "";
        openFor(loadedSpanMin);
    }

    // ---- drag-and-drop cell arrangement -------------------------------------
    // The grid is ONE composited stream, so a drop reorders cameras[] and the
    // wall re-composites (debounced — consecutive swaps coalesce); the playhead
    // is restored. Swaps are by camera id, so stale overlay positions during the
    // debounce window still commit correctly.
    property int dragFrom: -1            // grid slot index a drag started on (-1 = none)
    property int dragOver: -1            // grid slot index under the cursor
    property double dragX: 0
    property double dragY: 0
    property string dragName: ""
    function cellAtSlot(slot) {
        for (var i = 0; i < cells.length; i++)
            if (cells[i].row * grid.cols + cells[i].col === slot) return cells[i];
        return null;
    }
    function swapSlots(a, b) {
        var ca = cellAtSlot(a), cb = cellAtSlot(b);
        if (!ca || !cb || ca.camera_id === cb.camera_id) return;
        var ia = -1, ib = -1;
        for (var i = 0; i < cameras.length; i++) {
            if (cameras[i].camId === ca.camera_id) ia = i;
            if (cameras[i].camId === cb.camera_id) ib = i;
        }
        if (ia < 0 || ib < 0) return;
        var next = cameras.slice();
        var t = next[ia]; next[ia] = next[ib]; next[ib] = t;
        cameras = next;
        persistLayout();
        recomposeDebounce.restart();
    }
    Timer {
        id: recomposeDebounce
        interval: 800; repeat: false
        onTriggered: root.reopenSameWindow()
    }

    // ---- per-cell camera swap (right-click a cell → pick another camera) -----
    // Mirrors the Live wall: pick replaces the cell's camera (or, if the chosen
    // camera is already on the wall, swaps the two so nothing duplicates), then
    // re-composites the same window. cellPickerSlot = grid slot being edited.
    property int cellPickerSlot: -1
    property string cellPickerSearch: ""
    function openCellPicker(slot) {
        if (slot < 0 || !cellAtSlot(slot)) return;
        cellPickerSlot = slot; cellPickerSearch = "";
    }
    function setSlotCamera(slot, cam) {
        var cell = cellAtSlot(slot);
        cellPickerSlot = -1;
        if (!cell || !cam || !cam.camId) return;
        var idx = -1, existing = -1;
        for (var i = 0; i < cameras.length; i++) {
            if (cameras[i].camId === cell.camera_id) idx = i;
            if (cameras[i].camId === cam.camId) existing = i;
        }
        if (idx < 0 || existing === idx) return;     // not found / already this camera → no-op
        var next = cameras.slice();
        if (existing >= 0) { var t = next[idx]; next[idx] = next[existing]; next[existing] = t; }  // already on wall → swap
        else next[idx] = cam;                        // otherwise replace this cell's camera
        cameras = next;
        persistLayout();
        reopenSameWindow();
    }
    readonly property var cellPickerRows: {
        var out = [];
        var n = cameraModel ? cameraModel.total : 0;
        var q = cellPickerSearch.toLowerCase();
        for (var i = 0; i < n; i++) {
            var c = cameraModel.get(i);
            if (!c || !c.camId) continue;
            if (q !== "" && ("" + c.name).toLowerCase().indexOf(q) < 0
                         && ("" + c.ip).indexOf(q) < 0
                         && ("" + c.groupName).toLowerCase().indexOf(q) < 0) continue;
            out.push(c);
        }
        return out;
    }

    function pad(n) { return (n < 10 ? "0" : "") + n }
    function fmtClock(ms) { return (!ms || isNaN(ms)) ? "—" : Settings.clock(ms, true) }
    // Wall-clock with milliseconds, for the per-cell time indicator. The wall is ONE
    // composited stream, so this exact instant is what every cell is showing — the cells
    // are synchronized to the millisecond by construction, and printing the identical
    // readout in each cell makes that guarantee visible/auditable.
    function fmtWallMs(ms) {
        if (!ms || isNaN(ms)) return "—";
        var d = new Date(ms);
        function p(n, w) { var s = "" + Math.floor(n); while (s.length < (w || 2)) s = "0" + s; return s; }
        return p(d.getHours()) + ":" + p(d.getMinutes()) + ":" + p(d.getSeconds()) + "." + p(d.getMilliseconds(), 3);
    }

    function camIds() {
        var out = [];
        for (var i = 0; i < cameras.length && out.length < 16; i++) {
            var id = client ? (client.cameraIdForIp(cameras[i].ip) || client.cameraIdForMac(cameras[i].mac || "")) : "";
            if (id !== "") out.push(id);
        }
        return out;
    }
    function gridDims(n) {
        var cols = Math.ceil(Math.sqrt(Math.max(1, n)));
        var rows = Math.ceil(n / cols);
        return { cols: cols, rows: rows };
    }

    // compact player-seconds → wall ms (via composited fragments)
    function posToWall(sec) {
        for (var i = 0; i < frags.length; i++) {
            var f = frags[i];
            if (sec >= f.cs && sec <= f.ce) {
                var frac = (f.ce > f.cs) ? (sec - f.cs) / (f.ce - f.cs) : 0;
                return f.ws + frac * (f.we - f.ws);
            }
        }
        return frags.length ? frags[0].ws : winStartMs;
    }
    function wallToPos(ms) {
        for (var i = 0; i < frags.length; i++) {
            var f = frags[i];
            if (ms >= f.ws && ms <= f.we) {
                var frac = (f.we > f.ws) ? (ms - f.ws) / (f.we - f.ws) : 0;
                return f.cs + frac * (f.ce - f.cs);
            }
        }
        return 0;
    }
    // Smoothly-interpolated player position (compact ms) — same reason as the single-
    // camera Playback screen: MediaPlayer.position ticks coarsely over HLS, so binding
    // the playhead straight to it makes it lurch; a 60fps clock that snaps back on a
    // seek / drift keeps it gliding. The wall only ever plays at 1× (server composite).
    property double _smoothMs: 0
    // While a scrubber seek is SETTLING — player.position has jumped to the target but the HLS
    // decode hasn't produced frames there yet (a few seconds over the composited stream) — don't
    // let the readouts run ahead of the picture. Freeze _smoothMs at the displayed moment and snap
    // it forward only when the first fresh frame actually renders, so the per-cell time chips +
    // playhead stay honest to what's on screen (the whole point of a synchronized wall).
    // settleGuard releases the freeze if a frame never arrives.
    property bool _settling: false
    Timer { id: settleGuard; interval: 8000; onTriggered: { root._smoothMs = player.position; root._settling = false; } }
    Timer {
        interval: 16; repeat: true
        running: root.frags.length > 0 && player.playbackState === MediaPlayer.PlayingState && !root._settling
        onTriggered: {
            var d = player.duration;
            root._smoothMs = Math.min(d > 0 ? d : root._smoothMs, root._smoothMs + interval * player.playbackRate);
        }
    }
    Connections {
        target: player
        function onPositionChanged() {
            if (root._settling) return;                 // a seek jumped position; wait for the picture
            if (player.playbackState !== MediaPlayer.PlayingState
                    || Math.abs(player.position - root._smoothMs) > 400)
                root._smoothMs = player.position;
        }
        function onPlaybackStateChanged() {
            if (!root._settling && player.playbackState !== MediaPlayer.PlayingState) root._smoothMs = player.position;
        }
    }
    // Snap the readouts to the picture the instant the seeked-to frame renders, then resume the
    // smooth clock. Enabled only while settling, so there is zero per-frame cost in steady play.
    Connections {
        target: vout.videoSink
        // Armed while settling (seek) AND while a fresh open awaits its first frame — before
        // 2026-09-08 a fresh open never set _settling, so [WALLTIME] first_frame could not
        // fire and the soak read -1 for a wall that was, in fact, playing.
        enabled: root._settling || root._wallT0 > 0
        function onVideoFrameChanged() {
            root._smoothMs = player.position;
            root._settling = false;
            settleGuard.stop();
            if (root._wallT0 > 0) {
                console.log("[WALLTIME] first_frame dt=" + (Date.now() - root._wallT0) + "ms cells="
                            + (root.cells ? root.cells.length : -1));
                root._wallT0 = -1;
            }
        }
    }

    readonly property double playheadMs: posToWall(_smoothMs / 1000)
    function seekToWall(ms) {
        if (player.duration <= 0) return;
        var pos = wallToPos(ms);
        if (compactDuration > 3) pos = Math.min(pos, compactDuration - 3);   // headroom — don't strand at EOS
        // Raise the settle freeze BEFORE moving position, so the synchronous onPositionChanged
        // that the assignment may fire is already guarded and the readouts don't jump ahead.
        root._settling = true; settleGuard.restart();   // hold the readouts at the picture until frames land
        player.position = Math.round(Math.max(0, pos) * 1000);
        if (client && sessionId !== "") {        // B3 seek-hint: warm the fragment we're landing on (+2 ahead)
            var fi = _fragIndexAt(pos);
            if (fi >= 0) client.prewarmMosaic(sessionId, fi, 2);
        }
    }
    function _fragIndexAt(sec) {                  // manifest-fragment index covering compact-seconds `sec`
        for (var i = 0; i < frags.length; i++) if (sec >= frags[i].cs && sec <= frags[i].ce) return i;
        return -1;
    }

    // ---- per-camera motion lanes on the scrubber ---------------------------
    // The scrubber is thick, so we split it into one thin lane per displayed
    // camera (in grid reading order — top-left cell = top lane) and overlay that
    // camera's motion episodes, time-aligned across cameras. Motion comes from
    // /events/timeline per camera (server pairs started↔ended); 16 concurrent
    // fetches are safe — PlaybackClient routes each reply back by camera id.
    property var motionByCam: ({})          // backendCamId -> [{startMs,endMs,intensity}]

    // ===== "Roll Call": the cell state machine (spec §2.2) =================
    // A cell is recording / dormant / unknown / empty, and we must never infer
    // "nothing recorded" from a dark pixel — that is rendering an unknown as a
    // fact. The mosaic manifest carries availability per FRAGMENT (whole grid),
    // never per camera, so the honest answer comes from what the backend DOES
    // report per camera:
    //   recording_mode == "motion"  ->  a motion episode IS the recording
    //       episode for that camera, widened by its own pre/post roll. So an
    //       episode covering the playhead means it recorded; none means it did
    //       not. Both directions are sound.
    //   recording_mode absent       ->  we cannot tell. Say so ("availability
    //       unknown"), hatch the cell, and never claim either way.
    // Replace this whole derivation the day CV ships per-cell availability on
    // the mosaic manifest (docs/letters/2026-08-10-mosaic-per-cell-availability.md).
    property string hoverCamera: ""         // ONE value, three renderers (cell / lane / roll-call row)
    property bool stampAll: false           // T held — the sync proof

    function _camOf(camId) { return cameraModel ? cameraModel.cameraByBackendId(camId) : null; }
    function _isMotionMode(camId) {
        var c = _camOf(camId);
        return !!(c && String(c.recProfileMode || "") === "motion");
    }
    // Motion spans widened by the camera's own recording roll = its footage spans.
    function footageSpans(camId) {
        if (!_isMotionMode(camId)) return null;      // null = UNKNOWN, not "empty"
        var raw = motionByCam[camId] || [];
        var c = _camOf(camId);
        var pre = (c && c.recPreRollMs > 0) ? c.recPreRollMs : 5000;
        var post = (c && c.recPostRollMs > 0) ? c.recPostRollMs : 5000;
        var out = [];
        for (var i = 0; i < raw.length; i++)
            out.push({ s: raw[i].startMs - pre, e: raw[i].endMs + post });
        return out;
    }
    function cellStateOf(camId) {
        if (!camId) return "empty";
        var sp = footageSpans(camId);
        if (sp === null) return "unknown";
        var p = playheadMs;
        for (var i = 0; i < sp.length; i++) if (p >= sp[i].s && p <= sp[i].e) return "recording";
        return "dormant";
    }
    function motionNowFor(camId) {
        var raw = motionByCam[camId] || [], p = playheadMs;
        for (var i = 0; i < raw.length; i++)
            if (p >= raw[i].startMs - 2000 && p <= raw[i].endMs + 2000) return true;
        return false;
    }
    // Nearest footage edge for this camera, inside the loaded window. -1 = none.
    function nearestFootageMs(camId) {
        var sp = footageSpans(camId);
        if (!sp || sp.length === 0) return -1;
        var p = playheadMs, best = -1, bestD = Infinity;
        for (var i = 0; i < sp.length; i++) {
            var t = (p < sp[i].s) ? sp[i].s : (p > sp[i].e ? sp[i].e : p);
            if (t < winStartMs || t > winEndMs) continue;
            var d = Math.abs(t - p);
            if (d < bestD) { bestD = d; best = t; }
        }
        return best;
    }
    function offerLabelFor(camId) {
        var t = nearestFootageMs(camId);
        if (t < 0) return "";
        return (t < playheadMs ? "← " : "→ ") + Settings.clock(t, false);
    }
    readonly property int recordingCount: {
        var n = 0, ll = laneList;
        for (var i = 0; i < ll.length; i++) if (cellStateOf(ll[i].camId) === "recording") n++;
        return n;
    }
    // How many cells we cannot vouch for. Needed because "0/16 RECORDING" is a
    // CLAIM — it says nothing is recording — and on a wall of continuous-mode
    // cameras every cell is `unknown`, so that claim was being printed with no
    // evidence behind it. An unknown is not a zero. Same rule as the fleet's
    // recording counters: absent data renders as unknown, never as healthy, and
    // never as a fault either.
    readonly property int unknownCount: {
        var n = 0, ll = laneList;
        for (var i = 0; i < ll.length; i++) if (cellStateOf(ll[i].camId) === "unknown") n++;
        return n;
    }
    // One phrasing, three renderers, so the aside and the roll-call header can
    // never disagree about what the wall is claiming.
    readonly property string rollCallTally: {
        var tot = laneList.length;
        if (tot === 0) return "";
        if (unknownCount === tot) return qsTr("%1 UNCONFIRMED").arg(tot);
        if (unknownCount > 0) return qsTr("%1/%2 RECORDING · %3 UNCONFIRMED")
                                       .arg(recordingCount).arg(tot).arg(unknownCount);
        return qsTr("%1/%2 RECORDING").arg(recordingCount).arg(tot);
    }
    // True when at least one camera on the wall has NO footage covering the whole
    // marked range — the export stays valid, but the short clips stop being a
    // surprise. Cameras whose availability we cannot derive are not counted as
    // gaps: an unknown is not evidence of absence.
    readonly property bool selectionSpansGap: {
        if (!hasSelection) return false;
        var ll = laneList;
        for (var i = 0; i < ll.length; i++) {
            var sp = footageSpans(ll[i].camId);
            if (sp === null) continue;                 // unknown — never claimed as a gap
            var covered = false;
            for (var j = 0; j < sp.length; j++)
                if (sp[j].s <= selStartMs && sp[j].e >= selEndMs) { covered = true; break; }
            if (!covered) return true;
        }
        return false;
    }
    // §2.5 — the union of composited footage across the loaded window, as a
    // percentage. The one number that predicts whether scrubbing here is worth it.
    readonly property int coveragePct: {
        var span = winEndMs - winStartMs;
        if (span <= 0 || frags.length === 0) return 0;
        var cov = 0;
        for (var i = 0; i < frags.length; i++)
            cov += Math.max(0, Math.min(frags[i].we, winEndMs) - Math.max(frags[i].ws, winStartMs));
        return Math.round(100 * Math.min(1, cov / span));
    }
    readonly property var laneList: {
        var out = [];
        var cs = root.cells, g = root.grid;
        if (cs && cs.length > 0 && g && g.cols) {
            var sorted = cs.slice().sort(function (a, b) { return (a.row * g.cols + a.col) - (b.row * g.cols + b.col); });
            for (var i = 0; i < sorted.length; i++) {
                var cam = root.cameraModel ? root.cameraModel.cameraByBackendId(sorted[i].camera_id) : null;
                out.push({ camId: sorted[i].camera_id, name: cam && cam.name ? cam.name : sorted[i].camera_id });
            }
        } else {                              // pre-session fallback: cameras[] order
            for (var j = 0; j < root.cameras.length; j++)
                if (root.cameras[j].camId) out.push({ camId: root.cameras[j].camId, name: root.cameras[j].name || root.cameras[j].camId });
        }
        return out;
    }
    function loadWallTimeline() {
        motionByCam = ({});
        // `!(a > b)` rather than `a <= b`: identical for every finite pair, and it fires
        // on NaN where `<=` does not — which is the form line 156 already used.
        if (!client || !(winEndMs > winStartMs)) return;
        var ll = laneList, s = new Date(winStartMs).toISOString(), e = new Date(winEndMs).toISOString();
        // wide windows → ask the server for density bins (compact, fast) instead of
        // every episode; narrow windows → precise episode spans.
        var bins = (winEndMs - winStartMs) > 6 * 3600 * 1000 ? 300 : 0;
        for (var i = 0; i < ll.length; i++) client.fetchTimeline(ll[i].camId, s, e, bins);
    }
    Connections {
        target: root.client
        enabled: root.client !== null
        function onTimelineReady(cid, mode, blocks) {
            var eps = [];
            if (mode === "buckets") {
                for (var i = 0; i < blocks.length; i++) {
                    var b = blocks[i], bs = Date.parse(b.bucket_start), be = Date.parse(b.bucket_end);
                    var dur = Math.max(1, (be - bs) / 1000);
                    eps.push({ startMs: bs, endMs: be, intensity: Math.min(1, (b.motion_seconds || 0) / dur) });
                }
            } else if (mode === "episodes") {
                for (var j = 0; j < blocks.length; j++) {
                    var ep = blocks[j], st = Date.parse(ep.start_time);
                    var en = ep.end_time ? Date.parse(ep.end_time) : Math.min(Date.now(), root.winEndMs);
                    if (en < st) { var t = st; st = en; en = t; }
                    eps.push({ startMs: st, endMs: en, intensity: 1 });
                }
            } else return;                    // "error" → leave this camera's lane empty
            eps.sort(function (a, b) { return a.startMs - b.startMs; });
            var m = ({});
            for (var k in root.motionByCam) m[k] = root.motionByCam[k];
            m[cid] = eps;
            root.motionByCam = m;
        }
    }

    // ---- open / transport --------------------------------------------------
    function _windowFor(spanMin) {
        var end = Date.now();
        var start = end - spanMin * 60000;
        return { s: start, e: end };
    }
    function openFor(spanMin) {
        loadedSpanMin = spanMin || loadedSpanMin;
        selectedDay = "";
        var w = _windowFor(loadedSpanMin);
        _open(w.s, w.e);
    }
    // Calendar day-pick re-composites a 24 h window. Debounced so a flurry of rapid
    // day clicks coalesces into ONE session create instead of piling up composites.
    property string _pendingDay: ""
    Timer { id: dayDebounce; interval: 350; onTriggered: root._openDayNow() }
    function openForDay(dateStr) {
        selectedDay = dateStr; zoomMin = 1440;
        _pendingDay = dateStr; dayDebounce.restart();
    }
    function _openDayNow() {
        if (_pendingDay === "") return;
        var s = new Date(_pendingDay + "T00:00:00").getTime();
        loadedSpanMin = 1440; _pendingDay = "";
        _open(s, Math.min(s + 86400000, Date.now()));
    }
    // [WALLTIME] open -> FIRST REAL FRAME on the 16-cell wall. Stamped at the start
    // of every _open() and reported once the first video frame lands (the same
    // onVideoFrameChanged that ends the settle freeze), so the number is what a
    // guard waits, not what the session took. Operator target 2026-09-08: 2 s.
    property double _wallT0: -1
    function _open(startMs, endMs) {
        _wallT0 = Date.now();
        console.log("[WALLTIME] open t=" + _wallT0 + " start=" + new Date(startMs).toISOString());
        if (!client || cameras.length === 0) return;
        console.log("WALLOPEN," + new Date(startMs).toISOString() + "," + new Date(endMs).toISOString()
            + ",span=" + Math.round((endMs - startMs) / 60000) + "min");   // audit re-composites
        renderGuard.stop();
        errorText = ""; pending = false; loading = true;
        var oldSid = sessionId;          // B2a: ask the backend to reap it as we open the new one
        sessionId = ""; frags = []; grid = ({}); cells = []; _pendingSeekMs = -1;
        // Fully unload (not just stop): Qt 6.4's stop() re-prerolls the old media
        // at position 0, re-downloading its first segments through the proxy while
        // the new session is created (see PlaybackScreen's matching note).
        player.stop();
        player.source = "";
        var ids = camIds();
        if (ids.length === 0) { loading = false; errorText = "These cameras aren't in the recording backend."; return; }
        // Playback switched off (operator setting) → playback-service is stopped and the
        // mosaic session would connect-refuse. Same calm gate as the Playback screen,
        // same fail-safe-open key (CV letter 2026-06-16.reply3: the recorded wall is
        // playback-service; /streams keeps serving `functions` even when it's down).
        if (cameraModel && cameraModel.playbackEnabled === false) {
            loading = false;
            errorText = qsTr("Playback is switched off — the synchronized wall is paused. This is an operator setting, not a fault.");
            return;
        }
        var d = gridDims(ids.length);
        client.ensureReady();
        // coverage union moved to onMosaicSessionReady (2026-09-08): it decorates the timeline,
        // the session create is the guard's wait, and both hit the same IO-bound table.
        // prewarm_at=0 (B3): render the ENTRY fragment during create — entry plays from the
        // window start, so fragment 0 is the one the first frame waits for. Measured 2026-09-08
        // on an idle server, 6 h window: seg/0 served 2,027 / 2,140 ms after create with it,
        // 2,977 / 4,125 ms without; the create itself was not slower (285-460 vs 1,410-1,702 ms).
        client.openMosaicSession(ids, new Date(startMs).toISOString(), new Date(endMs).toISOString(),
                                 d.cols, d.rows, oldSid, 0);   // replaces=oldSid → one wall = one live session
    }
    // Zoom presets move the VIEW inside the already-loaded window (in-stream, instant)
    // instead of re-compositing. Only a preset WIDER than the loaded window grows it —
    // one re-composite, playhead preserved. This is the main win from the wall perf
    // report (docs/perf/2026-06-19): re-opens are slow (~8 s) and 56% stall; in-window
    // seeks are ~105 ms and 100% reliable.
    function setViewPreset(spanMin) {
        zoomMin = spanMin; selectedDay = ""; customZoom = false;
        if (frags.length > 0 && spanMin <= loadedSpanMin) {   // fits the loaded window → view only
            viewEndMs = winEndMs;
            viewStartMs = Math.max(winStartMs, winEndMs - spanMin * 60000);
        } else {
            var keepMs = frags.length ? playheadMs : -1;
            openFor(spanMin);
            _pendingSeekMs = keepMs;      // keep the playhead across the grow re-composite
        }
    }
    function setZoom(spanMin) { setViewPreset(spanMin); }   // back-compat alias

    // Export the In→Out moment across the wall (dual-archive): a per-camera clip
    // for each tile (live today) + one combined synchronized-grid clip (E2 —
    // honest failure until the backend ships the mosaic export). Feedback rides
    // the existing playbackClient export toasts in Main.
    function exportSelection() {
        if (!hasSelection || !client) return;
        var s = new Date(selStartMs).toISOString(), e = new Date(selEndMs).toISOString();
        var ids = camIds();
        // One group_id ties the dual-archive set (N per-camera clips + 1 combined
        // grid) together so the exports list (A6) renders them as one wall moment.
        var gid = "wall-" + Date.now();
        var purpose = "Wall review · " + ids.length + " cams · " + fmtClock(selStartMs) + "–" + fmtClock(selEndMs);
        for (var i = 0; i < ids.length; i++)
            client.createExport(ids[i], s, e, "wallclock", Artifacts.newExportPath(ids[i]), gid, purpose);
        if (sessionId !== "")
            client.createMosaicExport(sessionId, s, e, "wallclock", Artifacts.newExportPath("wall"), gid, purpose);
    }

    Connections {
        target: root.client
        enabled: root.client !== null
        function onMosaicSessionReady(sid, g, c, dur, fragments, meta) {
            if (root._wallT0 > 0) console.log("[WALLTIME] session_ready dt=" + (Date.now() - root._wallT0) + "ms frags=" + (fragments ? fragments.length : -1));
            root.loading = false; root.pending = false; root.errorText = "";
            root.sessionId = sid; root.grid = g; root.cells = c; root.compactDuration = dur;
            { var cids = root.camIds(); if (cids.length > 0) root.client.fetchCoverageUnion(cids); }   // after the index, not against it
            root.winStartMs = Date.parse(meta.wall_start);
            root.winEndMs = Date.parse(meta.wall_end);
            root.selStartMs = -1; root.selEndMs = -1;
            // View the whole loaded window; play from its start (compact 0). We do NOT
            // seek to the recent edge on a fresh open: seeking far into a just-composited
            // window render-chases the recording frontier (~9 s, measured). Playing from
            // the window start is ~3.8 s, and all navigation within the window is then an
            // in-stream seek. A restore (camera swap / window grow) keeps its pending
            // playhead. See docs/perf/2026-06-19.
            root.viewStartMs = root.winStartMs; root.viewEndMs = root.winEndMs;
            if (root._pendingSeekMs < 0) root.zoomMin = root.loadedSpanMin;   // fresh → chip reflects the full window
            var out = [];
            for (var i = 0; i < fragments.length; i++) {
                var f = fragments[i];
                if (f.availability === "no_recording") continue;   // whole-grid gap → shown as gap on the bar
                out.push({ cs: f.compact_start, ce: f.compact_end,
                           ws: Date.parse(f.wall_start), we: Date.parse(f.wall_end), avail: f.availability });
            }
            root.frags = out;
            // WT_TRACE: what the SERVER actually returned for this grid. The operator
            // sees black cells and cannot tell "no footage here" from "compositor did
            // not render it"; neither can we, because availability is per-FRAGMENT
            // (whole grid) and there is no per-cell truth in the manifest.
            if (typeof wtTrace !== "undefined" && wtTrace) {
                var av = {};
                for (var k = 0; k < fragments.length; k++) {
                    var a = fragments[k].availability || "?";
                    av[a] = (av[a] || 0) + 1;
                }
                console.log("[WALL] session=" + sid + " grid=" + g.cols + "x" + g.rows
                            + " " + g.width + "x" + g.height + "@" + g.fps + " " + g.codec
                            + " cells=" + c.length + " frags=" + fragments.length
                            + " kept=" + out.length + " availability=" + JSON.stringify(av)
                            + " dur=" + Math.round(dur) + "s t=" + Date.now());
                for (var m = 0; m < c.length; m++)
                    console.log("[WALL] cell " + c[m].index + " r" + c[m].row + "c" + c[m].col
                                + " cam=" + c[m].camera_id);
            }
            root.loadWallTimeline();      // per-camera motion lanes for the scrubber
            if (out.length === 0) { root.errorText = "No footage recorded in this range."; return; }
            player.source = root.client.mosaicPlaylistUrl(sid);
            player.play();
            if (root._wallT0 > 0) console.log("[WALLTIME] source_set dt=" + (Date.now() - root._wallT0) + "ms");
            renderGuard.restart();   // honest failure if the composite never produces frames
            if (perf.active) perf._onSessionReady();
        }
        function onMosaicSessionFailed(err, pending) {
            root.loading = false;
            root.pending = pending;     // 404 ⇒ endpoint not shipped yet
            root.errorText = err;
            if (perf.active) perf._onSessionFailed(err);
        }
        function onCoverageUnionReady(available, retDays, unionDays) {
            root.coveragePending = !available;
            if (available && retDays > 0) root.retentionDays = retDays;
            root.footageDays = unionDays;
        }
    }

    // Render watchdog. RE-MEASURED 2026-08-10 (16 cams, 6 h window, 5 sessions
    // against the pilot backend): session create 191-643 ms, first segment at the
    // window head 0.69 s, and prewarm -> segment served 1.2-2.4 s. The "~4-6 s for
    // the first segment" this comment used to claim is STALE — the backend is now
    // well inside the operator's 3 s bar. History kept because it explains the
    // shape: 3043dbe (render chase + batched bounded resolves + ~3.7× realtime)
    // took it down from ~45-55 s before 2026-06-12.
    // The 25 s budget below stays as-is: it is a never-hang backstop, not a target,
    // and a loaded backend is exactly when it has to be generous. Poll while
    // "Compositing…"
    // is up: if frames arrive, stand down; only fail honestly after a budget
    // comfortably above the measured cold start (the file's contract: never a
    // broken player — and never an error banner over video that IS playing).
    Timer {
        id: renderGuard
        interval: 5000; repeat: true
        property int waitedMs: 0
        onRunningChanged: if (running) waitedMs = 0
        onTriggered: {
            if (root.sessionId === "" || root.errorText !== "") { running = false; return; }
            if (player.position > 0) { running = false; return; }   // frames arrived
            waitedMs += interval;
            if (waitedMs >= 25000) {
                running = false;
                root.errorText = "Couldn't composite the synchronized grid for this window — the server didn't return frames in time. Try a different time, or Return to live.";
            }
        }
    }
    focus: true
    onVisibleChanged: {
        if (visible) { forceActiveFocus(); return; }
        player.stop();
        if (root.sessionId !== "" && client) {   // B1: free the composite as we leave the wall
            client.disposeMosaicSession(root.sessionId);
            root.sessionId = "";
        }
    }
    // App teardown — release the live composite rather than leaning on the idle reaper.
    Component.onDestruction: if (root.sessionId !== "" && client) client.disposeMosaicSession(root.sessionId)
    // Bindings must survive a Russian layout: match the Latin key OR the Cyrillic
    // character the same physical key emits (the PlaybackScreen convention).
    function _key(e, latin, cyr) { return e.key === latin || e.key === cyr }
    Keys.onReleased: (e) => {
        if (root._key(e, Qt.Key_T, 0x0415) && !e.isAutoRepeat) {
            root.stampAll = false; e.accepted = true;
        }
    }
    // keyboard transport: space = play/pause, ←/→ = ∓10s (Shift = ∓60s)
    Keys.onPressed: (e) => {
        if (root.pickerOpen) {           // picker owns the keyboard while open
            if (e.key === Qt.Key_Escape) { root.pickerOpen = false; e.accepted = true; }
            return;
        }
        if (root.cellPickerSlot >= 0) {  // per-cell picker owns the keyboard while open
            if (e.key === Qt.Key_Escape) { root.cellPickerSlot = -1; e.accepted = true; }
            return;
        }
        // T HELD stamps every cell (§2.3) — proof of synchronisation on demand
        // rather than fourteen chips asserting it permanently.
        // Layout-safe the way the rest of this product does it: the spec says
        // "bind by physical code", but Qt exposes no portable one (nativeScanCode
        // means different things on X11 and Windows — PlaybackScreen.qml:1077).
        // So bind the Latin key PLUS the Cyrillic character the SAME PHYSICAL KEY
        // emits on ЙЦУКЕН: T sits where Е does.
        if (root._key(e, Qt.Key_T, 0x0415) && !e.isAutoRepeat) {
            root.stampAll = true; e.accepted = true; return;
        }
        if (player.duration <= 0) return;
        if (e.key === Qt.Key_Space) {
            player.playbackState === MediaPlayer.PlayingState ? player.pause() : player.play();
            e.accepted = true;
        } else if (e.key === Qt.Key_Left) {
            player.position = Math.max(0, player.position - ((e.modifiers & Qt.ShiftModifier) ? 60000 : 10000));
            e.accepted = true;
        } else if (e.key === Qt.Key_Right) {
            player.position = Math.min(player.duration, player.position + ((e.modifiers & Qt.ShiftModifier) ? 60000 : 10000));
            e.accepted = true;
        } else if (e.key === Qt.Key_0 || e.key === Qt.Key_Home) {
            root.resetView(); e.accepted = true;   // FIT: drop a custom wheel-zoom back to the full window
        }
        // ---- §3, the rest. Latin + the Cyrillic the SAME PHYSICAL KEY emits ----
        else if (root._key(e, Qt.Key_BracketLeft, 0x0425)) {    // [ = Х
            root.selStartMs = root.playheadMs;
            if (!(root.selEndMs > root.selStartMs)) root.selEndMs = root.selStartMs + 30000;
            e.accepted = true;
        } else if (root._key(e, Qt.Key_BracketRight, 0x042A)) { // ] = Ъ
            root.selEndMs = root.playheadMs;
            if (!(root.selStartMs >= 0 && root.selStartMs < root.selEndMs))
                root.selStartMs = Math.max(root.winStartMs, root.selEndMs - 30000);
            e.accepted = true;
        } else if (root._key(e, Qt.Key_X, 0x0427)) {            // X = Ч
            if (root.hasSelection) root.exportSelection();
            e.accepted = true;
        } else if (root._key(e, Qt.Key_E, 0x0423)) {            // E = У
            Settings.eventsOnScrubber = !Settings.eventsOnScrubber; e.accepted = true;
        } else if (e.key >= Qt.Key_1 && e.key <= Qt.Key_5) {
            root.setViewPreset([15, 60, 360, 720, 1440][e.key - Qt.Key_1]); e.accepted = true;
        }
    }
    // §3 — Esc unwinds ONE layer per press: modal, then selection, then zoom. Any
    // other order is ambiguous about which thing it will close. Returns true when
    // it consumed a layer, so Main's app-wide Esc can fall through to fullscreen.
    function escapeLayer() {
        if (pickerOpen) { pickerOpen = false; return true; }
        if (cellPickerSlot >= 0) { cellPickerSlot = -1; return true; }
        if (hasSelection) { selStartMs = -1; selEndMs = -1; return true; }
        if (customZoom) { resetView(); return true; }
        return false;
    }

    // ======================================================================
    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        RowLayout {
            Layout.fillWidth: true; Layout.fillHeight: true; spacing: 0

            // ---- grid (single composited stream) + per-cell overlays --------
            Rectangle {
                id: playerArea
                Layout.fillWidth: true; Layout.fillHeight: true
                color: "#121110"; clip: true

                VideoOutput { id: vout; anchors.fill: parent; fillMode: VideoOutput.PreserveAspectFit }
                MediaPlayer {
                    id: player
                    videoOutput: vout
                    audioOutput: null
                    onErrorOccurred: (e, s) => {
                        if (e !== MediaPlayer.NoError) root.errorText = s
                        console.log("[WALLTIME] error code=" + e + " " + s + (root._wallT0 > 0 ? " dt=" + (Date.now() - root._wallT0) + "ms" : ""))
                    }
                    // [WALLTIME] stage markers between source_set and first_frame — before 2026-09-08
                    // the wall logged nothing in that gap, so a 60 s wait was unattributable.
                    onMediaStatusChanged: if (root._wallT0 > 0) console.log("[WALLTIME] mediaStatus=" + mediaStatus + " dt=" + (Date.now() - root._wallT0) + "ms")
                    onPlaybackStateChanged: if (root._wallT0 > 0) console.log("[WALLTIME] playbackState=" + playbackState + " dt=" + (Date.now() - root._wallT0) + "ms")
                    onPositionChanged: if (player.position > 0) renderGuard.stop()   // frames flowing → not stalled
                    // Apply the deferred playhead restore (camera re-assign). Must
                    // wait for `seekable` — a position set before the pipeline
                    // prerolls is silently dropped (same fix as PlaybackScreen).
                    function applyPendingSeek() {
                        if (seekable && duration > 0 && root._pendingSeekMs >= 0) {
                            root.seekToWall(root._pendingSeekMs);
                            root._pendingSeekMs = -1;
                        }
                    }
                    onSeekableChanged: applyPendingSeek()
                    onDurationChanged: applyPendingSeek()
                }

                // Fitted video rect (PreserveAspectFit) for placing cell overlays.
                readonly property real gAspect: (root.grid.width && root.grid.height)
                    ? root.grid.width / root.grid.height : (16 / 9)
                readonly property real boxAspect: width / Math.max(1, height)
                readonly property real fitW: gAspect > boxAspect ? width : height * gAspect
                readonly property real fitH: gAspect > boxAspect ? width / gAspect : height
                readonly property real fitX: (width - fitW) / 2
                readonly property real fitY: (height - fitH) / 2

                // per-cell labels (the grid pixels come from the server; we only
                // annotate each cell with its camera name)
                Repeater {
                    model: (root.sessionId !== "" && root.grid.cols && root.errorText === "") ? root.cells : []
                    delegate: Item {
                        readonly property int cols: root.grid.cols
                        readonly property int rows: root.grid.rows
                        readonly property int slot: modelData.row * cols + modelData.col
                        x: playerArea.fitX + (modelData.col / cols) * playerArea.fitW
                        y: playerArea.fitY + (modelData.row / rows) * playerArea.fitH
                        width: playerArea.fitW / cols
                        height: playerArea.fitH / rows
                        // "Roll Call" §2.2 — three explicit states, plus the honest
                        // `unknown` the missing per-cell availability field forces.
                        // The permanent per-cell timestamp is GONE: one clock in the
                        // aside proves synchronisation better (§2.3), and T stamps
                        // every cell on demand.
                        WpCell {
                            anchors.fill: parent
                            camId: modelData.camera_id
                            octet: {
                                var c = root.cameraModel ? root.cameraModel.cameraByBackendId(modelData.camera_id) : null;
                                var m = /\.(\d+)$/.exec((c && c.ip) || "");
                                return m ? "." + m[1] : "";
                            }
                            model: {
                                var c = root.cameraModel ? root.cameraModel.cameraByBackendId(modelData.camera_id) : null;
                                return c && c.name ? String(c.name).replace(/\s*\((?:\d+\.){3}\d+\)\s*$/, "") : "";
                            }
                            state: root.frags.length === 0 ? "unknown" : root.cellStateOf(modelData.camera_id)
                            motionNow: root.motionNowFor(modelData.camera_id)
                            hovered: root.hoverCamera === modelData.camera_id
                            stamped: root.stampAll
                            stampText: root.fmtWallMs(root.playheadMs)
                            offerMs: root.nearestFootageMs(modelData.camera_id)
                            offerLabel: root.offerLabelFor(modelData.camera_id)
                            onJumpRequested: (ms) => root.seekToWall(ms)
                            onPickRequested: root.cellPickerSlot = parent.slot
                            onHoverChanged: (cid, on) => root.hoverCamera = on ? cid : ""
                        }
                        // drag feedback: source cell dims, hovered target gets an accent frame
                        Rectangle {
                            anchors.fill: parent
                            visible: root.dragFrom >= 0 && parent.slot === root.dragFrom
                            color: Qt.rgba(0, 0, 0, 0.45)
                            border.width: 1; border.color: Theme.line2
                        }
                        Rectangle {
                            anchors.fill: parent; anchors.margins: 1
                            visible: root.dragFrom >= 0 && parent.slot === root.dragOver && root.dragOver !== root.dragFrom
                            color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.15)
                            border.width: 2; border.color: Theme.accent
                        }
                    }
                }

                // drag-to-rearrange: press a cell, drag onto another, release to swap.
                // Right-click a cell → pick another camera for that cell (like Live).
                MouseArea {
                    anchors.fill: parent
                    visible: root.sessionId !== "" && root.grid.cols > 0 && root.errorText === "" && !root.pickerOpen && root.cellPickerSlot < 0
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    cursorShape: root.dragFrom >= 0 ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                    function slotAt(mx, my) {
                        var c = root.grid.cols, r = root.grid.rows;
                        if (!c || !r) return -1;
                        var px = mx - playerArea.fitX, py = my - playerArea.fitY;
                        if (px < 0 || py < 0 || px >= playerArea.fitW || py >= playerArea.fitH) return -1;
                        return Math.floor(py / (playerArea.fitH / r)) * c + Math.floor(px / (playerArea.fitW / c));
                    }
                    onPressed: (m) => {
                        var s = slotAt(m.x, m.y);
                        if (m.button === Qt.RightButton) {       // right-click → swap this cell's camera
                            if (s >= 0 && root.cellAtSlot(s)) root.openCellPicker(s);
                            return;
                        }
                        if (s >= 0 && root.cellAtSlot(s)) {
                            root.dragFrom = s; root.dragOver = s;
                            root.dragX = m.x; root.dragY = m.y;
                            var cell = root.cellAtSlot(s);
                            var cam = root.cameraModel ? root.cameraModel.cameraByBackendId(cell.camera_id) : null;
                            root.dragName = cam && cam.name ? cam.name : cell.camera_id;
                        } else { m.accepted = false }
                    }
                    onPositionChanged: (m) => {
                        if (root.dragFrom < 0) return;
                        root.dragX = m.x; root.dragY = m.y;
                        root.dragOver = slotAt(m.x, m.y);
                    }
                    onReleased: {
                        if (root.dragFrom >= 0 && root.dragOver >= 0 && root.dragOver !== root.dragFrom)
                            root.swapSlots(root.dragFrom, root.dragOver);
                        root.dragFrom = -1; root.dragOver = -1; root.dragName = "";
                    }
                    onCanceled: { root.dragFrom = -1; root.dragOver = -1; root.dragName = "" }
                }

                // drag ghost: the camera name riding the cursor
                Rectangle {
                    visible: root.dragFrom >= 0
                    x: root.dragX + 12; y: root.dragY + 10
                    z: 10
                    width: dgT.implicitWidth + 14; height: 20
                    color: Theme.accent; radius: 2
                    Text { id: dgT; anchors.centerIn: parent; text: root.dragName
                        color: Theme.bg; font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.Bold }
                }

                LoadingState {
                    anchors.centerIn: parent
                    visible: root.loading || (player.mediaStatus === MediaPlayer.LoadingMedia && root.errorText === "" && !root.pending)
                    label: root.loading ? qsTr("Opening wall session…") : qsTr("Compositing…")
                }
                // honest pending / error / empty state
                Column {
                    anchors.centerIn: parent; spacing: 8; width: parent.width * 0.7
                    visible: root.errorText !== ""
                    Icon { anchors.horizontalCenter: parent.horizontalCenter; name: root.pending ? "pulse" : "off"; size: 30; color: Theme.ink3 }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter; horizontalAlignment: Text.AlignHCenter
                        width: parent.width; wrapMode: Text.WordWrap
                        text: root.pending ? "Synchronized wall playback — backend compositing pending"
                                           : root.errorText
                        color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 13
                    }
                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter; horizontalAlignment: Text.AlignHCenter
                        width: parent.width; wrapMode: Text.WordWrap
                        visible: root.pending
                        text: qsTr("The server-composited grid stream (E1) isn't live yet. Live tiles are unaffected — use Return to live.")
                        color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11
                    }
                }
            }

            // ---- aside: wall info + footage calendar ------------------------
            Rectangle {
                Layout.preferredWidth: 296; Layout.fillHeight: true; color: Theme.panel
                Rectangle { anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 1; color: Theme.line }
                ColumnLayout {
                    anchors.fill: parent; anchors.leftMargin: 1; spacing: 0
                    component Hdr: Text {
                        Layout.fillWidth: true; Layout.topMargin: 14; Layout.leftMargin: 16; Layout.bottomMargin: 8
                        color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                        font.weight: Font.DemiBold; font.letterSpacing: 1.4; font.capitalization: Font.AllUppercase
                    }

                    // ===== §2.3 THE ONE CLOCK — top block, never over the mosaic ==
                    // The fourteen per-cell chips are gone. One clock is STRONGER
                    // proof: fourteen chips implicitly claim the cells could differ
                    // and happen not to; the truth is they cannot, because there is
                    // one stream. It lives here and not floated over the picture
                    // because a 16:9 mosaic in a 16:9 stage leaves ~24px of
                    // letterbox — any overlay is ON a camera, and top-left is where
                    // the operator looks first.
                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: clockCol.implicitHeight + 26
                        Column {
                            id: clockCol
                            anchors { left: parent.left; right: parent.right; top: parent.top
                                      leftMargin: 16; rightMargin: 16; topMargin: 13 }
                            spacing: 2
                            Text {
                                text: root.frags.length ? Qt.formatDate(new Date(root.playheadMs), "ddd d MMM yyyy") : "—"
                                color: Qt.rgba(Theme.ink.r, Theme.ink.g, Theme.ink.b, 0.62)
                                font.family: Theme.fontMono; font.pixelSize: 14
                            }
                            Row {
                                spacing: 0
                                Text {
                                    text: root.frags.length ? Settings.clock(root.playheadMs, true) : "--:--:--"
                                    color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 21
                                }
                                Text {
                                    text: root.frags.length ? ("." + ("00" + Math.floor(root.playheadMs % 1000)).slice(-3)) : ""
                                    color: Theme.accent; font.family: Theme.fontMono; font.pixelSize: 21
                                }
                            }
                            // The badge names the MECHANISM, and its second half
                            // answers "how many cells should I be seeing?" before
                            // the operator reads a single cell.
                            Rectangle {
                                width: syncT.implicitWidth + 12; height: 16
                                color: "transparent"; border.width: 1; border.color: Theme.line2
                                Text {
                                    id: syncT; anchors.centerIn: parent
                                    text: qsTr("1 STREAM · %1").arg(root.rollCallTally)
                                    color: Theme.good; font.family: Theme.fontMono; font.pixelSize: 8
                                    font.letterSpacing: 1.2; font.weight: Font.DemiBold
                                }
                                MouseArea { id: syncMa; anchors.fill: parent; hoverEnabled: true }
                                C.ToolTip.visible: syncMa.containsMouse
                                C.ToolTip.delay: 300
                                C.ToolTip.text: qsTr("Every cell is the same instant by construction — one composited stream. Hold T to stamp every cell.")
                            }
                        }
                        Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                                    height: 1; color: Theme.line2 }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true; Layout.topMargin: 16; Layout.leftMargin: 16; Layout.rightMargin: 16; spacing: 2
                        Text { text: qsTr("Wall playback"); color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 16; font.weight: Font.DemiBold }
                        RowLayout {
                            Layout.fillWidth: true; spacing: 8
                            Text { text: root.cameras.length + " cameras · synchronized"; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11; Layout.fillWidth: true; elide: Text.ElideRight }
                            Rectangle {
                                implicitWidth: ecT.implicitWidth + 16; implicitHeight: 20
                                color: ecMa.containsMouse ? Theme.accent : "transparent"
                                border.width: 1; border.color: ecMa.containsMouse ? Theme.accent : Theme.line2
                                Text { id: ecT; anchors.centerIn: parent; text: qsTr("EDIT CAMERAS"); color: ecMa.containsMouse ? Theme.bg : Theme.ink2
                                    font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 0.8 }
                                MouseArea { id: ecMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.openPicker() }
                            }
                        }
                        // quick group switch — load a camera group's cameras onto the wall
                        RowLayout {
                            Layout.fillWidth: true; Layout.topMargin: 6; spacing: 8
                            Text { text: qsTr("GROUP"); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 1; Layout.alignment: Qt.AlignVCenter }
                            Rectangle {
                                id: wgCtl
                                Layout.fillWidth: true; implicitHeight: 28
                                color: Theme.bg; border.width: 1; border.color: wgMa.containsMouse ? Theme.accent : Theme.line2
                                Text { anchors.left: parent.left; anchors.leftMargin: 8; anchors.right: wgChev.left; anchors.rightMargin: 4; anchors.verticalCenter: parent.verticalCenter
                                    text: root.wallGroupLabel !== "" ? root.wallGroupLabel : "Custom selection"
                                    color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12; elide: Text.ElideRight }
                                Text { id: wgChev; anchors.right: parent.right; anchors.rightMargin: 8; anchors.verticalCenter: parent.verticalCenter; text: "▾"; color: Theme.ink3; font.pixelSize: 11 }
                                MouseArea { id: wgMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: wgPopup.open() }
                                C.Popup {
                                    id: wgPopup
                                    y: wgCtl.height + 2; x: 0; width: wgCtl.width; padding: 0
                                    background: Rectangle { color: Theme.panel; border.color: Theme.line2; border.width: 1 }
                                    contentItem: Column {
                                        Repeater {
                                            model: root.groupOpts
                                            delegate: Rectangle {
                                                required property var modelData
                                                readonly property bool isEmpty: modelData.count === 0
                                                width: wgCtl.width; height: 30
                                                color: (wgoMa.containsMouse && !isEmpty) ? Theme.panel2 : "transparent"
                                                Text { anchors.left: parent.left; anchors.leftMargin: 10
                                                    anchors.right: wgoCnt.left; anchors.rightMargin: 6; anchors.verticalCenter: parent.verticalCenter
                                                    text: modelData.name
                                                    color: parent.isEmpty ? Theme.ink3
                                                         : (root.wallGroupLabel === modelData.name ? Theme.accent : Theme.ink)
                                                    font.family: Theme.fontSans; font.pixelSize: 12; elide: Text.ElideRight }
                                                Text { id: wgoCnt; anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter
                                                    text: modelData.count
                                                    color: parent.isEmpty ? Theme.ink3
                                                         : (root.wallGroupLabel === modelData.name ? Theme.accent : Theme.ink2)
                                                    font.family: Theme.fontMono; font.pixelSize: 11 }
                                                // 0 cameras cannot become a wall — the row is visibly
                                                // inert (dimmed, arrow cursor, tooltip) rather than
                                                // eating the click and leaving the label unchanged.
                                                MouseArea { id: wgoMa; anchors.fill: parent; hoverEnabled: true
                                                    cursorShape: parent.isEmpty ? Qt.ArrowCursor : Qt.PointingHandCursor
                                                    onClicked: { if (parent.isEmpty) return;
                                                                 root.loadGroup(modelData.id, modelData.name); wgPopup.close() } }
                                                C.ToolTip.visible: wgoMa.containsMouse && isEmpty
                                                C.ToolTip.delay: 300
                                                C.ToolTip.text: qsTr("No cameras in this group")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        // The hint line is DELETED (§2.6): its two gestures are now
                        // affordances on the cells themselves (WpCell §2.2e). A
                        // sentence that has to explain the interaction model is a
                        // symptom, not documentation.
                    }

                    // ===== §2.5 the window statement — model BEFORE value =====
                    // The defect this fixes: rolling and calendar-day windows both
                    // printed "24 hours", which is how an operator read the far left
                    // of 24H as "just past midnight". They can no longer share words.
                    Item { Layout.fillWidth: true; Layout.preferredHeight: 12 }
                    RowLayout {
                        Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16
                        spacing: 8
                        Rectangle {
                            implicitWidth: wmT.implicitWidth + 12; implicitHeight: 16
                            color: root.selectedDay !== "" ? Theme.accentSoft : "transparent"
                            border.width: 1
                            border.color: root.selectedDay !== "" ? Theme.accent : Theme.info
                            Text {
                                id: wmT; anchors.centerIn: parent
                                text: root.selectedDay !== "" ? qsTr("CALENDAR DAY") : qsTr("ROLLING")
                                color: root.selectedDay !== "" ? Theme.accent : Theme.info
                                font.family: Theme.fontMono; font.pixelSize: 8
                                font.letterSpacing: 1.2; font.weight: Font.DemiBold
                            }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: root.frags.length === 0 ? "—"
                                : (root.selectedDay !== ""
                                   ? Qt.formatDate(new Date(root.winStartMs), "d MMM") + " · "
                                     + Settings.clock(root.winStartMs, false) + "–" + Settings.clock(root.winEndMs, false)
                                   : Settings.clock(root.winStartMs, false) + " → " + Settings.clock(root.winEndMs, false))
                            color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 12
                            elide: Text.ElideRight
                        }
                    }
                    Text {
                        Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.topMargin: 4
                        visible: root.frags.length > 0
                        text: root.selectedDay !== ""
                              ? qsTr("Midnight to midnight, clamped to now")
                              : qsTr("Ends now — the far left is %1 at %2")
                                .arg(Qt.formatDate(new Date(root.winStartMs), "ddd d MMM"))
                                .arg(Settings.clock(root.winStartMs, false))
                        color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11
                        wrapMode: Text.WordWrap
                    }
                    Text {
                        Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.topMargin: 2
                        visible: root.frags.length > 0
                        text: qsTr("%1% of the window has footage").arg(root.coveragePct)
                        color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                    }
                    Item { Layout.fillWidth: true; Layout.preferredHeight: 12 }
                    Rectangle { Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.preferredHeight: 1; color: Theme.line }
                    Item { Layout.fillWidth: true; Layout.preferredHeight: 14 }
                    PlaybackCalendar {
                        Layout.fillWidth: true
                        retentionDays: root.retentionDays
                        footageDays: root.footageDays
                        pending: root.coveragePending
                        selectedDate: root.selectedDay
                        onDaySelected: (d) => root.openForDay(d)
                    }

                    // ===== §2.4 ROLL CALL — the aside's one growable child =======
                    // The register in list form. It answers "which cells are lit"
                    // without scanning sixteen pictures, it is the correspondence
                    // map between thin lanes and pictures, and it makes the jump
                    // offer reachable for a camera in the far corner of the wall.
                    // Everything above it is fixed-height, so without it the aside
                    // would end in dead space (the Groups console lesson).
                    Rectangle { Layout.fillWidth: true; Layout.topMargin: 12; Layout.leftMargin: 16
                                Layout.rightMargin: 16; Layout.preferredHeight: 1; color: Theme.line }
                    RowLayout {
                        Layout.fillWidth: true; Layout.topMargin: 12; Layout.leftMargin: 16
                        Layout.rightMargin: 16; Layout.bottomMargin: 6
                        Text {
                            Layout.fillWidth: true; text: qsTr("ROLL CALL")
                            color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 8
                            font.letterSpacing: 1.4; font.weight: Font.DemiBold
                        }
                        Text {
                            text: root.rollCallTally
                            color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 8
                            font.letterSpacing: 1.2
                        }
                    }
                    ListView {
                        id: rollCall
                        Layout.fillWidth: true; Layout.fillHeight: true
                        Layout.leftMargin: 8; Layout.rightMargin: 8; Layout.bottomMargin: 8
                        clip: true
                        model: root.laneList                 // grid reading order
                        boundsBehavior: Flickable.StopAtBounds
                        C.ScrollBar.vertical: C.ScrollBar { }
                        delegate: Rectangle {
                            required property var modelData
                            readonly property string cs: root.cellStateOf(modelData.camId)
                            readonly property bool mo: root.motionNowFor(modelData.camId)
                            width: ListView.view.width; height: 24
                            color: root.hoverCamera === modelData.camId ? Theme.panel2 : "transparent"
                            Row {
                                anchors { left: parent.left; leftMargin: 8; verticalCenter: parent.verticalCenter }
                                spacing: 7
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 7; height: 7
                                    color: parent.parent.cs === "recording" ? Theme.good : "transparent"
                                    border.width: parent.parent.cs === "recording" ? 0 : 1
                                    border.color: Theme.line2
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: {
                                        var c = root.cameraModel ? root.cameraModel.cameraByBackendId(modelData.camId) : null;
                                        var m = /\.(\d+)$/.exec((c && c.ip) || "");
                                        return m ? "." + m[1] : "";
                                    }
                                    color: parent.parent.cs === "recording" ? Theme.ink : Theme.ink2
                                    font.family: Theme.fontMono; font.pixelSize: 11; font.weight: Font.DemiBold
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: parent.parent.mo && parent.parent.cs === "recording" ? qsTr("MOTION")
                                        : parent.parent.cs === "recording" ? qsTr("RECORDING")
                                        : parent.parent.cs === "dormant" ? qsTr("nothing at this instant")
                                        : qsTr("availability unknown")
                                    color: parent.parent.mo && parent.parent.cs === "recording" ? Theme.accent
                                         : parent.parent.cs === "recording" ? Theme.good : Theme.ink3
                                    font.family: Theme.fontMono; font.pixelSize: 9
                                    font.letterSpacing: parent.parent.cs === "recording" ? 1.2 : 0
                                }
                            }
                            Text {
                                anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                                visible: parent.cs === "dormant" && root.nearestFootageMs(modelData.camId) > 0
                                text: root.offerLabelFor(modelData.camId)
                                color: jmpMa.containsMouse ? Theme.accent : Theme.ink3
                                font.family: Theme.fontMono; font.pixelSize: 9
                                MouseArea {
                                    id: jmpMa; anchors.fill: parent; anchors.margins: -4
                                    hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: root.seekToWall(root.nearestFootageMs(modelData.camId))
                                }
                            }
                            HoverHandler { onHoveredChanged: root.hoverCamera = hovered ? modelData.camId : "" }
                        }
                    }
                }
            }
        }

        // ---- master timeline + transport ---------------------------------
        Rectangle {
            // transport (38) + the scrubber's own height + margins. Derived, not a
            // constant: the scrubber is resizable now, and a fixed band would let
            // it overflow the window instead of taking height from the stage —
            // which is exactly the trade §0's density arithmetic asks for.
            Layout.fillWidth: true
            Layout.preferredHeight: 38 + Settings.wallScrubH + 14
            color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; height: 1; color: Theme.line }

            // Wall-wide loading bar — the play-wall analogue of the per-camera tile loading bar
            // (CameraTile.loadBar). The grid is ONE composited stream, so one bar covers the whole
            // wall: an indeterminate sweep while the composite is loading/seeking (a re-composite
            // has no real %, so it sweeps honestly rather than faking progress). Sits at the very
            // top of the transport — directly below the camera wall, above the scrubber — and
            // spans the full width. Hidden the moment frames flow (loading=false) or on an error
            // (the error banner takes over).
            Rectangle {
                id: wallLoadBar
                anchors { left: parent.left; right: parent.right; top: parent.top }
                height: 3
                z: 5
                visible: (root.loading || root.pending || root._settling) && root.errorText === ""
                color: "#141a22"          // dim track (matches CameraTile.loadBar)
                clip: true
                Rectangle {
                    height: parent.height
                    width: parent.width * 0.30
                    color: Theme.accent
                    SequentialAnimation on x {
                        running: wallLoadBar.visible
                        loops: Animation.Infinite
                        NumberAnimation { from: -wallLoadBar.width * 0.30; to: wallLoadBar.width
                            duration: 1100; easing.type: Easing.InOutSine }
                    }
                }
            }

            RowLayout {
                id: tlControls
                anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 16; rightMargin: 16; topMargin: 12 }
                height: 24; spacing: 8
                component Chip: Rectangle {
                    id: chip
                    property string label: ""; property bool active: false
                    property string tip: ""
                    // §2.8 — `ghost` is for a PREFERENCE (the lane toggle), which
                    // gets an underline rather than a fill: filling it would read as
                    // a mode.
                    property bool ghost: false
                    signal clicked()
                    implicitWidth: ct.implicitWidth + 18; implicitHeight: 24
                    color: ghost ? (active ? Theme.accentSoft : "transparent")
                                 : (active ? Theme.accent : "transparent")
                    border.width: 1
                    border.color: (active && !ghost) ? Theme.accent : Theme.line2
                    Text { id: ct; anchors.centerIn: parent; text: parent.label
                        color: (parent.active && !parent.ghost) ? Theme.bg
                             : (parent.active ? Theme.accent : Theme.ink2)
                        font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 0.8; font.capitalization: Font.AllUppercase }
                    Rectangle { visible: parent.ghost && parent.active
                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                        height: 2; color: Theme.accent }
                    MouseArea { id: chMa; anchors.fill: parent; hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor; onClicked: parent.clicked() }
                    C.ToolTip.visible: chMa.containsMouse && chip.tip !== ""
                    C.ToolTip.delay: 400
                    C.ToolTip.text: chip.tip
                }
                Chip {
                    label: player.playbackState === MediaPlayer.PlayingState ? "❚❚" : "▶"
                    onClicked: player.playbackState === MediaPlayer.PlayingState ? player.pause() : player.play()
                }
                Chip { label: qsTr("−10s"); onClicked: player.position = Math.max(0, player.position - 10000) }
                Chip { label: qsTr("+10s"); onClicked: player.position = Math.min(player.duration, player.position + 10000) }
                Chip { label: qsTr("Last hour"); onClicked: root.setViewPreset(60) }
                Chip { label: qsTr("Last 15 min"); onClicked: root.setViewPreset(15) }
                Text { text: root.frags.length ? (Qt.formatDate(new Date(root.playheadMs), "ddd d MMM yyyy") + " · " + root.fmtClock(root.playheadMs)) : ""
                    color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11; Layout.leftMargin: 8 }
                Item { Layout.fillWidth: true }
                // Window presets move the view inside the loaded composite window;
                // they de-highlight once you wheel-zoom into a custom span (then the
                // Custom chip shows the visible span; Fit / 0-key resets).
                // §2.8 — the coverage readout sits with the span controls, because
                // that is where the operator decides whether this window is worth
                // scrubbing at all.
                Text {
                    visible: root.frags.length > 0
                    text: qsTr("%1% of the window has footage").arg(root.coveragePct)
                    color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                }
                Rectangle { visible: root.frags.length > 0; width: 1; height: 16; color: Theme.line2 }
                // Span chips NAME their model in the tooltip — these are rolling
                // windows ending now, and the calendar is the other model.
                Chip { label: "15m"; tip: qsTr("Rolling window — the last 15 min, ending now"); active: root.zoomMin === 15 && root.selectedDay === "" && !root.customZoom; onClicked: root.setViewPreset(15) }
                Chip { label: "1h"; tip: qsTr("Rolling window — the last 1h, ending now"); active: root.zoomMin === 60 && root.selectedDay === "" && !root.customZoom; onClicked: root.setViewPreset(60) }
                Chip { label: "6h"; tip: qsTr("Rolling window — the last 6h, ending now"); active: root.zoomMin === 360 && root.selectedDay === "" && !root.customZoom; onClicked: root.setViewPreset(360) }
                Chip { label: "12h"; tip: qsTr("Rolling window — the last 12h, ending now"); active: root.zoomMin === 720 && root.selectedDay === "" && !root.customZoom; onClicked: root.setViewPreset(720) }
                Chip { label: "24h"; tip: qsTr("Rolling window — the last 24h, ending now"); active: root.zoomMin === 1440 && root.selectedDay === "" && !root.customZoom; onClicked: root.setViewPreset(1440) }
                Chip { visible: root.customZoom; active: true; label: root.fmtSpan(root.viewEndMs - root.viewStartMs); onClicked: root.resetView() }
                Chip { visible: root.customZoom; label: "FIT"; tip: qsTr("Drop the custom zoom back to the loaded window"); onClicked: root.resetView() }
                Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 18; color: Theme.line2 }
                Chip { label: qsTr("Events"); ghost: true; active: Settings.eventsOnScrubber
                    tip: qsTr("Show a motion lane per camera in the scrubber")
                    onClicked: Settings.eventsOnScrubber = !Settings.eventsOnScrubber }
                Chip { visible: root.hasSelection; active: true
                    label: "↥ " + qsTr("Export selection") + " · " + root.fmtSpan(root.selEndMs - root.selStartMs)
                    onClicked: root.exportSelection() }
                Chip { label: qsTr("Return to live"); onClicked: root.returnToLive() }
            }

            // scrub bar — composited footage vs whole-grid gaps + playhead
            Rectangle {
                id: bar
                anchors { left: parent.left; right: parent.right; top: tlControls.bottom; topMargin: 10; leftMargin: 16; rightMargin: 16 }
                // §2.7 — 160px default, resizable 36-420. The scrubber is where the
                // operator WORKS on this screen, and 88px could not hold fourteen
                // lanes above the 7px legibility floor.
                height: Settings.wallScrubH
                color: "#16140f"; border.width: 1; border.color: Theme.line

                // span/x↔ms use the (zoomable) VIEW window, not the full session window
                readonly property double span: Math.max(1, root.viewEndMs - root.viewStartMs)
                function xOf(ms) { return (ms - root.viewStartMs) / span * width }
                function msOf(x) { return root.viewStartMs + (x / width) * span }
                property double pressMs: -1
                property double hoverMs: -1
                property int hoverLane: -1

                // ---- band geometry (§2.7): coverage and ruler are FIXED, and the
                // lanes are the single child that absorbs a resize. Flexing a
                // container whose children are all fixed relocates the void rather
                // than filling it (the Groups console lesson).
                readonly property bool lanesOn: Settings.eventsOnScrubber && root.laneList.length > 0
                readonly property int laneCount: root.laneList.length
                readonly property real coverH: lanesOn ? 14 : height
                readonly property real rulerH: lanesOn ? 15 : 0
                readonly property real laneTop: coverH + rulerH
                readonly property real laneAreaH: Math.max(0, height - laneTop - 2)
                // 7px floor: below it the lane AREA scrolls instead of crushing
                // fourteen cameras into 2px each.
                readonly property real laneH: (lanesOn && laneCount > 0)
                    ? Math.max(7, Math.floor(laneAreaH / laneCount)) : 0
                readonly property real laneContentH: laneH * laneCount
                readonly property bool hasWarming: {
                    for (var i = 0; i < root.frags.length; i++)
                        if (root.frags[i].avail !== "ready"
                            && root.frags[i].we >= root.viewStartMs && root.frags[i].ws <= root.viewEndMs) return true;
                    return false;
                }
                // Ruler ticks derived from the visible span, so the label density
                // stays readable from 15 minutes to 35 days.
                readonly property var tickList: {
                    var sp = span, out = [];
                    if (sp <= 0 || width <= 0) return out;
                    var steps = [10000, 30000, 60000, 300000, 900000, 1800000, 3600000,
                                 10800000, 21600000, 43200000, 86400000];
                    var step = steps[steps.length - 1];
                    for (var i = 0; i < steps.length; i++)
                        if (sp / steps[i] <= Math.max(4, width / 90)) { step = steps[i]; break; }
                    var t = Math.ceil(root.viewStartMs / step) * step;
                    var n = 0;
                    while (t <= root.viewEndMs && n < 400) {
                        out.push({ ms: t, major: (t % (step * 2)) === 0 || step >= 3600000 });
                        t += step; n++;
                    }
                    return out;
                }
                // §2.7 — the grip STRADDLES the top edge (it is positioned outside
                // the bar), so it costs 0px of picture at rest. A 5px band inside
                // the bar would spend picture on chrome.
                MouseArea {
                    id: grip
                    z: 40
                    anchors { left: parent.left; right: parent.right }
                    y: -4; height: 8
                    cursorShape: Qt.SizeVerCursor
                    property real pressY: 0
                    property int pressH: 0
                    onPressed: (m) => { pressY = m.y; pressH = Settings.wallScrubH }
                    onPositionChanged: (m) => {
                        if (!pressed) return;
                        Settings.wallScrubH = pressH - Math.round(m.y - pressY);
                    }
                    onDoubleClicked: Settings.wallScrubH = 160
                    Rectangle {
                        anchors.centerIn: parent
                        width: 44; height: 3
                        visible: grip.containsMouse || grip.pressed
                        color: Theme.accent
                    }
                    hoverEnabled: true
                }
                // merge a camera's motion spans by ~2px gap so a busy lane reads as a
                // band, not a thousand hairlines; clipped to the visible view window.
                function laneSpans(camId) {
                    var raw = root.motionByCam[camId];
                    if (!raw || raw.length === 0) return [];
                    var vs = root.viewStartMs, ve = root.viewEndMs, w = width, sp = ve - vs;
                    if (sp <= 0 || w <= 0) return [];
                    var minGap = (2 / w) * sp, out = [], cur = null;
                    for (var i = 0; i < raw.length; i++) {
                        var e = raw[i];
                        if (e.endMs < vs || e.startMs > ve) continue;
                        var s = Math.max(e.startMs, vs), en = Math.min(e.endMs, ve);
                        var it = (e.intensity === undefined) ? 1 : e.intensity;
                        if (cur && s - cur.eMs <= minGap) { cur.eMs = Math.max(cur.eMs, en); cur.it = Math.max(cur.it, it); }
                        else { if (cur) out.push({ sMs: cur.sMs, eMs: cur.eMs, it: cur.it }); cur = { sMs: s, eMs: en, it: it }; }
                    }
                    if (cur) out.push({ sMs: cur.sMs, eMs: cur.eMs, it: cur.it });
                    return out;
                }

                // footage coverage strip (whole-grid composited) — the scrub track
                Repeater {
                    model: root.frags
                    delegate: Rectangle {
                        x: bar.xOf(modelData.ws); width: Math.max(1, bar.xOf(modelData.we) - bar.xOf(modelData.ws))
                        y: 0; height: bar.coverH
                        color: modelData.avail === "ready" ? "#3f5a2a" : "#4a4327"   // ready vs warming
                    }
                }
                Rectangle { visible: bar.lanesOn; x: 0; y: bar.coverH; width: bar.width; height: 1; color: Theme.line }

                // ---- WARMING label (§2.7) — the compositor has not rendered this
                // stretch yet. A first-class colour, never a spinner and never a gap.
                Rectangle {
                    visible: bar.hasWarming
                    x: bar.width - wrmT.implicitWidth - 12; y: 1
                    width: wrmT.implicitWidth + 10; height: 12
                    color: "#4a4327"
                    Text { id: wrmT; anchors.centerIn: parent; text: qsTr("WARMING")
                        color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 8; font.letterSpacing: 1.2 }
                }

                // ---- ruler (§2.7) — span-derived ticks + hh:mm ----------------
                Item {
                    visible: bar.lanesOn
                    x: 0; y: bar.coverH + 1; width: bar.width; height: bar.rulerH - 1
                    clip: true
                    Repeater {
                        model: bar.tickList
                        delegate: Item {
                            required property var modelData
                            x: bar.xOf(modelData.ms); width: 1; height: parent.height
                            Rectangle { width: 1; height: modelData.major ? 5 : 3; color: Theme.line2 }
                            Text {
                                visible: modelData.major
                                x: 3; y: 1
                                text: Settings.clock(modelData.ms, false)
                                color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9
                            }
                        }
                    }
                }

                // ---- per-camera motion lanes (grid reading order) ----
                Flickable {
                    id: laneFlick
                    visible: bar.lanesOn
                    x: 0; y: bar.laneTop; width: bar.width; height: bar.laneAreaH
                    clip: true
                    contentHeight: bar.laneContentH
                    boundsBehavior: Flickable.StopAtBounds
                    // The scrubber's own MouseArea sits above this and takes drags
                    // (they mark In->Out), so flicking here would never fire. The
                    // scrollbar is left interactive and Ctrl+wheel drives contentY —
                    // both are reachable, which a bare Flickable under a full-bleed
                    // MouseArea is not.
                    interactive: false
                    Item {
                        width: bar.width; height: bar.laneContentH
                        Repeater {
                            model: root.laneList
                            delegate: Item {
                                id: lane
                                required property int index
                                required property var modelData
                                readonly property string camId: modelData.camId
                                readonly property bool hot: root.hoverCamera === camId
                                // §2.7 — a lane whose camera contributes NOTHING to
                                // this window takes a faint bad hatch: the lane
                                // equivalent of a dormant cell, so "this camera has
                                // no footage here" reads in both places.
                                readonly property bool barren: bar.laneSpans(camId).length === 0
                                y: lane.index * bar.laneH; width: bar.width; height: bar.laneH
                                Rectangle { anchors.fill: parent; visible: lane.index % 2 === 0; color: Qt.rgba(1, 1, 1, 0.022) }
                                Item {                                   // barren hatch
                                    anchors.fill: parent; visible: lane.barren; clip: true; opacity: 0.30
                                    Repeater {
                                        model: Math.ceil(bar.width / 10) + 2
                                        delegate: Rectangle {
                                            required property int index
                                            width: 2; height: lane.height * 2.2; color: Theme.bad
                                            transformOrigin: Item.Center; rotation: 45
                                            x: index * 10 - lane.height
                                            y: (lane.height - height) / 2
                                        }
                                    }
                                }
                                Rectangle { anchors.fill: parent; visible: lane.hot; color: Theme.accentSoft }   // shared hoverCamera
                                // lane label appears once the lane can carry it (§2.7)
                                Text {
                                    visible: bar.laneH >= 11
                                    x: 3; anchors.verticalCenter: parent.verticalCenter
                                    text: {
                                        var c = root.cameraModel ? root.cameraModel.cameraByBackendId(lane.camId) : null;
                                        var m = /\.(\d+)$/.exec((c && c.ip) || "");
                                        return m ? "." + m[1] : "";
                                    }
                                    color: lane.hot ? Theme.ink2 : Theme.ink3
                                    font.family: Theme.fontMono; font.pixelSize: 8
                                }
                                Repeater {
                                    model: bar.laneSpans(lane.camId)
                                    delegate: Rectangle {
                                        required property var modelData
                                        x: Math.max(0, bar.xOf(modelData.sMs))
                                        width: Math.max(2, bar.xOf(modelData.eMs) - bar.xOf(modelData.sMs))
                                        height: Math.max(2, Math.min(lane.height - 1, 6))
                                        y: (lane.height - height) / 2
                                        color: Theme.accent
                                        opacity: 0.45 + 0.45 * modelData.it
                                    }
                                }
                            }
                        }
                    }
                }

                // In/Out selection (full bar height)
                Rectangle {
                    visible: root.hasSelection
                    x: bar.xOf(root.selStartMs); width: Math.max(1, bar.xOf(root.selEndMs) - bar.xOf(root.selStartMs))
                    y: 0; height: parent.height
                    color: Theme.accentSoft; border.width: 1; border.color: Theme.accent
                }
                // playhead — vertical stick + diamond knob (one element), full height
                Rectangle {
                    visible: root.frags.length > 0
                    width: 2; height: parent.height; color: "#fff"
                    x: bar.xOf(root.playheadMs) - 1
                    Rectangle { anchors.horizontalCenter: parent.horizontalCenter; anchors.top: parent.top; width: 7; height: 7; rotation: 45; color: "#fff" }
                }
                // hover scrub guide
                Rectangle {
                    visible: bar.hoverMs >= 0 && root.frags.length > 0
                    width: 1; height: parent.height; color: Theme.ink3
                    x: bar.xOf(bar.hoverMs)
                }
                // sticky hover tooltip — the exact wall-clock time under the cursor
                Rectangle {
                    visible: bar.hoverMs >= 0 && root.frags.length > 0
                    readonly property real hx: bar.xOf(bar.hoverMs)
                    width: wTip.implicitWidth + 14; height: 20
                    x: Math.max(0, Math.min(bar.width - width, hx - width / 2)); y: 2
                    color: Qt.rgba(0, 0, 0, 0.9); border.width: 1; border.color: Theme.line2
                    // §2.7 — the WEEKDAY rides the tooltip for the same reason the
                    // clock carries the date: a rolling window crosses midnight by
                    // construction, so a bare time is ambiguous.
                    Text { id: wTip; anchors.centerIn: parent
                        text: {
                            var pre = "";
                            if (root.hoverCamera !== "") {
                                var c = root.cameraModel ? root.cameraModel.cameraByBackendId(root.hoverCamera) : null;
                                var m = /\.(\d+)$/.exec((c && c.ip) || "");
                                if (m) pre = "." + m[1] + " · ";
                            }
                            return pre + Qt.formatDate(new Date(bar.hoverMs), "ddd") + " " + root.fmtClock(bar.hoverMs);
                        }
                        color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 11 }
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: root.frags.length > 0
                    hoverEnabled: true
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onPositionChanged: (m) => {
                        bar.hoverMs = bar.msOf(m.x);
                        var ly = m.y - bar.laneTop;          // which camera lane is under the cursor
                        bar.hoverLane = (bar.lanesOn && ly >= 0 && ly < bar.laneAreaH && bar.laneH > 0)
                            ? Math.min(root.laneList.length - 1, Math.floor((ly + laneFlick.contentY) / bar.laneH)) : -1;
                        // The shared hoverCamera MUST be set from here. A HoverHandler
                        // on each lane never fires: this MouseArea is hoverEnabled and
                        // sits above the lane Flickable, so it consumes hover before
                        // the lanes see it — the correspondence silently did nothing.
                        root.hoverCamera = (bar.hoverLane >= 0 && bar.hoverLane < root.laneList.length)
                            ? root.laneList[bar.hoverLane].camId : "";
                        if (pressed && bar.pressMs >= 0) {     // dragging → tentative selection
                            var a = Math.min(bar.pressMs, bar.hoverMs), b = Math.max(bar.pressMs, bar.hoverMs);
                            root.selStartMs = a; root.selEndMs = b;
                        }
                    }
                    onExited: { bar.hoverMs = -1; bar.hoverLane = -1; root.hoverCamera = ""; }
                    onPressed: (m) => { bar.pressMs = bar.msOf(m.x); root.selStartMs = -1; root.selEndMs = -1; }
                    onReleased: (m) => {
                        var cur = bar.msOf(m.x);
                        // small movement = a click (seek); a real drag = clip selection
                        if (Math.abs(cur - bar.pressMs) < bar.span / bar.width * 4) {
                            root.selStartMs = -1; root.selEndMs = -1;
                            root.seekToWall(cur);
                        }
                        bar.pressMs = -1;
                    }
                    // mouse-wheel: zoom on the cursor; Shift+wheel pans (Premiere-style)
                    onWheel: (w) => {
                        // Ctrl+wheel scrolls the LANE AREA. It needs its own modifier
                        // because this MouseArea sits above the lane Flickable and
                        // takes every wheel event first — so the Flickable added for
                        // the 7px-floor overflow was unreachable by wheel OR drag,
                        // i.e. a scroll region that could not be scrolled. Ctrl keeps
                        // the unmodified wheel on zoom, which is the gesture the
                        // operator actually came for.
                        if ((w.modifiers & Qt.ControlModifier) && bar.lanesOn
                            && bar.laneContentH > bar.laneAreaH) {
                            var maxY = bar.laneContentH - bar.laneAreaH;
                            laneFlick.contentY = Math.max(0, Math.min(maxY,
                                laneFlick.contentY - (w.angleDelta.y > 0 ? 1 : -1) * bar.laneH * 2));
                            return;
                        }
                        if (w.modifiers & Qt.ShiftModifier) {
                            var d = (w.angleDelta.y > 0 ? -1 : 1) * bar.span * 0.15;
                            var ps = root.viewStartMs + d, pe = root.viewEndMs + d;
                            if (ps < root.winStartMs) { ps = root.winStartMs; pe = ps + bar.span; }
                            if (pe > root.winEndMs) { pe = root.winEndMs; ps = pe - bar.span; }
                            root.viewStartMs = ps; root.viewEndMs = pe;
                            return;
                        }
                        var atMs = bar.msOf(w.x);
                        var factor = w.angleDelta.y > 0 ? 0.8 : 1.25;   // up = zoom in
                        var newSpan = Math.max(5000, Math.min(root.winEndMs - root.winStartMs, bar.span * factor));
                        var leftFrac = (atMs - root.viewStartMs) / bar.span;
                        var ns = atMs - leftFrac * newSpan;
                        var ne = ns + newSpan;
                        if (ns < root.winStartMs) { ns = root.winStartMs; ne = ns + newSpan; }
                        if (ne > root.winEndMs) { ne = root.winEndMs; ns = ne - newSpan; }
                        root.viewStartMs = Math.max(root.winStartMs, ns);
                        root.viewEndMs = Math.min(root.winEndMs, ne);
                        root.customZoom = true;   // free-form zoom → de-highlight presets, show Fit
                    }
                }
                // Lane scrollbar. Declared AFTER the scrub MouseArea and given a z
                // above it: attached to the Flickable it rendered behind that
                // full-bleed MouseArea and could never be grabbed — visible, inert,
                // exactly the silent no-op the house rules forbid.
                C.ScrollBar {
                    id: laneSb
                    z: 30
                    visible: bar.lanesOn && bar.laneContentH > bar.laneAreaH
                    orientation: Qt.Vertical
                    policy: C.ScrollBar.AlwaysOn
                    interactive: true
                    x: bar.width - width; y: bar.laneTop
                    height: bar.laneAreaH
                    size: bar.laneAreaH / Math.max(1, bar.laneContentH)
                    position: laneFlick.contentY / Math.max(1, bar.laneContentH)
                    onPositionChanged: if (pressed) laneFlick.contentY = position * bar.laneContentH
                }

                // IN→OUT readout — floats over the lanes only while a selection exists
                Rectangle {
                    visible: root.frags.length > 0 && root.hasSelection
                    anchors { left: parent.left; bottom: parent.bottom; margins: 4 }
                    width: selT.implicitWidth + 12; height: 16
                    color: Qt.rgba(0, 0, 0, 0.82); border.width: 1; border.color: Theme.line2
                    // §2.7 — a selection that crosses a stretch where some camera has
                    // no footage is still a valid export; the operator simply must
                    // not be surprised when four of fourteen clips come back short.
                    // So it is NAMED before the export, not discovered after it.
                    Text { id: selT; anchors.centerIn: parent
                        text: qsTr("IN ") + root.fmtClock(root.selStartMs) + " → OUT " + root.fmtClock(root.selEndMs)
                              + " · " + root.fmtSpan(root.selEndMs - root.selStartMs)
                              + (root.selectionSpansGap ? " · " + qsTr("spans a gap — some cameras have no footage inside it") : "")
                        color: Theme.accent; font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 0.6 }
                }
            }
        }
    }
    // ---- camera picker: assign any ≤16 roster cameras to the wall ----------
    Rectangle {
        visible: root.pickerOpen
        anchors.fill: parent
        z: 60
        color: Qt.rgba(0, 0, 0, 0.55)
        MouseArea { anchors.fill: parent; onClicked: root.pickerOpen = false }
        Rectangle {
            anchors.centerIn: parent
            width: 460; height: Math.min(600, parent.height - 60)
            color: Theme.panel; border.width: 1; border.color: Theme.line2
            MouseArea { anchors.fill: parent; onClicked: {} }    // swallow backdrop clicks
            ColumnLayout {
                anchors.fill: parent; anchors.margins: 14; spacing: 10
                RowLayout {
                    Layout.fillWidth: true
                    ColumnLayout {
                        spacing: 1; Layout.fillWidth: true
                        Text { text: qsTr("Assign cameras"); color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 15; font.weight: Font.DemiBold }
                        Text { text: qsTr("The wall re-composites at the current moment"); color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11 }
                    }
                    Text { text: root.pickerCount + " / 16"; color: root.pickerCount >= 16 ? Theme.accent : Theme.ink3
                        font.family: Theme.fontMono; font.pixelSize: 13; font.weight: Font.DemiBold }
                }
                // search
                Rectangle {
                    Layout.fillWidth: true; implicitHeight: 32
                    color: Theme.bg; border.width: 1
                    border.color: pickInput.activeFocus ? Theme.accent : Theme.line2
                    TextInput {
                        id: pickInput
                        anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                        verticalAlignment: TextInput.AlignVCenter
                        color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12
                        clip: true
                        onTextChanged: root.pickSearch = text
                        Connections { target: root; function onPickerOpenChanged() { if (root.pickerOpen) { pickInput.text = ""; pickInput.forceActiveFocus() } } }
                    }
                    Text {
                        visible: pickInput.text === ""
                        anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; anchors.leftMargin: 10
                        text: qsTr("Search name, IP or group…"); color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12
                    }
                }
                // roster checklist
                ListView {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    clip: true
                    model: root.pickerRows
                    spacing: 2
                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool on: root.pickIds[modelData.camId] === true
                        width: ListView.view ? ListView.view.width : 0
                        height: 42
                        color: prMa.containsMouse ? Theme.panel2 : "transparent"
                        Rectangle {   // checkbox
                            id: prBox
                            anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter
                            width: 14; height: 14
                            color: parent.on ? Theme.accent : "transparent"
                            border.width: 1; border.color: parent.on ? Theme.accent : Theme.ink3
                            Text { anchors.centerIn: parent; visible: parent.parent.on; text: "✓"; color: Theme.bg; font.pixelSize: 10; font.weight: Font.Bold }
                        }
                        Column {
                            anchors.left: prBox.right; anchors.leftMargin: 10; anchors.right: parent.right; anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1
                            Text { text: modelData.name; color: parent.parent.on ? Theme.ink : Theme.ink2
                                font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium
                                elide: Text.ElideRight; width: parent.width }
                            Text { text: modelData.ip + (modelData.groupName ? "  ·  " + modelData.groupName : "")
                                color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                                elide: Text.ElideRight; width: parent.width }
                        }
                        MouseArea { id: prMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: root.togglePick(modelData.camId) }
                    }
                }
                // footer actions
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    Rectangle {
                        implicitWidth: plT.implicitWidth + 18; implicitHeight: 28
                        color: "transparent"; border.width: 1; border.color: plMa.containsMouse ? Theme.ink3 : Theme.line2
                        Text { id: plT; anchors.centerIn: parent; text: qsTr("Use live wall"); color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12 }
                        MouseArea { id: plMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: { Settings.clearWallLayout(); root.pickerOpen = false; root.resetToLiveRequested() } }
                    }
                    Text {
                        text: root.pickerCount === 0 ? "Pick at least one camera" : ""
                        color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11
                        Layout.fillWidth: true
                    }
                    Rectangle {
                        implicitWidth: pcT.implicitWidth + 22; implicitHeight: 28
                        color: "transparent"; border.width: 1; border.color: pcMa.containsMouse ? Theme.ink3 : Theme.line2
                        Text { id: pcT; anchors.centerIn: parent; text: qsTr("Cancel"); color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12 }
                        MouseArea { id: pcMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.pickerOpen = false }
                    }
                    Rectangle {
                        readonly property bool enabled: root.pickerCount > 0
                        implicitWidth: paT.implicitWidth + 22; implicitHeight: 28
                        color: enabled ? (paMa.containsMouse ? Qt.lighter(Theme.accent, 1.1) : Theme.accent) : Theme.panel2
                        Text { id: paT; anchors.centerIn: parent
                            text: qsTr("Apply · ") + root.pickerCount + (root.pickerCount === 1 ? " camera" : " cameras")
                            color: parent.enabled ? Theme.bg : Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
                        MouseArea { id: paMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: parent.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: if (parent.enabled) root.applyPick() }
                    }
                }
            }
        }
    }

    // ---- per-cell camera picker: right-click a tile → choose its camera ------
    Rectangle {
        visible: root.cellPickerSlot >= 0
        anchors.fill: parent
        z: 62
        color: Qt.rgba(0, 0, 0, 0.55)
        MouseArea { anchors.fill: parent; onClicked: root.cellPickerSlot = -1 }
        Rectangle {
            anchors.centerIn: parent
            width: 460; height: Math.min(580, parent.height - 60)
            color: Theme.panel; border.width: 1; border.color: Theme.line2
            MouseArea { anchors.fill: parent; onClicked: {} }    // swallow backdrop clicks
            ColumnLayout {
                anchors.fill: parent; anchors.margins: 14; spacing: 10
                ColumnLayout {
                    spacing: 1; Layout.fillWidth: true
                    Text { text: qsTr("Choose camera for this tile"); color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 15; font.weight: Font.DemiBold }
                    Text {
                        readonly property var _cur: root.cellPickerSlot >= 0 ? root.cellAtSlot(root.cellPickerSlot) : null
                        readonly property var _cam: _cur ? (root.cameraModel ? root.cameraModel.cameraByBackendId(_cur.camera_id) : null) : null
                        Layout.fillWidth: true; elide: Text.ElideRight
                        text: qsTr("Replaces ") + (_cam && _cam.name ? _cam.name : (_cur ? _cur.camera_id : "")) + " · the wall re-composites"
                        color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11
                    }
                }
                Rectangle {
                    Layout.fillWidth: true; implicitHeight: 32
                    color: Theme.bg; border.width: 1; border.color: cpInput.activeFocus ? Theme.accent : Theme.line2
                    TextInput {
                        id: cpInput
                        anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                        verticalAlignment: TextInput.AlignVCenter; clip: true
                        color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12
                        onTextChanged: root.cellPickerSearch = text
                        Connections { target: root; function onCellPickerSlotChanged() { if (root.cellPickerSlot >= 0) { cpInput.text = ""; cpInput.forceActiveFocus() } } }
                    }
                    Text { visible: cpInput.text === ""; anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; anchors.leftMargin: 10
                        text: qsTr("Search name, IP or group…"); color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12 }
                }
                ListView {
                    Layout.fillWidth: true; Layout.fillHeight: true; clip: true
                    model: root.cellPickerRows; spacing: 2
                    delegate: Rectangle {
                        required property var modelData
                        readonly property bool onWall: {
                            for (var i = 0; i < root.cameras.length; i++) if (root.cameras[i].camId === modelData.camId) return true;
                            return false;
                        }
                        width: ListView.view ? ListView.view.width : 0
                        height: 42
                        color: cpRowMa.containsMouse ? Theme.panel2 : "transparent"
                        Column {
                            anchors.left: parent.left; anchors.leftMargin: 12; anchors.right: onTag.left; anchors.rightMargin: 10
                            anchors.verticalCenter: parent.verticalCenter; spacing: 1
                            Text { text: modelData.name; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium; elide: Text.ElideRight; width: parent.width }
                            Text { text: modelData.ip + (modelData.groupName ? "  ·  " + modelData.groupName : ""); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10; elide: Text.ElideRight; width: parent.width }
                        }
                        Text { id: onTag; visible: parent.onWall; anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                            text: qsTr("ON WALL"); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 0.6 }
                        MouseArea { id: cpRowMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: root.setSlotCamera(root.cellPickerSlot, modelData) }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        implicitWidth: ccT.implicitWidth + 22; implicitHeight: 28
                        color: "transparent"; border.width: 1; border.color: ccMa.containsMouse ? Theme.ink3 : Theme.line2
                        Text { id: ccT; anchors.centerIn: parent; text: qsTr("Cancel"); color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12 }
                        MouseArea { id: ccMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.cellPickerSlot = -1 }
                    }
                }
            }
        }
    }

    // ---- WT_WALLPERF: synchronized-wall seek / re-composite latency harness ----
    // Measures, per playhead move, the time from issuing the move to the composited
    // grid playing again (all 16 cells advance one frame). Small offsets are in-stream
    // seeks within one loaded window; ±1d/±2d re-open the session (the real "navigate
    // far" path). Emits CSV "WALLPERF,..." lines. WT_WALLPERF=1 = full (20×), =quick =
    // 2× smoke. Needs a real GPU — frames don't decode under QT_QPA_PLATFORM=offscreen.
    Item {
        id: perf
        readonly property bool active: (typeof wtWallPerf !== "undefined") && wtWallPerf !== ""
        readonly property int iters: (active && wtWallPerf === "quick") ? 2 : 20
        property int frames: 0
        property var plan: []
        property int stepIndex: -1
        property var step: null
        property bool waiting: false
        property bool reopenPending: false
        property double actionT: 0
        property int framesAtAction: 0
        property double targetPos: 0
        property string phase: "idle"            // idle | warmup | run | done
        property double baseSmall: 0
        property double baseBig: 0

        function _now() { return Date.now(); }
        function _iso(ms) { return new Date(ms).toISOString(); }

        Component.onCompleted: if (perf.active) startTimer.start()
        Timer { id: startTimer; interval: 6000; onTriggered: perf._begin() }

        function _begin() {
            if (!root.cameraModel || !root.client) { startTimer.restart(); return; }
            var cams = root.cameraModel.page("", "", "ip", 1, 16), out = [];
            for (var i = 0; i < cams.length && out.length < 16; i++) if (cams[i] && cams[i].camId) out.push(cams[i]);
            if (out.length === 0) { startTimer.restart(); return; }
            root.cameras = out;
            var now = perf._now();
            perf.baseSmall = now - 4 * 3600000;               // in-stream anchor (recent footage)
            perf.baseBig = now - 2 * 86400000 - 1800000;      // re-open anchor (base+2d ≤ now)
            perf.plan = perf._buildPlan();
            console.log("WALLPERF,META,cams=" + out.length + ",iters=" + perf.iters
                + ",baseSmall=" + perf._iso(perf.baseSmall) + ",baseBig=" + perf._iso(perf.baseBig)
                + ",steps=" + perf.plan.length);
            perf.phase = "warmup";
            perf.waiting = true; perf.actionT = perf._now(); perf.framesAtAction = perf.frames;
            perf.targetPos = 0; perf.reopenPending = true;
            timeoutTimer.restart();
            root._open(perf.baseSmall - 3600000, perf.baseSmall + 5 * 3600000);   // 6h in-stream window
        }

        function _buildPlan() {
            var inStream = [10, 30, 60, 120], reopen = [1440, 2880], p = [];
            for (var a = 0; a < inStream.length; a++) {
                var O = inStream[a] * 60000;
                for (var i = 1; i <= perf.iters; i++) {
                    p.push({ kind: "seek", offMin: inStream[a], dir: qsTr("FF"), iter: i, toMs: perf.baseSmall + O });
                    p.push({ kind: "seek", offMin: inStream[a], dir: qsTr("RW"), iter: i, toMs: perf.baseSmall });
                }
            }
            for (var b = 0; b < reopen.length; b++) {
                var Ob = reopen[b] * 60000;
                for (var j = 1; j <= perf.iters; j++) {
                    p.push({ kind: "reopen", offMin: reopen[b], dir: qsTr("FF"), iter: j, toMs: perf.baseBig + Ob });
                    p.push({ kind: "reopen", offMin: reopen[b], dir: qsTr("RW"), iter: j, toMs: perf.baseBig });
                }
            }
            return p;
        }

        function _exec() {
            perf.step = perf.plan[perf.stepIndex];
            perf.waiting = true; perf.actionT = perf._now(); perf.framesAtAction = perf.frames;
            timeoutTimer.restart();
            if (perf.step.kind === "seek") {
                perf.reopenPending = false;
                root.seekToWall(perf.step.toMs);
                perf.targetPos = player.position;
            } else {
                perf.reopenPending = true; perf.targetPos = 0;
                root._open(perf.step.toMs, perf.step.toMs + 3600000);
            }
        }

        function _next() {
            perf.stepIndex++;
            if (perf.stepIndex >= perf.plan.length) {
                console.log("WALLPERF,DONE,total=" + perf.plan.length);
                perf.phase = "done"; quitTimer.start(); return;
            }
            perf._exec();
        }

        function _onSessionReady() { if (perf.reopenPending) perf.reopenPending = false; }
        function _onSessionFailed(err) { if (perf.waiting) perf._record("FAIL"); }

        function _check() {
            if (!perf.waiting || perf.reopenPending) return;
            if (perf.frames >= perf.framesAtAction + 2 && player.position > perf.targetPos + 60)
                perf._record("OK");
        }

        function _record(status) {
            var lat = perf._now() - perf.actionT;
            timeoutTimer.stop(); perf.waiting = false;
            var isReopen = (perf.step && perf.step.kind === "reopen");
            // let a re-composite settle longer before the next move so rapid session
            // teardown/create churn doesn't poison the following measurement.
            settleTimer.interval = (perf.phase === "warmup") ? 1500 : (isReopen ? 2500 : 700);
            if (perf.phase === "warmup") {
                console.log("WALLPERF,WARMUP," + status + "," + lat + "ms,frames=" + perf.frames);
                perf.phase = "run"; settleTimer.restart(); return;
            }
            var s = perf.step;
            console.log("WALLPERF," + s.kind + "," + s.offMin + "," + s.dir + "," + s.iter + ","
                + lat + "," + status + ",pos=" + Math.round(player.position) + ",frames=" + perf.frames);
            settleTimer.restart();
        }

        Connections { target: vout.videoSink; enabled: perf.active
            function onVideoFrameChanged(f) { perf.frames++; perf._check(); } }
        Timer { id: timeoutTimer; interval: 22000; onTriggered: if (perf.waiting) perf._record("TIMEOUT") }
        Timer { id: settleTimer; interval: 700; onTriggered: perf._next() }
        Timer { id: quitTimer; interval: 1500; onTriggered: Qt.quit() }
    }
}
