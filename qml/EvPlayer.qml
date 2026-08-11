import QtQuick
import QtQuick.Layouts
import Watchtower

// Inline event-clip player — a 1:1 port of view-triage.jsx <Player>. Plays the
// event clip in place (no separate "open playback" step): transport with
// play/pause, −10/+10, MM:SS / MM:SS readout, a seekable scrubber that highlights
// the event in/out window, and a 1×/2×/4× speed cycle.
// Timeline model: total = 6s pre-roll + clip + 6s post-roll, clip = max(dur, 14).
Item {
    id: pl
    property var ev: null

    readonly property real _clip: Math.max((ev && ev.durationSec) ? ev.durationSec : 20, 14)
    readonly property real _pre: 6
    readonly property real _post: 6
    readonly property real _total: _pre + _clip + _post
    property real prog: _pre / _total          // 0..1 head position; starts at event in-point
    property bool playing: true
    property int speed: 1
    readonly property real _cur: prog * _total
    readonly property bool _inEvent: _cur >= _pre && _cur <= _pre + _clip

    // surface is 21:9 of the width; transport adds a fixed 52px — drive our own
    // implicit height so a parent layout sizes us correctly (Item won't infer it
    // from an anchors-filled child).
    implicitHeight: width > 0 ? Math.round(width * 9 / 21) + 52 : 0

    // React key={cur.id} remount → reset transport whenever the event changes
    onEvChanged: { prog = _pre / _total; playing = true; speed = 1 }

    function _fmt(s) { s = Math.max(0, Math.round(s)); return EventsStore._p2(Math.floor(s / 60)) + ":" + EventsStore._p2(s % 60); }
    function _seekTo(frac) { prog = Math.min(1, Math.max(0, frac)); }
    function toggle() { playing = !playing }              // keyboard Space

    Timer {
        interval: 100; repeat: true; running: pl.playing
        onTriggered: { var n = pl.prog + (0.1 * pl.speed) / pl._total; pl.prog = n >= 1 ? 0 : n; }
    }

    Rectangle { anchors.fill: parent; color: "#000" }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---- video surface (21:9) ----
        Item {
            id: surface
            Layout.fillWidth: true
            Layout.preferredHeight: Math.round(width * 9 / 21)
            EvSnapshot { anchors.fill: parent; ev: pl.ev; playing: pl.playing; showPlayhead: false }

            Rectangle {                              // pl-state chip (top-right)
                anchors.top: parent.top; anchors.right: parent.right
                anchors.topMargin: 8; anchors.rightMargin: 10
                color: Qt.rgba(0, 0, 0, 0.55); height: 18; width: stateT.implicitWidth + 14
                Text {
                    id: stateT; anchors.centerIn: parent
                    text: (pl.playing ? "▶ " : "❚❚ ") + (pl._inEvent ? qsTr("EVENT") : qsTr("PLAYBACK"))
                    color: pl._inEvent ? Theme.accent : Qt.rgba(1, 1, 1, 0.7)
                    font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 0.9
                }
            }
        }

        // ---- transport bar ----
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 52
            color: Theme.panel
            Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Theme.line }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12; anchors.rightMargin: 12
                spacing: 9

                // play / pause
                Rectangle {
                    Layout.preferredWidth: 34; Layout.preferredHeight: 34
                    color: ppMa.containsMouse ? Theme.panel3 : Theme.panel2
                    border.width: 1; border.color: ppMa.containsMouse ? Theme.ink3 : Theme.line2
                    Row {                            // pause = two bars
                        anchors.centerIn: parent; spacing: 4; visible: pl.playing
                        Rectangle { width: 4; height: 14; color: Theme.ink }
                        Rectangle { width: 4; height: 14; color: Theme.ink }
                    }
                    EvIcon { anchors.centerIn: parent; visible: !pl.playing; name: "play"; size: 15; color: Theme.ink }
                    MouseArea { id: ppMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: pl.playing = !pl.playing }
                }
                // −10
                Rectangle {
                    Layout.preferredWidth: 38; Layout.preferredHeight: 34
                    color: b1.containsMouse ? Theme.panel3 : Theme.panel2
                    border.width: 1; border.color: b1.containsMouse ? Theme.ink3 : Theme.line2
                    Text { anchors.centerIn: parent; text: "−10"; color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 10 }
                    MouseArea { id: b1; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: pl._seekTo(pl.prog - 10 / pl._total) }
                }
                // +10
                Rectangle {
                    Layout.preferredWidth: 38; Layout.preferredHeight: 34
                    color: b2.containsMouse ? Theme.panel3 : Theme.panel2
                    border.width: 1; border.color: b2.containsMouse ? Theme.ink3 : Theme.line2
                    Text { anchors.centerIn: parent; text: "+10"; color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 10 }
                    MouseArea { id: b2; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: pl._seekTo(pl.prog + 10 / pl._total) }
                }
                // time readout
                Text {
                    Layout.alignment: Qt.AlignVCenter
                    textFormat: Text.StyledText
                    text: pl._fmt(pl._cur) + " <font color='" + Theme.ink3 + "'>/</font> " + pl._fmt(pl._total)
                    color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 11
                }
                // scrubber
                Item {
                    Layout.fillWidth: true; Layout.preferredHeight: 30
                    Rectangle { id: track; anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 5; color: Theme.panel3 }
                    Rectangle {                      // event window
                        anchors.verticalCenter: parent.verticalCenter; height: 5; color: Theme.accentDim
                        x: parent.width * (pl._pre / pl._total); width: parent.width * (pl._clip / pl._total)
                    }
                    Rectangle {                      // progress fill
                        anchors.verticalCenter: parent.verticalCenter; height: 5; color: Theme.accent
                        x: 0; width: parent.width * pl.prog
                    }
                    Rectangle {                      // playhead handle
                        anchors.verticalCenter: parent.verticalCenter; width: 3; height: 16; color: Theme.ink
                        x: parent.width * pl.prog - width / 2
                    }
                    MouseArea {
                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onPressed: (m) => pl._seekTo(m.x / width)
                        onPositionChanged: (m) => { if (pressed) pl._seekTo(m.x / width); }
                    }
                }
                // speed
                Rectangle {
                    Layout.preferredWidth: 38; Layout.preferredHeight: 34
                    color: sp.containsMouse ? Theme.panel3 : Theme.panel2
                    border.width: 1; border.color: sp.containsMouse ? Theme.ink3 : Theme.line2
                    Text { anchors.centerIn: parent; text: pl.speed + "×"; color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11 }
                    MouseArea { id: sp; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: pl.speed = (pl.speed === 1 ? 2 : pl.speed === 2 ? 4 : 1) }
                }
            }
        }
    }
}
