import QtQuick
import Watchtower

// Export progress strip. Shown while a clip export is running, and built around one
// rule: THE BAR NEVER INVENTS A NUMBER.
//
// An export is three phases with three different honesties (see the Q_PROPERTY note on
// PlaybackClient::exportFraction). CV's job object carries no progress field (checked
// against review.py's export model 2026-09-23), so the
// server phase is genuinely unknown and renders as a SWEEP, not as a fill sitting at
// 0%. Download and re-encode have real denominators and get a real fill.
//
// Because a sweep is only an animation, it cannot by itself prove the pipeline is
// alive — a frozen app would sweep just as happily. So the strip always carries two
// things driven by real events: the detail line (re-written by each 2 s server poll,
// each download chunk, each ffmpeg tick) and the elapsed clock. Together they answer
// the question this exists for: "is it working, or has it hung?" (operator, 2026-09-22,
// after a 1 h export gave no feedback at all between the start toast and the save.)
Item {
    id: xp
    required property var client

    readonly property bool active: client && client.exportActive
    readonly property string phase: client ? client.exportPhase : ""
    readonly property real frac: client ? client.exportFraction : -1
    readonly property bool determinate: frac >= 0
    readonly property string detail: client ? client.exportDetail : ""

    implicitHeight: active ? col.implicitHeight + 20 : 0
    visible: height > 0
    clip: true
    Behavior on implicitHeight { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

    // Elapsed is recomputed from the client's own start stamp, so it survives this
    // item being recreated and never free-runs on its own clock.
    property int elapsedS: 0
    Timer {
        interval: 1000; repeat: true; running: xp.active
        triggeredOnStart: true
        onTriggered: xp.elapsedS = (xp.client && xp.client.exportStartedMs > 0)
                     ? Math.max(0, Math.round((Date.now() - xp.client.exportStartedMs) / 1000)) : 0
    }
    function _clock(s) {
        var m = Math.floor(s / 60), r = s % 60;
        return m > 0 ? (m + "m " + (r < 10 ? "0" : "") + r + "s") : (r + "s");
    }
    readonly property var _steps: ["preparing", "downloading", "compressing"]
    readonly property int _stepIndex: _steps.indexOf(phase)

    Rectangle {
        anchors.fill: parent
        color: Theme.panel2
        Rectangle { anchors { left: parent.left; right: parent.right; top: parent.top }
                    height: 1; color: Theme.line }
    }

    Column {
        id: col
        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter
                  leftMargin: 14; rightMargin: 14 }
        spacing: 7

        Item {
            width: parent.width; height: lblL.implicitHeight
            Row {
                id: lblL
                anchors.left: parent.left
                spacing: 8
                Text {
                    text: xp.phase === "preparing"   ? qsTr("PREPARING CLIP")
                        : xp.phase === "downloading" ? qsTr("DOWNLOADING")
                        : xp.phase === "compressing" ? qsTr("RE-ENCODING")
                        : ""
                    color: Theme.accent; font.family: Theme.fontMono; font.pixelSize: 9
                    font.letterSpacing: 1.3; font.weight: Font.DemiBold
                }
                // Step 1/2/3 — where we are in a pipeline the operator cannot see.
                Row {
                    spacing: 3
                    anchors.verticalCenter: parent.verticalCenter
                    Repeater {
                        model: 3
                        delegate: Rectangle {
                            required property int index
                            width: 10; height: 2; radius: 1
                            color: index < xp._stepIndex ? Theme.accent
                                 : index === xp._stepIndex ? Theme.accent : Theme.line2
                            opacity: index <= xp._stepIndex ? 1 : 0.55
                        }
                    }
                }
                Text {
                    text: xp.detail
                    color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 9
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
            Text {
                anchors.right: parent.right
                // A percentage ONLY where one was measured. The server phase shows the
                // elapsed clock instead — unknown stated as unknown.
                text: xp.determinate ? Math.round(xp.frac * 100) + "%  ·  " + xp._clock(xp.elapsedS)
                                     : xp._clock(xp.elapsedS)
                color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9
            }
        }

        // ---- the bar ------------------------------------------------------
        Rectangle {
            id: track
            width: parent.width; height: 3; radius: 1.5
            color: Theme.line2
            // Held here, not on the sweep: a NumberAnimation whose `from` reads the
            // moving item's own id evaluates to undefined at creation time.
            readonly property real sweepW: Math.max(40, width * 0.22)

            // Determinate: a real fill, width == the measured fraction.
            Rectangle {
                visible: xp.determinate
                width: Math.max(2, track.width * Math.max(0, Math.min(1, xp.frac)))
                height: parent.height; radius: parent.radius
                color: Theme.accent
                Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
            }

            // Indeterminate: a sweep. Deliberately NOT a fill — a bar sitting at 0%
            // or creeping on a timer would be a claim about progress we do not have.
            Item {
                visible: !xp.determinate
                anchors.fill: parent
                clip: true
                Rectangle {
                    width: track.sweepW
                    height: track.height; radius: track.radius
                    color: Theme.accent; opacity: 0.85
                    x: -width
                    SequentialAnimation on x {
                        running: xp.active && !xp.determinate
                        loops: Animation.Infinite
                        NumberAnimation { from: -track.sweepW; to: track.width
                                          duration: 1150; easing.type: Easing.InOutSine }
                        PauseAnimation { duration: 180 }
                    }
                }
            }
        }
    }
}
