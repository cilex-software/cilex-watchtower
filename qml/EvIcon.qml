import QtQuick
import QtQuick.Shapes
import Watchtower

// events-v2 icon set (designs/events-v2/data.jsx `I`), recreated 1:1 with Qt Quick
// Shapes so there is no Qt SVG image-plugin dependency. 24×24 viewbox; <circle>
// elements are rewritten as arc path data. Usage: EvIcon { name:"person"; size:16; color:Theme.accent }
Item {
    id: root
    property string name: ""
    property int size: 16
    property color color: Theme.ink2
    implicitWidth: size
    implicitHeight: size

    // p: stroke/fill path data · f: filled (else stroked) · w: stroke width (default
    // 1.6) · pf: filled overlay sub-path (e.g. the offline status dot).
    readonly property var _icons: ({
        "person":     { "p": "M8.8 7 a3.2 3.2 0 1 0 6.4 0 a3.2 3.2 0 1 0 -6.4 0 M5.5 20c0-3.6 2.9-6 6.5-6s6.5 2.4 6.5 6" },
        "vehicle":    { "p": "M3 13l1.6-4.5A2 2 0 0 1 6.5 7h11a2 2 0 0 1 1.9 1.5L21 13v4h-2M3 17v-4m0 4h2m14 0h-2M7 17h10 M5.4 17.5 a1.6 1.6 0 1 0 3.2 0 a1.6 1.6 0 1 0 -3.2 0 M15.4 17.5 a1.6 1.6 0 1 0 3.2 0 a1.6 1.6 0 1 0 -3.2 0" },
        "motion":     { "p": "M9.6 12 a2.4 2.4 0 1 0 4.8 0 a2.4 2.4 0 1 0 -4.8 0 M5.5 5.5a9 9 0 0 0 0 13M18.5 5.5a9 9 0 0 1 0 13M8 8a5 5 0 0 0 0 8M16 8a5 5 0 0 1 0 8" },
        "line_cross": { "p": "M3 17h18 M8 21l6-16M14 11l4 2-1-4" },
        "loiter":     { "p": "M3.5 12 a8.5 8.5 0 1 0 17 0 a8.5 8.5 0 1 0 -17 0 M12 7v5l3 2" },
        "tamper":     { "p": "M12 3l8 4v5c0 5-3.5 8-8 9-4.5-1-8-4-8-9V7z M9.5 9.5l5 5M14.5 9.5l-5 5" },
        "offline":    { "p": "M3 3l18 18M10.6 5.1A9 9 0 0 1 21 12M5 8a13 13 0 0 0 -2 4M8.5 11.5A5 5 0 0 1 16 12M9 15a5 5 0 0 1 5-1.5",
                        "pf": "M11.4 19 a0.6 0.6 0 1 0 1.2 0 a0.6 0.6 0 1 0 -1.2 0" },
        "check":      { "p": "M4 12.5l5 5L20 6.5", "w": 1.8 },
        "x":          { "p": "M6 6l12 12M18 6L6 18", "w": 1.8 },
        "escalate":   { "p": "M12 19V5M6 11l6-6 6 6" },
        "play":       { "p": "M7 5l12 7-12 7z", "f": true },
        "bookmark":   { "p": "M6 4h12v16l-6-4-6 4z" },
        "bookmarkF":  { "p": "M6 4h12v16l-6-4-6 4z", "f": true },
        "export":     { "p": "M12 3v12M8 7l4-4 4 4M5 14v5a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-5" },
        "dispatch":   { "p": "M21 3L11 13M21 3l-6 18-4-8-8-4z" },
        "assign":     { "p": "M6 8 a3 3 0 1 0 6 0 a3 3 0 1 0 -6 0 M3.5 19c0-3 2.4-5 5.5-5 1.2 0 2.3.3 3.2.9M16 11v6M13 14h6" },
        "chev":       { "p": "M9 6l6 6-6 6", "w": 1.8 },
        "clock":      { "p": "M3 12 a9 9 0 1 0 18 0 a9 9 0 1 0 -18 0 M12 7v5l3 2" },
        "pin":        { "p": "M12 21s7-5.5 7-11a7 7 0 1 0 -14 0c0 5.5 7 11 7 11z M9.5 10 a2.5 2.5 0 1 0 5 0 a2.5 2.5 0 1 0 -5 0" },
        "bell":       { "p": "M6 8a6 6 0 0 1 12 0c0 7 3 8 3 8H3s3-1 3-8 M10 21a2 2 0 0 0 4 0" }
    })
    readonly property var _cur: _icons[name] ? _icons[name] : null

    Shape {
        width: 24; height: 24
        antialiasing: true
        transform: Scale { xScale: root.size / 24; yScale: root.size / 24 }
        ShapePath {
            strokeColor: root._cur && root._cur.f ? "transparent" : root.color
            fillColor: root._cur && root._cur.f ? root.color : "transparent"
            strokeWidth: root._cur && root._cur.w ? root._cur.w : 1.6
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: root._cur ? root._cur.p : "" }
        }
        ShapePath {                                   // filled overlay (offline dot)
            strokeColor: "transparent"
            fillColor: root._cur && root._cur.pf ? root.color : "transparent"
            PathSvg { path: root._cur && root._cur.pf ? root._cur.pf : "" }
        }
    }
}
