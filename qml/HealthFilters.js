.pragma library
.import "GroupsStatus.js" as States

// Stable inclusion keys, never translated badge text or its changing age suffix.
var columns = ["camera", "group", "live", "rec", "issue"];
var liveOrder = ["OFFLINE", "NO SIGNAL", "DEGRADED", "LOADING", "NO ACCESS", "UNKNOWN", "LIVE"];
var recOrder = ["REC STOPPED", "ARMED · NOT READY", "ARCHIVE DELAY", "ARMED · ARCHIVE DELAY",
                "REC ?", "ARMED · no motion", "ARMED", "REC", "OFF"];
var issueOrder = ["No signal", "Recording stopped", "Motion detector not ready", "Archive delayed",
                  "Archive unavailable", "Status unknown", "Stream degraded", "—"];

function cameraKey(cam) { return String(cam.camId); }
function groupKey(cam) { return String(cam.groupName || ""); }
function liveKey(cam) {
    switch (cam.live) {
    case States.LIVE.Offline: return "OFFLINE";
    case States.LIVE.NoSignal: return "NO SIGNAL";
    case States.LIVE.Degraded: return "DEGRADED";
    case States.LIVE.Loading: return "LOADING";
    case States.LIVE.PermissionDenied: return "NO ACCESS";
    case States.LIVE.Live: return "LIVE";
    default: return "UNKNOWN";
    }
}

function recCategory(cam, health, now) {
    health = health || ({});
    now = now === undefined ? Date.now() : now;
    var state = cam.recording, capture = health.capture_state || "unknown";
    var fresh = health.version === 1 && health.fresh === true;
    var archive = health.archive_state || (state === States.REC.Stalled || state === States.REC.NotRecording
                   || state === States.REC.Gap ? "delayed" : "unknown");
    // Keep RecordingStatusBadge.label's precedence, including legacy states.
    if (capture === "disabled" || (!fresh && state === States.REC.Disabled)) return "OFF";
    if (capture === "stopped") return "REC STOPPED";
    if (archive === "delayed" || archive === "unavailable") return "ARCHIVE DELAY";
    if (capture === "progressing") return "REC";
    if (fresh) {
        if (capture !== "idle") return "REC ?";
    } else {
        if (state === States.REC.Stalled || state === States.REC.Gap) return "ARCHIVE DELAY";
        if (state !== States.REC.Armed) return "REC ?";
    }
    if (cam.motionKnown === true && cam.motionReady !== true) return "ARMED · NOT READY";
    var vmd = cam.motionLastVmdAt ? Date.parse(cam.motionLastVmdAt) : -1;
    var segment = cam.lastSegmentAt ? Date.parse(cam.lastSegmentAt) : -1;
    if (!fresh && vmd > 0 && (now - vmd) / 1000 < 10800 && (segment <= 0 || vmd - segment > 3600000))
        return "ARMED · ARCHIVE DELAY";
    // The table does not supply lastMotionAtMs today; support it for badge parity.
    if (cam.lastMotionAtMs > 0) return "ARMED";
    var segmentAge = segment > 0 ? Math.max(0, (now - segment) / 1000) : -1;
    if (segmentAge < 0 || segmentAge > 86400) return "ARMED · no motion";
    return "ARMED";
}

function issueKey(cam, health) {
    health = health || ({});
    if (cam.live === States.LIVE.Offline || cam.live === States.LIVE.NoSignal) return "No signal";
    if (health.capture_state === "stopped") return "Recording stopped";
    if (health.archive_state === "delayed") return "Archive delayed";
    if (health.archive_state === "unavailable") return "Archive unavailable";
    if (cam.recording === States.REC.Armed && cam.motionKnown && !cam.motionReady) return "Motion detector not ready";
    if (cam.live === States.LIVE.Degraded) return "Stream degraded";
    return health.capture_state === "unknown" || health.archive_state === "unknown" ? "Status unknown" : "—";
}

function keys(cam, health, now) {
    return {camera: cameraKey(cam), group: groupKey(cam), live: liveKey(cam),
            rec: recCategory(cam, health, now), issue: issueKey(cam, health)};
}
function passes(keys, filters, except) {
    for (var i = 0; i < columns.length; ++i) {
        var col = columns[i], included = filters[col];
        if (col !== except && included !== null && included.indexOf(keys[col]) < 0) return false;
    }
    return true;
}
