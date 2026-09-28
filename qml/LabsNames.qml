pragma Singleton
import QtQuick

// The Labs analysers' names and colours: the Labs screen, its Statistics view, and the Playback
// timeline's Labs lane and observation card all read them HERE, so an analyser is called ONE
// thing everywhere. The names are the operator's (approved 2026-09-29, one set for Watchtower and
// cilex-vision, whose services/query-api/labs_names.py carries the same table -- their letter
// of that day); the short forms fit the lane's 120-px label block. Labels only: the slug is the
// key everywhere, and nothing branches on a name.
//
// `keys` is the lane's ROW ORDER and must equal wtlabs::laneKeys() in
// src/models/LabsTimelineData.h -- the painter draws row i from that list, and this file
// labels row i. tools/tests/labs-timeline.cpp compares the two.
QtObject {
    readonly property var keys: ["audio_energy", "blob_geometry", "camera_health", "colour_histogram",
                                 "foreground_mask", "frame_difference", "illumination", "optical_flow",
                                 "perceptual_hash", "track_linking"]

    // Distinct from the lanes above them: FOOTAGE is Theme.good (olive), MOTION Theme.accent
    // (amber). The row position names the analyser; colour only has to separate neighbours.
    readonly property var palette: ({
        "audio_energy":     "#b58ad6",
        "blob_geometry":    "#6f9bc4",
        "camera_health":    "#d96a5a",
        "colour_histogram": "#d77fb0",
        "foreground_mask":  "#4fb3a9",
        "frame_difference": "#c9a65a",
        "illumination":     "#d8cf72",
        "optical_flow":     "#62b6d9",
        "perceptual_hash":  "#9d978c",
        "track_linking":    "#8c86e0"
    })
    readonly property var colors: keys.map(function (k) { return palette[k]; })
    function color(k) { return palette[k] || "#9d978c"; }

    function title(k) {
        switch (k) {
        case "illumination":     return qsTr("Day / night");
        case "frame_difference": return qsTr("Motion intensity");
        case "camera_health":    return qsTr("Camera health");
        case "foreground_mask":  return qsTr("Objects in view");
        case "blob_geometry":    return qsTr("Object shapes");
        case "colour_histogram": return qsTr("Colour");
        case "optical_flow":     return qsTr("Direction of movement");
        case "track_linking":    return qsTr("Paths");
        // It finds a FROZEN feed (frames identical bit for bit); "Change detector" said the
        // opposite of what it finds (the operator's reason for the rename, 2026-09-29).
        case "perceptual_hash":  return qsTr("Frozen picture");
        case "audio_energy":     return qsTr("Sound");
        case "image_embedding":  return qsTr("Similar pictures");
        default:                 return k;
        }
    }

    function shortName(k) {
        switch (k) {
        case "illumination":     return qsTr("DAY / NIGHT", "labs lane label");
        case "frame_difference": return qsTr("INTENSITY", "labs lane label");
        case "camera_health":    return qsTr("HEALTH", "labs lane label");
        case "foreground_mask":  return qsTr("OBJECTS", "labs lane label");
        case "blob_geometry":    return qsTr("SHAPES", "labs lane label");
        case "colour_histogram": return qsTr("COLOUR", "labs lane label");
        case "optical_flow":     return qsTr("DIRECTION", "labs lane label");
        case "track_linking":    return qsTr("PATHS", "labs lane label");
        case "perceptual_hash":  return qsTr("FROZEN", "labs lane label");
        case "audio_energy":     return qsTr("SOUND", "labs lane label");
        case "image_embedding":  return qsTr("SIMILAR", "labs lane label");
        default:                 return k.toUpperCase();
        }
    }
}
