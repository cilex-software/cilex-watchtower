import QtQuick
import QtQuick.Shapes

// Vehicle silhouette for EvSnapshot (port of data.jsx VehicleGlyph, viewBox 200×96).
Item {
    id: r
    property color color: "#b9c2cc"
    Shape {
        width: 200; height: 96
        antialiasing: true
        transform: Scale { xScale: r.width / 200; yScale: r.height / 96 }
        ShapePath {                          // body
            strokeColor: "transparent"; fillColor: r.color
            PathSvg { path: "M8 64c-4 0-6-3-5-7l6-20c2-6 7-10 13-10h70l34 6c8 1 18 5 28 11l24 6c5 1 9 5 9 10v8c0 3-2 5-5 5H8z" }
        }
        ShapePath {                          // windshield (rect 34,30 56×22)
            strokeColor: "transparent"; fillColor: "#11161c"
            PathSvg { path: "M34 30h56v22h-56z" }
        }
        ShapePath {                          // wheels — outer
            strokeColor: "transparent"; fillColor: "#0c0f13"
            PathSvg { path: "M33 74 a15 15 0 1 0 30 0 a15 15 0 1 0 -30 0 M137 74 a15 15 0 1 0 30 0 a15 15 0 1 0 -30 0" }
        }
        ShapePath {                          // wheels — inner hub
            strokeColor: "transparent"; fillColor: r.color
            PathSvg { path: "M41 74 a7 7 0 1 0 14 0 a7 7 0 1 0 -14 0 M145 74 a7 7 0 1 0 14 0 a7 7 0 1 0 -14 0" }
        }
    }
}
