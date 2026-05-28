import QtQuick
import Watchtower

// The ONE drawing primitive for grid-layout pictograms. Renders an accurate
// "net" of a wall layout: the big spanning tile (when given) as a subtle filled
// rect, every other camera cell as an outline rect — all drawn to scale from the
// parameters via the shared LayoutSpec.cellRects enumeration. Nothing else is
// ever drawn here (no glyphs, no decoration). See task spec / design §14.
Canvas {
    id: canvas

    property int cols: 2
    property int rows: 2
    property var big: null            // null or { c, r, cw, ch }
    property real gap: 1.4
    property real pad: 1.4
    property real sw: 1.0             // outline stroke width
    property real rx: 1.0             // corner radius
    property color color: Theme.ink2  // "currentColor"

    width: 16
    height: 16
    antialiasing: true

    // Repaint whenever any input (incl. size/color) changes.
    readonly property var repaintKey: [width, height, cols, rows, big, gap, pad, sw, rx, color]
    onRepaintKeyChanged: requestPaint()
    Component.onCompleted: requestPaint()

    onPaint: {
        const ctx = getContext("2d");
        ctx.reset();
        const w = width, h = height;
        const cw = (w - pad * 2 - gap * (cols - 1)) / cols;
        const ch = (h - pad * 2 - gap * (rows - 1)) / rows;
        const X = (c) => pad + c * (cw + gap);
        const Y = (r) => pad + r * (ch + gap);

        const rects = LayoutSpec.cellRects(cols, rows, big);
        for (let i = 0; i < rects.length; ++i) {
            const cell = rects[i];
            const x = X(cell.c), y = Y(cell.r);
            const rw = cw * cell.cw + gap * (cell.cw - 1);
            const rh = ch * cell.ch + gap * (cell.ch - 1);
            const r = Math.max(0, Math.min(rx, rw / 2, rh / 2));
            ctx.beginPath();
            ctx.roundedRect(x, y, rw, rh, r, r);
            if (big && i === 0) {
                // big tile: subtle filled emphasis
                ctx.fillStyle = Qt.rgba(color.r, color.g, color.b, 0.18);
                ctx.fill();
            } else {
                // every other cell: outline only
                ctx.lineWidth = sw;
                ctx.strokeStyle = color;
                ctx.stroke();
            }
        }
    }
}
