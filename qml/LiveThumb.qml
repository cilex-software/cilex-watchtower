import QtQuick
import Watchtower

// A live camera thumbnail: a go2rtc still that refreshes every few seconds while it's
// on screen. Double-buffered — the refresh loads a hidden image and crossfades to it on
// ready, so the tile never blanks during a reload (Qt 6.4 clears an Image while its
// source reloads). cache:false keeps tiles from poisoning each other. Faint octet badge
// (e.g. ".101") + a live-status dot; click emits clicked().
//
// `cam` is a camera map (needs snapshotUrl, ip, live); `active` gates the refresh (pass
// the host view's visibility so off-screen / hidden tiles don't fetch).
Rectangle {
    id: thumb
    property var cam: null
    property bool active: true
    // Snapshot poll interval for decode-capped tiles. Now that the backend serves snapshots from a cached,
    // concurrency-bounded query-api endpoint (no go2rtc producer wake), a fast poll is cheap — so default 1 s
    // (was 4 s, which read as a 2–3 s "lag" on capped cameras). Env-tunable via WT_THUMB_REFRESH_MS.
    property int refreshMs: (typeof wtThumbRefreshMs !== "undefined" && wtThumbRefreshMs > 0) ? wtThumbRefreshMs : 1000
    property bool showOctet: true
    // Decode snapshots at the tile's display size, NOT full camera resolution. A snapshot tile is only
    // ever shown at tile size, so full-res JPEG decode (QImage + GPU texture, ×2 for the imgA/imgB
    // no-blank refresh) was pure waste — measured ~224 MB across the wall (N=5, p<.001; on-screen the
    // wall drops 677→~450 MB). wtThumbScale (WT_THUMB_SCALE) forces a fixed width for A/B testing.
    readonly property size _srcSize: (typeof wtThumbScale !== "undefined" && wtThumbScale > 0)
        ? Qt.size(wtThumbScale, Math.round(wtThumbScale * 9 / 16))
        : Qt.size(Math.ceil(width), Math.ceil(height))
    property bool showStatus: true
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
    function _refresh() {
        if (_base === "") return;
        _tick++;
        var url = _provBase + _sep + _tick;
        if (_showA) imgB.source = url; else imgA.source = url;   // load the off-screen buffer
    }
    function _reset() {
        _everLoaded = false; _showA = true; _tick = 0;
        imgA.source = ""; imgB.source = "";
        if (_base !== "") imgA.source = _provBase + _sep + "0";
    }
    onCamChanged: _reset()
    Component.onCompleted: if (_base !== "") imgA.source = _provBase + _sep + "0"

    Image {
        id: imgA
        anchors.fill: parent; anchors.margins: 1
        fillMode: Image.PreserveAspectCrop; asynchronous: true; cache: false; sourceSize: thumb._srcSize
        opacity: thumb._showA ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 220 } }
        onStatusChanged: if (status === Image.Ready) { thumb._everLoaded = true; thumb._showA = true; }
    }
    Image {
        id: imgB
        anchors.fill: parent; anchors.margins: 1
        fillMode: Image.PreserveAspectCrop; asynchronous: true; cache: false; sourceSize: thumb._srcSize
        opacity: thumb._showA ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 220 } }
        onStatusChanged: if (status === Image.Ready) { thumb._everLoaded = true; thumb._showA = false; }
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
    // periodic live refresh — only while the host view is shown
    Timer { interval: thumb.refreshMs; repeat: true; running: thumb.active && thumb._base !== ""; onTriggered: thumb._refresh() }
    MouseArea { id: tMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: thumb.clicked() }
}
