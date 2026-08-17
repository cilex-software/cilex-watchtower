import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C
import Watchtower

// Live Monitor (design §14): grid of live tiles with a layout segmented control,
// filter pills, status-first sort, manual paging, and a full-screen variant.
// View state is owned by the shell and passed in; this screen requests changes.
Item {
    id: root

    property var cameraModel: null
    property var eventModel: null        // for the "Recent events" filter (recent activity)
    property string layout: "16"         // canonical layout id (see LayoutSpec)
    property int page: 1
    property string statusFilter: ""
    property string sortMode: "live"      // live cameras first (offline last); see CameraModel
    property string groupId: ""
    property string groupLabel: qsTr("All cameras")
    property bool fullscreen: false

    signal layoutRequested(string id)
    signal pageRequested(int p)
    signal statusFilterRequested(string f)
    signal sortRequested(string s)
    signal fullscreenToggled()
    signal saveViewRequested()
    signal snapshotSaved(string path, string camName)
    signal cameraOpened(var cam)
    signal cameraOpenedNewTab(var cam)        // tile action "Open in new tab" → a view tab
    signal cameraPlaybackRequested(var cam)
    signal cameraIssueRequested(var cam)      // VIEW ISSUE on a tile → Health screen, camera selected
    signal wallPlaybackRequested()
    signal groupRequested(string groupId, string label)   // quick group switch from the header
    signal hdLimitReached()                               // a tile asked for HD past the cap

    // HD (main-stream) promotion budget. The wall renders every tile in SD by
    // default; each per-tile SD→HD promotion spins up a go2rtc HEVC→H.264
    // transcode, so concurrent HD tiles are capped to keep go2rtc out of its
    // memory cgroup under heavy wall use (backend-requested ~6). A promotion past
    // the cap is blocked with a hint; demotions and page changes free the budget.
    readonly property int hdCap: 6
    property int hdCount: 0
    // HD promotion gate, centralized + headless-testable (qml/HdCapTest.qml).
    // Pass the tile's current HD state; returns the state it should adopt. A
    // demotion always frees a slot; a promotion consumes one when under the cap,
    // otherwise it is blocked (tile stays SD) and hdLimitReached() fires the hint.
    function requestHdPromotion(currentlyOn) {
        if (currentlyOn) { hdCount = Math.max(0, hdCount - 1); return false; }
        if (hdCount < hdCap) { hdCount = hdCount + 1; return true; }
        hdLimitReached();
        return false;
    }
    // Release a tile's slot when it is torn down (paging/relayout).
    function releaseHd(wasOn) { if (wasOn) hdCount = Math.max(0, hdCount - 1); }

    // qsTr("All cameras") + every backend group, for the header group switcher. Reads
    // cameraModel.total so it re-evaluates when the roster/groups (re)load.
    // The count is groupList()'s `total`, which is computed from OUR roster —
    // never the backend's /groups camera_count, which counts cameras this client
    // cannot see (2026-08-10: /groups said Inside 26 · Снаружи 17 where the
    // roster holds 22 · 14). A dropdown must not promise cameras the wall can't
    // show. Zero is a real answer and is rendered as one: an empty group used to
    // look identical to a group of 22 until you clicked it.
    readonly property var groupOpts: {
        var out = [{ id: "", name: qsTr("All cameras"), count: cameraModel ? cameraModel.total : 0 }];
        if (cameraModel) {
            cameraModel.total;   // refresh dependency
            var gs = cameraModel.groupList();
            for (var i = 0; i < gs.length; i++)
                out.push({ id: gs[i].id, name: gs[i].name, count: gs[i].total });
        }
        return out;
    }

    // Layout geometry derived from the canonical id. lcells is the shared cell
    // enumeration (big tile first, then row-major) that both the toolbar/preset
    // pictograms and the live grid placement use, so a tile is always an exact
    // net of the wall. perPage = number of camera tiles the layout shows.
    readonly property var lspec: LayoutSpec.params(layout)
    readonly property int cols: lspec.cols
    readonly property int rows: lspec.rows

    // ---- Merged cells (cell spans) — operator-created big tiles ---------------
    // A span set turns the page into a FIXED net (like the plus4/center13 feature
    // layouts): {cols, rows, regions:[{c,r,cw,ch}]}, persisted per (group, layout)
    // beside the manual arrangement — so Saved Views and the CW-05 crash restore
    // carry merges for free. The grid dims are CAPTURED at first merge from the
    // grid the operator was actually looking at (the auto-fit net), so a merge
    // means what it meant on screen, not what the layout id implies.
    property int spansRev: 0
    readonly property var spanState: {
        spansRev;
        if (isFeatureLayout) return null;              // feature layouts keep their fixed big tile
        var raw = Settings.liveSpans(groupId, layout);
        if (raw === "") return null;
        try {
            var s = JSON.parse(raw);
            return (s && s.cols > 0 && s.rows > 0 && s.regions && s.regions.length > 0) ? s : null;
        } catch (e) { return null; }
    }
    readonly property bool hasSpans: spanState !== null
    // Row-major cell enumeration with merged regions emitted at their anchor
    // (top-left) scan position — so the camera that was in the anchor cell is the
    // one that fills the merged tile, with no reflow surprises.
    function _spanCells(s) {
        var covered = ({}), regionAt = ({});
        for (var i = 0; i < s.regions.length; i++) {
            var g = s.regions[i];
            regionAt[g.c + "," + g.r] = g;
            for (var c = g.c; c < g.c + g.cw; c++)
                for (var r = g.r; r < g.r + g.ch; r++)
                    covered[c + "," + r] = true;
        }
        var out = [];
        for (var rr = 0; rr < s.rows; rr++)
            for (var cc = 0; cc < s.cols; cc++) {
                var reg = regionAt[cc + "," + rr];
                if (reg) out.push({ c: reg.c, r: reg.r, cw: reg.cw, ch: reg.ch });
                else if (!covered[cc + "," + rr]) out.push({ c: cc, r: rr, cw: 1, ch: 1 });
            }
        return out;
    }
    readonly property var lcells: hasSpans ? _spanCells(spanState)
                                           : LayoutSpec.cellRects(lspec.cols, lspec.rows, lspec.big)
    // Spans render on the fixed net exactly like feature layouts do.
    readonly property bool useFixedNet: isFeatureLayout || hasSpans
    readonly property int perPage: lcells.length
    // Feature layouts (big-tile / center) keep their fixed cell geometry; symmetric
    // and custom grids AUTO-FIT to the number of cameras on the page — largest tiles,
    // aspect-correct, never stretched. perPage stays the page capacity (for paging).
    readonly property bool isFeatureLayout: layout === "plus4" || layout === "plus6"
        || layout === "plus8" || layout === "center13"
    readonly property int fillCount: Math.min(perPage, Math.max(0, total - (page - 1) * perPage))
    // countFiltered()/page() are imperative calls; read cameraModel.total (NOTIFY
    // countsChanged) inside these bindings so they re-evaluate when the model data
    // changes — e.g. the /streams list is (re)fetched after sign-in or refresh.
    readonly property int total: {
        if (!cameraModel) return 0;
        cameraModel.total;   // refresh dependency
        return cameraModel.countFiltered(groupId, _effFilter);
    }
    readonly property int pageCount: Math.max(1, Math.ceil(total / perPage))
    // ---- arrange mode: assign cameras to grid cells ------------------------
    // The grid normally auto-fills cells from the sorted roster. In arrange mode
    // the operator taps a cell and picks the camera that should occupy it; the
    // chosen camera swaps into that slot and the per-group order is persisted
    // (Settings.liveLayout), overriding the default sort for that group.
    property bool arrangeMode: false
    property int arrangeRev: 0            // bump to force arrangedFull re-eval after a save
    property int pickerCell: -1          // page-tile index being assigned (-1 = picker closed)
    // Cap on simultaneous live VA-API decodes on the wall — tiles beyond it show a periodic
    // snapshot, not a live pipeline. Each decode holds real memory on the shared iGPU, so this
    // bounds both steady memory and the teardown watermark during arrange/relayout churn
    // (the residual ~5.8 GB OOM). WT_MAX_DECODES overrides; default 16 — the product's
    // 16-stream wall target. (Was 9 during the 2026-06-30 OOM containment; the trigger —
    // go2rtc OOM-looping — was removed the same day, and the wall decodes substreams only.)
    // Under the RSS-shed safety valve (a memory runaway — e.g. the live-pipeline leak under go2rtc
    // instability) collapse to a single live decode so the wall sheds to snapshot tiles and RSS stops
    // climbing, rather than OOM-killing the client. Restores automatically when RSS recovers (hysteresis).
    // Precedence, highest first: the RSS-shed safety valve (a real memory runaway
    // always wins — it is what stops an OOM kill), then the WT_MAX_DECODES dev
    // override, then the operator's Preferences value. Default 32 (was a hardcoded
    // 16) at the operator's direction, 2026-08-11.
    readonly property int maxLiveDecodes: (typeof MemTel !== "undefined" && MemTel.shedLive) ? 1
        : ((typeof wtMaxDecodes !== "undefined" && wtMaxDecodes > 0) ? wtMaxDecodes
                                                                    : Settings.maxLiveDecodes)
    // Which cameras on the page get the ≤maxLiveDecodes LIVE decode slots — the most IMPORTANT ones, not just
    // the first N by sort position. An ARMED (motion-armed) camera gets a live pipeline ahead of an idle one,
    // so it's real-time, not a snapshot lagging behind. Stable: keyed off the roster/sort (not every status
    // poll), so slots don't thrash — each change is a pipeline build+teardown. With nothing armed it's the old
    // position order. (Set keyed by camId so it's robust across gridModel delegate recycling.)
    readonly property var liveDecodeSet: {
        var cams = pagedCameras, ranked = [];
        for (var i = 0; i < cams.length; i++)
            ranked.push({ id: cams[i].camId, armed: (cams[i].recording === CameraStatus.Armed), pos: i });
        ranked.sort(function(a, b) { return (a.armed === b.armed) ? (a.pos - b.pos) : (a.armed ? -1 : 1); });
        // maxLiveDecodes 0 = NO LIMIT (operator setting): every ranked tile
        // gets a live slot; the shed valve (MemTel.shedLive -> 1) still wins.
        var set = ({}), n = root.maxLiveDecodes > 0
                            ? Math.min(root.maxLiveDecodes, ranked.length) : ranked.length;
        for (var k = 0; k < n; k++) set[ranked[k].id] = true;
        return set;
    }
    // Responsive controls row: when it's too narrow to fit the right-hand action buttons
    // (Go-back / Save / Arrange), they collapse into the overflow "»" menu (MS-Office style).
    // LOOP-FREE: every term is a STABLE implicitWidth — a hidden button keeps its implicit size,
    // and toolbarSpacer.x stays at the (fixed) left-content width — so collapsing never changes
    // the decision that triggered it. Sort + full-screen stay inline (compact, always reachable).
    // Whether the right-hand actions WANT to collapse — recomputed live, including mid-resize.
    readonly property bool _tbWantCollapse: headerRow.width > 0
        && (toolbarSpacer.x + goBackBtn.implicitWidth + saveBtn.implicitWidth + arrangeBtn.implicitWidth
            + sortControl.implicitWidth + fullBtn.implicitWidth + 5 * headerRow.spacing + 8) > headerRow.width
    // The APPLIED collapse state that drives the buttons' `visible`. It is updated on a DEFERRED
    // tick (the timer below), never synchronously from the binding above: toggling a RowLayout
    // child's visibility *during the layout's own resize rearrange* re-enters QGridLayoutEngine and
    // crashes on a dangling attached Layout property (SIGSEGV in QQuickGridLayoutBase::rearrange —
    // reproduced by maximize/minimize). Deferring moves the toggle to the next tick, after the
    // resize pass unwinds, so the layout is never mutated re-entrantly.
    property bool _tbCollapsed: false
    Timer {
        interval: 0; repeat: false
        running: root._tbWantCollapse !== root._tbCollapsed
        onTriggered: root._tbCollapsed = root._tbWantCollapse
    }
    property string pickerSearch: ""
    property string pickerGroup: ""      // picker group filter ("" = all groups)
    property bool pickerHideShown: false // hide cameras already on the visible wall
    // While arranging, ignore the status filter so the full group is shown and a
    // saved order covers every camera (not just the currently-visible subset).
    readonly property string _effFilter: arrangeMode ? "" : statusFilter

    // Full filtered roster reordered by the saved per-group arrangement: saved
    // ids first (in saved order), then any remaining cameras in default sort
    // (so newly-added cameras still appear). Paging slices this.
    readonly property var arrangedFull: {
        arrangeRev;                       // refresh dep
        if (!cameraModel) return [];
        cameraModel.total;                // refresh dep
        var all = cameraModel.page(groupId, _effFilter, sortMode, 1, Math.max(1, total));
        var saved = Settings.liveLayout(groupId);
        if (!saved || saved.length === 0) return _liveFirst(all);
        var byId = ({});
        for (var i = 0; i < all.length; i++) byId[all[i].camId] = all[i];
        var out = [], used = ({});
        for (var j = 0; j < saved.length; j++) {
            var c = byId[saved[j]];
            if (c && !used[saved[j]]) { out.push(c); used[saved[j]] = true; }
        }
        for (var k = 0; k < all.length; k++)
            if (!used[all[k].camId]) out.push(all[k]);
        return _liveFirst(out);
    }
    // "Live first" (the default sort): online cameras ALWAYS lead the wall and offline
    // tiles sink to the last page — even on top of a saved manual arrangement, whose
    // relative order is preserved WITHIN each liveness tier (stable partition). Only in
    // the "live" sort (pick IP/Stream/Status to get the exact manual order back), and
    // never while arranging (so Arrange mode stays deterministic). Mirrors CameraModel's
    // liveRank; applied here too so it survives the arrangement overlay above.
    function _liveFirst(list) {
        if (sortMode !== "live" || arrangeMode || !list || list.length < 2)
            return list;
        function rank(c) {
            var s = c ? c.live : -1;
            return s === CameraStatus.Live ? 0
                 : s === CameraStatus.Degraded ? 1
                 : s === CameraStatus.Offline ? 3 : 2;   // unknown/unresolved between live and offline
        }
        var tagged = list.map(function (c, i) { return { c: c, i: i, r: rank(c) }; });
        tagged.sort(function (a, b) { return a.r !== b.r ? a.r - b.r : a.i - b.i; });   // stable within a tier
        return tagged.map(function (x) { return x.c; });
    }
    readonly property bool hasArrangement: { arrangeRev; return cameraModel ? Settings.liveLayout(groupId).length > 0 : false; }
    function _fullIds() { var a = arrangedFull, o = []; for (var i = 0; i < a.length; i++) o.push(a[i].camId); return o; }
    // camIds currently shown on the visible wall page — powers the picker's
    // "ON WALL" badge and the "hide on-wall" toggle.
    readonly property var displayedIds: {
        var p = pagedCameras, s = ({});
        for (var i = 0; i < p.length; i++) s[p[i].camId] = true;
        return s;
    }
    // Filtered camera list shown in the picker (group + hide-on-wall + search).
    readonly property var pickModel: {
        var q = pickerSearch.toLowerCase(), g = pickerGroup, hide = pickerHideShown;
        var disp = displayedIds, a = arrangedFull, out = [];
        for (var i = 0; i < a.length; i++) {
            var c = a[i];
            if (g !== "" && c.groupId !== g) continue;
            if (hide && disp[c.camId] === true) continue;
            if (q === "" || ("" + c.name).toLowerCase().indexOf(q) >= 0 || ("" + c.ip).indexOf(q) >= 0)
                out.push(c);
        }
        return out;
    }
    // Fallback thumbnail for a camera with no backend snapshot_url.
    //
    // This used to derive go2rtc's own JPEG endpoint from the RTSP URL —
    // http://<host>:1984/api/frame.jpeg?src=<stream>. **:1984 was CLOSED on
    // 2026-08-15** (every producer URL on that port carried a camera password);
    // verified refused on LAN and tailnet. There is no second source: the backend's
    // snapshot_url IS the snapshot service now, so a camera without one has no
    // picture available to us at all.
    //
    // So this now builds the ONE remaining source, and fixes a second defect while
    // it is here: the picker used `cam.snapshotUrl` as a bare QML Image source, and
    // that endpoint requires the session cookie — measured 2026-08-16, an
    // unauthenticated GET returns **401**. A QML Image carries no cookie, so those
    // requests were failing and the cell was quietly falling back to the camera
    // initial. Route through the cvframe provider, which attaches the cookie, the
    // same way LiveThumb does. A camera with no snapshot_url has no picture
    // available at all; "" is the honest answer and the picker draws the initial.
    function _thumbUrl(cam) {
        var base = (cam && cam.snapshotUrl) ? cam.snapshotUrl : "";
        if (base === "") return "";
        return "image://cvframe/" + base.replace(/^[a-z]+:\/\/[^\/]+\//, "");
    }
    // Cameras whose go2rtc frame.jpeg snapshot can't be decoded (e.g. an HEVC-only or
    // wedged producer that returns a non-JPEG). Recorded on the FIRST failure so we stop
    // re-requesting — a broken snapshot then logs at most once instead of spamming the
    // console on every picker re-open / status-poll refresh; the cell falls back to the
    // camera initial. (Both snapshotUrl and _thumbUrl hit the same frame.jpeg endpoint,
    // so there is no alternate URL worth trying.)
    property var _snapFailed: ({})

    // Picker thumbnail load LIMITER. The "Tap to change" grid shows every camera at once
    // (~32), and each thumbnail is a go2rtc frame.jpeg — i.e. a frame-grab on the shared
    // iGPU. Fetching all 32 simultaneously, on top of the live wall, spiked the iGPU +
    // memory and crashed the app (OOM on a swap-pressured box). So we admit at most
    // _thumbMax fetches at a time; the rest queue and start as slots free (each slot is
    // released when its thumbnail finishes — Ready or Error). Reset on every picker open.
    readonly property int _thumbMax: 6
    property int _thumbInFlight: 0
    property var _thumbGranted: ({})     // camId -> true once admitted to fetch
    property var _thumbWaiting: []       // camIds queued for a slot
    // camId -> true once its snapshot has loaded. Keyed by camId (survives GridView delegate
    // recreation) and NOT cleared by _thumbResetLoads, so a loaded thumbnail stays shown across
    // every picker open/close for the whole Live session — the picker opens INSTANTLY after the
    // first deliberate load, and each camera's go2rtc snapshot is fetched at most once.
    property var _thumbLoaded: ({})
    function _thumbWant(camId) {
        if (!camId || _thumbGranted[camId] || _thumbLoaded[camId]) return;   // already admitted/loaded
        if (_thumbWaiting.indexOf(camId) < 0) _thumbWaiting.push(camId);
        _thumbPump();
    }
    function _thumbPump() {
        while (_thumbInFlight < _thumbMax && _thumbWaiting.length > 0) {
            var id = _thumbWaiting.shift();
            var g = {};
            for (var k in _thumbGranted) g[k] = _thumbGranted[k];
            g[id] = true; _thumbGranted = g;                 // fresh object → bindings re-eval
            _thumbInFlight++;
        }
    }
    function _thumbRelease() {            // a thumbnail finished (ready or error)
        if (_thumbInFlight > 0) _thumbInFlight--;
        _thumbPump();
    }
    function _thumbResetLoads() {         // picker (re)opened — forget all prior load state
        _thumbWaiting = []; _thumbGranted = ({}); _thumbInFlight = 0;
    }
    // Fit-to-screen grid geometry: the largest (capped) cell size that lays all
    // `count` thumbnails out within availW×availH without scrolling. If they can't
    // all fit even at the minimum column width, returns the tightest columns and
    // the GridView scrolls (only for very large rosters — "dynamic to a degree").
    function _pickGeom(count, availW, availH) {
        var CMAXW = 208, CMINW = 132, LABELS = 50, ASPECT = 0.5625;  // thumb 16:9 + 2 label lines
        if (count < 1) count = 1;
        var maxCols = Math.max(1, Math.floor(availW / CMINW));
        var pick = { cols: 1, cellW: Math.min(CMAXW, Math.max(CMINW, availW)), cellH: 1, rows: count };
        for (var cols = 1; cols <= Math.min(count, maxCols); cols++) {
            var cw = Math.min(CMAXW, Math.floor(availW / cols));
            var ch = Math.round(cw * ASPECT) + LABELS;
            var rows = Math.ceil(count / cols);
            pick = { cols: cols, cellW: cw, cellH: ch, rows: rows };
            if (rows * ch <= availH) break;   // largest cells that fit without scroll
        }
        return pick;
    }
    readonly property real _pickChrome: 176       // title + pills + search + cancel + margins
    readonly property real _pickAvailW: width * 0.92 - 36
    readonly property real _pickAvailH: height * 0.9 - _pickChrome
    readonly property var _pg: _pickGeom(pickModel.length, _pickAvailW, _pickAvailH)
    function openCellPicker(tileIndex) { pickerSearch = ""; pickerGroup = ""; pickerHideShown = false; pickerCell = tileIndex; }
    // Free the cached thumbnails only when fully leaving the picker context (out of Arrange AND
    // the picker is closed). Within an Arrange session the loaded snapshots stay alive so the
    // picker opens instantly on every cell; right-click opens (no Arrange) free on close.
    onArrangeModeChanged: { if (!arrangeMode && pickerCell < 0) _thumbResetLoads(); }
    onPickerCellChanged: { if (pickerCell < 0 && !arrangeMode) _thumbResetLoads(); }
    // ---- drag-to-swap on the wall -------------------------------------------
    // The gesture the merge-selection MouseArea has been reserving ("plain drag
    // (reserved for future drag-swap)", selMa). Arrangement is an ORDERED ID LIST
    // (Settings.liveLayout) and geometry lives separately in spanState, so a drop
    // is a swap of two positions in that list — the grid does not move. That is
    // what makes merged tiles free: a big region stays big where it is, the
    // dragged camera fills it, the displaced camera takes the dragged tile's old
    // cell, and _spanCells() reflows the small cells around the region exactly as
    // before. No special case for 2x2 or larger.
    property int dragCell: -1                  // enumerated cell index being dragged
    property int dropCell: -1                  // enumerated cell index under the cursor
    property string dragCamId: ""
    property string dragCamName: ""
    function cancelDrag() { dragCell = -1; dropCell = -1; dragCamId = ""; dragCamName = ""; }
    // Map a grid coordinate to the enumerated cell index. NOT c + r*cols: with a
    // span present the enumeration skips covered cells, so the two disagree the
    // moment anything is merged.
    // `gCols` is the AUTO-FIT column count, which only equals lspec.cols on a fixed
    // net — pass it in rather than re-deriving it here.
    function cellIndexAt(c, r, gCols) {
        if (useFixedNet) {
            var cs = lcells;
            for (var i = 0; i < cs.length; i++) {
                var e = cs[i];
                if (c >= e.c && c < e.c + e.cw && r >= e.r && r < e.r + e.ch) return i;
            }
            return -1;
        }
        return r * gCols + c;                    // auto-fit: every cell is 1x1
    }
    function dropOnCell(targetIndex) {
        if (targetIndex < 0 || dragCell < 0 || targetIndex === dragCell || dragCamId === "") {
            cancelDrag(); return;
        }
        assignToCell(targetIndex, dragCamId);   // swaps the two ids; geometry untouched
        cancelDrag();
    }

    function assignToCell(tileIndex, camId) {
        var ids = _fullIds();
        var target = (page - 1) * perPage + tileIndex;
        var cur = ids.indexOf(camId);
        if (target >= ids.length || cur < 0) { pickerCell = -1; return; }
        var t = ids[target]; ids[target] = ids[cur]; ids[cur] = t;   // swap the chosen camera into the cell
        Settings.setLiveLayout(groupId, ids);
        arrangeRev++; pickerCell = -1;
    }
    function resetArrangement() { Settings.clearLiveLayout(groupId); arrangeRev++; }
    // Esc handling for arrange mode: close an open cell picker first, otherwise
    // leave arrange mode and return to the normal Live view. Per-cell changes are
    // already persisted (Settings.setLiveLayout), so exiting discards nothing.
    function escapeArrange() {
        if (mergeSel !== null) { mergeSel = null; return; }
        if (pickerCell >= 0) { pickerCell = -1; return; }
        arrangeMode = false;
    }

    // ---- merge selection (Shift+drag / Shift+click extend / Ctrl+click) -------
    // mergeSel = {c0,r0,c1,r1, ac,ar} — normalized inclusive rect + the ANCHOR
    // cell (where the drag started; its camera is the one that goes big).
    property var mergeSel: null
    onLayoutChanged: { mergeSel = null; cancelDrag() }
    onGroupIdChanged: mergeSel = null
    onPageChanged: { mergeSel = null; cancelDrag() }
    // Selection normalization: swallow any merged region the rect touches (the
    // Excel rule) — the highlight always shows the TRUE result of the merge.
    function _normSel(ac, ar, bc, br) {
        var c0 = Math.min(ac, bc), r0 = Math.min(ar, br);
        var c1 = Math.max(ac, bc), r1 = Math.max(ar, br);
        var regs = spanState ? spanState.regions : [];
        var grew = true;
        while (grew) {
            grew = false;
            for (var i = 0; i < regs.length; i++) {
                var g = regs[i];
                var gx1 = g.c + g.cw - 1, gy1 = g.r + g.ch - 1;
                if (g.c <= c1 && gx1 >= c0 && g.r <= r1 && gy1 >= r0) {   // intersects
                    if (g.c < c0) { c0 = g.c; grew = true; }
                    if (g.r < r0) { r0 = g.r; grew = true; }
                    if (gx1 > c1) { c1 = gx1; grew = true; }
                    if (gy1 > r1) { r1 = gy1; grew = true; }
                }
            }
        }
        return { c0: c0, r0: r0, c1: c1, r1: r1, ac: ac, ar: ar };
    }
    function startSel(c) { mergeSel = _normSel(c.c, c.r, c.c, c.r); }
    function extendSel(c) {
        if (mergeSel === null) { startSel(c); return; }
        mergeSel = _normSel(mergeSel.ac, mergeSel.ar, c.c, c.r);
    }
    // Region whose rect contains cell (c,r) — or null.
    function regionAt(c, r) {
        if (!spanState) return null;
        for (var i = 0; i < spanState.regions.length; i++) {
            var g = spanState.regions[i];
            if (c >= g.c && c < g.c + g.cw && r >= g.r && r < g.r + g.ch) return g;
        }
        return null;
    }
    // Slot index (position in lcells / pagedCameras) whose cell rect contains (c,r).
    function slotIndexForCell(c, r) {
        for (var i = 0; i < lcells.length; i++) {
            var g = lcells[i];
            if (c >= g.c && c < g.c + g.cw && r >= g.r && r < g.r + g.ch) return i;
        }
        return -1;
    }
    readonly property int _selW: mergeSel ? (mergeSel.c1 - mergeSel.c0 + 1) : 0
    readonly property int _selH: mergeSel ? (mergeSel.r1 - mergeSel.r0 + 1) : 0
    // Selection == exactly one existing region → the action is Split, not Merge.
    readonly property bool selIsRegion: {
        if (!mergeSel) return false;
        var g = regionAt(mergeSel.c0, mergeSel.r0);
        return g !== null && g.c === mergeSel.c0 && g.r === mergeSel.r0
            && g.cw === _selW && g.ch === _selH;
    }
    readonly property string selAnchorName: {
        if (!mergeSel) return "";
        var i = slotIndexForCell(mergeSel.ac, mergeSel.ar);
        return (i >= 0 && i < pagedCameras.length) ? pagedCameras[i].name : "";
    }
    function _saveSpans(s) {
        if (!s || s.regions.length === 0) Settings.clearLiveSpans(groupId, layout);
        else Settings.setLiveSpans(groupId, layout, JSON.stringify(s));
        spansRev++;
    }
    // Merge the current selection — or split it, when it IS a merged region.
    function mergeSelection() {
        if (mergeSel === null || isFeatureLayout) return false;
        if (selIsRegion) { var ok = splitAt(mergeSel.c0, mergeSel.r0); mergeSel = null; return ok; }
        if (_selW * _selH < 2) return false;
        var s = spanState ? JSON.parse(JSON.stringify(spanState))
                          : { cols: gridFrame.fitGrid.cols, rows: gridFrame.fitGrid.rows, regions: [] };
        if (mergeSel.c1 >= s.cols || mergeSel.r1 >= s.rows) return false;
        // The drag-start camera goes big: if the anchor isn't the rect's top-left,
        // swap the two cameras (assignToCell's exact persistence pattern) BEFORE
        // the span lands, while slot indices still describe the pre-merge grid.
        var iA = slotIndexForCell(mergeSel.ac, mergeSel.ar);
        var iT = slotIndexForCell(mergeSel.c0, mergeSel.r0);
        if (iA >= 0 && iT >= 0 && iA !== iT) {
            var ids = _fullIds(), s0 = (page - 1) * perPage;
            if (s0 + iA < ids.length && s0 + iT < ids.length) {
                var t = ids[s0 + iT]; ids[s0 + iT] = ids[s0 + iA]; ids[s0 + iA] = t;
                Settings.setLiveLayout(groupId, ids);
                arrangeRev++;
            }
        }
        // Swallowed regions are inside the rect by normalization — drop them.
        s.regions = s.regions.filter(function (g) {
            return !(g.c >= mergeSel.c0 && g.c + g.cw - 1 <= mergeSel.c1
                     && g.r >= mergeSel.r0 && g.r + g.ch - 1 <= mergeSel.r1);
        });
        s.regions.push({ c: mergeSel.c0, r: mergeSel.r0, cw: _selW, ch: _selH });
        _saveSpans(s);
        mergeSel = null;
        return true;
    }
    function splitAt(c, r) {
        var g = regionAt(c, r);
        if (!g || !spanState) return false;
        var s = JSON.parse(JSON.stringify(spanState));
        s.regions = s.regions.filter(function (x) { return !(x.c === g.c && x.r === g.r); });
        _saveSpans(s);
        return true;
    }
    Shortcut {
        sequence: "M"
        enabled: root.visible && root.mergeSel !== null && !root.arrangeMode && root.pickerCell < 0
        onActivated: root.mergeSelection()
    }
    Shortcut {
        sequence: "Return"
        enabled: root.visible && root.mergeSel !== null && !root.arrangeMode && root.pickerCell < 0
        onActivated: root.mergeSelection()
    }

    // ---- "Recent events" filter: cameras with activity in the last hour --------
    property int recentWindowMs: 3600000
    function refreshRecent() {
        if (cameraModel && eventModel)
            cameraModel.setRecentCameras(eventModel.recentCameraIds(recentWindowMs));
    }
    // Live MOTION tile indicator feed: a lightweight motion-only poll (never touches
    // the list model, so the sidebar doesn't churn) every 5s while the wall shows.
    // This poll interval IS the indicator's latency; push events = CV ask.
    Timer {
        interval: 5000; repeat: true; triggeredOnStart: true
        running: root.visible && root.eventModel !== null
        onTriggered: root.eventModel.pollMotion()
    }
    // While "Recent events" is the active filter and the screen is shown, pull the
    // latest events and re-evaluate the window every 30s (also ages cameras out).
    Timer {
        interval: 30000; repeat: true; triggeredOnStart: true
        running: root.visible && root.statusFilter === "recent"
        onTriggered: { if (root.eventModel) root.eventModel.refresh(); root.refreshRecent(); }
    }
    Connections {
        target: root.eventModel
        enabled: root.eventModel !== null && root.statusFilter === "recent"
        function onChanged() { root.refreshRecent(); }
    }

    // Empty-state copy: a genuinely empty roster (no camera access) vs a non-empty
    // roster whose current filter/group simply matched nothing (honest "no matches").
    function rosterEmpty() { return !cameraModel || cameraModel.total === 0; }
    // Three states, not two (booth, 2026-08-17): unavailable ("we asked and could
    // not find out") must outrank empty ("your account has no cameras") — a
    // /streams 500 on cold start used to render as the second, sending a guard
    // to chase an access problem that did not exist. The unavailable text names
    // no culprit and issues no instruction, because at that moment we know
    // neither.
    function rosterUnavailable() { return cameraModel && cameraModel.listUnavailable && cameraModel.total === 0; }
    function emptyTitle() {
        if (rosterUnavailable()) return qsTr("Camera list unavailable");
        return rosterEmpty() ? qsTr("No cameras") : qsTr("No matches");
    }
    function emptySubtitle() {
        if (rosterUnavailable())
            return qsTr("Could not fetch the camera list from Cilex Vision. Watchtower keeps retrying automatically.");
        if (rosterEmpty())
            return qsTr("No cameras are assigned to your account. Ask an administrator to grant camera access in Cilex Vision.");
        var where = (groupId === "" ? "" : qsTr(" in %1").arg(groupLabel));
        switch (statusFilter) {
        case "recent":    return qsTr("No cameras have had an event in the last hour") + where + ".";
        case "online":    return qsTr("No cameras are online") + where + " right now.";
        case "offline":   return qsTr("No cameras are offline") + where + " — all good.";
        case "degraded":  return qsTr("No cameras are degraded") + where + ".";
        case "recording": return qsTr("No cameras are recording") + where + ".";
        case "notrec":    return qsTr("All cameras are recording") + where + " — none stopped.";
        case "favorites": return qsTr("No starred cameras") + where + " yet. Tap a tile's star to pin it here.";
        case "issues":    return qsTr("No cameras have issues") + where + " — everything looks healthy.";
        default:          return qsTr("No cameras") + where + ".";
        }
    }

    readonly property var pagedCameras: {
        var s = (page - 1) * perPage;
        return arrangedFull.slice(s, s + perPage);
    }
    // The grid renders from this persistent, camId-keyed model — NOT straight from
    // the pagedCameras array. A Repeater bound to a JS array tears down and recreates
    // EVERY delegate whenever the array identity changes (a layout switch, a page
    // turn, a status poll), and each recreated CameraTile restarts its RTSP pipeline
    // → a green (undecoded) VA-API surface flashes across the whole wall. Reconciling
    // in place by camId (update / move / insert / remove) keeps the tiles for cameras
    // that are still on screen alive, so they keep playing through a relayout instead
    // of going green — and we don't needlessly re-negotiate ~16 RTSP sessions.
    ListModel { id: gridModel; dynamicRoles: true }
    function syncGrid(list) {
        if (!list) list = [];
        var want = ({});
        for (var i = 0; i < list.length; i++) want[list[i].camId] = true;
        for (var r = gridModel.count - 1; r >= 0; r--)          // drop cameras no longer on the page
            if (!want[gridModel.get(r).camId]) gridModel.remove(r);
        for (var j = 0; j < list.length; j++) {                 // place each camera at its slot
            var cam = list[j];
            var cur = -1;
            for (var k = j; k < gridModel.count; k++)
                if (gridModel.get(k).camId === cam.camId) { cur = k; break; }
            if (cur === -1)
                gridModel.insert(j, { camId: cam.camId, cam: cam });
            else {
                if (cur !== j) gridModel.move(cur, j, 1);
                gridModel.setProperty(j, "cam", cam);           // refresh data (badges) without recreating the tile
            }
        }
    }
    onPagedCamerasChanged: syncGrid(pagedCameras)
    Component.onCompleted: syncGrid(pagedCameras)
    readonly property string rangeText: {
        if (total === 0)
            return qsTr("0 of 0");
        const start = (page - 1) * perPage + 1;
        const end = Math.min(page * perPage, total);
        return qsTr("%1–%2 of %3").arg(start).arg(end).arg(total);
    }

    readonly property var sortLabels: ({ "live": "Live first", "ip": "IP address", "default": "Stream order", "status": "Status first", "alpha": "Alphabetical" })

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---------------------------------------------------------- sub-bar
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.subBarHeight
            visible: !root.fullscreen
            color: Theme.bg
            Rectangle {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: 1; color: Theme.line
            }

            RowLayout {
                id: headerRow
                anchors.fill: parent
                anchors.leftMargin: 20
                anchors.rightMargin: 20
                spacing: 12

                // layout segmented control — NetIcon pictograms (2×2 / 3×3 / 4×4 / Other)
                Rectangle {
                    id: layoutSeg
                    Layout.preferredHeight: 38
                    implicitWidth: segRow.implicitWidth
                    color: Theme.panel
                    border.width: 1
                    border.color: Theme.line2
                    Row {
                        id: segRow
                        height: 38
                        Repeater {
                            model: [
                                { id: "4",     lbl: "2×2",   cols: 2, rows: 2, big: null, gap: 1.4, pad: 1.6, sw: 1.4  },
                                { id: "9",     lbl: "3×3",   cols: 3, rows: 3, big: null, gap: 1.2, pad: 1.6, sw: 1.25 },
                                { id: "16",    lbl: "4×4",   cols: 4, rows: 4, big: null, gap: 1.0, pad: 1.6, sw: 1.1  },
                                { id: "other", lbl: qsTr("Other"), cols: 3, rows: 3, big: { c: 0, r: 0, cw: 2, ch: 2 }, gap: 1.2, pad: 1.6, sw: 1.25 }
                            ]
                            delegate: Item {
                                id: seg
                                required property var modelData
                                required property int index
                                readonly property bool isOther: modelData.id === "other"
                                // "Other" is active for any non-standard layout (not 1/4/9/16).
                                readonly property bool active: isOther
                                    ? (["1", "4", "9", "16"].indexOf(root.layout) < 0)
                                    : (root.layout === modelData.id)
                                width: segContent.implicitWidth + 22
                                height: 38
                                Rectangle {
                                    anchors.fill: parent
                                    color: seg.active ? Theme.accent : (segMa.containsMouse ? Theme.panel2 : "transparent")
                                }
                                Rectangle {
                                    visible: seg.index > 0
                                    anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                                    width: 1; color: Theme.line
                                }
                                Row {
                                    id: segContent
                                    anchors.centerIn: parent
                                    spacing: 6
                                    readonly property color fg: seg.active ? Theme.bg : (segMa.containsMouse ? Theme.ink : Theme.ink2)
                                    NetIcon {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 16; height: 16
                                        cols: seg.modelData.cols; rows: seg.modelData.rows; big: seg.modelData.big
                                        gap: seg.modelData.gap; pad: seg.modelData.pad; sw: seg.modelData.sw
                                        color: segContent.fg
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: seg.modelData.lbl
                                        color: segContent.fg
                                        font.family: Theme.fontMono; font.pixelSize: 12; font.weight: Font.DemiBold
                                    }
                                    Icon {
                                        visible: seg.isOther
                                        anchors.verticalCenter: parent.verticalCenter
                                        name: "chev"; size: 12; color: segContent.fg
                                    }
                                }
                                MouseArea {
                                    id: segMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (seg.isOther) otherPopup.open();
                                        else root.layoutRequested(seg.modelData.id);
                                    }
                                }
                            }
                        }
                    }

                    // "Other layouts" dropdown — exact-net preset pictograms + custom N×M picker.
                    C.Popup {
                        id: otherPopup
                        y: layoutSeg.height + 4
                        x: 0
                        width: 380
                        padding: 16
                        background: Rectangle { color: Theme.panel; border.color: Theme.line2; border.width: 1 }
                        contentItem: ColumnLayout {
                            spacing: 14

                            Text {
                                text: qsTr("OTHER LAYOUTS")
                                color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: Theme.fsLabel
                                font.capitalization: Font.AllUppercase; font.letterSpacing: 1.2; font.weight: Font.DemiBold
                            }
                            Grid {
                                Layout.fillWidth: true
                                columns: 3
                                rowSpacing: 8; columnSpacing: 8
                                Repeater {
                                    model: [
                                        { id: "1",        cols: 1, rows: 1, big: null },
                                        { id: "plus4",    cols: 3, rows: 3, big: { c: 0, r: 0, cw: 2, ch: 3 } },
                                        { id: "plus6",    cols: 3, rows: 3, big: { c: 0, r: 0, cw: 2, ch: 2 } },
                                        { id: "plus8",    cols: 4, rows: 4, big: { c: 0, r: 0, cw: 3, ch: 3 } },
                                        { id: "center13", cols: 4, rows: 4, big: { c: 1, r: 1, cw: 2, ch: 2 } },
                                        { id: "25",       cols: 5, rows: 5, big: null }
                                    ]
                                    delegate: Rectangle {
                                        id: preset
                                        required property var modelData
                                        readonly property bool sel: root.layout === modelData.id
                                        width: 108; height: 72
                                        color: presetMa.containsMouse ? Theme.panel2 : Theme.bg
                                        border.width: 1
                                        border.color: preset.sel ? Theme.accent : Theme.line2
                                        Column {
                                            anchors.centerIn: parent
                                            spacing: 8
                                            NetIcon {
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                width: 40; height: 30
                                                cols: preset.modelData.cols; rows: preset.modelData.rows; big: preset.modelData.big
                                                color: preset.sel ? Theme.accent : Theme.ink2
                                            }
                                            Text {
                                                anchors.horizontalCenter: parent.horizontalCenter
                                                text: LayoutSpec.label(preset.modelData.id)
                                                color: preset.sel ? Theme.accent : Theme.ink2
                                                font.family: Theme.fontMono; font.pixelSize: 10
                                            }
                                        }
                                        MouseArea {
                                            id: presetMa
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: { root.layoutRequested(preset.modelData.id); otherPopup.close() }
                                        }
                                    }
                                }
                            }

                            Rectangle { Layout.fillWidth: true; height: 1; color: Theme.line }

                            // custom N×M picker — hover the top-left block, click to commit
                            Text {
                                text: picker.hc >= 0
                                    ? (picker.hc + 1) + " × " + (picker.hr + 1) + " · " + ((picker.hc + 1) * (picker.hr + 1)) + " cameras"
                                    : "CUSTOM — HOVER TO CHOOSE A GRID"
                                color: picker.hc >= 0 ? Theme.accent : Theme.ink3
                                font.family: Theme.fontMono
                                font.pixelSize: picker.hc >= 0 ? 12 : Theme.fsLabel
                                font.capitalization: picker.hc >= 0 ? Font.MixedCase : Font.AllUppercase
                                font.letterSpacing: picker.hc >= 0 ? 0 : 1.2
                                font.weight: Font.DemiBold
                            }
                            Item {
                                id: picker
                                Layout.alignment: Qt.AlignHCenter
                                property int hc: -1
                                property int hr: -1
                                readonly property int cell: 15
                                readonly property int gp: 2
                                readonly property int pitch: cell + gp
                                implicitWidth: 10 * cell + 9 * gp
                                implicitHeight: 10 * cell + 9 * gp
                                width: implicitWidth; height: implicitHeight
                                Repeater {
                                    model: 100
                                    delegate: Rectangle {
                                        required property int index
                                        readonly property int cc: index % 10
                                        readonly property int rr: Math.floor(index / 10)
                                        readonly property bool on: cc <= picker.hc && rr <= picker.hr
                                        x: cc * picker.pitch
                                        y: rr * picker.pitch
                                        width: picker.cell; height: picker.cell
                                        color: on ? Theme.accent : Theme.bg
                                        border.width: 1
                                        border.color: on ? Theme.accent : Theme.line2
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onPositionChanged: (m) => {
                                        picker.hc = Math.max(0, Math.min(9, Math.floor(m.x / picker.pitch)));
                                        picker.hr = Math.max(0, Math.min(9, Math.floor(m.y / picker.pitch)));
                                    }
                                    onExited: { picker.hc = -1; picker.hr = -1 }
                                    onClicked: {
                                        if (picker.hc >= 0 && picker.hr >= 0) {
                                            root.layoutRequested((picker.hc + 1) + "x" + (picker.hr + 1));
                                            otherPopup.close();
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 24; color: Theme.line2 }

                // group scope switcher — re-scope the grid to a camera group in one click
                Rectangle {
                    id: groupControl
                    Layout.preferredHeight: 38
                    implicitWidth: groupRow.implicitWidth + 24
                    color: Theme.panel
                    border.width: 1
                    border.color: grpMa.containsMouse ? Theme.accent : Theme.line2
                    Row {
                        id: groupRow; anchors.centerIn: parent; spacing: 8
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.groupLabel
                            color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12
                            elide: Text.ElideRight; width: Math.min(implicitWidth, 180)
                        }
                        Icon { anchors.verticalCenter: parent.verticalCenter; name: "chev"; size: 12; color: Theme.ink3 }
                    }
                    MouseArea { id: grpMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: groupPopup.open() }
                    C.Popup {
                        id: groupPopup
                        y: groupControl.height + 4
                        x: 0
                        width: 220
                        padding: 0
                        background: Rectangle { color: Theme.panel; border.color: Theme.line2; border.width: 1 }
                        contentItem: Column {
                            Repeater {
                                model: root.groupOpts
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property bool isEmpty: modelData.count === 0
                                    width: 220; height: 34
                                    color: grpOptMa.containsMouse ? Theme.panel2 : "transparent"
                                    Text {
                                        anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                                        width: parent.width - 24 - cntTxt.implicitWidth - 8
                                        text: modelData.name
                                        // an empty group still scopes (and says "no cameras in X"),
                                        // so it stays clickable — it just stops looking like a
                                        // group with cameras in it
                                        color: root.groupId === modelData.id ? Theme.accent
                                             : (parent.isEmpty ? Theme.ink3 : Theme.ink)
                                        font.family: Theme.fontSans; font.pixelSize: 12; elide: Text.ElideRight
                                    }
                                    Text {
                                        id: cntTxt
                                        anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                                        text: modelData.count
                                        color: parent.isEmpty ? Theme.ink3
                                             : (root.groupId === modelData.id ? Theme.accent : Theme.ink2)
                                        font.family: Theme.fontMono; font.pixelSize: 11
                                    }
                                    MouseArea {
                                        id: grpOptMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: { root.groupRequested(modelData.id, modelData.name); groupPopup.close(); }
                                    }
                                }
                            }

                            // Manual resync — pull fresh groups + membership from
                            // the server now (the 15s poll also auto-syncs groups).
                            Rectangle { width: 220; height: 1; color: Theme.line2 }
                            Rectangle {
                                width: 220; height: 34
                                color: grpSyncMa.containsMouse ? Theme.panel2 : "transparent"
                                Text {
                                    anchors { left: parent.left; leftMargin: 12; right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                                    text: qsTr("↻  Sync from server")
                                    color: grpSyncMa.containsMouse ? Theme.accent : Theme.ink2
                                    font.family: Theme.fontSans; font.pixelSize: 12; elide: Text.ElideRight
                                }
                                MouseArea {
                                    id: grpSyncMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: { if (root.cameraModel) root.cameraModel.refresh(); groupPopup.close(); }
                                }
                            }
                        }
                    }
                }

                // Clear a transient map-selection scope ("Selected (N)") back to All
                // cameras in one click — shown only while the grid is scoped to it.
                Rectangle {
                    visible: root.groupId === "__selected__"
                    Layout.preferredHeight: 38
                    implicitWidth: clrRow.implicitWidth + 20
                    color: clrMa.containsMouse ? Theme.panel2 : Theme.panel
                    border.width: 1; border.color: clrMa.containsMouse ? Theme.accent : Theme.line2
                    Row {
                        id: clrRow; anchors.centerIn: parent; spacing: 6
                        Text { anchors.verticalCenter: parent.verticalCenter; text: "✕"; color: clrMa.containsMouse ? Theme.accent : Theme.ink2; font.pixelSize: 12 }
                        Text { anchors.verticalCenter: parent.verticalCenter; text: qsTr("Clear selection"); color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12 }
                    }
                    MouseArea {
                        id: clrMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: root.groupRequested("", "All cameras")
                    }
                }

                Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 24; color: Theme.line2 }

                // filter pills
                FilterPill {
                    label: qsTr("Favorites")
                    leadingStar: true
                    active: root.statusFilter === "favorites"
                    removable: root.statusFilter === "favorites"
                    onClicked: root.statusFilterRequested(root.statusFilter === "favorites" ? "" : "favorites")
                    onRemoved: root.statusFilterRequested("")
                }
                FilterPill {
                    label: qsTr("Online")
                    active: root.statusFilter === "online"
                    removable: root.statusFilter === "online"
                    onClicked: root.statusFilterRequested(root.statusFilter === "online" ? "" : "online")
                    onRemoved: root.statusFilterRequested("")
                }
                FilterPill {
                    label: qsTr("Recent events")
                    active: root.statusFilter === "recent"
                    onClicked: root.statusFilterRequested(root.statusFilter === "recent" ? "" : "recent")
                }
                FilterPill {
                    label: root.statusFilter === "issues" ? qsTr("Issues") : qsTr("Filter")
                    leadingPlus: root.statusFilter !== "issues"
                    removable: root.statusFilter === "issues"
                    active: ["offline", "degraded", "recording", "notrec", "favorites", "issues"].indexOf(root.statusFilter) >= 0
                    onClicked: root.statusFilterRequested(root.statusFilter === "issues" ? "" : "issues")
                    onRemoved: root.statusFilterRequested("")
                }

                Item { id: toolbarSpacer; Layout.fillWidth: true }

                // go back in time (enter synchronized wall playback)
                Rectangle {
                    id: goBackBtn
                    visible: !root._tbCollapsed
                    Layout.preferredHeight: 34
                    implicitWidth: gbtRow.implicitWidth + 24
                    color: gbtMa.containsMouse ? Theme.panel : "transparent"
                    border.width: 1
                    border.color: gbtMa.containsMouse ? Theme.accent : Theme.line2
                    Row {
                        id: gbtRow; anchors.centerIn: parent; spacing: 7
                        Icon { anchors.verticalCenter: parent.verticalCenter; name: "history"; size: 15; color: Theme.ink2 }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: qsTr("Go back in time"); color: Theme.ink2
                            font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium
                        }
                    }
                    MouseArea {
                        id: gbtMa; anchors.fill: parent; hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor; onClicked: root.wallPlaybackRequested()
                    }
                }

                // save current view (ghost)
                Rectangle {
                    id: saveBtn
                    visible: !root._tbCollapsed
                    Layout.preferredHeight: 34
                    implicitWidth: saveTxt.implicitWidth + 28
                    color: saveMa.containsMouse ? Theme.panel : "transparent"
                    border.width: 1
                    border.color: saveMa.containsMouse ? Theme.accent : "transparent"
                    Text {
                        id: saveTxt
                        anchors.centerIn: parent
                        text: qsTr("Save current view")
                        color: Theme.ink2
                        font.family: Theme.fontSans
                        font.pixelSize: 12
                        font.weight: Font.Medium
                    }
                    MouseArea {
                        id: saveMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.saveViewRequested()
                    }
                }

                // arrange cells — tap a cell to choose its camera (e.g. the Center tile)
                Rectangle {
                    id: arrangeBtn
                    visible: !root._tbCollapsed
                    Layout.preferredHeight: 34
                    implicitWidth: arrTxt.implicitWidth + 28
                    color: root.arrangeMode ? Theme.accent : (arrMa.containsMouse ? Theme.panel : "transparent")
                    border.width: 1
                    border.color: root.arrangeMode ? Theme.accent : (arrMa.containsMouse ? Theme.accent : Theme.line2)
                    Text {
                        id: arrTxt; anchors.centerIn: parent
                        text: root.arrangeMode ? qsTr("Done arranging") : qsTr("Arrange")
                        color: root.arrangeMode ? Theme.bg : Theme.ink2
                        font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium
                    }
                    MouseArea {
                        id: arrMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { root.arrangeMode = !root.arrangeMode; root.pickerCell = -1; }
                    }
                }
                // reset this group's arrangement (only while arranging + a custom order exists)
                Rectangle {
                    id: resetBtn
                    visible: root.arrangeMode && root.hasArrangement && !root._tbCollapsed
                    Layout.preferredHeight: 34
                    implicitWidth: resetTxt.implicitWidth + 24
                    color: resetMa.containsMouse ? Theme.panel : "transparent"
                    border.width: 1; border.color: resetMa.containsMouse ? Theme.accent : Theme.line2
                    Text { id: resetTxt; anchors.centerIn: parent; text: qsTr("Reset"); color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12 }
                    MouseArea { id: resetMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.resetArrangement() }
                }

                // sort dropdown
                Rectangle {
                    id: sortControl
                    visible: !root._tbCollapsed
                    Layout.preferredHeight: 38
                    implicitWidth: sortRow.implicitWidth + 24
                    color: Theme.panel
                    border.width: 1
                    border.color: sortMa.containsMouse ? Theme.accent : Theme.line2
                    Row {
                        id: sortRow
                        anchors.centerIn: parent
                        spacing: 8
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: qsTr("Sort: ") + root.sortLabels[root.sortMode]
                            color: Theme.ink
                            font.family: Theme.fontSans
                            font.pixelSize: 12
                        }
                        Icon { anchors.verticalCenter: parent.verticalCenter; name: "chev"; size: 12; color: Theme.ink3 }
                    }
                    MouseArea {
                        id: sortMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: sortPopup.open()
                    }
                    C.Popup {
                        id: sortPopup
                        y: sortControl.height + 4
                        x: 0
                        width: 160
                        padding: 0
                        background: Rectangle { color: Theme.panel; border.color: Theme.line2; border.width: 1 }
                        contentItem: Column {
                            Repeater {
                                model: [
                                    { id: "live",    lbl: "Live first" },
                                    { id: "ip",      lbl: "IP address" },
                                    { id: "default", lbl: "Stream order" },
                                    { id: "status",  lbl: "Status first" },
                                    { id: "alpha",   lbl: "Alphabetical" }
                                ]
                                delegate: Rectangle {
                                    required property var modelData
                                    width: 160
                                    height: 34
                                    color: optMa.containsMouse ? Theme.panel2 : "transparent"
                                    Text {
                                        anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                                        text: modelData.lbl
                                        color: root.sortMode === modelData.id ? Theme.accent : Theme.ink
                                        font.family: Theme.fontSans
                                        font.pixelSize: 12
                                    }
                                    MouseArea {
                                        id: optMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: { root.sortRequested(modelData.id); sortPopup.close() }
                                    }
                                }
                            }
                        }
                    }
                }

                // full-screen
                IconButton {
                    id: fullBtn
                    visible: !root._tbCollapsed
                    name: "full"
                    iconColor: Theme.ink2
                    borderColor: Theme.line2
                    bgColor: Theme.panel
                    hoverIcon: Theme.accent
                    hoverBorder: Theme.accent
                    tip: qsTr("Full-screen monitoring (F)")
                    implicitWidth: 38
                    implicitHeight: 38
                    onClicked: root.fullscreenToggled()
                }

                // Overflow ("»"): when the row is too narrow to fit the action buttons above
                // (Go-back / Save / Arrange), they collapse here — MS-Office-style right-edge
                // overflow. Opens a menu with the same commands. Shown only while collapsed.
                Rectangle {
                    id: overflowBtn
                    visible: root._tbCollapsed
                    Layout.preferredHeight: 38; Layout.preferredWidth: 38
                    color: (ovMa.containsMouse || ovPopup.visible) ? Theme.panel : "transparent"
                    border.width: 1
                    border.color: (ovMa.containsMouse || ovPopup.visible) ? Theme.accent : Theme.line2
                    Accessible.role: Accessible.Button
                    Accessible.name: "More controls"
                    Row {     // "»" double chevron
                        anchors.centerIn: parent; spacing: 0
                        Icon { name: "fwd"; size: 12; color: (ovMa.containsMouse || ovPopup.visible) ? Theme.accent : Theme.ink2 }
                        Icon { name: "fwd"; size: 12; color: (ovMa.containsMouse || ovPopup.visible) ? Theme.accent : Theme.ink2 }
                    }
                    MouseArea { id: ovMa; anchors.fill: parent; hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor; onClicked: ovPopup.open() }
                    C.ToolTip.visible: ovMa.containsMouse && !ovPopup.visible
                    C.ToolTip.text: "More controls"
                    C.ToolTip.delay: 400
                    C.Popup {
                        id: ovPopup
                        y: overflowBtn.height + 4
                        x: overflowBtn.width - width
                        width: 210; padding: 4
                        background: Rectangle { color: Theme.panel; border.color: Theme.line2; border.width: 1; radius: 2 }
                        contentItem: Column {
                            spacing: 0
                            component OvRow: Rectangle {
                                property string label: ""
                                property string icon: ""
                                signal triggered()
                                width: 202; height: 34
                                color: orMa.containsMouse ? Theme.panel2 : "transparent"
                                Row {
                                    anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                                    spacing: 9
                                    Icon { anchors.verticalCenter: parent.verticalCenter; name: icon; size: 15; color: Theme.ink2 }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: label
                                        color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13 }
                                }
                                MouseArea { id: orMa; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor; onClicked: { parent.triggered(); ovPopup.close() } }
                            }
                            OvRow { label: qsTr("Go back in time"); icon: "history"; onTriggered: root.wallPlaybackRequested() }
                            OvRow { label: qsTr("Save current view"); icon: "bookmark"; onTriggered: root.saveViewRequested() }
                            OvRow { label: root.arrangeMode ? qsTr("Done arranging") : qsTr("Arrange"); icon: "grid"
                                onTriggered: { root.arrangeMode = !root.arrangeMode; root.pickerCell = -1 } }
                            OvRow { visible: root.arrangeMode && root.hasArrangement
                                label: qsTr("Reset arrangement"); icon: "back"; onTriggered: root.resetArrangement() }
                            OvRow { label: qsTr("Full-screen"); icon: "full"; onTriggered: root.fullscreenToggled() }
                            Rectangle { width: 202; height: 1; color: Theme.line2 }   // divider before Sort
                            Text { leftPadding: 12; topPadding: 7; bottomPadding: 3
                                text: qsTr("SORT BY"); color: Theme.ink3; font.family: Theme.fontMono
                                font.pixelSize: 9; font.letterSpacing: 1 }
                            Repeater {
                                model: [ { id: "live", lbl: "Live first" }, { id: "ip", lbl: "IP address" }, { id: "default", lbl: "Stream order" },
                                         { id: "status", lbl: "Status first" }, { id: "alpha", lbl: "Alphabetical" } ]
                                delegate: Rectangle {
                                    required property var modelData
                                    width: 202; height: 30
                                    color: soMa.containsMouse ? Theme.panel2 : "transparent"
                                    Text { anchors { left: parent.left; leftMargin: 34; verticalCenter: parent.verticalCenter }
                                        text: modelData.lbl
                                        color: root.sortMode === modelData.id ? Theme.accent : Theme.ink
                                        font.family: Theme.fontSans; font.pixelSize: 12 }
                                    MouseArea { id: soMa; anchors.fill: parent; hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: { root.sortRequested(modelData.id); ovPopup.close() } }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Business-function "switched off" banner. Recording / Live View being off
        // is a deliberate operator state (admin stopped the containers), NOT a
        // fault — so this is calm amber, not red. Fail-safe: the model defaults
        // both to enabled, so this only appears on an explicit enabled:false.
        Rectangle {
            id: fnBanner
            // Fail-safe: only an explicit enabled:false counts as "off" (missing /
            // unknown reads as on), so a model without the field never false-alarms.
            readonly property bool recOff:  root.cameraModel ? (root.cameraModel.recordingEnabled === false) : false
            readonly property bool liveOff: root.cameraModel ? (root.cameraModel.liveViewEnabled === false) : false
            Layout.fillWidth: true
            Layout.leftMargin: root.fullscreen ? 4 : 20
            Layout.rightMargin: root.fullscreen ? 4 : 20
            Layout.topMargin: visible ? 8 : 0
            visible: recOff || liveOff
            Layout.preferredHeight: visible ? 40 : 0
            color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.10)
            border.color: Theme.accent; border.width: 1
            radius: 4
            Row {
                anchors { left: parent.left; leftMargin: 14; right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
                spacing: 10
                Icon { anchors.verticalCenter: parent.verticalCenter; name: "off"; size: 16; color: Theme.accent }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 26
                    elide: Text.ElideRight
                    color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12
                    text: (fnBanner.recOff && fnBanner.liveOff)
                          ? "Recording and Live View are switched off — no new footage, and live video/snapshots are unavailable. This is an operator setting, not a fault."
                          : (fnBanner.recOff
                             ? "Recording is switched off — no new footage is being recorded. This is an operator setting, not a fault."
                             : "Live View is switched off — live video and snapshots are unavailable. This is an operator setting, not a fault.")
                }
            }
        }

        // ---------------------------------------------------------- grid
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            Rectangle {
                id: gridFrame
                anchors.fill: parent
                anchors.leftMargin: root.fullscreen ? 4 : 20
                anchors.rightMargin: root.fullscreen ? 4 : 20
                anchors.topMargin: root.fullscreen ? 4 : 14
                anchors.bottomMargin: root.fullscreen ? 4 : 14
                color: Theme.line2
                visible: root.total > 0

                // The grid the tiles actually render in: feature layouts keep their
                // fixed cols×rows; everything else auto-fits to the cameras on the page
                // (recomputes on resize via width/height).
                readonly property var fitGrid: root.hasSpans
                    ? ({ cols: root.spanState.cols, rows: root.spanState.rows })
                    : root.isFeatureLayout
                    ? ({ cols: root.cols, rows: root.rows })
                    : LayoutSpec.bestGrid(root.fillCount, width, height, 16 / 9)

                // Manual cell positioning — NOT a QtQuick.Layouts GridLayout. On Qt 6.4.2 a
                // GridLayout SIGSEGVs in QQuickGridLayoutBase::rearrange after the window is
                // minimized and restored (a dangling attached-Layout access — reproduced by
                // maximize/minimize cycling). Computing each cell's x/y/w/h avoids the layout engine
                // entirely. Handles both auto-fit (1×1 cells) and feature spans (cw/ch). gSpace=1.
                Item {
                    id: gridArea
                    anchors.fill: parent
                    anchors.margins: 1
                    readonly property int gCols: Math.max(1, gridFrame.fitGrid.cols)
                    readonly property int gRows: Math.max(1, gridFrame.fitGrid.rows)
                    readonly property real gSpace: 1
                    readonly property real cellW: (width - (gCols - 1) * gSpace) / gCols
                    readonly property real cellH: (height - (gRows - 1) * gSpace) / gRows

                    // What the operator is carrying. Deliberately a label, not a live
                    // video copy — a second decode of the dragged camera for the length
                    // of a drag is real GPU cost on a wall already at its decode budget.
                    Rectangle {
                        id: dragGhost
                        visible: root.dragCell >= 0 && root.dragCamName !== ""
                        z: 200
                        width: ghostLabel.implicitWidth + 16
                        height: ghostLabel.implicitHeight + 10
                        radius: 3
                        color: Qt.rgba(0.10, 0.09, 0.07, 0.94)
                        border.width: 1; border.color: Theme.accent
                        Text {
                            id: ghostLabel
                            anchors.centerIn: parent
                            text: root.dragCamName
                            color: Theme.accent
                            font.family: Theme.fontSans; font.pixelSize: 12
                        }
                    }

                    Repeater {
                        id: gridRepeater
                        model: gridModel
                        delegate: Item {
                            id: cellWrap
                            required property int index
                            required property var cam      // the camera map (gridModel role)
                            readonly property var modelData: cam   // alias so the bindings below read unchanged
                            // Feature layouts place each tile in its fixed net cell
                            // (big tile spans); auto-fit grids place tiles row-major.
                            readonly property var cell: root.useFixedNet
                                ? (index < root.lcells.length ? root.lcells[index] : ({ c: 0, r: 0, cw: 1, ch: 1 }))
                                : ({ c: index % gridFrame.fitGrid.cols,
                                     r: Math.floor(index / gridFrame.fitGrid.cols), cw: 1, ch: 1 })
                            // Merged tile: auto-promote to HD within the wall's transcode
                            // budget — a 2×2 tile in SD would look worse than what it
                            // replaced. Demotion on split frees the slot.
                            readonly property bool isSpanned: cell.cw > 1 || cell.ch > 1
                            onIsSpannedChanged: {
                                if (isSpanned && !liveTile.useMainStream)
                                    liveTile.useMainStream = root.requestHdPromotion(false);
                                else if (!isSpanned && liveTile.useMainStream) {
                                    root.releaseHd(true);
                                    liveTile.useMainStream = false;
                                }
                            }
                            Component.onCompleted: {
                                if (isSpanned && !liveTile.useMainStream)
                                    liveTile.useMainStream = root.requestHdPromotion(false);
                            }
                            x: cell.c * (gridArea.cellW + gridArea.gSpace)
                            y: cell.r * (gridArea.cellH + gridArea.gSpace)
                            width: cell.cw * gridArea.cellW + (cell.cw - 1) * gridArea.gSpace
                            height: cell.ch * gridArea.cellH + (cell.ch - 1) * gridArea.gSpace

                            CameraTile {
                                id: liveTile
                                anchors.fill: parent
                                gridMode: true
                                eventsModel: root.eventModel   // ARMED badge motion-freshness
                                camModel: root.cameraModel     // badge state timers
                                // Live View off (go2rtc stopped by an operator) = a
                                // calm "switched off" tile, not a red fault.
                                liveViewEnabled: !(root.cameraModel && root.cameraModel.liveViewEnabled === false)
                                recordingEnabled: !(root.cameraModel && root.cameraModel.recordingEnabled === false)
                                camName: cellWrap.modelData.name
                                camId: cellWrap.modelData.camId
                                ip: cellWrap.modelData.ip
                                hwModel: cellWrap.modelData.model || ""
                                groupId: cellWrap.modelData.groupId
                                groupName: cellWrap.modelData.groupName
                                live: cellWrap.modelData.live
                                recording: cellWrap.modelData.recording
                                favorite: cellWrap.modelData.favorite
                                hasAudio: cellWrap.modelData.hasAudio === true
                                audioRecording: cellWrap.modelData.audioRecording === true
                                timestamp: cellWrap.modelData.timestamp
                                lastSeen: cellWrap.modelData.lastSeen
                                lastSegmentAt: cellWrap.modelData.lastSegmentAt
                                motionKnown: cellWrap.modelData.motionKnown === true
                                motionReady: cellWrap.modelData.motionReady === true
                                motionLastVmdAt: cellWrap.modelData.motionLastVmdAt ? cellWrap.modelData.motionLastVmdAt : ""
                                pattern: cellWrap.modelData.pattern
                                rtspUrl: cellWrap.modelData.rtspUrl
                                rtspSubUrl: cellWrap.modelData.rtspSubUrl
                                // Only play when Live Monitor is the visible section (so other
                                // screens don't hold open streams / hit cameras) AND not while
                                // arranging. Keeping the 16 VA-API decodes alive across the
                                // arrange/picker churn — or tearing them down per picker-open — balloons
                                // GPU/decode memory to ~8 GB and OOM-kills the app. Arrange only needs to
                                // IDENTIFY cameras (name + thumbnail in the picker), not watch them live,
                                // so the tiles drop to their placeholder during arrange and rebuild
                                // (staggered, via the build pump — no relayout freeze) on exit.
                                // WT_TEST_IP (dev) restricts streaming to a single camera.
                                videoActive: root.visible && !root.arrangeMode
                                    && ((typeof wtTestIp !== "undefined" && wtTestIp !== "")
                                        ? (cellWrap.modelData.ip === wtTestIp) : true)
                                // While arranging, a tap must pick a camera for the cell (arrange
                                // overlay), NOT open the camera full-screen — disable tap-to-open.
                                tapToOpen: !root.arrangeMode
                                // Live VA-API pipeline only for the cameras in the importance-ranked
                                // live set (armed first, then position) — capped at maxLiveDecodes; the
                                // rest show a periodic go2rtc snapshot (bounds GPU/decode memory).
                                liveDecodeAllowed: !!root.liveDecodeSet[cellWrap.modelData.camId]
                                snapshotUrl: cellWrap.modelData.snapshotUrl || ""
                                // HD promotion is gated by the wall's concurrency
                                // cap; teardown (paging/relayout) frees the slot.
                                onHdToggleRequested: liveTile.useMainStream =
                                    root.requestHdPromotion(liveTile.useMainStream)
                                Component.onDestruction: root.releaseHd(liveTile.useMainStream)
                                onSnapshotSaved: (p, n) => root.snapshotSaved(p, n)
                                onOpened: root.cameraOpened(cellWrap.modelData)
                                onPlayed: root.cameraPlaybackRequested(cellWrap.modelData)
                                onIssueRequested: root.cameraIssueRequested(cellWrap.modelData)
                                onOpenedNewTab: root.cameraOpenedNewTab(cellWrap.modelData)
                                spanned: cellWrap.isSpanned
                                onSplitRequested: root.splitAt(cellWrap.cell.c, cellWrap.cell.r)
                                // Favorite is persisted in CameraModel (keyed by camera_id);
                                // flip the tile optimistically so it reflects instantly (the
                                // paged snapshot won't re-fetch until the next page() call).
                                onFavoriteToggled: {
                                    favorite = !favorite;
                                    if (root.cameraModel) root.cameraModel.toggleFavoriteById(cellWrap.modelData.camId);
                                }
                            }

                            // arrange-mode overlay — tap to choose the camera for this cell
                            Rectangle {
                                anchors.fill: parent
                                visible: root.arrangeMode
                                readonly property bool isDropTarget:
                                    root.dragCell >= 0 && root.dropCell === cellWrap.index
                                                       && root.dropCell !== root.dragCell
                                readonly property bool isDragSource: root.dragCell === cellWrap.index
                                color: isDropTarget ? Qt.rgba(0.91, 0.63, 0.23, 0.30)
                                     : isDragSource ? Qt.rgba(0, 0, 0, 0.72)
                                     : cellOvMa.containsMouse ? Qt.rgba(0, 0, 0, 0.32)
                                                              : Qt.rgba(0, 0, 0, 0.58)
                                border.width: isDropTarget ? 3 : 2
                                border.color: Theme.accent
                                Column {
                                    anchors.centerIn: parent; spacing: 4; width: parent.width - 16
                                    Text { anchors.horizontalCenter: parent.horizontalCenter
                                        text: (cellWrap.index === 0 && root.lspec.big) ? qsTr("CENTER") : ("CELL " + (cellWrap.index + 1))
                                        color: Theme.accent; font.family: Theme.fontMono; font.pixelSize: 11; font.weight: Font.Bold; font.letterSpacing: 1 }
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; width: parent.width
                                        horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
                                        text: cellWrap.modelData.name; color: "#fff"; font.family: Theme.fontSans; font.pixelSize: 13; font.weight: Font.DemiBold }
                                    Text { anchors.horizontalCenter: parent.horizontalCenter
                                        text: qsTr("Tap to change"); color: Qt.rgba(1, 1, 1, 0.7); font.family: Theme.fontSans; font.pixelSize: 11 }
                                }
                                MouseArea {
                                    id: cellOvMa
                                    anchors.fill: parent; hoverEnabled: true
                                    cursorShape: root.dragCell >= 0 ? Qt.ClosedHandCursor : Qt.PointingHandCursor
                                    // Click still opens the picker; a drag past the
                                    // threshold becomes a move instead, and then the
                                    // release must NOT also open the picker.
                                    property bool moved: false
                                    property real pressX: 0
                                    property real pressY: 0
                                    onPressed: (m) => {
                                        moved = false; pressX = m.x; pressY = m.y;
                                        root.dragCell = cellWrap.index;
                                        root.dropCell = cellWrap.index;
                                        root.dragCamId = cellWrap.modelData.camId;
                                        root.dragCamName = cellWrap.modelData.name;
                                    }
                                    onPositionChanged: (m) => {
                                        if (root.dragCell < 0) return;
                                        // Threshold first: a shaky click must stay a click,
                                        // or every picker open becomes an accidental move.
                                        if (!moved
                                            && Math.abs(m.x - pressX) < 6
                                            && Math.abs(m.y - pressY) < 6) return;
                                        moved = true;
                                        var pt = mapToItem(gridArea, m.x, m.y);
                                        dragGhost.x = pt.x + 10;
                                        dragGhost.y = pt.y + 10;
                                        var c = Math.floor(pt.x / (gridArea.cellW + gridArea.gSpace));
                                        var r = Math.floor(pt.y / (gridArea.cellH + gridArea.gSpace));
                                        root.dropCell = (c < 0 || r < 0 || c >= gridArea.gCols || r >= gridArea.gRows)
                                                        ? -1 : root.cellIndexAt(c, r, gridArea.gCols);
                                    }
                                    onReleased: {
                                        if (moved) root.dropOnCell(root.dropCell);
                                        else { root.cancelDrag(); root.openCellPicker(cellWrap.index); }
                                    }
                                    onCanceled: root.cancelDrag()
                                }
                            }

                            // Right-click anywhere on the cell → open the camera
                            // picker for this slot (works in normal AND arrange mode).
                            // Accepts only the right button, so left-clicks pass
                            // straight through to the tile controls / arrange overlay.
                            MouseArea {
                                anchors.fill: parent
                                acceptedButtons: Qt.RightButton
                                onClicked: root.openCellPicker(cellWrap.index)
                            }
                        }
                    }

                    // Dark "empty slot" fillers — a partially-filled auto-fit grid shows
                    // intentional empty cells (camera-tile background) rather than the gray
                    // grid frame bleeding through. Feature layouts manage their own cells.
                    Repeater {
                        model: root.useFixedNet ? 0
                             : Math.max(0, gridFrame.fitGrid.cols * gridFrame.fitGrid.rows - root.fillCount)
                        delegate: Rectangle {
                            required property int index
                            readonly property int ci: root.fillCount + index
                            x: (ci % gridArea.gCols) * (gridArea.cellW + gridArea.gSpace)
                            y: Math.floor(ci / gridArea.gCols) * (gridArea.cellH + gridArea.gSpace)
                            width: gridArea.cellW
                            height: gridArea.cellH
                            color: Theme.tileBg
                        }
                    }

                    // ---- merge selection: Shift+drag rubber-band -----------------
                    // A modifier gate keeps plain click (open camera) and plain drag
                    // (reserved for future drag-swap) untouched: an unmodified press
                    // is rejected and falls through to the tiles below.
                    MouseArea {
                        id: selMa
                        anchors.fill: parent
                        z: 60
                        enabled: !root.arrangeMode && root.pickerCell < 0
                        acceptedButtons: Qt.LeftButton
                        property bool draggingSel: false
                        function cellAt(px, py) {
                            var c = Math.floor(px / (gridArea.cellW + gridArea.gSpace));
                            var r = Math.floor(py / (gridArea.cellH + gridArea.gSpace));
                            if (c < 0 || r < 0 || c >= gridArea.gCols || r >= gridArea.gRows) return null;
                            return { c: c, r: r };
                        }
                        onPressed: (m) => {
                            if (!(m.modifiers & Qt.ShiftModifier) && !(m.modifiers & Qt.ControlModifier)) {
                                m.accepted = false;             // plain press → the tile handles it
                                return;
                            }
                            var c = cellAt(m.x, m.y);
                            if (c === null) { m.accepted = false; return; }
                            if (m.modifiers & Qt.ControlModifier) {
                                // Ctrl+click: select a merged tile whole (arms Split),
                                // else grow the rectangle to include this cell.
                                var g = root.regionAt(c.c, c.r);
                                if (g && root.mergeSel === null)
                                    root.mergeSel = { c0: g.c, r0: g.r, c1: g.c + g.cw - 1,
                                                      r1: g.r + g.ch - 1, ac: g.c, ar: g.r };
                                else root.extendSel(c);
                            } else {
                                // Shift: extend from the existing anchor (Excel), else start.
                                if (root.mergeSel !== null) root.extendSel(c);
                                else root.startSel(c);
                                draggingSel = true;
                            }
                        }
                        onPositionChanged: (m) => {
                            if (!draggingSel) return;
                            var c = cellAt(m.x, m.y);
                            if (c !== null) root.extendSel(c);
                        }
                        onReleased: draggingSel = false
                    }
                    // Selection highlight — the arrange overlay's visual language.
                    Rectangle {
                        visible: root.mergeSel !== null
                        z: 55
                        x: root.mergeSel ? root.mergeSel.c0 * (gridArea.cellW + gridArea.gSpace) : 0
                        y: root.mergeSel ? root.mergeSel.r0 * (gridArea.cellH + gridArea.gSpace) : 0
                        width: root.mergeSel ? root._selW * gridArea.cellW + (root._selW - 1) * gridArea.gSpace : 0
                        height: root.mergeSel ? root._selH * gridArea.cellH + (root._selH - 1) * gridArea.gSpace : 0
                        color: Theme.accentSoft
                        border.width: 2
                        border.color: Theme.accent
                    }
                    // Floating action pill: Merge / Split / honest hint. Never a
                    // silent no-op — an unusable selection says why.
                    Rectangle {
                        id: mergePill
                        visible: root.mergeSel !== null
                        z: 70
                        readonly property bool canAct: !root.isFeatureLayout
                            && (root.selIsRegion || root._selW * root._selH >= 2)
                        readonly property string label:
                            root.isFeatureLayout ? qsTr("Merging isn't available on this layout")
                            : root.selIsRegion ? qsTr("Split %1×%2").arg(root._selW).arg(root._selH) + "  —  M"
                            : (root._selW * root._selH >= 2)
                              ? qsTr("Merge %1×%2").arg(root._selW).arg(root._selH)
                                + (root.selAnchorName !== "" ? " · " + root.selAnchorName : "") + "  —  M"
                              : qsTr("Shift+drag to select cells to merge")
                        x: {
                            if (!root.mergeSel) return 0;
                            var cx = (root.mergeSel.c0 + root._selW / 2) * (gridArea.cellW + gridArea.gSpace);
                            return Math.max(4, Math.min(gridArea.width - width - 4, cx - width / 2));
                        }
                        y: {
                            if (!root.mergeSel) return 0;
                            var by = (root.mergeSel.r1 + 1) * (gridArea.cellH + gridArea.gSpace) + 6;
                            return (by + height > gridArea.height - 4)
                                   ? Math.max(4, root.mergeSel.r0 * (gridArea.cellH + gridArea.gSpace) - height - 6)
                                   : by;
                        }
                        width: pillRow.implicitWidth + 24
                        height: 34
                        color: pillMa.containsMouse && canAct ? Theme.accent : Theme.panel
                        border.width: 1
                        border.color: canAct ? Theme.accent : Theme.line2
                        Row {
                            id: pillRow
                            anchors.centerIn: parent
                            spacing: 8
                            Icon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: root.selIsRegion ? "split" : "grid"
                                size: 13
                                color: pillMa.containsMouse && mergePill.canAct ? Theme.bg
                                     : mergePill.canAct ? Theme.accent : Theme.ink3
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: mergePill.label
                                color: pillMa.containsMouse && mergePill.canAct ? Theme.bg
                                     : mergePill.canAct ? Theme.ink : Theme.ink2
                                font.family: Theme.fontSans
                                font.pixelSize: 12
                                font.weight: Font.Medium
                            }
                        }
                        MouseArea {
                            id: pillMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: mergePill.canAct ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: if (mergePill.canAct) root.mergeSelection()
                        }
                    }
                }
            }

            // Brief gap between sign-in and the first /streams response.
            LoadingState {
                anchors.centerIn: parent
                visible: root.total === 0 && !root.fullscreen
                        && root.cameraModel && root.cameraModel.loading
                label: qsTr("Loading cameras…")
            }

            // Empty grid: distinguish an empty roster (no camera access — provisioned
            // in Cilex Vision) from a filter/group that simply matched nothing.
            EmptyState {
                anchors.fill: parent
                anchors.margins: 24
                visible: root.total === 0 && !root.fullscreen
                        && !(root.cameraModel && root.cameraModel.loading)
                icon: root.rosterUnavailable() ? "alert" : "monitor"
                title: root.emptyTitle()
                subtitle: root.emptySubtitle()
            }

            // floating exit button in full-screen
            Rectangle {
                visible: root.fullscreen
                anchors { top: parent.top; right: parent.right; topMargin: 12; rightMargin: 12 }
                implicitWidth: exitRow.implicitWidth + 24
                height: 34
                color: Qt.rgba(0.10, 0.094, 0.086, 0.85)
                border.width: 1
                border.color: Theme.line2
                Row {
                    id: exitRow
                    anchors.centerIn: parent
                    spacing: 8
                    Icon { anchors.verticalCenter: parent.verticalCenter; name: "x"; size: 14; color: Theme.ink }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Exit full-screen")
                        color: Theme.ink
                        font.family: Theme.fontSans
                        font.pixelSize: 12
                        font.weight: Font.Medium
                    }
                }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.fullscreenToggled() }
            }
        }

        // ---------------------------------------------------------- page bar
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 40
            visible: !root.fullscreen
            color: Theme.bg
            Rectangle {
                anchors { left: parent.left; right: parent.right; top: parent.top }
                height: 1; color: Theme.line
            }
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 20
                anchors.rightMargin: 20
                spacing: 12
                Text {
                    text: qsTr("%1 · %2 cameras · Page %3 of %4").arg(root.groupLabel).arg(root.total).arg(root.page).arg(root.pageCount)
                    color: Theme.ink3
                    font.family: Theme.fontMono
                    font.pixelSize: Theme.fsMono
                }
                // Discoverability for the modifier gesture (the cost of not burning
                // plain drag): a quiet standing hint, brighter while a selection is up.
                Text {
                    visible: !root.isFeatureLayout
                    text: root.mergeSel !== null
                          ? qsTr("M — merge · Esc — cancel").toUpperCase()
                          : qsTr("⇧ drag — merge cells").toUpperCase()
                    color: root.mergeSel !== null ? Theme.accent : Theme.ink3
                    font.family: Theme.fontMono
                    font.pixelSize: 9
                    font.letterSpacing: 0.8
                }
                Item { Layout.fillWidth: true }
                PaginationControl {
                    page: root.page
                    pageCount: root.pageCount
                    rangeText: root.rangeText
                    onPrev: root.pageRequested(root.page - 1)
                    onNext: root.pageRequested(root.page + 1)
                }
            }
        }
    }

    // Camera picker for arrange mode: tap a cell → choose which camera occupies it.
    Rectangle {
        anchors.fill: parent
        visible: root.pickerCell >= 0
        z: 200
        color: Qt.rgba(0, 0, 0, 0.6)
        MouseArea { anchors.fill: parent; onClicked: root.pickerCell = -1 }   // tap-out closes

        Rectangle {
            anchors.centerIn: parent
            // Dynamic: grows to fit the thumbnail grid, capped to the screen.
            width: Math.min(parent.width - 32, root._pg.cols * root._pg.cellW + 36)
            height: Math.min(parent.height - 32, root._pg.rows * root._pg.cellH + root._pickChrome)
            color: Theme.panel; border.color: Theme.line2; border.width: 1
            MouseArea { anchors.fill: parent }   // swallow clicks inside the panel

            ColumnLayout {
                anchors.fill: parent; anchors.margins: 16; spacing: 12

                Text {
                    Layout.fillWidth: true
                    text: qsTr("Camera for ") + ((root.pickerCell === 0 && root.lspec.big) ? "the center cell" : ("cell " + (root.pickerCell + 1)))
                    color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 15; font.weight: Font.DemiBold
                }

                // Group filter — qsTr("All cameras") + each configured group as pills.
                Flow {
                    Layout.fillWidth: true; spacing: 6
                    visible: root.groupOpts.length > 1
                    Repeater {
                        model: root.groupOpts
                        delegate: Rectangle {
                            required property var modelData
                            readonly property bool sel: root.pickerGroup === modelData.id
                            height: 26; width: gpTxt.implicitWidth + 20; radius: 13
                            color: sel ? Theme.accent : Theme.bg
                            border.width: 1; border.color: sel ? Theme.accent : Theme.line2
                            Text {
                                id: gpTxt; anchors.centerIn: parent; text: modelData.name
                                color: sel ? Theme.bg : Theme.ink2
                                font.family: Theme.fontSans; font.pixelSize: 12
                            }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                onClicked: root.pickerGroup = modelData.id }
                        }
                    }
                }

                // Search + a toggle to hide cameras already on the visible wall.
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 34
                        color: Theme.bg; border.color: Theme.line2; border.width: 1
                        C.TextField {
                            anchors.fill: parent; anchors.margins: 1
                            text: root.pickerSearch
                            onTextChanged: root.pickerSearch = text
                            placeholderText: qsTr("Search cameras…")
                            color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13
                            leftPadding: 10; verticalAlignment: TextInput.AlignVCenter
                            background: Rectangle { color: "transparent" }
                        }
                    }
                    Rectangle {
                        Layout.preferredHeight: 34; Layout.preferredWidth: hideTxt.implicitWidth + 24
                        color: root.pickerHideShown ? Theme.accent : Theme.bg
                        border.width: 1; border.color: root.pickerHideShown ? Theme.accent : Theme.line2
                        Text {
                            id: hideTxt; anchors.centerIn: parent
                            text: qsTr("Hide on-wall")
                            color: root.pickerHideShown ? Theme.bg : Theme.ink2
                            font.family: Theme.fontSans; font.pixelSize: 12
                        }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: root.pickerHideShown = !root.pickerHideShown }
                    }
                }

                GridView {
                    id: pickGrid
                    Layout.fillWidth: true; Layout.fillHeight: true
                    clip: true
                    cellWidth: root._pg.cellW
                    cellHeight: root._pg.cellH
                    model: root.pickModel
                    delegate: Item {
                        id: pickCell
                        required property var modelData
                        readonly property bool onWall: root.displayedIds[modelData.camId] === true
                        width: pickGrid.cellWidth; height: pickGrid.cellHeight
                        // Ask the load limiter for a fetch slot when the picker is open.
                        property bool _counted: false   // released our slot for the current load?
                        function _request() {
                            // Load while EITHER arranging (pre-warm) or the picker is open. Pre-warming on
                            // arrange-enter means the snapshots are already in flight (often done) by the
                            // time a cell is tapped, and the source stays set across open/close so re-opens
                            // are instant instead of re-fetching every go2rtc frame.jpeg.
                            if (root.arrangeMode || root.pickerCell >= 0) { pickCell._counted = false; root._thumbWant(modelData.camId); }
                        }
                        Component.onCompleted: _request()                       // delegate created while picker open
                        Connections { target: root
                            function onPickerCellChanged() { pickCell._request() }
                            function onArrangeModeChanged() { pickCell._request() }   // pre-warm on entering Arrange
                        }
                        Rectangle {
                            anchors.fill: parent; anchors.margins: 4
                            color: cmA.containsMouse ? Theme.panel2 : Theme.bg
                            border.width: 1; border.color: cmA.containsMouse ? Theme.accent : Theme.line2
                            Column {
                                anchors.fill: parent; anchors.margins: 6; spacing: 3
                                // tiny live thumbnail (fetch-once go2rtc sub-stream still)
                                Rectangle {
                                    width: parent.width; height: Math.round(parent.width * 9 / 16)
                                    color: "#0b0b0c"; clip: true
                                    Image {
                                        id: thumb; anchors.fill: parent
                                        fillMode: Image.PreserveAspectCrop
                                        asynchronous: true; cache: true
                                        // Decode at thumbnail size, NOT the camera's full resolution —
                                        // a go2rtc frame.jpeg can be 2560×1440 (~14 MB decoded); at ~24
                                        // tiles that's hundreds of MB of pixmaps for cells a few cm wide.
                                        sourceSize.width: 480
                                        // Backend snapshot URL (go2rtc frame.jpeg) when present, else a
                                        // client-derived sub-stream frame. Skip the fetch when the picker
                                        // is closed (these GridView delegates exist even when hidden — don't
                                        // fetch snapshots for every camera in the background), when Live View
                                        // is off (snapshots would 404), or when this camera's snapshot has
                                        // already failed to decode once (don't re-spam — show the initial).
                                        // Show the snapshot when it's ALREADY loaded (_thumbLoaded — stays put
                                        // across open/close so re-opens are instant), OR when the picker is
                                        // active (arranging or open) AND the load limiter has admitted this
                                        // camera (_thumbGranted). Never fetch for an off Live View or a snapshot
                                        // that already failed to decode (show the camera initial instead).
                                        source: ((root.cameraModel && root.cameraModel.liveViewEnabled === false)
                                                 || root._snapFailed[pickCell.modelData.camId]
                                                 || !(root._thumbLoaded[pickCell.modelData.camId]
                                                      || ((root.arrangeMode || root.pickerCell >= 0)
                                                          && root._thumbGranted[pickCell.modelData.camId]))) ? ""
                                                : root._thumbUrl(pickCell.modelData)
                                        onStatusChanged: {
                                            // Mark loaded (keep-alive across open/close) the first time it's Ready.
                                            if (status === Image.Ready && pickCell.modelData && pickCell.modelData.camId
                                                && !root._thumbLoaded[pickCell.modelData.camId]) {
                                                var L = {};
                                                for (var lk in root._thumbLoaded) L[lk] = root._thumbLoaded[lk];
                                                L[pickCell.modelData.camId] = true; root._thumbLoaded = L;
                                            }
                                            // Release the limiter slot once the fetch settles (Ready or Error),
                                            // exactly once, so the next queued thumbnail can start.
                                            if (!pickCell._counted && (status === Image.Ready || status === Image.Error)) {
                                                pickCell._counted = true;
                                                if (status === Image.Error && pickCell.modelData && pickCell.modelData.camId) {
                                                    // record + stop retrying this camera's snapshot (fresh object → re-eval)
                                                    var m = {};
                                                    for (var k in root._snapFailed) m[k] = root._snapFailed[k];
                                                    m[pickCell.modelData.camId] = true;
                                                    root._snapFailed = m;
                                                }
                                                root._thumbRelease();
                                            }
                                        }
                                    }
                                    // placeholder: "Live View off" when disabled, else loading dots /
                                    // the camera initial while or if the frame doesn't load.
                                    Text {
                                        anchors.centerIn: parent
                                        visible: thumb.status !== Image.Ready
                                        text: (root.cameraModel && root.cameraModel.liveViewEnabled === false) ? "Live View off"
                                              : (thumb.status === Image.Loading ? "…"
                                                 : (("" + pickCell.modelData.name).charAt(0).toUpperCase() || "?"))
                                        color: Theme.ink3; font.family: Theme.fontSans
                                        font.pixelSize: (root.cameraModel && root.cameraModel.liveViewEnabled === false) ? 10 : 18
                                    }
                                    Rectangle { x: 5; y: 5; width: 7; height: 7; radius: 4
                                        color: pickCell.modelData.live ? Theme.good : Theme.ink3 }
                                    Rectangle {
                                        visible: pickCell.onWall
                                        anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 4
                                        height: 15; width: owT.implicitWidth + 8; radius: 7
                                        color: Qt.rgba(0, 0, 0, 0.66); border.color: Theme.accent; border.width: 1
                                        Text { id: owT; anchors.centerIn: parent; text: qsTr("ON WALL"); color: Theme.accent
                                            font.family: Theme.fontMono; font.pixelSize: 8; font.weight: Font.Bold }
                                    }
                                }
                                Text { width: parent.width; text: pickCell.modelData.name
                                    color: pickCell.onWall ? Theme.ink2 : Theme.ink
                                    font.family: Theme.fontSans; font.pixelSize: 12; elide: Text.ElideRight }
                                Text { width: parent.width; text: pickCell.modelData.ip; color: Theme.ink3
                                    font.family: Theme.fontMono; font.pixelSize: 10; elide: Text.ElideRight }
                            }
                            MouseArea { id: cmA; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: root.assignToCell(root.pickerCell, pickCell.modelData.camId) }
                        }
                    }
                    // Honest empty state when filters leave nothing to pick.
                    Text {
                        anchors.centerIn: pickGrid
                        width: pickGrid.width - 32
                        visible: pickGrid.count === 0
                        horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                        text: root.pickerHideShown
                              ? "Every matching camera is already on the wall."
                              : ((root.pickerSearch !== "" || root.pickerGroup !== "")
                                 ? qsTr("No cameras match.") : qsTr("No cameras available."))
                        color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 13
                    }
                }

                Text {
                    Layout.alignment: Qt.AlignRight
                    text: qsTr("Cancel"); color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 13
                    MouseArea { anchors.fill: parent; anchors.margins: -10; cursorShape: Qt.PointingHandCursor; onClicked: root.pickerCell = -1 }
                }
            }
        }
    }
}
