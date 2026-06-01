import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as QC
import Watchtower

// Clips & Snapshots library (design §8 / §296–304). Reached via the command
// palette (the nav rail has no Clips item). Lists locally-saved snapshots
// (SnapshotModel over the Artifacts dir) in the artifact table + detail panel.
// Server-side exported clips can't be listed yet — cilex-vision has no
// exports/clips LIST endpoint (asked in the API-requests letter §A6) — so the
// Clips filter shows an honest "pending" note rather than fake rows.
Item {
    id: root

    property var snapshotModel: null
    property var cameraModel: null
    property var playbackClient: null

    property string pill: "all"          // all | snapshots | clips
    property var sel: null
    property var rows: []
    property var serverClips: []         // A6: raw export jobs from GET /review/exports

    function fmtSize(b) {
        if (!b) return "—";
        return b < 1048576 ? (Math.max(1, Math.round(b / 1024)) + " KB") : ((b / 1048576).toFixed(1) + " MB");
    }
    function fmtCaptured(iso) {
        var t = Date.parse(iso);
        if (isNaN(t)) return "—";
        var d = new Date(t);
        return Qt.formatDate(d, "MMM d") + " · " + Settings.clock(t, false);
    }
    function statusColor(s) {
        return s === "ready" ? Theme.good : ((s === "failed" || s === "error") ? Theme.bad : Theme.accent);
    }
    // Adapt a server export job (A6) into a unified row.
    function mapClip(j) {
        var camName;
        if (j.kind === "mosaic")
            camName = "Grid · " + (j.group_id ? j.group_id : ("" + (j.mosaic_session_id || "")).slice(0, 8));
        else {
            var c = root.cameraModel ? root.cameraModel.cameraByBackendId(j.camera_id) : null;
            camName = (c && c.name) ? c.name : (j.camera_id || "—");
        }
        return {
            _kind: "clip", key: j.job_id,
            title: (j.purpose && j.purpose !== "") ? j.purpose
                   : (j.kind === "mosaic" ? "Synchronized grid clip" : "Camera clip"),
            camera: camName, capturedIso: j.created_at, bytes: j.output_bytes,
            state: j.state, status: ("" + j.state).toUpperCase(),
            openUrl: (j.state === "ready" && j.downloadUrl) ? j.downloadUrl : "",
            resolution: j.resolution, mode: j.mode, groupId: j.group_id,
            purpose: j.purpose, kindLabel: j.kind, wallStart: j.wall_start, wallEnd: j.wall_end
        };
    }
    function recompute() {
        var out = [];
        if (root.pill !== "clips" && root.snapshotModel) {
            var snaps = root.snapshotModel.all();
            for (var i = 0; i < snaps.length; i++) {
                var s = snaps[i];
                out.push({ _kind: "snapshot", key: s.filePath, title: s.title, camera: s.camera,
                           capturedIso: s.capturedIso, bytes: s.bytes, fileUrl: s.fileUrl,
                           fileName: s.fileName, state: "ready", status: "READY", openUrl: s.fileUrl });
            }
        }
        if (root.pill !== "snapshots") {
            for (var k = 0; k < root.serverClips.length; k++) out.push(root.mapClip(root.serverClips[k]));
        }
        out.sort(function (a, b) { return Date.parse(b.capturedIso) - Date.parse(a.capturedIso); });
        root.rows = out;
        if (root.sel) {
            var found = null;
            for (var m = 0; m < root.rows.length; m++)
                if (root.rows[m].key === root.sel.key) { found = root.rows[m]; break; }
            root.sel = found;
        }
    }
    function refresh() {
        if (root.snapshotModel) root.snapshotModel.refresh();
        if (root.playbackClient) root.playbackClient.fetchExports();
        recompute();
    }
    onPillChanged: recompute()
    Component.onCompleted: refresh()
    onVisibleChanged: if (visible) refresh()
    Connections {
        target: root.snapshotModel
        enabled: root.snapshotModel !== null
        function onChanged() { root.recompute() }
    }
    Connections {
        target: root.playbackClient
        enabled: root.playbackClient !== null
        function onExportsListReady(exports) { root.serverClips = exports; root.recompute() }
    }

    component Pill: Rectangle {
        id: p
        property string label: ""
        property bool on: false
        signal clicked()
        implicitHeight: 30
        implicitWidth: pt.implicitWidth + 24
        color: p.on ? Theme.accentSoft : (pma.containsMouse ? Theme.panel2 : Theme.panel)
        border.width: 1; border.color: p.on ? Theme.accent : (pma.containsMouse ? Theme.ink3 : Theme.line2)
        Text { id: pt; anchors.centerIn: parent; text: p.label; color: p.on ? Theme.accent : Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
        MouseArea { id: pma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: p.clicked() }
    }

    readonly property int wGlyph: 36
    readonly property int wCam: 200
    readonly property int wWhen: 160
    readonly property int wSize: 90
    readonly property int wStatus: 100
    readonly property int wAct: 90

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // sub-bar
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 56
            color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 16; spacing: 6
                Text { text: "Clips & Snapshots"; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 16; font.weight: Font.DemiBold; Layout.rightMargin: 8 }
                Pill { label: "All"; on: root.pill === "all"; onClicked: root.pill = "all" }
                Pill { label: "Snapshots" + (root.snapshotModel ? " · " + root.snapshotModel.total : ""); on: root.pill === "snapshots"; onClicked: root.pill = "snapshots" }
                Pill { label: "Clips · " + root.serverClips.length; on: root.pill === "clips"; onClicked: root.pill = "clips" }
                Item { Layout.fillWidth: true }
                Rectangle {
                    implicitHeight: 30; implicitWidth: rfRow.implicitWidth + 22
                    color: rfMa.containsMouse ? Theme.panel2 : "transparent"
                    border.width: 1; border.color: rfMa.containsMouse ? Theme.accent : Theme.line2
                    Row {
                        id: rfRow; anchors.centerIn: parent; spacing: 6
                        Icon { anchors.verticalCenter: parent.verticalCenter; name: "pulse"; size: 13; color: Theme.ink2 }
                        Text { anchors.verticalCenter: parent.verticalCenter; text: "Refresh"; color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12 }
                    }
                    MouseArea { id: rfMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.refresh() }
                }
            }
        }

        // table + detail
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                // header
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 38
                    color: Theme.bg
                    Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line2 }
                    component Th: Text {
                        height: 38; verticalAlignment: Text.AlignVCenter
                        color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.DemiBold; font.letterSpacing: 1.2; font.capitalization: Font.AllUppercase
                    }
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 0
                        Th { text: ""; Layout.preferredWidth: root.wGlyph }
                        Th { text: "Title"; Layout.fillWidth: true }
                        Th { text: "Camera"; Layout.preferredWidth: root.wCam }
                        Th { text: "Captured"; Layout.preferredWidth: root.wWhen }
                        Th { text: "Size"; Layout.preferredWidth: root.wSize }
                        Th { text: "Status"; Layout.preferredWidth: root.wStatus }
                        Th { text: ""; Layout.preferredWidth: root.wAct }
                    }
                }

                // rows
                ListView {
                    id: list
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: root.rows
                    boundsBehavior: Flickable.StopAtBounds
                    QC.ScrollBar.vertical: QC.ScrollBar { }

                    delegate: Rectangle {
                        id: rowItem
                        required property var modelData
                        width: ListView.view.width
                        height: 50
                        readonly property bool isSel: root.sel && root.sel.key === modelData.key
                        color: isSel ? Theme.accentSoft : (rowMa.containsMouse ? Theme.panel : "transparent")
                        Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
                        MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.sel = modelData }
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 0
                            Item { Layout.preferredWidth: root.wGlyph; Layout.fillHeight: true
                                Icon { anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left
                                    name: rowItem.modelData._kind === "clip" ? (rowItem.modelData.kindLabel === "mosaic" ? "layers" : "clip") : "shot"
                                    size: 16; color: Theme.ink2 } }
                            Text { Layout.fillWidth: true; text: rowItem.modelData.title; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13; font.weight: Font.Medium; elide: Text.ElideRight }
                            Text { Layout.preferredWidth: root.wCam; text: rowItem.modelData.camera || "—"; color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11; elide: Text.ElideRight }
                            Text { Layout.preferredWidth: root.wWhen; text: root.fmtCaptured(rowItem.modelData.capturedIso); color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11 }
                            Text { Layout.preferredWidth: root.wSize; text: root.fmtSize(rowItem.modelData.bytes); color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11 }
                            Text { Layout.preferredWidth: root.wStatus; text: rowItem.modelData.status; color: root.statusColor(rowItem.modelData.state); font.family: Theme.fontMono; font.pixelSize: 11; font.weight: Font.DemiBold }
                            Item { Layout.preferredWidth: root.wAct; Layout.fillHeight: true
                                Rectangle {
                                    visible: rowItem.modelData.openUrl !== ""
                                    anchors.verticalCenter: parent.verticalCenter; implicitWidth: opT.implicitWidth + 16; implicitHeight: 24
                                    color: opMa.containsMouse ? Theme.panel2 : "transparent"; border.width: 1; border.color: opMa.containsMouse ? Theme.accent : Theme.line2
                                    Text { id: opT; anchors.centerIn: parent; text: "Open"; color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 11 }
                                    MouseArea { id: opMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Qt.openUrlExternally(rowItem.modelData.openUrl) }
                                }
                            }
                        }
                    }

                    // empty / pending state
                    Column {
                        anchors.centerIn: parent
                        spacing: 6
                        visible: root.rows.length === 0
                        Icon { anchors.horizontalCenter: parent.horizontalCenter; name: root.pill === "clips" ? "clip" : "shot"; size: 30; color: Theme.ink3 }
                        Text { anchors.horizontalCenter: parent.horizontalCenter
                            text: root.pill === "clips" ? "No exported clips here yet" : "No snapshots yet."
                            color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 14 }
                        Text { anchors.horizontalCenter: parent.horizontalCenter
                            text: root.pill === "clips" ? "Export a clip from playback or a synchronized wall selection."
                                                        : "Capture one from a live tile or from playback."
                            color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12 }
                    }
                }
            }

            // detail panel
            Rectangle {
                Layout.preferredWidth: 380
                Layout.fillHeight: true
                visible: root.sel !== null
                color: Theme.panel
                Rectangle { anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 1; color: Theme.line }
                ColumnLayout {
                    anchors.fill: parent; anchors.leftMargin: 1; spacing: 0
                    // header
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 56; color: Theme.panel
                        Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 10; spacing: 8
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 1
                                Text { text: root.sel ? root.sel.title : ""; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 14; font.weight: Font.DemiBold; elide: Text.ElideRight; Layout.fillWidth: true }
                                Text { text: !root.sel ? "" : ((root.sel._kind === "clip" ? (root.sel.kindLabel === "mosaic" ? "GRID CLIP" : "CAMERA CLIP") : "SNAPSHOT") + " · " + root.fmtCaptured(root.sel.capturedIso)); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11; elide: Text.ElideRight; Layout.fillWidth: true }
                            }
                            IconButton { name: "x"; iconColor: Theme.ink2; hoverIcon: Theme.ink; hoverBg: Theme.panel2; hoverBorder: Theme.line2; tip: "Close"; onClicked: root.sel = null }
                        }
                    }
                    // body
                    QC.ScrollView {
                        Layout.fillWidth: true; Layout.fillHeight: true; clip: true
                        contentWidth: availableWidth
                        ColumnLayout {
                            width: 380 - 1
                            spacing: 0
                            // 16:9 preview (the real image)
                            Rectangle {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 14
                                Layout.preferredHeight: width * 9 / 16
                                color: "#000"; border.width: 1; border.color: Theme.line2
                                // snapshots show the real image; clips (video) show a glyph + state
                                Image {
                                    anchors.fill: parent; anchors.margins: 1
                                    visible: root.sel && root.sel._kind === "snapshot"
                                    source: (root.sel && root.sel._kind === "snapshot") ? root.sel.fileUrl : ""
                                    fillMode: Image.PreserveAspectFit; asynchronous: true; sourceSize.width: 800
                                }
                                Column {
                                    anchors.centerIn: parent; spacing: 6
                                    visible: root.sel && root.sel._kind === "clip"
                                    Icon { anchors.horizontalCenter: parent.horizontalCenter
                                        name: (root.sel && root.sel.kindLabel === "mosaic") ? "layers" : "clip"; size: 32; color: Theme.ink3 }
                                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.sel ? root.sel.status : ""
                                        color: root.sel ? root.statusColor(root.sel.state) : Theme.ink3
                                        font.family: Theme.fontMono; font.pixelSize: 11; font.weight: Font.DemiBold }
                                }
                            }
                            component KV: RowLayout {
                                id: kv; property string k: ""; property string v: ""
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 6; spacing: 8
                                Text { text: kv.k; color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12; Layout.fillWidth: true }
                                Text { text: kv.v; color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 11; horizontalAlignment: Text.AlignRight; elide: Text.ElideRight }
                            }
                            Item { Layout.preferredHeight: 10 }
                            KV { k: "Type"; v: !root.sel ? "" : (root.sel._kind === "clip" ? (root.sel.kindLabel === "mosaic" ? "Combined grid clip (MP4)" : "Camera clip (MP4)") : "Snapshot (PNG)") }
                            KV { k: "Camera"; v: root.sel ? (root.sel.camera || "—") : "" }
                            KV { k: "Captured"; v: root.sel ? root.fmtCaptured(root.sel.capturedIso) : "" }
                            KV { k: "Size"; v: root.sel ? root.fmtSize(root.sel.bytes) : "" }
                            KV { k: "Resolution"; v: root.sel ? (root.sel.resolution || "—") : ""; visible: root.sel && root.sel._kind === "clip" }
                            KV { k: "Mode"; v: root.sel ? (root.sel.mode || "—") : ""; visible: root.sel && root.sel._kind === "clip" }
                            KV { k: "Status"; v: root.sel ? root.sel.status : ""; visible: root.sel && root.sel._kind === "clip" }
                            KV { k: "Group"; v: root.sel ? (root.sel.groupId || "—") : ""; visible: root.sel && root.sel._kind === "clip" && root.sel.groupId }
                            KV { k: "File"; v: root.sel ? root.sel.fileName : ""; visible: root.sel && root.sel._kind === "snapshot" }
                            // actions
                            Flow {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 14; Layout.bottomMargin: 14
                                spacing: 6
                                component ABtn: Rectangle {
                                    property string label: ""; property string icon: ""; property bool primary: false
                                    signal clicked()
                                    implicitHeight: 34; implicitWidth: arow.implicitWidth + 26
                                    color: primary ? (abMa.containsMouse ? "#f0b04e" : Theme.accent) : (abMa.containsMouse ? Theme.panel2 : Theme.bg)
                                    border.width: primary ? 0 : 1; border.color: abMa.containsMouse ? Theme.accent : Theme.line2
                                    Row { id: arow; anchors.centerIn: parent; spacing: 7
                                        Icon { visible: parent.parent.icon !== ""; anchors.verticalCenter: parent.verticalCenter; name: parent.parent.icon; size: 13; color: parent.parent.primary ? Theme.bg : Theme.ink }
                                        Text { anchors.verticalCenter: parent.verticalCenter; text: parent.parent.label; color: parent.parent.primary ? Theme.bg : Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
                                    }
                                    MouseArea { id: abMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: parent.clicked() }
                                }
                                ABtn { primary: true; icon: "newtab"; label: "Open"
                                    visible: root.sel && root.sel.openUrl !== ""
                                    onClicked: if (root.sel && root.sel.openUrl !== "") Qt.openUrlExternally(root.sel.openUrl) }
                                ABtn { icon: "clip"; label: "Reveal in folder"
                                    visible: root.sel && root.sel._kind === "snapshot"
                                    onClicked: if (root.snapshotModel) Qt.openUrlExternally("file://" + root.snapshotModel.dir) }
                            }
                        }
                    }
                }
            }
        }
    }
}
