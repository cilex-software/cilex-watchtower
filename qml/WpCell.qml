import QtQuick
import QtQuick.Controls.Basic as C
import Watchtower

// Wall playback — ONE cell overlay of the composited mosaic ("Roll Call" §2.2).
//
// The picture underneath is a cell of a SINGLE composited stream; this draws
// only the annotation over it. Position comes from the server's cells[] map,
// never a client list index — after a swap the two disagree for the 191-643 ms
// the re-composite takes, and drawing from the client list would put every name
// on the wrong picture for that whole time.
//
// A cell is exactly ONE of four states. The shipped build had one visual for
// all of them, which is the honesty failure the redesign exists to fix:
//
//   recording  the composite carries video here — picture shows through
//   dormant    this camera provably recorded nothing at this instant
//   unknown    we cannot tell — picture shows through, and we SAY we cannot tell
//   empty      no camera is assigned to this slot at all
//
// `unknown` is not in the spec's three; it is the honest degradation the spec's
// own trap demands. The offer in §2.2b needs per-camera availability, and the
// mosaic manifest reports availability per FRAGMENT (whole grid) only. Where the
// backend reports `recording_mode: motion` we can derive the answer soundly (a
// motion episode IS the recording episode for such a camera, ± its roll); where
// it reports no mode we must not infer "nothing recorded" from a dark pixel.
//
// UNKNOWN NO LONGER HATCHES (2026-09-24). It used to, and the consequence was a
// wall that showed nothing at all: `recording_profile.mode` is "continuous" on
// these cameras, `_isMotionMode()` is therefore false for every one of them,
// cellStateOf() answers "unknown" sixteen times, and sixteen opaque hatches went
// over a composite that WAS delivering frames. A guard saw an empty grid and no
// way to tell it from a dead wall.
//
// The hatch is for what we know is absent, not for what we cannot confirm.
// Hiding real server pixels behind it is "clearing an on-screen image" without a
// real identity change — the thing CLAUDE.md forbids outright, and the same
// failure as the every-poll tile blanking (888c5da) and the events-rail strobe
// (f5021b7). So `unknown` now shows the picture and carries a corner badge that
// says the state is unconfirmed. The operator sees the footage AND is told we
// cannot vouch for it, which is strictly more information than a hatch.
//
// This does NOT restore the original sin. The sin was letting a black cell be
// READ as "nothing recorded"; the badge names the uncertainty out loud, and a
// composite that never produces frames at all is still caught by renderGuard in
// WallPlayback rather than by painting over it here.
Item {
    id: cell

    property string camId: ""
    property string octet: ""
    property string model: ""
    property string state: "unknown"      // recording | dormant | unknown | empty
    property bool motionNow: false
    property bool hovered: false
    property bool stamped: false          // T held — the sync proof
    property string stampText: ""
    property double offerMs: -1           // nearest footage for this camera, -1 = none
    property string offerLabel: ""        // e.g. "← 11:15"

    signal jumpRequested(double ms)
    signal pickRequested()
    signal hoverChanged(string camId, bool on)

    // Hatched = we can PROVE there is nothing here. `unknown` is not proof, so it
    // is not hatched; it shows whatever the composite has and says it is unconfirmed.
    readonly property bool _hatched: state === "dormant"
    // Cells where server pixels may be arriving. These need the scrim and white
    // type, or the name sits unreadable on top of the picture.
    readonly property bool _hasPicture: state === "recording" || state === "unknown"

    // ---- field ------------------------------------------------------------
    // Dormant is a 6px diagonal hatch, never flat black: black is what a
    // FAILURE looks like, and the whole point of the state is that it is
    // unmistakably drawn. Empty is a flat darker field — "no camera here" and
    // "this camera recorded nothing" are different facts and never share pixels.
    Rectangle {
        anchors.fill: parent
        visible: cell.state === "empty"
        color: "#100f0e"
    }
    Item {
        anchors.fill: parent
        visible: cell._hatched
        clip: true
        Rectangle { anchors.fill: parent; color: "#131211" }
        // 6px bars on a 12px pitch at 135°. Rotated about their CENTRE and made
        // long enough to cross the cell corner-to-corner, so the band always
        // spans the clip rect — rotating about the top-left leaves the first and
        // last bars outside it and the hatch silently vanishes.
        Repeater {
            model: Math.ceil((cell.width + cell.height) / 12) + 2
            delegate: Rectangle {
                required property int index
                readonly property real _len: (cell.width + cell.height) * 1.5
                width: 6
                height: _len
                color: "#171513"
                antialiasing: false
                transformOrigin: Item.Center
                rotation: 45
                x: index * 12 - cell.height - 6
                y: (cell.height - _len) / 2
            }
        }
    }

    // ---- identity ---------------------------------------------------------
    // Recording keeps a scrim so white type survives any picture; the dark
    // states drop it — a cell with nothing to show is not competing for
    // attention.
    Rectangle {
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: 22
        visible: cell._hasPicture
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#b3000000" }
            GradientStop { position: 1.0; color: "#00000000" }
        }
    }
    Row {
        anchors { left: parent.left; top: parent.top; leftMargin: 6; topMargin: 4 }
        spacing: 6
        visible: cell.state !== "empty"
        Text {
            text: cell.octet
            color: cell._hasPicture ? "#ffffff" : Theme.ink2
            font.family: Theme.fontMono; font.pixelSize: 11; font.weight: Font.DemiBold
        }
        Text {
            width: Math.max(0, cell.width - 60)
            text: cell.model
            color: cell._hasPicture ? "#9effffff" : Theme.ink3
            font.family: Theme.fontSans; font.pixelSize: 10
            elide: Text.ElideRight
        }
    }

    // ---- the fact, and the offer (§2.2b) ----------------------------------
    Column {
        anchors.centerIn: parent
        spacing: 7
        visible: cell._hatched && cell.height > 54
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            // Only a dormant cell reaches here now; `unknown` gets the corner badge
            // below instead, because it has a picture to not cover up.
            text: qsTr("NOTHING RECORDED")
            color: Theme.ink3
            font.family: Theme.fontMono; font.pixelSize: 9
            font.letterSpacing: 1.4; font.capitalization: Font.AllUppercase
        }
        // The offer is the redesign: a dormant cell knows something nothing else
        // on this screen knows — when its camera DID record, nearest to here —
        // so it renders that as content and clicking seeks the whole wall there.
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: cell.state === "dormant" && cell.offerMs > 0
            width: offT.implicitWidth + 16; height: 20
            color: offMa.containsMouse ? Theme.accentDim : Theme.accentSoft
            border.width: 1; border.color: Theme.accentDim
            Text {
                id: offT; anchors.centerIn: parent
                text: cell.offerLabel
                color: Theme.accent; font.family: Theme.fontMono; font.pixelSize: 10
            }
            MouseArea {
                id: offMa; anchors.fill: parent; hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: cell.jumpRequested(cell.offerMs)
            }
            C.ToolTip.visible: offMa.containsMouse
            C.ToolTip.delay: 400
            C.ToolTip.text: qsTr("Jump to this camera's nearest footage")
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: cell.state === "dormant" && cell.offerMs <= 0
            text: qsTr("none in this window")
            color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9
        }
    }

    // ---- unknown: say so WITHOUT covering the picture ----------------------
    // Bottom-right so it never collides with the identity row (top-left), the
    // MOTION chip (top-right) or the T-stamp (bottom-left). Its own scrim keeps
    // it legible over any footage; it is deliberately small, because the picture
    // is the content and this is a caveat about the picture.
    Rectangle {
        anchors { right: parent.right; bottom: parent.bottom; margins: 4 }
        visible: cell.state === "unknown" && !cell.hovered && cell.width > 96 && cell.height > 40
        width: unkT.implicitWidth + 12; height: 15
        color: "#cc16140f"
        border.width: 1; border.color: Theme.line2
        Text {
            id: unkT
            anchors.centerIn: parent
            text: qsTr("AVAILABILITY UNKNOWN")
            color: Theme.ink3
            font.family: Theme.fontMono; font.pixelSize: 8; font.letterSpacing: 1.1
        }
    }
    // Too small to carry the words: a bare dot, so the state is still visible on a
    // dense grid rather than silently dropping to "looks like it is recording".
    Rectangle {
        anchors { right: parent.right; bottom: parent.bottom; margins: 5 }
        visible: cell.state === "unknown" && !cell.hovered
                 && !(cell.width > 96 && cell.height > 40) && cell.width > 28
        width: 6; height: 6; radius: 3
        color: "#cc16140f"
        border.width: 1; border.color: Theme.ink3
    }

    // ---- empty slot -------------------------------------------------------
    Rectangle {
        anchors.centerIn: parent
        visible: cell.state === "empty" && cell.height > 40
        width: addT.implicitWidth + 20; height: 24
        color: addMa.containsMouse ? Theme.panel2 : "transparent"
        border.width: 1; border.color: addMa.containsMouse ? Theme.accent : Theme.line2
        Text {
            id: addT; anchors.centerIn: parent
            text: "+ " + qsTr("ADD CAMERA")
            color: addMa.containsMouse ? Theme.accent : Theme.ink3
            font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 1.2
        }
        MouseArea {
            id: addMa; anchors.fill: parent; hoverEnabled: true
            cursorShape: Qt.PointingHandCursor; onClicked: cell.pickRequested()
        }
    }

    // ---- motion now (§2.2d) — only ever on a RECORDING cell ---------------
    Rectangle {
        anchors.fill: parent
        visible: cell.motionNow && cell.state === "recording"
        color: "transparent"
        border.width: 2; border.color: Theme.accent
    }
    Rectangle {
        anchors { right: parent.right; top: parent.top; margins: 4 }
        visible: cell.motionNow && cell.state === "recording"
        width: mtT.implicitWidth + 10; height: 14
        color: Theme.accent
        Text {
            id: mtT; anchors.centerIn: parent; text: qsTr("MOTION")
            color: Theme.bg; font.family: Theme.fontMono; font.pixelSize: 8
            font.letterSpacing: 1.2; font.weight: Font.DemiBold
        }
    }

    // ---- correspondence ring (§2.2f) — one hoverCamera, three renderers ----
    Rectangle {
        anchors.fill: parent
        visible: cell.hovered && cell.state !== "empty"
        color: "transparent"
        border.width: 2; border.color: Theme.ink
    }

    // ---- T-held stamp (§2.3) — proof on demand, not asserted permanently ---
    Rectangle {
        anchors { left: parent.left; bottom: parent.bottom; margins: 4 }
        visible: cell.stamped && cell.state !== "empty"
        width: stT.implicitWidth + 10; height: 16
        color: "#cc16140f"
        Text {
            id: stT; anchors.centerIn: parent; text: cell.stampText
            color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 9
        }
    }

    // ---- gesture affordances (§2.2e) — replaces the deleted hint line ------
    Row {
        anchors { right: parent.right; bottom: parent.bottom; margins: 4 }
        spacing: 4
        visible: cell.hovered && cell.state !== "empty" && cell.width > 90
        Rectangle {
            width: 20; height: 20
            color: "#d10d0c0b"; border.width: 1
            border.color: swMa.containsMouse ? Theme.accent : Theme.line2
            Text { anchors.centerIn: parent; text: "⇄"; color: swMa.containsMouse ? Theme.accent : Theme.ink2; font.pixelSize: 11 }
            MouseArea {
                id: swMa; anchors.fill: parent; hoverEnabled: true
                cursorShape: Qt.PointingHandCursor; onClicked: cell.pickRequested()
            }
            C.ToolTip.visible: swMa.containsMouse; C.ToolTip.delay: 400
            C.ToolTip.text: qsTr("Choose another camera for this tile")
        }
        Rectangle {
            width: 20; height: 20
            color: "#d10d0c0b"; border.width: 1; border.color: Theme.line2
            Text { anchors.centerIn: parent; text: "✥"; color: Theme.ink2; font.pixelSize: 11 }
            // drag itself is handled by the grid's own drag MouseArea underneath;
            // this is the affordance that says the gesture exists
        }
    }

    HoverHandler {
        enabled: cell.state !== "empty"
        onHoveredChanged: cell.hoverChanged(cell.camId, hovered)
    }
}
