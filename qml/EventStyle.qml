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
        case "motion":          return "Motion";
        case "motion_started":  return "Motion started";
        case "motion_ended":    return "Motion ended";
        case "motion_detected": return "Motion detected";
        case "entered_scene":   return "Entered scene";
        case "exited_scene":    return "Exited scene";
        case "stopped":         return "Stopped";
        case "loitering":       return "Loitering";
        case "line_crossing":   return "Line crossing";
        case "intrusion":       return "Intrusion";
        case "region_entrance": return "Region entrance";
        case "region_exiting":  return "Region exiting";
        case "tamper":          return "Tamper";
        case "scene_change":    return "Scene change";
        case "video_loss":      return "Video loss";
        case "face_detected":   return "Face detected";
        case "defocus":         return "Defocus";
        case "pir":             return "PIR";
        case "camera_event":    return "Camera event";
        default:
            var s = ("" + t).replace(/_/g, " ");
            return s.length ? s.charAt(0).toUpperCase() + s.slice(1) : "Event";
        }
    }
}
