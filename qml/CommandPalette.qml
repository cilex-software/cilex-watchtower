import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as QC
import Watchtower

// Command palette (Ctrl+K / design §10). Center-top 680px overlay searching
// cameras, groups, saved views and events over the existing models. Keyboard:
// ↑↓ navigate, ↵ open, Esc close. Clips are omitted — there's no enumerable
// clip/export source yet (no backend list endpoint), so we don't show an empty
// or fake group.
Item {
    id: root
    anchors.fill: parent
    visible: false

    property var cameraModel: null
    property var savedViewModel: null
    property var eventModel: null
    property var snapshotModel: null

    signal openCamera(var cam)
    signal openGroup(string groupId, string label)
    signal openView(var view)
    signal openEvents()
    signal openClips()

    property string query: ""
    property int sel: -1                  // display index of the selected row
    property var built: ({ display: [], flat: [], groups: [] })

    function eventGlyph(t) { return EventStyle.icon(t); }
    function eventColor(t) { return EventStyle.color(t); }

    function build() {
        var ql = query.toLowerCase().trim();
        function mm(s) { return ql === "" || (s !== undefined && s !== null && ("" + s).toLowerCase().indexOf(ql) >= 0); }
        var groups = [];
        if (cameraModel) {
            var cams = cameraModel.page("", "", "alpha", 1, 100000), cr = [];
            for (var i = 0; i < cams.length; i++) {
                var c = cams[i];
                if (mm(c.name) || mm(c.camId) || mm(c.ip) || mm(c.groupName))
                    cr.push({ type: "camera", title: c.name, subtitle: (c.camId || c.ip) + " · " + (c.groupName || ""), glyph: "monitor", isCam: true, live: c.live, recording: c.recording, data: c });
            }
            if (cr.length) groups.push({ label: qsTr("Cameras"), count: cr.length, rows: cr.slice(0, 5) });
        }
        if (cameraModel) {
            var gs = cameraModel.groupList(), gr = [];
            for (var j = 0; j < gs.length; j++) {
                var g = gs[j];
                if (mm(g.name)) gr.push({ type: "group", title: g.name, subtitle: (g.total || 0) + " cameras", glyph: "layers", glyphColor: Theme.ink3, data: g });
            }
            if (gr.length) groups.push({ label: qsTr("Groups"), count: gr.length, rows: gr.slice(0, 5) });
        }
        if (savedViewModel) {
            var vs = savedViewModel.list(), vr = [];
            for (var k = 0; k < vs.length; k++) {
                var v = vs[k];
                if (mm(v.name)) vr.push({ type: "view", title: v.name, subtitle: (v.shared ? qsTr("Shared") : qsTr("Mine")) + " · " + LayoutSpec.label(v.layout) + " layout", glyph: "grid", glyphColor: Theme.ink3, data: v });
            }
            if (vr.length) groups.push({ label: qsTr("Saved Views"), count: vr.length, rows: vr.slice(0, 5) });
        }
        if (eventModel) {
            var es = eventModel.all(), er = [];
            for (var n = 0; n < es.length; n++) {
                var e = es[n];
                if (mm(e.desc) || mm(e.camName) || mm(e.type))
                    er.push({ type: "event", title: e.desc, subtitle: ("" + e.type).toUpperCase() + " · " + e.time, glyph: eventGlyph(e.type), glyphColor: eventColor(e.type), data: e });
            }
            if (er.length) groups.push({ label: qsTr("Events"), count: er.length, rows: er.slice(0, 5) });
        }
        if (snapshotModel) {
            var ss = snapshotModel.all(), sr = [];
            for (var p = 0; p < ss.length; p++) {
                var s = ss[p];
                if (mm(s.title) || mm(s.camera) || mm("snapshot"))
                    sr.push({ type: "clip", title: s.title, subtitle: qsTr("Snapshot · ") + (s.camera || ""), glyph: "shot", glyphColor: Theme.ink2, data: s });
            }
            if (sr.length) groups.push({ label: qsTr("Clips & Snapshots"), count: sr.length, rows: sr.slice(0, 5) });
        }
        var flat = [], display = [];
        for (var gi = 0; gi < groups.length; gi++) {
            display.push({ header: true, label: groups[gi].label, count: groups[gi].count });
            for (var ri = 0; ri < groups[gi].rows.length; ri++) {
                var row = groups[gi].rows[ri];
                row.flatIndex = flat.length;
                flat.push(row);
                display.push({ header: false, row: row });
            }
        }
        return { display: display, flat: flat, groups: groups };
    }

    function firstRow() { for (var x = 0; x < built.display.length; x++) if (!built.display[x].header) return x; return -1; }
    function rowAfter(i) { for (var x = i + 1; x < built.display.length; x++) if (!built.display[x].header) return x; return i; }
    function rowBefore(i) { for (var x = i - 1; x >= 0; x--) if (!built.display[x].header) return x; return i; }
    function rebuild() { built = build(); sel = firstRow(); }
    onQueryChanged: rebuild()
    function moveSel(next) { sel = next; resultsList.positionViewAtIndex(sel, ListView.Contain) }

    function open() { query = ""; visible = true; rebuild(); searchInput.forceActiveFocus(); }
    function close() { visible = false }
    function activate(row) {
        if (!row) return;
        close();
        if (row.type === "camera") root.openCamera(row.data);
        else if (row.type === "group") root.openGroup(row.data.id, row.data.name);
        else if (row.type === "view") root.openView(row.data);
        else if (row.type === "event") root.openEvents();
        else if (row.type === "clip") root.openClips();
    }
    function activateSel() {
        if (sel < 0 || sel >= built.display.length || built.display[sel].header) return;
        activate(built.display[sel].row);
    }
    function countSummary() {
        var parts = [];
        for (var i = 0; i < built.groups.length; i++) parts.push(built.groups[i].count + " " + built.groups[i].label.toLowerCase());
        return parts.length ? parts.join(" · ") : "no matches";
    }

    // scrim
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.55)
        MouseArea { anchors.fill: parent; onClicked: root.close() }
    }

    // faux shadow behind the panel
    Rectangle {
        anchors.fill: panel; anchors.margins: -1
        color: "transparent"
        // a soft dark halo
        Rectangle { anchors.fill: parent; anchors.margins: -8; color: Qt.rgba(0,0,0,0.35); z: -1 }
    }

    // palette
    Rectangle {
        id: panel
        width: 680
        anchors.horizontalCenter: parent.horizontalCenter
        y: 90
        height: col.implicitHeight
        color: Theme.panel
        border.width: 1; border.color: Theme.accent
        MouseArea { anchors.fill: parent }   // eat clicks inside

        ColumnLayout {
            id: col
            width: parent.width
            spacing: 0

            // search row
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 56
                color: "transparent"
                Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
                Icon { anchors.left: parent.left; anchors.leftMargin: 18; anchors.verticalCenter: parent.verticalCenter; name: "search"; size: 16; color: Theme.accent }
                TextInput {
                    id: searchInput
                    anchors.fill: parent; anchors.leftMargin: 50; anchors.rightMargin: 16
                    verticalAlignment: TextInput.AlignVCenter
                    color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 16
                    clip: true; selectByMouse: true
                    text: root.query
                    onTextChanged: root.query = text
                    Keys.onDownPressed: root.moveSel(root.rowAfter(root.sel))
                    Keys.onUpPressed: root.moveSel(root.rowBefore(root.sel))
                    Keys.onReturnPressed: root.activateSel()
                    Keys.onEnterPressed: root.activateSel()
                    Keys.onEscapePressed: (e) => { root.close(); e.accepted = true }
                }
                Text {
                    visible: searchInput.text === ""
                    anchors.left: parent.left; anchors.leftMargin: 50; anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("Search cameras, groups, views, events…")
                    color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 16
                }
            }

            // results
            ListView {
                id: resultsList
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(contentHeight, 460)
                clip: true
                model: root.built.display
                boundsBehavior: Flickable.StopAtBounds
                QC.ScrollBar.vertical: QC.ScrollBar { }

                delegate: Item {
                    required property var modelData
                    required property int index
                    width: ListView.view.width
                    implicitHeight: modelData.header ? 28 : 46

                    // group header
                    Text {
                        visible: modelData.header
                        anchors.left: parent.left; anchors.leftMargin: 16; anchors.bottom: parent.bottom; anchors.bottomMargin: 4
                        text: modelData.header ? (modelData.label + " · " + modelData.count) : ""
                        color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.DemiBold; font.letterSpacing: 1.4; font.capitalization: Font.AllUppercase
                    }

                    // result row
                    Rectangle {
                        visible: !modelData.header
                        anchors.fill: parent
                        readonly property bool isSel: root.sel === index
                        color: isSel ? Theme.panel2 : "transparent"
                        Rectangle { anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 3; color: parent.isSel ? Theme.accent : "transparent" }
                        MouseArea {
                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onEntered: root.sel = index
                            onClicked: if (!modelData.header) root.activate(modelData.row)
                        }
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 16; spacing: 12
                            // 36×26 thumb (camera preview, else glyph)
                            Rectangle {
                                Layout.preferredWidth: 36; Layout.preferredHeight: 26
                                color: "#000"; border.width: 1; border.color: Theme.line2
                                PlaceholderVid {
                                    anchors.fill: parent; anchors.margins: 1
                                    visible: !modelData.header && modelData.row.isCam === true
                                    pattern: (!modelData.header && modelData.row.data) ? (modelData.row.data.pattern || 0) : 0
                                    geom: "lobby"
                                }
                                Icon {
                                    anchors.centerIn: parent
                                    visible: !modelData.header && modelData.row.isCam !== true
                                    name: modelData.header ? "" : modelData.row.glyph
                                    size: 14
                                    color: (!modelData.header && modelData.row.glyphColor) ? modelData.row.glyphColor : Theme.ink3
                                }
                            }
                            // info
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 1
                                Text { text: modelData.header ? "" : modelData.row.title; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13; font.weight: Font.Medium; elide: Text.ElideRight; Layout.fillWidth: true }
                                Text { text: modelData.header ? "" : modelData.row.subtitle; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11; elide: Text.ElideRight; Layout.fillWidth: true }
                            }
                            // camera badges
                            Row {
                                spacing: 4
                                visible: !modelData.header && modelData.row.isCam === true
                                LiveStatusBadge { state: (!modelData.header && modelData.row.isCam === true) ? modelData.row.live : CameraStatus.LiveUnknown }
                                RecordingStatusBadge { state: (!modelData.header && modelData.row.isCam === true) ? modelData.row.recording : CameraStatus.RecUnknown }
                            }
                        }
                    }
                }

                // no matches
                Text {
                    anchors.centerIn: parent
                    visible: root.built.flat.length === 0
                    text: root.query === "" ? qsTr("Type to search") : qsTr("No matches for “") + root.query + "”"
                    color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 13
                }
            }

            // footer
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 34
                color: Theme.panel
                Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; height: 1; color: Theme.line }
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 14
                    component Hint: Row {
                        property string k: ""
                        property string label: ""
                        spacing: 5
                        Rectangle { anchors.verticalCenter: parent.verticalCenter; implicitWidth: kt.implicitWidth + 10; implicitHeight: 16; color: Theme.bg; border.width: 1; border.color: Theme.line2
                            Text { id: kt; anchors.centerIn: parent; text: parent.parent.k; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 } }
                        Text { anchors.verticalCenter: parent.verticalCenter; text: parent.label; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                    }
                    Hint { k: "↑↓"; label: qsTr("Navigate") }
                    Hint { k: "↵"; label: qsTr("Open") }
                    Hint { k: "Esc"; label: qsTr("Close") }
                    Item { Layout.fillWidth: true }
                    Text { text: root.countSummary(); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                }
            }
        }
    }
}
