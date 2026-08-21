import QtQuick
import Watchtower

// Playback navigator, TIER 2 — the ruler and the FOOTAGE / MOTION lanes
// (spec §2.6). Same 120px label block as tier 1, so both tracks align on one
// horizontal time axis.
//
// Scrubbing PREVIEWS ONLY. §3.6 measures a seek at p90 986 ms per session
// re-open; a drag that seeks per pointer-move issues ~60 a second. The line
// follows the pointer, a chip says why the picture has not moved, and exactly
// ONE seek is issued — on release.
Item {
    id: lanes

    property double winS: 0
    property double winE: 0
    property var segs: []            // [{ws, we}] recorded footage, wall ms
    property var items: []           // [{id, ms, len, color}] one model, shared with the list
    property double ph: 0            // playhead, wall ms
    property double markS: -1
    property double markE: -1
    property string hoverId: ""
    property string selId: ""
    property bool showMotion: true
    property int footageH: 14
    property int motionH: 18
    readonly property int rulerH: 15
    readonly property int labelW: 120

    signal seekRequested(double ms)
    signal hovered(string id)
    signal picked(string id, double ms)
    signal zoomRequested(real factor, double atMs)
    signal panRequested(double deltaMs)
    // Plain left-drag marks an export range — the gesture this scrubber had
    // before the "One Axis" rebuild (removed by a36a062 along with wheel zoom).
    // The host owns selStart/selEnd; this only reports.
    signal markRequested(double s, double e)
    signal markCleared()

    readonly property double span: Math.max(1, winE - winS)
    readonly property real trackW: Math.max(1, width - labelW)
    function xOf(ms) { return (ms - winS) / span * trackW }
    function msOf(x) { return winS + Math.max(0, Math.min(1, x / trackW)) * span }

    // Ruler intervals are chosen from the SPAN, not from the pixel width, so the
    // ticks are the ones the span buttons promise (spec §2.6).
    readonly property var _steps: {
        var s = span;
        if (s <= 15 * 60000 + 1000) return [60000, 300000];
        if (s <= 3600000 + 1000)    return [300000, 300000];
        if (s <= 6 * 3600000 + 1000) return [1800000, 3600000];
        if (s <= 12 * 3600000 + 1000) return [3600000, 7200000];
        return [3600000, 10800000];
    }
    readonly property var _ticks: {
        var st = _steps[0], out = [];
        if (st <= 0 || span <= 0) return out;
        for (var t = Math.ceil(winS / st) * st; t < winE && out.length < 400; t += st) out.push(t);
        return out;
    }

    // drag state — a preview, never a seek
    property double _dragMs: -1
    property double _pressMs: -1
    property real _pressX: -1
    property bool _marking: false          // the drag has passed the 4px threshold
    // While MARKING, this is not a seek gesture: the playhead must not preview and
    // the "release to seek" chip must not promise a seek that will not happen.
    readonly property bool dragging: _dragMs >= 0 && !_marking
    readonly property double atMs: dragging ? _dragMs : ph

    // Hover preview (operator ask 2026-08-21) — the standard player affordance:
    // a hairline under the pointer and the exact time a click would seek to.
    // hoverMs uses msOf(x), the SAME formula onReleased seeks with, so the
    // promise and the click share one mapping. Hidden while a press is in
    // flight (the release-to-seek chip owns that state) and while a MOTION bar
    // is hovered — there a click picks the episode, not a time, and a time
    // chip would promise a seek that will not happen.
    property real _hoverX: -1
    readonly property double hoverMs: _hoverX >= 0 ? msOf(_hoverX) : -1
    readonly property bool _hoverLive: _hoverX >= 0 && _dragMs < 0 && hoverId === ""
    // Dev/verification hook: --pb-hover-test=<trackX> forces the preview on at
    // that x (a WT_SCREENSHOT run cannot move the real pointer without an
    // Accessibility grant). Inert without the argument.
    Component.onCompleted: {
        var args = Qt.application.arguments;
        for (var i = 0; i < args.length; i++)
            if (args[i].indexOf("--pb-hover-test=") === 0)
                _hoverX = parseInt(args[i].substring(16), 10);
    }

    // ---- label block ------------------------------------------------------
    Item {
        id: lbl
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: lanes.labelW
        Rectangle { anchors { right: parent.right; top: parent.top; bottom: parent.bottom } width: 1; color: Theme.line }
        Column {
            anchors { left: parent.left; leftMargin: 10; top: parent.top; topMargin: lanes.rulerH + 2 }
            spacing: 4
            Text { text: qsTr("FOOTAGE", "playback lane label"); color: Theme.good
                font.family: Theme.fontMono; font.pixelSize: 8; font.letterSpacing: 1.3; font.weight: Font.DemiBold }
            Text { visible: lanes.showMotion; text: qsTr("MOTION", "playback lane label"); color: Theme.accent
                font.family: Theme.fontMono; font.pixelSize: 8; font.letterSpacing: 1.3; font.weight: Font.DemiBold }
        }
    }

    // ---- track ------------------------------------------------------------
    Item {
        id: track
        anchors { left: lbl.right; right: parent.right; top: parent.top; bottom: parent.bottom }
        clip: true

        // ruler
        Item {
            id: ruler
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: lanes.rulerH
            Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: 1; color: Theme.line }
            Repeater {
                model: lanes._ticks
                delegate: Item {
                    required property var modelData
                    readonly property bool major: (modelData % lanes._steps[1]) === 0
                    readonly property real tx: lanes.xOf(modelData)
                    visible: tx >= -1 && tx <= track.width + 1
                    Rectangle { x: parent.tx; y: 0; width: 1
                        height: parent.major ? ruler.height : 5; color: Theme.line2 }
                    Text {
                        visible: parent.major
                        x: Math.round(parent.tx) + 3; y: 3
                        text: PbFmt.hm(parent.modelData)
                        color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9
                    }
                }
            }
        }

        // FOOTAGE lane — gaps are LITERAL. A motion-recorded camera is 80–120
        // segments a day totalling under an hour; smoothing that into bars would
        // imply a continuity the archive does not have.
        Rectangle {
            id: fLane
            anchors { left: parent.left; right: parent.right; top: ruler.bottom }
            height: lanes.footageH
            color: "#151412"
            Repeater {
                model: lanes.segs
                delegate: Rectangle {
                    required property var modelData
                    readonly property real x0: lanes.xOf(modelData.ws)
                    readonly property real x1: lanes.xOf(modelData.we)
                    visible: x1 >= 0 && x0 <= track.width
                    x: x0; y: 2; height: parent.height - 4
                    width: Math.max(1, x1 - x0)          // a 3-second clip in 24H stays visible
                    color: Theme.good
                }
            }
            Text {
                anchors.centerIn: parent
                visible: lanes.segs.length === 0
                text: qsTr("NO FOOTAGE IN THIS WINDOW")
                color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 1.2
            }
        }

        // MOTION lane — one bar per episode, min-width 2px. At 24H with 200 events
        // the bars merge into dense blocks, and that IS the shape of the day: no
        // decimation, no "+N more" (spec §5).
        Rectangle {
            id: mLane
            anchors { left: parent.left; right: parent.right; top: fLane.bottom }
            height: lanes.showMotion ? lanes.motionH : 0
            visible: lanes.showMotion
            color: "#151412"
            Rectangle { anchors { left: parent.left; right: parent.right; top: parent.top }
                height: 1; color: Qt.rgba(52 / 255, 48 / 255, 42 / 255, 0.7) }
            Repeater {
                model: lanes.showMotion ? lanes.items : []
                delegate: Rectangle {
                    id: bar
                    required property var modelData
                    readonly property real x0: lanes.xOf(modelData.ms)
                    readonly property real x1: lanes.xOf(modelData.ms + modelData.len)
                    readonly property bool isHov: lanes.hoverId === modelData.id
                    readonly property bool isSel: lanes.selId === modelData.id
                    visible: x1 >= -2 && x0 <= track.width + 2
                    x: x0; y: 3; height: Math.max(2, parent.height - 6)
                    width: Math.max(2, x1 - x0)
                    color: isSel ? "#ffffff" : isHov ? Theme.ink : modelData.color
                    z: isSel ? 4 : isHov ? 3 : 1
                    border.width: isSel ? 1 : 0
                    border.color: Theme.accent
                    MouseArea {
                        anchors.fill: parent; anchors.margins: -1
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: lanes.hovered(bar.modelData.id)
                        onExited: if (lanes.hoverId === bar.modelData.id) lanes.hovered("")
                        onPressed: (m) => { m.accepted = true; lanes.picked(bar.modelData.id, bar.modelData.ms) }
                    }
                }
            }
        }

        // marked export range — a visible object across BOTH lanes (spec §2.7)
        Item {
            visible: lanes.markS >= 0 && lanes.markE > lanes.markS
            anchors { top: ruler.bottom; bottom: parent.bottom }
            x: lanes.xOf(Math.max(lanes.markS, lanes.winS))
            width: Math.max(2, lanes.xOf(Math.min(lanes.markE, lanes.winE))
                               - lanes.xOf(Math.max(lanes.markS, lanes.winS)))
            z: 5
            Rectangle {
                anchors.fill: parent
                color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.13)
            }
            Rectangle { anchors { left: parent.left; top: parent.top; bottom: parent.bottom } width: 1; color: Theme.accent }
            Rectangle { anchors { right: parent.right; top: parent.top; bottom: parent.bottom } width: 1; color: Theme.accent }
            // End caps only when the band is wide enough to hold both: at 24H a
            // four-minute range is ~4px, and two 11px caps anchored to opposite
            // edges then cross over and read as "] [". The band's own accent
            // edges carry it below that, and the header states the duration.
            Rectangle {
                anchors { left: parent.left; top: parent.top }
                visible: parent.width >= 26
                width: capA.implicitWidth + 6; height: 11; color: Theme.accent
                Text { id: capA; anchors.centerIn: parent; text: "["; color: "#241a08"
                    font.family: Theme.fontMono; font.pixelSize: 8; font.letterSpacing: 1.2; font.weight: Font.Bold }
            }
            Rectangle {
                anchors { right: parent.right; top: parent.top }
                visible: parent.width >= 26
                width: capB.implicitWidth + 6; height: 11; color: Theme.accent
                Text { id: capB; anchors.centerIn: parent; text: "]"; color: "#241a08"
                    font.family: Theme.fontMono; font.pixelSize: 8; font.letterSpacing: 1.2; font.weight: Font.Bold }
            }
        }

        // playhead — 1px line over both lanes with a 9×7 triangular handle
        Item {
            visible: lanes.atMs >= lanes.winS && lanes.atMs <= lanes.winE
            x: lanes.xOf(lanes.atMs)
            anchors { top: ruler.bottom; bottom: parent.bottom }
            z: 6
            Rectangle { width: 1; anchors { top: parent.top; bottom: parent.bottom } color: Theme.ink }
            Canvas {
                x: -4; y: -1; width: 9; height: 7
                onPaint: {
                    var c = getContext("2d");
                    c.reset();
                    c.fillStyle = Theme.ink;
                    c.beginPath(); c.moveTo(0, 0); c.lineTo(9, 0); c.lineTo(4.5, 7); c.closePath(); c.fill();
                }
            }
        }
        // Hover preview line + time chip. A HoverHandler (not hoverEnabled on the
        // seek MouseArea) so the MOTION bars' own hover highlight keeps receiving
        // events — handlers observe hover without consuming it.
        HoverHandler {
            onHoveredChanged: if (!hovered) lanes._hoverX = -1
            onPointChanged: lanes._hoverX = hovered ? point.position.x : -1
        }
        Item {
            visible: lanes._hoverLive
            x: lanes._hoverX
            anchors { top: ruler.bottom; bottom: parent.bottom }
            z: 7
            Rectangle { width: 1; anchors { top: parent.top; bottom: parent.bottom } color: Theme.ink2 }
        }
        Rectangle {
            visible: lanes._hoverLive
            z: 8
            x: Math.max(0, Math.min(track.width - width, lanes._hoverX - width / 2))
            y: ruler.height - height - 1
            width: hovT.implicitWidth + 12; height: 16
            color: Theme.ink
            Text {
                id: hovT; anchors.centerIn: parent
                text: PbFmt.hms(lanes.hoverMs)
                color: Theme.bg; font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.DemiBold
            }
        }
        // "release to seek" — the second half is not decoration: it tells the
        // operator why the picture has not moved yet.
        Rectangle {
            visible: lanes.dragging
            z: 9
            readonly property real cx: lanes.xOf(lanes.atMs)
            x: Math.max(0, Math.min(track.width - width, cx - width / 2))
            y: ruler.height - height - 1
            width: chipT.implicitWidth + 12; height: 16
            color: Theme.ink
            Text {
                id: chipT; anchors.centerIn: parent
                text: PbFmt.hms(lanes.atMs) + " · " + qsTr("release to seek")
                color: Theme.bg; font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.DemiBold
            }
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton
            preventStealing: true
            onPressed: (m) => {
                lanes._pressX = m.x;
                lanes._pressMs = lanes.msOf(m.x);
                lanes._dragMs = lanes._pressMs;
                lanes._marking = false;
                lanes.markCleared();                // a fresh press drops the old range
            }
            onPositionChanged: (m) => {
                if (lanes._dragMs < 0) return;
                // 4px is the same threshold the pre-rebuild scrubber used, and the
                // same one the 16-camera wall still uses: below it the gesture is a
                // click that seeks, above it a range drag that does NOT seek.
                if (!lanes._marking && Math.abs(m.x - lanes._pressX) >= 4)
                    lanes._marking = true;
                if (lanes._marking) {
                    var cur = lanes.msOf(m.x);
                    lanes.markRequested(Math.min(lanes._pressMs, cur), Math.max(lanes._pressMs, cur));
                } else {
                    lanes._dragMs = lanes.msOf(m.x);     // still a seek preview
                }
            }
            onCanceled: { lanes._dragMs = -1; lanes._marking = false; lanes._pressX = -1; }
            onReleased: (m) => {
                var wasMarking = lanes._marking;
                var target = lanes.msOf(m.x);
                lanes._dragMs = -1; lanes._marking = false; lanes._pressX = -1;
                if (wasMarking) {
                    // Commit the range. Deliberately NO seek: a drag that both marked
                    // and jumped would spend a session re-open (p90 986ms) the
                    // operator did not ask for.
                    lanes.markRequested(Math.min(lanes._pressMs, target), Math.max(lanes._pressMs, target));
                    return;
                }
                lanes.seekRequested(target);        // EXACTLY ONE seek, on release
            }
            // Wheel = zoom AT THE CURSOR, Shift+wheel = pan — the Premiere / Final
            // Cut idiom, and what this scrubber did before the "One Axis" rebuild
            // (added 0746a71, dropped by a36a062 because the gesture belonged to
            // the old zoomable band and was not in the spec's preserved list).
            // The host still owns the window maths; this only reports the gesture,
            // so the ribbon and the span chips stay the single source of the view.
            onWheel: (w) => {
                var atMs = lanes.msOf(w.x - lanes.labelW);
                if (w.modifiers & Qt.ShiftModifier)
                    lanes.panRequested(w.angleDelta.y > 0 ? -lanes.span * 0.15 : lanes.span * 0.15);
                else
                    lanes.zoomRequested(w.angleDelta.y > 0 ? 0.8 : 1.25, atMs);   // up = in
            }
        }
    }
}
