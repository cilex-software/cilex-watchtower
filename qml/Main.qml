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
    property int gridLayout: 16          // cameras per page
    property int gridPage: 1
    property string statusFilter: ""
    property string sortMode: "default"
    property string groupFilter: ""
    property string groupLabel: "All cameras"
    property bool fullscreen: false
    property var focusedCamera: null    // shows Single Camera Detail when non-null
    property var playbackCamera: null   // shows Playback (S06) when non-null

    function setLayout(n) { gridLayout = n; gridPage = 1 }
    function setStatusFilter(f) { statusFilter = f; gridPage = 1 }
    function toggleStatusChip(which) { setStatusFilter(statusFilter === which ? "" : which) }
    // Open the Save-current-view modal, capturing the current Live Monitor state.
    function openSaveView() {
        saveViewModal.layoutSize = win.gridLayout;
        saveViewModal.statusFilter = win.statusFilter;
        saveViewModal.groupLabel = win.groupLabel;
        saveViewModal.open();
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
                    win.gridLayout = v.layoutSize; win.statusFilter = v.statusFilter; win.sortMode = v.sortMode;
                    win.groupFilter = v.groupId; win.groupLabel = v.groupLabel; win.gridPage = 1; win.section = "live";
                    break;
                }
        }
    }
    Component.onCompleted: if (typeof wtSection === "undefined" || wtSection === "") applyDefaultLanding()

    CameraModel { id: cameraModel }
    EventModel { id: eventModel }
    SavedViewModel { id: savedViewModel }
    SnapshotModel { id: snapshotModel; dir: Artifacts.snapshotDir }
    PlaybackClient { id: playbackClient }

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
    Timer {
        interval: 500; running: typeof wtPlaybackIp !== "undefined" && wtPlaybackIp !== ""
        onTriggered: {
            var all = cameraModel.page("", "", "default", 1, 50);
            for (var i = 0; i < all.length; i++)
                if (all[i].ip === wtPlaybackIp) {
                    win.focusedCamera = all[i];
                    win.playbackCamera = all[i];
                    playbackScreen.openFor(all[i], 60);
                    break;
                }
        }
    }

    // keyboard shortcuts (design §30)
    Shortcut { sequence: "F"; onActivated: win.fullscreen = !win.fullscreen }
    Shortcut { sequence: "Escape"; onActivated: if (win.fullscreen) win.fullscreen = false }
    Shortcut { sequence: "1"; onActivated: win.setLayout(1) }
    Shortcut { sequence: "2"; onActivated: win.setLayout(4) }
    Shortcut { sequence: "3"; onActivated: win.setLayout(9) }
    Shortcut { sequence: "4"; onActivated: win.setLayout(16) }
    Shortcut { sequence: "Ctrl+K"; onActivated: commandPalette.open() }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        NavRail {
            Layout.fillHeight: true
            visible: !win.fullscreen
            section: win.section
            unackCount: eventModel.unacknowledgedCount
            onSectionSelected: (sid) => win.section = sid
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            TopBar {
                Layout.fillWidth: true
                visible: !win.fullscreen
                cameraModel: cameraModel
                statusFilter: win.statusFilter
                onStatusChipClicked: (which) => win.toggleStatusChip(which)
                onAvatarClicked: win.section = "preferences"
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
                    visible: win.section === "live" && win.focusedCamera === null
                    cameraModel: cameraModel
                    layoutSize: win.gridLayout
                    page: win.gridPage
                    statusFilter: win.statusFilter
                    sortMode: win.sortMode
                    groupId: win.groupFilter
                    groupLabel: win.groupLabel
                    fullscreen: win.fullscreen
                    onLayoutRequested: (size) => win.setLayout(size)
                    onPageRequested: (p) => win.gridPage = Math.max(1, Math.min(p, liveMonitor.pageCount))
                    onStatusFilterRequested: (f) => win.setStatusFilter(f)
                    onSortRequested: (s) => win.sortMode = s
                    onFullscreenToggled: win.fullscreen = !win.fullscreen
                    onSaveViewRequested: win.openSaveView()
                    onSnapshotSaved: (path, camName) => toastHost.show(
                        "Snapshot captured", camName + " · saved to Pictures/Watchtower",
                        "accent", "Open", "file://" + path)
                    onCameraOpened: (cam) => win.focusedCamera = cam
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
                    onOpenPlayback: (camId) => {
                        var cam = cameraModel.cameraByBackendId(camId);
                        if (cam && cam.camId) { win.focusedCamera = cam; win.playbackCamera = cam; playbackScreen.openFor(cam, 60) }
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
                        win.gridLayout = view.layoutSize;
                        win.statusFilter = view.statusFilter;
                        win.sortMode = view.sortMode;
                        win.groupFilter = view.groupId;
                        win.groupLabel = view.groupLabel;
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
                    visible: win.section === "live" && !win.fullscreen && win.focusedCamera === null
                    cameraModel: cameraModel
                    eventModel: eventModel
                }
            }
        }
    }

    // Clip-export feedback from the playback backend.
    Connections {
        target: playbackClient
        function onExportStarted(jobId) {
            toastHost.show("Export started", "Preparing clip on cilex-vision…", "accent", "", "")
        }
        function onExportReady(jobId, url) {
            toastHost.show("Clip ready", "Exported clip is available", "good", "Download", url)
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
            win.gridLayout = view.layoutSize; win.statusFilter = view.statusFilter; win.sortMode = view.sortMode;
            win.groupFilter = view.groupId; win.groupLabel = view.groupLabel; win.gridPage = 1; win.section = "live";
            savedViewModel.touch(view.viewId);
        }
        onOpenEvents: { win.focusedCamera = null; win.playbackCamera = null; win.section = "events" }
    }
}
