import QtQuick
import QtQuick.Layouts
import QtMultimedia
import Watchtower

// Imagery part 2 — REAL inline player for the Triage hero. Opens a cilex-vision
// review session around the event moment and plays the recorded HLS via
// QtMultimedia (the same stable path PlaybackScreen uses), seeked to the event.
// Uses its OWN PlaybackClient (passed in) so it never clobbers the main Playback
// screen's session. Mock mode uses EvPlayer (procedural) instead — EvTriage swaps
// between them. While the session loads, the real event frame (EvSnapshot) is the
// poster.
Item {
    id: hp
    property var ev: null
    property var playbackClient: null

    // 21:9 surface + 52px transport (drive our own implicit height for the layout)
    implicitHeight: width > 0 ? Math.round(width * 9 / 21) + 52 : 0

    readonly property real _clip: Math.max((ev && ev.durationSec) ? ev.durationSec : 20, 14)
    property string _sid: ""
    property var _frags: []
    property real _compactDur: 0
    property bool _loading: true
    property string _error: ""
    property int _pendingSeekMs: -1
    property bool _armed: false
    property int _speed: 1
    property real _smoothMs: 0                          // interpolated playhead (smooth)

    // Advance the playhead continuously at 30fps; the raw MediaPlayer.position
    // updates coarsely/jitterily over HLS, so we interpolate and only snap on a
    // real seek (large divergence) — keeps the scrubber gliding, not twitching.
    Timer {
        interval: 33; repeat: true
        running: player.playbackState === MediaPlayer.PlayingState
        onTriggered: hp._smoothMs = Math.min(player.duration > 0 ? player.duration : hp._smoothMs,
                                             hp._smoothMs + 33 * player.playbackRate)
    }
    Connections {
        target: player
        function onPositionChanged() { if (Math.abs(player.position - hp._smoothMs) > 500) hp._smoothMs = player.position; }
        function onPlaybackStateChanged() { if (player.playbackState !== MediaPlayer.PlayingState) hp._smoothMs = player.position; }
    }

    onEvChanged: hp._open()
    Component.onCompleted: hp._open()
    Component.onDestruction: { player.stop(); player.source = ""; }

    function _open() {
        if (!ev || !ev.id || !playbackClient) return;
        _loading = true; _error = ""; _sid = ""; _frags = []; _armed = false; _speed = 1; _smoothMs = 0;
        player.stop(); player.source = ""; player.playbackRate = 1;
        var ts = ev.ts.getTime();
        _pendingSeekMs = ts - 15000;                       // event − 15s lead-in
        playbackClient.ensureReady();
        playbackClient.openSession(ev.cam.id,
            new Date(ts - 15000).toISOString(),
            new Date(ts + (hp._clip + 15) * 1000).toISOString(), true);
    }

    // compact player-seconds ↔ wall ms (via the session's ready fragments)
    function _wallToPos(ms) {
        for (var i = 0; i < _frags.length; i++) {
            var f = _frags[i];
            if (ms >= f.ws && ms <= f.we)
                return f.cs + ((f.we > f.ws) ? (ms - f.ws) / (f.we - f.ws) : 0) * (f.ce - f.cs);
        }
        for (var j = 0; j < _frags.length; j++) if (_frags[j].ws >= ms) return _frags[j].cs;
        return _compactDur;
    }
    function _seekWall(ms) {
        var pos = _wallToPos(ms);
        if (_compactDur > 3) pos = Math.min(pos, _compactDur - 3);
        player.position = Math.round(Math.max(0, pos) * 1000);
    }
    function _fmt(ms) { var s = Math.max(0, Math.round(ms / 1000)); return EventsStore._p2(Math.floor(s / 60)) + ":" + EventsStore._p2(s % 60); }
    function toggle() { player.playbackState === MediaPlayer.PlayingState ? player.pause() : player.play() }  // keyboard Space

    Connections {
        target: hp.playbackClient
        enabled: hp.playbackClient !== null
        function onSessionReady(sid, dur, fragments, meta) {
            hp._sid = sid; hp._compactDur = dur;
            var out = [];
            for (var i = 0; i < fragments.length; i++) {
                var f = fragments[i];
                if (f.availability !== "ready") continue;
                out.push({ cs: f.compact_start, ce: f.compact_end, ws: Date.parse(f.wall_start), we: Date.parse(f.wall_end) });
            }
            hp._frags = out;
            hp._armed = true;
            if (out.length === 0) { hp._loading = false; hp._error = "No footage recorded around this moment."; return; }
            hp._loading = false; hp._error = "";
            player.source = hp.playbackClient.playlistUrl(sid);
            player.play();
        }
        function onSessionFailed(err) { hp._loading = false; hp._error = err; }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---- video surface ----
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Math.round(width * 9 / 21)
            color: "#000"; clip: true

            VideoOutput { id: vout; anchors.fill: parent; fillMode: VideoOutput.PreserveAspectFit }
            MediaPlayer {
                id: player
                videoOutput: vout
                audioOutput: null
                playbackRate: hp._speed
                // Seek to the event once the pipeline is seekable (a position set on
                // durationChanged before preroll is dropped). Land on the recorded
                // footage CLOSEST to the event — same logic as PlaybackScreen.
                function _applySeek() {
                    if (!hp._armed || hp._loading || !(seekable && duration > 0 && hp._pendingSeekMs >= 0)) return;
                    var evt = hp._pendingSeekMs + 15000;
                    var bestWall = -1, bestD = Infinity;
                    for (var i = 0; i < hp._frags.length; i++) {
                        var f = hp._frags[i], d, w;
                        if (evt >= f.ws && evt <= f.we) { d = 0; w = hp._pendingSeekMs; }
                        else if (evt > f.we) { d = evt - f.we; w = f.we - 3000; }
                        else { d = f.ws - evt; w = f.ws; }
                        if (d < bestD) { bestD = d; bestWall = w; }
                    }
                    hp._seekWall(bestWall >= 0 ? bestWall : evt);
                    hp._pendingSeekMs = -1;
                }
                onSeekableChanged: _applySeek()
                onDurationChanged: _applySeek()
            }

            // poster: the real event frame until the recording is rendering
            EvSnapshot {
                anchors.fill: parent
                visible: hp._loading || hp._error !== "" || player.mediaStatus < MediaPlayer.BufferedMedia
                ev: hp.ev; showOsd: true; showPlayhead: false
            }
            Text { visible: hp._loading; anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.margins: 8
                text: "Loading recording…"; color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 10 }
            Text { visible: hp._error !== ""; anchors.centerIn: parent; width: parent.width * 0.7
                text: hp._error; color: Theme.ink2; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                font.family: Theme.fontSans; font.pixelSize: 12 }

            Rectangle {                                    // playback state chip
                anchors.top: parent.top; anchors.right: parent.right; anchors.topMargin: 8; anchors.rightMargin: 10
                visible: !hp._loading && hp._error === ""
                color: Qt.rgba(0, 0, 0, 0.55); height: 18; width: stC.implicitWidth + 14
                Text { id: stC; anchors.centerIn: parent
                    text: (player.playbackState === MediaPlayer.PlayingState ? "▶ " : "❚❚ ") + "PLAYBACK"
                    color: Theme.accent; font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 0.9 }
            }
        }

        // ---- transport ----
        Rectangle {
            Layout.fillWidth: true; Layout.preferredHeight: 52; color: Theme.panel
            Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Theme.line }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 9

                Rectangle {                                // play / pause
                    Layout.preferredWidth: 34; Layout.preferredHeight: 34
                    color: pp.containsMouse ? Theme.panel3 : Theme.panel2; border.width: 1; border.color: pp.containsMouse ? Theme.ink3 : Theme.line2
                    Row { anchors.centerIn: parent; spacing: 4; visible: player.playbackState === MediaPlayer.PlayingState
                        Rectangle { width: 4; height: 14; color: Theme.ink } Rectangle { width: 4; height: 14; color: Theme.ink } }
                    EvIcon { anchors.centerIn: parent; visible: player.playbackState !== MediaPlayer.PlayingState; name: "play"; size: 15; color: Theme.ink }
                    MouseArea { id: pp; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: player.playbackState === MediaPlayer.PlayingState ? player.pause() : player.play() }
                }
                Rectangle { Layout.preferredWidth: 38; Layout.preferredHeight: 34; color: b1.containsMouse ? Theme.panel3 : Theme.panel2; border.width: 1; border.color: b1.containsMouse ? Theme.ink3 : Theme.line2
                    Text { anchors.centerIn: parent; text: "−10"; color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 10 }
                    MouseArea { id: b1; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: player.position = Math.max(0, player.position - 10000) } }
                Rectangle { Layout.preferredWidth: 38; Layout.preferredHeight: 34; color: b2.containsMouse ? Theme.panel3 : Theme.panel2; border.width: 1; border.color: b2.containsMouse ? Theme.ink3 : Theme.line2
                    Text { anchors.centerIn: parent; text: "+10"; color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 10 }
                    MouseArea { id: b2; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: player.position = Math.min(player.duration, player.position + 10000) } }
                Text { textFormat: Text.StyledText
                    text: hp._fmt(hp._smoothMs) + " <font color='" + Theme.ink3 + "'>/</font> " + hp._fmt(player.duration)
                    color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 11 }
                Item {                                      // scrubber
                    Layout.fillWidth: true; Layout.preferredHeight: 30
                    readonly property real _f: player.duration > 0 ? Math.max(0, Math.min(1, hp._smoothMs / player.duration)) : 0
                    Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 5; color: Theme.panel3 }
                    Rectangle { anchors.verticalCenter: parent.verticalCenter; height: 5; color: Theme.accent; width: parent.width * parent._f }
                    Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 3; height: 16; color: Theme.ink; x: parent.width * parent._f - 1.5 }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onPressed: (m) => { if (player.duration > 0) player.position = Math.round(Math.max(0, Math.min(width, m.x)) / width * player.duration) }
                        onPositionChanged: (m) => { if (pressed && player.duration > 0) player.position = Math.round(Math.max(0, Math.min(width, m.x)) / width * player.duration) } }
                }
                Rectangle { Layout.preferredWidth: 38; Layout.preferredHeight: 34; color: sp.containsMouse ? Theme.panel3 : Theme.panel2; border.width: 1; border.color: sp.containsMouse ? Theme.ink3 : Theme.line2
                    Text { anchors.centerIn: parent; text: hp._speed + "×"; color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11 }
                    MouseArea { id: sp; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: hp._speed = (hp._speed === 1 ? 2 : hp._speed === 2 ? 4 : 1) } }
            }
        }
    }
}
