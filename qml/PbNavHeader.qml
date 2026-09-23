import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C
import Watchtower

// Playback navigator header · 26px of gapless hairline-separated cells
// (spec §2.3). `Coverage` lives here — promoted out of the dissolved info rail,
// beside the lanes it describes — and `Last motion` is here as an ACTION cell,
// because it was never a status value: it is a jump.
//
// LAST MOTION and MARKED render only when they have something to say; the header
// is not padded with disabled cells.
Item {
    id: hdr
    height: 26

    property double playheadMs: 0
    property bool hasPlayhead: false
    property int segCount: 0
    property int coveredPct: 0
    // The timeline has not answered for this window, so its segment count is not a
    // measurement yet. Without this, an unopened session renders as the definite
    // "no footage in this window" (2026-09-22, while the archive was in fact intact).
    property bool pending: false
    property double lastMotionMs: -1
    property double markMs: -1         // marked-range duration, ms; <= 0 = no range
    property bool showMotion: true
    property bool showEvents: true
    property int spanMin: 60           // 15 / 60 / 360 / 720 / 1440
    signal pageRequested(int dir)      // -1 back, +1 forward, by one whole span
    readonly property string spanLabel: spanMin === 15 ? qsTr("15 minutes")
                                     : spanMin === 60 ? qsTr("hour")
                                     : spanMin === 1440 ? qsTr("day")
                                     : qsTr("%1 hours").arg(Math.round(spanMin / 60))
    property bool zoomed: false        // a free-form wheel zoom is active -> show FIT

    signal jumpLastMotion()
    signal clearMark()
    signal toggleMotion()
    signal toggleEvents()
    signal spanPicked(int minutes)
    signal fitRequested()

    readonly property int labelW: 120

    Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: 1; color: Theme.line }

    // A gapless cell: content-sized, one hairline on its right edge.
    component Cell: Rectangle {
        id: c
        property string label: ""
        property color labelColor: Theme.ink3
        property bool interactive: false
        property bool active: false
        property bool ghost: false
        property string tip: ""
        signal activated()
        Layout.fillHeight: true
        Layout.preferredWidth: txt.implicitWidth + 20
        color: active && !ghost ? Theme.accent
               : active && ghost ? Theme.accentSoft
               : (interactive && cMa.containsMouse ? Theme.panel2 : "transparent")
        Text {
            id: txt
            anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
            text: c.label
            color: c.active && !c.ghost ? "#241a08" : c.labelColor
            font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 1.3
            font.weight: c.active && !c.ghost ? Font.Bold : Font.Normal
        }
        Rectangle { anchors { right: parent.right; top: parent.top; bottom: parent.bottom } width: 1; color: Theme.line }
        Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                    height: 2; color: Theme.accent; visible: c.active && c.ghost }
        MouseArea {
            id: cMa; anchors.fill: parent; enabled: c.interactive
            hoverEnabled: c.interactive; cursorShape: Qt.PointingHandCursor
            onClicked: c.activated()
        }
        C.ToolTip.visible: c.tip !== "" && cMa.containsMouse
        C.ToolTip.delay: 400
        C.ToolTip.text: c.tip
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // PLAYHEAD — 120px, matching the ribbon's label block above
        Rectangle {
            Layout.preferredWidth: hdr.labelW
            Layout.fillHeight: true
            color: "transparent"
            Rectangle { anchors { right: parent.right; top: parent.top; bottom: parent.bottom } width: 1; color: Theme.line }
            Column {
                anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                spacing: 0
                Text { text: qsTr("PLAYHEAD", "playback navigator header")
                    color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 8; font.letterSpacing: 1.3 }
                Text { text: hdr.hasPlayhead ? (PbFmt.wd(hdr.playheadMs) + " " + PbFmt.hms(hdr.playheadMs)) : "—"
                    color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 10 }
            }
        }

        // COVERAGE — the number that predicts whether scrubbing is worth it.
        // A motion-recorded fleet routinely reads 4–7%; that is not a bug, it is
        // the truth the old screen buried fifth in a key/value stack.
        Rectangle {
            id: covCell
            readonly property bool zero: hdr.segCount <= 0
            readonly property bool unknown: hdr.pending
            Layout.preferredWidth: covRow.implicitWidth + 20
            Layout.fillHeight: true
            color: "transparent"
            Rectangle { anchors { right: parent.right; top: parent.top; bottom: parent.bottom } width: 1; color: Theme.line }
            Row {
                id: covRow
                anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                spacing: 4
                Text { visible: !covCell.zero && !covCell.unknown; text: PbFmt.segs(hdr.segCount)
                    color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 9; font.weight: Font.DemiBold }
                Text { text: covCell.unknown ? qsTr("coverage unknown")
                             : covCell.zero ? qsTr("no footage in this window")
                                          : "· " + qsTr("%1% covered").arg(hdr.coveredPct)
                    color: covCell.unknown ? Theme.ink3 : covCell.zero ? Theme.bad : Theme.ink3
                    font.family: Theme.fontMono; font.pixelSize: 9 }
            }
        }

        Cell {
            visible: hdr.lastMotionMs > 0
            interactive: true
            labelColor: Theme.accent
            label: qsTr("LAST MOTION") + " " + PbFmt.hms(hdr.lastMotionMs) + " ›"
            tip: qsTr("Jump to the newest motion")
            onActivated: hdr.jumpLastMotion()
        }

        Cell {
            visible: hdr.markMs > 0
            interactive: true
            labelColor: Theme.accent
            label: qsTr("MARKED") + " " + PbFmt.dur(hdr.markMs) + " ✕"
            tip: qsTr("Clear the marked range")
            onActivated: hdr.clearMark()
        }

        Item { Layout.fillWidth: true; Layout.fillHeight: true }   // the only flexible cell

        Cell {
            interactive: true; ghost: true; active: hdr.showMotion
            labelColor: hdr.showMotion ? Theme.accent : Theme.ink3
            label: qsTr("MOTION", "navigator toggle")
            tip: qsTr("Show or hide the motion lane")
            onActivated: hdr.toggleMotion()
        }
        Cell {
            interactive: true; ghost: true; active: hdr.showEvents
            labelColor: hdr.showEvents ? Theme.accent : Theme.ink3
            label: qsTr("EVENTS", "navigator toggle")
            tip: qsTr("Show or hide the events column")
            onActivated: hdr.toggleEvents()
        }
        // Page the loaded window a WHOLE span. These sit with the span chips because
        // what they move by IS the span: at 1H they step an hour, at 6H six. Chevrons
        // rather than words so the pair reads as one control and survives translation.
        Cell {
            interactive: true; ghost: true
            label: "\u2039"
            tip: qsTr("Previous %1 (PageUp)").arg(hdr.spanLabel)
            onActivated: hdr.pageRequested(-1)
        }
        Cell {
            interactive: true; ghost: true
            label: "\u203A"
            tip: qsTr("Next %1 (PageDown)").arg(hdr.spanLabel)
            onActivated: hdr.pageRequested(1)
        }
        Repeater {
            model: [[qsTr("15M", "span button"), 15], [qsTr("1H", "span button"), 60],
                    [qsTr("6H", "span button"), 360], [qsTr("12H", "span button"), 720],
                    [qsTr("24H", "span button"), 1440]]
            delegate: Cell {
                required property var modelData
                interactive: true
                // A solid accent fill, not a ghost underline: one of them is always
                // true, so the set is a radio and not a pair of switches.
                active: hdr.spanMin === modelData[1]
                label: modelData[0]
                onActivated: hdr.spanPicked(modelData[1])
            }
        }
        // The way OUT of a free-form wheel zoom. It appears only while zoomed, for
        // the same reason the wall's FIT does: a gesture that changes the view with
        // no visible exit is a trap, and none of the span buttons above can express
        // "back to the whole loaded window" once the view is a custom span.
        Cell {
            visible: hdr.zoomed
            interactive: true; active: true
            label: qsTr("FIT", "reset a custom timeline zoom")
            tip: qsTr("Drop the custom zoom back to the loaded window")
            onActivated: hdr.fitRequested()
        }
    }
}
