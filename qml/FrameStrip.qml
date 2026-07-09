import QtQuick
import Watchtower

// Frame-by-frame FILMSTRIP (playback frameMode, toggled with F): big neighbor
// thumbnails around the current frame, current one centered and accented.
// Thumbs come straight from the decoded-frame cache (image://fcache/<pts>);
// slots the cache doesn't hold yet render as quiet placeholders and fill in as
// frames are visited (entry warmup + rolling prefetch keep the right side fed).
//
// Anti-flicker: the Repeater's model is a FIXED slot count — delegates persist
// and only their pts (→ Image.source) rebinds. A cached JPEG for a given PTS is
// immutable, so URLs carry NO revision cache-buster: a thumb whose pts didn't
// change never reloads (the first cut rebuilt every delegate and re-fetched
// every image on each capture — the whole strip flickered while filling).
Item {
    id: strip

    property double currentPts: -1
    property int sideSlots: 3                   // neighbors shown each side
    property var clockOf: null                  // function(ptsMs) → "HH:mm:ss.mmm"
    signal jumpRequested(double pts)

    // pts for slot `i` (0..2*sideSlots; center = sideSlots). Depends on the cache
    // revision + current frame: re-evaluated on either, but the VALUE only changes
    // when the mapping really moved — persistent delegates then keep their image.
    //
    // EVERY returned pts — the center included — is a key that EXISTS in the cache:
    // a URL for an uncached frame would miss in the provider and Qt's pixmap cache
    // would pin the miss to that URL forever (the black-thumbnails bug). The center
    // shows its placeholder for the ~1s until the entry warmup caches the origin.
    function ptsForIndex(i) {
        var rev = FrameCache.rev;               // dependency for re-evaluation
        if (currentPts <= 0) return -1;
        var off = i - sideSlots;
        if (off === 0) {
            var c = FrameCache.cachedAround(currentPts + 2, 1, 0);   // nearest key ≤ current
            return (c.length > 0 && Math.abs(c[c.length - 1] - currentPts) <= 2) ? c[c.length - 1] : -1;
        }
        if (off < 0) {
            var below = FrameCache.cachedAround(currentPts, sideSlots + 1, 0);
            var left = [];
            for (var b = 0; b < below.length; b++)
                if (currentPts - below[b] > 2) left.push(below[b]);
            var idx = left.length + off;        // off is negative: -1 → last of left
            return idx >= 0 ? left[idx] : -1;
        }
        var above = FrameCache.cachedAround(currentPts, 0, sideSlots);
        return (off - 1) < above.length ? above[off - 1] : -1;
    }

    Row {
        anchors.centerIn: parent
        spacing: 8
        Repeater {
            model: 2 * strip.sideSlots + 1      // FIXED count — delegates persist
            delegate: Rectangle {
                required property int index
                readonly property bool cur: index === strip.sideSlots
                readonly property double pts: strip.ptsForIndex(index)
                readonly property bool has: pts > 0
                width: cur ? Math.round(strip.height * 16 / 9) : Math.round(strip.height * 0.78 * 16 / 9)
                height: cur ? strip.height : Math.round(strip.height * 0.78)
                anchors.verticalCenter: parent.verticalCenter
                color: "#101010"
                border.width: cur ? 2 : 1
                border.color: cur ? Theme.accent : Theme.line2
                opacity: cur ? 1.0 : (has ? 0.85 : 0.45)

                Image {
                    anchors.fill: parent
                    anchors.margins: parent.cur ? 2 : 1
                    visible: parent.has
                    asynchronous: true
                    fillMode: Image.PreserveAspectFit
                    // no ?rev= — a cached frame's JPEG never changes; stable URL = no reload
                    source: parent.has ? "image://fcache/" + Math.round(parent.pts) : ""
                }
                Text {                            // placeholder slot — frame not cached yet
                    anchors.centerIn: parent
                    visible: !parent.has
                    text: "·"
                    color: Theme.ink3; font.pixelSize: 18
                }
                Rectangle {                       // per-thumb timestamp footer
                    visible: parent.has
                    anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                    height: 14; color: Qt.rgba(0, 0, 0, 0.62)
                    Text {
                        anchors.centerIn: parent
                        text: parent.parent.has && strip.clockOf ? strip.clockOf(parent.parent.pts) : ""
                        color: parent.parent.cur ? Theme.accent : Theme.ink2
                        font.family: Theme.fontMono; font.pixelSize: 9
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    enabled: parent.has && !parent.cur
                    cursorShape: Qt.PointingHandCursor
                    onClicked: strip.jumpRequested(parent.pts)
                }
            }
        }
    }
}
