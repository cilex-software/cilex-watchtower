import QtQuick
import QtQuick.Layouts
import Watchtower

// The Events redesign area (port of designs/events-v2 app.jsx shell, minus the
// app-level rail/top bar which the real Watchtower shell already provides). It
// owns the Events-specific sub-chrome: the mode switcher (01–04) + rationale and
// the live OPEN / CRITICAL / CLEARED status strip, over ONE shared EventsStore.
// The stage hosts the four views; selection (selId) is shared across them.
Item {
    id: area
    property string mode: "triage"
    property string selId: ""                     // shared event selection across views

    // Data source. demo (or no eventModel) → the events-v2 mock showcase; otherwise
    // the live cilex-vision feed via EventModel + CameraModel, mapped honestly in
    // EventsStore.ingestReal (neutral severity, no fabricated fields).
    property var eventModel: null
    property var cameraModel: null
    property bool demo: false
    readonly property int _camCount: cameraModel ? cameraModel.total : 0

    function _buildLookup() {
        var lk = ({});
        var n = cameraModel ? cameraModel.total : 0;
        var cols = Math.max(1, Math.ceil(Math.sqrt(n)));
        var rows = Math.max(1, Math.ceil(n / cols));
        for (var i = 0; i < n; i++) {
            var c = cameraModel.get(i);
            if (!c || !c.camId) continue;
            var col = i % cols, ri = Math.floor(i / cols);
            // No site-plan coords from the backend yet — spread pins on a grid so the
            // Map stays usable (a layout fallback, not invented positions).
            lk[c.camId] = { key: c.camId, id: c.camId, name: (c.name ? c.name : c.camId),
                zone: (c.groupName ? c.groupName : ""),
                x: Math.round((col + 0.5) / cols * 100), y: Math.round((ri + 0.5) / rows * 100) };
        }
        return lk;
    }
    function _ingestReal() {
        if (!eventModel) { EventsStore.loadMock(); return; }
        EventsStore.ingestReal(eventModel.all(), area._buildLookup());
    }

    Component.onCompleted: {
        if (demo || !eventModel) {
            EventsStore.loadMock();
        } else {
            EventsStore.realAck = function (id) { if (area.eventModel) area.eventModel.acknowledgeById(id); };
            area._ingestReal();
        }
    }
    Connections {
        target: area.eventModel
        enabled: !area.demo && area.eventModel !== null
        function onChanged() { area._ingestReal(); }
    }
    on_CamCountChanged: if (!demo && eventModel) area._ingestReal()    // cameras load async → re-resolve names/zones

    readonly property var _modes: [
        { id: "triage",   n: "01", label: "Triage Queue",      tag: "Clear the backlog",
          why: "<font color='#f0ece4'><b>Inbox triage.</b></font> Work the queue top-down by priority — watch the event clip inline, run the response procedure, and record a disposition. Best when one operator must clear a backlog of unhandled alarms fast." },
        { id: "review",   n: "02", label: "Verify",            tag: "See it · sort it",
          why: "<font color='#f0ece4'><b>Verify — Wall + Sessions in one screen.</b></font> Toggle between the snapshot <font color='#f0ece4'><b>Wall</b></font> (confirm a threat or dismiss a false alarm at a glance) and <font color='#f0ece4'><b>Smart Sessions</b></font> (motion fragments collapsed by zone, ranked by priority, bulk-acknowledged)." },
        { id: "timeline", n: "03", label: "Activity Timeline", tag: "Patterns & investigation",
          why: "<font color='#f0ece4'><b>Forensic timeline.</b></font> One lane per camera across time; each event extends a bar to the right showing how long it lasted, so clusters and dwell-times become obvious. Best for investigating \"what happened between 5 and 8\"." },
        { id: "map",      n: "04", label: "Situation Map",     tag: "Where is it happening",
          why: "<font color='#f0ece4'><b>Spatial awareness.</b></font> Events pulse on the site plan where they physically occur. Best for supervisors and owners who think in places, not log lines, and need to dispatch in context." }
    ]
    readonly property var _curMode: {
        for (var i = 0; i < _modes.length; i++) if (_modes[i].id === mode) return _modes[i];
        return _modes[0];
    }

    Rectangle { anchors.fill: parent; color: Theme.bg }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ============ mode bar: switcher + rationale + status strip ============
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Math.max(58, modeRow.implicitHeight + 16)
            color: Theme.bg
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }

            RowLayout {
                id: modeRow
                anchors.fill: parent
                anchors.leftMargin: 20; anchors.rightMargin: 20
                spacing: 16

                // ---- mode switcher (segmented) ----
                Rectangle {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredHeight: 40
                    Layout.preferredWidth: seg.implicitWidth
                    color: Theme.panel; border.width: 1; border.color: Theme.line2
                    Row {
                        id: seg
                        height: parent.height
                        Repeater {
                            model: area._modes
                            delegate: Rectangle {
                                id: segBtn
                                required property var modelData
                                required property int index
                                readonly property bool _active: area.mode === modelData.id
                                height: seg.height
                                width: segRow.implicitWidth + 32
                                color: _active ? Theme.accent : (segMa.containsMouse ? Theme.panel2 : Theme.panel)
                                Rectangle { visible: segBtn.index < area._modes.length - 1
                                    anchors.right: parent.right; width: 1; height: parent.height; color: Theme.line }
                                Row {
                                    id: segRow; anchors.centerIn: parent; spacing: 8
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: segBtn.modelData.n
                                        color: segBtn._active ? Qt.rgba(26/255, 24/255, 22/255, 0.6) : Theme.ink3
                                        font.family: Theme.fontMono; font.pixelSize: 10 }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: segBtn.modelData.label
                                        color: segBtn._active ? Theme.bg : (segMa.containsMouse ? Theme.ink : Theme.ink2)
                                        font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.DemiBold }
                                }
                                MouseArea { id: segMa; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor; onClicked: area.mode = segBtn.modelData.id }
                            }
                        }
                    }
                }

                // ---- rationale (tag + why) ----
                ColumnLayout {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.maximumWidth: 620
                    Layout.fillWidth: true
                    spacing: 2
                    Text { text: area._curMode.tag.toUpperCase(); color: Theme.accent
                        font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 1.0 }
                    Text { Layout.fillWidth: true; text: area._curMode.why; color: Theme.ink2
                        textFormat: Text.StyledText; wrapMode: Text.WordWrap; lineHeight: 1.25
                        font.family: Theme.fontSans; font.pixelSize: 12 }
                }

                Item { Layout.fillWidth: true }

                // ---- status strip (OPEN / CRITICAL / CLEARED) ----
                Rectangle {
                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredHeight: 38
                    Layout.preferredWidth: chipRow.implicitWidth
                    color: Theme.panel; border.width: 1; border.color: Theme.line2
                    Row {
                        id: chipRow
                        height: parent.height
                        Repeater {
                            model: [ { dot: Theme.bad,    n: EventsStore.openCount,    l: "open" },
                                     { dot: Theme.accent, n: EventsStore.critCount,    l: "critical" },
                                     { dot: Theme.good,   n: EventsStore.clearedCount, l: "cleared" } ]
                            delegate: Rectangle {
                                required property var modelData
                                required property int index
                                height: chipRow.height; width: cRow.implicitWidth + 28; color: "transparent"
                                Rectangle { visible: index < 2; anchors.right: parent.right; width: 1; height: parent.height; color: Theme.line }
                                Row {
                                    id: cRow; anchors.centerIn: parent; spacing: 8
                                    Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 7; height: 7; color: modelData.dot }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.n; color: Theme.ink
                                        font.family: Theme.fontSans; font.pixelSize: 18; font.weight: Font.Bold }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.l.toUpperCase(); color: Theme.ink3
                                        font.family: Theme.fontMono; font.pixelSize: 11; font.letterSpacing: 0.9 }
                                }
                            }
                        }
                    }
                }
            }
        }

        // ============ stage — the active view ============
        Item {
            Layout.fillWidth: true; Layout.fillHeight: true; clip: true

            Loader {
                anchors.fill: parent
                sourceComponent: area.mode === "triage" ? triageC
                               : area.mode === "review" ? reviewC
                               : area.mode === "timeline" ? timelineC
                               : mapC
            }
        }
    }

    Component {
        id: triageC
        EvTriage { selId: area.selId; onSelect: (id) => area.selId = id }
    }
    Component {
        id: reviewC
        EvVerify { onOpenInTriage: (id) => { area.selId = id; area.mode = "triage"; } }
    }
    Component {
        id: timelineC
        EvTimeline { onOpenInTriage: (id) => { area.selId = id; area.mode = "triage"; } }
    }
    Component {
        id: mapC
        EvMap { onOpenInTriage: (id) => { area.selId = id; area.mode = "triage"; } }
    }
}
