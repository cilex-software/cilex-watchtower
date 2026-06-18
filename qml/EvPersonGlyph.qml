import QtQuick
import QtQuick.Shapes

// Person silhouette for EvSnapshot (port of data.jsx PersonGlyph, viewBox 42×100).
Item {
    id: r
    property color color: "#cdd6df"
    Shape {
        width: 42; height: 100
        antialiasing: true
        transform: Scale { xScale: r.width / 42; yScale: r.height / 100 }
        ShapePath {                          // head (ellipse cx21 cy11 rx8.5 ry9)
            strokeColor: "transparent"; fillColor: r.color
            PathSvg { path: "M12.5 11 a8.5 9 0 1 0 17 0 a8.5 9 0 1 0 -17 0" }
        }
        ShapePath {                          // body
            strokeColor: "transparent"; fillColor: r.color
            PathSvg { path: "M9 34c0-7 5-12 12-12s12 5 12 12v22c0 3-2 4-4 4l-1 26h-4l-1.5-24h-3L20 86h-4l-1-26c-2 0-4-1-4-4z" }
        }
    }
}
