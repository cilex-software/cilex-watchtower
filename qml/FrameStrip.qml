import QtQuick
import Watchtower

// Frame-by-frame FILMSTRIP (playback frameMode, toggled with F): big neighbor
// thumbnails around the current frame, current one centered and accented.
// Thumbs come straight from the decoded-frame cache (image://fcache/<pts>);
// the hidden harvester keeps the cache filled ahead/behind, so slots are
// normally always populated.
//
// Smoothness rules (operator-driven, 2026-07-09):
// • FIXED slot count — delegates persist; only their pts rebinds.
// • Each tile is DOUBLE-BUFFERED: the old frame stays painted until the new
//   one has decoded, so a tile never blanks to black mid-swap.
// • Neighbors must be ADJACENT: slots chain outward from the center with a
//   max gap of ~2.6×frame-duration — a cached frame from some other region
//   (an earlier visit) can never masquerade as "the next frame". Beyond a
//   chain break the slot shows a quiet placeholder until the harvester fills
//   the true neighbors.
// • URLs are only minted for frames that EXIST in the cache (a miss would pin
//   a black pixmap to that URL in Qt's image cache forever).
Item {
    id: strip

    property double currentPts: -1
    property int sideSlots: 3                   // neighbors shown each side
    property var clockOf: null                  // function(ptsMs) → "HH:mm:ss.mmm"
    signal jumpRequested(double pts)

    readonly property real _dur: FrameClock.medianFrameDurMs > 1 ? FrameClock.medianFrameDurMs : 50
    // Floor at 130 ms: VFR streams mix 40/80/100 ms intervals while the MEDIAN can
    // sit at 30-50 ms — 2.6×median then knife-edges below a real 80 ms gap and the
    // strip drops tiles that ARE cached (fsoak window-3). 130 ms still can't stitch
    // across true region jumps (those are seconds apart).
    readonly property real _chainLim: Math.max(2.6 * _dur, 130)

    function ptsForIndex(i) {
        var rev = FrameCache.rev;               // dependency: re-evaluate on cache changes
        if (currentPts <= 0) return -1;
        var off = i - sideSlots;
        // center: the cursor's own frame, only if actually cached
        var c = FrameCache.cachedAround(currentPts + 2, 1, 0);
        var center = (c.length > 0 && Math.abs(c[c.length - 1] - currentPts) <= 2) ? c[c.length - 1] : -1;
        if (off === 0) return center;
        var base = center >= 0 ? center : currentPts;
        if (off > 0) {
            var above = FrameCache.cachedAround(base, 0, sideSlots);
            var prev = base, n = 0;
            for (var a = 0; a < above.length; a++) {
                if (above[a] - prev > _chainLim) break;      // chain broken — another region
                prev = above[a]; n++;
                if (n === off) return above[a];
            }
            return -1;
        }
        var below = FrameCache.cachedAround(base, sideSlots + 1, 0);
        var left = [], p = base;
        for (var b = below.length - 1; b >= 0; b--) {
            if (below[b] >= base - 2) continue;              // skip the base key itself
            if (p - below[b] > _chainLim) break;             // chain broken
            left.unshift(below[b]); p = below[b];
        }
        var idx = left.length + off;                          // off negative: -1 → rightmost of left
        return idx >= 0 ? left[idx] : -1;
    }

    Row {
        anchors.centerIn: parent
        spacing: 8
        Repeater {
            model: 2 * strip.sideSlots + 1      // FIXED count — delegates persist
            delegate: Rectangle {
                id: tile
                required property int index
                readonly property bool cur: index === strip.sideSlots
                readonly property double pts: strip.ptsForIndex(index)
                property double shownPts: -1    // what's actually painted right now
                property bool frontA: true
                width: cur ? Math.round(strip.height * 16 / 9) : Math.round(strip.height * 0.78 * 16 / 9)
                height: cur ? strip.height : Math.round(strip.height * 0.78)
                anchors.verticalCenter: parent.verticalCenter
                color: "#101010"
                border.width: cur ? 2 : 1
                border.color: cur ? Theme.accent : Theme.line2
                opacity: cur ? 1.0 : (shownPts > 0 ? 0.85 : 0.45)

                function _url(p) { return "image://fcache/" + Math.round(p); }
                // Double-buffer: load the NEW frame into the back image; swap only
                // when it's decoded — the front keeps the previous frame painted.
                onPtsChanged: {
                    if (pts <= 0) { shownPts = -1; imgA.source = ""; imgB.source = ""; return; }
                    if (Math.abs(pts - shownPts) < 1) return;
                    (frontA ? imgB : imgA).source = _url(pts);
                }
                function _swapIfReady(img, isA) {
                    if (img.status !== Image.Ready) return;
                    if (isA === frontA) return;                       // it's the front already
                    if (tile.pts > 0 && String(img.source) === _url(tile.pts)) {
                        frontA = isA;
                        shownPts = tile.pts;
                    }
                }
                Image {
                    id: imgA
                    anchors.fill: parent; anchors.margins: tile.cur ? 2 : 1
                    visible: tile.frontA && tile.shownPts > 0
                    asynchronous: true
                    fillMode: Image.PreserveAspectFit
                    onStatusChanged: tile._swapIfReady(imgA, true)
                }
                Image {
                    id: imgB
                    anchors.fill: parent; anchors.margins: tile.cur ? 2 : 1
                    visible: !tile.frontA && tile.shownPts > 0
                    asynchronous: true
                    fillMode: Image.PreserveAspectFit
                    onStatusChanged: tile._swapIfReady(imgB, false)
                }
                Text {                            // placeholder — nothing painted yet
                    anchors.centerIn: parent
                    visible: tile.shownPts < 0   // pts 0 is a real frame (day start), not a placeholder
                    text: "·"
                    color: Theme.ink3; font.pixelSize: 18
                }
                Rectangle {                       // per-thumb timestamp footer (only over a real frame)
                    visible: tile.shownPts > 0
                    anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                    height: 14; color: Qt.rgba(0, 0, 0, 0.62)
                    Text {
                        anchors.centerIn: parent
                        text: tile.shownPts > 0 && strip.clockOf ? strip.clockOf(tile.shownPts) : ""
                        color: tile.cur ? Theme.accent : Theme.ink2
                        font.family: Theme.fontMono; font.pixelSize: 9
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    enabled: tile.pts > 0 && !tile.cur
                    cursorShape: Qt.PointingHandCursor
                    onClicked: strip.jumpRequested(tile.pts)
                }
            }
        }
    }
}
