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

    property string pill: "all"          // all | snapshots | clips
    property var sel: null
    property var rows: []

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
    function recompute() {
        var snaps = (root.snapshotModel && root.pill !== "clips") ? root.snapshotModel.all() : [];
        root.rows = snaps;
        if (root.sel) {
            var found = null;
            for (var i = 0; i < root.rows.length; i++) if (root.rows[i].filePath === root.sel.filePath) { found = root.rows[i]; break; }
            root.sel = found;
        }
    }
    onPillChanged: recompute()
    Component.onCompleted: { if (snapshotModel) snapshotModel.refresh(); recompute() }
    onVisibleChanged: if (visible && snapshotModel) { snapshotModel.refresh(); recompute() }
    Connections {
        target: root.snapshotModel
        enabled: root.snapshotModel !== null
        function onChanged() { root.recompute() }
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
                Pill { label: "Clips · 0"; on: root.pill === "clips"; onClicked: root.pill = "clips" }
                Item { Layout.fillWidth: true }
                Text { text: "Server clips pending backend list endpoint"; color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11 }
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
                        readonly property bool isSel: root.sel && root.sel.filePath === modelData.filePath
                        color: isSel ? Theme.accentSoft : (rowMa.containsMouse ? Theme.panel : "transparent")
                        Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
                        MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.sel = modelData }
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 0
                            Item { Layout.preferredWidth: root.wGlyph; Layout.fillHeight: true
                                Icon { anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; name: "shot"; size: 16; color: Theme.ink2 } }
                            Text { Layout.fillWidth: true; text: rowItem.modelData.title; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13; font.weight: Font.Medium; elide: Text.ElideRight }
                            Text { Layout.preferredWidth: root.wCam; text: rowItem.modelData.camera || "—"; color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11; elide: Text.ElideRight }
                            Text { Layout.preferredWidth: root.wWhen; text: root.fmtCaptured(rowItem.modelData.capturedIso); color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11 }
                            Text { Layout.preferredWidth: root.wSize; text: root.fmtSize(rowItem.modelData.bytes); color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11 }
                            Text { Layout.preferredWidth: root.wStatus; text: "READY"; color: Theme.good; font.family: Theme.fontMono; font.pixelSize: 11; font.weight: Font.DemiBold }
                            Item { Layout.preferredWidth: root.wAct; Layout.fillHeight: true
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter; implicitWidth: opT.implicitWidth + 16; implicitHeight: 24
                                    color: opMa.containsMouse ? Theme.panel2 : "transparent"; border.width: 1; border.color: opMa.containsMouse ? Theme.accent : Theme.line2
                                    Text { id: opT; anchors.centerIn: parent; text: "Open"; color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 11 }
                                    MouseArea { id: opMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: Qt.openUrlExternally(rowItem.modelData.fileUrl) }
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
                            text: root.pill === "clips" ? "Server-side clip exports will list here once Cilex Vision adds a list endpoint."
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
                                Text { text: root.sel ? ("SNAPSHOT · " + root.fmtCaptured(root.sel.capturedIso)) : ""; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11; elide: Text.ElideRight; Layout.fillWidth: true }
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
                                Image { anchors.fill: parent; anchors.margins: 1; source: root.sel ? root.sel.fileUrl : ""; fillMode: Image.PreserveAspectFit; asynchronous: true; sourceSize.width: 800 }
                            }
                            component KV: RowLayout {
                                id: kv; property string k: ""; property string v: ""
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 6; spacing: 8
                                Text { text: kv.k; color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12; Layout.fillWidth: true }
                                Text { text: kv.v; color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 11; horizontalAlignment: Text.AlignRight; elide: Text.ElideRight }
                            }
                            Item { Layout.preferredHeight: 10 }
                            KV { k: "Type"; v: "Snapshot (PNG)" }
                            KV { k: "Camera"; v: root.sel ? (root.sel.camera || "—") : "" }
                            KV { k: "Captured"; v: root.sel ? root.fmtCaptured(root.sel.capturedIso) : "" }
                            KV { k: "Size"; v: root.sel ? root.fmtSize(root.sel.bytes) : "" }
                            KV { k: "File"; v: root.sel ? root.sel.fileName : "" }
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
                                ABtn { primary: true; icon: "newtab"; label: "Open"; onClicked: if (root.sel) Qt.openUrlExternally(root.sel.fileUrl) }
                                ABtn { icon: "clip"; label: "Reveal in folder"; onClicked: if (root.snapshotModel) Qt.openUrlExternally("file://" + root.snapshotModel.dir) }
                            }
                        }
                    }
                }
            }
        }
    }
}
