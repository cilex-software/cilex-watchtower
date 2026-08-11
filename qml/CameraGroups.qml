import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C
import Watchtower
import "GroupsStatus.js" as St

// Camera Groups — "Wall" (designs/handoff-groups/2026-08-07-groups-redesign-spec.md).
// A gapless mosaic: 16:9 tiles butting edge to edge, every piece of chrome painted
// ON the frame as an overlay — with no gutters a footer WOULD be the gap. Left pane
// 264px carries group health plus an attention console; the 58px header is now 34
// and the permanent hint strip is a load-bearing filter bar.
//
// Rows, not a GridView: a GridView positions delegates on a fixed cellWidth grid,
// so paneWidth % cols becomes a lighter strip down the right edge — the one seam a
// gapless wall cannot have. A ListView of RowLayouts lets the layout engine
// distribute the remainder (spec §2.4).
Item {
    id: root
    property var cameraModel: null

    property string selectedGroup: ""             // "" = all, "__ungrouped__" = no group
    property string selectedGroupName: qsTr("All cameras")
    property int rev: 0
    readonly property bool canEdit: AuthController.role === "admin" || AuthController.role === "operator"

    property int perRow: 6                        // PREFERENCE: 6 dense default / 4 identify gear
    property string gq: ""
    property string cq: ""
    property string facet: "all"                  // all | unnamed | faults

    signal openInLive(string groupId, string label)
    signal openCamera(var cam)

    Connections {
        target: root.cameraModel
        function onCountsChanged() { root.rev++ }
        function onGroupsChanged() { root.rev++ }
        function onGroupCreated(groupId) { root.selectedGroup = groupId; root.rev++ }
    }

    readonly property var groupsData: (root.rev, root.cameraModel ? root.cameraModel.groupList() : [])
    readonly property int allCount: (root.rev, root.cameraModel ? root.cameraModel.total : 0)

    // fleet, rebuilt only when a rendered field changes (a routine poll must not
    // destroy every delegate — measured 2026-08-02). Segment/VMD at HOUR precision:
    // badge states settle within the hour without churning the wall.
    property var fleet: []
    property string _sig: " "
    function _rebuild() {
        var next = root.cameraModel ? root.cameraModel.page("", "", "alpha", 1, 100000) : [];
        var sig = "";
        for (var i = 0; i < next.length; i++) {
            var c = next[i];
            sig += c.camId + "|" + c.name + "|" + (c.groupId || "") + "|" + c.live + "|" + c.recording
                 + "|" + (c.motionKnown === true) + "|" + (c.motionReady === true)
                 + "|" + String(c.lastSegmentAt || "").slice(0, 13)
                 + "|" + String(c.motionLastVmdAt || "").slice(0, 13) + "\n";
        }
        if (sig !== root._sig) { root._sig = sig; root.fleet = next }
    }
    onRevChanged: _rebuild()
    onCameraModelChanged: _rebuild()
    Component.onCompleted: _rebuild()

    // scope → facet → search
    readonly property var scoped: {
        var out = [];
        for (var i = 0; i < fleet.length; i++) {
            var c = fleet[i];
            if (selectedGroup === "") out.push(c);
            else if (selectedGroup === "__ungrouped__") { if (!c.groupId) out.push(c) }
            else if (c.groupId === selectedGroup) out.push(c);
        }
        return out;
    }
    function _facetPass(c) {
        if (facet === "unnamed") return St.unnamed(c);
        if (facet === "faults") return St.FAULT(c);
        return true;
    }
    readonly property var shown: {
        var out = [];
        for (var i = 0; i < scoped.length; i++)
            if (_facetPass(scoped[i]) && St.matches(scoped[i], cq)) out.push(scoped[i]);
        return out;
    }
    readonly property var rows: {
        var out = [], r = [];
        for (var i = 0; i < shown.length; i++) {
            r.push(shown[i]);
            if (r.length === perRow) { out.push(r); r = [] }
        }
        if (r.length) out.push(r);
        return out;
    }
    function _count(list, fn) { var n = 0; for (var i = 0; i < list.length; i++) if (fn(list[i])) n++; return n }
    readonly property int nAll: scoped.length
    readonly property int nUnnamed: _count(scoped, St.unnamed)
    readonly property int nFaults: _count(scoped, St.FAULT)
    readonly property int nNotRec: _count(scoped, St.REC_BROKEN)
    readonly property int nUngrouped: _count(fleet, function (c) { return !c.groupId })

    // selection — the range anchor is an interaction pointer, never render state
    property var sel: ({})
    property string anchorId: ""
    readonly property int selCount: { var n = 0; for (var k in sel) if (sel[k]) n++; return n }
    function clearSel() { sel = ({}); anchorId = "" }
    function toggleSel(id) { var s = Object.assign({}, sel); s[id] = !s[id]; sel = s; anchorId = id }
    function onlySel(id) { var s = ({}); s[id] = true; sel = s; anchorId = id }
    function rangeSel(id) {
        var a = -1, b = -1;
        for (var i = 0; i < shown.length; i++) {
            if (shown[i].camId === anchorId) a = i;
            if (shown[i].camId === id) b = i;
        }
        if (a < 0) { onlySel(id); return }
        var s = Object.assign({}, sel);
        for (var j = Math.min(a, b); j <= Math.max(a, b); j++) s[shown[j].camId] = true;
        sel = s;                                            // anchor deliberately survives
    }
    function selectAllShown() { var s = ({}); for (var i = 0; i < shown.length; i++) s[shown[i].camId] = true; sel = s }
    function fileSelection(gid) {
        for (var k in sel) if (sel[k]) root.cameraModel.setCameraGroup(k, gid);
        root.rev++;
    }
    function groupCams(gid) {
        var out = [];
        for (var i = 0; i < fleet.length; i++) {
            var c = fleet[i];
            if (gid === "__ungrouped__" ? !c.groupId : c.groupId === gid) out.push(c);
        }
        return out;
    }

    // the open camera must not outlive its filter
    property string openId: ""
    readonly property int openIdx: {
        for (var i = 0; i < shown.length; i++) if (shown[i].camId === openId) return i;
        return -1;
    }
    readonly property var openCam: openIdx >= 0 ? shown[openIdx] : null
    onShownChanged: if (openId !== "" && openIdx < 0) openId = ""
    function stepOpen(d) {
        var j = openIdx + d;
        if (openIdx >= 0 && j >= 0 && j < shown.length) openId = shown[j].camId;   // never wraps
    }

    Keys.onPressed: (e) => {
        if (e.key === Qt.Key_Escape) { if (openId !== "") openId = ""; else clearSel(); e.accepted = true }
        else if (e.key === Qt.Key_A && (e.modifiers & Qt.ControlModifier)) { selectAllShown(); e.accepted = true }
        else if (openId !== "" && (e.key === Qt.Key_Left || e.key === Qt.Key_Right)) {
            stepOpen(e.key === Qt.Key_Right ? 1 : -1); e.accepted = true;
        }
    }
    onVisibleChanged: if (visible) forceActiveFocus()

    Rectangle { anchors.fill: parent; color: Theme.bg }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ============================================== LEFT PANE — 264px
        Rectangle {
            Layout.preferredWidth: Settings.groupsPaneW
            Layout.fillHeight: true
            color: Theme.bg
            Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.line; z: 2 }
            // resize handle: the hairline is 1px, the grab zone is 6 (operator ask
            // 2026-08-09). Width persists; double-click restores the spec's 264.
            Rectangle {
                id: paneGrip
                anchors.right: parent.right; anchors.rightMargin: -2
                width: 6; height: parent.height
                z: 3
                color: (gripMa.containsMouse || gripMa.pressed) ? Theme.accentSoft : "transparent"
                Rectangle {
                    visible: gripMa.containsMouse || gripMa.pressed
                    anchors.right: parent.right; anchors.rightMargin: 2
                    width: 1; height: parent.height; color: Theme.accent
                }
                MouseArea {
                    id: gripMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.SizeHorCursor
                    property real startX: 0
                    property int startW: 264
                    onPressed: (m) => { startX = mapToItem(root, m.x, 0).x; startW = Settings.groupsPaneW }
                    onPositionChanged: (m) => {
                        if (!pressed) return;
                        Settings.groupsPaneW = startW + Math.round(mapToItem(root, m.x, 0).x - startX);
                    }
                    onDoubleClicked: Settings.groupsPaneW = 264
                }
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.rightMargin: 1
                spacing: 0

                // a · group search (every role — reading is not a privilege)
                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: 30; color: Theme.panel
                    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
                    Text { id: gqIcon; anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                        text: "⌕"; color: Theme.ink3; font.pixelSize: 12 }
                    C.TextField {
                        id: gqField
                        anchors { left: gqIcon.right; leftMargin: 7; right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                        padding: 0; color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 11
                        background: null
                        onTextChanged: root.gq = text
                    }
                    Text { visible: gqField.text === ""
                        anchors { left: gqIcon.right; leftMargin: 7; verticalCenter: parent.verticalCenter }
                        text: qsTr("Find a group…"); color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11 }
                }

                // b · rows
                component GRow: Rectangle {
                    id: gr
                    property string gid: ""
                    property string gname: ""
                    property int gcount: 0
                    property string ic: "layers"
                    property bool dropOn: false
                    readonly property bool isSel: root.selectedGroup === gid
                    readonly property var hs: {
                        var cams = gid === "" ? root.fleet : root.groupCams(gid), b = 0, w = 0, o = 0;
                        for (var i = 0; i < cams.length; i++) {
                            if (St.FAULT(cams[i])) b++; else if (St.warn(cams[i])) w++; else o++;
                        }
                        return { b: b, w: w, o: o, t: Math.max(1, cams.length) };
                    }
                    Layout.fillWidth: true
                    Layout.preferredHeight: 34
                    implicitHeight: 34
                    color: dropOn ? Theme.accentSoft : (isSel ? Theme.accentSoft : (grMa.containsMouse ? Theme.panel2 : "transparent"))
                    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
                    Rectangle { visible: gr.isSel; anchors.left: parent.left; width: 3; height: parent.height; color: Theme.accent }
                    Rectangle { visible: gr.dropOn; anchors.fill: parent; color: "transparent"; border.width: 1; border.color: Theme.accent }
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 10; spacing: 7
                        Icon { name: gr.ic; size: 12; color: gr.isSel ? Theme.accent : Theme.ink3 }
                        Text {
                            Layout.fillWidth: true; elide: Text.ElideRight; text: gr.gname
                            color: gr.isSel ? Theme.accent : Theme.ink2
                            font.family: Theme.fontSans; font.pixelSize: 12
                            font.weight: gr.isSel ? Font.DemiBold : Font.Normal
                        }
                        Text {
                            visible: gr.gcount === 0 && gr.gid !== "" && gr.gid !== "__ungrouped__"
                            text: qsTr("EMPTY"); color: Theme.ink3
                            font.family: Theme.fontMono; font.pixelSize: 8; font.letterSpacing: 1.0
                        }
                        Row {                                   // c · 34×3 health bar
                            visible: gr.gid !== "__ungrouped__"
                            Layout.preferredWidth: 34; Layout.preferredHeight: 3; Layout.alignment: Qt.AlignVCenter
                            spacing: 0
                            Rectangle { width: gr.hs.b === 0 ? 0 : Math.max(2, Math.round(34 * gr.hs.b / gr.hs.t)); height: 3; color: Theme.bad }
                            Rectangle { width: gr.hs.w === 0 ? 0 : Math.max(2, Math.round(34 * gr.hs.w / gr.hs.t)); height: 3; color: Theme.accent }
                            Rectangle { width: gr.hs.o === 0 ? 0 : Math.max(2, Math.round(34 * gr.hs.o / gr.hs.t)); height: 3; color: Theme.good }
                        }
                        Text {
                            text: gr.gcount; color: gr.isSel ? Theme.accent : Theme.ink3
                            font.family: Theme.fontMono; font.pixelSize: 10
                            font.weight: gr.isSel ? Font.DemiBold : Font.Normal
                        }
                    }
                    MouseArea {
                        id: grMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { root.selectedGroup = gr.gid; root.selectedGroupName = gr.gname; root.openId = "" }
                    }
                    DropArea {
                        anchors.fill: parent
                        enabled: root.canEdit && gr.gid !== ""
                        onEntered: gr.dropOn = true
                        onExited: gr.dropOn = false
                        onDropped: { gr.dropOn = false; root.fileSelection(gr.gid === "__ungrouped__" ? "" : gr.gid); root.clearSel() }
                    }
                }

                GRow { gid: ""; gname: qsTr("All cameras"); gcount: root.allCount; ic: "monitor" }
                GRow {
                    visible: root.nUngrouped > 0
                    gid: "__ungrouped__"; gname: qsTr("Ungrouped"); gcount: root.nUngrouped
                }
                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: 22; color: Theme.bg
                    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 10
                        Text { Layout.fillWidth: true; text: qsTr("CAMERA GROUPS"); color: Theme.ink3
                            font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 1.4 }
                        Text { text: root.groupsData.length; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9 }
                    }
                }
                ListView {
                    id: groupList
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(contentHeight, 34 * 7)
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    model: {
                        var out = [], q = root.gq.toLowerCase();
                        for (var i = 0; i < root.groupsData.length; i++) {
                            var g = root.groupsData[i];
                            if (q === "" || String(g.name).toLowerCase().indexOf(q) >= 0) out.push(g);
                        }
                        return out;
                    }
                    delegate: GRow {
                        required property var modelData
                        width: groupList.width
                        gid: modelData.id; gname: modelData.name; gcount: modelData.total
                    }
                }

                // d · + New group — creates nothing until a name is committed
                Rectangle {
                    id: newGroupRow
                    visible: root.canEdit
                    property bool arming: false
                    Layout.fillWidth: true; Layout.preferredHeight: 34; color: Theme.panel
                    Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Theme.line2 }
                    RowLayout {
                        visible: !newGroupRow.arming
                        anchors.fill: parent; anchors.leftMargin: 12; spacing: 8
                        Text { text: "+"; color: Theme.accent; font.pixelSize: 14 }
                        Text { Layout.fillWidth: true; text: qsTr("New group"); color: Theme.ink2
                            font.family: Theme.fontSans; font.pixelSize: 12 }
                    }
                    MouseArea {
                        visible: !newGroupRow.arming; anchors.fill: parent; hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { newGroupRow.arming = true; ngField.text = ""; ngField.forceActiveFocus() }
                    }
                    RowLayout {
                        visible: newGroupRow.arming
                        anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 8; spacing: 8
                        C.TextField {
                            id: ngField
                            Layout.fillWidth: true; padding: 0
                            color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12
                            background: null
                            onAccepted: {
                                if (text.trim() !== "") root.cameraModel.createGroup(text.trim());
                                newGroupRow.arming = false;
                            }
                            Keys.onEscapePressed: newGroupRow.arming = false
                        }
                        Text { text: "↵"; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11 }
                        Text {
                            text: "✕"; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11
                            MouseArea { anchors.fill: parent; anchors.margins: -6; cursorShape: Qt.PointingHandCursor
                                onClicked: newGroupRow.arming = false }
                        }
                    }
                    Text {
                        visible: newGroupRow.arming && ngField.text === ""
                        anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                        text: qsTr("Group name…"); color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12
                    }
                }

                // ---- attention console (§2.1b B) ----
                Rectangle {
                    id: cons
                    Layout.fillWidth: true; Layout.fillHeight: true; color: Theme.panel
                    Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Theme.line2 }

                    readonly property int cNotRec: root._count(root.fleet, St.REC_BROKEN)
                    readonly property int cUnnamed: root._count(root.fleet, St.unnamed)
                    readonly property int cOffline: root._count(root.fleet, St.offline)
                    readonly property int cUnknown: root._count(root.fleet, St.unknown)
                    readonly property int cFault: root._count(root.fleet, St.FAULT)
                    readonly property int cWarn: root._count(root.fleet, St.warn)
                    readonly property int cOk: root._count(root.fleet, St.ok)

                    ColumnLayout {
                        anchors.fill: parent; anchors.topMargin: 1; spacing: 0

                        Text {
                            Layout.fillWidth: true; Layout.topMargin: 10; Layout.leftMargin: 12; Layout.bottomMargin: 4
                            text: qsTr("NEEDS ATTENTION"); color: Theme.ink3
                            font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 1.4
                        }
                        component ARow: Rectangle {
                            id: ar
                            property int n: 0
                            property string label: ""
                            property color dot: Theme.bad
                            property string goFacet: ""
                            Layout.fillWidth: true; Layout.preferredHeight: 30
                            color: (ar.n > 0 && arMa.containsMouse && ar.goFacet !== "") ? Theme.panel2 : "transparent"
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 10; spacing: 8
                                Rectangle { Layout.preferredWidth: 6; Layout.preferredHeight: 6; Layout.alignment: Qt.AlignVCenter
                                    color: ar.n > 0 ? ar.dot : Theme.ink3 }
                                Text { text: ar.n; color: ar.n > 0 ? Theme.ink : Theme.ink3
                                    font.family: Theme.fontMono; font.pixelSize: 13; font.weight: Font.DemiBold }
                                Text { Layout.fillWidth: true; elide: Text.ElideRight; text: ar.label
                                    color: ar.n > 0 ? Theme.ink2 : Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11 }
                                Text { visible: ar.n > 0 && ar.goFacet !== ""; text: "→"; color: Theme.ink3
                                    font.family: Theme.fontMono; font.pixelSize: 11 }
                            }
                            MouseArea {
                                id: arMa; anchors.fill: parent; hoverEnabled: true
                                enabled: ar.n > 0 && ar.goFacet !== ""
                                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onClicked: { root.selectedGroup = ""; root.selectedGroupName = qsTr("All cameras"); root.facet = ar.goFacet }
                            }
                        }
                        ARow { n: cons.cNotRec;    label: qsTr("not recording");           dot: Theme.bad;    goFacet: "faults" }
                        ARow { n: cons.cUnnamed;   label: qsTr("still unnamed");           dot: Theme.accent; goFacet: "unnamed" }
                        ARow { n: root.nUngrouped; label: qsTr("ungrouped");               dot: Theme.accent }
                        ARow { n: cons.cOffline;   label: qsTr("offline");                 dot: Theme.bad }
                        ARow { n: cons.cUnknown;   label: qsTr("recording state unknown"); dot: Theme.accent }

                        Item { Layout.fillWidth: true; Layout.preferredHeight: 8 }
                        Item {
                            id: fleetBar
                            Layout.fillWidth: true; Layout.leftMargin: 12; Layout.rightMargin: 12; Layout.preferredHeight: 6
                            readonly property int t: Math.max(1, root.fleet.length)
                            Rectangle { anchors.fill: parent; color: Theme.panel3 }
                            Row {
                                anchors.fill: parent; spacing: 0
                                Rectangle { width: fleetBar.width * cons.cFault / fleetBar.t; height: 6; color: Theme.bad }
                                Rectangle { width: fleetBar.width * cons.cWarn / fleetBar.t; height: 6; color: Theme.accent }
                                Rectangle { width: fleetBar.width * cons.cOk / fleetBar.t; height: 6; color: Theme.good }
                            }
                        }
                        Text {
                            Layout.fillWidth: true; Layout.leftMargin: 12; Layout.rightMargin: 10
                            Layout.topMargin: 5; Layout.bottomMargin: 8
                            elide: Text.ElideRight
                            text: cons.cFault + " FAULT · " + cons.cWarn + " WARN · " + cons.cOk + " OK · "
                                  + Math.round(100 * cons.cOk / Math.max(1, root.fleet.length)) + "% " + qsTr("HEALTHY")
                            color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 0.5
                        }

                        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.line }
                        Text {
                            Layout.fillWidth: true; Layout.topMargin: 8; Layout.leftMargin: 12; Layout.bottomMargin: 4
                            text: qsTr("WORK QUEUE"); color: Theme.ink3
                            font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 1.4
                        }
                        // the growable child: flexing a container whose children are all
                        // fixed does not remove a void, it relocates it (§2.1b B)
                        ListView {
                            id: workQueue
                            Layout.fillWidth: true; Layout.fillHeight: true
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            model: {
                                var out = [];
                                for (var i = 0; i < root.fleet.length; i++) {
                                    var c = root.fleet[i], r = "", rk = 9;
                                    if (St.REC_BROKEN(c)) { r = qsTr("not recording"); rk = 0 }
                                    else if (St.DET_BROKEN(c)) { r = qsTr("detector not ready"); rk = 1 }
                                    else if (St.offline(c)) { r = qsTr("offline"); rk = 2 }
                                    else if (St.unknown(c)) { r = qsTr("state unknown"); rk = 3 }
                                    else if (St.unnamed(c)) { r = qsTr("unnamed"); rk = 4 }
                                    if (r !== "") out.push({ cam: c, reason: r, rank: rk });
                                }
                                out.sort(function (a, b) { return a.rank - b.rank });
                                return out;
                            }
                            delegate: Rectangle {
                                id: wq
                                required property var modelData
                                width: workQueue.width; height: 26
                                color: wqMa.containsMouse ? Theme.panel2 : "transparent"
                                RowLayout {
                                    anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 10; spacing: 7
                                    Rectangle { Layout.preferredWidth: 5; Layout.preferredHeight: 5; radius: 2.5
                                        Layout.alignment: Qt.AlignVCenter
                                        color: wq.modelData.rank <= 1 ? Theme.bad : Theme.accent }
                                    Text { text: St.octet(wq.modelData.cam); color: Theme.ink
                                        font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.DemiBold }
                                    Text { Layout.fillWidth: true; elide: Text.ElideRight
                                        text: St.unnamed(wq.modelData.cam) ? St.modelOf(wq.modelData.cam) : wq.modelData.cam.name
                                        color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 10 }
                                    Text { text: wq.modelData.reason; color: Theme.ink3
                                        font.family: Theme.fontMono; font.pixelSize: 9 }
                                }
                                MouseArea { id: wqMa; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.openId = wq.modelData.cam.camId }
                            }
                            Text {
                                anchors.centerIn: parent; width: parent.width - 28
                                visible: workQueue.count === 0
                                text: qsTr("Nothing needs attention. Every camera is named, grouped and recording.")
                                color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11
                                wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter
                            }
                        }
                    }
                }
            }
        }

        // ============================================== RIGHT — the wall
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // header 34px
            Rectangle {
                id: hdr
                property bool armed: false
                Layout.fillWidth: true; Layout.preferredHeight: 34; color: Theme.bg
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 14; spacing: 10
                    Text {
                        visible: !renameF.visible
                        text: root.selectedGroup === "" ? qsTr("All cameras")
                            : root.selectedGroup === "__ungrouped__" ? qsTr("Ungrouped") : root.selectedGroupName
                        color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 14; font.weight: Font.DemiBold
                        MouseArea {
                            anchors.fill: parent
                            enabled: root.canEdit && root.selectedGroup !== "" && root.selectedGroup !== "__ungrouped__"
                            // double-click, never single: an unrevertable server write
                            onDoubleClicked: { renameF.text = root.selectedGroupName; renameF.visible = true
                                               renameF.forceActiveFocus(); renameF.selectAll() }
                        }
                    }
                    C.TextField {
                        id: renameF
                        visible: false
                        Layout.preferredWidth: 220; padding: 2
                        color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 14; font.weight: Font.DemiBold
                        background: Rectangle { color: Theme.panel; border.width: 1; border.color: Theme.accent }
                        onAccepted: {
                            if (text.trim() !== "") {           // empty is refused, old name stands
                                root.cameraModel.renameGroup(root.selectedGroup, text.trim());
                                root.selectedGroupName = text.trim();
                            }
                            visible = false;
                        }
                        Keys.onEscapePressed: visible = false
                    }
                    Text { text: root.scoped.length; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                    Item { Layout.fillWidth: true }

                    component HCell: Rectangle {
                        id: hc
                        property string label: ""
                        property bool danger: false
                        signal tapped()
                        Layout.fillHeight: true
                        Layout.preferredWidth: hcT.implicitWidth + 24
                        color: hcMa.containsMouse ? (hc.danger ? Theme.badSoft : Theme.panel2) : "transparent"
                        Rectangle { anchors.left: parent.left; width: 1; height: parent.height; color: Theme.line }
                        Text { id: hcT; anchors.centerIn: parent; text: hc.label
                            color: hc.danger ? Theme.bad : (hcMa.containsMouse ? Theme.ink : Theme.ink2)
                            font.family: Theme.fontSans; font.pixelSize: 11 }
                        MouseArea { id: hcMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor; onClicked: hc.tapped() }
                    }
                    HCell {
                        visible: !hdr.armed
                        label: "▤ " + qsTr("Open in Live Monitor")
                        onTapped: root.openInLive(root.selectedGroup === "__ungrouped__" ? "" : root.selectedGroup,
                                                  root.selectedGroupName)
                    }
                    HCell {
                        visible: root.canEdit && !hdr.armed && root.selectedGroup !== "" && root.selectedGroup !== "__ungrouped__"
                        label: qsTr("Delete group"); danger: true
                        onTapped: hdr.armed = true
                    }
                    // armed in place — the blast radius is in the sentence
                    Rectangle {
                        visible: hdr.armed
                        Layout.fillHeight: true
                        Layout.preferredWidth: delT.implicitWidth + 76
                        color: "#2c211d"
                        Rectangle { anchors.left: parent.left; width: 1; height: parent.height; color: Theme.line }
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 10; spacing: 12
                            Text {
                                id: delT
                                text: root.scoped.length > 0
                                    ? qsTr("Delete “%1”? %2 become ungrouped.").arg(root.selectedGroupName)
                                          .arg(qsTr("%n camera(s)", "", root.scoped.length))
                                    : qsTr("Delete “%1”?").arg(root.selectedGroupName)
                                color: Theme.bad; font.family: Theme.fontMono; font.pixelSize: 10
                            }
                            Text {
                                text: "✓"; color: Theme.bad; font.pixelSize: 13
                                MouseArea {
                                    anchors.fill: parent; anchors.margins: -6; cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        root.cameraModel.removeGroup(root.selectedGroup);
                                        root.selectedGroup = ""; root.selectedGroupName = qsTr("All cameras");
                                        hdr.armed = false;
                                    }
                                }
                            }
                            Text {
                                text: "✕"; color: Theme.ink3; font.pixelSize: 12
                                MouseArea { anchors.fill: parent; anchors.margins: -6; cursorShape: Qt.PointingHandCursor
                                    onClicked: hdr.armed = false }
                            }
                        }
                    }
                }
            }

            // read-only strip, stated once
            Rectangle {
                visible: !root.canEdit
                Layout.fillWidth: true; Layout.preferredHeight: 22; color: Theme.panel
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
                Text {
                    anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
                    text: "⃠ " + qsTr("READ-ONLY · your role cannot rename, group or delete")
                    color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 10
                }
            }

            // filter bar 30px — replaces the permanent hint strip
            Rectangle {
                Layout.fillWidth: true; Layout.preferredHeight: 30; color: Theme.bg
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
                RowLayout {
                    anchors.fill: parent; spacing: 0
                    Rectangle {
                        Layout.preferredWidth: 196; Layout.fillHeight: true; color: "transparent"
                        Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.line }
                        Text { id: cqIcon; anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
                            text: "⌕"; color: Theme.ink3; font.pixelSize: 12 }
                        C.TextField {
                            id: cqField
                            anchors { left: cqIcon.right; leftMargin: 6; right: parent.right; rightMargin: 10
                                      verticalCenter: parent.verticalCenter }
                            padding: 0; color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 11
                            background: null
                            onTextChanged: { root.cq = text; root.openId = "" }
                        }
                        Text { visible: cqField.text === ""
                            anchors { left: cqIcon.right; leftMargin: 6; verticalCenter: parent.verticalCenter }
                            text: qsTr("Octet or name…"); color: Theme.ink3
                            font.family: Theme.fontSans; font.pixelSize: 11 }
                    }
                    component Facet: Rectangle {
                        id: fc
                        property string fkey: ""
                        property string label: ""
                        property int n: 0
                        property bool fault: false
                        readonly property bool on: root.facet === fkey
                        Layout.fillHeight: true
                        Layout.preferredWidth: fRow.implicitWidth + 22
                        color: fc.on ? (fc.fault ? Theme.badSoft : Theme.accentSoft) : (fMa.containsMouse ? Theme.panel2 : "transparent")
                        Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.line }
                        Rectangle { visible: fc.on; anchors.bottom: parent.bottom; width: parent.width; height: 2
                            color: fc.fault ? Theme.bad : Theme.accent }
                        Row {
                            id: fRow; anchors.centerIn: parent; spacing: 6
                            Text { anchors.verticalCenter: parent.verticalCenter; text: fc.label
                                color: fc.on ? (fc.fault ? Theme.bad : Theme.accent) : Theme.ink2
                                font.family: Theme.fontSans; font.pixelSize: 11 }
                            Text { anchors.verticalCenter: parent.verticalCenter; text: fc.n
                                color: fc.on ? (fc.fault ? Theme.bad : Theme.accent) : Theme.ink3
                                font.family: Theme.fontMono; font.pixelSize: 10 }
                        }
                        MouseArea { id: fMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: { root.facet = fc.fkey; root.openId = "" } }
                    }
                    Facet { fkey: "all";     label: qsTr("All");     n: root.nAll }
                    Facet { fkey: "unnamed"; label: qsTr("Unnamed"); n: root.nUnnamed }
                    Facet { fkey: "faults";  label: qsTr("Faults");  n: root.nFaults; fault: true }
                    Item { Layout.fillWidth: true }
                    Text {
                        Layout.rightMargin: 14
                        text: root.nNotRec + " " + qsTr("not recording")
                        color: root.nNotRec > 0 ? Theme.bad : Theme.ink3
                        font.family: Theme.fontMono; font.pixelSize: 10
                    }
                    Text {
                        Layout.rightMargin: 14
                        text: root.shown.length + " " + qsTr("of") + " " + root.scoped.length
                        color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                    }
                    // 4 / 6 per row — a preference, never a function of width
                    component PR: Rectangle {
                        id: pr
                        property int v: 6
                        Layout.fillHeight: true; Layout.preferredWidth: 26
                        color: root.perRow === pr.v ? Theme.accentSoft : (prMa.containsMouse ? Theme.panel2 : "transparent")
                        Rectangle { anchors.left: parent.left; width: 1; height: parent.height; color: Theme.line }
                        Text { anchors.centerIn: parent; text: pr.v
                            color: root.perRow === pr.v ? Theme.accent : Theme.ink3
                            font.family: Theme.fontMono; font.pixelSize: 10 }
                        MouseArea { id: prMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: root.perRow = pr.v }
                    }
                    PR { v: 4 }
                    PR { v: 6 }
                }
            }

            // ---- the wall ----
            Item {
                id: wallHost
                Layout.fillWidth: true; Layout.fillHeight: true
                clip: true
                readonly property int rowH: Math.round(width / root.perRow * 9 / 16)
                readonly property int baseW: Math.floor(width / root.perRow)
                readonly property int remW: width - baseW * root.perRow

                ListView {
                    id: wall
                    anchors.fill: parent
                    visible: root.rows.length > 0
                    clip: true
                    cacheBuffer: 0                                   // viewport-only (§3)
                    boundsBehavior: Flickable.StopAtBounds
                    model: root.rows
                    C.ScrollBar.vertical: C.ScrollBar {
                        // a lighter track reads as exactly the seam this wall removes
                        contentItem: Rectangle { implicitWidth: 3; color: Theme.line2 }
                        background: Rectangle { color: "#141312" }
                    }

                    delegate: RowLayout {
                        required property var modelData
                        width: wall.width
                        height: wallHost.rowH
                        spacing: 0                                   // gap: 0, both axes

                        Repeater {
                            model: parent.modelData
                            delegate: Item {
                                id: tile
                                required property var modelData
                                required property int index
                                readonly property var c: modelData
                                readonly property bool isSel: root.sel[c.camId] === true
                                readonly property bool fault: St.FAULT(c)
                                readonly property bool warn: St.warn(c)
                                readonly property bool off: St.offline(c)
                                readonly property int scrimH: root.perRow === 6 ? 20 : 24
                                // exact: floor + one pixel to the leading (w % cols) tiles, so a
                                // row sums to the pane width with no lighter strip at the edge
                                Layout.preferredWidth: wallHost.baseW + (tile.index < wallHost.remW ? 1 : 0)
                                Layout.preferredHeight: wallHost.rowH

                                Rectangle { anchors.fill: parent; color: tile.off ? "#191817" : "#141312" }
                                LiveThumb {
                                    anchors.fill: parent
                                    visible: !tile.off                // offline is never requested
                                    cam: tile.c
                                    active: root.visible && root.openId === ""   // paused behind the modal
                                    showOctet: false; showStatus: false
                                    refreshMs: 10000                  // slow poll: organisational screen
                                }

                                // bottom scrim — the only permanent chrome
                                Rectangle {
                                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                                    height: tile.scrimH
                                    gradient: Gradient {
                                        GradientStop { position: 0.0; color: "transparent" }
                                        GradientStop { position: 1.0
                                            color: tile.isSel ? Qt.rgba(0.56, 0.38, 0.11, 0.9) : Qt.rgba(0, 0, 0, 0.86) }
                                    }
                                    Row {
                                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom
                                                  leftMargin: 5; rightMargin: 5; bottomMargin: 3 }
                                        spacing: 6
                                        Text {
                                            id: octT
                                            text: St.octet(tile.c); color: "#ffffff"      // never truncated
                                            font.family: Theme.fontMono
                                            font.pixelSize: root.perRow === 6 ? 11 : 12
                                            font.weight: Font.DemiBold
                                        }
                                        Text {
                                            width: Math.max(0, parent.width - octT.width - 6)
                                            elide: Text.ElideRight
                                            text: St.unnamed(tile.c) ? St.modelOf(tile.c) : tile.c.name
                                            color: St.unnamed(tile.c) ? Qt.rgba(1, 1, 1, 0.5) : Qt.rgba(1, 1, 1, 0.9)
                                            font.family: Theme.fontSans
                                            font.pixelSize: root.perRow === 6 ? 11 : 12
                                        }
                                    }
                                }
                                Rectangle {
                                    visible: St.unnamed(tile.c)
                                    anchors { right: parent.right; bottom: parent.bottom; rightMargin: 4; bottomMargin: tile.scrimH + 3 }
                                    height: 12; width: unT.implicitWidth + 8
                                    color: Qt.rgba(0, 0, 0, 0.66)
                                    Text { id: unT; anchors.centerIn: parent; text: qsTr("UNNAMED"); color: Theme.accent
                                        font.family: Theme.fontMono; font.pixelSize: 8; font.letterSpacing: 0.8 }
                                }

                                // top row — checkbox · status marker · online dot
                                Row {
                                    anchors { left: parent.left; top: parent.top; leftMargin: 5; topMargin: 5 }
                                    spacing: 5
                                    Rectangle {
                                        visible: root.canEdit && (tileMa.containsMouse || tile.isSel)
                                        width: 14; height: 14
                                        color: tile.isSel ? Theme.accent : Qt.rgba(0, 0, 0, 0.55)
                                        border.width: 1
                                        border.color: tile.isSel ? Theme.accent : Qt.rgba(1, 1, 1, 0.55)
                                        Text { anchors.centerIn: parent; visible: tile.isSel; text: "✓"
                                            color: "#241a08"; font.pixelSize: 10; font.weight: Font.Bold }
                                        MouseArea { anchors.fill: parent; anchors.margins: -2
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.toggleSel(tile.c.camId) }
                                    }
                                    Rectangle {
                                        visible: St.marker(tile.c) !== ""
                                        height: 13; width: mkT.implicitWidth + 8
                                        color: St.markerIsFault(tile.c) ? Theme.bad : Qt.rgba(0, 0, 0, 0.6)
                                        border.width: St.markerIsFault(tile.c) ? 0 : 1
                                        border.color: Theme.accent
                                        Text { id: mkT; anchors.centerIn: parent; text: St.marker(tile.c)
                                            color: St.markerIsFault(tile.c) ? "#241a08" : Theme.accent
                                            font.family: Theme.fontMono; font.pixelSize: 8
                                            font.letterSpacing: 0.5; font.weight: Font.DemiBold }
                                    }
                                }
                                Rectangle {
                                    anchors { right: parent.right; top: parent.top; rightMargin: 5; topMargin: 5 }
                                    width: 5; height: 5; radius: 2.5
                                    color: tile.off ? Theme.bad : Theme.good
                                }

                                // hover row — the two things that need words
                                Row {
                                    visible: tileMa.containsMouse
                                    anchors { left: parent.left; bottom: parent.bottom
                                              leftMargin: 5; bottomMargin: tile.scrimH + 3 }
                                    spacing: 5
                                    Rectangle {
                                        height: 14; width: hbT.implicitWidth + 10
                                        color: Qt.rgba(0, 0, 0, 0.72)
                                        Text { id: hbT; anchors.centerIn: parent; text: St.badgeText(tile.c)
                                            color: tile.fault ? Theme.bad : Theme.ink2
                                            font.family: Theme.fontMono; font.pixelSize: 9 }
                                    }
                                    Rectangle {
                                        visible: root.perRow === 4
                                        height: 14; width: gcT.implicitWidth + 10
                                        color: Qt.rgba(0, 0, 0, 0.72)
                                        Text { id: gcT; anchors.centerIn: parent
                                            text: tile.c.groupName !== "" ? tile.c.groupName : qsTr("Ungrouped")
                                            color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 9 }
                                    }
                                }

                                // every state is an INSET ring — never a border, never a gap
                                Rectangle { anchors.fill: parent; color: "transparent"
                                    border.width: 1; border.color: Qt.rgba(0, 0, 0, 0.55) }
                                Rectangle {
                                    visible: tile.fault || tile.warn || tile.isSel
                                    anchors.fill: parent; color: "transparent"
                                    border.width: (tile.isSel || tile.fault) ? 2 : 1
                                    border.color: tile.isSel ? Theme.accent
                                                : tile.fault ? Theme.bad
                                                : Qt.rgba(232 / 255, 161 / 255, 58 / 255, 0.55)
                                }

                                MouseArea {
                                    id: tileMa
                                    anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: (m) => {
                                        root.forceActiveFocus();
                                        if (m.modifiers & Qt.ShiftModifier) { root.rangeSel(tile.c.camId); return }
                                        if (m.modifiers & (Qt.ControlModifier | Qt.MetaModifier)) { root.toggleSel(tile.c.camId); return }
                                        root.onlySel(tile.c.camId);
                                        root.openId = tile.c.camId;      // plain click selects AND opens
                                    }
                                }
                            }
                        }
                        // a short last row keeps full-row tile width; the spacer eats the rest
                        Item { Layout.fillWidth: true; Layout.preferredWidth: 0 }
                    }
                }

                // honest empty states — each names its scope or filter
                Column {
                    anchors.centerIn: parent
                    visible: root.rows.length === 0
                    spacing: 6
                    width: Math.min(420, parent.width - 60)
                    Text {
                        width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                        text: root.facet === "faults" ? qsTr("Every camera in scope is recording.")
                            : root.facet === "unnamed" ? qsTr("Every camera in scope has a name.")
                            : root.cq !== "" ? qsTr("Nothing matches “%1”.").arg(root.cq)
                            : qsTr("No cameras in “%1”.").arg(root.selectedGroupName)
                        color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 13
                    }
                    Text {
                        width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                        visible: root.facet === "all" && root.cq === "" && root.selectedGroup !== ""
                        text: qsTr("Select cameras in another group and move them here.")
                        color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11
                    }
                }
            }

            // ---- selection bar — one click files the whole selection
            Rectangle {
                visible: root.canEdit && root.selCount > 0
                Layout.fillWidth: true; Layout.preferredHeight: 34
                color: "#2b2318"
                Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Theme.accent }
                RowLayout {
                    anchors.fill: parent; spacing: 0
                    Text {
                        Layout.leftMargin: 14; Layout.rightMargin: 14
                        text: qsTr("%n selected", "", root.selCount); color: Theme.accent
                        font.family: Theme.fontSans; font.pixelSize: 11; font.weight: Font.DemiBold
                    }
                    Text {
                        Layout.rightMargin: 10; text: qsTr("MOVE TO"); color: Theme.ink3
                        font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 1.2
                    }
                    Repeater {
                        model: root.groupsData
                        delegate: Rectangle {
                            id: mv
                            required property var modelData
                            Layout.fillHeight: true
                            Layout.preferredWidth: mvT.implicitWidth + 22
                            color: mvMa.containsMouse ? Theme.accentDim : "transparent"
                            Rectangle { anchors.left: parent.left; width: 1; height: parent.height
                                color: Qt.rgba(1, 1, 1, 0.08) }
                            Text { id: mvT; anchors.centerIn: parent; text: mv.modelData.name; color: Theme.ink
                                font.family: Theme.fontSans; font.pixelSize: 11 }
                            MouseArea { id: mvMa; anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { root.fileSelection(mv.modelData.id); root.clearSel() } }
                        }
                    }
                    Rectangle {
                        Layout.fillHeight: true; Layout.preferredWidth: ungT.implicitWidth + 22
                        color: ungMa.containsMouse ? Theme.accentDim : "transparent"
                        Rectangle { anchors.left: parent.left; width: 1; height: parent.height; color: Qt.rgba(1, 1, 1, 0.08) }
                        Text { id: ungT; anchors.centerIn: parent; text: qsTr("Ungrouped"); color: Theme.ink2
                            font.family: Theme.fontSans; font.pixelSize: 11 }
                        MouseArea { id: ungMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { root.fileSelection(""); root.clearSel() } }
                    }
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        Layout.fillHeight: true; Layout.preferredWidth: clrT.implicitWidth + 24
                        color: clrMa.containsMouse ? Theme.accentDim : "transparent"
                        Text { id: clrT; anchors.centerIn: parent; text: "✕ " + qsTr("Clear"); color: Theme.ink2
                            font.family: Theme.fontSans; font.pixelSize: 11 }
                        MouseArea { id: clrMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor; onClicked: root.clearSel() }
                    }
                }
            }
        }
    }

    // ====================================== MODAL LIGHTBOX (§2.7)
    Loader {
        id: modalLoader
        anchors.fill: parent
        active: root.openId !== "" && root.openCam !== null
        z: 100
        sourceComponent: modalC
    }
    Component {
        id: modalC
        Item {
            id: modal
            anchors.fill: parent
            readonly property var c: root.openCam
            readonly property int idx: root.openIdx
            // derived AFTER the index they depend on
            readonly property var prevCam: idx > 0 ? root.shown[idx - 1] : null
            readonly property var nextCam: (idx >= 0 && idx < root.shown.length - 1) ? root.shown[idx + 1] : null

            Rectangle {
                anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.62)
                MouseArea { anchors.fill: parent; onClicked: root.openId = "" }
            }

            Rectangle {
                id: card
                readonly property int cw: Math.round(root.width * 0.84)
                readonly property int vh: Math.max(160, Math.min(Math.round(cw * 9 / 16),
                                                                 Math.round(root.height * 0.86) - 60))
                width: cw; height: vh + 60
                anchors.centerIn: parent
                color: Theme.panel; border.width: 1; border.color: Theme.line2
                clip: true                                       // the card clips its own children
                MouseArea { anchors.fill: parent }                // swallow clicks (don't close)

                ColumnLayout {
                    anchors.fill: parent; anchors.margins: 1; spacing: 0

                    Rectangle {                                  // header 30
                        Layout.fillWidth: true; Layout.preferredHeight: 30; color: Theme.panel
                        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 12; spacing: 10
                            Text { text: St.octet(modal.c); color: Theme.accent
                                font.family: Theme.fontMono; font.pixelSize: 13; font.weight: Font.DemiBold }
                            Text {
                                Layout.maximumWidth: 460; elide: Text.ElideRight
                                text: St.unnamed(modal.c) ? St.modelOf(modal.c) : modal.c.name
                                color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13
                            }
                            Rectangle {
                                visible: St.unnamed(modal.c)
                                Layout.preferredHeight: 13; Layout.preferredWidth: unm.implicitWidth + 8
                                color: "transparent"; border.width: 1; border.color: Theme.accent
                                Text { id: unm; anchors.centerIn: parent; text: qsTr("UNNAMED"); color: Theme.accent
                                    font.family: Theme.fontMono; font.pixelSize: 8 }
                            }
                            Item { Layout.fillWidth: true }
                            Text { text: (modal.idx + 1) + " / " + root.shown.length; color: Theme.ink3
                                font.family: Theme.fontMono; font.pixelSize: 10 }
                            Rectangle {
                                Layout.fillHeight: true; Layout.preferredWidth: 34
                                color: xMa.containsMouse ? Theme.panel2 : "transparent"
                                Text { anchors.centerIn: parent; text: "✕"; color: Theme.ink2; font.pixelSize: 12 }
                                MouseArea { id: xMa; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor; onClicked: root.openId = "" }
                            }
                        }
                    }

                    Item {                                        // frame + ONE shared nav layer
                        id: frame
                        Layout.fillWidth: true
                        Layout.preferredHeight: card.vh
                        property bool navShown: true
                        Rectangle { anchors.fill: parent; color: "#0a0908" }
                        LiveThumb {
                            anchors.fill: parent
                            visible: !St.offline(modal.c)
                            cam: modal.c; active: true
                            showOctet: false; showStatus: false; refreshMs: 2000
                        }
                        Timer { id: idleT; interval: 2600; onTriggered: frame.navShown = false; running: true }
                        MouseArea {
                            anchors.fill: parent; hoverEnabled: true
                            onPositionChanged: { frame.navShown = true; idleT.restart() }
                            onExited: { frame.navShown = false; idleT.stop() }
                        }
                        Connections {
                            target: root
                            function onOpenIdChanged() { frame.navShown = true; idleT.restart() }
                        }

                        component Plate: Rectangle {
                            id: plate
                            property var cam: null
                            property bool isNext: false
                            readonly property bool atEnd: cam === null
                            width: 168; height: 58
                            color: Qt.rgba(0, 0, 0, 0.66)
                            opacity: frame.navShown ? 1 : 0
                            visible: opacity > 0.01
                            Behavior on opacity { NumberAnimation { duration: 130 } }
                            Text {
                                visible: plate.atEnd; anchors.centerIn: parent
                                text: plate.isNext ? qsTr("END OF LIST") : qsTr("START OF LIST")
                                color: Theme.ink3; font.family: Theme.fontMono
                                font.pixelSize: 9; font.letterSpacing: 1.0
                            }
                            Row {
                                visible: !plate.atEnd
                                anchors.fill: parent; anchors.margins: 6
                                layoutDirection: plate.isNext ? Qt.RightToLeft : Qt.LeftToRight
                                spacing: 8
                                Rectangle {                        // 50×29 adjacent frame
                                    width: 50; height: 29; color: "#141312"
                                    anchors.verticalCenter: parent.verticalCenter
                                    LiveThumb {
                                        anchors.fill: parent; cam: plate.cam; active: !plate.atEnd
                                        showOctet: false; showStatus: false; refreshMs: 30000
                                    }
                                    Rectangle {
                                        visible: plate.cam && (St.FAULT(plate.cam) || St.warn(plate.cam))
                                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                                        height: 2
                                        color: (plate.cam && St.FAULT(plate.cam)) ? Theme.bad : Theme.accent
                                    }
                                }
                                Column {
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 1
                                    Text { text: plate.isNext ? qsTr("NEXT") : qsTr("PREV")
                                        color: Qt.rgba(1, 1, 1, 0.5); font.family: Theme.fontMono
                                        font.pixelSize: 8; font.letterSpacing: 1.0 }
                                    Text { text: plate.cam ? St.octet(plate.cam) : ""
                                        color: plateMa.containsMouse ? Theme.accent : "#ffffff"
                                        font.family: Theme.fontMono; font.pixelSize: 12; font.weight: Font.DemiBold }
                                    Text {
                                        width: 96; elide: Text.ElideRight
                                        text: plate.cam ? (St.unnamed(plate.cam) ? St.modelOf(plate.cam) : plate.cam.name) : ""
                                        color: Qt.rgba(1, 1, 1, 0.68); font.family: Theme.fontSans; font.pixelSize: 9
                                    }
                                }
                            }
                            MouseArea {
                                id: plateMa
                                anchors.fill: parent; hoverEnabled: true
                                enabled: !plate.atEnd
                                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onClicked: root.stepOpen(plate.isNext ? 1 : -1)
                            }
                        }
                        Plate {
                            anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 10 }
                            cam: modal.prevCam; isNext: false
                        }
                        Plate {
                            anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 10 }
                            cam: modal.nextCam; isNext: true
                        }
                    }

                    Rectangle {                                   // footer 30
                        Layout.fillWidth: true; Layout.preferredHeight: 30; color: Theme.panel
                        Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Theme.line }
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 14
                            // metadata cells shrink and ellipsize; action cells never do
                            Text { Layout.fillWidth: true; Layout.minimumWidth: 0; elide: Text.ElideRight
                                text: modal.c.ip; color: Theme.ink3
                                font.family: Theme.fontMono; font.pixelSize: 10 }
                            Text { Layout.fillWidth: true; Layout.minimumWidth: 0; elide: Text.ElideRight
                                text: modal.c.model ? modal.c.model : St.modelOf(modal.c); color: Theme.ink3
                                font.family: Theme.fontMono; font.pixelSize: 10 }
                            Text { Layout.fillWidth: true; Layout.minimumWidth: 0; elide: Text.ElideRight
                                text: St.badgeText(modal.c)
                                color: St.FAULT(modal.c) ? Theme.bad : Theme.ink3
                                font.family: Theme.fontMono; font.pixelSize: 10 }
                            Item { Layout.fillWidth: true }
                            Text {
                                text: modal.c.groupName !== "" ? modal.c.groupName : qsTr("Ungrouped")
                                color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 10
                            }
                            Text { text: "▤ " + qsTr("Open in Live Monitor"); color: Theme.accent
                                font.family: Theme.fontSans; font.pixelSize: 10
                                MouseArea { anchors.fill: parent; anchors.margins: -4
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: { var cam = modal.c; root.openId = ""; root.openCamera(cam) } } }
                            Text { text: qsTr("← → ESC"); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9 }
                        }
                    }
                }
            }
        }
    }
}
