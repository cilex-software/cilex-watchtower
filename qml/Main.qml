import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import Watchtower
import "WatchNames.js" as WatchNames

// Application shell (design §10): nav rail · top bar · Live Monitor + ops
// sidebar. Owns the Live Monitor view state; child screens request changes.
Window {
    id: win
    width: 1440
    height: 900
    visible: true
    color: Theme.bg
    title: "Watchtower"
    // Frameless — Watchtower draws the designed 36px title bar itself (TitleBar.qml).
    // The host chrome we get under GNOME/Wayland is Qt's own client-side decoration,
    // which paints a title strip with NO usable minimize/maximize/close buttons
    // (operator report 2026-07-25). Move and resize are handed straight back to the
    // compositor via startSystemMove()/startSystemResize() — see TitleBar.qml and
    // `resizeFrame` at the bottom of this file.
    flags: Qt.Window | Qt.FramelessWindowHint
    // Explicit shutdown intent for Warden (heartbeat contract §4): every ORDERLY
    // shutdown — title-bar ×, Alt+F4, compositor close, and yes, Qt.quit() too
    // (app teardown closes the window, so onClosing fires; measured, not assumed)
    // — writes a marker. The guarantee that matters is the negative one: a crash,
    // kill, or hang can never write it, so a fresh marker is proof the exit was
    // chosen, not suffered.
    onClosing: Settings.markOperatorQuit()

    property string section: (typeof wtSection !== "undefined" && wtSection !== "") ? wtSection : "live"
    property string gridLayout: (typeof wtLayout !== "undefined" && wtLayout !== "")
                                ? wtLayout : "16"   // canonical layout id (see LayoutSpec)
    property int gridPage: 1
    property string statusFilter: (typeof wtStatusFilter !== "undefined" && wtStatusFilter !== "") ? wtStatusFilter : ""
    // Live wall leads with cameras that are actually live (offline tiles sink to the
    // last page). Overridable via the Sort menu, and a saved view / manual arrangement
    // still wins. See CameraModel "live" sort.
    property string sortMode: "live"
    property string groupFilter: ""
    property string groupLabel: qsTr("All cameras")
    property bool fullscreen: false
    property var focusedCamera: null    // shows Single Camera Detail when non-null
    property var playbackCamera: null   // shows Playback (S06) when non-null
    property string wallMode: "live"    // "live" | "playback" (synchronized wall review)
    property bool opsSidebarOpen: true  // Live page right-hand panel (OpsSidebar) — toggled from the Live toolbar

    // ------------------------------------------------------------- View tabs
    // tabs[0] is the MAIN tab: whatever the nav rail points at, which may itself
    // hold a camera opened IN PLACE (a tile's "Open"). tabs[1..] are cameras
    // opened with a tile's "Open in new tab" — they survive going back to the
    // wall or to another section, which is the only thing that ever made that
    // control different from "Open". Until 2026-07-25 it opened the identical
    // full-screen view and left nothing behind (operator report), so the strip
    // (TabStrip.qml) is what makes the action real; it appears only once a
    // camera tab exists.
    property var tabs: [ { "kind": "main" } ]
    property int activeTab: 0
    property var mainTabCamera: null    // camera opened in place inside tabs[0]
    // Preferences lives in its OWN closable tab (operator report 2026-08-06:
    // as a section it hijacked the home slot's label AND — ungated by
    // focusedCamera — co-rendered beside a camera tab, splitting the window).
    readonly property bool prefsTabActive: activeTab > 0 && activeTab < tabs.length
                                           && tabs[activeTab].kind === "prefs"

    function sectionLabel(sid) {
        // The live section is TWO screens: the live wall and synchronized wall
        // playback. Saying "Live wall" while the operator is scrubbing yesterday
        // is the title bar contradicting the picture (spec §0, problem 10).
        return sid === "live" ? (wallMode === "playback" ? qsTr("Wall playback") : qsTr("Live wall"))
             : sid === "groups" ? qsTr("Groups")
             : sid === "views" ? qsTr("Views")
             : sid === "events" ? qsTr("Events")
             : sid === "health" ? qsTr("Health")
             : sid === "clips" ? qsTr("Clips")
             : sid === "preferences" ? qsTr("Preferences") : sid;
    }
    function homeTabLabel() {
        return mainTabCamera ? mainTabCamera.name : sectionLabel(section);
    }
    function activeTabLabel() {
        if (playbackCamera) return qsTr("Playback") + " · " + playbackCamera.name;
        if (prefsTabActive) return qsTr("Preferences");
        if (activeTab > 0 && activeTab < tabs.length && tabs[activeTab].cam)
            return tabs[activeTab].cam.name;
        return homeTabLabel();
    }

    // Open a camera in the CURRENT tab — a tile's "Open", the command palette,
    // Health/Groups hand-offs, a sibling thumbnail. Navigates in place: the main
    // tab remembers it, a camera tab re-points at the new camera.
    // [LIVETIME] the user gesture: "open this camera". Stamped HERE, not on the detail
    // view's cameraChanged — the boot path sets that ~7 s before the roster exists and the
    // measured number then includes app start (measured 2026-09-08: decoder chosen at
    // "-7 s" relative to a stamp that fired first). A guard's click is this function.
    property double liveOpenT0: -1
    function openCameraHere(cam) {
        if (!cam) return;
        liveOpenT0 = Date.now();
        console.log("[LIVETIME] open t=" + liveOpenT0 + " cam=" + (cam.ip || "?"));
        // Tell the parking lot which camera this is BEFORE the wall is torn down, so its lit
        // pipeline survives the cap whatever the creation order (see RtspVideoSource.h).
        if (typeof LiveHints !== "undefined") LiveHints.wantCamera(cam.rtspSubUrl || "", cam.rtspUrl || "");
        if (activeTab > 0 && activeTab < tabs.length) {
            var t = tabs.slice();
            t[activeTab] = { "kind": "camera", "camId": cam.camId, "cam": cam };
            tabs = t;
        } else {
            mainTabCamera = cam;
        }
        focusedCamera = cam;
    }

    // Open a camera in a NEW tab (a tile's "Open in new tab"). A camera that
    // already has a tab is raised rather than duplicated — a second tab on the
    // same camera would be indistinguishable from the first.
    function openCameraTab(cam) {
        if (!cam) return;
        for (var i = 1; i < tabs.length; i++) {
            if (tabs[i].camId === cam.camId) { activateTab(i); return; }
        }
        tabs = tabs.concat([{ "kind": "camera", "camId": cam.camId, "cam": cam }]);
        activateTab(tabs.length - 1);
    }

    function openPreferences() {
        for (var i = 1; i < tabs.length; i++)
            if (tabs[i].kind === "prefs") { activateTab(i); return; }
        tabs = tabs.concat([{ "kind": "prefs" }]);
        activateTab(tabs.length - 1);
    }

    function activateTab(i) {
        if (i < 0 || i >= tabs.length) return;
        playbackCamera = null;      // playback is a focus mode inside a tab, not a tab
        activeTab = i;
        if (i === 0) { focusedCamera = mainTabCamera; return; }
        if (tabs[i].kind === "prefs") { focusedCamera = null; return; }
        // Re-resolve against the model so a tab opened minutes ago carries current
        // status/stream urls rather than the snapshot it was created from.
        var live = cameraModel ? cameraModel.cameraByBackendId(tabs[i].camId) : null;
        focusedCamera = (live && live.camId !== undefined && live.camId !== "") ? live : tabs[i].cam;
    }

    function closeTab(i) {
        if (i <= 0 || i >= tabs.length) return;     // the main tab never closes
        // Closing the active tab lands on the one to its RIGHT (the browser rule),
        // or on the left neighbour when it was the last tab.
        var next = (activeTab === i) ? Math.min(i, tabs.length - 2)
                 : (activeTab > i ? activeTab - 1 : activeTab);
        var t = tabs.slice();
        t.splice(i, 1);
        tabs = t;
        activateTab(Math.max(0, Math.min(next, tabs.length - 1)));
    }

    // Leave the camera view in the current tab (the detail view's back arrow):
    // in a camera tab that IS closing the tab; in the main tab it returns to the
    // section underneath.
    function closeCameraHere() {
        if (activeTab > 0) closeTab(activeTab);
        else { mainTabCamera = null; focusedCamera = null; }
    }

    // ---------------------------------------- View-state persistence (Warden CW-05)
    // A restart — Warden's crash-restart above all — must land the guard exactly
    // where they were: same section, layout, group, page, open tabs, focused
    // camera. The blob stores only IDs that re-resolve against the live roster
    // (never invented content); playback position is deliberately NOT restored —
    // a review session can't be resumed blindly later, so a camera that was in
    // playback restores to its live view instead.
    //
    // Persistence is ACTIVE only on a clean operator boot: any boot-shaping dev
    // hook (WT_SECTION, WT_TABS, soak drivers…) makes the run ineligible, so
    // synthetic states never overwrite the guard's real view. Saves arm only
    // after the restore attempt resolves — boot defaults must not clobber the
    // saved state while the roster is still loading.
    readonly property bool restoreEligible:
        !wtRestoreOff && !wtDemo && !wtTabsTest && !wtEventsTest && !wtHeroTest
        && wtMergeTest === "" && wtSeek10k === ""
        && wtSection === "" && wtTabs === "" && wtStatusFilter === "" && wtWinSize === ""
        && wtFocusIp === "" && wtDetailIp === "" && wtPlaybackIp === "" && wtGroup === ""
        && wtWallDay === "" && !wtGuardSoak && !wtFsoak && !wtNightSoak && !wtCalStress
        && !wtResizeTest && wtChurnTest === 0
    property bool _vsArmed: false    // saves allowed (post-restore)
    // Restore attempt resolved. Starts TRUE when restore is ineligible (fixture
    // envs, dev shortcuts): nothing will ever run _vsFinish then, and anything
    // gated on _vsDone — cold-launch deep links, measured 2026-08-23 — would
    // wait forever on a flag with no setter.
    property bool _vsDone: !restoreEligible

    function _vsCapture() {
        var t = [];
        for (var i = 1; i < tabs.length; i++)
            if (tabs[i].kind === "camera") t.push(tabs[i].camId);   // prefs tab is not worth restoring
        return JSON.stringify({
            v: 1, at: Date.now(),
            section: section, layout: gridLayout, page: gridPage,
            status: statusFilter, sort: sortMode,
            // The map-selection pseudo-group is session-local — never persist it.
            group: groupFilter === "__selected__" ? "" : groupFilter,
            groupLabel: groupFilter === "__selected__" ? qsTr("All cameras") : groupLabel,
            sidebar: opsSidebarOpen,
            mainCam: mainTabCamera ? mainTabCamera.camId : "",
            tabs: t, active: activeTab
        });
    }
    // The binding reads every shell property, so ANY navigation refreshes the
    // blob; the debounce collapses a click-burst into one sync()ed write.
    property string _vsBlob: _vsCapture()
    on_VsBlobChanged: if (_vsArmed && restoreEligible) vsSaveDebounce.restart()
    Timer { id: vsSaveDebounce; interval: 1000; onTriggered: Settings.saveViewState(win._vsBlob) }
    // Idle-age heartbeat (CW-15 endurance finding F1): an untouched session never
    // changes the blob, so `at` never refreshed and a guard who simply WATCHED the
    // wall all day crossed the 24 h freshness window — a crash after that restored
    // nothing. The freshness rule targets machines that were OFF for days, not
    // sessions that ran quietly; an hourly re-save keeps a running session forever
    // inside the window at the cost of one small write.
    Timer {
        interval: 3600000; repeat: true
        running: win._vsArmed && win.restoreEligible
        onTriggered: Settings.saveViewState(win._vsCapture())
    }

    function _vsFinish(outcome) {
        if (outcome !== "applied") console.log("[RESTORE] skipped (" + outcome + ")");
        _vsDone = true;
        _vsArmed = true;
    }
    Timer {
        id: vsRestore
        interval: 700; repeat: true
        running: win.restoreEligible && !win._vsDone
        property int tries: 0
        onTriggered: {
            tries++;
            var raw = Settings.viewState();
            if (raw === "") { win._vsFinish("none"); return; }
            // Tabs/cameras resolve against the roster — wait for it (bounded:
            // a backendless boot must still arm saves eventually).
            // Two different waits, deliberately. Not-authenticated is the
            // backendless boot the short bound exists for — saves must arm
            // eventually even with no server. Authenticated-but-empty is a
            // server that IS there and merely slow, and giving up on it throws
            // away the operator's saved wall for the rest of the session.
            //
            // Observed 2026-08-16 02:30: /streams 500'd after 31 s under host
            // load (8-11 s typical, 30 s timeout), restore gave up at 02:31:10,
            // and the roster landed at 02:31:56 — 46 s after we stopped caring.
            // The wall then came up in a default layout and the operator
            // reasonably read that as "no cameras loaded". 42 s is not a
            // property of the operator's intent, it is a property of a bad
            // afternoon on the backend.
            if (!AuthController.authenticated) {
                if (tries > 60) win._vsFinish("timeout-no-auth");     // ~42 s
                return;
            }
            if (cameraModel.total === 0) {
                if (tries > 430) win._vsFinish("timeout-no-roster");  // ~5 min
                return;
            }
            var s;
            try { s = JSON.parse(raw); } catch (e) { win._vsFinish("corrupt"); return; }
            if (!s || s.v !== 1) { win._vsFinish("unknown-version"); return; }
            if ((Date.now() - (s.at || 0)) > 24 * 3600 * 1000) { win._vsFinish("stale"); return; }
            win.gridLayout = s.layout || "16";
            win.gridPage = s.page || 1;
            win.statusFilter = s.status || "";
            win.sortMode = s.sort || "live";
            win.groupFilter = s.group || "";
            win.groupLabel = s.groupLabel || qsTr("All cameras");
            win.opsSidebarOpen = s.sidebar !== false;
            win.section = (!s.section || s.section === "preferences") ? "live" : s.section;
            var t = [{ "kind": "main" }];
            var lost = 0;
            var saved = s.tabs || [];
            for (var i = 0; i < saved.length; i++) {
                var c = cameraModel.cameraByBackendId(saved[i]);
                if (c && c.camId) t.push({ "kind": "camera", "camId": c.camId, "cam": c });
                else lost++;                       // camera left the roster — drop honestly
            }
            win.tabs = t;
            if (s.mainCam) {
                var mc = cameraModel.cameraByBackendId(s.mainCam);
                win.mainTabCamera = (mc && mc.camId) ? mc : null;
            } else {
                win.mainTabCamera = null;
            }
            win.activateTab(Math.max(0, Math.min(s.active || 0, t.length - 1)));
            console.log("[RESTORE] applied section=" + win.section + " layout=" + win.gridLayout
                        + " tabs=" + (t.length - 1) + (lost ? " lost=" + lost : "")
                        + " active=" + win.activeTab
                        + " age_s=" + Math.round((Date.now() - s.at) / 1000));
            win._vsFinish("applied");
        }
    }

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
        mainTabCamera = null;
        activateTab(0);              // lands on the main tab (also clears playback)
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
        groupLabel = qsTr("Selected (%1)").arg(ids.length);
        mainTabCamera = null;
        activateTab(0);
        wallMode = "live";
        section = "live";
    }

    // Left-rail navigation. Camera detail, single-camera playback, and wall
    // playback are full-screen overlays that layer OVER a section (they gate on
    // focusedCamera / playbackCamera / wallMode, not on `section`), so setting
    // `section` alone leaves them up and the rail looks dead — e.g. clicking LIVE
    // while already in wall playback (section is already "live") wouldn't exit it.
    // Clear every overlay so a rail click always lands on that section's main view.
    // Camera TABS are left standing — the rail navigates the main tab, it doesn't
    // close the other places the operator is keeping open.
    function goToSection(sid) {
        mainTabCamera = null;
        activateTab(0);
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
        function _fs() { var c = guardSoak._randCam(); if (c) win.openCameraHere(c); }       // double-click → fullscreen
        function _fsExit() { win.closeCameraHere(); }
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
        if (groupFilter === "__selected__") { groupFilter = ""; groupLabel = qsTr("All cameras"); }
    }
    function setStatusFilter(f) { statusFilter = f; gridPage = 1 }
    // Topbar status chips are SITE-level numbers, so engaging one widens the wall to the
    // whole site (operator, 2026-08-20: "Offline 7" over a group-scoped wall showed the
    // group's 2 offliners — the honest intersection, but you clicked a 7 and must see 7).
    // Clearing the chip leaves whatever scope the user has since chosen untouched.
    // ---- shareable event links (cilex:// scheme, operator order 2026-08-21) ----
    // The link IDENTIFIES, never authorizes: nothing resolves before sign-in, a
    // foreign installation's link is surfaced honestly (never silently retargeted),
    // and every fetch behind the reveal rides the server's normal auth.
    property string _queuedLink: ""
    function handleDeepLink(u) {
        // Every exit logs — the 2026-08-23 wrong-video session was undiagnosable
        // because three of these branches returned in silence.
        DeepLink.clearPending();
        var r = DeepLink.parse(u);
        if (!r.ok) {
            console.log("[LINK] parse REJECTED (bad token/checksum/scheme)");
            toastHost.show(qsTr("Link"), qsTr("Not a Cilex Watchtower link"), "bad", "", "");
            return;
        }
        if (!AuthController.authenticated) { console.log("[LINK] queued until sign-in"); _queuedLink = u; return; }
        if (!_vsDone) { console.log("[LINK] queued until view-state restore"); _queuedLink = u; return; }
        if (!r.sameSite) {
            console.log("[LINK] foreign site=" + r.site + " current=" + r.currentSite);
            toastHost.show(qsTr("Link"),
                qsTr("This link belongs to another Cilex installation (%1) — this Watchtower is signed in to %2").arg(r.site).arg(r.currentSite),
                "accent", "", "");
            return;
        }
        console.log("[LINK] accepted event=" + r.event + " -> events section");
        goToSection("events");
        // The feed ingests asynchronously after the section opens — wait for it
        // (bounded) instead of false-negating a perfectly shareable event.
        _linkWaitEvent = r.event; _linkWaitTicks = 0;
        linkWait.restart();
    }
    property string _linkWaitEvent: ""
    // Mirrored onto EventsStore so the queue can show the search. Deliberately a CHANGE
    // HANDLER and not five assignments: this state is cleared on four different exit
    // paths (found, resolved-by-id, resolve-failed, timeout) and a fifth added later
    // would otherwise leave the indicator spinning over a search that already ended.
    on_LinkWaitEventChanged: EventsStore.linkSearchId = _linkWaitEvent
    property int _linkWaitTicks: 0
    property bool _linkResolving: false
    Timer {
        id: linkWait
        interval: 500; repeat: true
        onTriggered: {
            if (win._linkWaitEvent === "") { stop(); return; }
            var evs = EventsStore.events;
            for (var i = 0; i < evs.length; i++)
                if (evs[i].id === win._linkWaitEvent) {
                    console.log("[LINK] resolved event=" + win._linkWaitEvent + " cam="
                                + (evs[i].cam ? evs[i].cam.id : "?") + " after " + win._linkWaitTicks + " ticks");
                    win.holdLinkedEvent(win._linkWaitEvent);
                    eventsArea.openInTriage(win._linkWaitEvent, "");
                    win._linkWaitEvent = ""; stop(); return;
                }
            if (win._linkWaitTicks === 20 && !win._linkResolving) {   // ~10 s: not in the loaded queue
                // Closed/aged events are NOT in the open queue — resolve by id
                // (GET /events/{id}; live server-side since CV's reply, events.py:873).
                // The 2026-08-23 wrong-video illusion: this path used to give up here
                // and the queue head autoplayed AS IF it were the linked clip.
                win._linkResolving = EventsStore.resolveById(win._linkWaitEvent);
                console.log("[LINK] not in queue, by-id resolve "
                            + (win._linkResolving ? "dispatched" : "unavailable")
                            + " event=" + win._linkWaitEvent);
            }
            if (++win._linkWaitTicks > 60) {                 // +20 s for the resolve round-trip
                console.log("[LINK] resolve TIMEOUT event=" + win._linkWaitEvent);
                toastHost.show(qsTr("Link"),
                    qsTr("The linked event is not available — it may not exist, or your sign-in cannot see it"),
                    "bad", "", "");
                win._linkWaitEvent = ""; win._linkResolving = false; stop();
            }
        }
    }
    // Retention hold (operator rule 2026-08-28): "if somebody had searched for the clip
    // [it is] important enough to not be deleted". A clip reached by share link is
    // evidence someone is working — it must not vanish under the rolling retention sweep.
    //
    // HONEST BOUNDARY, and it is the whole of the caveat: Watchtower does not own the
    // footage and cannot stop a deletion. Cameras have no storage; retention is
    // cilex-vision's sweep over ITS archive, and the API exposes no hold/preserve verb —
    // grep-verified across the contract 2026-08-28, only read-only retentionDays on
    // /coverage. So this records the INTENT durably and locally, which is the half we
    // own, and the ask is filed as docs/letters/2026-08-28-retention-hold-for-linked-clips.md.
    // When that endpoint lands, this function is the one place that gains the PUT — and
    // Settings.heldEventIds is the backlog to replay. It is deliberately NOT surfaced as
    // "protected" anywhere in the UI: claiming a clip is safe when the server can still
    // delete it is exactly the green-by-default failure the house rules forbid.
    function holdLinkedEvent(evId) {
        if (!evId) return;
        if (Settings.isEventHeld(evId)) { console.log("[HOLD] already held event=" + evId); return; }
        Settings.holdEvent(evId);
        console.log("[HOLD] linked event marked for non-deletion event=" + evId
                    + " (local intent; server-side hold PENDING — no API yet)");
    }
    Connections {
        target: DeepLink
        function onLinkReceived(u) { win.handleDeepLink(u) }
    }
    Connections {
        target: EventsStore
        // Share-link by-id resolve outcomes (EventsStore relays EventModel signals).
        function onLinkResolved(row) {
            if (win._linkWaitEvent === "" || row.eventId !== win._linkWaitEvent) return;
            var ts = row.triageState;
            var tab = (ts === "resolved" || ts === "dismissed") ? "all" : "";
            console.log("[LINK] resolved by id event=" + row.eventId + " state=" + ts
                        + (tab !== "" ? " tab=all" : ""));
            win.holdLinkedEvent(row.eventId);
            eventsArea.openInTriage(row.eventId, "", tab);
            win._linkWaitEvent = ""; win._linkResolving = false; linkWait.stop();
        }
        function onLinkResolveFailed(eventId, code) {
            if (win._linkWaitEvent === "" || eventId !== win._linkWaitEvent) return;
            // 404 covers absent AND forbidden by server design (the enumeration-
            // oracle conflation) — this wording must never distinguish them.
            toastHost.show(qsTr("Link"),
                qsTr("The linked event is not available — it may not exist, or your sign-in cannot see it"),
                "bad", "", "");
            win._linkWaitEvent = ""; win._linkResolving = false; linkWait.stop();
        }
    }
    Connections {
        target: AuthController
        function onAuthenticatedChanged() {
            if (AuthController.authenticated && win._queuedLink !== "") {
                var u = win._queuedLink; win._queuedLink = "";
                win.handleDeepLink(u);
            }
        }
    }
    on_VsDoneChanged: if (_vsDone && _queuedLink !== "") {
        var u = _queuedLink; _queuedLink = "";
        handleDeepLink(u);
    }
    function toggleStatusChip(which) {
        var engaging = statusFilter !== which;
        if (engaging) {
            groupFilter = ""; groupLabel = qsTr("All cameras");
            if (section !== "live") goToSection("live");
        }
        setStatusFilter(engaging ? which : "");
    }
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
        if (!gid) return { id: "", label: qsTr("All cameras") };
        var gs = cameraModel.groupList();
        if (gs.length === 0) return { id: gid, label: label };
        for (var i = 0; i < gs.length; i++)
            if (gs[i].id === gid) return { id: gid, label: gs[i].name };
        return { id: "", label: qsTr("All cameras") };
    }

    // Restore a saved view's merged cells. The spans live in Settings under
    // (group, layout) because that is what LiveMonitor reads, but the AUTHORITY is
    // now the view itself — so opening a view WITHOUT merges must CLEAR the key,
    // not leave whatever was merged last. Otherwise a plain view silently inherits
    // the previous view's big tiles, which is the same class of bug as the one the
    // operator reported on 2026-09-02, just in the other direction.
    function applyViewSpans(groupId, layout, spans) {
        if (spans && spans.length > 0) Settings.setLiveSpans(groupId, layout, spans);
        else                           Settings.clearLiveSpans(groupId, layout);
        liveMonitor.spansRev++;        // spanState is cached against this counter
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
    // Deferred day open for WT_PLAYBACK_DAY — fires once coverage has answered, so the
    // hook reproduces a real calendar click (fast-open included) rather than racing it.
    Timer {
        id: dayBootHook
        property string day: ""
        interval: 250; repeat: true
        onTriggered: {
            if (playbackScreen.coveragePending) return;   // still waiting on /review/coverage
            stop();
            if (day.indexOf("T") > 0)
                playbackScreen.openAt(playbackScreen.camera, new Date(day).getTime());
            else
                playbackScreen.openForDay(day);
        }
    }
    // Leaving the Live section drops wall-playback back to live (and stops its player via visibility).
    onSectionChanged: if (section !== "live") wallMode = "live"

    Component.onCompleted: {
        if (typeof wtWinSize !== "undefined" && wtWinSize !== "") {
            var wh = String(wtWinSize).split("x");
            if (wh.length === 2 && +wh[0] >= 400 && +wh[1] >= 300) { win.width = +wh[0]; win.height = +wh[1]; }
        }
        cameraModel.setCameraScope(AuthController.cameraScope);
        if (typeof wtSection === "undefined" || wtSection === "") applyDefaultLanding();
        else if (win.section === "preferences") { win.section = "live"; win.openPreferences(); }
        // A cold-launch deep link navigates LAST — before the landing logic it
        // would be silently overridden back to the default section (measured:
        // first build of this feature landed on Live with the link swallowed).
        if (DeepLink.pendingUrl !== "") handleDeepLink(DeepLink.pendingUrl);
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
        // WT_FOCUS_DELAY_MS (test): wait this long after the roster lands before focusing, so
        // the wall's tiles (and their warm-keeps) exist first — otherwise the hook measures a
        // COLD open the instant /streams returns, which is not what a guard clicking a tile
        // on a lit wall experiences (measured 2026-09-08: 3 runs, no warm-keep had fired).
        property int _focusDelay: (typeof wtFocusDelayMs !== "undefined" && wtFocusDelayMs > 0) ? wtFocusDelayMs : 0
        property double _rosterAt: 0
        running: typeof wtFocusIp !== "undefined" && wtFocusIp !== "" && win.focusedCamera === null
        onTriggered: {
            // FULL roster, not page 1-of-50: a camera beyond row 50 was silently never
            // matched (the same bug playbackBootHook fixed 2026-08-21; re-found 2026-09-08
            // when .103, camera ~60 of 133, never opened across ten runs).
            var all = [];
            for (var r = 0; r < cameraModel.total; r++) all.push(cameraModel.get(r));
            // WT_FOCUS_IP=page:<armed|recording|any> — pick a camera from the wall's CURRENT page at
            // click time (rock-n-roll soak 2026-09-12: the page's sixteen change between launches,
            // so an ip chosen before launch lands off-page and measures the cold path instead of
            // the adoption the operator's live target is about).
            var want = String(wtFocusIp);
            if (want.indexOf("page:") === 0) {
                var kind = want.substring(5);
                var pc = (typeof liveMonitor !== "undefined" && liveMonitor.pagedCameras) ? liveMonitor.pagedCameras : [];
                var pool = [], anyPool = [];
                for (var k = 0; k < pc.length; k++) {
                    var pcam = pc[k]; if (!pcam || !pcam.ip) continue;
                    anyPool.push(pcam);
                    var armed = (pcam.recording === CameraStatus.Armed);
                    if ((kind === "armed" && armed) || (kind === "recording" && pcam.recording === CameraStatus.Recording)) pool.push(pcam);
                }
                if (kind === "any" || pool.length === 0) pool = anyPool;
                if (pool.length === 0) return;                       // page not built yet — keep ticking
                want = pool[Math.floor(Math.random() * pool.length)].ip;
            }
            for (var i = 0; i < all.length; i++)
                if (all[i] && all[i].ip === want) {
                    // Delay gate: the roster is here; keep ticking (the Timer repeats while
                    // focusedCamera is null) until the delay has elapsed, THEN open once.
                    if (_focusDelay > 0) {
                        if (_rosterAt === 0) _rosterAt = Date.now();
                        if (Date.now() - _rosterAt < _focusDelay) break;
                    }
                    win.openCameraHere(all[i]); break;
                }
        }
    }
    // Dev hook: WT_FOCUS_CLOSE_MS closes the focused camera that long after it opened, so one
    // run also measures the RETURN path — the wall tile re-adopting the detail view's pipeline
    // (see RtspVideoSource ParkingLot) instead of rebuilding into a mid-GOP keyframe wait.
    Timer {
        interval: (typeof wtFocusCloseMs !== "undefined" && wtFocusCloseMs > 0) ? wtFocusCloseMs : 1
        repeat: false
        running: typeof wtFocusCloseMs !== "undefined" && wtFocusCloseMs > 0 && win.focusedCamera !== null
        onTriggered: {
            console.log("[LIVETIME] close t=" + Date.now() + " cam=" + (win.focusedCamera ? win.focusedCamera.ip : "?"));
            win.closeCameraHere();
        }
    }
    // Dev hook: WT_TABS=<ip>[,<ip>…] opens those cameras as view tabs once the
    // roster has loaded (screenshot verification + soak coverage for the strip).
    Timer {
        id: tabsBootHook
        interval: 500; repeat: true
        running: typeof wtTabs !== "undefined" && wtTabs !== ""
        onTriggered: {
            var all = cameraModel.page("", "", "default", 1, 64);
            if (all.length === 0) return;
            var want = ("" + wtTabs).split(",");
            for (var w = 0; w < want.length; w++) {
                var ip = want[w].trim();
                for (var i = 0; i < all.length; i++)
                    if (all[i].ip === ip) { win.openCameraTab(all[i]); break; }
            }
            if (typeof wtTabsHome !== "undefined" && wtTabsHome) win.activateTab(0);
            tabsBootHook.running = false;
        }
    }
    // ---- WT_SEEK10K: large-scale scrubber seek-latency harness -------------
    // Measures the OPERATOR metric: the click-equivalent seekToWall() call →
    // the first RENDERED frame within ±3 s of the target while playback is
    // advancing (frame truth via FrameClock.lastPtsMs mapped through
    // posToWall — "position moved" is never trusted as "landed"). Landing is
    // checked on every rendered-frame event (~40 ms resolution); the timer
    // only drives the state machine and the 20 s timeout. One log line per
    // seek:
    //   [SEEK10K] i=N cam=<ip> day=<d> tgt=<s-into-day> dist=<s> reopen=0|1 dt=<ms>
    // dt=-1 marks a timeout (give-up path) — counted, never hidden. Targets
    // are drawn ONLY from real footage fragments (tlFrags spans >15 s), so a
    // measurement is always "video should exist here".
    readonly property int _s10kFrameSeq: playbackScreen._frameSeq
    on_S10kFrameSeqChanged: seek10k.checkLanding()
    Timer {
        id: seek10k
        interval: 120; repeat: true
        running: wtSeek10k !== ""
        property var flat: []          // [{ip, day}] shuffled; combos retire when cold-dry
        property int planIdx: 0
        property int done: 0
        readonly property int total: wtSeek10kN > 0 ? wtSeek10kN : 10000
        property int perOpen: 12       // seeks per day-open (amortizes opens, keeps date variety)
        property int perOpenThis: 12   // this open's quota (jittered when WT_SEEK10K_PEROPEN set)
        // ES date-time without offset parses as LOCAL time — exactly what "end at 8AM" means.
        readonly property double untilMs: (typeof wtSeek10kUntil !== "undefined" && wtSeek10kUntil !== "")
                                          ? Date.parse(wtSeek10kUntil) : -1
        readonly property string todayStr: Qt.formatDate(new Date(), "yyyy-MM-dd")
        property var dryAt: ({})       // comboKey → ms when it went cold-dry (today's date re-wets)
        // Flapping-day cooldown (2026-08-02): the nightly backend contention makes
        // some day-opens hang >180 s INTERMITTENTLY; last night each flapper was
        // retried every cycle — 100 hangs × 180 s = 5 h of the window burned.
        // One hang parks the combo for 45 min instead.
        property var openFailAt: ({})
        // Cold-run bookkeeping: exclMap = warm shadows from PRIOR runs (env file),
        // usedMap = this run's own touches. A target must sit ≥ minSepS from every
        // entry of both for its combo — first-touch cold, or it isn't measured.
        property var exclMap: ({})
        property var usedMap: ({})
        readonly property int minSepS: 120
        function comboKey(e) { return e.ip + "|" + e.day; }
        function isCold(e, offSec) {
            var lists = [exclMap[comboKey(e)], usedMap[comboKey(e)]];
            for (var l = 0; l < 2; l++) {
                var a = lists[l];
                if (!a) continue;
                for (var i = 0; i < a.length; i++)
                    if (Math.abs(a[i] - offSec) < minSepS) return false;
            }
            return true;
        }
        function markUsed(e, offSec) {
            var k = comboKey(e);
            if (!usedMap[k]) usedMap[k] = [];
            usedMap[k].push(offSec);
        }
        property int inOpen: 0
        property string st: "boot"
        property double t0: 0
        property double target: 0
        property double prevWall: 0
        property int genAtSeek: 0
        property int waitTicks: 0
        property int timeouts: 0
        property int openFails: 0
        property int seqAtSeek: 0
        // Landing = NSEEK's proven recipe (the night-soak seek verifier): a NEW
        // rendered frame since the click (frameSeq advance — defuses the
        // position-moved-early trap: during a far-seek re-anchor the OLD player
        // keeps rendering, so playhead-nearness alone would lie) AND playheadMs
        // (absolute wall) within ±5 s of the target. Evaluated on every rendered
        // frame → ~frame-interval precision. FrameClock.lastPtsMs is deliberately
        // NOT used: it is segment-relative on this pipeline (probed 2026-07-31).
        function checkLanding() {
            if (st !== "watch") return;
            if (playbackScreen._frameSeq <= seqAtSeek) return;
            if (Math.abs(playbackScreen.playheadMs - target) > 5000) return;
            var dt = Date.now() - t0;
            var e = flat[planIdx % flat.length];
            console.log("[SEEK10K] i=" + (done + 1) + " cam=" + e.ip + " day=" + e.day
                        + " tgt=" + Math.round((target - playbackScreen.tlStartMs) / 1000)
                        + " dist=" + Math.round(Math.abs(target - prevWall) / 1000)
                        + " reopen=" + (playbackScreen._openGen !== genAtSeek ? 1 : 0)
                        + " dt=" + dt);
            done++; inOpen++; st = "settle"; waitTicks = 0;
        }
        function pickTarget() {
            var fr = playbackScreen.tlFrags, spans = [], tot = 0;
            for (var i = 0; i < fr.length; i++) {
                var d = fr[i].we - fr[i].ws;
                if (d > 15000) { spans.push(fr[i]); tot += d - 7000; }
            }
            if (spans.length === 0 || tot <= 0) return -1;
            // Rejection-sample a COLD offset: up to 80 draws avoiding the warm
            // shadow of every prior touch (both runs). No luck = the day's cold
            // pockets are spent → -2 retires the combo (honest, never recycled warm).
            var e = flat[planIdx % flat.length];
            for (var t = 0; t < 80; t++) {
                var r = Math.random() * tot, cand = -1;
                for (var j = 0; j < spans.length; j++) {
                    var usable = spans[j].we - spans[j].ws - 7000;
                    if (r <= usable) { cand = spans[j].ws + 2000 + r; break; }
                    r -= usable;
                }
                if (cand < 0) continue;
                var offSec = Math.round((cand - playbackScreen.tlStartMs) / 1000);
                if (isCold(e, offSec)) return cand;
            }
            return -2;
        }
        onTriggered: {
            // Hard wall-clock deadline (overnight mode) — checked every tick, so the
            // stop is exact regardless of what state the machine is in.
            if (untilMs > 0 && Date.now() >= untilMs && st !== "boot") {
                console.log("[SEEK10K] DONE done=" + done + " timeouts=" + timeouts
                            + " openFails=" + openFails + " (deadline reached)");
                Qt.quit(); return;
            }
            if (st === "boot") {
                if (!AuthController.authenticated || cameraModel.total === 0) return;
                try { var plan = JSON.parse(wtSeek10k); } catch (e) { console.log("[SEEK10K] BAD PLAN"); running = false; return; }
                flat = [];
                for (var p = 0; p < plan.length; p++)
                    for (var d = 0; d < plan[p].days.length; d++)
                        flat.push({ ip: plan[p].ip, day: plan[p].days[d] });
                if (flat.length === 0) { console.log("[SEEK10K] EMPTY PLAN"); running = false; return; }
                // Prior-run warm shadows (cold mode): "ip|day|sec" lines via env file.
                if (typeof wtSeek10kExclude !== "undefined" && wtSeek10kExclude !== "") {
                    var lines = wtSeek10kExclude.split("\n"), nx = 0;
                    for (var x = 0; x < lines.length; x++) {
                        var parts = lines[x].trim().split("|");
                        if (parts.length !== 3) continue;
                        var k = parts[0] + "|" + parts[1];
                        if (!exclMap[k]) exclMap[k] = [];
                        exclMap[k].push(parseInt(parts[2]));
                        nx++;
                    }
                    console.log("[SEEK10K] cold mode: " + nx + " excluded warm shadows, minSep=" + minSepS + "s");
                }
                for (var s = flat.length - 1; s > 0; s--) {           // shuffle: random date order
                    var q = Math.floor(Math.random() * (s + 1));
                    var tmp = flat[s]; flat[s] = flat[q]; flat[q] = tmp;
                }
                console.log("[SEEK10K] START total=" + total + " combos=" + flat.length + " perOpen=" + perOpen);
                st = "open";
            } else if (st === "open") {
                var e = flat[planIdx % flat.length];
                // A dry TODAY re-wets as recording accrues — skip it for 20 min, don't retire.
                if (dryAt[comboKey(e)] !== undefined) {
                    if (e.day === todayStr && Date.now() - dryAt[comboKey(e)] > 20 * 60000)
                        delete dryAt[comboKey(e)];               // enough new footage may exist — retry
                    else { planIdx++; waitTicks++;
                           if (waitTicks > flat.length * 3) { waitTicks = 0; st = "coldwait"; }
                           return; }
                }
                // A flapping day (open hung >180 s) cools down for 45 min.
                if (openFailAt[comboKey(e)] !== undefined) {
                    if (Date.now() - openFailAt[comboKey(e)] > 45 * 60000)
                        delete openFailAt[comboKey(e)];
                    else { planIdx++; waitTicks++;
                           if (waitTicks > flat.length * 3) { waitTicks = 0; st = "coldwait"; }
                           return; }
                }
                var all = cameraModel.page("", "", "default", 1, 64), cam = null;
                for (var i = 0; i < all.length; i++) if (all[i].ip === e.ip) { cam = all[i]; break; }
                if (!cam) { console.log("[SEEK10K] cam gone: " + e.ip); planIdx++; return; }
                win.focusedCamera = cam; win.playbackCamera = cam; playbackScreen.camera = cam;
                playbackScreen.openForDay(e.day);
                perOpenThis = (typeof wtSeek10kPerOpen !== "undefined" && wtSeek10kPerOpen > 0)
                              ? Math.max(1, wtSeek10kPerOpen + Math.floor(Math.random() * 3) - 1)
                              : perOpen;
                inOpen = 0; waitTicks = 0; st = "await";
            } else if (st === "coldwait") {
                // Every combo is dry and only a growing TODAY can re-wet — idle 5 min.
                if (++waitTicks > 2500) { waitTicks = 0; st = "open"; }
            } else if (st === "await") {
                if (playbackScreen.tlEndMs > playbackScreen.tlStartMs && playbackScreen.advancing) {
                    waitTicks = 0; st = "settle";
                } else if (++waitTicks > 1500) {                      // 180 s — give pristine days their first synth; skip dead combo
                    console.log("[SEEK10K] OPEN-TIMEOUT cam=" + flat[planIdx % flat.length].ip
                                + " day=" + flat[planIdx % flat.length].day);
                    openFailAt[comboKey(flat[planIdx % flat.length])] = Date.now();
                    openFails++; planIdx++; st = "open";
                }
            } else if (st === "seek") {
                target = pickTarget();
                if (target === -2) {                                  // cold pockets spent
                    var eDry = flat[planIdx % flat.length];
                    if (eDry.day === todayStr || untilMs > 0) {
                        // Overnight/growing-day mode: mark dry, revisit later
                        // (TODAY re-wets; others stay skipped until the deadline).
                        dryAt[comboKey(eDry)] = Date.now();
                        console.log("[SEEK10K] combo COLD-DRY (parked): " + eDry.ip + " " + eDry.day);
                        planIdx++; st = "open"; return;
                    }
                    var dead = flat.splice(planIdx % flat.length, 1)[0];
                    console.log("[SEEK10K] combo COLD-DRY, retired: " + dead.ip + " " + dead.day
                                + " (" + flat.length + " combos left)");
                    if (flat.length === 0) {
                        console.log("[SEEK10K] DONE done=" + done + " timeouts=" + timeouts
                                    + " openFails=" + openFails + " (cold inventory exhausted)");
                        Qt.quit(); return;
                    }
                    st = "open"; return;
                }
                if (target < 0) { console.log("[SEEK10K] no usable footage, skipping combo"); planIdx++; st = "open"; return; }
                markUsed(flat[planIdx % flat.length],
                         Math.round((target - playbackScreen.tlStartMs) / 1000));
                prevWall = playbackScreen.playheadMs > 0 ? playbackScreen.playheadMs
                                                         : playbackScreen.tlStartMs;
                genAtSeek = playbackScreen._openGen;
                seqAtSeek = playbackScreen._frameSeq;
                t0 = Date.now();
                playbackScreen.seekToWall(target);
                waitTicks = 0; st = "watch";
            } else if (st === "watch") {
                checkLanding();                                       // belt: poll besides the frame event
                if (waitTicks > 0 && waitTicks % 42 === 0)
                    console.log("[SEEK10K][probe] ph=" + Math.round((playbackScreen.playheadMs - playbackScreen.tlStartMs) / 1000)
                                + " tgt=" + Math.round((target - playbackScreen.tlStartMs) / 1000)
                                + " seq=" + playbackScreen._frameSeq + "/" + seqAtSeek
                                + " adv=" + playbackScreen.advancing
                                + " gen=" + playbackScreen._openGen + "/" + genAtSeek);
                if (++waitTicks > 167) {                              // 20 s — honest give-up
                    var e2 = flat[planIdx % flat.length];
                    console.log("[SEEK10K] i=" + (done + 1) + " cam=" + e2.ip + " day=" + e2.day
                                + " tgt=" + Math.round((target - playbackScreen.tlStartMs) / 1000)
                                + " dist=" + Math.round(Math.abs(target - prevWall) / 1000)
                                + " reopen=" + (playbackScreen._openGen !== genAtSeek ? 1 : 0)
                                + " dt=-1");
                    timeouts++; done++; inOpen++; st = "settle"; waitTicks = 0;
                }
            } else if (st === "settle") {
                if (++waitTicks < 3) return;                          // ~360 ms between seeks
                if (done >= total) {
                    console.log("[SEEK10K] DONE done=" + done + " timeouts=" + timeouts
                                + " openFails=" + openFails);
                    Qt.quit(); return;
                }
                if (inOpen >= perOpenThis) { planIdx++; st = "open"; }
                else st = "seek";
            }
        }
    }

    // Dev self-test (merged cells): WT_MERGE_TEST=seed drives Shift-drag-equivalent
    // selection + merge on a fresh profile and quits; =verify (new process, same
    // profile) asserts persistence, then splits and asserts restoration.
    // [MERGETEST] PASS/FAIL. Exercises the exact shipping functions.
    Timer {
        id: mergeTest
        interval: 600; repeat: true
        running: wtMergeTest !== ""
        property int fails: 0
        function ck(label, got, want) {
            var ok = String(got) === String(want);
            if (!ok) mergeTest.fails++;
            console.log("[MERGETEST] " + (ok ? "ok  " : "FAIL") + " " + label + " got=" + got + " want=" + want);
        }
        function region5() {   // the expected slot-5 region of a (1,1)-(2,2) merge on 4×4
            var c = liveMonitor.lcells[5];
            return c.c + "," + c.r + "," + c.cw + "," + c.ch;
        }
        onTriggered: {
            if (!AuthController.authenticated || cameraModel.total < 16) return;
            if (win.section !== "live") win.goToSection("live");
            if (win.gridLayout !== "16") { win.setLayout("16"); return; }   // next tick re-enters
            if (!liveMonitor.visible) return;
            mergeTest.running = false;
            if (wtMergeTest === "seed") {
                var anchorBefore = liveMonitor.pagedCameras.length > 5 ? liveMonitor.pagedCameras[5].camId : "?";
                liveMonitor.startSel({ c: 1, r: 1 });
                liveMonitor.extendSel({ c: 2, r: 2 });
                mergeTest.ck("sel", liveMonitor._selW + "x" + liveMonitor._selH, "2x2");
                mergeTest.ck("selName", liveMonitor.selAnchorName !== "", true);
                mergeTest.ck("merged", liveMonitor.mergeSelection(), true);
                mergeTest.ck("perPage", liveMonitor.perPage, 13);
                mergeTest.ck("region@5", region5(), "1,1,2,2");
                mergeTest.ck("anchorCamKept",
                             liveMonitor.pagedCameras.length > 5 ? liveMonitor.pagedCameras[5].camId : "?",
                             anchorBefore);
                console.log("[MERGETEST] SEEDED " + (mergeTest.fails === 0 ? "PASS" : "FAIL")
                            + " fails=" + mergeTest.fails);
                Qt.quit();
            } else {                                            // verify
                mergeTest.ck("persisted.perPage", liveMonitor.perPage, 13);
                mergeTest.ck("persisted.region@5", region5(), "1,1,2,2");
                mergeTest.ck("selectRegion.split", (function () {
                    liveMonitor.mergeSel = { c0: 1, r0: 1, c1: 2, r1: 2, ac: 1, ar: 1 };
                    var wasSplitMode = liveMonitor.selIsRegion;
                    return wasSplitMode && liveMonitor.mergeSelection();
                })(), true);
                mergeTest.ck("split.perPage", liveMonitor.perPage, 16);
                mergeTest.ck("spans.cleared", liveMonitor.hasSpans, false);
                console.log("[MERGETEST] " + (mergeTest.fails === 0 ? "PASS" : "FAIL")
                            + " fails=" + mergeTest.fails);
                Qt.quit();
            }
        }
    }
    // Dev self-test (CW-05): WT_RESTORE_TEST=seed navigates to a known state on a
    // fresh profile and persists it; WT_RESTORE_TEST=verify (same profile, new
    // process) asserts the restore reproduced it. [RESTTEST] PASS/FAIL.
    Timer {
        id: restTest
        interval: 600; repeat: true
        running: wtRestoreTest !== ""
        property int fails: 0
        function ck(label, got, want) {
            var ok = String(got) === String(want);
            if (!ok) restTest.fails++;
            console.log("[RESTTEST] " + (ok ? "ok  " : "FAIL") + " " + label + " got=" + got + " want=" + want);
        }
        onTriggered: {
            if (!win._vsDone) return;                       // restore attempt first
            if (!AuthController.authenticated || cameraModel.total === 0) return;
            if (wtRestoreTest === "seed") {
                var all = cameraModel.page("", "", "default", 1, 8);
                if (all.length < 3) return;
                restTest.running = false;
                // Deterministic seed even on a DIRTY profile: the verify phase asserts
                // section=live, but a prior session may have left (and restored) any
                // section — seed from the state the assertions assume.
                if (win.section !== "live") win.goToSection("live");
                win.openCameraHere(all[0]);                 // camera in the main tab
                win.openCameraTab(all[1]);
                win.openCameraTab(all[2]);
                win.activateTab(1);
                win.setLayout("9");
                Settings.saveViewState(win._vsCapture());   // deterministic (no debounce wait)
                console.log("[RESTTEST] SEEDED main=" + all[0].camId + " tabs=2 active=1 layout=9");
                Qt.quit();
            } else {
                restTest.running = false;
                restTest.ck("tabs.len", win.tabs.length, 3);
                restTest.ck("active", win.activeTab, 1);
                restTest.ck("layout", win.gridLayout, "9");
                restTest.ck("section", win.section, "live");
                restTest.ck("mainCam", win.mainTabCamera ? "set" : "null", "set");
                restTest.ck("focused", win.focusedCamera ? win.focusedCamera.camId : "null",
                            win.tabs.length > 1 ? win.tabs[1].camId : "?");
                console.log("[RESTTEST] " + (restTest.fails === 0 ? "PASS" : "FAIL") + " fails=" + restTest.fails);
                Qt.quit();
            }
        }
    }
    // Section-switch latency harness: WT_NAVTEST=N alternates live↔groups N round-
    // trips on the real roster. Two numbers per switch: [NAV] frame ui=<ms> (click →
    // first frame swapped with the new section — GUI-thread responsiveness) and,
    // offline, content settle from WT_TRACE [EVIMG] first-success times after each
    // "[NAV] go groups" timestamp. 12 s warm dwell first, 4 s per leg, then quit.
    Timer {
        id: navTest
        interval: 4000; repeat: true
        running: typeof wtNavTest !== "undefined" && wtNavTest > 0
        property int leg: -3          // negative legs = warm-up dwell (12 s on live)
        property double t0: 0
        onTriggered: {
            if (cameraModel.total < 5) return;                 // wait for the roster
            leg++;
            if (leg < 0) return;
            if (leg >= wtNavTest * 2) {
                console.log("[NAV] done legs=" + leg);
                navTest.running = false;
                Qt.quit();
                return;
            }
            var tgt = (win.section === "groups") ? "live" : "groups";
            t0 = Date.now();
            navFrame.armed = true;
            console.log("[NAV] go " + tgt);
            win.section = tgt;
        }
    }
    Connections {
        id: navFrame
        property bool armed: false
        target: win
        enabled: typeof wtNavTest !== "undefined" && wtNavTest > 0
        function onFrameSwapped() {
            if (!navFrame.armed) return;
            navFrame.armed = false;
            console.log("[NAV] frame section=" + win.section + " ui=" + (Date.now() - navTest.t0) + "ms");
        }
    }

    // Dev self-test: WT_TABS_TEST=1 drives the tab bookkeeping over the real roster
    // and asserts each outcome ([TABTEST] lines, then PASS/FAIL). Runs against the
    // shipping functions — index math (open · raise · navigate-in-place · close) is
    // exactly the part that silently rots, and it is not visible in a screenshot.
    Timer {
        id: tabTest
        interval: 500; repeat: true
        running: typeof wtTabsTest !== "undefined" && wtTabsTest
        property int fails: 0
        function ck(label, got, want) {
            var ok = (String(got) === String(want));
            if (!ok) tabTest.fails++;
            console.log("[TABTEST] " + (ok ? "ok  " : "FAIL") + " " + label + " got=" + got + " want=" + want);
        }
        function camIdOf(c) { return c ? c.camId : "null"; }
        onTriggered: {
            var all = cameraModel.page("", "", "default", 1, 8);
            if (all.length < 3) return;                       // wait for the roster
            tabTest.running = false;
            var a = all[0], b = all[1], c = all[2];

            tabTest.ck("start.len", win.tabs.length, 1);
            tabTest.ck("start.active", win.activeTab, 0);

            win.openCameraHere(a);                            // a tile's "Open" from the wall
            tabTest.ck("openHere.len", win.tabs.length, 1);   // no tab: it lives in the main tab
            tabTest.ck("openHere.focus", tabTest.camIdOf(win.focusedCamera), a.camId);

            win.openCameraTab(b);                             // "Open in new tab"
            tabTest.ck("newTab.len", win.tabs.length, 2);
            tabTest.ck("newTab.active", win.activeTab, 1);
            tabTest.ck("newTab.focus", tabTest.camIdOf(win.focusedCamera), b.camId);

            win.openCameraTab(c);
            tabTest.ck("newTab2.len", win.tabs.length, 3);
            tabTest.ck("newTab2.active", win.activeTab, 2);

            win.openCameraTab(b);                             // already open → raised, not duplicated
            tabTest.ck("dedupe.len", win.tabs.length, 3);
            tabTest.ck("dedupe.active", win.activeTab, 1);

            win.activateTab(0);                               // main tab keeps what was opened in it
            tabTest.ck("home.focus", tabTest.camIdOf(win.focusedCamera), a.camId);
            tabTest.ck("home.len", win.tabs.length, 3);

            win.activateTab(2);
            win.openCameraHere(a);                            // navigate the CURRENT tab in place
            tabTest.ck("inplace.len", win.tabs.length, 3);
            tabTest.ck("inplace.tab2", win.tabs[2].camId, a.camId);

            win.closeTab(2);                                  // active + last → left neighbour
            tabTest.ck("closeLast.len", win.tabs.length, 2);
            tabTest.ck("closeLast.active", win.activeTab, 1);

            win.openCameraTab(c);                             // [main, b, c], active 2
            win.activateTab(1);
            win.closeTab(1);                                  // active, has a right → that one
            tabTest.ck("closeMid.len", win.tabs.length, 2);
            tabTest.ck("closeMid.active", win.activeTab, 1);
            tabTest.ck("closeMid.tab1", win.tabs[1].camId, c.camId);

            win.closeCameraHere();                            // back arrow inside a camera tab
            tabTest.ck("back.len", win.tabs.length, 1);
            tabTest.ck("back.active", win.activeTab, 0);
            tabTest.ck("back.focus", tabTest.camIdOf(win.focusedCamera), a.camId);   // main tab's camera

            win.closeCameraHere();                            // again, in the main tab → the section
            tabTest.ck("back2.focus", tabTest.camIdOf(win.focusedCamera), "null");

            win.openCameraTab(b);
            win.goToSection("events");                        // rail navigates the MAIN tab only
            tabTest.ck("rail.len", win.tabs.length, 2);
            tabTest.ck("rail.active", win.activeTab, 0);
            tabTest.ck("rail.focus", tabTest.camIdOf(win.focusedCamera), "null");
            tabTest.ck("rail.section", win.section, "events");

            win.closeTab(0);                                  // the main tab never closes
            tabTest.ck("mainPinned.len", win.tabs.length, 2);

            console.log("[TABTEST] " + (tabTest.fails === 0 ? "PASS" : "FAIL") + " fails=" + tabTest.fails);
            Qt.quit();
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
    // Dev pilot: WT_DETAIL_IP opens the maximized live detail for that camera once
    // the roster has loaded (mirrors playbackBootHook; inert unless set).
    Timer {
        id: detailBootHook
        interval: 500; repeat: true
        running: typeof wtDetailIp !== "undefined" && wtDetailIp !== ""
        onTriggered: {
            var all = cameraModel.page("", "", "default", 1, 50);
            for (var i = 0; i < all.length; i++)
                if (all[i].ip === wtDetailIp) {
                    detailBootHook.running = false;
                    win.section = "live";
                    win.openCameraHere(all[i]);
                    break;
                }
        }
    }

    // Repeats until the camera roster has loaded (one-shot raced the /streams fetch).
    Timer {
        id: playbackBootHook
        interval: 500; repeat: true
        running: typeof wtPlaybackIp !== "undefined" && wtPlaybackIp !== ""
        onTriggered: {
            // Scan the FULL roster, not a page: page-1-of-50 silently never matched
            // when roster order left the camera beyond row 50, so the hook looped
            // forever and the app stayed on the live wall (caught 2026-08-21: soak
            // cycle 3 ran with 16 wall pipelines decoding under the harness).
            var all = [];
            for (var r = 0; r < cameraModel.total; r++) all.push(cameraModel.get(r));
            for (var i = 0; i < all.length; i++)
                if (all[i] && all[i].ip === wtPlaybackIp) {
                    playbackBootHook.running = false;
                    win.focusedCamera = all[i];
                    win.playbackCamera = all[i];
                    if (typeof wtPlaybackDay !== "undefined" && wtPlaybackDay !== "") {
                        playbackScreen.camera = all[i];                 // set camera, then open just the day
                        // WAIT FOR COVERAGE before opening. openForDay()'s fast-open path is
                        // gated on dayInfo[date].firstMs, which arrives with /review/coverage —
                        // and the real user path cannot click a day until the calendar has
                        // drawn its dots, so coverage is always in hand there. This hook used
                        // to fire the instant the camera appeared in the roster, i.e. BEFORE
                        // coverage, so fast-open could never engage and the hook silently
                        // exercised the pre-2026-08-30 whole-day path instead. Measured
                        // 2026-08-31 on .126/2026-08-30: no [PBTIME] fast_open line, and a
                        // 2,702-fragment 2.06 MB day manifest fetched before first frame.
                        // An A/B of WT_PB_NO_FAST_OPEN through this hook would have compared
                        // the old path against itself.
                        dayBootHook.day = wtPlaybackDay;
                        dayBootHook.restart();
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
    // WT_FSOAK — extended FILMSTRIP soak (2026-07-10, operator ask). Drives the
    // frame-by-frame review flow across cameras and days the way an operator does:
    // open a (camera, day) from the plan, let it play, sometimes click a fragment,
    // enter frame mode, MEASURE how long the filmstrip takes to populate (gate:
    // <1000 ms), exercise arrow-steps both ways, then jump to another day — 25% of
    // jumps are HOT (frame mode kept on across the day switch, the churn gesture
    // that segfaulted pre-4aa4ed7). Plan comes from WT_FSOAK_PLAN JSON:
    //   [{"ip":"192.168.1.201","days":["2026-07-10",...]}, ...]
    // flattened to (ip,day) pairs walked with a coprime stride so consecutive
    // cycles hop camera AND day. [FSOAK] lines carry all metrics; [HB] 500 ms
    // heartbeat exposes GUI stalls as timestamp gaps. Inert unless WT_FSOAK set.
    Timer {
        id: fsoakHb
        interval: 500; repeat: true
        running: (typeof wtFsoak !== "undefined") && wtFsoak
        onTriggered: console.log("[HB] " + Date.now())
    }
    Timer {
        id: fsoak
        readonly property bool on: (typeof wtFsoak !== "undefined") && wtFsoak
        property var pairs: []            // flattened [{ip,day}]
        property var cams: ({})           // ip → camera object
        property int n: 0                 // completed cycles
        property string state: "roster"   // roster|open|play|preseek|fm|strip|steps|linger
        property double t0: 0             // state-entry timestamp
        property double tOpen: 0
        property double tFm: 0
        property int openSeq: 0           // _frameSeq at open — the counter is cumulative
        property bool hot: false          // this cycle ends with a hot day-switch
        property int stepsLeft: 0
        property int violations: 0
        property var curPair: null

        interval: 250; repeat: true
        running: on
        function pair() { return pairs[(n * 13) % pairs.length]; }
        function dur() { return FrameClock.medianFrameDurMs > 1 ? FrameClock.medianFrameDurMs : 50; }
        // Filmstrip "loaded" = center frame cached (±2 ms) and ≥5 of the 7 visible
        // slots chained within the strip's own adjacency limit (2.6×frameDur).
        function stripChained() {
            var c = FrameClock.lastPtsMs;
            if (c < 0) return 0;          // pts 0 is a valid cursor (day start)
            var lim = Math.max(2.6 * dur(), 130);   // VFR floor — mirrors the strip
            var a = FrameCache.cachedAround(c, 3, 3);
            var center = -1;
            for (var i = 0; i < a.length; i++) if (Math.abs(a[i] - c) <= 2) { center = i; break; }
            if (center < 0) return 0;
            var chained = 1;
            for (i = center - 1; i >= 0; i--) { if (a[i + 1] - a[i] > lim) break; chained++; }
            for (i = center + 1; i < a.length; i++) { if (a[i] - a[i - 1] > lim) break; chained++; }
            return chained;
        }
        function go(st) { state = st; t0 = Date.now(); }
        function fail(what, extra) {
            violations++;
            console.log("[FSOAK] VIOLATION n=" + n + " what=" + what + " cam=" + (curPair ? curPair.ip : "?")
                        + " day=" + (curPair ? curPair.day : "?") + " " + (extra || "")
                        + " violations=" + violations);
        }
        function nextCycle(keepFm) {
            n++;
            if (!keepFm && playbackScreen.frameMode) playbackScreen.exitFrameMode();
            go("open");
        }
        onTriggered: {
            var now = Date.now();
            if (state === "roster") {
                if (!pairs.length) {
                    var plan;
                    try { plan = JSON.parse(wtFsoakPlan); } catch (e) { console.log("[FSOAK] BAD PLAN: " + e); running = false; return; }
                    var all = cameraModel.page("", "", "default", 1, 50);
                    if (!all.length) return;                       // roster not ready
                    var flat = [];
                    for (var p = 0; p < plan.length; p++) {
                        var camObj = null;
                        for (var i = 0; i < all.length; i++) if (all[i].ip === plan[p].ip) { camObj = all[i]; break; }
                        if (!camObj) { console.log("[FSOAK] cam not in roster: " + plan[p].ip); continue; }
                        cams[plan[p].ip] = camObj;
                        for (var d = 0; d < plan[p].days.length; d++)
                            flat.push({ ip: plan[p].ip, day: plan[p].days[d] });
                    }
                    if (!flat.length) { console.log("[FSOAK] EMPTY PLAN after roster match"); running = false; return; }
                    pairs = flat;
                    console.log("[FSOAK] START pairs=" + pairs.length + " qt=" + wtQtRuntime
                                + " plan=" + wtFsoakPlan);
                }
                go("open");
                return;
            }
            if (state === "open") {
                curPair = pair();
                hot = (n % 4 === 3);
                var c = cams[curPair.ip];
                win.focusedCamera = c; win.playbackCamera = c;
                console.log("[FSOAK] t=" + now + " n=" + n + " open cam=" + curPair.ip + " day=" + curPair.day
                            + " hot=" + (playbackScreen.frameMode ? "arrived-in-fm" : "no")
                            + " cache=" + FrameCache.frames + "f");
                tOpen = now;
                openSeq = playbackScreen._frameSeq;
                if (playbackScreen.camera !== c) {
                    // Camera change goes through the real operator flow — openFor
                    // resets + refetches coverage. Setting .camera directly left the
                    // PREVIOUS camera's footageDays in place and openForDay's
                    // no-footage short-circuit fired on days that exist (round-1
                    // false "No footage" violations).
                    playbackScreen.openFor(c, 60);
                    go("cover");
                } else {
                    playbackScreen.openForDay(curPair.day);
                    go("play");
                }
                return;
            }
            if (state === "cover") {                               // wait for the new camera's coverage
                if (!playbackScreen.coveragePending) {
                    playbackScreen.openForDay(curPair.day);
                    tOpen = now; openSeq = playbackScreen._frameSeq;
                    go("play");
                } else if (now - t0 > 12000) {
                    fail("coverage_timeout");
                    playbackScreen.openForDay(curPair.day);        // open anyway (pending bypasses the short-circuit)
                    tOpen = now; openSeq = playbackScreen._frameSeq;
                    go("play");
                }
                return;
            }
            if (state === "play") {
                if (playbackScreen.frags.length > 0 && playbackScreen.advancing
                        && playbackScreen._frameSeq > openSeq + 8) { // frames of THIS session rendered (the counter is cumulative)
                    console.log("[FSOAK] t=" + now + " n=" + n + " playing ttff_ms=" + (now - tOpen)
                                + " frags=" + playbackScreen.frags.length);
                    go((n % 3 === 1) ? "preseek" : "fm");
                } else if (playbackScreen.errorText !== "") {
                    fail("open_error", "err=\"" + playbackScreen.errorText + "\"");
                    // A day the app's coverage rejects (e.g. aged past retention
                    // mid-soak) will reject forever — drop the pair from rotation.
                    if (playbackScreen.errorText.indexOf("No footage recorded on this day") >= 0) {
                        for (var pi = pairs.length - 1; pi >= 0; pi--)
                            if (pairs[pi].ip === curPair.ip && pairs[pi].day === curPair.day) pairs.splice(pi, 1);
                        console.log("[FSOAK] pruned " + curPair.ip + "/" + curPair.day + " -> pairs=" + pairs.length);
                        if (!pairs.length) { console.log("[FSOAK] plan exhausted"); running = false; return; }
                    }
                    nextCycle(false);
                } else if (now - t0 > 25000) {
                    fail("open_timeout", "ttff>25s frags=" + playbackScreen.frags.length);
                    nextCycle(false);
                }
                return;
            }
            if (state === "preseek") {                             // operator clicks a fragment first
                if (now - t0 < 1500) return;                       // let playback settle a beat
                var fr = playbackScreen.frags;
                if (fr.length > 3) {
                    var k = (n * 7) % fr.length;
                    // frags rows are OBJECTS ({cs,ce,ws,...}); [2] read undefined and
                    // seekToWall(NaN) nuked the session into a fake "empty manifest"
                    // (rounds 1-3: every fm_refused + "transient" empty was this).
                    console.log("[FSOAK] t=" + now + " n=" + n + " preseek frag#" + k + "/" + fr.length + " ws=" + fr[k].ws);
                    playbackScreen.seekToWall(fr[k].ws + 300);
                }
                go("fm"); t0 = now + 1200;                         // brief settle after the click
                return;
            }
            if (state === "fm") {
                if (now < t0) return;                              // settle wait from preseek
                if (!playbackScreen.frameMode) {
                    playbackScreen.enterFrameMode();
                    if (!playbackScreen.frameMode) {               // guard refused (no frags/stepper)
                        if (now - tOpen > 30000) { fail("fm_refused"); nextCycle(false); }
                        return;
                    }
                }
                tFm = Date.now();
                go("strip");
                return;
            }
            if (state === "strip") {
                var ch = stripChained();
                // At the session head there is nothing behind pts 0 — 4 chained
                // (center + 3 ahead) is ALL SEVEN slots that can exist there.
                var need = (FrameClock.lastPtsMs < 4 * dur()) ? 4 : 5;
                if (ch >= need) {
                    var ms = now - tFm;
                    console.log("[FSOAK] t=" + now + " n=" + n + " strip_ms=" + ms + " chained=" + ch
                                + " cache=" + FrameCache.frames + "f "
                                + (ms <= 1000 ? qsTr("PASS") : qsTr("SLOW")));
                    if (ms > 1000) fail("strip_slow", "strip_ms=" + ms
                        + " c=" + FrameClock.lastPtsMs.toFixed(1) + " dur=" + dur().toFixed(1)
                        + " around=" + JSON.stringify(FrameCache.cachedAround(FrameClock.lastPtsMs, 3, 3)));
                    stepsLeft = 10;
                    go("steps");
                } else if (now - tFm > 6000) {
                    fail("strip_timeout", "chained=" + ch + " after 6s cache=" + FrameCache.frames
                         + "f harvest=" + FrameCache.harvestCapturing
                         + " c=" + FrameClock.lastPtsMs.toFixed(1) + " dur=" + dur().toFixed(1)
                         + " around=" + JSON.stringify(FrameCache.cachedAround(FrameClock.lastPtsMs, 3, 3)));
                    stepsLeft = 6;                                 // exercise anyway — stalls surface in steps
                    go("steps");
                }
                return;
            }
            if (state === "steps") {                               // arrow-step both directions
                if (now - t0 < 400) return;                        // ~2 bursts/s
                if (stepsLeft > 0) {
                    playbackScreen.stepBurst(stepsLeft > 5 ? 1 : -1, 2);
                    stepsLeft--;
                    t0 = now;
                } else {
                    go("linger");
                }
                return;
            }
            if (state === "linger") {                              // let the harvester breathe post-steps
                if (now - t0 < 2000) return;
                console.log("[FSOAK] t=" + now + " n=" + n + " cycle-done cam=" + curPair.ip + " day=" + curPair.day
                            + " hotNext=" + hot + " cache=" + FrameCache.frames + "f/" + FrameCache.bytesMB.toFixed(1) + "MB");
                nextCycle(hot);                                    // hot → frame mode SURVIVES the day jump
                return;
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
        function _cam() {
            // WT_SOAK_FIX_CAM pins the soak to one camera (targeted wedge repro).
            if (typeof wtSoakFixCam !== "undefined" && wtSoakFixCam !== "" && nightSoak.cams.length) {
                for (var i = 0; i < nightSoak.cams.length; i++)
                    if (nightSoak.cams[i].ip === wtSoakFixCam) return nightSoak.cams[i];
            }
            return nightSoak.cams.length ? nightSoak.cams[nightSoak.camIdx % nightSoak.cams.length] : null;
        }
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
            nightSoak.expTag = "cam=" + c.ip + " q=" + (hi ? qsTr("HIGH") : qsTr("STD")) + " durMin=" + durMin + " day=" + nightSoak.curDay + " tag=" + (tag || "rand");
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
                if (typeof wtSoakFixDay !== "undefined" && wtSoakFixDay !== "") {   // targeted wedge repro: pin the day
                    nightSoak.curDay = wtSoakFixDay;
                    nightSoak.dayOff = Math.max(0, Math.round((Date.now() - new Date(wtSoakFixDay + "T12:00:00").getTime()) / 86400000));
                } else {
                    nightSoak.dayOff = (nightSoak.cycle * 5 + 3) % nightSoak.daySpan;   // varied day, incl. >5d old
                    nightSoak.curDay = nightSoak._dayStr(nightSoak.dayOff);
                }
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
                // WT_GRAB_STORM: burst extra preview grabs — they intentionally bleed
                // across the drawer close AND the next cycle's session switch, so the
                // readback overlaps teardown/swap (the suspected wedge race window).
                if (typeof wtGrabStorm !== "undefined" && wtGrabStorm > 0)
                    grabStormT.left = wtGrabStorm;
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
    // WT_GRAB_STORM burst driver: fires playbackScreen.stormGrab() every 250ms while
    // charges remain (armed each drawer step). Deliberately outlives the drawer and
    // overlaps the next open/teardown — the grab/render race the wedge repro amplifies.
    Timer {
        id: grabStormT
        property int left: 0
        interval: 250; repeat: true
        running: left > 0 && (typeof wtNightSoak !== "undefined" && wtNightSoak === true)
        onTriggered: { left--; playbackScreen.stormGrab(); }
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
    // F is context-split: on the playback screen it toggles frame-by-frame mode
    // (handled by PlaybackScreen's own key handling — this app-wide shortcut would
    // otherwise steal the key before the screen ever sees it); everywhere else it
    // stays the fullscreen toggle. F11 = fullscreen always (desktop standard).
    Shortcut { sequence: "F"; enabled: !playbackScreen.visible; onActivated: win.fullscreen = !win.fullscreen }
    Shortcut { sequence: "F11"; onActivated: win.fullscreen = !win.fullscreen }
    // Escape unwinds ONE layer at a time. On Playback the layering is the
    // screen's own (fullscreen → speed ladder → frame mode → selection and
    // mark), so it is delegated: escapeLayer() returns true when it consumed a
    // layer. Written flat here it cleared a marked range while leaving the
    // operator inside the very mode the on-picture chip advertises exiting.
    Shortcut { sequence: "Escape"; onActivated: { if (commandPalette.visible) commandPalette.close(); else if (playbackScreen.visible && playbackScreen.escapeLayer()) { } else if (wallPlayback.visible && wallPlayback.escapeLayer()) { } else if (liveMonitor.visible && (liveMonitor.arrangeMode || liveMonitor.pickerCell >= 0 || liveMonitor.mergeSel !== null)) liveMonitor.escapeArrange(); else if (win.focusedCamera !== null && win.playbackCamera === null) win.closeCameraHere(); else if (win.fullscreen) win.fullscreen = false } }
    Shortcut { sequence: "1"; onActivated: win.setLayout("1") }
    Shortcut { sequence: "2"; onActivated: win.setLayout("4") }
    Shortcut { sequence: "3"; onActivated: win.setLayout("9") }
    Shortcut { sequence: "4"; onActivated: win.setLayout("16") }
    Shortcut { sequence: "Ctrl+K"; onActivated: commandPalette.open() }
    // View tabs. Disabled (not silently inert) when there is nothing to act on, and
    // during playback, where the strip is hidden and a stray Ctrl+Tab would drop the
    // operator out of a review session.
    Shortcut {
        sequence: "Ctrl+W"
        enabled: win.activeTab > 0 && win.playbackCamera === null
        onActivated: win.closeTab(win.activeTab)
    }
    Shortcut {
        sequence: "Ctrl+Tab"
        enabled: win.tabs.length > 1 && win.playbackCamera === null
        onActivated: win.activateTab((win.activeTab + 1) % win.tabs.length)
    }
    Shortcut {
        sequence: "Ctrl+Shift+Tab"
        enabled: win.tabs.length > 1 && win.playbackCamera === null
        onActivated: win.activateTab((win.activeTab + win.tabs.length - 1) % win.tabs.length)
    }

    // Window title bar (frameless window — see `flags` above). Hidden in the app's
    // own fullscreen mode along with the rest of the chrome; F11/Esc still exit.
    TitleBar {
        id: titleBar
        anchors { left: parent.left; right: parent.right; top: parent.top }
        z: 900
        win: win
        visible: !win.fullscreen
        subtitle: AuthController.authenticated ? win.activeTabLabel() : ""
    }

    RowLayout {
        anchors.fill: parent
        anchors.topMargin: titleBar.visible ? titleBar.height : 0
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
                onPreferencesRequested: win.openPreferences()
                onAlertsViewAllRequested: win.goToSection("events")
                onSearchActivated: commandPalette.open()
                // Live right-hand panel toggle — only meaningful on the live wall.
                showSidePanelToggle: win.section === "live" && win.wallMode === "live" && win.focusedCamera === null
                sidePanelOpen: win.opsSidebarOpen
                onToggleSidePanelRequested: win.opsSidebarOpen = !win.opsSidebarOpen
            }

            // View tabs — present only while a camera tab is open, so the default
            // shell keeps every pixel it has today. Hidden during playback, which
            // is a full-focus mode inside whichever tab opened it.
            TabStrip {
                Layout.fillWidth: true
                visible: win.tabs.length > 1 && !win.fullscreen && win.playbackCamera === null
                tabs: win.tabs
                activeIndex: win.activeTab
                cameraModel: cameraModel
                homeLabel: win.homeTabLabel()
                homeIsCamera: win.mainTabCamera !== null
                onActivated: (i) => win.activateTab(i)
                onCloseRequested: (i) => win.closeTab(i)
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                LiveMonitor {
                    id: liveMonitor
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: win.section === "live" && win.focusedCamera === null && win.wallMode === "live" && !win.prefsTabActive
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
                    // "Open" navigates the tab the operator is in; "Open in new tab"
                    // adds a tab that outlives going back to the wall.
                    onCameraOpened: (cam) => win.openCameraHere(cam)
                    onCameraOpenedNewTab: (cam) => win.openCameraTab(cam)
                    onCameraPlaybackRequested: (cam) => {
                        win.openCameraHere(cam);
                        win.playbackCamera = cam;
                        playbackScreen.openFor(cam, 60);
                    }
                    // VIEW ISSUE on a tile: land on Health with that camera's detail
                    // panel open — the issue explanation lives there.
                    onCameraIssueRequested: (cam) => {
                        healthScreen.sel = cam;
                        win.section = "health";
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
                    visible: win.section === "live" && win.focusedCamera === null && win.wallMode === "playback" && !win.prefsTabActive
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
                    visible: win.section === "groups" && win.focusedCamera === null && !win.prefsTabActive
                    cameraModel: cameraModel
                    onNotify: (message) => toastHost.show(qsTr("Groups"), message, "accent", "", "")
                    onOpenInLive: (gid, label) => {
                        win.groupFilter = gid;
                        win.groupLabel = label;
                        win.gridPage = 1;
                        win.section = "live";
                    }
                    onOpenCamera: (cam) => win.openCameraHere(cam)
                }

                SingleCameraDetail {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: win.focusedCamera !== null && win.playbackCamera === null
                    cameraModel: cameraModel
                    camera: win.focusedCamera
                    // Back = leave this camera view: in a camera tab that closes the
                    // tab; in the main tab it drops back to the section underneath.
                    onClosed: win.closeCameraHere()
                    onSwitchCamera: (cam) => win.openCameraHere(cam)
                    onOpenPlayback: (mac) => {
                        win.playbackCamera = win.focusedCamera;
                        playbackScreen.openFor(win.focusedCamera, 60);
                    }
                    // Event row click -> the TRIAGE QUEUE with that event selected
                    // and its camera's lane soloed (operator ask 2026-08-06; was
                    // playback-at-timestamp). goToSection lands the main tab.
                    onOpenEventInTriage: (evId, camId) => {
                        win.goToSection("events");
                        eventsArea.openInTriage(evId, camId);
                    }
                    onSnapshotSaved: (path, camName) => toastHost.show(
                        "Snapshot captured", camName + " · saved to Pictures/Watchtower",
                        "accent", "Open", "file://" + path)
                }

                PlaybackScreen {
                    id: playbackScreen
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    eventsModel: eventModel
                    visible: win.playbackCamera !== null
                    client: playbackClient
                    cameraModel: cameraModel
                    onClosed: win.playbackCamera = null
                    onReturnToLive: { win.mainTabCamera = null; win.activateTab(0) }
                    fullscreenOn: win.fullscreen
                    onFullscreenRequested: win.fullscreen = !win.fullscreen
                    onOpenSettingsRequested: win.openPreferences()
                    onSnapshotSaved: (path, camName) => toastHost.show(
                        "Snapshot captured", camName + " · saved to Pictures/Watchtower",
                        "accent", "Open", "file://" + path)
                }

                PreferencesScreen {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: win.prefsTabActive
                    savedViewModel: savedViewModel
                    cameraModel: cameraModel
                    onClosed: win.section = "live"
                }

                HealthScreen {
                    id: healthScreen
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: win.section === "health" && win.focusedCamera === null && win.playbackCamera === null && !win.prefsTabActive
                    cameraModel: cameraModel
                    storageHealth: storageHealth
                    playbackClient: playbackClient
                    onOpenLive: (cam) => { win.section = "live"; win.openCameraHere(cam) }
                    onOpenPlayback: (cam) => { win.openCameraHere(cam); win.playbackCamera = cam; playbackScreen.openFor(cam, 60) }
                    onOpenEvents: (cam) => win.section = "events"
                }

                // Events-screen redesign (events-v2 port) — now the DEFAULT Events
                // screen, on the live cilex-vision feed (EventsStore.ingestReal).
                // WT_DEMO → the mock showcase; WT_EVENTS_LEGACY → the old EventsScreen.
                EventsArea {
                    id: eventsArea
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: !wtEventsLegacy && win.section === "events" && win.focusedCamera === null && win.playbackCamera === null && !win.prefsTabActive
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
                    onNotify: (m) => toastHost.show(qsTr("Events"), m, "accent", "", "")
                }

                // Legacy table-style Events screen — fallback behind WT_EVENTS_LEGACY.
                EventsScreen {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: wtEventsLegacy && win.section === "events" && win.focusedCamera === null && win.playbackCamera === null && !win.prefsTabActive
                    eventModel: eventModel
                    cameraModel: cameraModel
                    onOpenPlayback: (camId, atMs) => {
                        var cam = cameraModel.cameraByBackendId(camId);
                        if (cam && cam.camId) { win.openCameraHere(cam); win.playbackCamera = cam; playbackScreen.openAt(cam, atMs) }
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
                    visible: win.section === "views" && win.focusedCamera === null && win.playbackCamera === null && !win.prefsTabActive
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
                        win.applyViewSpans(vg.id, view.layout, view.spans);
                        savedViewModel.touch(view.viewId);
                    }
                }

                ClipsScreen {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: win.section === "clips" && win.focusedCamera === null && win.playbackCamera === null && !win.prefsTabActive
                    snapshotModel: snapshotModel
                    cameraModel: cameraModel
                    playbackClient: playbackClient
                }

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: ["live", "groups", "preferences", "health", "events", "views", "clips"].indexOf(win.section) < 0 && !win.prefsTabActive
                    EmptyState {
                        anchors.centerIn: parent
                        icon: "pulse"
                        title: qsTr("Coming soon")
                        subtitle: win.section + " is part of a later phase."
                    }
                }

                OpsSidebar {
                    Layout.fillHeight: true
                    visible: win.section === "live" && !win.fullscreen && win.focusedCamera === null && win.wallMode === "live" && win.opsSidebarOpen && !win.prefsTabActive
                    cameraModel: cameraModel
                    eventModel: eventModel
                    // "View all →" on the LIVE EVENTS panel → open the full Events screen
                    // (same as the alerts dropdown's View-all, line ~473).
                    onViewAllEvents: win.goToSection("events")
                }
            }
        }
    }

    // Login gate — covers the shell until a valid session is held. Stops below the
    // title bar: the window must stay closable/movable while signed out.
    LoginScreen {
        anchors.fill: parent
        anchors.topMargin: titleBar.visible ? titleBar.height : 0
        visible: !AuthController.authenticated
        z: 1000
    }

    // ------------------------------------------------- frameless resize edges
    // A frameless window has no border for the compositor to grab, so the edges
    // are ours: each grip hands a resize back to the compositor via
    // startSystemResize(). They overlay the outermost 4px of the shell (the nav
    // rail's outer margin, a sliver of the ops sidebar's scrollbar) — the usual
    // client-side-decoration trade, and every control stays reachable inboard of
    // it. Absent while maximized/fullscreen, where there is nothing to drag.
    Item {
        id: resizeFrame
        anchors.fill: parent
        z: 1100
        // Kept live in the app's chrome-hidden fullscreen mode too — that mode hides
        // the title bar but the window is still an ordinary resizable window.
        visible: win.visibility !== Window.Maximized && win.visibility !== Window.FullScreen

        readonly property int t: 4      // edge thickness
        readonly property int c: 14     // corner reach

        component Grip: MouseArea {
            property int edges: 0
            hoverEnabled: true
            onPressed: win.startSystemResize(edges)
        }

        Grip {
            edges: Qt.LeftEdge; cursorShape: Qt.SizeHorCursor; width: resizeFrame.t
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom
                      topMargin: resizeFrame.c; bottomMargin: resizeFrame.c }
        }
        Grip {
            edges: Qt.RightEdge; cursorShape: Qt.SizeHorCursor; width: resizeFrame.t
            anchors { right: parent.right; top: parent.top; bottom: parent.bottom
                      topMargin: resizeFrame.c; bottomMargin: resizeFrame.c }
        }
        Grip {
            edges: Qt.TopEdge; cursorShape: Qt.SizeVerCursor; height: resizeFrame.t
            anchors { top: parent.top; left: parent.left; right: parent.right
                      leftMargin: resizeFrame.c; rightMargin: resizeFrame.c }
        }
        Grip {
            edges: Qt.BottomEdge; cursorShape: Qt.SizeVerCursor; height: resizeFrame.t
            anchors { bottom: parent.bottom; left: parent.left; right: parent.right
                      leftMargin: resizeFrame.c; rightMargin: resizeFrame.c }
        }
        Grip {
            edges: Qt.TopEdge | Qt.LeftEdge; cursorShape: Qt.SizeFDiagCursor
            width: resizeFrame.c; height: resizeFrame.c
            anchors { top: parent.top; left: parent.left }
        }
        Grip {
            edges: Qt.TopEdge | Qt.RightEdge; cursorShape: Qt.SizeBDiagCursor
            width: resizeFrame.c; height: resizeFrame.c
            anchors { top: parent.top; right: parent.right }
        }
        Grip {
            edges: Qt.BottomEdge | Qt.LeftEdge; cursorShape: Qt.SizeBDiagCursor
            width: resizeFrame.c; height: resizeFrame.c
            anchors { bottom: parent.bottom; left: parent.left }
        }
        Grip {
            edges: Qt.BottomEdge | Qt.RightEdge; cursorShape: Qt.SizeFDiagCursor
            width: resizeFrame.c; height: resizeFrame.c
            anchors { bottom: parent.bottom; right: parent.right }
        }
    }

    // The design's window outline (box-shadow: 0 0 0 1px #000) — the only edge a
    // frameless window has against the desktop. Pointer-transparent (no handlers),
    // so the grips above keep working through it.
    Rectangle {
        anchors.fill: parent
        z: 1200
        visible: resizeFrame.visible
        color: "transparent"
        border.width: 1
        border.color: "#000000"
    }

    // Clip-export feedback from the playback backend.
    Connections {
        target: playbackClient
        function onExportStarted(jobId) {
            toastHost.show("Export started", "Preparing clip on cilex-vision…", "accent", "", "")
        }
        function onExportSaved(jobId, path) {
            // State the EXACT size. The drawer could only estimate; this is the file.
            // Decimal MB, so it matches both the download strip and the Finder.
            var b = playbackClient.lastExportBytes;
            var sz = b > 0 ? (b >= 1e9 ? (b / 1e9).toFixed(2) + " GB" : (b / 1e6).toFixed(1) + " MB") : "";
            toastHost.show("Clip saved", (sz ? sz + " · " : "") + "Saved to " + Artifacts.exportDir,
                           "good", "Open folder", "file://" + Artifacts.exportDir)
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
    // Export progress. App-wide and anchored to the window bottom on purpose: the
    // operator confirms an export from the playback drawer and then navigates away,
    // so a strip living inside that drawer would vanish exactly when the long wait
    // starts. Collapses to zero height when nothing is exporting.
    ExportProgress {
        id: exportStrip
        client: playbackClient
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        z: 900
    }

    ToastHost {
        id: toastHost
        // ToastHost fills the window and pins its stack bottom-right, so the strip
        // would sit under it. Lift the fill's floor instead of moving the host.
        anchors.bottomMargin: exportStrip.height
        onActionInvoked: (actionId) => { if (actionId === "retryExportHigh") playbackClient.retryLastExportAsHigh() }
    }

    // One-touch autofocus status (2026-08-03 letter §2): the backend's sentence is
    // rendered VERBATIM — success and failure alike — never mapped to local strings.
    Connections {
        target: Ptz
        function _afCamLabel(camId) {
            var all = cameraModel.page("", "", "default", 1, 100000);
            for (var i = 0; i < all.length; i++)
                if (all[i].camId === camId) return all[i].name + " · " + all[i].ip;
            return camId;
        }
        function onFocusAutoStarted(camId) {
            // A real pulse search holds the request 20-40 s (CV reply5) —
            // immediate honest feedback, then the completion toast follows.
            toastHost.show(qsTr("Autofocus started — the lens may hunt for up to 40 seconds"),
                           _afCamLabel(camId), "good", "", "");
        }
        function onOpDone(camId, what, message) {
            if (what !== "focus-auto") return;
            toastHost.show(message !== "" ? message : qsTr("Autofocus finished"),
                           _afCamLabel(camId), "good", "", "");
        }
        function onOpFailed(camId, what, message) {
            if (what !== "focus-auto") return;
            toastHost.show(message, _afCamLabel(camId), "warn", "", "");
        }
    }

    // The Watch: unlock toasts (closed-shift truth only — the backend feeds
    // unlocked_since exclusively from banked accruals) + check-in failures.
    Connections {
        target: Watch
        function onUnlocked(family, tier) {
            toastHost.show(qsTr("New badge earned: %1 — %2").arg(WatchNames.familyName(family)).arg(WatchNames.tierName(tier)),
                           Watch.guardName, "good", "", "");
        }
        function onOpFailed(message) {
            toastHost.show(message, qsTr("The Watch"), "warn", "", "");
        }
    }

    // Save-current-view modal (O03) — opened from Live Monitor or Saved Views.
    SaveViewModal {
        id: saveViewModal
        onSaved: (name, shared) => {
            // Capture the merged cells INTO the view. They used to be left in the
            // global Settings key under (group, layout), which meant two views over
            // the same group and layout shared one set of merges — save a merged
            // view, merge differently, and the first view silently changed under
            // the operator. Reported 2026-09-02: a view saved with merged cells
            // came back as a plain grid.
            savedViewModel.saveCurrent(name, shared, win.gridLayout, win.statusFilter,
                                       win.sortMode, win.groupFilter, win.groupLabel,
                                       Settings.liveSpans(win.groupFilter, win.gridLayout));
            toastHost.show("View saved", name + " · " + (shared ? qsTr("Shared") : qsTr("Mine")), "good", "", "");
        }
    }

    // Command palette (Ctrl+K) — global quick-jump across cameras/groups/views/events.
    CommandPalette {
        id: commandPalette
        cameraModel: cameraModel
        savedViewModel: savedViewModel
        eventModel: eventModel
        snapshotModel: snapshotModel
        // A palette jump navigates the tab the operator is in (cameras) or lands on
        // the main tab (sections) — it never closes the tabs they left open.
        onOpenCamera: (cam) => { win.section = "live"; win.openCameraHere(cam) }
        onOpenClips: win.goToSection("clips")
        onOpenGroup: (gid, label) => { win.groupFilter = gid; win.groupLabel = label; win.gridPage = 1; win.goToSection("live") }
        onOpenView: (view) => {
            var cg = win.resolveGroup(view.groupId, view.groupLabel);
            win.gridLayout = view.layout; win.statusFilter = view.statusFilter; win.sortMode = view.sortMode;
            win.groupFilter = cg.id; win.groupLabel = cg.label; win.gridPage = 1;
            win.goToSection("live");
            win.applyViewSpans(cg.id, view.layout, view.spans);
            savedViewModel.touch(view.viewId);
        }
        onOpenEvents: win.goToSection("events")
    }
}
