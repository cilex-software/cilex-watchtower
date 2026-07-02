import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import Watchtower

// Application shell (design §10): nav rail · top bar · Live Monitor + ops
// sidebar. Owns the Live Monitor view state; child screens request changes.
Window {
    id: win
    width: 1440
    height: 900
    visible: true
    color: Theme.bg
    title: qsTr("Watchtower")

    property string section: (typeof wtSection !== "undefined" && wtSection !== "") ? wtSection : "live"
    property string gridLayout: "16"     // canonical layout id (see LayoutSpec)
    property int gridPage: 1
    property string statusFilter: (typeof wtStatusFilter !== "undefined" && wtStatusFilter !== "") ? wtStatusFilter : ""
    // Live wall leads with cameras that are actually live (offline tiles sink to the
    // last page). Overridable via the Sort menu, and a saved view / manual arrangement
    // still wins. See CameraModel "live" sort.
    property string sortMode: "live"
    property string groupFilter: ""
    property string groupLabel: "All cameras"
    property bool fullscreen: false
    property var focusedCamera: null    // shows Single Camera Detail when non-null
    property var playbackCamera: null   // shows Playback (S06) when non-null
    property string wallMode: "live"    // "live" | "playback" (synchronized wall review)
    property bool opsSidebarOpen: true  // Live page right-hand panel (OpsSidebar) — toggled from the Live toolbar

    // --- Resize stress-test driver (WT_RESIZE_TEST): drives programmatic resizes for the external
    //     CPU/RSS sampler. Phase 1 (0-120s) random non-extreme sizes; phase 2 (120-240s) degenerate
    //     edge cases. Logs requested + actual-granted size each tick (timestamps align with the sampler).
    property double _rtStart: 0
    property int _rtN: 0
    Timer {
        running: typeof wtResizeTest !== "undefined" && wtResizeTest === true
        interval: 400; repeat: true
        readonly property var extremes: [[1,1],[1920,40],[40,1080],[3000,60],[60,2000],[100,100],
            [2560,1440],[1,900],[900,1],[3840,2160],[200,1200],[1200,200],[50,50],[1600,30],[30,1600]]
        onTriggered: {
            if (win._rtStart === 0) { win._rtStart = Date.now(); console.log("[RT] START t=" + Date.now()); }
            if (win._rtN > 0) console.log("[RT] act " + win.width + "x" + win.height + " t=" + Date.now());
            var el = (Date.now() - win._rtStart) / 1000.0;
            if (el > 240) { console.log("[RT] DONE n=" + win._rtN + " t=" + Date.now()); Qt.quit(); return; }
            var w, h, ph;
            if (el < 120) { ph = "normal"; w = 600 + Math.floor(Math.random()*840); h = 400 + Math.floor(Math.random()*500); }
            else if (Math.random() < 0.6) { ph = "extreme"; var e = extremes[Math.floor(Math.random()*extremes.length)]; w = e[0]; h = e[1]; }
            else { ph = "extreme"; w = 1 + Math.floor(Math.random()*4000); h = 1 + Math.floor(Math.random()*2500); }
            win._rtN++;
            console.log("[RT] req " + w + "x" + h + " ph=" + ph + " n=" + win._rtN + " t=" + Date.now());
            win.width = w; win.height = h;
        }
    }

    // Enter synchronized wall playback. Seeds from the operator's persisted wall
    // layout when one exists, else from the cameras currently on the wall page.
    function enterWallPlayback() {
        var per = ({ "1": 1, "4": 4, "9": 9, "16": 16 })[gridLayout] || 16;
        wallPlayback.seedCameras(cameraModel.page(groupFilter, statusFilter, sortMode, gridPage, per));
        wallMode = "playback";
        wallPlayback.openFor();
    }

    // Enter wall playback over an EXPLICIT camera set (the Situation-Map selection),
    // bypassing the persisted wall layout. Resolves backend ids → camera objects,
    // clears any overlay, switches to the live section's wall, composites the hour.
    function enterWallWithCameras(ids) {
        if (!ids || ids.length === 0) return;
        var cams = [];
        for (var i = 0; i < ids.length && cams.length < 16; i++) {
            var c = cameraModel.cameraByBackendId(ids[i]);
            if (c && c.camId) cams.push(c);
        }
        if (cams.length === 0) return;
        focusedCamera = null;
        playbackCamera = null;
        section = "live";
        wallMode = "playback";
        wallPlayback.openWithCameras(cams);
    }

    // Show the LIVE feed of an explicit camera set (the Situation-Map selection) in
    // the Live Monitor. Scopes the grid to a "__selected__" pseudo-group (handled in
    // CameraModel.matches), so the group switcher's "All cameras" cleanly exits it.
    function enterLiveWithCameras(ids) {
        if (!ids || ids.length === 0 || !cameraModel) return;
        cameraModel.setSelectedCameras(ids);
        var n = Math.min(ids.length, 16);
        gridLayout = n <= 1 ? "1" : n <= 4 ? "4" : n <= 9 ? "9" : "16";   // fit the grid to the count
        gridPage = 1;
        statusFilter = "";                 // show every selected camera regardless of status
        groupFilter = "__selected__";
        groupLabel = "Selected (" + ids.length + ")";
        focusedCamera = null;
        playbackCamera = null;
        wallMode = "live";
        section = "live";
    }

    // Left-rail navigation. Camera detail, single-camera playback, and wall
    // playback are full-screen overlays that layer OVER a section (they gate on
    // focusedCamera / playbackCamera / wallMode, not on `section`), so setting
    // `section` alone leaves them up and the rail looks dead — e.g. clicking LIVE
    // while already in wall playback (section is already "live") wouldn't exit it.
    // Clear every overlay so a rail click always lands on that section's main view.
    function goToSection(sid) {
        focusedCamera = null;
        playbackCamera = null;
        wallMode = "live";
        section = sid;
    }

    // ---- WT_GUARD_SOAK: long-run guard-usage ENDURANCE + STRESS emulator (inert unless wtGuardSoak) ----
    // Drives heavy, realistic guard interaction so a long run exercises the leak-prone paths, not just nav:
    //  · Live   — fullscreen random cameras, REPLACE/swap random cameras into random tiles (the historical
    //             swap-leak path), and change layouts (1/4/9/16);
    //  · Events — cycle all four tabs (Triage / Review / Timeline / Map) and play random event videos (hero);
    //  · Wall   — enter playback and re-arrange (swap) cells repeatedly (re-composites the mosaic).
    // Logs [GUARD] t=<epoch> step=<name> on each action so the sampler can attribute RSS/CPU + count actions.
    Timer {
        id: guardSoak
        property int step: 0
        readonly property int liveMs: (typeof wtGuardLiveMs !== "undefined" && wtGuardLiveMs > 0) ? wtGuardLiveMs : 180000
        // random pickers over the live roster / a page tile / a wall slot
        function _roster() { return cameraModel ? cameraModel.page(win.groupFilter, "", win.sortMode, 1, 64) : []; }
        function _randCam() { var c = guardSoak._roster(); return c.length ? c[Math.floor(Math.random() * c.length)] : null; }
        function _randCamId() { var c = guardSoak._randCam(); return c ? c.camId : ""; }
        function _perPage() { return ({ "1": 1, "4": 4, "9": 9, "16": 16 })[win.gridLayout] || 16; }
        function _fs() { var c = guardSoak._randCam(); if (c) win.focusedCamera = c; }       // double-click → fullscreen
        function _fsExit() { win.focusedCamera = null; }
        // right-click → pick a replacement camera for a random tile, N times (the swap-leak path)
        function _replaceN(n) {
            for (var i = 0; i < n; i++) {
                var t = Math.floor(Math.random() * guardSoak._perPage());
                liveMonitor.openCellPicker(t); liveMonitor.assignToCell(t, guardSoak._randCamId());
            }
            liveMonitor.pickerCell = -1;
        }
        function _wallSwapN(n) { for (var i = 0; i < n; i++) wallPlayback.swapSlots(Math.floor(Math.random() * 16), Math.floor(Math.random() * 16)); }
        // ---- single-camera PLAYBACK: calendar + historic scrubbing (with cameras unplugged, playback for
        // other cameras runs off stored footage — the "playbacks don't work / very slow" path) ----
        property int _pbDayOff: 0
        property int _pbCamIdx: 0
        property int _pbCount: 0
        function _pbCam() { var c = guardSoak._roster(); return c.length ? c[guardSoak._pbCamIdx % c.length] : null; }
        function _pbDayStr(off) { var d = new Date(); d.setDate(d.getDate() - off); return Qt.formatDate(d, "yyyy-MM-dd"); }
        function _pbOpen() {                              // open the current camera's current day → plays if footage
            var c = guardSoak._pbCam(); if (!c) return;
            win.focusedCamera = c; win.playbackCamera = c; playbackScreen.camera = c;
            playbackScreen.openForDay(guardSoak._pbDayStr(guardSoak._pbDayOff));
            guardSoak._pbCount++;
        }
        function _pbScrub() {                             // seek within the loaded footage (historic scrub)
            if (playbackScreen.advancing && playbackScreen.tlEndMs > playbackScreen.tlStartMs) {
                var f = ((guardSoak._pbCount % 5) + 1) / 6.0;
                playbackScreen.seekToWall(playbackScreen.tlStartMs + f * (playbackScreen.tlEndMs - playbackScreen.tlStartMs));
            }
        }
        function _pbSweep(n) {                            // rapid day-clicks = the teardown-churn / ".201 stops responding" path
            for (var i = 0; i < n; i++) {
                guardSoak._pbDayOff = (guardSoak._pbDayOff + 1) % 14;   // sweep the last 14 days
                var c = guardSoak._pbCam(); if (c) { win.playbackCamera = c; playbackScreen.camera = c; }
                playbackScreen.openForDay(guardSoak._pbDayStr(guardSoak._pbDayOff));
            }
            guardSoak._pbCamIdx++;                        // next camera after each sweep
        }
        readonly property var seq: [
            // ---- LIVE: monitor, then heavy interaction (fullscreen, replace/swap, layouts) ----
            { name: "live",               dwell: liveMs, fn: function(){ win.goToSection("live"); liveMonitor.resetArrangement(); win.setLayout("16"); } },
            { name: "live-fullscreen",    dwell: 6000,   fn: function(){ guardSoak._fs(); } },
            { name: "live-fs-exit",       dwell: 35000,  fn: function(){ guardSoak._fsExit(); } },
            { name: "live-fullscreen2",   dwell: 6000,   fn: function(){ guardSoak._fs(); } },
            { name: "live-fs-exit2",      dwell: 22000,  fn: function(){ guardSoak._fsExit(); } },
            { name: "live-replace",       dwell: 14000,  fn: function(){ guardSoak._replaceN(4); } },
            { name: "live-layout-4",      dwell: 22000,  fn: function(){ win.setLayout("4"); } },
            { name: "live-layout-9",      dwell: 22000,  fn: function(){ win.setLayout("9"); } },
            { name: "live-fullscreen3",   dwell: 6000,   fn: function(){ guardSoak._fs(); } },
            { name: "live-fs-exit3",      dwell: 22000,  fn: function(){ guardSoak._fsExit(); win.setLayout("16"); } },
            { name: "live-replace2",      dwell: 14000,  fn: function(){ guardSoak._replaceN(4); } },
            // ---- EVENTS: all four tabs + play random event videos ----
            { name: "events-triage",      dwell: 22000,  fn: function(){ win.goToSection("events"); eventsArea.mode = "triage"; } },
            { name: "events-triage-play", dwell: 20000,  fn: function(){ eventsArea.selectRandomEvent(); } },
            { name: "events-triage-play2",dwell: 20000,  fn: function(){ eventsArea.selectRandomEvent(); } },
            { name: "events-review",      dwell: 20000,  fn: function(){ eventsArea.mode = "review"; } },
            { name: "events-review-play", dwell: 20000,  fn: function(){ eventsArea.selectRandomEvent(); } },
            { name: "events-timeline",    dwell: 20000,  fn: function(){ eventsArea.mode = "timeline"; } },
            { name: "events-timeline-play",dwell: 18000, fn: function(){ eventsArea.selectRandomEvent(); } },
            { name: "events-map",         dwell: 20000,  fn: function(){ eventsArea.mode = "map"; } },
            // ---- other sections ----
            { name: "groups",             dwell: 20000,  fn: function(){ win.goToSection("groups"); } },
            { name: "views",              dwell: 18000,  fn: function(){ win.goToSection("views"); } },
            { name: "health",             dwell: 18000,  fn: function(){ win.goToSection("health"); } },
            // ---- PLAYBACK (single camera): open a day + historic scrub + rapid calendar sweep (teardown churn) ----
            { name: "playback-open",      dwell: 12000,  fn: function(){ guardSoak._pbOpen(); } },
            { name: "playback-scrub",     dwell: 10000,  fn: function(){ guardSoak._pbScrub(); } },
            { name: "playback-cal-sweep", dwell: 16000,  fn: function(){ guardSoak._pbSweep(4); } },
            { name: "playback-open2",     dwell: 12000,  fn: function(){ guardSoak._pbOpen(); } },
            { name: "playback-scrub2",    dwell: 10000,  fn: function(){ guardSoak._pbScrub(); } },
            { name: "playback-cal-sweep2",dwell: 16000,  fn: function(){ guardSoak._pbSweep(4); } },
            // ---- PLAYBACK WALL: enter + re-arrange (swap) repeatedly ----
            { name: "playback-wall",      dwell: 45000,  fn: function(){ win.goToSection("live"); win.enterWallPlayback(); } },
            { name: "playback-wall-swap", dwell: 30000,  fn: function(){ guardSoak._wallSwapN(5); } },
            { name: "playback-wall-swap2",dwell: 30000,  fn: function(){ guardSoak._wallSwapN(5); } }
        ]
        running: (typeof wtGuardSoak !== "undefined" && wtGuardSoak === true)
        repeat: true
        triggeredOnStart: true
        interval: 2000
        onTriggered: {
            var s = seq[step % seq.length];
            try { s.fn(); } catch (e) { console.log("[GUARD] ERR " + s.name + " " + e); }
            console.log("[GUARD] t=" + Date.now() + " step=" + s.name + " section=" + win.section + " wall=" + win.wallMode);
            guardSoak.interval = s.dwell;
            step = step + 1;
        }
    }

    function setLayout(n) {
        gridLayout = n; gridPage = 1;
        // A layout preset means "show me a normal grid", so exit a transient map-selection
        // scope ("Selected (N)") instead of staying stuck re-tiling just those few cameras.
        if (groupFilter === "__selected__") { groupFilter = ""; groupLabel = "All cameras"; }
    }
    function setStatusFilter(f) { statusFilter = f; gridPage = 1 }
    function toggleStatusChip(which) { setStatusFilter(statusFilter === which ? "" : which) }
    // Open the Save-current-view modal, capturing the current Live Monitor state.
    function openSaveView() {
        saveViewModal.layout = win.gridLayout;
        saveViewModal.statusFilter = win.statusFilter;
        saveViewModal.groupLabel = win.groupLabel;
        saveViewModal.open();
    }
    // A saved view's group may be stale (a pre-backend local id, or a since-
    // deleted group). Resolve it against the current backend group list; if it's
    // gone, fall back to "all cameras". Kept as-is while groups are still loading.
    function resolveGroup(gid, label) {
        if (!gid) return { id: "", label: "All cameras" };
        var gs = cameraModel.groupList();
        if (gs.length === 0) return { id: gid, label: label };
        for (var i = 0; i < gs.length; i++)
            if (gs[i].id === gid) return { id: gid, label: gs[i].name };
        return { id: "", label: "All cameras" };
    }

    // Apply the user's default landing screen on launch (Live / a saved view / a
    // group). A dev WT_SECTION override wins. Models are ready by onCompleted.
    function applyDefaultLanding() {
        var dl = Settings.defaultLanding;
        if (!dl || dl === "live") return;
        if (dl.indexOf("group:") === 0) {
            var gid = dl.substring(6);
            var groups = cameraModel.groupList();
            for (var i = 0; i < groups.length; i++)
                if (groups[i].id === gid) { win.groupFilter = gid; win.groupLabel = groups[i].name; break; }
            win.gridPage = 1; win.section = "live";
        } else if (dl.indexOf("view:") === 0) {
            var vid = dl.substring(5);
            var views = savedViewModel.list();
            for (var j = 0; j < views.length; j++)
                if (views[j].viewId === vid) {
                    var v = views[j];
                    var dg = win.resolveGroup(v.groupId, v.groupLabel);
                    win.gridLayout = v.layout; win.statusFilter = v.statusFilter; win.sortMode = v.sortMode;
                    win.groupFilter = dg.id; win.groupLabel = dg.label; win.gridPage = 1; win.section = "live";
                    break;
                }
        }
    }
    // Leaving the Live section drops wall-playback back to live (and stops its player via visibility).
    onSectionChanged: if (section !== "live") wallMode = "live"

    Component.onCompleted: {
        cameraModel.setCameraScope(AuthController.cameraScope);
        if (typeof wtSection === "undefined" || wtSection === "") applyDefaultLanding();
    }

    CameraModel { id: cameraModel }
    EventModel { id: eventModel }
    SavedViewModel { id: savedViewModel }
    SnapshotModel { id: snapshotModel; dir: Artifacts.snapshotDir }
    StorageHealth { id: storageHealth }
    PlaybackClient { id: playbackClient }

    // Admin switched the live-video transport (go2rtc ↔ direct RTSP): re-fetch
    // /streams so the new stream URLs take effect on the wall.
    Connections {
        target: Settings
        function onLiveTransportChanged() { cameraModel.refresh() }
    }

    // Apply the signed-in operator's camera scope (empty = all cameras). Fires on
    // login, token restore, and sign-out as the JWT claims change.
    Connections {
        target: AuthController
        function onIdentityChanged() { cameraModel.setCameraScope(AuthController.cameraScope) }
    }

    // Dev hook: WT_FOCUS_IP boots straight into Single Camera Detail for that
    // camera. Repeats until the camera roster has loaded (the first /streams
    // response lands a few seconds after login), then stops once focused.
    Timer {
        interval: 500; repeat: true
        running: typeof wtFocusIp !== "undefined" && wtFocusIp !== "" && win.focusedCamera === null
        onTriggered: {
            var all = cameraModel.page("", "", "default", 1, 50);
            for (var i = 0; i < all.length; i++)
                if (all[i].ip === wtFocusIp) { win.focusedCamera = all[i]; break; }
        }
    }
    // Dev hook: WT_GROUP boots the Live grid filtered to that group (by name);
    // repeats until the group roster has loaded.
    Timer {
        interval: 500; repeat: true
        running: typeof wtGroup !== "undefined" && wtGroup !== "" && win.groupFilter === ""
        onTriggered: {
            var gs = cameraModel.groupList();
            for (var i = 0; i < gs.length; i++)
                if (("" + gs[i].name).toLowerCase() === ("" + wtGroup).toLowerCase()) {
                    win.groupFilter = gs[i].id; win.groupLabel = gs[i].name; win.gridPage = 1; break;
                }
        }
    }
    // Dev hook: WT_PLAYBACK_IP boots straight into Playback (S06) for that camera.
    // Repeats until the camera roster has loaded (one-shot raced the /streams fetch).
    Timer {
        id: playbackBootHook
        interval: 500; repeat: true
        running: typeof wtPlaybackIp !== "undefined" && wtPlaybackIp !== ""
        onTriggered: {
            var all = cameraModel.page("", "", "default", 1, 50);
            for (var i = 0; i < all.length; i++)
                if (all[i].ip === wtPlaybackIp) {
                    playbackBootHook.running = false;
                    win.focusedCamera = all[i];
                    win.playbackCamera = all[i];
                    if (typeof wtPlaybackDay !== "undefined" && wtPlaybackDay !== "") {
                        playbackScreen.camera = all[i];                 // set camera, then open just the day
                        if (wtPlaybackDay.indexOf("T") > 0)             // dev: a full local instant — open the
                            playbackScreen.openAt(all[i], new Date(wtPlaybackDay).getTime());  // day + seek there (−15s)
                        else
                            playbackScreen.openForDay(wtPlaybackDay);   // dev: a specific day (warm/hot/mixed footage)
                    } else {
                        // Seek-latency test (WT_SEEK_TEST) needs the widest session the backend serves
                        // (24h = 1440min) so the larger jump steps have footage to land on.
                        playbackScreen.openFor(all[i], (typeof wtSeekTest !== "undefined" && wtSeekTest)
                            ? ((typeof wtSeekSpan !== "undefined" && wtSeekSpan > 0) ? wtSeekSpan : 1440) : 60);
                    }
                    break;
                }
        }
    }
    // Dev/soak hook: WT_CAL_STRESS drives the playback CALENDAR + historic playback
    // the way an operator does — pick a camera, open a day (it plays if there's
    // footage), scrub it, then click another day, sweeping the whole retention window;
    // every few days move to the next camera. Clicking a day tears down the playing
    // session — the GUI-thread teardown that "stops responding" under a degraded
    // backend (the reported .201 bug), and the load/seek path that's "awfully slow".
    // Rotates over the FULL roster (every camera's past footage is still in storage,
    // even unplugged). [CAL] + [PBSTOP] + WTSMOOTH lines are timestamped so the
    // analyzer derives calendar-click hitch, time-to-first-frame, and any freeze.
    Timer {
        id: calStress
        property var _cams: []           // full roster (resolved once)
        property int _camIdx: 0
        property int _tick: 0            // fixed 1s ticks (interval-change-while-running is unreliable)
        property int _nextAt: 2          // act on this tick; +dwell after each action
        property int _step: 0            // 0=open a day, 1=seek/scrub, 2=next day (calendar click)
        property int _dayOff: 0          // day offset back from today
        property int _dayCount: 0
        readonly property int _daySpan: 14     // sweep the last 14 days (mix of footage + empty)
        readonly property int _daysPerCam: 4   // day-clicks before advancing to the next camera
        interval: 1000; repeat: true
        running: (typeof wtCalStress !== "undefined" && wtCalStress === true)
        function _dayStr(off) { var d = new Date(); d.setDate(d.getDate() - off); return Qt.formatDate(d, "yyyy-MM-dd"); }
        function _cam() { return calStress._cams[calStress._camIdx % calStress._cams.length]; }
        function _select(c) { win.focusedCamera = c; win.playbackCamera = c; playbackScreen.camera = c; }
        onTriggered: {
            calStress._tick++;
            if (!calStress._cams.length) {                          // resolve the roster once
                calStress._cams = cameraModel.page("", "", "default", 1, 50);
                if (!calStress._cams.length) return;                // roster not ready — retry next tick
                if (typeof wtPlaybackIp !== "undefined" && wtPlaybackIp !== "")   // start on WT_PLAYBACK_IP if given
                    for (var i = 0; i < calStress._cams.length; i++)
                        if (calStress._cams[i].ip === wtPlaybackIp) { calStress._camIdx = i; break; }
                calStress._nextAt = calStress._tick + 1; return;
            }
            if (calStress._tick < calStress._nextAt) return;
            var cam = calStress._cam();
            if (calStress._step === 0) {                            // OPEN a day (session open + prior teardown)
                calStress._select(cam);
                var day = calStress._dayStr(calStress._dayOff);
                console.log("[CAL] t=" + Date.now() + " action=open cam=" + (cam ? cam.ip : "?")
                            + " day=" + day + " off=" + calStress._dayOff + " playing=" + playbackScreen.advancing);
                playbackScreen.openForDay(day);
                calStress._step = 1; calStress._nextAt = calStress._tick + 8;   // let it load + play
            } else if (calStress._step === 1) {                     // SEEK/scrub within the loaded day
                var played = playbackScreen.advancing;
                if (played && playbackScreen.tlEndMs > playbackScreen.tlStartMs) {
                    var frac = ((calStress._dayCount % 5) + 1) / 6.0;
                    var tgt = playbackScreen.tlStartMs + frac * (playbackScreen.tlEndMs - playbackScreen.tlStartMs);
                    console.log("[CAL] t=" + Date.now() + " action=seek cam=" + (cam ? cam.ip : "?") + " frac=" + frac.toFixed(2));
                    playbackScreen.seekToWall(tgt);
                } else {
                    console.log("[CAL] t=" + Date.now() + " action=seek-skip cam=" + (cam ? cam.ip : "?") + " (no footage)");
                }
                calStress._step = 2; calStress._nextAt = calStress._tick + 6;
            } else {                                                // NEXT day (calendar navigation → teardown)
                calStress._dayOff = (calStress._dayOff + 1) % calStress._daySpan;
                calStress._dayCount++;
                if (calStress._dayCount % calStress._daysPerCam === 0) calStress._camIdx++;   // rotate camera
                console.log("[CAL] t=" + Date.now() + " action=next dayCount=" + calStress._dayCount
                            + " nextCamIdx=" + calStress._camIdx);
                calStress._step = 0; calStress._nextAt = calStress._tick + 2;
            }
        }
    }
    // ========================================================================
    // WT_NIGHT_SOAK — comprehensive overnight endurance/stress harness (2026-07-02).
    // Drives the operator's real historic-playback flow — pick a RANDOM camera →
    // Open playback → RANDOM calendar day → seek to a RANDOM instant — with rigorous
    // per-action timing, PLUS a full export matrix (every camera; every quality on a
    // known-footage camera/day; HD-older-than-5-days policy; select+cancel; drawer
    // focus for Esc), and seek-LAND verification (did the video move to the target?).
    //
    // Log grammar (parsed by the analyzer → docs/perf report):
    //   [NTIME] action=<a> ms=<t>            every timed action; ms>1000 also emits
    //   [NSLOW] action=<a> ms=<t> (>1s)      the >1s violations the operator flagged
    //   [NSEEK] land err_s=… | TIMEOUT       seek landed near target, or froze/dead-air
    //   [XSOAK] action=export … dest=…       export requested (cam/quality/range/day)
    //   [XRESULT] job=… OK file=… total_ms=  export finished (supervisor stats the file)
    //   [ESCTEST] drawer focus=OK|LOST       drawer holds active focus ⇒ Esc will close it
    //   [SEEKBAR] hidden-while-day-loaded     the playhead vanished with footage loaded (bug)
    // Freezes: WTSMOOTH STALL (WT_SMOOTHTEST). Crashes: [WT-FATAL]. RSS: [WT-MEM]/sampler.
    Timer {
        id: nightSoak
        interval: 1000; repeat: true
        running: (typeof wtNightSoak !== "undefined" && wtNightSoak === true)

        property var cams: []
        property int camIdx: 0
        property int tick: 0
        property int nextAt: 4
        property int step: 0            // 0 open · 1 await-load · 2 seek · 3 await-land · 4 export · 5 drawer · 6 next
        property int cycle: 0
        property double t0: 0
        property int frameSeqAtSeek: -1
        property double seekTgt: 0
        property int dayOff: 0
        readonly property int daySpan: 14
        property string curDay: ""
        property int expTurn: 0
        property double expT0: 0
        property string expTag: ""
        property bool sawDay: false     // a day session loaded this cycle (for seek-bar / seek gating)

        function _log(a, ms) {
            console.log("[NTIME] t=" + Date.now() + " action=" + a + " ms=" + Math.round(ms));
            if (ms > 1000) console.log("[NSLOW] action=" + a + " ms=" + Math.round(ms) + " (>1s)");
        }
        function _cam() { return nightSoak.cams.length ? nightSoak.cams[nightSoak.camIdx % nightSoak.cams.length] : null; }
        function _dayStr(off) { var d = new Date(); d.setDate(d.getDate() - off); return Qt.formatDate(d, "yyyy-MM-dd"); }
        function _select(c) { win.focusedCamera = c; win.playbackCamera = c; playbackScreen.camera = c; }
        function _camId(c) { return c ? (playbackClient.cameraIdForIp(c.ip) || playbackClient.cameraIdForMac(c.mac || "")) : ""; }
        // a random [start,end] of ~durMin inside the loaded day's footage (tlFrags), or null
        function _pickRange(durMin) {
            var f = playbackScreen.tlFrags;
            if (!f || !f.length) return null;
            var i = (nightSoak.cycle * 7 + nightSoak.expTurn) % f.length;   // deterministic-but-varied pick
            var span = f[i].we - f[i].ws;
            var want = durMin * 60000;
            var s = f[i].ws + Math.min(span * 0.1, Math.max(0, span - want));
            var e = Math.min(f[i].we + want, s + want);                     // may extend across neighbouring footage
            if (e - s < 2000) e = s + Math.min(want, 2000);
            return { s: s, e: e };
        }
        function _doExport(hi, durMin, tag) {
            var c = nightSoak._cam(), id = nightSoak._camId(c), r = nightSoak._pickRange(durMin);
            if (!c || !id || !r) { console.log("[XSOAK] skip reason=" + (!c ? "nocam" : !id ? "nocamid" : "nofootage")
                                               + " cam=" + (c ? c.ip : "?") + " day=" + nightSoak.curDay); return false; }
            var dest = Artifacts.newExportPath((c.name || id), "mp4");
            nightSoak.expT0 = Date.now();
            nightSoak.expTag = "cam=" + c.ip + " q=" + (hi ? "HIGH" : "STD") + " durMin=" + durMin + " day=" + nightSoak.curDay + " tag=" + (tag || "rand");
            console.log("[XSOAK] t=" + Date.now() + " action=export " + nightSoak.expTag
                        + " range=" + Qt.formatDateTime(new Date(r.s), "HH:mm:ss") + "-" + Qt.formatDateTime(new Date(r.e), "HH:mm:ss")
                        + " dest=" + dest);
            playbackClient.createExport(id, new Date(r.s).toISOString(), new Date(r.e).toISOString(),
                                        "wallclock", dest, "", "soak", hi, ({}));
            return true;
        }

        onTriggered: {
            nightSoak.tick++;
            if (!nightSoak.cams.length) {                       // resolve roster once
                nightSoak.cams = cameraModel.page("", "", "default", 1, 64);
                if (!nightSoak.cams.length) return;
                nightSoak.nextAt = nightSoak.tick + 1; return;
            }
            // seek-bar invariant: the playhead is bound to frags.length>0; if a day is
            // loaded (tlFrags present, playing) but frags emptied, the bar vanished.
            if (nightSoak.sawDay && playbackScreen.tlFrags.length > 0 && playbackScreen.frags.length === 0
                    && !playbackScreen.loading && playbackScreen.errorText === "")
                console.log("[SEEKBAR] hidden-while-day-loaded cam=" + (nightSoak._cam() ? nightSoak._cam().ip : "?") + " day=" + nightSoak.curDay);

            if (nightSoak.step === 3) return;   // seek-land measured by nsSeekWatch (40ms, sub-second precision)
            if (nightSoak.tick < nightSoak.nextAt) return;
            var cam = nightSoak._cam();

            if (nightSoak.step === 0) {                         // OPEN a random day (calendar click)
                nightSoak._select(cam);
                nightSoak.dayOff = (nightSoak.cycle * 5 + 3) % nightSoak.daySpan;   // varied day, incl. >5d old
                nightSoak.curDay = nightSoak._dayStr(nightSoak.dayOff);
                nightSoak.sawDay = false;
                if (typeof win.goToSection === "function") win.goToSection("live");   // fresh nav
                win.focusedCamera = cam; win.playbackCamera = cam; playbackScreen.camera = cam;
                console.log("[NTIME] t=" + Date.now() + " action=open-begin cam=" + (cam ? cam.ip : "?") + " day=" + nightSoak.curDay + " off=" + nightSoak.dayOff);
                playbackScreen.openForDay(nightSoak.curDay);     // [PBTIME] times open→first_frame
                nightSoak.step = 1; nightSoak.nextAt = nightSoak.tick + 10;
            } else if (nightSoak.step === 1) {                  // AWAIT load, then decide seek/empty
                if (playbackScreen.advancing && playbackScreen.tlEndMs > playbackScreen.tlStartMs) {
                    nightSoak.sawDay = true; nightSoak.step = 2; nightSoak.nextAt = nightSoak.tick + 1;
                } else {                                         // empty/honest-no-footage day → skip to export/next
                    console.log("[NTIME] t=" + Date.now() + " action=day-empty cam=" + (cam ? cam.ip : "?") + " day=" + nightSoak.curDay + " err=" + (playbackScreen.errorText || "-"));
                    nightSoak.step = 4; nightSoak.nextAt = nightSoak.tick + 1;
                }
            } else if (nightSoak.step === 2) {                  // SEEK to a random instant (scrubber click)
                var lo = playbackScreen.tlStartMs, hi = playbackScreen.tlEndMs;
                var frac = ((nightSoak.cycle * 13) % 90 + 5) / 100.0;        // 5%..95%
                var ff = playbackScreen.tlFrags;
                if (nightSoak.cycle % 4 === 0 || !ff.length) {                // 1-in-4 clicks land in DEAD AIR (tests snap)
                    nightSoak.seekTgt = lo + frac * (hi - lo);
                } else {                                                     // else land INSIDE footage (tests exact seek)
                    var fr = ff[(nightSoak.cycle * 3) % ff.length];
                    nightSoak.seekTgt = fr.ws + frac * (fr.we - fr.ws);
                }
                nightSoak.t0 = Date.now(); nightSoak.frameSeqAtSeek = playbackScreen._frameSeq;
                console.log("[NTIME] t=" + Date.now() + " action=seek-begin cam=" + (cam ? cam.ip : "?") + " frac=" + frac.toFixed(2)
                            + " tgt=" + Qt.formatDateTime(new Date(nightSoak.seekTgt), "HH:mm:ss"));
                playbackScreen.seekToWall(nightSoak.seekTgt);
                nightSoak.step = 3; nightSoak.nextAt = nightSoak.tick + 8;    // 8s land timeout
            } else if (nightSoak.step === 4) {                  // EXPORT matrix (rotates)
                if (typeof wtSoakNoExport !== "undefined" && wtSoakNoExport === true) {   // bisect: skip export+drawer
                    nightSoak.step = 6; nightSoak.nextAt = nightSoak.tick + 1; return;
                }
                var t = nightSoak.expTurn % 6;
                var durMin = [1, 2, 5, 12, 25, 40][nightSoak.cycle % 6];      // 1..40 min sizes
                if (t === 0) nightSoak._doExport(true, durMin, "rand-high");
                else if (t === 1) nightSoak._doExport(false, durMin, "rand-std");
                else if (t === 2) { nightSoak._doExport(true, 2, "samecam-high"); }   // pair for size compare
                else if (t === 3) { nightSoak._doExport(false, 2, "samecam-std"); }
                else if (t === 4) {                                            // HD-older-than-5d policy
                    if (nightSoak.dayOff > 5) nightSoak._doExport(true, 1, "old5d-high");
                    else nightSoak._doExport(true, 1, "recent-high");
                } else { nightSoak._log("export-turn-skip", 0); }
                nightSoak.expTurn++;
                nightSoak.step = 5; nightSoak.nextAt = nightSoak.tick + 4;
            } else if (nightSoak.step === 5) {                  // DRAWER: open → focus/Esc check → cancel
                var r = nightSoak._pickRange(1);
                if (r && playbackScreen.advancing) {
                    playbackScreen.selStartMs = r.s; playbackScreen.selEndMs = r.e;
                    playbackScreen.openExportDrawer();
                    var ok = playbackScreen.exportDrawerVisible && playbackScreen.exportDrawerFocus;
                    console.log("[ESCTEST] drawer focus=" + (ok ? "OK" : "LOST") + " visible=" + playbackScreen.exportDrawerVisible
                                + " activeFocus=" + playbackScreen.exportDrawerFocus);
                    playbackScreen.closeExportDrawer();          // cancel-before-launch path
                    console.log("[XSOAK] drawer-cancel closed visible=" + playbackScreen.exportDrawerVisible);
                }
                nightSoak.step = 6; nightSoak.nextAt = nightSoak.tick + 2;
            } else {                                             // NEXT: advance camera, loop
                nightSoak.cycle++;
                if (nightSoak.cycle % 2 === 0) nightSoak.camIdx++;            // rotate camera every 2 cycles
                nightSoak.step = 0; nightSoak.nextAt = nightSoak.tick + 2;
            }
        }
    }
    // Precise seek-land timer: polls the rendered-frame counter every 40ms so the
    // scrubber-click → first-changed-frame latency is measured to ~40ms (the 1s cycle
    // timer would quantize it to whole seconds → false >1s violations).
    Timer {
        id: nsSeekWatch
        interval: 40; repeat: true
        running: (typeof wtNightSoak !== "undefined" && wtNightSoak === true) && nightSoak.step === 3
        onTriggered: {
            var dt = Date.now() - nightSoak.t0;
            if (playbackScreen._frameSeq > nightSoak.frameSeqAtSeek) {
                nightSoak._log("seek-land", dt);
                var ph = playbackScreen.playheadMs, err = Math.abs(ph - nightSoak.seekTgt);
                var inFoot = playbackScreen.msInFootage(nightSoak.seekTgt);
                var phFoot = playbackScreen.msInFootage(ph);
                var ok = inFoot ? (err < 5000) : phFoot;   // in-footage → land near; dead-air → snapped to footage
                console.log("[NSEEK] " + (ok ? "OK" : "BAD") + " land_ms=" + Math.round(dt) + " inFootage=" + inFoot
                            + " landedOnFootage=" + phFoot + " err_s=" + Math.round(err / 1000)
                            + " tgt=" + Qt.formatDateTime(new Date(nightSoak.seekTgt), "HH:mm:ss")
                            + " ph=" + Qt.formatDateTime(new Date(ph), "HH:mm:ss"));
                nightSoak.step = 4; nightSoak.nextAt = nightSoak.tick + 2;
            } else if (dt > 8000) {
                console.log("[NSEEK] TIMEOUT no-frame-after=" + Math.round(dt) + "ms (froze or dead-air) cam="
                            + (nightSoak._cam() ? nightSoak._cam().ip : "?"));
                nightSoak.step = 4; nightSoak.nextAt = nightSoak.tick + 2;
            }
        }
    }
    // Export result capture for the night soak (file size stat'd by the supervisor).
    Connections {
        target: playbackClient
        enabled: (typeof wtNightSoak !== "undefined" && wtNightSoak === true)
        function onExportStarted(jobId) {
            console.log("[XSOAK] started job=" + jobId + " dispatch_ms=" + (Date.now() - nightSoak.expT0) + " " + nightSoak.expTag);
        }
        function onExportSaved(jobId, path) {
            // Export is a backend job (create→remux/transcode→download) with a progress
            // toast — its total_ms is recorded for the export report but is NOT a <1s UI
            // violation (only interactive actions are held to the 1s bar).
            console.log("[XRESULT] job=" + jobId + " OK file=" + path + " total_ms=" + (Date.now() - nightSoak.expT0) + " " + nightSoak.expTag);
        }
        function onExportFailed(jobId, err) {
            console.log("[XRESULT] job=" + jobId + " FAIL err=\"" + err + "\" total_ms=" + (Date.now() - nightSoak.expT0) + " " + nightSoak.expTag);
        }
    }

    // Dev hook: WT_WALL_DAY boots into synchronized wall playback over the current
    // live page's cameras — a given day (YYYY-MM-DD) or "live" for the last hour.
    Timer {
        interval: 3000; running: typeof wtWallDay !== "undefined" && wtWallDay !== ""
        onTriggered: {
            wallMode = "playback";
            // The WT_WALLPERF harness seeds + opens the session itself; if we also
            // opened here it would create a second composite ~3 s later (churn).
            if (typeof wtWallPerf !== "undefined" && wtWallPerf !== "") return;
            var per = ({ "1": 1, "4": 4, "9": 9, "16": 16 })[gridLayout] || 16;
            wallPlayback.seedCameras(cameraModel.page(groupFilter, statusFilter, sortMode, gridPage, per));
            if (wtWallDay === "live") wallPlayback.openFor();
            else wallPlayback.openForDay(wtWallDay);
        }
    }

    // keyboard shortcuts (design §30)
    Shortcut { sequence: "F"; onActivated: win.fullscreen = !win.fullscreen }
    Shortcut { sequence: "Escape"; onActivated: { if (commandPalette.visible) commandPalette.close(); else if (liveMonitor.visible && (liveMonitor.arrangeMode || liveMonitor.pickerCell >= 0)) liveMonitor.escapeArrange(); else if (win.fullscreen) win.fullscreen = false } }
    Shortcut { sequence: "1"; onActivated: win.setLayout("1") }
    Shortcut { sequence: "2"; onActivated: win.setLayout("4") }
    Shortcut { sequence: "3"; onActivated: win.setLayout("9") }
    Shortcut { sequence: "4"; onActivated: win.setLayout("16") }
    Shortcut { sequence: "Ctrl+K"; onActivated: commandPalette.open() }

    RowLayout {
        anchors.fill: parent
        spacing: 0
        visible: AuthController.authenticated   // shell hidden until signed in

        NavRail {
            Layout.fillHeight: true
            visible: !win.fullscreen
            section: win.section
            unackCount: eventModel.unacknowledgedCount
            onSectionSelected: (sid) => win.goToSection(sid)
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            TopBar {
                Layout.fillWidth: true
                visible: !win.fullscreen
                cameraModel: cameraModel
                eventModel: eventModel
                statusFilter: win.statusFilter
                initials: AuthController.initials
                operatorName: AuthController.username
                hasAlerts: eventModel.unacknowledgedCount > 0
                onStatusChipClicked: (which) => win.toggleStatusChip(which)
                onPreferencesRequested: win.goToSection("preferences")
                onAlertsViewAllRequested: win.goToSection("events")
                onSearchActivated: commandPalette.open()
                // Live right-hand panel toggle — only meaningful on the live wall.
                showSidePanelToggle: win.section === "live" && win.wallMode === "live" && win.focusedCamera === null
                sidePanelOpen: win.opsSidebarOpen
                onToggleSidePanelRequested: win.opsSidebarOpen = !win.opsSidebarOpen
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                LiveMonitor {
                    id: liveMonitor
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: win.section === "live" && win.focusedCamera === null && win.wallMode === "live"
                    cameraModel: cameraModel
                    eventModel: eventModel
                    layout: win.gridLayout
                    page: win.gridPage
                    statusFilter: win.statusFilter
                    sortMode: win.sortMode
                    groupId: win.groupFilter
                    groupLabel: win.groupLabel
                    fullscreen: win.fullscreen
                    onLayoutRequested: (id) => win.setLayout(id)
                    onPageRequested: (p) => win.gridPage = Math.max(1, Math.min(p, liveMonitor.pageCount))
                    onStatusFilterRequested: (f) => win.setStatusFilter(f)
                    onSortRequested: (s) => win.sortMode = s
                    onGroupRequested: (gid, label) => { win.groupFilter = gid; win.groupLabel = label; win.gridPage = 1 }
                    onFullscreenToggled: win.fullscreen = !win.fullscreen
                    onSaveViewRequested: win.openSaveView()
                    onSnapshotSaved: (path, camName) => toastHost.show(
                        "Snapshot captured", camName + " · saved to Pictures/Watchtower",
                        "accent", "Open", "file://" + path)
                    onCameraOpened: (cam) => win.focusedCamera = cam
                    onCameraPlaybackRequested: (cam) => {
                        win.focusedCamera = cam;
                        win.playbackCamera = cam;
                        playbackScreen.openFor(cam, 60);
                    }
                    onWallPlaybackRequested: win.enterWallPlayback()
                    onHdLimitReached: toastHost.show(
                        "HD limit reached",
                        "Up to " + liveMonitor.hdCap + " tiles can stream in HD at once — switch one back to SD first.",
                        "accent", "", "")
                }

                WallPlayback {
                    id: wallPlayback
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: win.section === "live" && win.focusedCamera === null && win.wallMode === "playback"
                    client: playbackClient
                    cameraModel: cameraModel
                    onReturnToLive: win.wallMode = "live"
                    // Picker "Use live wall": saved layout cleared — reseed from the
                    // live page and re-composite the same window.
                    onResetToLiveRequested: {
                        var per = ({ "1": 1, "4": 4, "9": 9, "16": 16 })[win.gridLayout] || 16;
                        wallPlayback.seedCameras(cameraModel.page(win.groupFilter, win.statusFilter, win.sortMode, win.gridPage, per));
                        wallPlayback.reopenSameWindow();
                    }
                }

                CameraGroups {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: win.section === "groups" && win.focusedCamera === null
                    cameraModel: cameraModel
                    onOpenInLive: (gid, label) => {
                        win.groupFilter = gid;
                        win.groupLabel = label;
                        win.gridPage = 1;
                        win.section = "live";
                    }
                    onOpenCamera: (cam) => win.focusedCamera = cam
                }

                SingleCameraDetail {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: win.focusedCamera !== null && win.playbackCamera === null
                    cameraModel: cameraModel
                    camera: win.focusedCamera
                    onClosed: win.focusedCamera = null
                    onSwitchCamera: (cam) => win.focusedCamera = cam
                    onOpenPlayback: (mac) => {
                        win.playbackCamera = win.focusedCamera;
                        playbackScreen.openFor(win.focusedCamera, 60);
                    }
                    onSnapshotSaved: (path, camName) => toastHost.show(
                        "Snapshot captured", camName + " · saved to Pictures/Watchtower",
                        "accent", "Open", "file://" + path)
                }

                PlaybackScreen {
                    id: playbackScreen
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: win.playbackCamera !== null
                    client: playbackClient
                    cameraModel: cameraModel
                    onClosed: win.playbackCamera = null
                    onReturnToLive: { win.playbackCamera = null; win.focusedCamera = null }
                    onFullscreenRequested: win.fullscreen = true
                    onSnapshotSaved: (path, camName) => toastHost.show(
                        "Snapshot captured", camName + " · saved to Pictures/Watchtower",
                        "accent", "Open", "file://" + path)
                }

                PreferencesScreen {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: win.section === "preferences"
                    savedViewModel: savedViewModel
                    cameraModel: cameraModel
                    onClosed: win.section = "live"
                }

                HealthScreen {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: win.section === "health" && win.focusedCamera === null && win.playbackCamera === null
                    cameraModel: cameraModel
                    storageHealth: storageHealth
                    onOpenLive: (cam) => { win.section = "live"; win.focusedCamera = cam }
                    onOpenPlayback: (cam) => { win.focusedCamera = cam; win.playbackCamera = cam; playbackScreen.openFor(cam, 60) }
                    onOpenEvents: (cam) => win.section = "events"
                }

                // Events-screen redesign (events-v2 port) — now the DEFAULT Events
                // screen, on the live cilex-vision feed (EventsStore.ingestReal).
                // WT_DEMO → the mock showcase; WT_EVENTS_LEGACY → the old EventsScreen.
                EventsArea {
                    id: eventsArea
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: !wtEventsLegacy && win.section === "events" && win.focusedCamera === null && win.playbackCamera === null
                    demo: wtDemo
                    eventModel: eventModel
                    cameraModel: cameraModel
                    // Export the event's whole episode (footage span) to the Clips library. EvTriage already
                    // resolved the episode start/end via EventsStore.episodeWindow, so a motion_ended event
                    // exports its real footage instead of an empty forward window (global toasts fire below).
                    onExportClip: (camId, startMs, endMs, purpose) => {
                        var cam = cameraModel.cameraByBackendId(camId);
                        var id = (cam && cam.camId) ? cam.camId : camId;
                        var base = (cam && cam.name) ? cam.name : id;
                        var dest = Artifacts.newExportPath(base, "mp4");
                        playbackClient.createExport(id, new Date(startMs).toISOString(),
                                                    new Date(endMs).toISOString(),
                                                    "wallclock", dest, "", purpose);
                    }
                    // Situation-Map multi-select → jump to wall playback over only those cameras.
                    onOpenWall: (ids) => win.enterWallWithCameras(ids)
                    // Situation-Map multi-select → live grid scoped to only those cameras.
                    onOpenLive: (ids) => win.enterLiveWithCameras(ids)
                }

                // Legacy table-style Events screen — fallback behind WT_EVENTS_LEGACY.
                EventsScreen {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: wtEventsLegacy && win.section === "events" && win.focusedCamera === null && win.playbackCamera === null
                    eventModel: eventModel
                    cameraModel: cameraModel
                    onOpenPlayback: (camId, atMs) => {
                        var cam = cameraModel.cameraByBackendId(camId);
                        if (cam && cam.camId) { win.focusedCamera = cam; win.playbackCamera = cam; playbackScreen.openAt(cam, atMs) }
                    }
                    // Export a 1-minute clip around the event (15s lead-in → 45s after)
                    // straight to the Clips library. The shared auth cookie is already
                    // held (login gate), so createExport needs no session/priming; the
                    // global export Connections below surface start/saved/failed toasts.
                    onExportClip: (camId, atMs, purpose) => {
                        var cam = cameraModel.cameraByBackendId(camId);
                        var id = (cam && cam.camId) ? cam.camId : camId;
                        var base = (cam && cam.name) ? cam.name : id;
                        var dest = Artifacts.newExportPath(base, "mp4");
                        playbackClient.createExport(id, new Date(atMs - 15000).toISOString(),
                                                    new Date(atMs + 45000).toISOString(),
                                                    "wallclock", dest, "", purpose);
                    }
                }

                SavedViewsScreen {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: win.section === "views" && win.focusedCamera === null && win.playbackCamera === null
                    savedViewModel: savedViewModel
                    cameraModel: cameraModel
                    onSaveCurrentRequested: win.openSaveView()
                    onOpenView: (view) => {
                        var vg = win.resolveGroup(view.groupId, view.groupLabel);
                        win.gridLayout = view.layout;
                        win.statusFilter = view.statusFilter;
                        win.sortMode = view.sortMode;
                        win.groupFilter = vg.id;
                        win.groupLabel = vg.label;
                        win.gridPage = 1;
                        win.section = "live";
                        savedViewModel.touch(view.viewId);
                    }
                }

                ClipsScreen {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: win.section === "clips" && win.focusedCamera === null && win.playbackCamera === null
                    snapshotModel: snapshotModel
                    cameraModel: cameraModel
                    playbackClient: playbackClient
                }

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: ["live", "groups", "preferences", "health", "events", "views", "clips"].indexOf(win.section) < 0
                    EmptyState {
                        anchors.centerIn: parent
                        icon: "pulse"
                        title: "Coming soon"
                        subtitle: win.section + " is part of a later phase."
                    }
                }

                OpsSidebar {
                    Layout.fillHeight: true
                    visible: win.section === "live" && !win.fullscreen && win.focusedCamera === null && win.wallMode === "live" && win.opsSidebarOpen
                    cameraModel: cameraModel
                    eventModel: eventModel
                    // "View all →" on the LIVE EVENTS panel → open the full Events screen
                    // (same as the alerts dropdown's View-all, line ~473).
                    onViewAllEvents: win.goToSection("events")
                }
            }
        }
    }

    // Login gate — covers the shell until a valid session is held.
    LoginScreen {
        anchors.fill: parent
        visible: !AuthController.authenticated
        z: 1000
    }

    // Clip-export feedback from the playback backend.
    Connections {
        target: playbackClient
        function onExportStarted(jobId) {
            toastHost.show("Export started", "Preparing clip on cilex-vision…", "accent", "", "")
        }
        function onExportSaved(jobId, path) {
            toastHost.show("Clip saved", "Saved to " + Artifacts.exportDir, "good", "Open folder", "file://" + Artifacts.exportDir)
        }
        function onExportFailed(jobId, err) {
            // A Standard export over a window whose sub-stream wasn't recorded now fails honestly
            // (Cilex Vision reply9) and points at High — offer a one-click re-run from the main
            // stream (option 1). Match the backend's hint; a structured reason code is on our ask list.
            if (err.indexOf("High export") >= 0 || err.indexOf("sub-stream") >= 0)
                toastHost.show("Standard unavailable for this window", err, "bad",
                               "Export as High instead", "", "retryExportHigh")
            else
                toastHost.show("Export failed", err === "" ? "The clip could not be exported" : err, "bad", "", "")
        }
    }

    // Toast stack overlay (snapshot feedback now; alerts later).
    ToastHost {
        id: toastHost
        onActionInvoked: (actionId) => { if (actionId === "retryExportHigh") playbackClient.retryLastExportAsHigh() }
    }

    // Save-current-view modal (O03) — opened from Live Monitor or Saved Views.
    SaveViewModal {
        id: saveViewModal
        onSaved: (name, shared) => {
            savedViewModel.saveCurrent(name, shared, win.gridLayout, win.statusFilter,
                                       win.sortMode, win.groupFilter, win.groupLabel);
            toastHost.show("View saved", name + " · " + (shared ? "Shared" : "Mine"), "good", "", "");
        }
    }

    // Command palette (Ctrl+K) — global quick-jump across cameras/groups/views/events.
    CommandPalette {
        id: commandPalette
        cameraModel: cameraModel
        savedViewModel: savedViewModel
        eventModel: eventModel
        snapshotModel: snapshotModel
        onOpenCamera: (cam) => { win.section = "live"; win.focusedCamera = cam }
        onOpenClips: { win.focusedCamera = null; win.playbackCamera = null; win.section = "clips" }
        onOpenGroup: (gid, label) => { win.focusedCamera = null; win.groupFilter = gid; win.groupLabel = label; win.gridPage = 1; win.section = "live" }
        onOpenView: (view) => {
            win.focusedCamera = null;
            var cg = win.resolveGroup(view.groupId, view.groupLabel);
            win.gridLayout = view.layout; win.statusFilter = view.statusFilter; win.sortMode = view.sortMode;
            win.groupFilter = cg.id; win.groupLabel = cg.label; win.gridPage = 1; win.section = "live";
            savedViewModel.touch(view.viewId);
        }
        onOpenEvents: { win.focusedCamera = null; win.playbackCamera = null; win.section = "events" }
    }
}
