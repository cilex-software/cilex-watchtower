import QtQuick
import Watchtower

// Frame-by-frame filmstrip (playback frameMode, toggled with F): big neighbor
// thumbnails around the current frame, current one centered and accented.
// Thumbs come straight from the decoded-frame cache (image://fcache/<pts>);
// slots the cache doesn't hold yet render as quiet placeholders and fill in as
// frames are visited (the mode's warmup pre-fills the first neighbors).
Item {
    id: strip

    property double currentPts: -1
    property int sideSlots: 3                   // neighbors shown each side
    property var clockOf: null                  // function(ptsMs) → "HH:mm:ss.mmm" (host supplies wall mapping)
    signal jumpRequested(double pts)

    // Slot model: [−side..0..+side]; each = { pts: cachedPtsOr-1, cur: bool }.
    // Cached keys anchor real thumbs; gaps show placeholders. Rebuilds on cache
    // revision and on the current frame changing.
    readonly property var slotModel: {
        var rev = FrameCache.rev;               // dependency: rebuild on cache changes
        var out = [];
        if (currentPts <= 0) return out;
        var below = FrameCache.cachedAround(currentPts, sideSlots + 1, 0);   // ascending, incl current key
        var above = FrameCache.cachedAround(currentPts, 0, sideSlots);
        // left side: entries below current (excluding the current key itself)
        var left = [];
        for (var i = 0; i < below.length; i++)
            if (Math.abs(below[i] - currentPts) > 2) left.push(below[i]);
        while (left.length > sideSlots) left.shift();
        while (left.length < sideSlots) left.unshift(-1);
        for (i = 0; i < left.length; i++) out.push({ pts: left[i], cur: false });
        out.push({ pts: currentPts, cur: true });
        for (i = 0; i < sideSlots; i++)
            out.push({ pts: i < above.length ? above[i] : -1, cur: false });
        return out;
    }

    Row {
        anchors.centerIn: parent
        spacing: 8
        Repeater {
            model: strip.slotModel
            delegate: Rectangle {
                required property var modelData
                readonly property bool cur: modelData.cur
                readonly property bool has: modelData.pts > 0
                width: cur ? Math.round(strip.height * 16 / 9) : Math.round(strip.height * 0.78 * 16 / 9)
                height: cur ? strip.height : Math.round(strip.height * 0.78)
                anchors.verticalCenter: parent.verticalCenter
                color: "#101010"
                border.width: cur ? 2 : 1
                border.color: cur ? Theme.accent : Theme.line2
                opacity: cur ? 1.0 : (has ? 0.85 : 0.45)

                Image {
                    anchors.fill: parent
                    anchors.margins: cur ? 2 : 1
                    visible: parent.has
                    asynchronous: true
                    fillMode: Image.PreserveAspectFit
                    source: parent.has ? "image://fcache/" + Math.round(modelData.pts) + "?r=" + FrameCache.rev : ""
                }
                Text {                            // placeholder slot — frame not visited yet
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
                        text: parent.parent.has && strip.clockOf ? strip.clockOf(modelData.pts) : ""
                        color: cur ? Theme.accent : Theme.ink2
                        font.family: Theme.fontMono; font.pixelSize: 9
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    enabled: parent.has && !cur
                    cursorShape: Qt.PointingHandCursor
                    onClicked: strip.jumpRequested(modelData.pts)
                }
            }
        }
    }
}
