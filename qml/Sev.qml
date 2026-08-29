import QtQuick
import Watchtower

// events-v2 .sev — severity tag: a 3×12 colored bar + uppercase mono label.
// critical=bad · high=accent · medium=ink-2 · low=ink-3.
Row {
    id: r
    property string level: "low"
    spacing: 6
    Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: 3; height: 12; color: Theme.sevColor(r.level)
    }
    // The level is a PROTOCOL value ("low"/"high"), not display copy. Uppercasing it
    // printed LOW / HIGH / CRITICAL into a Russian UI with no way to translate them —
    // reported from the booth 2026-08-21. Map to real strings instead; the default arm
    // keeps an unknown level visible rather than blank.
    readonly property string _label: {
        switch (r.level) {
        case "critical": return qsTr("CRITICAL");
        case "high":     return qsTr("HIGH");
        case "medium":   return qsTr("MEDIUM");
        case "low":      return qsTr("LOW");
        default:         return r.level.toUpperCase();
        }
    }
    Text {
        anchors.verticalCenter: parent.verticalCenter
        text: r._label; color: Theme.sevColor(r.level)
        font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.DemiBold; font.letterSpacing: 0.8
    }
}
