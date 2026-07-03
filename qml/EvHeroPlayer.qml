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

    property string _sid: ""
    property var _frags: []
    property real _compactDur: 0
    property bool _loading: false
    property string _error: ""
    property int _pendingSeekMs: -1
    property bool _armed: false
    property int _speed: 1
    property real _smoothMs: 0                          // interpolated playhead (smooth)
    // The EPISODE timeline the scrubber shows — [start, end] from EventsStore.episodeWindow, set on a fresh
    // open and KEPT across far-seek re-opens (so a far seek doesn't shrink/jump the scrubber to the loaded
    // sub-window). The player session (_frags) is a window inside it. Mirrors PlaybackScreen's tl*/win*.
    property double tlStartMs: 0
    property double tlEndMs: 0
    property double _seekingToWall: -1                  // target held on the scrubber while a far-seek re-opens
    property bool _continuous: false                    // continuous-timeline session ⇒ direct seeks land within a run
    property int _frameSeq: 0                            // ++ on every rendered frame — input to the freeze-watchdog
    property int _seekWatchSeq: -1                       // _frameSeq when a direct continuous seek was issued; -1 = idle
    property double _seekWatchWall: 0                    // that seek's target, for the watchdog's fallback re-open
    // wall-clock time of the frame currently on screen (compact playhead → wall, via the ready fragments)
    readonly property double _playheadWallMs: _seekingToWall >= 0 ? _seekingToWall
                                            : (_frags.length ? _posToWall(_smoothMs) : tlStartMs)

    // Advance the playhead continuously at 30fps; the raw MediaPlayer.position
    // updates coarsely/jitterily over HLS, so we interpolate and only snap on a
    // real seek (large divergence) — keeps the scrubber gliding, not twitching.
    Timer {
        interval: 33; repeat: true
        running: player.playbackState === MediaPlayer.PlayingState
        onTriggered: hp._smoothMs = Math.min(player.duration > 0 ? player.duration : hp._smoothMs,
                                             hp._smoothMs + 33 * player.playbackRate)
    }
    // ---- WT_HERO_TEST instrumentation (inert unless wtHeroTest set) ------------------------------------
    // Precise latency from the seek/open COMMAND to the first ACTUALLY-RENDERED frame, via the video sink's
    // frame signal (a paused seek renders nothing and player.position over HLS is coarse, so we detect the
    // first frame the backend flushes after the command). EvTriage drives the events + jumps; we log [HT].
    readonly property bool _htOn: (typeof wtHeroTest !== "undefined" && wtHeroTest === true)
    property int testFrames: 0
    property bool _htOpenPending: false
    property double _htOpenT0: 0
    property bool _htSeekPending: false
    property double _htSeekT0: 0
    property int _htSeekFramesAt: 0
    property int _htSeekReq: 0
    readonly property real testDurMs: player.duration
    function testSeek(deltaMs) {
        if (player.playbackState !== MediaPlayer.PlayingState) player.play();   // paused seeks render nothing
        _htSeekReq = deltaMs; _htSeekT0 = Date.now(); _htSeekFramesAt = testFrames; _htSeekPending = true;
        if (typeof wtSeekDirect !== "undefined" && wtSeekDirect)               // validation: direct demuxer seek, NO re-open
            _seekWall(Math.max(tlStartMs, Math.min(tlEndMs, _playheadWallMs + deltaMs)));   // lands iff the session is continuous
        else
            seekToWall(_playheadWallMs + deltaMs);                              // the REAL seek path (near direct / far re-open)
    }
    // Freeze-watchdog (LAST RESORT only): on a continuous session direct seeks land ~99% — the slow ones are
    // cold BASE renditions (S3 fetch, ~2-4s) that DO land, and re-opening hits the same cold base, so a tight
    // watchdog just churns. So it's deliberately long: it re-opens only a genuine >6s hang, never the cold tail.
    Timer {
        id: seekWatch; interval: 6000; repeat: false
        onTriggered: {
            if (hp._seekWatchSeq >= 0 && hp._frameSeq <= hp._seekWatchSeq) hp._seekFar(hp._seekWatchWall);
            hp._seekWatchSeq = -1;
        }
    }
    Connections {
        target: vout.videoSink
        function onVideoFrameChanged(frame) {
            hp._frameSeq++;
            hp.testFrames++;
            if (hp._htOpenPending) {
                hp._htOpenPending = false;
                console.log("[HT] OPEN lat=" + (Date.now() - hp._htOpenT0) + " dur=" + Math.round(player.duration / 1000)
                            + " ev=" + (hp.ev ? hp.ev.id : "?") + " t=" + Date.now());
            } else if (hp._htSeekPending && !hp._loading && hp.testFrames > hp._htSeekFramesAt) {
                hp._htSeekPending = false;   // !_loading excludes a far-seek re-open's stop-flush; the real
                console.log("[HT] SEEK req=" + hp._htSeekReq + " lat=" + (Date.now() - hp._htSeekT0) + " t=" + Date.now());
            }
        }
    }

    Connections {
        target: player
        function onPositionChanged() { if (Math.abs(player.position - hp._smoothMs) > 500) hp._smoothMs = player.position; }
        function onPlaybackStateChanged() { if (player.playbackState !== MediaPlayer.PlayingState) hp._smoothMs = player.position; }
    }

    // On-demand: a new event shows its snapshot poster; the recording loads only on a play-tap.
    // Auto-loading + the tab-switch teardown were the two events-browsing leaks (each ~+44 MB/min).
    property bool _started: false
    onEvChanged: { hp._reset(); if (typeof wtHeroAutoplay !== "undefined" && wtHeroAutoplay) hp._open(); }
    Component.onDestruction: { player.stop(); player.source = ""; }

    // Views are kept alive (StackLayout), so pause the recording when Triage isn't the shown tab.
    property bool surfaced: true
    onSurfacedChanged: if (!surfaced && player.playbackState === MediaPlayer.PlayingState) player.pause()

    function _reset() {
        _started = false; _loading = false; _error = ""; _sid = ""; _frags = []; _armed = false;
        _pendingSeekMs = -1; _smoothMs = 0; _seekingToWall = -1; _continuous = false;
        seekWatch.stop(); _seekWatchSeq = -1; player.stop(); player.source = "";
    }
    function _open() {
        if (!ev || !ev.id || !playbackClient) return;
        _started = true;
        if (_htOn) { _htOpenT0 = Date.now(); _htOpenPending = false; _htSeekPending = false; }   // armed in onSessionReady
        _loading = true; _error = ""; _sid = ""; _frags = []; _armed = false; _speed = 1; _smoothMs = 0; _seekingToWall = -1;
        player.stop(); player.source = ""; player.playbackRate = 1;
        // Open EXACTLY the episode [start, end] (+15s margins) so a clip never spills into a neighbouring
        // episode's footage. EventsStore joins the motion lifecycle and normalises ev.ts to the episode
        // START, so this is a forward window with the footage (recording is motion-triggered: the episode's
        // recording_id covers [start, end]). Verified live on .106: 188 / 28 ready fragments.
        var w = EventsStore.episodeWindow(ev);
        tlStartMs = w.startMs; tlEndMs = (w.endMs > w.startMs ? w.endMs : w.startMs + 1000);   // the episode timeline
        _pendingSeekMs = w.startMs - 15000;                              // seek to ~15s before the episode start
        playbackClient.ensureReady();
        playbackClient.openSession(ev.cam.id,
            new Date(w.startMs - 15000).toISOString(),
            new Date(tlEndMs + 15000).toISOString(), true);
    }
    // Seek to a WALL time on the episode timeline.
    //  • CONTINUOUS session (Cilex Vision route B): direct seeks land within a contiguous run, so we seek
    //    directly and only RE-OPEN proactively when the jump crosses a kept boundary (gap/codec/profile/
    //    pts_wrap — a discontinuity:true fragment). The freeze-watchdog re-opens the rare flaky tail.
    //  • LEGACY session: every fragment is a discontinuity the FFmpeg demuxer can't seek across (56% of
    //    jumps froze, 58-79% for ≥10s), so anything past a tiny in-buffer nudge re-opens a short window at
    //    the target — the A1 PlaybackScreen workaround. Either way the episode timeline (tl*) is kept.
    function seekToWall(wall) {
        if (!_started) return;
        wall = Math.max(tlStartMs, Math.min(tlEndMs, wall));
        if (_continuous) {
            if (_armed && _frags.length > 0 && _crossesBoundary(_playheadWallMs, wall)) { _seekFar(wall); return; }
            _seekWall(wall);
            _seekWatchSeq = _frameSeq; _seekWatchWall = wall; seekWatch.restart();   // arm the freeze-watchdog
            return;
        }
        if (_armed && _frags.length > 0 && Math.abs(wall - _playheadWallMs) <= 3000) { _seekWall(wall); return; }
        _seekFar(wall);
    }
    // Does the wall jump [from,to] step over a kept discontinuity:true fragment? (The leading "start" sits at
    // the run start ≤ from, so a normal mid-clip seek never crosses it — only real gaps/codec/profile/wrap.)
    function _crossesBoundary(fromWall, toWall) {
        var lo = Math.min(fromWall, toWall), hi = Math.max(fromWall, toWall);
        for (var i = 0; i < _frags.length; i++)
            if (_frags[i].disc && _frags[i].ws > lo && _frags[i].ws <= hi) return true;
        return false;
    }
    function _seekFar(wall) {
        if (!ev || !playbackClient) return;
        var ep = EventsStore.episodeWindow(ev);
        if (_htOn) console.log("[HT] REOPEN cont=" + _continuous + " t=" + Date.now());   // re-open count = the leak proxy
        seekWatch.stop(); _seekWatchSeq = -1;                            // a re-open supersedes any pending direct-seek watch
        _loading = true; _armed = false; _frags = []; _pendingSeekMs = wall - 15000; _seekingToWall = wall;
        player.stop(); player.source = "";
        playbackClient.ensureReady();
        playbackClient.openSession(ev.cam.id,
            new Date(wall - 15000).toISOString(),
            new Date(Math.max(ep.endMs, wall) + 15000).toISOString(), true);
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
    // compact player-position (ms) → wall ms — inverse of _wallToPos, for the on-screen timestamp
    function _posToWall(compactMs) {
        var sec = compactMs / 1000;
        for (var i = 0; i < _frags.length; i++) {
            var f = _frags[i];
            if (sec >= f.cs && sec <= f.ce)
                return f.ws + ((f.ce > f.cs) ? (sec - f.cs) / (f.ce - f.cs) : 0) * (f.we - f.ws);
        }
        return _frags.length ? _frags[0].ws : 0;
    }
    function _seekWall(ms) {
        var pos = _wallToPos(ms);
        if (_compactDur > 3) pos = Math.min(pos, _compactDur - 3);
        player.position = Math.round(Math.max(0, pos) * 1000);
    }
    function _fmt(ms) { var s = Math.max(0, Math.round(ms / 1000)); return EventsStore._p2(Math.floor(s / 60)) + ":" + EventsStore._p2(s % 60); }
    function toggle() {   // Space / play button: first press loads the recording on demand
        if (!hp._started) { hp._open(); return; }
        player.playbackState === MediaPlayer.PlayingState ? player.pause() : player.play();
    }

    Connections {
        target: hp.playbackClient
        enabled: hp.playbackClient !== null
        function onSessionReady(sid, dur, fragments, meta) {
            hp._sid = sid; hp._compactDur = dur;
            var out = [];
            for (var i = 0; i < fragments.length; i++) {
                // Positional primitive row (pre-filtered "ready" in PlaybackClient):
                // [cs, ce, wsMs, weMs, disc, boundary, …] — see PlaybackScreen.onSessionReady.
                var f = fragments[i];
                out.push({ cs: f[0], ce: f[1], ws: f[2], we: f[3],
                           disc: !!f[4], boundary: f[5] || "" });   // kept-discontinuity markers (§4-ii)
            }
            hp._frags = out;
            hp._continuous = !!(meta && meta.seek_mode === "continuous");   // ⇒ direct seeks, re-open only at boundaries
            hp._armed = true;
            if (typeof wtTrace !== "undefined" && wtTrace)
                console.log("[HERO] session ready: " + out.length + " ready fragments · ev=" + (ev ? ev.rawType : "?")
                            + " dur=" + (ev ? ev.durationSec : 0) + "s");
            if (out.length === 0) { hp._loading = false; hp._error = "No footage recorded around this moment."; return; }
            hp._loading = false; hp._error = "";
            if (typeof wtHeroNoplay === "undefined" || !wtHeroNoplay) {   // leak bisect: WT_HERO_NOPLAY skips the decode
                player.source = hp.playbackClient.playlistUrl(sid);
                if (typeof MemTel !== "undefined") MemTel.noteOpen();
                player.play();
            }
            if (hp._htOn) {                                   // arm the latency detector for the new session
                hp.testFrames = 0;
                if (hp._htSeekPending) hp._htSeekFramesAt = 0;   // far-seek re-open: next frame = the seek landing
                else hp._htOpenPending = true;                    // fresh event open
            }
        }
        function onSessionFailed(err) {
            hp._loading = false; hp._error = err;
            if (typeof wtTrace !== "undefined" && wtTrace) console.log("[HERO] session FAILED: " + err);
        }
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
                onPlaybackStateChanged: if (typeof MemTel !== "undefined") MemTel.setPlaying(1, playbackState === MediaPlayer.PlayingState)
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
                    hp._pendingSeekMs = -1; hp._seekingToWall = -1;   // landed → release the held scrubber playhead
                }
                onSeekableChanged: _applySeek()
                onDurationChanged: _applySeek()
            }

            // poster: the real event frame until the recording is rendering. The player
            // draws its OWN top-left identity (below), so suppress the poster's to avoid
            // the PLAYBACK chip overlapping it.
            EvSnapshot {
                anchors.fill: parent
                visible: hp._loading || hp._error !== "" || player.mediaStatus < MediaPlayer.BufferedMedia
                ev: hp.ev; showOsd: true; showIdent: false; showPlayhead: false
            }
            // on-demand affordance: tap the poster to load + play (recordings are NOT auto-loaded — see _reset)
            MouseArea {
                anchors.fill: parent
                visible: !hp._started && !hp._loading && hp._error === ""
                enabled: visible; cursorShape: Qt.PointingHandCursor
                onClicked: hp._open()
            }
            Rectangle {
                anchors.centerIn: parent
                visible: !hp._started && !hp._loading && hp._error === ""
                width: 56; height: 56; radius: 28
                color: Qt.rgba(0, 0, 0, 0.55); border.width: 1.5; border.color: "#ffffff"
                EvIcon { anchors.centerIn: parent; anchors.horizontalCenterOffset: 2; name: "play"; size: 22; color: "#ffffff" }
            }
            Text { visible: hp._loading; anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.margins: 8
                text: "Loading recording…"; color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 10 }
            Text { visible: hp._error !== ""; anchors.centerIn: parent; width: parent.width * 0.7
                text: hp._error; color: Theme.ink2; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                font.family: Theme.fontSans; font.pixelSize: 12 }

            // top-left header: playback-state chip + camera identity (name · IP), laid
            // out in one Row so the chip never overlaps the identity (the reported bug).
            Row {
                anchors.top: parent.top; anchors.left: parent.left; anchors.topMargin: 8; anchors.leftMargin: 10
                anchors.right: parent.right; anchors.rightMargin: 10
                visible: !hp._loading && hp._error === ""
                spacing: 8
                Rectangle {                                // playback state chip
                    anchors.verticalCenter: parent.verticalCenter
                    color: Qt.rgba(0, 0, 0, 0.55); height: 18; width: stC.implicitWidth + 14
                    Text { id: stC; anchors.centerIn: parent
                        text: (player.playbackState === MediaPlayer.PlayingState ? "▶ " : "❚❚ ") + "PLAYBACK"
                        color: Theme.accent; font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 0.9 }
                }
                Rectangle {                                // camera identity: name · IP (backend id dropped — useless)
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !!(hp.ev && hp.ev.cam)
                    color: Qt.rgba(0, 0, 0, 0.55); height: 18
                    width: Math.min(idT.implicitWidth + 14, hp.width - stC.implicitWidth - 150)
                    Text { id: idT; anchors.centerIn: parent; width: parent.width - 12; elide: Text.ElideRight
                        // name + IP; skip the IP if the name already carries it (avoid doubling)
                        text: {
                            if (!hp.ev || !hp.ev.cam) return "";
                            var nm = hp.ev.cam.name || "", ip = hp.ev.cam.ip || "";
                            return (ip && nm.indexOf(ip) < 0) ? (nm + "   ·   " + ip) : nm;
                        }
                        color: Qt.rgba(1, 1, 1, 0.92); font.family: Theme.fontMono; font.pixelSize: 11 }
                }
            }

            // wall-clock timestamp of the frame on screen (top-right OSD) — YYYY-MM-DD HH:MM:SS
            Rectangle {
                anchors.top: parent.top; anchors.right: parent.right; anchors.topMargin: 8; anchors.rightMargin: 10
                visible: hp._started && !hp._loading && hp._error === "" && hp._frags.length > 0
                         && player.mediaStatus >= MediaPlayer.BufferedMedia
                color: Qt.rgba(0, 0, 0, 0.6); height: 24; width: tsT.implicitWidth + 16
                Text { id: tsT; anchors.centerIn: parent
                    text: Qt.formatDateTime(new Date(hp._playheadWallMs), "yyyy-MM-dd HH:mm:ss")
                    color: "#ffffff"; font.family: Theme.fontMono; font.pixelSize: 14; font.weight: Font.Medium }
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
                        onClicked: hp.toggle() }
                }
                Rectangle { Layout.preferredWidth: 38; Layout.preferredHeight: 34; color: b1.containsMouse ? Theme.panel3 : Theme.panel2; border.width: 1; border.color: b1.containsMouse ? Theme.ink3 : Theme.line2
                    Text { anchors.centerIn: parent; text: "−10"; color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 10 }
                    MouseArea { id: b1; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: hp.seekToWall(hp._playheadWallMs - 10000) } }
                Rectangle { Layout.preferredWidth: 38; Layout.preferredHeight: 34; color: b2.containsMouse ? Theme.panel3 : Theme.panel2; border.width: 1; border.color: b2.containsMouse ? Theme.ink3 : Theme.line2
                    Text { anchors.centerIn: parent; text: "+10"; color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 10 }
                    MouseArea { id: b2; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: hp.seekToWall(hp._playheadWallMs + 10000) } }
                Text { textFormat: Text.StyledText
                    text: hp._fmt(hp._playheadWallMs - hp.tlStartMs) + " <font color='" + Theme.ink3 + "'>/</font> " + hp._fmt(hp.tlEndMs - hp.tlStartMs)
                    color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 11 }
                Item {                                      // scrubber — spans the whole EPISODE timeline (tl*), not the loaded window
                    Layout.fillWidth: true; Layout.preferredHeight: 30
                    readonly property real _span: hp.tlEndMs - hp.tlStartMs
                    readonly property real _f: _span > 0 ? Math.max(0, Math.min(1, (hp._playheadWallMs - hp.tlStartMs) / _span)) : 0
                    function _seekX(x) { if (_span > 0) hp.seekToWall(hp.tlStartMs + Math.max(0, Math.min(width, x)) / width * _span); }
                    Rectangle { anchors.verticalCenter: parent.verticalCenter; width: parent.width; height: 5; color: Theme.panel3 }
                    Rectangle { anchors.verticalCenter: parent.verticalCenter; height: 5; color: Theme.accent; width: parent.width * parent._f }
                    Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 3; height: 16; color: Theme.ink; x: parent.width * parent._f - 1.5 }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onPressed: (m) => parent._seekX(m.x)
                        onReleased: (m) => parent._seekX(m.x) }
                }
                Rectangle { Layout.preferredWidth: 38; Layout.preferredHeight: 34; color: sp.containsMouse ? Theme.panel3 : Theme.panel2; border.width: 1; border.color: sp.containsMouse ? Theme.ink3 : Theme.line2
                    Text { anchors.centerIn: parent; text: hp._speed + "×"; color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11 }
                    MouseArea { id: sp; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: hp._speed = (hp._speed === 1 ? 2 : hp._speed === 2 ? 4 : 1) } }
            }
        }
    }
}
