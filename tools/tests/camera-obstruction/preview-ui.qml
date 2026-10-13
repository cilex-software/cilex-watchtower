// The shipping application and incident widgets, connected only to the local fixture.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Watchtower
import "qrc:/qt/qml/Watchtower/qml" as Product

Product.Main {
    id: preview
    width: 1280
    height: 960
    title: "Watchtower — obstruction UI SIMULATION"
    property string previewStatus: "Open the alarm camera, then try the real review buttons."
    property bool scenarioBusy: false

    function scenario(name) {
        scenarioBusy = true;
        var request = new XMLHttpRequest();
        request.open("POST", AuthController.baseUrl + "/fixture/preview/" + name);
        request.setRequestHeader("Content-Type", "application/json");
        request.onreadystatechange = function() {
            if (request.readyState !== XMLHttpRequest.DONE) return;
            preview.scenarioBusy = false;
            if (request.status !== 200) {
                preview.previewStatus = "Local simulation request failed: " + request.status;
                return;
            }
            if (name === "alarm" || name === "reset") {
                preview.focusedCamera = null;
                preview.playbackCamera = null;
                preview.activeTab = 0;
                preview.mainTabCamera = null;
                preview.tabs = [{kind: "main"}];
            }
            preview.previewStatus = name === "eligible"
                ? "Two earlier false alarms are simulated. Classify this alarm as false to reveal the seven-day button."
                : name === "recover" ? "Recovery simulated; the review strip shows restored visibility."
                : name === "reset" ? "Simulation cleared. Use Trigger alarm to start again."
                : "New simulated alarm. Open the camera to review it.";
            CameraObstruction.refresh();
        };
        request.send("{}");
    }

    Rectangle {
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        z: 1600
        color: "#152c39"
        border.color: "#6acbff"
        implicitHeight: controls.implicitHeight + 24
        ColumnLayout {
            id: controls
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
            spacing: 5
            Label {
                Layout.fillWidth: true
                text: "SIMULATION — local UI preview · fake cameras · no live video, reports or alarm changes"
                color: "#ffffff"
                font.bold: true
                wrapMode: Text.WordWrap
            }
            Label {
                Layout.fillWidth: true
                text: preview.previewStatus
                color: "#c6eaff"
                wrapMode: Text.WordWrap
            }
            Flow {
                Layout.fillWidth: true
                spacing: 8
                enabled: AuthController.authenticated && CameraObstruction.available && !preview.scenarioBusy
                Button { objectName: "previewTriggerAlarm"; text: "Trigger alarm"; onClicked: preview.scenario("alarm") }
                Button { objectName: "previewRepeatedFalseAlarms"; text: "Repeated false alarms"; onClicked: preview.scenario("eligible") }
                Button { objectName: "previewRecovery"; text: "Restore visibility"; onClicked: preview.scenario("recover") }
                Button { objectName: "previewReset"; text: "Reset"; onClicked: preview.scenario("reset") }
                Button { objectName: "previewClose"; text: "Close preview"; onClicked: preview.close() }
            }
        }
    }
}
