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
