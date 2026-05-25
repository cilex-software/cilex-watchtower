import QtQuick
import QtQuick.Shapes
import Watchtower

// Loading is a first-class state alongside empty/error (design §31). A calm
// rotating arc plus a plain-language label (e.g. "Connecting…").
Item {
    id: root

    property string label: "Loading…"
    property int ringSize: 20
    property color ringColor: Theme.accent

    Column {
        anchors.centerIn: parent
        spacing: Theme.s12

        Shape {
            id: ring
            anchors.horizontalCenter: parent.horizontalCenter
            width: root.ringSize
            height: root.ringSize
            antialiasing: true
            transformOrigin: Item.Center

            ShapePath {
                strokeColor: root.ringColor
                strokeWidth: 2
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                    centerX: root.ringSize / 2
                    centerY: root.ringSize / 2
                    radiusX: root.ringSize / 2 - 2
                    radiusY: root.ringSize / 2 - 2
                    startAngle: -90
                    sweepAngle: 280
                }
            }

            RotationAnimation on rotation {
                running: root.visible
                loops: Animation.Infinite
                from: 0
                to: 360
                duration: 900
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.label
            color: Theme.ink2
            font.family: Theme.fontMono
            font.pixelSize: Theme.fsMono
            font.letterSpacing: 0.4
        }
    }
}
