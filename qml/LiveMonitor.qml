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
    property string pickerSearch: ""
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
        if (!saved || saved.length === 0) return all;
        var byId = ({});
        for (var i = 0; i < all.length; i++) byId[all[i].camId] = all[i];
        var out = [], used = ({});
        for (var j = 0; j < saved.length; j++) {
            var c = byId[saved[j]];
            if (c && !used[saved[j]]) { out.push(c); used[saved[j]] = true; }
        }
        for (var k = 0; k < all.length; k++)
            if (!used[all[k].camId]) out.push(all[k]);
        return out;
    }
    readonly property bool hasArrangement: { arrangeRev; return cameraModel ? Settings.liveLayout(groupId).length > 0 : false; }
    function _fullIds() { var a = arrangedFull, o = []; for (var i = 0; i < a.length; i++) o.push(a[i].camId); return o; }
    function openCellPicker(tileIndex) { pickerSearch = ""; pickerCell = tileIndex; }
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
        if (pickerCell >= 0) { pickerCell = -1; return; }
        arrangeMode = false;
    }

    // ---- "Recent events" filter: cameras with activity in the last hour --------
    property int recentWindowMs: 3600000
    function refreshRecent() {
        if (cameraModel && eventModel)
            cameraModel.setRecentCameras(eventModel.recentCameraIds(recentWindowMs));
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
    function emptyTitle() { return rosterEmpty() ? "No cameras" : "No matches"; }
    function emptySubtitle() {
        if (rosterEmpty())
            return "No cameras are assigned to your account. Ask an administrator to grant camera access in Cilex Vision.";
        var where = (groupId === "" ? "" : " in " + groupLabel);
        switch (statusFilter) {
        case "recent":    return "No cameras have had an event in the last hour" + where + ".";
        case "online":    return "No cameras are online" + where + " right now.";
        case "offline":   return "No cameras are offline" + where + " — all good.";
        case "degraded":  return "No cameras are degraded" + where + ".";
        case "recording": return "No cameras are recording" + where + ".";
        case "notrec":    return "All cameras are recording" + where + " — none stopped.";
        case "favorites": return "No starred cameras" + where + " yet. Tap a tile's star to pin it here.";
        case "issues":    return "No cameras have issues" + where + " — everything looks healthy.";
        default:          return "No cameras" + where + ".";
        }
    }

    readonly property var pagedCameras: {
        var s = (page - 1) * perPage;
        return arrangedFull.slice(s, s + perPage);
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

                // arrange cells — tap a cell to choose its camera (e.g. the Center tile)
                Rectangle {
                    Layout.preferredHeight: 34
                    implicitWidth: arrTxt.implicitWidth + 28
                    color: root.arrangeMode ? Theme.accent : (arrMa.containsMouse ? Theme.panel : "transparent")
                    border.width: 1
                    border.color: root.arrangeMode ? Theme.accent : (arrMa.containsMouse ? Theme.accent : Theme.line2)
                    Text {
                        id: arrTxt; anchors.centerIn: parent
                        text: root.arrangeMode ? "Done arranging" : "Arrange"
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
                    visible: root.arrangeMode && root.hasArrangement
                    Layout.preferredHeight: 34
                    implicitWidth: resetTxt.implicitWidth + 24
                    color: resetMa.containsMouse ? Theme.panel : "transparent"
                    border.width: 1; border.color: resetMa.containsMouse ? Theme.accent : Theme.line2
                    Text { id: resetTxt; anchors.centerIn: parent; text: "Reset"; color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12 }
                    MouseArea { id: resetMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.resetArrangement() }
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
                        delegate: Item {
                            id: cellWrap
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

                            CameraTile {
                                anchors.fill: parent
                                gridMode: true
                                camName: cellWrap.modelData.name
                                camId: cellWrap.modelData.camId
                                ip: cellWrap.modelData.ip
                                groupId: cellWrap.modelData.groupId
                                groupName: cellWrap.modelData.groupName
                                live: cellWrap.modelData.live
                                recording: cellWrap.modelData.recording
                                favorite: cellWrap.modelData.favorite
                                hasAudio: cellWrap.modelData.hasAudio
                                timestamp: cellWrap.modelData.timestamp
                                lastSeen: cellWrap.modelData.lastSeen
                                lastSegmentAt: cellWrap.modelData.lastSegmentAt
                                pattern: cellWrap.modelData.pattern
                                rtspUrl: cellWrap.modelData.rtspUrl
                                rtspSubUrl: cellWrap.modelData.rtspSubUrl
                                // Only play when Live Monitor is the visible section (so other
                                // screens don't hold open streams / hit cameras), and not while
                                // arranging (the overlay covers it). WT_TEST_IP (dev) further
                                // restricts streaming to a single camera.
                                videoActive: root.visible && !root.arrangeMode
                                    && ((typeof wtTestIp !== "undefined" && wtTestIp !== "")
                                        ? (cellWrap.modelData.ip === wtTestIp) : true)
                                onSnapshotSaved: (p, n) => root.snapshotSaved(p, n)
                                onOpened: root.cameraOpened(cellWrap.modelData)
                                onPlayed: root.cameraPlaybackRequested(cellWrap.modelData)
                                onOpenedNewTab: root.cameraOpened(cellWrap.modelData)
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
                                color: cellOvMa.containsMouse ? Qt.rgba(0, 0, 0, 0.32) : Qt.rgba(0, 0, 0, 0.58)
                                border.width: 2
                                border.color: Theme.accent
                                Column {
                                    anchors.centerIn: parent; spacing: 4; width: parent.width - 16
                                    Text { anchors.horizontalCenter: parent.horizontalCenter
                                        text: (cellWrap.index === 0 && root.lspec.big) ? "CENTER" : ("CELL " + (cellWrap.index + 1))
                                        color: Theme.accent; font.family: Theme.fontMono; font.pixelSize: 11; font.weight: Font.Bold; font.letterSpacing: 1 }
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; width: parent.width
                                        horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
                                        text: cellWrap.modelData.name; color: "#fff"; font.family: Theme.fontSans; font.pixelSize: 13; font.weight: Font.DemiBold }
                                    Text { anchors.horizontalCenter: parent.horizontalCenter
                                        text: "Tap to change"; color: Qt.rgba(1, 1, 1, 0.7); font.family: Theme.fontSans; font.pixelSize: 11 }
                                }
                                MouseArea {
                                    id: cellOvMa
                                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: root.openCellPicker(cellWrap.index)
                                }
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

            // Empty grid: distinguish an empty roster (no camera access — provisioned
            // in Cilex Vision) from a filter/group that simply matched nothing.
            EmptyState {
                anchors.fill: parent
                anchors.margins: 24
                visible: root.total === 0 && !root.fullscreen
                        && !(root.cameraModel && root.cameraModel.loading)
                icon: "monitor"
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

    // Camera picker for arrange mode: tap a cell → choose which camera occupies it.
    Rectangle {
        anchors.fill: parent
        visible: root.pickerCell >= 0
        z: 200
        color: Qt.rgba(0, 0, 0, 0.6)
        MouseArea { anchors.fill: parent; onClicked: root.pickerCell = -1 }   // tap-out closes

        Rectangle {
            anchors.centerIn: parent
            width: 440
            height: Math.min(parent.height - 80, 540)
            color: Theme.panel; border.color: Theme.line2; border.width: 1
            MouseArea { anchors.fill: parent }   // swallow clicks inside the panel

            ColumnLayout {
                anchors.fill: parent; anchors.margins: 16; spacing: 12

                Text {
                    Layout.fillWidth: true
                    text: "Camera for " + ((root.pickerCell === 0 && root.lspec.big) ? "the center cell" : ("cell " + (root.pickerCell + 1)))
                    color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 15; font.weight: Font.DemiBold
                }

                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: 34
                    color: Theme.bg; border.color: Theme.line2; border.width: 1
                    C.TextField {
                        anchors.fill: parent; anchors.margins: 1
                        text: root.pickerSearch
                        onTextChanged: root.pickerSearch = text
                        placeholderText: "Search cameras…"
                        color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13
                        leftPadding: 10; verticalAlignment: TextInput.AlignVCenter
                        background: Rectangle { color: "transparent" }
                    }
                }

                ListView {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    clip: true
                    model: {
                        var q = root.pickerSearch.toLowerCase();
                        var a = root.arrangedFull, out = [];
                        for (var i = 0; i < a.length; i++) {
                            var c = a[i];
                            if (q === "" || ("" + c.name).toLowerCase().indexOf(q) >= 0 || ("" + c.ip).indexOf(q) >= 0)
                                out.push(c);
                        }
                        return out;
                    }
                    delegate: Rectangle {
                        required property var modelData
                        width: ListView.view ? ListView.view.width : 0
                        height: 42
                        color: pickRowMa.containsMouse ? Theme.panel2 : "transparent"
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 10
                            Rectangle { width: 7; height: 7; radius: 4; color: modelData.live ? Theme.good : Theme.ink3 }
                            Text { text: modelData.name; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13; Layout.fillWidth: true; elide: Text.ElideRight }
                            Text { text: modelData.ip; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11 }
                        }
                        MouseArea { id: pickRowMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: root.assignToCell(root.pickerCell, modelData.camId) }
                    }
                }

                Text {
                    Layout.alignment: Qt.AlignRight
                    text: "Cancel"; color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 13
                    MouseArea { anchors.fill: parent; anchors.margins: -10; cursorShape: Qt.PointingHandCursor; onClicked: root.pickerCell = -1 }
                }
            }
        }
    }
}
