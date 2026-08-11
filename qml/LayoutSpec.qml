pragma Singleton
import QtQuick

// Layout "brain" for the Live Monitor grid selector. Maps a canonical layout id
// to its grid geometry, enumerates the camera-tile cells, and produces display
// labels. The SAME cell enumeration drives both the NetIcon pictograms and the
// functional grid placement, so a pictogram is always an exact net of the wall.
//
// Canonical ids:
//   "1" "4" "9" "16" "25"             — symmetric grids (count == id)
//   "plus4" "plus6" "plus8"           — one big tile (camera 0) + smaller tiles
//   "center13"                        — one centered big tile + 12-tile ring
//   "<N>x<M>"                         — custom N columns × M rows, e.g. "5x4"
QtObject {
    id: root

    // Grid geometry for an id: { cols, rows, big } where big is null or the
    // spanning camera-0 tile { c, r, cw, ch } (cell-grid units).
    function params(id) {
        switch (id) {
        case "1":   return { cols: 1, rows: 1, big: null };
        case "4":   return { cols: 2, rows: 2, big: null };
        case "9":   return { cols: 3, rows: 3, big: null };
        case "16":  return { cols: 4, rows: 4, big: null };
        case "25":  return { cols: 5, rows: 5, big: null };
        case "plus4":    return { cols: 3, rows: 3, big: { c: 0, r: 0, cw: 2, ch: 3 } };
        case "plus6":    return { cols: 3, rows: 3, big: { c: 0, r: 0, cw: 2, ch: 2 } };
        case "plus8":    return { cols: 4, rows: 4, big: { c: 0, r: 0, cw: 3, ch: 3 } };
        case "center13": return { cols: 4, rows: 4, big: { c: 1, r: 1, cw: 2, ch: 2 } };
        }
        const m = /^(\d+)x(\d+)$/.exec(id);
        if (m) {
            const n = Math.max(1, Math.min(10, parseInt(m[1])));
            const mm = Math.max(1, Math.min(10, parseInt(m[2])));
            return { cols: n, rows: mm, big: null };
        }
        return { cols: 4, rows: 4, big: null }; // safe default ("16")
    }

    // Enumerate camera-tile cells in render/placement order: the big spanning
    // tile first (when present), then every cell NOT covered by big in row-major
    // order. Each entry is { c, r, cw, ch } in cell-grid units. NetIcon draws
    // these; the live grid places real tiles in these same cells.
    function cellRects(cols, rows, big) {
        const out = [];
        const covered = {};
        if (big) {
            out.push({ c: big.c, r: big.r, cw: big.cw, ch: big.ch });
            for (let bc = big.c; bc < big.c + big.cw; ++bc)
                for (let br = big.r; br < big.r + big.ch; ++br)
                    covered[bc + "," + br] = true;
        }
        for (let r = 0; r < rows; ++r)
            for (let c = 0; c < cols; ++c)
                if (!covered[c + "," + r])
                    out.push({ c: c, r: r, cw: 1, ch: 1 });
        return out;
    }

    function cells(id) {
        const p = params(id);
        return cellRects(p.cols, p.rows, p.big);
    }

    // Best uniform grid (cols×rows, cols*rows >= n) for n tiles of aspect
    // `tileAspect` inside a `contW`×`contH` box — the one that makes the fitted
    // (letterboxed) tiles LARGEST. This is how an uneven camera count is laid out
    // without stretching: 3 → 2×2 (2 over 1), 5 → 3×2, etc. Cells stay ~tileAspect.
    function bestGrid(n, contW, contH, tileAspect) {
        if (n < 1) return { cols: 1, rows: 1 };
        if (!(contW > 0) || !(contH > 0)) { contW = tileAspect; contH = 1; }
        let best = { cols: 1, rows: n }, bestArea = -1;
        for (let cols = 1; cols <= n; ++cols) {
            const rows = Math.ceil(n / cols);
            const cw = contW / cols, ch = contH / rows;
            const tw = Math.min(cw, ch * tileAspect);   // fitted tile width
            const area = tw * (tw / tileAspect);
            if (area > bestArea + 1e-6) { bestArea = area; best = { cols: cols, rows: rows }; }
        }
        return best;
    }

    // Number of camera tiles a layout shows (== number of cells).
    function count(id) { return cells(id).length; }

    // Human label, e.g. "4×4 · 16", "1 + 5 · 6", "Center + 12 · 13", "5×4 · 20".
    function label(id) {
        switch (id) {
        case "1":   return qsTr("Single · 1");
        case "4":   return qsTr("2×2 · 4");
        case "9":   return qsTr("3×3 · 9");
        case "16":  return qsTr("4×4 · 16");
        case "25":  return qsTr("5×5 · 25");
        case "plus4":    return qsTr("1 + 3 · 4");
        case "plus6":    return qsTr("1 + 5 · 6");
        case "plus8":    return qsTr("1 + 7 · 8");
        case "center13": return qsTr("Center + 12 · 13");
        }
        const m = /^(\d+)x(\d+)$/.exec(id);
        if (m) return m[1] + "×" + m[2] + " · " + (parseInt(m[1]) * parseInt(m[2]));
        return id;
    }
}
