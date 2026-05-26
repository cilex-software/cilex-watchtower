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

    function setLayout(n) { gridLayout = n; gridPage = 1 }
    function setStatusFilter(f) { statusFilter = f; gridPage = 1 }
    function toggleStatusChip(which) { setStatusFilter(statusFilter === which ? "" : which) }

    CameraModel { id: cameraModel }
    EventModel { id: eventModel }

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

    // keyboard shortcuts (design §30)
    Shortcut { sequence: "F"; onActivated: win.fullscreen = !win.fullscreen }
    Shortcut { sequence: "Escape"; onActivated: if (win.fullscreen) win.fullscreen = false }
    Shortcut { sequence: "1"; onActivated: win.setLayout(1) }
    Shortcut { sequence: "2"; onActivated: win.setLayout(4) }
    Shortcut { sequence: "3"; onActivated: win.setLayout(9) }
    Shortcut { sequence: "4"; onActivated: win.setLayout(16) }

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
                    onSaveViewRequested: { /* Save Current View modal (O03) — later phase */ }
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
                    visible: win.focusedCamera !== null
                    cameraModel: cameraModel
                    camera: win.focusedCamera
                    onClosed: win.focusedCamera = null
                    onSwitchCamera: (cam) => win.focusedCamera = cam
                    onOpenPlayback: (mac) => { /* Playback (S06) — task 14 */ }
                    onSnapshotSaved: (path, camName) => toastHost.show(
                        "Snapshot captured", camName + " · saved to Pictures/Watchtower",
                        "accent", "Open", "file://" + path)
                }

                PreferencesScreen {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: win.section === "preferences"
                    onClosed: win.section = "live"
                }

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    visible: ["live", "groups", "preferences"].indexOf(win.section) < 0
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

    // Toast stack overlay (snapshot feedback now; alerts later).
    ToastHost { id: toastHost }
}
