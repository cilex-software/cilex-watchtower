import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C
import QtMultimedia
import Watchtower

// Playback (S06): recorded playback of one camera from cilex-vision. Main player
// + 340px info aside + full-width bottom timeline. The HLS stream is served
// through the app's local auth proxy (PlaybackClient/HlsProxy). The timeline,
// footage/gap shading, and playhead↔wall-clock mapping all come from the real
// session manifest fragments — no fabricated coverage.
Item {
    id: root

    property var camera: null          // camera map (name, ip, mac, groupName, …)
    property var client: null          // PlaybackClient
    property var cameraModel: null

    signal closed()                    // back — returns to the previous (detail) view
    signal returnToLive()              // red control — back to Live Monitor

    // session state
    property string sessionId: ""
    property var frags: []             // ready fragments (compact_start/end + wall_start/end ms)
    property double compactDuration: 0
    property double winStartMs: 0      // loaded wall-clock window (the whole session)
    property double winEndMs: 0
    // Zoomable scrubber view — a subset of [winStartMs, winEndMs] so you can zoom
    // in on a long (12h/24h) timeline to place an export In/Out precisely
    // (Premiere-style: +/− keys around the playhead, scroll to zoom on the cursor,
    // Shift+scroll to pan, 0/Fit to reset).
    property double viewStartMs: 0
    property double viewEndMs: 0
    readonly property bool tlZoomed: (winEndMs - winStartMs) > 0 && (viewEndMs - viewStartMs) < (winEndMs - winStartMs) - 1
    property int zoomMin: 60           // 15 / 60 / 1440
    property bool loading: false
    property string errorText: ""

    // clip selection (wall ms), -1 = none
    property double selStartMs: -1
    property double selEndMs: -1
    readonly property bool hasSelection: selStartMs >= 0 && selEndMs > selStartMs

    readonly property string camId: (client && camera)
        ? (client.cameraIdForIp(camera.ip) || client.cameraIdForMac(camera.mac || "")) : ""

    // ---- events on the scrubber: motion episodes + point events ----------
    // Motion = amber spans; other event types = point ticks. Sources below:
    // motionEpisodes/Buckets come from /events/timeline (see loadTimeline); the
    // dedicated EventModel supplies non-motion point events + the recent list.
    property var motionEpisodes: []      // motion spans from /events/timeline (episodes mode)
    property var motionBuckets: []       // density bins from /events/timeline (buckets mode)
    property bool bucketMode: false      // true when a very busy window switched to bucket rendering
    readonly property int bucketThreshold: 2000   // episode count above which we switch to density buckets
    property var pointEvents: []
    property var eventList: []           // [{type, ts}] for the aside list, newest-first (excl. motion_ended)
    // Motion episodes come PRE-JOINED from the backend /events/timeline endpoint
    // (server pairs motion_started↔motion_ended by recording_id) — no client paging
    // or pairing. The EventModel below still supplies non-motion point events + the
    // recent list (its first page is enough; those are rare/recent).
    function loadTimeline() {
        motionEpisodes = []; motionBuckets = []; bucketMode = false;
        if (!client || camId === "" || winEndMs <= winStartMs) return;
        client.fetchTimeline(camId, new Date(winStartMs).toISOString(), new Date(winEndMs).toISOString(), 0);
    }
    function loadMotionEvents() {
        pointEvents = []; eventList = [];
        if (camId === "" || winEndMs <= winStartMs) return;
        motionEvents.search(camId, new Date(winStartMs).toISOString(), new Date(winEndMs).toISOString());
    }
    function rebuildEvents() {
        var all = motionEvents.all(), pts = [], evl = [];
        for (var i = 0; i < all.length; i++) {
            var ev = all[i];
            if (ev.camId !== camId) continue;                       // ignore the instance's initial global fetch
            if (ev.type !== "motion_ended") evl.push({ type: ev.type, ts: ev.ts });
            if (!EventStyle.isMotionSpan(ev.type)) pts.push({ ms: ev.ts, type: ev.type });   // non-motion → tick
        }
        pts.sort(function (a, b) { return a.ms - b.ms; });
        pointEvents = pts;
        eventList = evl;
    }
    // per-type show/hide (legend keys: "motion" for the span lane, raw event_type
    // for point ticks). Persisted in Settings.hiddenScrubberEventTypes.
    function typeHidden(key) { return Settings.hiddenScrubberEventTypes.indexOf(key) >= 0; }
    function typeVisible(key) { return Settings.eventsOnScrubber && !typeHidden(key); }
    function toggleType(key) {
        var h = Settings.hiddenScrubberEventTypes.slice(), i = h.indexOf(key);
        if (i >= 0) h.splice(i, 1); else h.push(key);
        Settings.hiddenScrubberEventTypes = h;
    }
    // legend keys present in the window: "motion" (if any episodes) + each distinct point type
    readonly property var eventTypesPresent: {
        var seen = ({}), out = [];
        if (motionEpisodes.length > 0 || motionBuckets.length > 0) out.push("motion");
        for (var i = 0; i < pointEvents.length; i++) {
            var t = pointEvents[i].type;
            if (!seen[t]) { seen[t] = true; out.push(t); }
        }
        return out;
    }
    // most-recent events (visible types) for the aside list; motion_ended omitted
    // (the start is the meaningful row).
    readonly property var recentList: {
        var src = eventList, out = [];
        for (var i = 0; i < src.length && out.length < 12; i++) {
            var key = EventStyle.isMotionSpan(src[i].type) ? "motion" : src[i].type;
            if (!typeVisible(key)) continue;
            out.push(src[i]);
        }
        return out;
    }

    // ---- helpers ---------------------------------------------------------
    function pad(n) { return (n < 10 ? "0" : "") + n }
    function fmtClock(ms) {
        if (!ms || isNaN(ms)) return "—";
        return Settings.clock(ms, true);   // honors the Time-format preference
    }
    function fmtDur(sec) {
        sec = Math.max(0, Math.round(sec));
        var m = Math.floor(sec / 60), s = sec % 60;
        return m + ":" + pad(s);
    }
    // compact player-seconds -> wall ms (via ready fragments)
    function posToWall(sec) {
        for (var i = 0; i < frags.length; i++) {
            var f = frags[i];
            if (sec >= f.cs && sec <= f.ce) {
                var frac = (f.ce > f.cs) ? (sec - f.cs) / (f.ce - f.cs) : 0;
                return f.ws + frac * (f.we - f.ws);
            }
        }
        return frags.length ? frags[0].ws : winStartMs;
    }
    // wall ms -> compact player-seconds (nearest covered fragment)
    function wallToPos(ms) {
        for (var i = 0; i < frags.length; i++) {
            var f = frags[i];
            if (ms >= f.ws && ms <= f.we) {
                var frac = (f.we > f.ws) ? (ms - f.ws) / (f.we - f.ws) : 0;
                return f.cs + frac * (f.ce - f.cs);
            }
        }
        // not inside footage — snap to the next fragment that starts after ms
        for (var j = 0; j < frags.length; j++)
            if (frags[j].ws >= ms) return frags[j].cs;
        return compactDuration;
    }
    function seekToWall(ms) {
        if (!player.seekable && player.duration <= 0) return;
        var pos = wallToPos(ms);
        // Keep a little headroom before end-of-footage: seeking to the exact last
        // instant strands the pipeline at EOS (frozen frame, endless re-fetch of
        // the final segment). Found 2026-06-14 jumping to motion events whose time
        // is past the camera's last recorded frame.
        if (compactDuration > 3) pos = Math.min(pos, compactDuration - 3);
        var p = Math.round(Math.max(0, pos) * 1000);
        player.position = p;
        root._scanPos = p;        // keep the scan accumulator in step with manual seeks
    }

    // current playhead wall ms
    readonly property double playheadMs: posToWall(player.position / 1000)

    // ---- playback speed / fast-forward ----------------------------------
    // playbackRate carries low speeds, but the HEVC-1440p decoder caps near ~14×
    // realtime on this hardware, so x20…x200 can't decode every frame. Above
    // maxDecodeRate we "scan": the player keeps playing (so frames render) while
    // a timer jumps the playhead forward by rate×interval — a true high-speed
    // fast-forward (how VMS clients race through hours of footage).
    readonly property var speeds: [1, 2, 4, 10, 20, 50, 100, 200]
    readonly property real maxDecodeRate: 10
    property real playSpeed: 1
    property bool paused: false
    property double _scanPos: -1          // scan accumulator (compact ms)
    readonly property bool advancing: !paused && frags.length > 0
    function applyTransport() {
        if (paused || frags.length === 0) { scanTimer.stop(); player.pause(); return; }
        if (playSpeed <= maxDecodeRate) {
            scanTimer.stop();
            player.playbackRate = playSpeed;
            player.play();
        } else {
            scanTimer.stop();
            player.playbackRate = 1;
            _scanPos = player.position;
            player.play();                // keep rendering frames between jumps
            scanTimer.start();
        }
    }
    function setSpeed(s) { playSpeed = s; paused = false; applyTransport(); }
    function togglePlay() { paused = !paused; applyTransport(); }

    // ---- timeline zoom (precise export selection on long windows) -----------
    function resetView() { viewStartMs = winStartMs; viewEndMs = winEndMs; }
    // Zoom the view by `factor` (<1 = in, >1 = out) keeping centerMs under the
    // same x; clamp to the loaded window, 2s minimum span.
    function zoomView(factor, centerMs) {
        var full = winEndMs - winStartMs;
        if (full <= 0) return;
        var cur = viewEndMs - viewStartMs; if (cur <= 0) cur = full;
        var span = Math.max(2000, Math.min(full, cur * factor));
        if (centerMs < viewStartMs || centerMs > viewEndMs) centerMs = (viewStartMs + viewEndMs) / 2;
        var frac = (centerMs - viewStartMs) / cur;
        var ns = centerMs - frac * span, ne = ns + span;
        if (ns < winStartMs) { ns = winStartMs; ne = ns + span; }
        if (ne > winEndMs) { ne = winEndMs; ns = ne - span; }
        viewStartMs = Math.max(winStartMs, ns);
        viewEndMs = Math.min(winEndMs, ne);
    }
    function panView(deltaMs) {
        var span = viewEndMs - viewStartMs;
        var ns = viewStartMs + deltaMs, ne = viewEndMs + deltaMs;
        if (ns < winStartMs) { ns = winStartMs; ne = ns + span; }
        if (ne > winEndMs) { ne = winEndMs; ns = ne - span; }
        viewStartMs = ns; viewEndMs = ne;
    }
    // Human span label for the "Custom" zoom chip, e.g. "2h 14m", "45m", "30s".
    function fmtSpan(ms) {
        var s = Math.round(ms / 1000);
        if (s < 60) return s + "s";
        var m = Math.round(s / 60);
        if (m < 60) return m + "m";
        var h = Math.floor(m / 60), mm = m % 60;
        return mm ? (h + "h " + mm + "m") : (h + "h");
    }

    // ---- timeline ruler (adaptive tick marks, Premiere/FCP-style) -----------
    // Nice major intervals, each with a clock-aligned minor subdivision, so ticks
    // always land on round local times. Picked so a labeled tick is ~every 90px.
    readonly property var _niceIntervals: [
        { major: 1000, minor: 1 },     { major: 5000, minor: 5 },     { major: 10000, minor: 2 },
        { major: 15000, minor: 3 },    { major: 30000, minor: 2 },    { major: 60000, minor: 4 },
        { major: 120000, minor: 4 },   { major: 300000, minor: 5 },   { major: 600000, minor: 2 },
        { major: 900000, minor: 3 },   { major: 1800000, minor: 2 },  { major: 3600000, minor: 4 },
        { major: 7200000, minor: 4 },  { major: 10800000, minor: 3 }, { major: 21600000, minor: 6 },
        { major: 43200000, minor: 2 }, { major: 86400000, minor: 4 }
    ]
    function _localMidnight(ms) { var d = new Date(ms); d.setHours(0, 0, 0, 0); return d.getTime(); }
    function _rulerLabel(ms, interval) {
        var d = new Date(ms);
        return interval < 60000 ? Qt.formatTime(d, "HH:mm:ss") : Qt.formatTime(d, "HH:mm");
    }
    // Tick marks for the visible [startMs,endMs] over widthPx: [{ms, major, lbl}].
    function computeTicks(startMs, endMs, widthPx) {
        var span = endMs - startMs;
        if (span <= 0 || widthPx <= 0) return [];
        var target = span * 90 / widthPx;            // aim for a labeled tick ~every 90px
        var pick = _niceIntervals[_niceIntervals.length - 1];
        for (var i = 0; i < _niceIntervals.length; i++)
            if (_niceIntervals[i].major >= target) { pick = _niceIntervals[i]; break; }
        var minorStep = pick.major / pick.minor;
        var anchor = _localMidnight(startMs);        // align to local midnight (round local times)
        var first = anchor + Math.ceil((startMs - anchor) / minorStep) * minorStep;
        var out = [];
        for (var t = first; t <= endMs && out.length < 600; t += minorStep) {
            var rel = Math.round((t - anchor) / minorStep);
            var isMajor = (rel % pick.minor) === 0;
            out.push({ ms: t, major: isMajor, lbl: isMajor ? _rulerLabel(t, pick.major) : "" });
        }
        return out;
    }

    // ---- session open ----------------------------------------------------
    property bool _pendingOpen: false
    // When >= 0, tryOpen() uses this explicit wall window (a calendar day)
    // instead of the rolling "last zoomMin minutes" window.
    property double _explicitStart: -1
    property double _explicitEnd: -1
    property double _pendingSeekMs: -1     // after the session loads, seek here (event open-at, −15s lead-in)
    property bool _pendingArmed: false     // true only once THIS open's session is ready (race-safe deferred seek)
    property string selectedDay: ""        // "yyyy-MM-dd" loaded from the calendar, else ""

    // footage-calendar coverage state (fed by PlaybackClient.coverageReady)
    property int retentionDays: 35         // longest tier retention = calendar span
    property var footageDays: []           // dates with recorded footage
    property bool coveragePending: true    // coverage API not yet answered/available

    function openFor(cam, spanMin) {
        camera = cam;
        zoomMin = spanMin || zoomMin;
        _explicitStart = -1; _explicitEnd = -1; selectedDay = ""; _pendingSeekMs = -1;
        coveragePending = true; footageDays = [];   // reset for the (possibly new) camera
        errorText = ""; selStartMs = -1; selEndMs = -1;
        if (!client) return;
        client.ensureReady();
        if (root.camId !== "") client.fetchCoverage(root.camId);
        _pendingOpen = true;
        tryOpen();
    }
    // Load a single calendar day's full 24h (gaps included), clamped to now.
    function openForDay(dateStr) {
        if (!camera) return;
        var startD = new Date(dateStr + "T00:00:00");   // local midnight
        var s = startD.getTime();
        _explicitStart = s;
        _explicitEnd = Math.min(s + 86400000, Date.now());
        selectedDay = dateStr;
        zoomMin = 1440;
        errorText = ""; selStartMs = -1; selEndMs = -1; _pendingSeekMs = -1;
        // Coverage already tells us this day has no recorded footage (it has no
        // calendar dot) — show an honest empty state instead of opening a session
        // that can only come back empty (or, on a transport hiccup, as a cryptic
        // "Session error"). Only short-circuit when coverage is actually known.
        if (!coveragePending && footageDays.indexOf(dateStr) < 0) {
            _pendingOpen = false; loading = false;
            frags = []; sessionId = ""; compactDuration = 0;
            if (player) { player.stop(); player.source = ""; }
            errorText = "No footage recorded on this day.";
            return;
        }
        if (!client) return;
        client.ensureReady();
        _pendingOpen = true;
        tryOpen();
    }
    // Open playback at a specific wall instant (e.g. from an event), loading that
    // day and seeking to 15s before the moment so the operator sees the lead-up.
    function openAt(cam, atMs) {
        if (!cam || !atMs || atMs <= 0) { openFor(cam, 60); return; }
        camera = cam;
        openForDay(Qt.formatDate(new Date(atMs), "yyyy-MM-dd"));
        _pendingSeekMs = atMs - 15000;     // set AFTER openForDay (which clears it); applied on session load
        _pendingArmed = false;             // disarm until this day's session reports ready
    }
    function tryOpen() {
        if (!_pendingOpen || !client || !camera) return;
        // Live View off → playback-service is stopped; no session can be created.
        // Skip the doomed attempt (the player overlay explains it) and keep
        // _pendingOpen so re-enabling Live View re-creates the session.
        if (root.cameraModel && root.cameraModel.liveViewEnabled === false) {
            loading = false; errorText = "";
            return;
        }
        var id = client.cameraIdForIp(camera.ip) || client.cameraIdForMac(camera.mac || "");
        if (!id) {
            if (!client.loggedIn) return;          // /streams not resolved yet — wait
            _pendingOpen = false;
            errorText = "This camera is not in the recording backend.";
            return;
        }
        _pendingOpen = false;
        loading = true;
        frags = [];            // drop the prior session's fragments — a deferred seek or
                               // overlay must never resolve against stale coverage mid-swap
        // Fully unload (not just stop) before switching sessions. Qt 6.4's stop()
        // re-prerolls the OLD media at position 0 — it re-downloads its first
        // segments through the proxy (observed in the 2026-06-11 seek bench) while
        // the new session is being created. Clearing the source drops that wasted
        // work and detaches the old pipeline cleanly.
        player.stop();
        player.source = "";
        var start, end;
        if (_explicitStart >= 0) { start = _explicitStart; end = _explicitEnd; }
        else { end = Date.now(); start = end - zoomMin * 60000; }
        // hevc_capable=true: we decode HEVC, so prefer the hot 1440p main stream
        // where it exists (backend serves sub/h264 elsewhere). The 2026-06-11
        // hevc_capable 500 is fixed server-side (131d1b6) — see
        // docs/letters/2026-06-11-session-hevc-capable-500.reply.md.
        client.openSession(id, new Date(start).toISOString(),
                           new Date(end).toISOString(), true);
    }
    function setZoom(spanMin) { openFor(camera, spanMin); }

    Connections {
        target: root.client
        enabled: root.client !== null
        function onSessionReady(sid, dur, fragments, meta) {
            root.loading = false;
            root._pendingArmed = true;     // fragments below are now THIS session's — safe to apply a pending seek
            root.sessionId = sid;
            root.compactDuration = dur;
            root.winStartMs = Date.parse(meta.wall_start);
            root.winEndMs = Date.parse(meta.wall_end);
            root.resetView();          // new session → scrubber shows the full window
            var out = [];
            for (var i = 0; i < fragments.length; i++) {
                var f = fragments[i];
                if (f.availability !== "ready") continue;
                out.push({ cs: f.compact_start, ce: f.compact_end,
                           ws: Date.parse(f.wall_start), we: Date.parse(f.wall_end),
                           codec: f.codec, tier: f.tier, resolution: f.resolution });
            }
            root.frags = out;
            if (out.length === 0) { root.errorText = "No footage recorded in this range."; return; }
            root.errorText = "";
            root.loadMotionEvents();        // point events + recent list (EventModel)
            root.loadTimeline();            // motion episode spans from /events/timeline
            root.playSpeed = 1; root.paused = false; root._scanPos = -1;   // fresh session → 1× play
            scanTimer.stop(); player.playbackRate = 1;
            player.source = root.client.playlistUrl(sid);
            player.play();
        }
        function onSessionFailed(err) { root.loading = false; root.errorText = err; }
        function onCamerasResolved() {
            root.tryOpen();
            if (root.camId !== "") root.client.fetchCoverage(root.camId);
        }
        function onCoverageReady(cameraId, available, retentionDays, days) {
            if (cameraId !== root.camId) return;
            root.coveragePending = !available;
            if (available && retentionDays > 0) root.retentionDays = retentionDays;
            var out = [];
            for (var i = 0; i < days.length; i++) {
                var d = days[i];
                if (d.has_footage === undefined || d.has_footage) out.push(d.date);
            }
            root.footageDays = out;
        }
        // Motion episode spans (or density buckets) from /events/timeline — the
        // backend pairs motion_started↔motion_ended server-side, so no client paging.
        function onTimelineReady(cid, mode, blocks) {
            if (cid !== root.camId) return;
            if (mode === "buckets") {
                var bk = [];
                for (var i = 0; i < blocks.length; i++) {
                    var b = blocks[i];
                    bk.push({ sMs: Date.parse(b.bucket_start), eMs: Date.parse(b.bucket_end),
                              count: b.episode_count, seconds: b.motion_seconds });
                }
                root.motionBuckets = bk; root.bucketMode = true; root.motionEpisodes = [];
                return;
            }
            var eps = [];
            for (var j = 0; j < blocks.length; j++) {
                var ep = blocks[j];
                var st = Date.parse(ep.start_time);
                var en = ep.end_time ? Date.parse(ep.end_time) : Math.min(Date.now(), root.winEndMs);
                if (en < st) { var t = st; st = en; en = t; }
                eps.push({ startMs: st, endMs: en });
            }
            if (eps.length > root.bucketThreshold) {     // very busy → bounded density buckets
                root.motionEpisodes = []; root.bucketMode = true;
                root.client.fetchTimeline(root.camId, new Date(root.winStartMs).toISOString(),
                                          new Date(root.winEndMs).toISOString(), 600);
                return;
            }
            eps.sort(function (a, b) { return a.startMs - b.startMs; });
            root.motionEpisodes = eps; root.bucketMode = false;
        }
    }

    // Dedicated event feed for the playback scrubber's NON-MOTION point events +
    // the aside recent list — a SEPARATE EventModel from the shared global one so
    // scoping it to this camera+window doesn't clobber the Events screen / Live
    // "recent" query. (Motion spans come from /events/timeline; see onTimelineReady.)
    EventModel { id: motionEvents }
    Connections {
        target: motionEvents
        function onChanged() { root.rebuildEvents(); }   // first page is enough for points + recent list
    }

    // Live View came back on → (re)create the playback session if we're showing
    // this screen for a camera (covers a gated open, and a session that died when
    // Live View was switched off mid-playback).
    Connections {
        target: root.cameraModel
        function onFunctionsChanged() {
            if (root.visible && root.camera && root.cameraModel
                && root.cameraModel.liveViewEnabled !== false) {
                root._pendingOpen = true;
                root.tryOpen();
            }
        }
    }

    // pause streams when hidden; tidy player on hide
    focus: true
    onVisibleChanged: { if (visible) forceActiveFocus(); else { player.stop(); scanTimer.stop() } }
    // Timeline zoom keys (Premiere-style): +/- around the playhead, 0 to fit.
    Keys.onPressed: (e) => {
        if (root.frags.length === 0) return;
        if (e.key === Qt.Key_Plus || e.key === Qt.Key_Equal) { root.zoomView(0.5, root.playheadMs); e.accepted = true; }
        else if (e.key === Qt.Key_Minus || e.key === Qt.Key_Underscore) { root.zoomView(2.0, root.playheadMs); e.accepted = true; }
        else if (e.key === Qt.Key_0 || e.key === Qt.Key_Home) { root.resetView(); e.accepted = true; }
    }

    // Drives the playhead during high-speed scan (playSpeed > maxDecodeRate):
    // accumulate rate×interval ms of footage per tick and seek there; stop at the
    // end of footage. The player stays playing so frames render between jumps.
    Timer {
        id: scanTimer
        interval: 200; repeat: true
        onTriggered: {
            if (root.playSpeed <= root.maxDecodeRate || root.frags.length === 0) { stop(); return; }
            if (root._scanPos < 0) root._scanPos = player.position;
            root._scanPos += root.playSpeed * interval;        // ms of footage advanced per tick
            var endMs = Math.max(0, (root.compactDuration - 0.4) * 1000);
            if (root.compactDuration > 0 && root._scanPos >= endMs) {
                player.position = Math.round(endMs);
                root.playSpeed = 1; root.paused = true; root.applyTransport();   // reached the end
                return;
            }
            player.position = Math.round(root._scanPos);
        }
    }

    // ======================================================================
    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Recording switched off → no new footage is being recorded; past footage
        // is still viewable. Calm amber note (not a fault). Fail-safe: only on an
        // explicit enabled:false.
        Rectangle {
            id: recBanner
            readonly property bool recOff: root.cameraModel ? (root.cameraModel.recordingEnabled === false) : false
            Layout.fillWidth: true
            visible: recOff
            Layout.preferredHeight: visible ? 34 : 0
            color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.10)
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.accent }
            Row {
                anchors { left: parent.left; leftMargin: 16; right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
                spacing: 8
                Icon { anchors.verticalCenter: parent.verticalCenter; name: "off"; size: 14; color: Theme.accent }
                Text { anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 24; elide: Text.ElideRight
                    text: "Recording is switched off — no new footage is being recorded. Past footage is still available."
                    color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12 }
            }
        }

        // ---- player + aside ---------------------------------------------
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            Rectangle {
                id: playerArea
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: "#1d2120"
                clip: true

                VideoOutput { id: vout; anchors.fill: parent; fillMode: VideoOutput.PreserveAspectFit }
                MediaPlayer {
                    id: player
                    videoOutput: vout
                    audioOutput: null
                    // Apply a deferred open-at seek (event −15s jump / WT_PLAYBACK_DAY
                    // instant). Must wait for `seekable` — a position set on
                    // durationChanged is silently dropped by the not-yet-prerolled
                    // pipeline (found 2026-06-12: event jumps landed at day start).
                    function applyPendingSeek() {
                        // _pendingArmed ensures frags belong to THIS session — a seekable/
                        // duration signal from the prior session (or the source swap) must
                        // not apply the pending seek against stale fragments.
                        if (!root._pendingArmed || root.loading || !(seekable && duration > 0 && root._pendingSeekMs >= 0)) return;
                        if (root.frags.length === 0) { root.seekToWall(root._pendingSeekMs); root._pendingSeekMs = -1; return; }
                        // Event/open-at jump: land on the recorded footage CLOSEST to the
                        // event, not a blind forward-snap (which can jump minutes across a
                        // gap) or a freeze at EOS. Motion-triggered cams often detect motion
                        // they never record; if the nearest footage is far, say so honestly.
                        var evt = root._pendingSeekMs + 15000;     // pending = event − 15s lead-in
                        var bestWall = -1, bestD = Infinity;
                        for (var i = 0; i < root.frags.length; i++) {
                            var f = root.frags[i], d, w;
                            if (evt >= f.ws && evt <= f.we) { d = 0; w = root._pendingSeekMs; }   // inside → keep the −15s lead-in
                            else if (evt > f.we) { d = evt - f.we; w = f.we - 3000; }             // gap after → this clip's tail
                            else { d = f.ws - evt; w = f.ws; }                                    // gap before → this clip's head
                            if (d < bestD) { bestD = d; bestWall = w; }
                        }
                        if (bestD > 90000) {     // no footage within 90s of the event
                            root.errorText = "No footage was recorded around this moment.";
                            root._pendingSeekMs = -1;
                            return;
                        }
                        root.seekToWall(bestWall);
                        root._pendingSeekMs = -1;
                    }
                    onSeekableChanged: applyPendingSeek()
                    onDurationChanged: applyPendingSeek()
                }

                LoadingState {
                    anchors.centerIn: parent
                    visible: root.loading || (player.mediaStatus === MediaPlayer.LoadingMedia && root.errorText === "")
                    label: "Loading recording…"
                }
                Column {
                    anchors.centerIn: parent
                    spacing: 6
                    visible: root.errorText !== ""
                    Icon { anchors.horizontalCenter: parent.horizontalCenter; name: "off"; size: 30; color: Theme.ink3 }
                    Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.errorText
                        color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 13 }
                }

                // Live View switched off → playback-service is stopped, so no
                // recorded playback / mosaic session can be created. Calm; explains
                // the deliberate state instead of a spinning or broken player.
                Rectangle {
                    anchors.fill: parent
                    visible: root.cameraModel && root.cameraModel.liveViewEnabled === false
                    color: "#1d2120"
                    Column {
                        anchors.centerIn: parent
                        spacing: 8
                        width: parent.width
                        Icon { anchors.horizontalCenter: parent.horizontalCenter; name: "off"; size: 34; color: Theme.accent }
                        Text { anchors.horizontalCenter: parent.horizontalCenter
                            text: "Playback unavailable"; color: Theme.ink
                            font.family: Theme.fontSans; font.pixelSize: 16; font.weight: Font.DemiBold }
                        Text { anchors.horizontalCenter: parent.horizontalCenter
                            width: Math.min(440, parent.width - 48); horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                            text: "Live View is switched off — recorded playback and export are paused. This is an operator setting, not a fault."
                            color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12 }
                    }
                }

                // top overlay
                Rectangle {
                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                    height: 60
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: Qt.rgba(0,0,0,0.75) }
                        GradientStop { position: 1.0; color: "transparent" }
                    }
                    RowLayout {
                        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                        anchors.leftMargin: 14; anchors.rightMargin: 16; anchors.topMargin: 12
                        spacing: 10
                        IconButton { name: "back"; iconColor: "#fff"; hoverIcon: Theme.accent; tip: "Back"; onClicked: root.closed() }
                        Rectangle {
                            implicitWidth: pbTag.implicitWidth + 14; implicitHeight: 18; color: Theme.accent
                            Text { id: pbTag; anchors.centerIn: parent; text: "PLAYBACK"; color: Theme.bg
                                font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.Bold; font.letterSpacing: 1 }
                        }
                        Text { text: root.camera ? root.camera.name : ""; color: "#fff"
                            font.family: Theme.fontSans; font.pixelSize: 14; font.weight: Font.DemiBold }
                        Item { Layout.fillWidth: true }
                        // primary playhead readout — the main time reference while reviewing
                        Text { text: Qt.formatDate(new Date(root.playheadMs), "ddd") + " · " + root.fmtClock(root.playheadMs)
                            color: "#fff"; font.family: Theme.fontMono; font.pixelSize: 22; font.weight: Font.DemiBold
                            font.letterSpacing: 0.5; visible: root.frags.length > 0 }
                    }
                }

                // selection chip
                Rectangle {
                    anchors.top: parent.top; anchors.topMargin: 64; anchors.horizontalCenter: parent.horizontalCenter
                    visible: root.hasSelection
                    implicitWidth: selRow.implicitWidth + 20; implicitHeight: 32
                    color: Qt.rgba(0,0,0,0.6); border.width: 1; border.color: Theme.accent
                    Row {
                        id: selRow; anchors.centerIn: parent; spacing: 10
                        Text { anchors.verticalCenter: parent.verticalCenter
                            text: "CLIP  " + root.fmtClock(root.selStartMs) + " → " + root.fmtClock(root.selEndMs)
                                  + "  ·  " + root.fmtDur((root.selEndMs - root.selStartMs)/1000)
                            color: "#fff"; font.family: Theme.fontMono; font.pixelSize: 11 }
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            implicitWidth: expTxt.implicitWidth + 16; implicitHeight: 22; color: Theme.accent
                            Text { id: expTxt; anchors.centerIn: parent; text: "Export Clip"; color: Theme.bg
                                font.family: Theme.fontSans; font.pixelSize: 11; font.weight: Font.Medium }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.openExportDrawer() }
                        }
                    }
                }

                // bottom controls
                Rectangle {
                    anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                    height: 56
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: "transparent" }
                        GradientStop { position: 1.0; color: Qt.rgba(0,0,0,0.75) }
                    }
                    component Ctl: IconButton {
                        bgColor: Qt.rgba(0,0,0,0.5); borderColor: Theme.line2
                        iconColor: "#fff"; hoverBg: Theme.accent; hoverBorder: Theme.accent; hoverIcon: Theme.bg
                    }
                    // left cluster
                    Row {
                        anchors.left: parent.left; anchors.leftMargin: 16
                        anchors.bottom: parent.bottom; anchors.bottomMargin: 12
                        spacing: 6
                        Ctl { name: "jumpBack"; tip: "Back 10s"; onClicked: { var p = Math.max(0, player.position - 10000); player.position = p; root._scanPos = p; } }
                        Ctl { name: root.advancing ? "pause" : "play"
                            tip: "Play / pause"
                            onClicked: root.togglePlay() }
                        Ctl { name: "jumpFwd"; tip: "Forward 10s"; onClicked: { var p = Math.min(player.duration, player.position + 10000); player.position = p; root._scanPos = p; } }
                        // speed — popup of x1…x200 (x20+ scans, since the decoder caps ~14×)
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            implicitWidth: 48; implicitHeight: 30; color: spdMa.containsMouse ? Theme.accent : Qt.rgba(0,0,0,0.5)
                            border.width: 1; border.color: spdMa.containsMouse ? Theme.accent : Theme.line2
                            Text { anchors.centerIn: parent; text: root.playSpeed + "×"; color: spdMa.containsMouse ? Theme.bg : "#fff"
                                font.family: Theme.fontMono; font.pixelSize: 11; font.weight: Font.Bold }
                            MouseArea { id: spdMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: spdPopup.open() }
                            C.Popup {
                                id: spdPopup
                                y: -implicitHeight - 4          // open upward (controls sit at the bottom)
                                x: 0; width: 66; padding: 0
                                background: Rectangle { color: Theme.panel; border.color: Theme.line2; border.width: 1 }
                                contentItem: Column {
                                    Repeater {
                                        model: root.speeds
                                        delegate: Rectangle {
                                            required property var modelData
                                            width: 66; height: 30
                                            color: spdOptMa.containsMouse ? Theme.panel2 : "transparent"
                                            Text { anchors.centerIn: parent; text: modelData + "×"
                                                color: root.playSpeed === modelData ? Theme.accent : Theme.ink
                                                font.family: Theme.fontMono; font.pixelSize: 11; font.weight: Font.Bold }
                                            MouseArea { id: spdOptMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: { root.setSpeed(modelData); spdPopup.close() } }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    // right cluster
                    Row {
                        anchors.right: parent.right; anchors.rightMargin: 16
                        anchors.bottom: parent.bottom; anchors.bottomMargin: 12
                        spacing: 6
                        Ctl { name: "shot"; tip: "Snapshot"; onClicked: root.snapshot() }
                        Ctl { name: "full"; tip: "Fullscreen"; onClicked: root.fullscreenRequested() }
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            implicitWidth: rtlRow.implicitWidth + 18; implicitHeight: 30
                            color: rtlMa.containsMouse ? Theme.bad : Qt.rgba(0,0,0,0.5)
                            border.width: 1; border.color: Theme.bad
                            Row { id: rtlRow; anchors.centerIn: parent; spacing: 6
                                Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 7; height: 7; radius: 4; color: rtlMa.containsMouse ? "#fff" : Theme.bad }
                                Text { anchors.verticalCenter: parent.verticalCenter; text: "Return to Live"; color: "#fff"
                                    font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
                            }
                            MouseArea { id: rtlMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.returnToLive() }
                        }
                    }
                }
            }

            // ---- info aside ----
            Rectangle {
                Layout.preferredWidth: 340
                Layout.fillHeight: true
                color: Theme.panel
                Rectangle { anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 1; color: Theme.line }
                ColumnLayout {
                    anchors.fill: parent; anchors.leftMargin: 1; spacing: 0
                    component Hdr: Text {
                        Layout.fillWidth: true; Layout.topMargin: 14; Layout.leftMargin: 16; Layout.bottomMargin: 8
                        color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                        font.weight: Font.DemiBold; font.letterSpacing: 1.4; font.capitalization: Font.AllUppercase
                    }
                    component KV: RowLayout {
                        property string k: ""; property string v: ""
                        Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16
                        Text { text: parent.k; color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12; Layout.preferredWidth: 120 }
                        Text { text: parent.v; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12; Layout.fillWidth: true; horizontalAlignment: Text.AlignRight; elide: Text.ElideRight }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true; Layout.topMargin: 16; Layout.leftMargin: 16; Layout.rightMargin: 16; spacing: 2
                        Text { text: root.camera ? root.camera.name : ""; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 16; font.weight: Font.DemiBold }
                        Text { text: root.camera ? root.camera.groupName : ""; color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11 }
                        Row { spacing: 4; topPadding: 4
                            LiveStatusBadge { state: root.camera ? root.camera.live : CameraStatus.LiveUnknown }
                            RecordingStatusBadge { state: root.camera ? root.camera.recording : CameraStatus.RecUnknown }
                        }
                    }
                    Hdr { text: "Status" }
                    KV { k: "Playhead"; v: root.frags.length ? root.fmtClock(root.playheadMs) : "—" }
                    KV { k: "Quality"; v: { var f = root.fragAt(player.position/1000);
                            if (!f) return "—";
                            var c = f.codec === "hevc" ? "HEVC" : "H.264";
                            // E5: read the real resolution field; fall back to codec inference
                            // only for old rows where resolution is null.
                            return (f.resolution && f.resolution !== "") ? (f.resolution + " (" + c + ")")
                                   : (f.codec === "hevc" ? "HD 1440p (HEVC)" : "SD 720p (H.264)"); } }
                    KV { k: "Coverage"; v: root.frags.length + " segments" }
                    KV { k: "Window"; v: root.selectedDay !== ""
                            ? Qt.formatDate(new Date(root.selectedDay + "T00:00:00"), "ddd d MMM")
                            : (root.zoomMin === 1440 ? "24 hours" : root.zoomMin === 720 ? "12 hours"
                               : root.zoomMin === 360 ? "6 hours" : root.zoomMin === 60 ? "1 hour"
                               : root.zoomMin + " min") }

                    // footage calendar — pick a day to load its full 24h
                    Item { Layout.fillWidth: true; Layout.preferredHeight: 10 }
                    Rectangle { Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.preferredHeight: 1; color: Theme.line }
                    Item { Layout.fillWidth: true; Layout.preferredHeight: 14 }
                    PlaybackCalendar {
                        Layout.fillWidth: true
                        retentionDays: root.retentionDays
                        footageDays: root.footageDays
                        pending: root.coveragePending
                        selectedDate: root.selectedDay
                        onDaySelected: (d) => root.openForDay(d)
                    }

                    Hdr { text: "Events" }
                    // legend / per-type show-hide — one toggle per type present in the
                    // window; click to show/hide that type's markers on the scrubber.
                    Flow {
                        Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16
                        spacing: 6; visible: root.eventTypesPresent.length > 0
                        Repeater {
                            model: root.eventTypesPresent
                            Rectangle {
                                id: lg
                                required property var modelData
                                readonly property string key: lg.modelData
                                readonly property bool on: root.typeVisible(lg.key)
                                implicitWidth: lgRow.implicitWidth + 14; implicitHeight: 22
                                color: lgMa.containsMouse ? Theme.panel2 : "transparent"
                                border.width: 1; border.color: Theme.line2
                                Row { id: lgRow; anchors.centerIn: parent; spacing: 6
                                    Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 7; height: 7
                                        color: EventStyle.color(lg.key); opacity: lg.on ? 1 : 0.3 }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: EventStyle.label(lg.key)
                                        color: lg.on ? Theme.ink : Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11 }
                                }
                                MouseArea { id: lgMa; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor; onClicked: root.toggleType(lg.key) }
                            }
                        }
                    }
                    Text { visible: root.eventTypesPresent.length === 0
                        Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16
                        text: "No events in this range."; color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12 }

                    Item { Layout.fillWidth: true; Layout.preferredHeight: 8 }
                    // recent list — most recent events (visible types); click to jump
                    Repeater {
                        model: root.recentList
                        Rectangle {
                            id: evrow
                            required property var modelData
                            Layout.fillWidth: true; Layout.preferredHeight: 26
                            color: evMa.containsMouse ? Theme.panel2 : "transparent"
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 16; spacing: 8
                                Rectangle { Layout.preferredWidth: 6; Layout.preferredHeight: 6; Layout.alignment: Qt.AlignVCenter
                                    color: EventStyle.color(evrow.modelData.type) }
                                Text { Layout.fillWidth: true; text: EventStyle.label(evrow.modelData.type); color: Theme.ink
                                    font.family: Theme.fontSans; font.pixelSize: 12; elide: Text.ElideRight; verticalAlignment: Text.AlignVCenter }
                                Text { text: root.fmtClock(evrow.modelData.ts); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11 }
                            }
                            MouseArea { id: evMa; anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor; onClicked: root.seekToWall(evrow.modelData.ts) }
                        }
                    }
                    Item { Layout.fillHeight: true }
                }
            }
        }

        // ---- timeline ----------------------------------------------------
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 124
            color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; height: 1; color: Theme.line }

            // controls row
            RowLayout {
                id: tlControls
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                anchors.leftMargin: 16; anchors.rightMargin: 16; anchors.topMargin: 12
                height: 22; spacing: 8
                component Chip: Rectangle {
                    property string label: ""
                    property bool active: false
                    signal clicked()
                    implicitWidth: ct.implicitWidth + 18; implicitHeight: 22
                    color: active ? Theme.accent : "transparent"
                    border.width: 1; border.color: active ? Theme.accent : Theme.line2
                    Text { id: ct; anchors.centerIn: parent; text: parent.label; color: parent.active ? Theme.bg : Theme.ink2
                        font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 0.8; font.capitalization: Font.AllUppercase }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: parent.clicked() }
                }
                Chip { label: "Last hour"; onClicked: root.setZoom(60) }
                Chip { label: "Last 15 min"; onClicked: root.setZoom(15) }
                Text { text: root.frags.length ? ("PLAYHEAD · " + Qt.formatDate(new Date(root.playheadMs), "ddd") + " " + root.fmtClock(root.playheadMs)) : ""
                    color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11; Layout.leftMargin: 8 }
                Item { Layout.fillWidth: true }
                Chip { label: "Events"; active: Settings.eventsOnScrubber; onClicked: Settings.eventsOnScrubber = !Settings.eventsOnScrubber }
                // Window presets re-open the session; they de-highlight once you
                // wheel/±-zoom the scrubber into a custom range (then a Custom chip
                // shows the visible span; scroll/±/0 to zoom, Fit to reset).
                Chip { label: "15m"; active: root.zoomMin === 15 && root.selectedDay === "" && !root.tlZoomed; onClicked: root.setZoom(15) }
                Chip { label: "1h"; active: root.zoomMin === 60 && root.selectedDay === "" && !root.tlZoomed; onClicked: root.setZoom(60) }
                Chip { label: "6h"; active: root.zoomMin === 360 && root.selectedDay === "" && !root.tlZoomed; onClicked: root.setZoom(360) }
                Chip { label: "12h"; active: root.zoomMin === 720 && root.selectedDay === "" && !root.tlZoomed; onClicked: root.setZoom(720) }
                Chip { label: "24h"; active: root.zoomMin === 1440 && root.selectedDay === "" && !root.tlZoomed; onClicked: root.setZoom(1440) }
                Chip { visible: root.tlZoomed; active: true; label: root.fmtSpan(root.viewEndMs - root.viewStartMs); onClicked: root.resetView() }
                Chip { visible: root.tlZoomed; label: "Fit"; onClicked: root.resetView() }
            }

            // bar
            Rectangle {
                id: bar
                anchors.left: parent.left; anchors.right: parent.right
                anchors.top: tlControls.bottom; anchors.topMargin: 10
                anchors.leftMargin: 16; anchors.rightMargin: 16
                height: 78
                color: "#16140f"; border.width: 1; border.color: Theme.line

                clip: true   // footage/selection outside the zoomed view are clipped
                readonly property double span: Math.max(1, root.viewEndMs - root.viewStartMs)
                function xOf(ms) { return (ms - root.viewStartMs) / span * width }
                function msOf(x) { return root.viewStartMs + (x / width) * span }
                property double hoverMs: -1   // wall ms under the cursor (-1 = not hovering)
                readonly property var rulerTicks: root.computeTicks(root.viewStartMs, root.viewEndMs, width)
                // Motion episodes clipped to the visible window and MERGED by zoom: two
                // episodes whose on-screen gap is < ~3px fuse into one band (so a busy
                // 24h view collapses to legible density bands; zoom in and they resolve
                // into discrete start→end spans). coveredMs/extent drives the intensity.
                readonly property var visibleMotion: {
                    if (root.bucketMode || !root.typeVisible("motion")) return [];
                    var eps = root.motionEpisodes, vs = root.viewStartMs, ve = root.viewEndMs, w = width, sp = ve - vs;
                    if (!eps || eps.length === 0 || sp <= 0 || w <= 0) return [];
                    var minGapMs = (3 / w) * sp, out = [], cur = null;
                    for (var i = 0; i < eps.length; i++) {
                        var e = eps[i];
                        if (e.endMs < vs || e.startMs > ve) continue;
                        var s = Math.max(e.startMs, vs), en = Math.min(e.endMs, ve);
                        if (cur && s - cur.eMs <= minGapMs) {
                            cur.eMs = Math.max(cur.eMs, en); cur.count += 1; cur.coveredMs += (en - s);
                        } else {
                            if (cur) out.push(cur);
                            cur = { sMs: s, eMs: en, count: 1, coveredMs: (en - s) };
                        }
                    }
                    if (cur) out.push(cur);
                    return out.map(function (b) {
                        return { sMs: b.sMs, eMs: b.eMs, count: b.count,
                                 intensity: Math.min(1, b.coveredMs / Math.max(1, b.eMs - b.sMs)) };
                    });
                }
                // density-bucket band (server aggregation) — used instead of per-episode
                // rendering for a very busy window. One segment per non-empty bin.
                readonly property var bucketBand: {
                    if (!root.bucketMode || !root.typeVisible("motion")) return [];
                    var bk = root.motionBuckets, vs = root.viewStartMs, ve = root.viewEndMs, out = [];
                    if (!bk || bk.length === 0) return [];
                    for (var i = 0; i < bk.length; i++) {
                        var b = bk[i];
                        if (b.eMs < vs || b.sMs > ve || b.seconds <= 0) continue;
                        var dur = Math.max(1, (b.eMs - b.sMs) / 1000);
                        out.push({ sMs: b.sMs, eMs: b.eMs, count: b.count, intensity: Math.min(1, b.seconds / dur) });
                    }
                    return out;
                }
                readonly property var motionBand: root.bucketMode ? bucketBand : visibleMotion
                function motionAt(ms) {
                    var v = motionBand;
                    for (var i = 0; i < v.length; i++) if (ms >= v[i].sMs && ms <= v[i].eMs) return v[i];
                    return null;
                }
                readonly property var hoverMotion: hoverMs >= 0 ? motionAt(hoverMs) : null
                // discrete (non-motion) events clipped to view + visible types, clustered
                // by ~7px so dense runs collapse to one tick with a count.
                readonly property var visiblePoints: {
                    if (!Settings.eventsOnScrubber) return [];
                    var pts = root.pointEvents, vs = root.viewStartMs, ve = root.viewEndMs, w = width, sp = ve - vs;
                    if (!pts || pts.length === 0 || sp <= 0 || w <= 0) return [];
                    var minGapMs = (7 / w) * sp, out = [], cur = null;
                    for (var i = 0; i < pts.length; i++) {
                        var p = pts[i];
                        if (p.ms < vs || p.ms > ve || root.typeHidden(p.type)) continue;
                        if (cur && p.ms - cur.lastMs <= minGapMs) {
                            cur.count += 1; cur.lastMs = p.ms;
                            if (cur.type !== p.type) cur.mixed = true;
                        } else {
                            if (cur) out.push(cur);
                            cur = { ms: p.ms, lastMs: p.ms, count: 1, type: p.type, mixed: false };
                        }
                    }
                    if (cur) out.push(cur);
                    return out;
                }
                function pointAt(ms) {
                    var v = visiblePoints, sp = root.viewEndMs - root.viewStartMs, tol = (6 / Math.max(1, width)) * sp;
                    for (var i = 0; i < v.length; i++)
                        if (Math.abs(ms - (v[i].ms + v[i].lastMs) / 2) <= tol) return v[i];
                    return null;
                }
                readonly property var hoverPoint: hoverMs >= 0 ? pointAt(hoverMs) : null

                // gap backdrop (whole bar = red stripe), footage drawn on top
                Rectangle {
                    anchors.fill: parent; anchors.margins: 1
                    visible: root.frags.length > 0
                    color: "transparent"
                    Rectangle { anchors.fill: parent; color: Theme.bad; opacity: 0.12 }
                }

                // footage segments (olive)
                Repeater {
                    model: root.frags
                    Rectangle {
                        readonly property double x0: bar.xOf(modelData.ws)
                        readonly property double x1: bar.xOf(modelData.we)
                        x: Math.max(1, x0); y: 8
                        width: Math.max(1, x1 - x0); height: 18
                        color: modelData.codec === "hevc" ? Theme.good : Qt.lighter(Theme.good, 1.15)
                        opacity: 0.75
                    }
                }
                // motion episodes (amber) — a free-standing lane below the footage band;
                // merged into density bands at wide zoom (see bar.visibleMotion). Click a
                // band to seek into it; hover for the time range / count.
                Repeater {
                    model: bar.motionBand
                    Rectangle {
                        readonly property double bx0: bar.xOf(modelData.sMs)
                        readonly property double bx1: bar.xOf(modelData.eMs)
                        x: Math.max(1, bx0); y: 28
                        width: Math.max(2, bx1 - bx0); height: 6
                        color: Theme.accent
                        opacity: 0.45 + 0.45 * modelData.intensity
                    }
                }
                // lane labels
                Row {
                    anchors.left: parent.left; anchors.leftMargin: 6; anchors.top: parent.top; anchors.topMargin: 39
                    spacing: 10
                    Text { text: "FOOTAGE"; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 8; font.letterSpacing: 1 }
                    Text { visible: root.typeVisible("motion"); text: "MOTION"; color: Theme.accent; font.family: Theme.fontMono; font.pixelSize: 8; font.letterSpacing: 1 }
                }

                // discrete event ticks (non-motion types) — clustered pins colored by
                // type (neutral when a cluster mixes types); count shown for clusters.
                Repeater {
                    model: bar.visiblePoints
                    Item {
                        id: pin
                        readonly property double px: bar.xOf((modelData.ms + modelData.lastMs) / 2)
                        readonly property color c: modelData.mixed ? Theme.ink2 : EventStyle.color(modelData.type)
                        visible: px >= -2 && px <= bar.width + 2
                        x: px; y: 0
                        Rectangle { x: -2; y: 22; width: 5; height: 5; color: pin.c }                 // dot cap
                        Rectangle { x: 0; y: 24; width: 2; height: 14; color: pin.c; opacity: 0.9 }    // pin
                        Text { visible: modelData.count > 1; x: 4; y: 19; text: modelData.count
                            color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 8 }
                    }
                }

                // adaptive time ruler — major (labeled) + minor ticks at the bottom,
                // intervals chosen from the visible span (re-evaluates on zoom/pan)
                Repeater {
                    model: bar.rulerTicks
                    delegate: Item {
                        required property var modelData
                        readonly property real tx: bar.xOf(modelData.ms)
                        visible: tx >= -1 && tx <= bar.width + 1
                        Rectangle {
                            x: parent.tx; width: 1
                            height: parent.modelData.major ? 11 : 6
                            y: bar.height - height - 1
                            color: parent.modelData.major ? Qt.rgba(1, 1, 1, 0.40) : Qt.rgba(1, 1, 1, 0.16)
                        }
                        Text {
                            visible: parent.modelData.major && parent.tx <= bar.width - implicitWidth - 2
                            x: Math.round(parent.tx) + 3; y: bar.height - 25
                            text: parent.modelData.lbl
                            color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 8
                        }
                    }
                }

                // selection overlay
                Rectangle {
                    visible: root.hasSelection
                    x: bar.xOf(root.selStartMs); width: Math.max(2, bar.xOf(root.selEndMs) - bar.xOf(root.selStartMs))
                    y: 0; height: parent.height
                    color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.18)
                    Rectangle { anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 2; color: Theme.accent }
                    Rectangle { anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 2; color: Theme.accent }
                }

                // playhead
                Rectangle {
                    visible: root.frags.length > 0
                    x: Math.max(0, bar.xOf(root.playheadMs)) - 1; y: 0; width: 2; height: parent.height
                    color: "#ffffff"
                    Rectangle { anchors.horizontalCenter: parent.horizontalCenter; anchors.top: parent.top; width: 7; height: 7; rotation: 45; color: "#fff" }
                }

                // (window start/end axis labels removed — the visible range is conveyed
                // by the zoom buttons + calendar; the playhead readout above the video,
                // the PLAYHEAD label, and the hover tooltip are the time references.)

                // hover guide + time tooltip — the wall-clock time under the cursor
                Rectangle {
                    visible: bar.hoverMs >= 0
                    x: Math.max(0, Math.min(bar.width - 1, bar.xOf(bar.hoverMs)))
                    y: 0; width: 1; height: parent.height
                    color: Qt.rgba(1, 1, 1, 0.35)
                }
                Rectangle {
                    visible: bar.hoverMs >= 0
                    readonly property real hx: bar.xOf(bar.hoverMs)
                    x: Math.max(0, Math.min(bar.width - width, hx - width / 2))
                    y: 2
                    implicitWidth: hoverT.implicitWidth + 10; height: 16
                    color: Qt.rgba(0, 0, 0, 0.85); border.width: 1; border.color: Theme.line2
                    Text { id: hoverT; anchors.centerIn: parent
                        text: bar.hoverPoint
                              ? ((bar.hoverPoint.count > 1 ? bar.hoverPoint.count + " events · " : EventStyle.label(bar.hoverPoint.type) + " · ")
                                 + root.fmtClock((bar.hoverPoint.ms + bar.hoverPoint.lastMs) / 2))
                              : bar.hoverMotion
                                ? ((bar.hoverMotion.count > 1 ? bar.hoverMotion.count + " motions · " : "Motion · ")
                                   + root.fmtClock(bar.hoverMotion.sMs) + "–" + root.fmtClock(bar.hoverMotion.eMs))
                                : root.fmtClock(bar.hoverMs)
                        color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 9 }
                }

                // click to seek, drag to select
                MouseArea {
                    anchors.fill: parent
                    property double pressMs: -1
                    cursorShape: Qt.PointingHandCursor
                    hoverEnabled: true
                    onPressed: (m) => { pressMs = bar.msOf(m.x); root.selStartMs = -1; root.selEndMs = -1 }
                    onPositionChanged: (m) => {
                        bar.hoverMs = bar.msOf(m.x);
                        if (pressMs < 0) return;
                        var cur = bar.msOf(m.x);
                        root.selStartMs = Math.min(pressMs, cur);
                        root.selEndMs = Math.max(pressMs, cur);
                    }
                    onExited: bar.hoverMs = -1
                    onReleased: (m) => {
                        var cur = bar.msOf(m.x);
                        if (Math.abs(cur - pressMs) < bar.span / bar.width * 4) {  // a click, not a drag
                            root.selStartMs = -1; root.selEndMs = -1;
                            root.seekToWall(cur);
                        }
                        pressMs = -1;
                    }
                    // scroll = zoom on the cursor; Shift+scroll = pan (Premiere-style)
                    onWheel: (w) => {
                        if (w.modifiers & Qt.ShiftModifier)
                            root.panView(w.angleDelta.y > 0 ? -bar.span * 0.15 : bar.span * 0.15);
                        else
                            root.zoomView(w.angleDelta.y > 0 ? 0.8 : 1.25, bar.msOf(w.x));
                    }
                }
            }
        }
    }

    // returns the ready fragment covering compact-seconds s (or null)
    function fragAt(s) {
        for (var i = 0; i < frags.length; i++)
            if (s >= frags[i].cs && s <= frags[i].ce) return frags[i];
        return null;
    }

    signal fullscreenRequested()
    signal snapshotSaved(string path, string camName)

    function snapshot() {
        vout.grabToImage(function(res) {
            var p = Artifacts.newSnapshotPath((root.camera ? root.camera.camId : "playback") + "_pb");
            if (res.saveToFile(p)) root.snapshotSaved(p, root.camera ? root.camera.name : "");
        });
    }
    // Open the export drawer for the current selection, seeding it with a grabbed
    // preview frame. The drawer collects the full export form and emits confirmed()
    // with the fields cilex-vision's API supports today (range + mode).
    function openExportDrawer() {
        if (!hasSelection || !client) return;
        exportDrawer.openWith(camera, camId, selStartMs, selEndMs, frags, playheadMs);
        vout.grabToImage(function(res) { if (res) exportDrawer.previewSource = res.url; });
    }

    ExportDrawer {
        id: exportDrawer
        z: 50
        onConfirmed: (s, e, mode, purpose) => {
            if (!root.client) return;
            var base = (root.camera && root.camera.name) ? root.camera.name : root.camId;
            var dest = Artifacts.newExportPath(base, "mp4");
            root.client.createExport(root.camId, new Date(s).toISOString(),
                                     new Date(e).toISOString(), mode, dest, "", purpose);
        }
    }

    // QA self-test (WT_SMOOTHTEST=<seconds>): verifies playback SMOOTHNESS (video
    // frames keep arriving while the playhead advances — no frozen frame while the
    // timer ticks) and FRAME/TIMER SYNC (the displayed frame's PTS tracks the
    // playhead). Prints WTSMOOTH lines and quits after the window. A "freeze" =
    // playing + position advancing + no new presented frame.
    Item {
        id: probe
        property bool on: (typeof wtSmoothTest !== "undefined") && wtSmoothTest !== ""
        property int runSec: probe.on ? (parseInt(wtSmoothTest) || 45) : 0
        property int frames: 0
        property double lastFrameMs: -1     // presented frame PTS (ms), if exposed
        property int stalls: 0
        property double maxStallMs: 0
        property double maxDesyncMs: 0
        property double lastPos: -1
        property int lastFrames: 0
        property double freezeStart: -1
        Connections {
            target: vout.videoSink
            enabled: probe.on
            function onVideoFrameChanged(frame) {
                probe.frames++;
                if (frame !== undefined && frame !== null && frame.startTime !== undefined && frame.startTime >= 0)
                    probe.lastFrameMs = frame.startTime / 1000;
            }
        }
        Timer {                       // 100ms sampler: freeze + desync detection
            running: probe.on; interval: 100; repeat: true
            onTriggered: {
                if (player.playbackState !== MediaPlayer.PlayingState) {
                    probe.lastPos = player.position; probe.lastFrames = probe.frames; probe.freezeStart = -1; return;
                }
                var now = Date.now(), pos = player.position;
                var posAdv = probe.lastPos >= 0 && (pos - probe.lastPos) > 40;
                var frmAdv = probe.frames > probe.lastFrames;
                // ignore the initial open/preroll — only flag mid-playback freezes
                if (posAdv && !frmAdv && probe.frames > 8) {
                    if (probe.freezeStart < 0) probe.freezeStart = now;
                    probe.maxStallMs = Math.max(probe.maxStallMs, now - probe.freezeStart);
                } else if (frmAdv) {
                    if (probe.freezeStart >= 0 && (now - probe.freezeStart) > 400) {
                        probe.stalls++;
                        console.log("WTSMOOTH STALL " + Math.round(now - probe.freezeStart) + "ms near playhead=" + root.fmtClock(root.playheadMs));
                    }
                    probe.freezeStart = -1;
                }
                if (probe.lastFrameMs >= 0)
                    probe.maxDesyncMs = Math.max(probe.maxDesyncMs, Math.abs(pos - probe.lastFrameMs));
                probe.lastPos = pos; probe.lastFrames = probe.frames;
            }
        }
        Timer {                       // 1s heartbeat + final summary
            running: probe.on; interval: 1000; repeat: true
            property int sec: 0
            onTriggered: {
                sec++;
                console.log("WTSMOOTH t=" + sec + "s frames=" + probe.frames + " pos=" + player.position
                    + " playhead=" + root.fmtClock(root.playheadMs) + " status=" + player.mediaStatus + " state=" + player.playbackState);
                if (sec >= probe.runSec) {
                    console.log("WTSMOOTH SUMMARY stalls=" + probe.stalls + " maxStall=" + Math.round(probe.maxStallMs)
                        + "ms maxDesync=" + Math.round(probe.maxDesyncMs) + "ms frames=" + probe.frames + " over=" + sec + "s");
                    Qt.quit();
                }
            }
        }
    }
}
