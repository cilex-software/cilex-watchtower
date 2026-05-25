import QtQuick
import Watchtower

// Stand-in for a real camera feed (used until the GStreamer video item lands,
// and as the fallback for stale/failed states). Warm near-black base per
// pattern, a faint architectural schematic, a timestamp, and an id label.
Item {
    id: root

    property int pattern: 0          // 0..3
    property string ts: ""
    property string label: ""
    property string geom: "corridor" // "parking" | "lobby" | "corridor"

    readonly property var _bg: ["#181612", "#11151a", "#0d1318", "#161219"]

    Rectangle {
        anchors.fill: parent
        color: root._bg[root.pattern % 4]
    }

    Canvas {
        id: schematic
        anchors.fill: parent
        opacity: 0.18
        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            ctx.strokeStyle = "#ffffff";
            const W = width, H = height;
            const sx = W / 200, sy = H / 120;
            function line(x1, y1, x2, y2, w) {
                ctx.beginPath();
                ctx.lineWidth = w * sx;
                ctx.moveTo(x1 * sx, y1 * sy);
                ctx.lineTo(x2 * sx, y2 * sy);
                ctx.stroke();
            }
            function rect(x, y, w, h, lw) {
                ctx.lineWidth = lw * sx;
                ctx.strokeRect(x * sx, y * sy, w * sx, h * sy);
            }
            if (root.geom === "parking") {
                line(0, 100, 200, 80, 0.5); line(40, 120, 80, 60, 0.5); line(200, 120, 130, 60, 0.5);
                rect(60, 65, 14, 8, 0.4); rect(100, 62, 14, 8, 0.4);
            } else if (root.geom === "lobby") {
                rect(20, 50, 40, 60, 0.4); rect(140, 40, 40, 70, 0.4); line(0, 100, 200, 100, 0.4);
            } else {
                line(0, 20, 100, 60, 0.4); line(200, 20, 100, 60, 0.4);
                line(0, 100, 100, 60, 0.4); line(200, 100, 100, 60, 0.4);
            }
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }

    Text {
        visible: root.ts !== ""
        text: root.ts
        anchors { top: parent.top; right: parent.right; topMargin: 6; rightMargin: 8 }
        font.family: Theme.fontMono
        font.pixelSize: 10
        color: Qt.rgba(1, 1, 1, 0.55)
    }

    Text {
        visible: root.label !== ""
        text: root.label
        anchors { left: parent.left; bottom: parent.bottom; leftMargin: 8; bottomMargin: 6 }
        font.family: Theme.fontMono
        font.pixelSize: 9
        font.letterSpacing: 0.9
        color: Qt.rgba(1, 1, 1, 0.35)
    }
}
