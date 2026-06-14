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
    property string statusFilter: ""
    property string sortMode: "ip"
    property string groupFilter: ""
    property string groupLabel: "All cameras"
    property bool fullscreen: false
    property var focusedCamera: null    // shows Single Camera Detail when non-null
    property var playbackCamera: null   // shows Playback (S06) when non-null
    property string wallMode: "live"    // "live" | "playback" (synchronized wall review)

    // Enter synchronized wall playback. Seeds from the operator's persisted wall
    // layout when one exists, else from the cameras currently on the wall page.
    function enterWallPlayback() {
        var per = ({ "1": 1, "4": 4, "9": 9, "16": 16 })[gridLayout] || 16;
        wallPlayback.seedCameras(cameraModel.page(groupFilter, statusFilter, sortMode, gridPage, per));
        wallMode = "playback";
        wallPlayback.openFor(60);
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

    function setLayout(n) { gridLayout = n; gridPage = 1 }
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
    // camera (deferred so the shell finishes its first layout pass, matching the
    // real flow where the user clicks a tile after the grid has settled).
    Timer {
        interval: 400; running: typeof wtFocusIp !== "undefined" && wtFocusIp !== ""
        onTriggered: {
            var all = cameraModel.page("", "", "default", 1, 50);
            for (var i = 0; i < all.length; i++)
                if (all[i].ip === wtFocusIp) { win.focusedCamera = all[i]; break; }
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
                        playbackScreen.openFor(all[i], 60);
                    }
                    break;
                }
        }
    }
    // Dev hook: WT_WALL_DAY boots into synchronized wall playback over the current
    // live page's cameras — a given day (YYYY-MM-DD) or "live" for the last hour.
    Timer {
        interval: 3000; running: typeof wtWallDay !== "undefined" && wtWallDay !== ""
        onTriggered: {
            var per = ({ "1": 1, "4": 4, "9": 9, "16": 16 })[gridLayout] || 16;
            wallPlayback.seedCameras(cameraModel.page(groupFilter, statusFilter, sortMode, gridPage, per));
            wallMode = "playback";
            if (wtWallDay === "live") wallPlayback.openFor(60);
            else wallPlayback.openForDay(wtWallDay);
        }
    }

    // keyboard shortcuts (design §30)
    Shortcut { sequence: "F"; onActivated: win.fullscreen = !win.fullscreen }
    Shortcut { sequence: "Escape"; onActivated: { if (commandPalette.visible) commandPalette.close(); else if (win.fullscreen) win.fullscreen = false } }
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

                EventsScreen {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: win.section === "events" && win.focusedCamera === null && win.playbackCamera === null
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
                    visible: win.section === "live" && !win.fullscreen && win.focusedCamera === null && win.wallMode === "live"
                    cameraModel: cameraModel
                    eventModel: eventModel
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
            toastHost.show("Export failed", err === "" ? "The clip could not be exported" : err, "bad", "", "")
        }
    }

    // Toast stack overlay (snapshot feedback now; alerts later).
    ToastHost { id: toastHost }

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
