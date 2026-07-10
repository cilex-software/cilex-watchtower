import QtQuick
import Watchtower

// Visual atom for a status badge (used by LiveStatusBadge / RecordingStatusBadge).
// Height 18, JetBrains Mono 9px/600 uppercase 0.06em, color-coded dim background
// with a small status dot (square — consistent with the 0-radius design language).
Rectangle {
    id: root

    property string label: ""
    // Badge timer: epoch ms when this state was OBSERVED to begin; -1 = onset
    // unknown (no suffix). Rendered as "LABEL · 4m", gated by Settings.badgeTimers
    // (Preferences → Display). Ticks every 30 s.
    property double sinceMs: -1
    property int _tick: 0
    Timer {
        interval: 30000; repeat: true
        running: root.visible && root.sinceMs > 0 && Settings.badgeTimers
        onTriggered: root._tick++
    }
    readonly property string ageSuffix: {
        _tick;
        if (!Settings.badgeTimers || sinceMs <= 0) return "";
        var s = Math.max(0, (Date.now() - sinceMs) / 1000);
        if (s < 60) return " · " + qsTr("now");
        if (s < 3600) return " · " + Math.floor(s / 60) + qsTr("m");
        if (s < 86400) return " · " + Math.floor(s / 3600) + qsTr("h");
        return " · " + Math.floor(s / 86400) + qsTr("d");
    }
    property color fg: Theme.ink3
    property color bgColor: Theme.line
    property color dotColor: Theme.ink3
    property bool dotHollow: false   // not-recording / gap: hollow ring
    property bool dotPulse: false    // recording: pulsing

    implicitHeight: 18
    implicitWidth: content.implicitWidth + 12
    height: 18
    color: bgColor
    radius: 0

    Row {
        id: content
        anchors.centerIn: parent
        spacing: 4

        Rectangle {
            id: dot
            width: root.dotHollow ? 7 : 6
            height: width
            radius: 0
            anchors.verticalCenter: parent.verticalCenter
            color: root.dotHollow ? "transparent" : root.dotColor
            border.width: root.dotHollow ? 1.5 : 0
            border.color: root.dotColor

            SequentialAnimation on opacity {
                running: root.dotPulse
                loops: Animation.Infinite
                NumberAnimation { to: 0.3; duration: 800; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1.0; duration: 800; easing.type: Easing.InOutSine }
            }
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.label + root.ageSuffix
            color: root.fg
            font.family: Theme.fontMono
            font.pixelSize: Theme.fsBadge   // 9
            font.weight: Font.DemiBold       // 600
            font.letterSpacing: 0.54         // ~0.06em at 9px
        }
    }
}
