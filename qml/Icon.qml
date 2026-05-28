import QtQuick
import QtQuick.Shapes
import Watchtower

// Stroke-based outline icon set recreated from the prototype's inline SVG set
// (24×24 viewbox, 1.5px stroke). Rendered with Qt Quick Shapes so there is no
// dependency on the Qt SVG image plugin. Usage: Icon { name: "search"; size: 16; color: Theme.ink2 }
Item {
    id: root

    property string name: ""
    property int size: 16
    property color color: Theme.ink2

    implicitWidth: size
    implicitHeight: size

    // name -> { p: SVG path data, f: filled (else stroked), w: stroke width (default 1.5) }
    readonly property var _icons: ({
        "monitor":  { "p": "M3 4h18v13h-18z M9 20h6 M12 17v3" },
        "grid":     { "p": "M3 3h7v7h-7z M14 3h7v7h-7z M3 14h7v7h-7z M14 14h7v7h-7z" },
        "layers":   { "p": "M12 3l9 5-9 5-9-5 9-5z M3 13l9 5 9-5" },
        "clip":     { "p": "M3 5h18v14h-18z M3 9h18 M7 5v14" },
        "bell":     { "p": "M6 8a6 6 0 0 1 12 0c0 7 3 8 3 8H3s3-1 3-8 M10 21a2 2 0 0 0 4 0" },
        "pulse":    { "p": "M3 12h4l3-8 4 16 3-8h4" },
        "gear":     { "p": "M19.4 15a1.7 1.7 0 00.3 1.8l.1.1a2 2 0 11-2.8 2.8l-.1-.1a1.7 1.7 0 00-1.8-.3 1.7 1.7 0 00-1 1.5V21a2 2 0 11-4 0v-.1a1.7 1.7 0 00-1.1-1.5 1.7 1.7 0 00-1.8.3l-.1.1a2 2 0 11-2.8-2.8l.1-.1a1.7 1.7 0 00.3-1.8 1.7 1.7 0 00-1.5-1H3a2 2 0 110-4h.1a1.7 1.7 0 001.5-1.1 1.7 1.7 0 00-.3-1.8l-.1-.1a2 2 0 112.8-2.8l.1.1a1.7 1.7 0 001.8.3H9a1.7 1.7 0 001-1.5V3a2 2 0 114 0v.1a1.7 1.7 0 001 1.5 1.7 1.7 0 001.8-.3l.1-.1a2 2 0 112.8 2.8l-.1.1a1.7 1.7 0 00-.3 1.8V9a1.7 1.7 0 001.5 1H21a2 2 0 110 4h-.1a1.7 1.7 0 00-1.5 1z M9 12 a3 3 0 1 0 6 0 a3 3 0 1 0 -6 0" },
        "search":   { "p": "M4 11 a7 7 0 1 0 14 0 a7 7 0 1 0 -14 0 M21 21l-4.3-4.3" },
        "x":        { "p": "M6 6l12 12 M18 6L6 18" },
        "play":     { "p": "M6 4l14 8-14 8V4z", "f": true },
        "pause":    { "p": "M6 4h4v16H6z M14 4h4v16h-4z", "f": true },
        "back":     { "p": "M15 6l-6 6 6 6" },
        "fwd":      { "p": "M9 6l6 6-6 6" },
        "jumpBack": { "p": "M11 8L5 12l6 4 M5 12h11a4 4 0 010 8" },
        "jumpFwd":  { "p": "M13 8l6 4-6 4 M19 12H8a4 4 0 100 8" },
        "full":     { "p": "M4 9V4h5 M20 9V4h-5 M4 15v5h5 M20 15v5h-5" },
        "shot":     { "p": "M3 6h18v14h-18z M8 13 a4 4 0 1 0 8 0 a4 4 0 1 0 -8 0 M9 6l2-2h2l2 2" },
        "bookmark": { "p": "M6 4h12v16l-6-4-6 4V4z" },
        "star":     { "p": "M12 3l2.7 6.3 6.8.5-5.2 4.5 1.6 6.7L12 17.5l-5.9 3.5 1.6-6.7L2.5 9.8l6.8-.5L12 3z" },
        "newtab":   { "p": "M14 4h6v6 M20 4l-9 9 M19 13v6H5V5h6" },
        "download": { "p": "M12 4v12 M6 12l6 6 6-6 M4 20h16" },
        "audio":    { "p": "M11 5L6 9H3v6h3l5 4V5z M15 9a4 4 0 010 6" },
        "audioMute":{ "p": "M11 5L6 9H3v6h3l5 4V5z M17 9l4 6 M21 9l-4 6" },
        "chev":     { "p": "M6 9l6 6 6-6" },
        "alert":    { "p": "M12 9v4 M12 17h.01 M10.3 3.9L1.8 18a2 2 0 001.7 3h17a2 2 0 001.7-3L13.7 3.9a2 2 0 00-3.4 0z" },
        "off":      { "p": "M4 12 a8 8 0 1 0 16 0 a8 8 0 1 0 -16 0 M6.3 6.3l11.4 11.4" },
        "rec":      { "p": "M6 12 a6 6 0 1 0 12 0 a6 6 0 1 0 -12 0", "f": true },
        "motion":   { "p": "M10 6 a2 2 0 1 0 4 0 a2 2 0 1 0 -4 0 M9 12l3-3 3 3-2 3v6 M9 21v-6" },
        "check":    { "p": "M5 12l5 5L20 7", "w": 2 }
    })

    readonly property var _cur: _icons[name] ? _icons[name] : null

    Shape {
        width: 24
        height: 24
        antialiasing: true
        // Author paths in the 24-unit viewbox, then scale to the requested size.
        // Scaling the whole shape also scales the stroke, matching the prototype
        // (1.5px stroke in a 24 box rendered at icon size).
        transform: Scale { xScale: root.size / 24; yScale: root.size / 24 }

        ShapePath {
            strokeColor: root._cur && root._cur.f ? "transparent" : root.color
            fillColor: root._cur && root._cur.f ? root.color : "transparent"
            strokeWidth: root._cur && root._cur.w ? root._cur.w : 1.5
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: root._cur ? root._cur.p : "" }
        }
    }
}
