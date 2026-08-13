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
    // Chrome density, set by the tile from its own measured width
    // (CameraTile.chromeTier). The badge gives up detail in the order an
    // operator misses it least:
    //   2  dot + label + age    "■ LIVE · 42m"
    //   1  dot + label          "■ LIVE"        — the age goes first
    //   0  dot only             a coloured square. Recording keeps dotPulse, so
    //                           it reads as a camcorder tally light rather than
    //                           as a label that has been taken away.
    property int tier: 2
    property int _tick: 0
    Timer {
        interval: 30000; repeat: true
        running: root.visible && root.sinceMs > 0 && Settings.badgeTimers
        onTriggered: root._tick++
    }
    readonly property string ageSuffix: {
        _tick;
        if (tier < 2) return "";        // no room for the age at this density
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

    // Padding and height shrink with the tier; at tier 0 the badge is a 12x12
    // square holding nothing but its dot.
    readonly property int _pad: tier === 0 ? 4 : (tier === 1 ? 9 : 12)
    implicitHeight: tier === 0 ? 12 : (tier === 1 ? 16 : 18)
    implicitWidth: content.implicitWidth + _pad
    height: implicitHeight
    color: bgColor
    radius: 0

    Row {
        id: content
        anchors.centerIn: parent
        spacing: 4

        Rectangle {
            id: dot
            width: root.tier === 0 ? 8 : (root.dotHollow ? 7 : 6)
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
            visible: root.tier > 0
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
