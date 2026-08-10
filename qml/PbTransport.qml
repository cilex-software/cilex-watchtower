import QtQuick
import QtQuick.Controls.Basic as C
import Watchtower

// Playback transport · four groups by JOB, on the picture (spec §2.4).
//
// Three anchors and one rule: a continuous LEFT run (move · rate) — everything
// the operator does *to* the recording; the frame cluster pinned at the CENTRE,
// which is what marks it as a mode rather than another action; and a
// RIGHT-anchored exit group — the two ways off the screen. A group with no edge
// to belong to has its position decided by the widths of its neighbours, which
// from the operator's side is arbitrary.
Item {
    id: bar

    property bool playing: false
    property bool canPlay: true
    property bool blocked: false        // playbackOff / sessionError — the archive cannot be driven
    property real rate: 1
    property var rates: [0.25, 0.5, 1, 2, 4, 10, 20, 50, 100, 200]
    property real maxDecodeRate: 10
    property bool frameMode: false
    // The range tools are shown whenever frame mode is on OR a range exists:
    // it must be impossible to create a marked range whose export control is
    // hidden (spec §2.4 — brief problem 8 rebuilt in a worse form).
    property bool rangeTools: false
    property bool ladderOpen: false
    property bool fullscreenOn: false
    property double markMs: -1          // marked-range duration; <= 0 = no range
    property bool backFetching: false   // the backward step's cache fetch is in flight
    property real padL: 11
    property real padR: 11

    signal back10()
    signal stepBack()
    signal playPause()
    signal stepFwd()
    signal fwd10()
    signal ladderToggled()
    signal ratePicked(real r)
    signal frameToggled()
    signal markIn()
    signal markOut()
    signal exportClicked()
    signal fullscreenToggled()
    signal snapshot()
    signal snapshotStamped()
    signal returnToLive()

    function fmtRate(s) { return s === 0.25 ? "¼×" : s === 0.5 ? "½×" : s + "×" }

    implicitHeight: 64

    // gradient scrim: transparent → 86% black
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.86) }
        }
    }

    component TGroup: Rectangle {
        default property alias cells: grow.data
        color: Qt.rgba(13 / 255, 12 / 255, 11 / 255, 0.72)
        border.width: 1
        border.color: Theme.line2
        implicitHeight: 34
        implicitWidth: grow.implicitWidth
        Row { id: grow; anchors.fill: parent }
    }

    component TCell: Rectangle {
        id: tc
        property string icon: ""
        property string glyph: ""
        // U+229E (⊞) renders as a missing-glyph box in this runtime's mono
        // fallback (verified on screen), so the frame-mode mark is DRAWN.
        property bool frameMark: false
        property bool exportMark: false
        property string label: ""
        property color tint: Qt.rgba(1, 1, 1, 0.78)
        property color hoverTint: Qt.rgba(232 / 255, 161 / 255, 58 / 255, 0.16)
        property bool on: false
        property bool primary: false
        property bool wide: false
        property string tip: ""
        property bool cellEnabled: true
        signal activated()
        height: 34
        width: Math.max(primary || wide ? 42 : 34, inner.implicitWidth + (label !== "" ? 22 : 16))
        color: on ? Theme.accentSoft : (tcMa.containsMouse && cellEnabled ? hoverTint : "transparent")
        opacity: cellEnabled ? 1 : 0.3
        Rectangle { anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                    width: 1; color: Qt.rgba(68 / 255, 63 / 255, 55 / 255, 0.75) }
        Row {
            id: inner
            anchors.centerIn: parent
            spacing: 6
            Icon { visible: tc.icon !== ""; name: tc.icon; size: tc.primary ? 16 : 14
                   color: tc.on ? Theme.accent : tc.tint; anchors.verticalCenter: parent.verticalCenter }
            Item {
                visible: tc.frameMark
                width: 15; height: 15
                anchors.verticalCenter: parent.verticalCenter
                readonly property color ink: tc.on ? Theme.accent : tc.tint
                Rectangle { anchors.fill: parent; color: "transparent"; border.width: 1; border.color: parent.ink }
                Rectangle { x: 7; y: 3; width: 1; height: 9; color: parent.ink }
                Rectangle { x: 3; y: 7; width: 9; height: 1; color: parent.ink }
            }
            // Export: an arrow OUT of a bar (the icon set's `download`, turned).
            Icon { visible: tc.exportMark; name: "download"; size: 14; rotation: 180
                   color: tc.on ? Theme.accent : tc.tint; anchors.verticalCenter: parent.verticalCenter }
            Text { visible: tc.glyph !== ""; text: tc.glyph; color: tc.on ? Theme.accent : tc.tint
                   font.family: Theme.fontMono; font.pixelSize: tc.primary ? 15 : 12; font.weight: Font.DemiBold
                   anchors.verticalCenter: parent.verticalCenter }
            Text { visible: tc.label !== ""; text: tc.label; color: tc.on ? Theme.accent : tc.tint
                   font.family: Theme.fontSans; font.pixelSize: 11
                   anchors.verticalCenter: parent.verticalCenter }
        }
        MouseArea {
            id: tcMa; anchors.fill: parent; hoverEnabled: true
            enabled: tc.cellEnabled
            cursorShape: Qt.PointingHandCursor
            onClicked: tc.activated()
        }
        C.ToolTip.visible: tc.tip !== "" && tcMa.containsMouse
        C.ToolTip.delay: 400
        C.ToolTip.text: tc.tip
    }

    // ---- left run: move · rate -------------------------------------------
    Row {
        id: leftRun
        anchors { left: parent.left; bottom: parent.bottom; leftMargin: bar.padL; bottomMargin: 9 }
        spacing: 9
        TGroup {
            TCell { icon: "jumpBack"; tip: qsTr("Back 10 s ←"); cellEnabled: bar.canPlay; onActivated: bar.back10() }
            TCell {
                id: stepBackCell
                icon: "stepBack"; tip: qsTr("Step back one frame ,"); cellEnabled: bar.canPlay
                onActivated: bar.stepBack()
                // Backward stepping is visibly asymmetric and must STAY visible: a
                // 2px accent hairline for the cache fetch. Not a spinner and not a
                // disabled state — the step still happens (spec §2.4, §3.6).
                Rectangle {
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                    height: 2; color: Theme.accent; visible: bar.backFetching
                }
            }
            TCell { icon: bar.playing ? "pause" : "play"; primary: true
                    tip: bar.playing ? qsTr("Pause Space") : qsTr("Play Space")
                    cellEnabled: bar.canPlay; onActivated: bar.playPause() }
            TCell { icon: "stepFwd"; tip: qsTr("Step forward one frame ."); cellEnabled: bar.canPlay
                    onActivated: bar.stepFwd() }
            TCell { icon: "jumpFwd"; tip: qsTr("Forward 10 s →"); cellEnabled: bar.canPlay; onActivated: bar.fwd10() }
        }
        // Rate sits directly beside the step buttons because it modifies how they move.
        TGroup {
            id: rateGroup
            TCell {
                id: rateCell
                on: bar.ladderOpen
                cellEnabled: bar.canPlay
                width: 52
                // The scan boundary is SHOWN, not named: the words "SCAN" and
                // "frames skipped" are engineering vocabulary that read as a fault
                // report to a guard under pressure. Colour marks the boundary; the
                // tooltip says it in plain words.
                tip: qsTr("Playback rate — J / L. Above 10× the picture skips ahead to keep up.")
                onActivated: bar.ladderToggled()
                Row {
                    anchors.centerIn: parent
                    spacing: 3
                    Text { text: bar.fmtRate(bar.rate)
                        color: bar.rate > bar.maxDecodeRate ? Theme.bad : Qt.rgba(1, 1, 1, 0.78)
                        font.family: Theme.fontMono; font.pixelSize: 11; font.weight: Font.DemiBold
                        anchors.verticalCenter: parent.verticalCenter }
                    Text { text: "▴"; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 8
                        anchors.verticalCenter: parent.verticalCenter }
                }
            }
        }
    }

    // ---- speed ladder — all ten rates at once (spec §2.4) ----------------
    Rectangle {
        id: ladder
        visible: bar.ladderOpen
        z: 20
        width: 120
        height: bar.rates.length * 24 + 5
        x: leftRun.x + rateGroup.x + rateGroup.width / 2 - width / 2
        y: bar.height - 9 - 34 - 4 - height
        color: Theme.panel
        border.width: 1; border.color: Theme.line2
        Column {
            anchors.fill: parent
            anchors.margins: 1
            Repeater {
                // fastest at the top, so the ladder reads like a throttle
                model: bar.rates.length
                delegate: Column {
                    required property int index
                    readonly property real r: bar.rates[bar.rates.length - 1 - index]
                    width: ladder.width - 2
                    // a 5px hairline break above 10× — no text
                    Rectangle {
                        visible: parent.r === 10
                        width: parent.width; height: 5; color: Theme.bg
                        Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Theme.line2 }
                        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line2 }
                    }
                    Rectangle {
                        width: parent.width; height: 24
                        readonly property bool isScan: parent.r > bar.maxDecodeRate
                        readonly property bool isOn: Math.abs(bar.rate - parent.r) < 0.001
                        color: isOn ? (isScan ? Theme.bad : Theme.accent)
                                    : (lrMa.containsMouse ? Theme.panel2 : "transparent")
                        Text {
                            anchors { left: parent.left; leftMargin: 9; verticalCenter: parent.verticalCenter }
                            text: bar.fmtRate(parent.parent.r)
                            color: parent.isOn ? (parent.isScan ? "#ffffff" : "#241a08")
                                   : parent.isScan ? Theme.bad : Theme.ink2
                            font.family: Theme.fontMono; font.pixelSize: 11
                            font.weight: parent.isOn ? Font.Bold : Font.Normal
                        }
                        Text {
                            visible: parent.isScan
                            anchors { right: parent.right; rightMargin: 9; verticalCenter: parent.verticalCenter }
                            text: "▸"
                            color: parent.isOn ? "#ffffff" : Theme.bad
                            font.family: Theme.fontMono; font.pixelSize: 8
                        }
                        MouseArea {
                            id: lrMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: bar.ratePicked(parent.parent.r)
                        }
                    }
                }
            }
        }
    }

    // ---- centre: the frame cluster, pinned absolutely --------------------
    // Spacers would centre it on the LEFTOVER space, so revealing the range
    // cells slid it 75px — the worst possible behaviour for the one control an
    // operator presses to enter that mode. The cluster centres as a whole.
    TGroup {
        id: frameCluster
        anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 9 }
        // Icon only. The centre is a position nothing else can claim, and that is
        // what marks it as a mode; a word there would make it one more button.
        TCell { frameMark: true; primary: true; on: bar.frameMode; cellEnabled: bar.canPlay
                tip: qsTr("Frame-by-frame F"); onActivated: bar.frameToggled() }
        TCell { visible: bar.rangeTools; glyph: "["; tint: Theme.good; cellEnabled: bar.canPlay
                tip: qsTr("Mark in ["); onActivated: bar.markIn() }
        TCell { visible: bar.rangeTools; glyph: "]"; tint: Theme.good; cellEnabled: bar.canPlay
                tip: qsTr("Mark out ]"); onActivated: bar.markOut() }
        // The only width-changing cell (Export → 4m 12s) ENDS the run, so nothing
        // it grows into can shift a button the operator is aiming at.
        TCell {
            visible: bar.rangeTools
            exportMark: true; tint: Theme.good
            label: bar.markMs > 0 ? PbFmt.dur(bar.markMs) : qsTr("Export")
            cellEnabled: bar.canPlay && bar.markMs > 0
            tip: qsTr("Export marked range X")
            onActivated: bar.exportClicked()
        }
    }

    // ---- right: the two ways off the screen -------------------------------
    Row {
        anchors { right: parent.right; bottom: parent.bottom; rightMargin: bar.padR; bottomMargin: 9 }
        spacing: 9
        TGroup {
            TCell { icon: "full"; on: bar.fullscreenOn
                    tip: qsTr("Fullscreen Shift F"); onActivated: bar.fullscreenToggled() }
            TCell { icon: "shot"; tint: Theme.good; cellEnabled: bar.canPlay
                    tip: qsTr("Snapshot S"); onActivated: bar.snapshot() }
            TCell {
                icon: "shot"; tint: Theme.good; cellEnabled: bar.canPlay
                tip: qsTr("Snapshot with timestamp Shift S"); onActivated: bar.snapshotStamped()
                Text { anchors { right: parent.right; rightMargin: 5; bottom: parent.bottom; bottomMargin: 5 }
                       text: "T"; color: Theme.good; font.family: Theme.fontMono; font.pixelSize: 9
                       font.weight: Font.Bold }
            }
            TCell {
                id: liveCell
                tint: Theme.bad
                hoverTint: Qt.rgba(Theme.bad.r, Theme.bad.g, Theme.bad.b, 0.2)
                width: liveRow.implicitWidth + 22
                onActivated: bar.returnToLive()
                Row {
                    id: liveRow
                    anchors.centerIn: parent; spacing: 7
                    Rectangle { width: 6; height: 6; radius: 3; color: Theme.bad
                                anchors.verticalCenter: parent.verticalCenter }
                    Text { text: qsTr("Return to Live"); color: Theme.bad
                           font.family: Theme.fontSans; font.pixelSize: 11
                           anchors.verticalCenter: parent.verticalCenter }
                }
            }
        }
    }
}
