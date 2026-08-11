import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls.Basic as C
import Watchtower

// Window title bar — design "Window shell" (36px): wordmark left, three round
// window buttons right (minimize · maximize · close).
//
// The handoff drew this bar as "generic OS-style, replaced by host". The host
// chrome we actually get under GNOME/Wayland is Qt's own client-side decoration,
// which paints a title strip with NO usable window buttons (operator report
// 2026-07-25) — so the window is frameless (Main.qml) and Watchtower draws the
// designed bar itself. Dragging hands a move grab to the compositor,
// double-click maximizes/restores; the resize edges live in Main.qml.
Item {
    id: root

    property var win: null            // the Window this bar drives
    property string subtitle: ""      // the view currently on screen (ink-2)

    implicitHeight: Theme.titleBarHeight

    readonly property bool maximized: root.win !== null && root.win.visibility === Window.Maximized

    function toggleMaximize() {
        if (!root.win) return;
        root.win.visibility = root.maximized ? Window.Windowed : Window.Maximized;
    }

    // ------------------------------------------------------------- surface
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: Theme.titleBarTop }
            GradientStop { position: 1.0; color: Theme.titleBarBottom }
        }
        Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 1
            color: "#000000"
        }
    }

    // ------------------------------------------ drag to move / dbl-click max
    // Declared BEFORE the content row so the window buttons keep their own
    // clicks. The move grab is handed to the compositor only past a small
    // threshold — starting it on press would swallow the second click of a
    // double-click (the same rule Qt's own decoration follows).
    MouseArea {
        anchors.fill: parent
        property real pressX: 0
        property real pressY: 0
        property bool moving: false
        onPressed: (m) => { pressX = m.x; pressY = m.y; moving = false }
        onPositionChanged: (m) => {
            if (!moving && pressed && root.win
                    && (Math.abs(m.x - pressX) > 3 || Math.abs(m.y - pressY) > 3)) {
                moving = true;
                root.win.startSystemMove();
            }
        }
        onDoubleClicked: root.toggleMaximize()
    }

    // Window button: a 14px disc with an 8px glyph at 0.5 opacity (design), the
    // one deliberately round control in an otherwise orthogonal system.
    component WinBtn: Item {
        id: btn
        property string kind: "min"        // min | max | close
        property string tip: ""
        signal activated()

        implicitWidth: 14
        implicitHeight: 14
        Accessible.role: Accessible.Button
        Accessible.name: btn.tip
        Accessible.onPressAction: btn.activated()

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: btn.kind === "close"
                   ? (bMa.containsMouse ? Qt.lighter(Theme.bad, 1.2) : Theme.bad)
                   : (bMa.containsMouse ? Theme.ink3 : Theme.line2)
        }
        Item {
            anchors.fill: parent
            opacity: bMa.containsMouse ? 1.0 : 0.5
            Behavior on opacity { NumberAnimation { duration: 90 } }

            Rectangle {                      // minimize — a single rule
                visible: btn.kind === "min"
                anchors.centerIn: parent
                width: 6; height: 1.4
                color: Theme.windowBackdrop
            }
            Rectangle {                      // maximize / restore — a square outline
                visible: btn.kind === "max"
                anchors.centerIn: parent
                width: 6.4; height: 6.4
                color: "transparent"
                border.width: 1.2; border.color: Theme.windowBackdrop
            }
            Item {                           // close — a cross
                visible: btn.kind === "close"
                anchors.centerIn: parent
                width: 8; height: 8
                Rectangle { anchors.centerIn: parent; width: 7.2; height: 1.4
                            rotation: 45; antialiasing: true; color: Theme.windowBackdrop }
                Rectangle { anchors.centerIn: parent; width: 7.2; height: 1.4
                            rotation: -45; antialiasing: true; color: Theme.windowBackdrop }
            }
        }
        MouseArea {
            id: bMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.activated()
        }
        C.ToolTip.visible: bMa.containsMouse
        C.ToolTip.text: btn.tip
        C.ToolTip.delay: 400
    }

    // ------------------------------------------------------------- content
    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        spacing: 12

        // Design: fixed 70px left spacer — now also home to the Warden supervision
        // indicator: a near-invisible eye that is LIT only while Cilex Warden is
        // actually the parent process RIGHT NOW (MemTel keeps it honest with a
        // periodic getppid() check — a dead Warden re-parents us and the eye goes
        // out). Deliberately quiet: ink-3, no red state, no alarm — the guard is
        // never the detector; unsupervised simply shows nothing here. It exists
        // for the OPERATOR's glance ("is this station watched?"), hence the
        // tooltip carries the Warden version.
        Item {
            Layout.preferredWidth: 70
            Layout.fillHeight: true
            Item {
                id: wardenEye
                visible: typeof MemTel !== "undefined" && MemTel.underWarden
                anchors { left: parent.left; leftMargin: 2; verticalCenter: parent.verticalCenter }
                width: 20; height: 20
                Icon {
                    anchors.centerIn: parent
                    name: "eye"; size: 12
                    color: eyeMa.containsMouse ? Theme.ink2 : Theme.ink3
                    opacity: 0.8
                }
                MouseArea { id: eyeMa; anchors.fill: parent; hoverEnabled: true }
                C.ToolTip.visible: eyeMa.containsMouse
                C.ToolTip.delay: 400
                C.ToolTip.text: qsTr("Supervised by Cilex Warden %1 — auto-restart and crash reporting armed")
                                .arg(typeof wtWardenVersion !== "undefined" && wtWardenVersion !== "" ? wtWardenVersion : "")
            }
        }

        Text {
            Layout.alignment: Qt.AlignVCenter
            text: qsTr("WATCHTOWER")
            color: Theme.ink
            font.family: Theme.fontMono
            font.pixelSize: 11
            font.weight: Font.DemiBold
            font.letterSpacing: 0.66              // 0.06em
        }
        Text {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            text: root.subtitle !== "" ? ("· " + root.subtitle) : ""
            color: Theme.ink2
            font.family: Theme.fontSans
            font.pixelSize: 12
            elide: Text.ElideRight
        }

        Row {
            Layout.alignment: Qt.AlignVCenter
            spacing: 8
            WinBtn {
                kind: "min"; tip: qsTr("Minimize")
                onActivated: if (root.win) root.win.visibility = Window.Minimized
            }
            WinBtn {
                kind: "max"; tip: root.maximized ? qsTr("Restore") : qsTr("Maximize")
                onActivated: root.toggleMaximize()
            }
            WinBtn {
                kind: "close"; tip: qsTr("Close")
                onActivated: if (root.win) root.win.close()
            }
        }
    }
}
