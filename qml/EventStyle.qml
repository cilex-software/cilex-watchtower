pragma Singleton
import QtQuick

// Single source of truth for camera-event styling — color / icon / label — used by
// the events feed, alerts dropdown, ops sidebar, command palette, and the playback
// scrubber's event markers. (Previously each of those redefined a partial copy.)
//
// Color is a 3-tier severity/category scheme over the Theme tokens:
//   amber  (accent) = motion              red (bad) = security-critical
//   violet         = other analytics
QtObject {
    // The two motion-lifecycle types the playback scrubber renders as start→end SPANS
    // (everything else is a point event / tick).
    function isMotionSpan(t) { return t === "motion_started" || t === "motion_ended"; }

    function isCritical(t) {
        switch (t) {
        case "loitering": case "intrusion": case "tamper": case "video_loss": return true;
        default: return false;
        }
    }

    function color(t) {
        if (isCritical(t)) return Theme.bad;                 // red — security / critical
        switch (t) {
        case "motion": case "motion_started": case "motion_ended": case "motion_detected":
            return Theme.accent;                             // amber — motion
        default:
            return Theme.violet;                            // violet — other analytics
        }
    }

    function icon(t) {
        switch (t) {
        case "loitering": case "stopped": case "intrusion": case "tamper": case "video_loss":
            return "alert";
        default:
            return "motion";
        }
    }

    function label(t) {
        switch (t) {
        case "motion":          return qsTr("Motion");
        case "motion_started":  return qsTr("Motion started");
        case "motion_ended":    return qsTr("Motion ended");
        case "motion_detected": return qsTr("Motion detected");
        case "entered_scene":   return qsTr("Entered scene");
        case "exited_scene":    return qsTr("Exited scene");
        case "stopped":         return qsTr("Stopped");
        case "loitering":       return qsTr("Loitering");
        case "line_crossing":   return qsTr("Line crossing");
        case "intrusion":       return qsTr("Intrusion");
        case "region_entrance": return qsTr("Region entrance");
        case "region_exiting":  return qsTr("Region exiting");
        case "tamper":          return qsTr("Tamper");
        case "scene_change":    return qsTr("Scene change");
        case "video_loss":      return qsTr("Video loss");
        case "face_detected":   return qsTr("Face detected");
        case "defocus":         return qsTr("Defocus");
        case "pir":             return qsTr("PIR");
        case "camera_event":    return qsTr("Camera event");
        default:
            var s = ("" + t).replace(/_/g, " ");
            return s.length ? s.charAt(0).toUpperCase() + s.slice(1) : "Event";
        }
    }
}
