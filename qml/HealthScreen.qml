import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as QC
import Watchtower

// Health (S07) — design handoff README §7 + watchtower.html HealthScreen.
// A full-width strip of 6 stat cards over CameraModel's live counts, a camera
// table filtered by the active card, and a 380px detail panel. This is a pure
// view over CameraModel — camera live/recording status is whatever the store
// holds (from provisioning import), the same source the rest of the app uses;
// there is no separate live health feed yet, so we never fabricate durations.
Item {
    id: root

    property var cameraModel: null

    signal openLive(var cam)
    signal openPlayback(var cam)
    signal openEvents(var cam)

    property string activeFilter: ""           // default to Visible (all) — real fleets are mostly healthy, so an Offline default (per the mock) would open empty
    property var sel: null                     // selected camera map -> detail panel

    // table rows for the active filter (status-sorted; all of them — the table scrolls)
    readonly property var rows: cameraModel
        ? cameraModel.page("", activeFilter, "status", 1, 100000) : []

    // column widths (header + row delegate share these; Camera column fills the rest)
    readonly property int wGroup: 150
    readonly property int wLive: 110
    readonly property int wRec: 110
    readonly property int wSeen: 110
    readonly property int wIssue: 220
    readonly property int wAct: 72

    function liveText(s) {
        switch (s) {
        case CameraStatus.Live: return "Live";
        case CameraStatus.Offline: return "Offline";
        case CameraStatus.Degraded: return "Degraded";
        case CameraStatus.NoSignal: return "No signal";
        case CameraStatus.Loading: return "Loading";
        default: return "Unknown";
        }
    }
    function recText(s) {
        switch (s) {
        case CameraStatus.Recording: return "Recording";
        case CameraStatus.NotRecording: return "Not recording";
        case CameraStatus.RecordingGap: return "Recording gap";
        default: return "Unknown";
        }
    }
    function issueText(cam) {
        if (cam.live === CameraStatus.Offline || cam.live === CameraStatus.NoSignal) return "No signal";
        if (cam.recording === CameraStatus.RecordingGap) return "Recent recording gap";
        if (cam.live === CameraStatus.Degraded) return "Stream degraded";
        if (cam.recording === CameraStatus.NotRecording) return "Live but not recording";
        return "—";
    }
    function issueColor(cam) {
        if (cam.live === CameraStatus.Offline || cam.live === CameraStatus.NoSignal) return Theme.bad;
        if (cam.live === CameraStatus.Degraded || cam.recording === CameraStatus.NotRecording
            || cam.recording === CameraStatus.RecordingGap) return Theme.warn;
        return Theme.ink3;
    }
    function calloutColor(cam) {
        if (cam.live === CameraStatus.Offline || cam.live === CameraStatus.NoSignal) return Theme.bad;
        if (cam.live === CameraStatus.Degraded || cam.recording === CameraStatus.NotRecording
            || cam.recording === CameraStatus.RecordingGap) return Theme.warn;
        if (cam.live === CameraStatus.Live && cam.recording === CameraStatus.Recording) return Theme.accent;
        if (cam.live === CameraStatus.Live) return Theme.good;   // live, recording not reported
        return Theme.ink3;
    }
    function calloutText(cam) {
        if (cam.live === CameraStatus.Offline || cam.live === CameraStatus.NoSignal)
            return "<b>Camera is offline.</b> " + (cam.lastSeen ? ("Last seen " + cam.lastSeen + ". ") : "")
                 + "Playback may still be available for footage recorded before the outage.";
        if (cam.live === CameraStatus.Live && cam.recording === CameraStatus.NotRecording)
            return "<b>Camera is live but not recording.</b> Live monitoring works; no new footage is being saved.";
        if (cam.recording === CameraStatus.RecordingGap)
            return "<b>Recording gap detected.</b> Some footage in the recent window is missing.";
        if (cam.live === CameraStatus.Degraded)
            return "<b>Stream degraded.</b> Reduced bitrate due to network conditions; recording continues.";
        if (cam.live === CameraStatus.Live && cam.recording === CameraStatus.Recording)
            return "<b>Camera is live and recording.</b> No issues detected.";
        if (cam.live === CameraStatus.Live)
            return "<b>Camera is live.</b> Recording status isn't being reported for this camera.";
        return "<b>Status unknown.</b> No recent health signal for this camera.";
    }
    readonly property bool selOffline: sel && (sel.live === CameraStatus.Offline || sel.live === CameraStatus.NoSignal)

    // shared button
    component Btn: Rectangle {
        id: b
        property string label: ""
        property string icon: ""
        property bool ghost: false
        property bool small: false
        signal clicked()
        implicitHeight: b.small ? 24 : 34
        implicitWidth: brow.implicitWidth + (b.small ? 16 : 26)
        color: b.ghost ? (bma.containsMouse ? Theme.panel : "transparent")
                       : (bma.containsMouse ? Theme.panel : Theme.bg)
        border.width: b.ghost ? 0 : 1
        border.color: bma.containsMouse ? Theme.accent : Theme.line2
        Row {
            id: brow; anchors.centerIn: parent; spacing: 7
            Icon { visible: b.icon !== ""; anchors.verticalCenter: parent.verticalCenter; name: b.icon; size: 13; color: b.ghost ? Theme.ink2 : Theme.ink }
            Text { anchors.verticalCenter: parent.verticalCenter; text: b.label; color: b.ghost ? Theme.ink2 : Theme.ink; font.family: Theme.fontSans; font.pixelSize: b.small ? 11 : 12; font.weight: Font.Medium }
        }
        MouseArea { id: bma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: b.clicked() }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ===== stat cards strip =====
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 84
            color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }

            component Card: Item {
                id: card
                property string key: ""
                property string label: ""
                property int value: 0
                property color numColor: Theme.ink
                property bool last: false
                Layout.fillWidth: true
                Layout.fillHeight: true
                readonly property bool active: root.activeFilter === card.key
                Rectangle {
                    anchors.fill: parent
                    color: (card.active || cardMa.containsMouse) ? Theme.panel : Theme.bg
                    Rectangle { visible: !card.last; anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 1; color: Theme.line }
                    Rectangle { visible: card.active; anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; height: 3; color: Theme.accent }
                    Column {
                        anchors.left: parent.left; anchors.top: parent.top
                        anchors.leftMargin: 18; anchors.topMargin: card.active ? 15 : 18
                        spacing: 8
                        Text { text: card.value; color: card.numColor; font.family: Theme.fontSans; font.pixelSize: 32; font.weight: Font.Bold; font.letterSpacing: -1 }
                        Text { text: card.label; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.DemiBold; font.letterSpacing: 1.4; font.capitalization: Font.AllUppercase }
                    }
                    MouseArea { id: cardMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.activeFilter = card.key; root.sel = null } }
                }
            }

            RowLayout {
                anchors.fill: parent
                spacing: 0
                Card { key: "";         label: "Visible";       value: root.cameraModel ? root.cameraModel.total : 0;            numColor: Theme.ink }
                Card { key: "online";   label: "Online";        value: root.cameraModel ? root.cameraModel.onlineCount : 0;      numColor: Theme.good }
                Card { key: "offline";  label: "Offline";       value: root.cameraModel ? root.cameraModel.offlineCount : 0;     numColor: Theme.bad }
                Card { key: "degraded"; label: "Degraded";      value: root.cameraModel ? root.cameraModel.degradedCount : 0;    numColor: Theme.accent }
                Card { key: "notrec";   label: "Not recording"; value: root.cameraModel ? root.cameraModel.notRecordingCount : 0; numColor: Theme.accent }
                Card { key: "gap";      label: "Recent gaps";   value: root.cameraModel ? root.cameraModel.recordingGapCount : 0; numColor: Theme.accent; last: true }
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
                        Th { text: "Camera"; Layout.fillWidth: true }
                        Th { text: "Group"; Layout.preferredWidth: root.wGroup }
                        Th { text: "Live"; Layout.preferredWidth: root.wLive }
                        Th { text: "Recording"; Layout.preferredWidth: root.wRec }
                        Th { text: "Last seen"; Layout.preferredWidth: root.wSeen }
                        Th { text: "Recent issue"; Layout.preferredWidth: root.wIssue }
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
                        required property int index
                        width: ListView.view.width
                        height: 52
                        readonly property bool isSel: root.sel && root.sel.camId === modelData.camId
                        color: isSel ? Theme.accentSoft : (rowMa.containsMouse ? Theme.panel : "transparent")
                        Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }

                        MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.sel = modelData }

                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 0
                            // Camera
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 1
                                Text { text: rowItem.modelData.name; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13; font.weight: Font.DemiBold; elide: Text.ElideRight; Layout.fillWidth: true }
                                Text { text: rowItem.modelData.camId; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10; elide: Text.ElideRight; Layout.fillWidth: true }
                            }
                            // Group
                            Text { Layout.preferredWidth: root.wGroup; text: rowItem.modelData.groupName; color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12; elide: Text.ElideRight }
                            // Live
                            Item { Layout.preferredWidth: root.wLive; Layout.fillHeight: true
                                LiveStatusBadge { anchors.verticalCenter: parent.verticalCenter; state: rowItem.modelData.live } }
                            // Recording
                            Item { Layout.preferredWidth: root.wRec; Layout.fillHeight: true
                                RecordingStatusBadge { anchors.verticalCenter: parent.verticalCenter; state: rowItem.modelData.recording } }
                            // Last seen
                            Text { Layout.preferredWidth: root.wSeen; color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 12
                                text: (rowItem.modelData.live === CameraStatus.Offline || rowItem.modelData.live === CameraStatus.NoSignal)
                                      ? (rowItem.modelData.lastSeen ? rowItem.modelData.lastSeen : "—") : "now" }
                            // Recent issue
                            Text { Layout.preferredWidth: root.wIssue; color: root.issueColor(rowItem.modelData); font.family: Theme.fontSans; font.pixelSize: 11; elide: Text.ElideRight; text: root.issueText(rowItem.modelData) }
                            // action
                            Item { Layout.preferredWidth: root.wAct; Layout.fillHeight: true
                                Btn { anchors.verticalCenter: parent.verticalCenter; small: true; ghost: true; label: "Open"; onClicked: root.openLive(rowItem.modelData) } }
                        }
                    }

                    // empty state
                    EmptyState {
                        anchors.centerIn: parent
                        visible: root.rows.length === 0
                        icon: "check"
                        title: "Nothing here"
                        subtitle: "No cameras match this filter."
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
                    anchors.fill: parent
                    anchors.leftMargin: 1
                    spacing: 0

                    // header
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 56; color: Theme.panel
                        Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 10; spacing: 8
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 1
                                Text { text: root.sel ? root.sel.name : ""; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 14; font.weight: Font.DemiBold; elide: Text.ElideRight; Layout.fillWidth: true }
                                Text { text: root.sel ? (root.sel.camId + "  ·  " + root.sel.groupName) : ""; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11; elide: Text.ElideRight; Layout.fillWidth: true }
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

                            // 16:9 preview
                            Rectangle {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 14
                                Layout.preferredHeight: (width) * 9 / 16
                                color: "#000"
                                // offline -> NO SIGNAL, else placeholder schematic
                                Rectangle {
                                    anchors.fill: parent; visible: root.selOffline; color: "#0a0d11"
                                    Column {
                                        anchors.centerIn: parent; spacing: 4
                                        Icon { anchors.horizontalCenter: parent.horizontalCenter; name: "off"; size: 28; color: Theme.bad }
                                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "NO SIGNAL"; color: Theme.bad; font.family: Theme.fontMono; font.pixelSize: 13; font.letterSpacing: 1.3 }
                                        Text { anchors.horizontalCenter: parent.horizontalCenter; visible: root.sel && root.sel.lastSeen; text: root.sel ? ("last seen " + root.sel.lastSeen) : ""; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                                    }
                                }
                                PlaceholderVid {
                                    anchors.fill: parent; visible: !root.selOffline
                                    pattern: root.sel ? (root.sel.pattern || 0) : 0
                                    geom: "lobby"
                                    label: root.sel ? root.sel.camId : ""
                                }
                                // badges
                                Row {
                                    anchors.top: parent.top; anchors.left: parent.left; anchors.margins: 6; spacing: 4
                                    LiveStatusBadge { state: root.sel ? root.sel.live : CameraStatus.LiveUnknown }
                                    RecordingStatusBadge { state: root.sel ? root.sel.recording : CameraStatus.RecUnknown }
                                }
                            }

                            // status callout
                            Rectangle {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 12
                                color: Theme.bg
                                implicitHeight: calloutText.implicitHeight + 20
                                Rectangle { anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 3; color: root.sel ? root.calloutColor(root.sel) : Theme.ink3 }
                                Text {
                                    id: calloutText
                                    anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: 12; anchors.rightMargin: 12
                                    textFormat: Text.StyledText; wrapMode: Text.WordWrap
                                    text: root.sel ? root.calloutText(root.sel) : ""
                                    color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12; lineHeight: 1.35
                                }
                            }

                            // KV facts
                            component KV: RowLayout {
                                id: kv; property string k: ""; property string v: ""
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 6; spacing: 8
                                Text { text: kv.k; color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12; Layout.fillWidth: true }
                                Text { text: kv.v; color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 11; horizontalAlignment: Text.AlignRight; elide: Text.ElideRight }
                            }
                            Item { Layout.preferredHeight: 8 }
                            KV { k: "Live status"; v: root.sel ? root.liveText(root.sel.live) : "" }
                            KV { k: "Recording status"; v: root.sel ? root.recText(root.sel.recording) : "" }
                            KV { k: "Last seen"; v: root.sel ? (root.selOffline ? (root.sel.lastSeen ? root.sel.lastSeen : "—") : "now") : "" }
                            KV { k: "Last available footage"; v: "—" }
                            KV { k: "Group"; v: root.sel ? root.sel.groupName : "" }

                            // actions
                            Flow {
                                Layout.fillWidth: true; Layout.leftMargin: 14; Layout.rightMargin: 14; Layout.topMargin: 14; Layout.bottomMargin: 14
                                spacing: 6
                                Btn { icon: "monitor"; label: "Open live"; onClicked: if (root.sel) root.openLive(root.sel) }
                                Btn { icon: "clip"; label: "Playback"; onClicked: if (root.sel) root.openPlayback(root.sel) }
                                Btn { icon: "bell"; label: "Events"; ghost: true; onClicked: if (root.sel) root.openEvents(root.sel) }
                            }
                        }
                    }
                }
            }
        }
    }
}
