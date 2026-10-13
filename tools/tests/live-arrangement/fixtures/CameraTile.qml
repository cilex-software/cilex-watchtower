import QtQuick
import Watchtower

// No media, timers, image providers, network or settings. All arrangement,
// selection and delegate reconciliation around this tile are shipping QML.
Rectangle {
    objectName: "fixtureCamera_" + camId
    color: Theme.tileBg
    property bool gridMode: false
    property var eventsModel: null
    property var camModel: null
    property bool liveViewEnabled: true
    property bool recordingEnabled: true
    property string camName: ""
    property string camId: ""
    property string ip: ""
    property string hwModel: ""
    property string groupId: ""
    property string groupName: ""
    property int live: 0
    property int recording: 0
    property bool favorite: false
    property bool hasAudio: false
    property bool audioRecording: false
    property string timestamp: ""
    property string lastSeen: ""
    property string lastSegmentAt: ""
    property bool motionKnown: false
    property bool motionReady: false
    property string motionLastVmdAt: ""
    property int pattern: 0
    property string rtspUrl: ""
    property string rtspSubUrl: ""
    property string hlsSubUrl: ""
    property string hlsOptUrl: ""
    property bool videoActive: false
    property bool tapToOpen: true
    property bool liveDecodeAllowed: true
    property string snapshotUrl: ""
    property bool useMainStream: false
    property bool spanned: false
    signal hdToggleRequested()
    signal snapshotSaved(string path, string camName)
    signal opened()
    signal played()
    signal issueRequested()
    signal openedNewTab()
    signal splitRequested()
    signal favoriteToggled()
    Text {
        anchors { top: parent.top; left: parent.left; margins: 7 }
        text: camName + "\n" + ip
        color: Theme.ink3
        font.pixelSize: 10
        font.family: Theme.fontMono
    }
}
