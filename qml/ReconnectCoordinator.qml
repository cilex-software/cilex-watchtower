pragma Singleton
import QtQuick

// Global rate limiter for live-tile stream reconnects.
//
// Why this exists: a backend hiccup (e.g. go2rtc restarting) can stall many tiles at
// once. If each tile independently rebuilds its GStreamer/VA-API pipeline the instant it
// notices, the shared Intel iGPU gets a burst of simultaneous decode-context teardown +
// creation — the exact churn we suspect behind the Live-"Change layout" freeze. So every
// tile routes its reconnect attempt through here, and we release at most ONE initiation
// per `minIntervalMs`. A fleet-wide stall then recovers gradually (one pipeline at a time)
// instead of in a single damaging burst. Per-tile backoff lives in VideoSurface; this is
// purely the global serializer.
QtObject {
    id: coord

    // Minimum spacing between reconnect initiations across the whole app. 16 stalled
    // tiles → recovery spread over ~16 × this, one rebuild at a time.
    property int minIntervalMs: 700

    // EVIDENCE that go2rtc's RTSP port is reachable from this client: the wall-clock
    // time any surface last received a frame over an rtsp:// url. The source ladder
    // consults this before abandoning RTSP for the HTTP transport — on the site LAN a
    // transient error on one tile must recycle, not step down (measured 2026-09-11:
    // LAN tiles pushed to SD·NET by one-off errors while their neighbours played on
    // RTSP). Decays: silence for 60 s means "unknown", so a laptop that roams off
    // the VPN mid-session can still fall back.
    property double rtspLastFrameMs: -1
    // REMOTE MODE: some surface had to abandon RTSP for the HTTP (HLS) transport.
    // CV's live proxy tops out at ~130 req/s and is comfortable to ~50 (their
    // measurement 2026-09-11), so a remote wall is held to httpLiveBudget live tiles
    // and the rest show snapshots. Cleared by rtsp frames.
    //
    // 16, not the original 10. That 10 came from CV's estimate of 5.4 req/s per
    // tile; measured end to end on this Mac 2026-09-18 the real cost is 3.0 req/s
    // (one tile, 70 s, counted at our own proxy — AVFoundation fetches each segment
    // once, so the duplicate fetches that number assumed do not happen). 16 tiles is
    // therefore ~48 req/s — still inside the ~50 CV sized for, and it lights a full
    // 4x4 page instead of leaving six tiles on snapshots.
    property bool remoteMode: false
    readonly property int httpLiveBudget: 16
    function noteTransportFallback() { remoteMode = true; }
    // Authoritative "do not bother with rtsp on this network": either a surface
    // already had to fall back, or the startup TCP probe says the port is dead.
    function rtspKnownUnreachable() {
        if (remoteMode) return true;
        return (typeof LiveHttp !== "undefined") && LiveHttp.rtspProbe === 0;
    }
    function noteRtspFrame() {
        var now = Date.now();
        if (now - rtspLastFrameMs > 2000) rtspLastFrameMs = now;   // throttled write
        if (remoteMode) remoteMode = false;
    }
    function rtspReachable() { return rtspLastFrameMs > 0 && (Date.now() - rtspLastFrameMs) < 60000; }

    property var _queue: []                 // FIFO of pending reconnect callbacks
    property double _lastReleaseMs: -1.0e12 // far in the past → first request fires at once

    // Ask for a reconnect slot. `fn` is invoked exactly once, when a global slot frees up.
    // Callbacks must self-guard (re-check they still need to reconnect) since they may run
    // a moment later, by which point the tile may have recovered or gone inactive.
    function request(fn) {
        if (!fn)
            return;
        _queue.push(fn);
        _drain();
    }

    function _drain() {
        if (_queue.length === 0)
            return;
        var elapsed = Date.now() - _lastReleaseMs;
        if (elapsed >= minIntervalMs) {
            _lastReleaseMs = Date.now();
            var fn = _queue.shift();
            if (fn)
                fn();
            if (_queue.length > 0) {        // more waiting → schedule the next release
                _gap.interval = minIntervalMs;
                _gap.restart();
            }
        } else {                            // too soon → wait out the remaining gap
            _gap.interval = Math.max(1, minIntervalMs - elapsed);
            _gap.restart();
        }
    }

    property Timer _gap: Timer {
        repeat: false
        onTriggered: coord._drain()
    }
}
