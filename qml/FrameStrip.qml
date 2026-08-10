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
    property int sideSlots: 4                   // neighbors shown each side (9 frames total)
    property var clockOf: null                  // function(ptsMs) → "HH:mm:ss.mmm"
    signal jumpRequested(double pts)

    // A strip where NOTHING resolves is the state the operator cannot read: nine
    // placeholder dots say "there are no frames" even when the cache is full and
    // the slots simply cannot chain to a cursor that has moved (measured 2026-08-10:
    // lit=0/9 against cache=288f for 60 s+ after a re-open resumed playback).
    // Each tile keeps its own bit here, so this costs nothing on the rev path —
    // it only changes when a slot's pts changes.
    property int _litMask: 0
    readonly property bool _blank: _litMask === 0
    // Debounced: a re-open legitimately blanks the strip for the ~1 s it takes the
    // first frame to land. Only a blank that PERSISTS is worth explaining.
    property bool _settled: false
    readonly property bool _explain: _blank && _settled
    Timer {
        interval: 1500; repeat: false
        running: strip._blank                       // restarts on every fresh blank
        onRunningChanged: if (running) strip._settled = false
        onTriggered: strip._settled = true
    }

    // Cells FLEX rather than sit at a fixed size (spec §2.4, the filmstrip): a
    // 171px width cap, an 80px height cap and a 16:9 ratio, so whichever
    // dimension binds drives the other and the band fits its frames at any
    // window width, at 1440 and at 1200, with zero overflow.
    readonly property int slots: 2 * sideSlots + 1
    readonly property real _gap: 6
    readonly property real _wByW: Math.min(171, (width - _gap * (slots - 1)) / slots)
    readonly property real _wByH: Math.min(80, height) * 16 / 9
    readonly property real cellW: Math.max(24, Math.min(_wByW, _wByH))
    readonly property real cellH: Math.round(cellW * 9 / 16)

    readonly property real _dur: FrameClock.medianFrameDurMs > 1 ? FrameClock.medianFrameDurMs : 50
    // Floor at 130 ms: VFR streams mix 40/80/100 ms intervals while the MEDIAN can
    // sit at 30-50 ms — 2.6×median then knife-edges below a real 80 ms gap and the
    // strip drops tiles that ARE cached (fsoak window-3). 130 ms still can't stitch
    // across true region jumps (those are seconds apart).
    readonly property real _chainLim: Math.max(2.6 * _dur, 130)

    function ptsForIndex(i) {
        var rev = FrameCache.rev;               // dependency: re-evaluate on cache changes
        // `< 0`, never `<= 0`: PTS 0 is a REAL frame — the first frame of a fresh
        // window, which is exactly where a far-seek re-open lands. Rejecting it
        // blanked all nine slots for as long as the cursor sat there (the same
        // pts-0-is-a-valid-cursor rule the stepper chain learned in the 2026-07-11
        // soak, never applied here).
        if (currentPts < 0) return -1;
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

    Text {
        anchors.centerIn: parent
        visible: strip._explain
        text: qsTr("No frames cached around this moment — pause to fill the strip")
        color: Theme.ink3
        font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 1.4
    }

    Row {
        anchors.centerIn: parent
        visible: !strip._explain
        spacing: strip._gap
        Repeater {
            model: strip.slots                  // FIXED count — delegates persist
            delegate: Rectangle {
                id: tile
                required property int index
                readonly property bool cur: index === strip.sideSlots
                readonly property double pts: strip.ptsForIndex(index)
                property double shownPts: -1    // what's actually painted right now
                property bool frontA: true
                width: strip.cellW
                height: strip.cellH
                anchors.verticalCenter: parent.verticalCenter
                color: "#141312"
                border.width: cur ? 2 : 1
                border.color: cur ? Theme.accent : Theme.line
                opacity: cur ? 1.0 : (shownPts >= 0 ? 0.9 : 0.5)

                function _url(p) { return "image://fcache/" + Math.round(p); }
                // `< 0` is the only sentinel — PTS 0 is a REAL frame (the first frame
                // of a window). Guarding with `<= 0` here left the CENTRE tile — the
                // operator's own frame — showing a placeholder dot over a cache that
                // held it, every time a re-open landed at the head of a window.
                // Double-buffer: load the NEW frame into the back image; swap only
                // when it's decoded — the front keeps the previous frame painted.
                onPtsChanged: {
                    strip._litMask = pts >= 0 ? (strip._litMask | (1 << index))
                                              : (strip._litMask & ~(1 << index));
                    if (pts < 0) { shownPts = -1; imgA.source = ""; imgB.source = ""; return; }
                    if (shownPts >= 0 && Math.abs(pts - shownPts) < 1) return;
                    (frontA ? imgB : imgA).source = _url(pts);
                }
                Component.onCompleted: if (pts >= 0) strip._litMask |= (1 << index);
                function _swapIfReady(img, isA) {
                    if (img.status !== Image.Ready) return;
                    if (isA === frontA) return;                       // it's the front already
                    if (tile.pts >= 0 && String(img.source) === _url(tile.pts)) {
                        frontA = isA;
                        shownPts = tile.pts;
                    }
                }
                Image {
                    id: imgA
                    anchors.fill: parent; anchors.margins: tile.cur ? 2 : 1
                    visible: tile.frontA && tile.shownPts >= 0
                    asynchronous: true
                    fillMode: Image.PreserveAspectFit
                    onStatusChanged: tile._swapIfReady(imgA, true)
                }
                Image {
                    id: imgB
                    anchors.fill: parent; anchors.margins: tile.cur ? 2 : 1
                    visible: !tile.frontA && tile.shownPts >= 0
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
                    visible: tile.shownPts >= 0
                    anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                    height: 13; color: tile.cur ? Theme.accent : Qt.rgba(13 / 255, 12 / 255, 11 / 255, 0.78)
                    Text {
                        anchors.centerIn: parent
                        text: tile.shownPts >= 0 && strip.clockOf ? strip.clockOf(tile.shownPts) : ""
                        color: tile.cur ? "#241a08" : "#ffffff"
                        font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 0.6
                        font.weight: tile.cur ? Font.Bold : Font.Normal
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    enabled: tile.pts >= 0 && !tile.cur
                    cursorShape: Qt.PointingHandCursor
                    onClicked: strip.jumpRequested(tile.pts)
                }
            }
        }
    }
}
