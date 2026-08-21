import QtQuick
import Watchtower

// A live camera thumbnail: a go2rtc still that refreshes every few seconds while it's
// on screen. Double-buffered — the refresh loads a hidden image and swaps to it on
// ready, so the tile never blanks during a reload (Qt 6.4 clears an Image while its
// source reloads). The swap is INSTANT, never a crossfade: two simultaneous 220 ms
// opacity fades can't sum to full coverage over the black base, so every refresh
// dipped the tile to ~75% brightness — at the 1 s poll that read as the whole wall
// "dimming on and off" at 1 Hz (measured ×0.78–0.82 luminance dips across phase-locked
// tile batches in the 2026-08-02 operator screenshots). A hard cut, like video, can't dim.
// cache:false keeps tiles from poisoning each other. Faint octet badge
// (e.g. ".101") + a live-status dot; click emits clicked().
//
// `cam` is a camera map (needs snapshotUrl, ip, live); `active` gates the refresh (pass
// the host view's visibility so off-screen / hidden tiles don't fetch).
Rectangle {
    id: thumb
    property var cam: null
    property bool active: true
    // Snapshot poll interval. Default = the server's SNAPSHOT_CACHE_TTL_S (10 s):
    // polling faster returns byte-identical cached JPEGs — measured 2026-08-17,
    // CV's TTL disclosure — so the old 1 s default paid 10× the bandwidth for
    // zero fresher pixels, and on the booth's starved WAN that waste was ~half
    // the link (their bandwidth correction letter). The 1 s era predates the
    // server cache; the "snappier" it bought has not existed since the cache
    // landed. If the operator wants fresher stills, CV tunes the TTL and this
    // default moves WITH it — the two must agree or one side is lying to the
    // other. Env-tunable via WT_THUMB_REFRESH_MS.
    property int refreshMs: (typeof wtThumbRefreshMs !== "undefined" && wtThumbRefreshMs > 0) ? wtThumbRefreshMs : 10000
    property bool showOctet: true
    // Decode snapshots at the tile's display size, NOT full camera resolution. A snapshot tile is only
    // ever shown at tile size, so full-res JPEG decode (QImage + GPU texture, ×2 for the imgA/imgB
    // no-blank refresh) was pure waste — measured ~224 MB across the wall (N=5, p<.001; on-screen the
    // wall drops 677→~450 MB). wtThumbScale (WT_THUMB_SCALE) forces a fixed width for A/B testing.
    readonly property size _srcSize: (typeof wtThumbScale !== "undefined" && wtThumbScale > 0)
        ? Qt.size(wtThumbScale, Math.round(wtThumbScale * 9 / 16))
        : Qt.size(Math.ceil(width), Math.ceil(height))
    property bool showStatus: true
    // A host that draws its own offline treatment (CameraTile's NO SIGNAL overlay
    // already prints "last seen …") sets this false so the marking is not doubled.
    property bool showStale: true
    signal clicked()

    color: "#0b0d10"; clip: true
    border.width: tMa.containsMouse ? 1.5 : 1
    border.color: tMa.containsMouse ? Theme.accent : Theme.line2

    readonly property string _base: (cam && cam.snapshotUrl) ? cam.snapshotUrl : ""
    // Cache-buster separator: the query-api snapshot URL has no '?' (the old go2rtc frame.jpeg?src=… did),
    // so appending "&_r=" to a '?'-less URL is malformed → 404. Use '?' when there's no query yet.
    readonly property string _sep: _base.indexOf("?") < 0 ? "?_r=" : "&_r="
    // Route the snapshot through the cvframe image PROVIDER (which attaches the auth cookie) rather than a raw
    // QML Image — the query-api cached snapshot endpoint requires auth, and a bare QML Image sends no cookie →
    // 401 "Host requires authentication" → blank tile. Strip scheme+host (the backend echoes our connect host,
    // so the provider's baseUrl + path resolves to the same URL).
    readonly property string _provBase: _base === "" ? "" : ("image://cvframe/" + _base.replace(/^[a-z]+:\/\/[^\/]+\//, ""))
    property int _tick: 0
    property bool _showA: true          // which buffer is on screen
    property bool _everLoaded: false
    // Error backoff (CW-15 endurance finding F3): a detail view whose siblings are
    // OFFLINE retried every refreshMs and each 404 logged a QQuickImage warning —
    // ~10 warn/s into the flight recorder (~4 MB/h of noise) for an EXPECTED
    // state. After 3 straight failures the poll drops to 15 s until one succeeds.
    property int _errStreak: 0
    // Graduated (2026-08-21, operator report: paired "QML QQuickImage: HTTP 404"
    // lines every few seconds): Qt logs ONE warning per failed attempt and that
    // cannot be suppressed from QML, so the only honest way to quiet a
    // permanently-404 camera is to ask less often. 3 fails → 15 s (the CW-15
    // value), 8 → 60 s, 12 → 5 min steady state. Self-heal paths: any success
    // resets the streak; a camera swap resets (_reset); and a LIVE-STATE CHANGE
    // resets (below) so a camera coming back is re-probed within one tick, not
    // in five minutes.
    readonly property int _effectiveMs: _errStreak >= 12 ? 300000
                                      : _errStreak >= 8  ? 60000
                                      : _errStreak >= 3  ? 15000 : refreshMs
    // One attributed line per streak — the raw Qt warning names the QML file but
    // not the camera, which made tonight's report undiagnosable from the log.
    function _noteError() {
        _errStreak++;
        if (_errStreak === 3)
            console.log("[THUMB] snapshot failing cam=" + (cam && cam.ip ? cam.ip : "?")
                        + " live=" + (cam ? cam.live : -1) + " — backoff 15s→60s→5min");
    }
    function _refresh() {
        if (_base === "") return;
        _tick++;
        var url = _provBase + _sep + _tick;
        if (_showA) imgB.source = url; else imgA.source = url;   // load the off-screen buffer
    }
    function _reset() {
        _everLoaded = false; _showA = true; _tick = 0; _errStreak = 0;
        imgA.source = ""; imgB.source = "";
        if (_base !== "") imgA.source = _provBase + _sep + "0";
    }
    // Reset ONLY when this thumb is pointed at a DIFFERENT camera — never on a
    // mere re-assignment of `cam`.
    //
    // `cam` arrives as an object LITERAL (CameraTile.qml: `cam: ({ snapshotUrl…,
    // lastSegmentAt: root.lastSegmentAt })`), so QML builds a brand-new object
    // whenever any field changes — and `last_segment_at` ticks forward on EVERY
    // /streams poll, i.e. every 15 s for every recording camera
    // (CameraModel.cpp:593). Binding to `onCamChanged` therefore fired _reset()
    // on a timer: both buffers cleared, `_everLoaded` false, the monitor glyph
    // back, and the tile BLACK until a fresh JPEG arrived 0.5–4.6 s later.
    //
    // Measured on the booth wall before this change: 25 of 36 tiles went dark
    // simultaneously and took ~6 s to recover, repeating with the poll. That is
    // the operator's "streams disappear and are replaced with black squares".
    //
    // Nothing about a new `last_segment_at` invalidates the picture on screen,
    // and the imgA/imgB pair above already refreshes without blanking — it loads
    // the off-screen buffer and swaps only on Ready. Keying the reset on the
    // snapshot URL restores that: a genuine camera swap (delegate recycling)
    // still clears, so one camera's still can never be shown under another's name.
    property string _loadedBase: ""
    property int _lastLive: -1
    function _ensureFor() {
        // A live-state transition is new information: a backed-off thumb re-probes
        // on the next tick instead of waiting out its 15s/60s/5min interval.
        var lv = (cam && cam.live !== undefined) ? cam.live : -1;
        if (lv !== _lastLive) {
            _lastLive = lv;
            if (_errStreak >= 3) _errStreak = 0;
        }
        if (_base === _loadedBase)
            return;                       // same camera — keep what is on screen
        _loadedBase = _base;
        _reset();
    }
    onCamChanged: _ensureFor()
    Component.onCompleted: _ensureFor()
    // Fire immediately on (re)activation — the repeat Timer's first tick is a full
    // interval away, which added a flat +1 s before a section switch even STARTED
    // filling its thumbs (measured in the 2026-08-02 [NAV]/[EVIMG] trace). Skip
    // thumbs in error-backoff: a camera mid 404-episode costs 2–6 s of server time
    // per ask, and re-poking all of them on every section entry occupied most of
    // the client gate's lanes — head-of-line for the healthy 90% (entries with 5
    // episode-cams measured p50 1.1–2.4 s vs 0.2–0.4 s without). Their own 15 s
    // backoff timer keeps retrying; they just don't ride the entry burst.
    onActiveChanged: if (active && _base !== "" && _errStreak < 3) _refresh()

    Image {
        id: imgA
        anchors.fill: parent; anchors.margins: 1
        fillMode: Image.PreserveAspectCrop; asynchronous: true; cache: false; sourceSize: thumb._srcSize
        opacity: thumb._showA ? 1 : 0
        onStatusChanged: {
            if (status === Image.Ready) { thumb._everLoaded = true; thumb._showA = true; thumb._errStreak = 0; }
            else if (status === Image.Error) thumb._noteError();
        }
    }
    Image {
        id: imgB
        anchors.fill: parent; anchors.margins: 1
        fillMode: Image.PreserveAspectCrop; asynchronous: true; cache: false; sourceSize: thumb._srcSize
        opacity: thumb._showA ? 0 : 1
        onStatusChanged: {
            if (status === Image.Ready) { thumb._everLoaded = true; thumb._showA = false; thumb._errStreak = 0; }
            else if (status === Image.Error) thumb._noteError();
        }
    }
    Icon {   // placeholder until the first frame loads (offline / loading)
        anchors.centerIn: parent; visible: !thumb._everLoaded
        name: (thumb.cam && thumb.cam.live === CameraStatus.Offline) ? "off" : "monitor"
        size: Math.min(20, parent.height * 0.22); color: Theme.ink3
    }
    Rectangle {   // live-status dot (top-right)
        visible: thumb.showStatus; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 4
        width: 8; height: 8; radius: 4
        color: (thumb.cam && thumb.cam.live === CameraStatus.Live) ? Theme.good
             : (thumb.cam && thumb.cam.live === CameraStatus.Offline) ? Theme.bad : Theme.accent
        border.width: 1; border.color: Qt.rgba(0, 0, 0, 0.4)
    }
    // ---- staleness -------------------------------------------------------------
    // From 2026-08-16 this endpoint answers an OFFLINE camera with its last recorded
    // frame and HTTP 200 (CV deploy; verified here — four offline cameras returned
    // 26–60 KB JPEGs at X-Snapshot-Age-S ≈ 129,700, i.e. ~36 h old, against an online
    // control at age 0). That is a real improvement over an eternal 404, but a 36-hour
    // photograph of a quiet corridor is indistinguishable from a live one, and a guard
    // must never be shown a dead camera's last good moment as if it were now. So the
    // age is drawn, always, whenever the picture is not current.
    //
    // The age comes from `lastSegmentAt` (CameraModel.cpp:399), because a QML Image
    // cannot read CV's X-Snapshot-Age-S header.
    //
    // The two are NOT the same quantity, and only converge when the camera is offline.
    // Measured 2026-08-16: an ONLINE camera returned age 0 (the endpoint served a live
    // frame) while its last_segment_at was ~2 min old — segments land in batches, so
    // segment time lags a live snapshot by up to a segment. Thresholding on segment age
    // therefore painted almost the whole Groups wall stale on the first build of this
    // change; the screenshot caught it. For an OFFLINE camera there is no live frame, so
    // the served picture IS the last segment and the two agree (measured: last segment
    // 2026-08-14T09:27:53 against a header age of 129,716 s).
    //
    // So: badge only when the endpoint is knowingly serving history — an offline camera.
    readonly property int _ageS: {
        thumb._tick;                                   // re-evaluate on each refresh
        if (!thumb.cam || !thumb.cam.lastSegmentAt) return -1;
        var t = Date.parse(thumb.cam.lastSegmentAt);
        return isNaN(t) ? -1 : Math.max(0, Math.round((Date.now() - t) / 1000));
    }
    readonly property bool _stale: _everLoaded
        && cam && cam.live === CameraStatus.Offline
    function _rel(s) {
        if (s < 90)     return qsTr("just now");
        if (s < 5400)   return qsTr("%1 min ago").arg(Math.round(s / 60));
        if (s < 172800) return qsTr("%1 h ago").arg(Math.round(s / 3600));
        return qsTr("%1 d ago").arg(Math.round(s / 86400));
    }
    // An unknown age on an offline camera is still not-current, and says so rather
    // than staying silent — absent data renders as unknown, never as healthy.
    readonly property string _ageText: _ageS >= 0 ? _rel(_ageS) : qsTr("not live")
    Rectangle {   // knock the stale frame back so it cannot read as a live picture
        visible: thumb._stale && thumb.showStale
        anchors.fill: parent; anchors.margins: 1
        color: Qt.rgba(0, 0, 0, 0.38)
    }
    Rectangle {   // "36 h ago" — never gated on showStatus; this one is not optional
        visible: thumb._stale && thumb.showStale && thumb.width >= 90 && thumb.height >= 44
        anchors { left: parent.left; top: parent.top; margins: 3 }
        width: ageT.implicitWidth + 8; height: ageT.implicitHeight + 3; radius: 2
        color: Qt.rgba(0, 0, 0, 0.58)
        Text {
            id: ageT; anchors.centerIn: parent; text: thumb._ageText
            color: Theme.warn; font.family: Theme.fontMono; font.pixelSize: 10
        }
    }
    Rectangle {   // too small for words (the 50×29 adjacent-frame plate) — still marked
        visible: thumb._stale && thumb.showStale && !(thumb.width >= 90 && thumb.height >= 44)
        anchors { left: parent.left; top: parent.top; margins: 3 }
        width: 5; height: 5; radius: 1; color: Theme.warn
    }
    Rectangle {   // faint octet badge (e.g. ".101")
        visible: thumb.showOctet && octT.text !== ""
        anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.margins: 3
        width: octT.implicitWidth + 8; height: octT.implicitHeight + 3; radius: 2
        color: Qt.rgba(0, 0, 0, 0.42)
        Text {
            id: octT; anchors.centerIn: parent
            text: { var p = ("" + (thumb.cam && thumb.cam.ip || "")).split("."); return p.length ? ("." + p[p.length - 1]) : ""; }
            color: Qt.rgba(1, 1, 1, 0.82); font.family: Theme.fontMono; font.pixelSize: 10
        }
    }
    // periodic live refresh — only while the host view is shown (interval backs
    // off to 15 s after 3 straight failures; recovers on the first success).
    //
    // `visible` is in the condition deliberately. Two call sites hide an offline
    // camera's thumbnail with `visible: !off` and one of them carries the comment
    // "offline is never requested" — which was FALSE: visibility never gated this
    // timer, only `active` did, so hidden thumbnails polled on regardless. That is
    // where the bulk of the 20,542 snapshot 404s came from (measured 2026-08-07→15).
    // It stopped being merely wasteful on 2026-08-16, when CV made the endpoint
    // serve an offline camera's last recorded frame: the same hidden pollers now
    // pull a 60 KB JPEG apiece instead of a tiny 404 body. Qt Quick's `visible` is
    // effective visibility (a child of a hidden parent reads false), so this also
    // parks thumbnails behind a closed modal or an unselected tab.
    Timer {
        interval: thumb._effectiveMs; repeat: true
        running: thumb.active && thumb.visible && thumb._base !== ""
        onTriggered: thumb._refresh()
    }
    MouseArea { id: tMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: thumb.clicked() }
}
