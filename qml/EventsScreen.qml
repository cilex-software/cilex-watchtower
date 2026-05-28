import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as QC
import Watchtower

// Events & Alerts (S06 nav / design §6 + watchtower.html EventsScreen). Filter
// pills + a table of operational events, with an inline detail panel. Events come
// from EventModel (live cilex-vision /events, or WT_DEMO mock); camera names are
// resolved via CameraModel. Acknowledge is a local, persisted operator action —
// cilex-vision has no acknowledge endpoint yet (see docs/letters/).
//
// Functional filters: Unacknowledged + type (Motion/Offline/Bookmarks). The
// mock's Today/All-cameras/+Filter chips are deferred — we don't fake controls
// that have no data behind them (no per-event date scope, no camera picker yet).
Item {
    id: root

    property var eventModel: null
    property var cameraModel: null

    signal openPlayback(string camId)

    // active filters
    property bool fUnack: true          // default on (design)
    property bool fMotion: false
    property bool fOffline: false
    property bool fBookmark: false

    property var sel: null              // selected event map -> detail panel
    property var rows: []

    function eventIcon(type) {
        switch (type) {
        case "motion": return "motion";
        case "offline": return "off";
        case "online": return "check";
        case "gap": return "alert";
        case "bookmark": return "bookmark";
        default: return "alert";
        }
    }
    function eventColor(type) {
        switch (type) {
        case "offline": return Theme.bad;
        case "online": return Theme.good;
        case "bookmark": return Theme.violet;
        default: return Theme.accent;   // motion, gap
        }
    }
    function camDisplay(ev) {
        var r = root.cameraModel ? root.cameraModel.cameraByBackendId(ev.camId) : null;
        return (r && r.name) ? r.name : (ev.camName ? ev.camName : ev.camId);
    }
    function groupDisplay(ev) {
        var r = root.cameraModel ? root.cameraModel.cameraByBackendId(ev.camId) : null;
        return (r && r.groupName) ? r.groupName : (ev.group ? ev.group : "—");
    }

    function filtered() {
        var all = root.eventModel ? root.eventModel.all() : [];
        var types = [];
        if (root.fMotion) types.push("motion");
        if (root.fOffline) types.push("offline");
        if (root.fBookmark) types.push("bookmark");
        var out = [];
        for (var i = 0; i < all.length; i++) {
            var e = all[i];
            if (root.fUnack && e.ack) continue;
            if (types.length && types.indexOf(e.type) < 0) continue;
            out.push(e);
        }
        return out;
    }
    function recompute() {
        root.rows = filtered();
        // keep the selected event in sync with the refreshed data (e.g. after ack)
        if (root.sel) {
            var found = null;
            var all = root.eventModel ? root.eventModel.all() : [];
            for (var i = 0; i < all.length; i++)
                if (all[i].eventId === root.sel.eventId) { found = all[i]; break; }
            root.sel = found;
        }
    }
    onFUnackChanged: recompute()
    onFMotionChanged: recompute()
    onFOfflineChanged: recompute()
    onFBookmarkChanged: recompute()
    Component.onCompleted: recompute()
    onVisibleChanged: if (visible && root.eventModel) root.eventModel.refresh()
    Connections {
        target: root.eventModel
        enabled: root.eventModel !== null
        function onChanged() { root.recompute() }
    }

    // shared button
    component Btn: Rectangle {
        id: b
        property string label: ""
        property string icon: ""
        property bool primary: false
        property bool ghost: false
        property bool small: false
        signal clicked()
        implicitHeight: b.small ? 24 : 34
        implicitWidth: brow.implicitWidth + (b.small ? 16 : 26)
        color: b.primary ? (bma.containsMouse ? "#f0b04e" : Theme.accent)
                         : b.ghost ? (bma.containsMouse ? Theme.panel : "transparent")
                                   : (bma.containsMouse ? Theme.panel : Theme.bg)
        border.width: (b.primary || b.ghost) ? 0 : 1
        border.color: bma.containsMouse ? Theme.accent : Theme.line2
        Row {
            id: brow; anchors.centerIn: parent; spacing: 7
            Icon { visible: b.icon !== ""; anchors.verticalCenter: parent.verticalCenter; name: b.icon; size: b.small ? 12 : 13; color: b.primary ? Theme.bg : (b.ghost ? Theme.ink2 : Theme.ink) }
            Text { anchors.verticalCenter: parent.verticalCenter; text: b.label; color: b.primary ? Theme.bg : (b.ghost ? Theme.ink2 : Theme.ink); font.family: Theme.fontSans; font.pixelSize: b.small ? 11 : 12; font.weight: b.primary ? Font.DemiBold : Font.Medium }
        }
        MouseArea { id: bma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: b.clicked() }
    }
    // filter pill
    component Pill: Rectangle {
        id: p
        property string label: ""
        property bool on: false
        signal toggled()
        implicitHeight: 30
        implicitWidth: prow.implicitWidth + 24
        color: p.on ? Theme.accentSoft : (pma.containsMouse ? Theme.panel2 : Theme.panel)
        border.width: 1
        border.color: p.on ? Theme.accent : (pma.containsMouse ? Theme.ink3 : Theme.line2)
        Row {
            id: prow; anchors.centerIn: parent; spacing: 6
            Text { anchors.verticalCenter: parent.verticalCenter; text: p.label; color: p.on ? Theme.accent : Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
            Text { anchors.verticalCenter: parent.verticalCenter; visible: p.on; text: "×"; color: p.on ? Theme.accent : Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 12 }
        }
        MouseArea { id: pma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: p.toggled() }
    }

    // column widths (header + rows share these; Event column fills the rest)
    readonly property int wIcon: 36
    readonly property int wCam: 200
    readonly property int wGroup: 150
    readonly property int wTime: 110
    readonly property int wStatus: 170
    readonly property int wAct: 116

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ===== sub-bar: filter pills + Clear all =====
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 56
            color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 16; spacing: 6
                Pill { label: "Unacknowledged"; on: root.fUnack; onToggled: root.fUnack = !root.fUnack }
                Pill { label: "Motion"; on: root.fMotion; onToggled: root.fMotion = !root.fMotion }
                Pill { label: "Offline"; on: root.fOffline; onToggled: root.fOffline = !root.fOffline }
                Pill { label: "Bookmarks"; on: root.fBookmark; onToggled: root.fBookmark = !root.fBookmark }
                Item { Layout.fillWidth: true }
                Btn { ghost: true; label: "Clear all"; onClicked: { root.fUnack = false; root.fMotion = false; root.fOffline = false; root.fBookmark = false } }
            }
        }

        // ===== table + detail =====
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // ---- table ----
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
                        color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                        font.weight: Font.DemiBold; font.letterSpacing: 1.2; font.capitalization: Font.AllUppercase
                    }
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 0
                        Th { text: ""; Layout.preferredWidth: root.wIcon }
                        Th { text: "Event"; Layout.fillWidth: true }
                        Th { text: "Camera"; Layout.preferredWidth: root.wCam }
                        Th { text: "Group"; Layout.preferredWidth: root.wGroup }
                        Th { text: "Time"; Layout.preferredWidth: root.wTime }
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
                        height: 54
                        readonly property bool isSel: root.sel && root.sel.eventId === modelData.eventId
                        color: isSel ? Theme.accentSoft : (rowMa.containsMouse ? Theme.panel : "transparent")
                        Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
                        MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.sel = modelData }

                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 0
                            // type icon
                            Item { Layout.preferredWidth: root.wIcon; Layout.fillHeight: true
                                Icon { anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; name: root.eventIcon(rowItem.modelData.type); size: 16; color: root.eventColor(rowItem.modelData.type) } }
                            // Event (desc + TYPE)
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 1
                                Text { text: rowItem.modelData.desc; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13; elide: Text.ElideRight; Layout.fillWidth: true }
                                Text { text: ("" + rowItem.modelData.type).toUpperCase(); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 0.6; Layout.fillWidth: true }
                            }
                            // Camera (name + id)
                            ColumnLayout {
                                Layout.preferredWidth: root.wCam; spacing: 1
                                Text { text: root.camDisplay(rowItem.modelData); color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12; elide: Text.ElideRight; Layout.fillWidth: true }
                                Text { text: rowItem.modelData.camId; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10; elide: Text.ElideRight; Layout.fillWidth: true }
                            }
                            // Group
                            Text { Layout.preferredWidth: root.wGroup; text: root.groupDisplay(rowItem.modelData); color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12; elide: Text.ElideRight }
                            // Time
                            Text { Layout.preferredWidth: root.wTime; text: rowItem.modelData.time; color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 12 }
                            // Status
                            Item { Layout.preferredWidth: root.wStatus; Layout.fillHeight: true
                                // acknowledged
                                Column {
                                    anchors.verticalCenter: parent.verticalCenter; spacing: 1
                                    visible: rowItem.modelData.ack
                                    Row { spacing: 4
                                        Icon { anchors.verticalCenter: parent.verticalCenter; name: "check"; size: 12; color: Theme.accent }
                                        Text { anchors.verticalCenter: parent.verticalCenter; text: "Acknowledged"; color: Theme.accent; font.family: Theme.fontSans; font.pixelSize: 11 }
                                    }
                                    Text { text: (rowItem.modelData.ackBy ? rowItem.modelData.ackBy : "") + (rowItem.modelData.ackTime ? ("  ·  " + rowItem.modelData.ackTime) : ""); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                                }
                                // new
                                Row {
                                    anchors.verticalCenter: parent.verticalCenter; spacing: 6
                                    visible: !rowItem.modelData.ack
                                    Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 6; height: 6; radius: 3; color: Theme.bad }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: "NEW"; color: Theme.bad; font.family: Theme.fontSans; font.pixelSize: 11; font.weight: Font.DemiBold }
                                }
                            }
                            // action
                            Item { Layout.preferredWidth: root.wAct; Layout.fillHeight: true
                                Btn { anchors.verticalCenter: parent.verticalCenter; small: true; ghost: true; icon: "clip"; label: "Playback"; onClicked: root.openPlayback(rowItem.modelData.camId) } }
                        }
                    }

                    // empty / loading state
                    Column {
                        anchors.centerIn: parent
                        spacing: 6
                        visible: root.rows.length === 0
                        Icon { anchors.horizontalCenter: parent.horizontalCenter; name: (root.eventModel && root.eventModel.loading) ? "pulse" : "check"; size: 28; color: Theme.ink3 }
                        Text { anchors.horizontalCenter: parent.horizontalCenter
                            text: (root.eventModel && root.eventModel.loading) ? "Loading events…"
                                  : ((root.eventModel && root.eventModel.total > 0) ? "No events match these filters." : "No events recorded.")
                            color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 13 }
                    }
                }
            }

            // ---- detail panel ----
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
                                Text { text: root.sel ? root.sel.desc : ""; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 14; font.weight: Font.DemiBold; elide: Text.ElideRight; Layout.fillWidth: true }
                                Text { text: root.sel ? (("" + root.sel.type).toUpperCase() + "  ·  " + root.sel.time) : ""; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11; elide: Text.ElideRight; Layout.fillWidth: true }
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

                            // 16:9 preview with a play affordance
                            Rectangle {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 14
                                Layout.preferredHeight: width * 9 / 16
                                color: "#000"
                                PlaceholderVid {
                                    anchors.fill: parent
                                    pattern: 2
                                    geom: "parking"
                                    ts: root.sel ? root.sel.time : ""
                                    label: root.sel ? root.sel.camId : ""
                                }
                                Rectangle {
                                    anchors.centerIn: parent
                                    width: 44; height: 44; radius: 22
                                    color: Qt.rgba(11 / 255, 14 / 255, 18 / 255, 0.85)
                                    border.width: 1; border.color: Theme.line2
                                    Icon { anchors.centerIn: parent; name: "play"; size: 18; color: "#fff" }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: if (root.sel) root.openPlayback(root.sel.camId) }
                                }
                            }

                            // KV facts
                            component KV: RowLayout {
                                id: kv; property string k: ""; property string v: ""; property color vColor: Theme.ink
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 6; spacing: 8
                                Text { text: kv.k; color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12; Layout.fillWidth: true }
                                Text { text: kv.v; color: kv.vColor; font.family: Theme.fontMono; font.pixelSize: 11; horizontalAlignment: Text.AlignRight; elide: Text.ElideRight }
                            }
                            Item { Layout.preferredHeight: 10 }
                            KV { k: "Camera"; v: root.sel ? root.camDisplay(root.sel) : "" }
                            KV { k: "Group"; v: root.sel ? root.groupDisplay(root.sel) : "" }
                            KV { k: "Time"; v: root.sel ? root.sel.time : "" }
                            KV { k: "Status"; v: root.sel ? (root.sel.ack ? "ACKNOWLEDGED" : "NEW") : ""; vColor: root.sel && root.sel.ack ? Theme.accent : Theme.bad }
                            KV { k: "Acknowledged by"; v: root.sel ? root.sel.ackBy : ""; visible: root.sel && root.sel.ack }
                            KV { k: "Acknowledged at"; v: root.sel ? root.sel.ackTime : ""; visible: root.sel && root.sel.ack }

                            // actions
                            Flow {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 14; Layout.bottomMargin: 14
                                spacing: 6
                                Btn { primary: true; icon: "clip"; label: "Open playback"; onClicked: if (root.sel) root.openPlayback(root.sel.camId) }
                                Btn { icon: "check"; label: "Acknowledge"; visible: root.sel && !root.sel.ack; onClicked: if (root.sel && root.eventModel) root.eventModel.acknowledgeById(root.sel.eventId) }
                            }
                        }
                    }
                }
            }
        }
    }
}
