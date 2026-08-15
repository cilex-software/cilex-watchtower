import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C
import Watchtower

// Right-docked operations sidebar (320px), Live Monitor only (design §10). Site
// status 2×2 + a scrolling Live Events feed. Hidden in full-screen mode.
Item {
    id: root

    property var cameraModel: null
    property var eventModel: null

    signal eventActivated(int row)
    signal viewAllEvents()

    implicitWidth: Theme.opsSidebarWidth

    function eventIcon(type) { return EventStyle.icon(type); }
    function eventColor(type) { return EventStyle.color(type); }

    // Still-fetch state per event id, held on the ROOT so it survives ListView delegate
    // recycling — a recycled delegate re-assigns `source` and would otherwise restart
    // the whole attempt sequence every time a row scrolls back into view.
    //
    // Why retry at all: measured 2026-08-15, `events/{id}/snapshot` answers the newest
    // events with
    //     503 {"detail":"Footage for this event is still being written/uploaded"}
    //     Retry-After: 30
    // That is a NOT YET, not a failure — and this rail shows the 14 most recent events,
    // i.e. exactly the ones whose footage is still being flushed. Giving up on the first
    // error would guarantee a permanently empty rail. (CvImageProvider retries 503
    // internally but clamps Retry-After to 5 s and stops after 3 tries, so all of its
    // attempts land inside the first ~15 s of a 30 s wait and cannot succeed here.)
    // Two separate counters, deliberately. `_stillGen` keys the request URL and is bumped
    // ONLY by the retry timer — binding the URL to the failure count instead would make
    // every error rewrite the source and refetch immediately, i.e. a hot retry loop.
    // `_stillFails` counts errors however they arrive and drives the give-up latch; it
    // must be independent because the feed re-polls every 15 s and rebuilds all
    // delegates, which resets any per-delegate state and would otherwise mean an event
    // that can never produce a still is re-requested forever.
    property var _stillGen: ({})         // evId -> request generation (URL cache-buster)
    property var _stillFails: ({})       // evId -> errors seen, across delegate rebuilds
    property var _stillFailed: ({})      // evId -> true once we have stopped trying
    readonly property int _stillMaxTries: 4
    function _bumpStillGen(evId) {
        var g = {};
        for (var k in _stillGen) g[k] = _stillGen[k];
        g[evId] = (g[evId] || 0) + 1;
        _stillGen = g;
    }
    function _noteStillFail(evId) {      // returns the new failure count
        var f = {};
        for (var k in _stillFails) f[k] = _stillFails[k];
        f[evId] = (f[evId] || 0) + 1;
        _stillFails = f;
        return f[evId];
    }
    function _noteStillFailed(evId, url) {
        if (!evId || _stillFailed[evId]) return;
        var d = {};
        for (var k in _stillFailed) d[k] = _stillFailed[k];
        d[evId] = true;
        _stillFailed = d;
        // Log the URL, not just the code. The 2026-08-15 thumbnail investigation had to
        // ask CV which endpoint we were calling because we only ever recorded the status.
        console.warn("[EVRAIL] gave up on event still after "
                     + (_stillFails[evId] || 0) + " attempts: " + url);
    }
    function relTime(tsMs) {
        if (!tsMs || tsMs <= 0) return "";
        var s = Math.max(0, (Date.now() - tsMs) / 1000);
        if (s < 60) return qsTr("now");
        if (s < 3600) return Math.floor(s / 60) + qsTr("m");
        if (s < 86400) return Math.floor(s / 3600) + qsTr("h");
        return Math.floor(s / 86400) + qsTr("d");
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.bg
        Rectangle {
            anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
            width: 1
            color: Theme.line
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.leftMargin: 1   // clear the left hairline
            spacing: 0

            // ---- Site Status header ----
            Text {
                Layout.fillWidth: true
                Layout.topMargin: 14
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                Layout.bottomMargin: 8
                text: qsTr("Site Status")
                color: Theme.ink3
                font.family: Theme.fontMono
                font.pixelSize: 10
                font.weight: Font.DemiBold
                font.letterSpacing: 1.6
                font.capitalization: Font.AllUppercase
            }

            // ---- 2×2 stats ----
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: stats.implicitHeight + 2
                color: Theme.line
                // Grid POSITIONER (not GridLayout): QQuickGridLayout SIGSEGVs on minimize/restore in
                // Qt 6.4.2 (see LiveMonitor camera grid). Cells get an explicit equal width.
                Grid {
                    id: stats
                    anchors.fill: parent
                    anchors.margins: 1
                    columns: 2
                    rowSpacing: 1
                    columnSpacing: 1

                    component StatCell: Rectangle {
                        id: cell
                        property string lbl: ""
                        property int value: 0
                        property color valueColor: Theme.ink
                        width: (stats.width - stats.columnSpacing) / 2
                        height: 64
                        color: Theme.bg
                        Column {
                            anchors { left: parent.left; top: parent.top; leftMargin: 14; topMargin: 12 }
                            spacing: 4
                            Text {
                                text: cell.lbl
                                color: Theme.ink3
                                font.family: Theme.fontMono
                                font.pixelSize: 10
                                font.letterSpacing: 1.0
                                font.capitalization: Font.AllUppercase
                            }
                            Text {
                                text: cell.value
                                color: cell.valueColor
                                font.family: Theme.fontSans
                                font.pixelSize: 22
                                font.weight: Font.Bold
                                font.letterSpacing: -0.44
                            }
                        }
                    }

                    StatCell { lbl: qsTr("Online");   value: root.cameraModel ? root.cameraModel.onlineCount : 0;       valueColor: Theme.good }
                    StatCell { lbl: qsTr("Offline");  value: root.cameraModel ? root.cameraModel.offlineCount : 0;      valueColor: Theme.bad }
                    StatCell { lbl: qsTr("Degraded"); value: root.cameraModel ? root.cameraModel.degradedCount : 0;     valueColor: Theme.warn }
                    StatCell { lbl: qsTr("Not rec");  value: root.cameraModel ? root.cameraModel.notRecordingCount : 0; valueColor: Theme.warn }
                }
            }

            // ---- Live Events header ----
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 16
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                Layout.bottomMargin: 8
                Text {
                    Layout.fillWidth: true
                    text: qsTr("Live Events")
                    color: Theme.ink3
                    font.family: Theme.fontMono
                    font.pixelSize: 10
                    font.weight: Font.DemiBold
                    font.letterSpacing: 1.6
                    font.capitalization: Font.AllUppercase
                }
                Text {
                    text: qsTr("View all →")
                    color: Theme.accent
                    font.family: Theme.fontSans
                    font.pixelSize: 11
                    MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: root.viewAllEvents() }
                }
            }

            // ---- event feed: one row per motion INCIDENT, real mid-event still ----
            // (CV spec 2026-07-10: substance mirrored — mid-incident thumbnails via the
            // governed /events/{id}/snapshot?pos=mid, IP-first camera line, one row per
            // incident — rendered in Watchtower's own style. Stills load through
            // CvImageProvider's 2-concurrent gate + 503 retry, so a feed of thumbs can
            // never shed to black; placeholder is a neutral tile with a camera glyph.)
            Timer {
                interval: 15000; repeat: true; triggeredOnStart: true
                running: root.visible && root.eventModel !== null
                onTriggered: root.eventModel.fetchLiveFeed()
            }
            ListView {
                id: feed
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.leftMargin: 16
                Layout.rightMargin: 16
                Layout.bottomMargin: 12
                clip: true
                spacing: 0
                model: root.eventModel ? root.eventModel.liveFeed : []

                delegate: Item {
                    id: row
                    required property int index
                    required property var modelData
                    readonly property double tsMs: modelData.tsMs

                    width: ListView.view.width
                    height: 66

                    Rectangle {
                        anchors { left: parent.left; right: parent.right; top: parent.top }
                        height: 1
                        color: Theme.line
                        visible: row.index > 0
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.topMargin: 6
                        anchors.bottomMargin: 6
                        spacing: 10

                        // mid-incident still — 16:9, never black
                        Rectangle {
                            id: stillCell
                            Layout.preferredWidth: 96
                            Layout.preferredHeight: 54
                            Layout.alignment: Qt.AlignVCenter
                            color: Theme.panel2
                            border.width: 1
                            border.color: Theme.line2
                            clip: true

                            // Four states that must never render alike. Until 2026-08-15 a
                            // failed fetch and an event with nothing to show drew the SAME
                            // muted glyph, so an operator — and this agent, reading a
                            // screenshot — could not tell "no picture exists" from "the
                            // picture did not arrive".
                            readonly property string evId: "" + row.modelData.id
                            // Ask only when a recording covers the moment. `recordingId`, NOT
                            // `hasClip`: the endpoint extracts a frame from recorded video and
                            // has nothing to do with clip_url (see EventModel.cpp's live-feed
                            // map). Gating on hasClip is why the rail never asked at all —
                            // measured on the pilot feed, clip_url was set on 1 row of 14
                            // while 3 of 14 had a recording_id.
                            readonly property bool noEpisode: !row.modelData.recordingId
                            readonly property bool latched: root._stillFailed[evId] === true
                            readonly property int gen: root._stillGen[evId] || 0
                            property bool waiting: false          // inside a Retry-After pause
                            // Cache-buster: QML caches by URL, so a retry needs a new one.
                            readonly property string stillUrl:
                                "image://cvframe/events/" + evId + "/snapshot?pos=mid"
                            readonly property bool failed: latched

                            Image {
                                id: still
                                anchors.fill: parent
                                anchors.margins: 1
                                asynchronous: true
                                fillMode: Image.PreserveAspectCrop
                                sourceSize.width: 192
                                source: (stillCell.noEpisode || stillCell.latched)
                                        ? "" : (stillCell.stillUrl + "&_t=" + stillCell.gen)
                                visible: status === Image.Ready
                                onStatusChanged: {
                                    if (status !== Image.Error)
                                        return;
                                    // The server's own answer to a too-new event is "retry in
                                    // 30 s", so honour it rather than treating the first error
                                    // as final. Bounded by the failure count, then latched.
                                    if (root._noteStillFail(stillCell.evId) >= root._stillMaxTries) {
                                        root._noteStillFailed(stillCell.evId, stillCell.stillUrl);
                                    } else {
                                        stillCell.waiting = true;
                                        retryStill.restart();
                                    }
                                }
                            }
                            Timer {
                                id: retryStill
                                interval: 30000               // = the endpoint's Retry-After
                                onTriggered: {
                                    stillCell.waiting = false;
                                    root._bumpStillGen(stillCell.evId);   // → new URL → refetch
                                }
                            }
                            Rectangle {                     // shimmer while the queued fetch runs
                                anchors.fill: parent
                                anchors.margins: 1
                                visible: still.status === Image.Loading
                                color: Theme.panel3
                                SequentialAnimation on opacity {
                                    running: still.status === Image.Loading
                                    loops: Animation.Infinite
                                    NumberAnimation { to: 0.45; duration: 600; easing.type: Easing.InOutSine }
                                    NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutSine }
                                }
                            }
                            Icon {                          // footage still being written — will retry
                                anchors.centerIn: parent
                                visible: stillCell.waiting
                                name: "history"
                                size: 16
                                color: Theme.ink2
                            }
                            Icon {                          // nothing recorded at that moment
                                anchors.centerIn: parent
                                visible: !stillCell.failed && !stillCell.waiting
                                         && still.status !== Image.Ready
                                         && still.status !== Image.Loading
                                name: "shot"
                                size: 16
                                color: Theme.ink3
                            }
                            Icon {                          // asked, retried, never arrived —
                                anchors.centerIn: parent    // NOT the same as "no picture exists"
                                visible: stillCell.failed
                                name: "alert"
                                size: 16
                                color: Theme.warn
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            spacing: 4
                            RowLayout {                     // title row: ● label + relative time
                                Layout.fillWidth: true
                                spacing: 6
                                Rectangle {
                                    Layout.preferredWidth: 6; Layout.preferredHeight: 6
                                    color: root.eventColor(row.modelData.type)
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: EventStyle.label(row.modelData.type)
                                    color: row.modelData.ack ? Theme.ink2 : Theme.ink
                                    font.family: Theme.fontSans
                                    font.pixelSize: 12
                                    font.weight: Font.Medium
                                    elide: Text.ElideRight
                                }
                                Text {
                                    text: root.relTime(row.tsMs)
                                    color: Theme.ink3
                                    font.family: Theme.fontMono
                                    font.pixelSize: 10
                                }
                                // Acknowledge — THE production ack affordance (server-
                                // persisted via POST /events/{id}/acknowledge; feeds The
                                // Watch's vigilance family: attention, not luck).
                                Rectangle {
                                    visible: !row.modelData.ack
                                    Layout.preferredWidth: 18; Layout.preferredHeight: 18
                                    radius: 3
                                    color: ackMa.containsMouse ? Theme.accent : "transparent"
                                    border.width: 1
                                    border.color: ackMa.containsMouse ? Theme.accent : Theme.line2
                                    Text {
                                        anchors.centerIn: parent; text: "✓"
                                        color: ackMa.containsMouse ? Theme.bg : Theme.ink3
                                        font.pixelSize: 11; font.weight: Font.Bold
                                    }
                                    MouseArea {
                                        id: ackMa; anchors.fill: parent; hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: if (root.eventModel) root.eventModel.acknowledgeById(row.modelData.id)
                                    }
                                    C.ToolTip.visible: ackMa.containsMouse
                                    C.ToolTip.delay: 400
                                    C.ToolTip.text: qsTr("Acknowledge")
                                }
                            }
                            RowLayout {                     // camera line: IP first, never clipped
                                Layout.fillWidth: true
                                spacing: 6
                                Text {
                                    text: row.modelData.ip
                                    visible: text !== ""
                                    color: Theme.ink2
                                    font.family: Theme.fontMono
                                    font.pixelSize: 10
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: row.modelData.camName
                                    color: Theme.ink3
                                    font.family: Theme.fontSans
                                    font.pixelSize: 10
                                    elide: Text.ElideRight
                                }
                            }
                        }

                        Rectangle {
                            visible: !row.modelData.ack
                            Layout.preferredWidth: 6
                            Layout.preferredHeight: 6
                            Layout.alignment: Qt.AlignTop
                            Layout.topMargin: 6
                            color: Theme.bad
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.viewAllEvents()
                    }
                }
            }
        }
    }
}
