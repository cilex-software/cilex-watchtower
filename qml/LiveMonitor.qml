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
    property string layout: "16"         // canonical layout id (see LayoutSpec)
    property int page: 1
    property string statusFilter: ""
    property string sortMode: "default"
    property string groupId: ""
    property string groupLabel: "All cameras"
    property bool fullscreen: false

    signal layoutRequested(string id)
    signal pageRequested(int p)
    signal statusFilterRequested(string f)
    signal sortRequested(string s)
    signal fullscreenToggled()
    signal saveViewRequested()
    signal snapshotSaved(string path, string camName)
    signal cameraOpened(var cam)
    signal cameraPlaybackRequested(var cam)
    signal wallPlaybackRequested()
    signal groupRequested(string groupId, string label)   // quick group switch from the header

    // "All cameras" + every backend group, for the header group switcher. Reads
    // cameraModel.total so it re-evaluates when the roster/groups (re)load.
    readonly property var groupOpts: {
        var out = [{ id: "", name: "All cameras" }];
        if (cameraModel) {
            cameraModel.total;   // refresh dependency
            var gs = cameraModel.groupList();
            for (var i = 0; i < gs.length; i++) out.push({ id: gs[i].id, name: gs[i].name });
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
    readonly property var lcells: LayoutSpec.cellRects(lspec.cols, lspec.rows, lspec.big)
    readonly property int perPage: lcells.length
    // countFiltered()/page() are imperative calls; read cameraModel.total (NOTIFY
    // countsChanged) inside these bindings so they re-evaluate when the model data
    // changes — e.g. the /streams list is (re)fetched after sign-in or refresh.
    readonly property int total: {
        if (!cameraModel) return 0;
        cameraModel.total;   // refresh dependency
        return cameraModel.countFiltered(groupId, statusFilter);
    }
    readonly property int pageCount: Math.max(1, Math.ceil(total / perPage))
    readonly property var pagedCameras: {
        if (!cameraModel) return [];
        cameraModel.total;   // refresh dependency
        return cameraModel.page(groupId, statusFilter, sortMode, page, perPage);
    }
    readonly property string rangeText: {
        if (total === 0)
            return "0 of 0";
        const start = (page - 1) * perPage + 1;
        const end = Math.min(page * perPage, total);
        return start + "–" + end + " of " + total;
    }

    readonly property var sortLabels: ({ "ip": "IP address", "default": "Stream order", "status": "Status first", "alpha": "Alphabetical" })

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
                                { id: "other", lbl: "Other", cols: 3, rows: 3, big: { c: 0, r: 0, cw: 2, ch: 2 }, gap: 1.2, pad: 1.6, sw: 1.25 }
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
                                text: "OTHER LAYOUTS"
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
                                    width: 220; height: 34
                                    color: grpOptMa.containsMouse ? Theme.panel2 : "transparent"
                                    Text {
                                        anchors { left: parent.left; leftMargin: 12; right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                                        text: modelData.name
                                        color: root.groupId === modelData.id ? Theme.accent : Theme.ink
                                        font.family: Theme.fontSans; font.pixelSize: 12; elide: Text.ElideRight
                                    }
                                    MouseArea {
                                        id: grpOptMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: { root.groupRequested(modelData.id, modelData.name); groupPopup.close(); }
                                    }
                                }
                            }
                        }
                    }
                }

                Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 24; color: Theme.line2 }

                // filter pills
                FilterPill {
                    label: "Favorites"
                    leadingStar: true
                    active: root.statusFilter === "favorites"
                    removable: root.statusFilter === "favorites"
                    onClicked: root.statusFilterRequested(root.statusFilter === "favorites" ? "" : "favorites")
                    onRemoved: root.statusFilterRequested("")
                }
                FilterPill {
                    label: "Online"
                    active: root.statusFilter === "online"
                    removable: root.statusFilter === "online"
                    onClicked: root.statusFilterRequested(root.statusFilter === "online" ? "" : "online")
                    onRemoved: root.statusFilterRequested("")
                }
                FilterPill {
                    label: "Recent events"
                    active: root.statusFilter === "recent"
                    onClicked: root.statusFilterRequested(root.statusFilter === "recent" ? "" : "recent")
                }
                FilterPill {
                    label: root.statusFilter === "issues" ? "Issues" : "Filter"
                    leadingPlus: root.statusFilter !== "issues"
                    removable: root.statusFilter === "issues"
                    active: ["offline", "degraded", "recording", "notrec", "favorites", "issues"].indexOf(root.statusFilter) >= 0
                    onClicked: root.statusFilterRequested(root.statusFilter === "issues" ? "" : "issues")
                    onRemoved: root.statusFilterRequested("")
                }

                Item { Layout.fillWidth: true }

                // go back in time (enter synchronized wall playback)
                Rectangle {
                    Layout.preferredHeight: 34
                    implicitWidth: gbtRow.implicitWidth + 24
                    color: gbtMa.containsMouse ? Theme.panel : "transparent"
                    border.width: 1
                    border.color: gbtMa.containsMouse ? Theme.accent : Theme.line2
                    Row {
                        id: gbtRow; anchors.centerIn: parent; spacing: 7
                        Icon { anchors.verticalCenter: parent.verticalCenter; name: "clip"; size: 14; color: Theme.ink2 }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Go back in time"; color: Theme.ink2
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
                    Layout.preferredHeight: 34
                    implicitWidth: saveTxt.implicitWidth + 28
                    color: saveMa.containsMouse ? Theme.panel : "transparent"
                    border.width: 1
                    border.color: saveMa.containsMouse ? Theme.accent : "transparent"
                    Text {
                        id: saveTxt
                        anchors.centerIn: parent
                        text: "Save current view"
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

                // sort dropdown
                Rectangle {
                    id: sortControl
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
                            text: "Sort: " + root.sortLabels[root.sortMode]
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
                    name: "full"
                    iconColor: Theme.ink2
                    borderColor: Theme.line2
                    bgColor: Theme.panel
                    hoverIcon: Theme.accent
                    hoverBorder: Theme.accent
                    tip: "Full-screen monitoring (F)"
                    implicitWidth: 38
                    implicitHeight: 38
                    onClicked: root.fullscreenToggled()
                }
            }
        }

        // ---------------------------------------------------------- grid
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: root.fullscreen ? 4 : 20
                anchors.rightMargin: root.fullscreen ? 4 : 20
                anchors.topMargin: root.fullscreen ? 4 : 14
                anchors.bottomMargin: root.fullscreen ? 4 : 14
                color: Theme.line2
                visible: root.total > 0

                GridLayout {
                    anchors.fill: parent
                    anchors.margins: 1
                    columns: root.cols
                    rows: root.rows
                    rowSpacing: 1
                    columnSpacing: 1

                    Repeater {
                        id: gridRepeater
                        model: root.pagedCameras
                        delegate: CameraTile {
                            required property var modelData
                            required property int index
                            // Place each tile in its net cell (big tile spans).
                            readonly property var cell: index < root.lcells.length
                                ? root.lcells[index] : ({ c: 0, r: 0, cw: 1, ch: 1 })
                            Layout.row: cell.r
                            Layout.column: cell.c
                            Layout.rowSpan: cell.ch
                            Layout.columnSpan: cell.cw
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            gridMode: true
                            camName: modelData.name
                            camId: modelData.camId
                            ip: modelData.ip
                            groupId: modelData.groupId
                            groupName: modelData.groupName
                            live: modelData.live
                            recording: modelData.recording
                            favorite: modelData.favorite
                            hasAudio: modelData.hasAudio
                            timestamp: modelData.timestamp
                            lastSeen: modelData.lastSeen
                            lastSegmentAt: modelData.lastSegmentAt
                            pattern: modelData.pattern
                            rtspUrl: modelData.rtspUrl
                            rtspSubUrl: modelData.rtspSubUrl
                            // Only play when Live Monitor is the visible section (so other
                            // screens don't hold open streams / hit cameras). WT_TEST_IP
                            // (dev) further restricts streaming to a single camera.
                            videoActive: root.visible
                                && ((typeof wtTestIp !== "undefined" && wtTestIp !== "")
                                    ? (modelData.ip === wtTestIp) : true)
                            onSnapshotSaved: (p, n) => root.snapshotSaved(p, n)
                            onOpened: root.cameraOpened(modelData)
                            onPlayed: root.cameraPlaybackRequested(modelData)
                            onOpenedNewTab: root.cameraOpened(modelData)
                            // Favorite is persisted in CameraModel (keyed by camera_id);
                            // flip the tile optimistically so it reflects instantly (the
                            // paged snapshot won't re-fetch until the next page() call).
                            onFavoriteToggled: {
                                favorite = !favorite;
                                if (root.cameraModel) root.cameraModel.toggleFavoriteById(modelData.camId);
                            }
                        }
                    }
                }
            }

            // Brief gap between sign-in and the first /streams response.
            LoadingState {
                anchors.centerIn: parent
                visible: root.total === 0 && !root.fullscreen
                        && root.cameraModel && root.cameraModel.loading
                label: "Loading cameras…"
            }

            // Backend returned no cameras for this operator — their /streams scope is
            // empty. Cameras are provisioned and assigned in Cilex Vision.
            EmptyState {
                anchors.fill: parent
                anchors.margins: 24
                visible: root.total === 0 && !root.fullscreen
                        && !(root.cameraModel && root.cameraModel.loading)
                icon: "monitor"
                title: "No cameras"
                subtitle: "No cameras are assigned to your account. Ask an administrator "
                          + "to grant camera access in Cilex Vision."
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
                        text: "Exit full-screen"
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
                    text: root.groupLabel + " · " + root.total + " cameras · Page " + root.page + " of " + root.pageCount
                    color: Theme.ink3
                    font.family: Theme.fontMono
                    font.pixelSize: Theme.fsMono
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
}
