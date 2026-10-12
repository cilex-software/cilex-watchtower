import QtQuick
import QtQuick.Controls
import QtTest
import Watchtower

Item {
    id: screen
    width: 1100
    height: 700
    QtObject {
        id: fixture
        property var pendingIncident: ({})
        property var reviewIncident: ({})
        property bool actionBusy: false
        property bool canManage: true
        property string errorString: ""
        property var lastAction: []
        function act(id, action) { lastAction = [id, action]; }
    }
    CameraObstructionAlert {
        id: alarm
        anchors.fill: parent
        controller: fixture
        onOpenCamera: (cameraId, incidentId) => {
            test.openedCamera = cameraId;
            test.openedIncident = incidentId;
            fixture.reviewIncident = fixture.pendingIncident;
            fixture.pendingIncident = {};
        }
    }
    CameraObstructionReview {
        id: review
        anchors { left: parent.left; right: parent.right; top: parent.top }
        controller: fixture
    }
    TestCase {
        id: test
        name: "CameraObstructionUi"
        when: windowShown
        property string openedCamera: ""
        property string openedIncident: ""
        function incident() {
            return {incident_id:"incident-109",camera_id:"camera-109",camera_name:"4.1.6 · 192.168.1.109",
                    state:"active",disposition:"pending",alert_pending:true,suppressed:false,can_disable_7d:false};
        }
        function init() {
            fixture.pendingIncident = {};
            fixture.reviewIncident = {};
            fixture.actionBusy = false;
            fixture.canManage = true;
            fixture.errorString = "";
            fixture.lastAction = [];
            openedCamera = "";
            openedIncident = "";
        }
        function test_openAndClassify() {
            fixture.pendingIncident = incident();
            wait(100);
            verify(alarm.visible);
            verify(!review.visible);
            grabImage(screen).save("/tmp/camera-obstruction-alert-test.png");
            mouseClick(findChild(alarm, "cameraObstructionOpenLive"));
            compare(openedCamera, "camera-109");
            compare(openedIncident, "incident-109");
            verify(!alarm.visible);
            verify(review.visible);
            var falseButton = findChild(review, "cameraObstructionFalseAlarm");
            verify(falseButton.visible);
            verify(!findChild(review, "cameraObstructionDisable7d").visible);
            mouseClick(falseButton);
            compare(fixture.lastAction, ["incident-109", "false_alarm"]);
            verify(falseButton.visible); // No optimistic classification before server acceptance.
            grabImage(screen).save("/tmp/camera-obstruction-review-test.png");
            var response = incident();
            response.disposition = "false_alarm";
            response.alert_pending = false;
            response.suppressed = true;
            response.suppressed_until = "2026-10-13T06:00:00Z";
            response.can_disable_7d = true;
            response.report_status = "queued";
            response.evidence_status = "pending";
            fixture.reviewIncident = response;
            wait(20);
            verify(!falseButton.visible);
            var disable = findChild(review, "cameraObstructionDisable7d");
            verify(disable.visible);
            mouseClick(disable);
            var dialog = findChild(review, "cameraObstructionDisableConfirmation");
            tryCompare(dialog, "visible", true);
            dialog.accept();
            compare(fixture.lastAction, ["incident-109", "disable_7d"]);
        }
        function test_confirmAndViewer() {
            fixture.reviewIncident = incident();
            var confirm = findChild(review, "cameraObstructionConfirm");
            wait(20);
            verify(confirm.visible);
            mouseClick(confirm);
            compare(fixture.lastAction, ["incident-109", "confirm"]);
            fixture.actionBusy = true;
            verify(!confirm.enabled);
            fixture.actionBusy = false;
            fixture.canManage = false;
            verify(!confirm.enabled);
            verify(!findChild(review, "cameraObstructionFalseAlarm").enabled);
            verify(!findChild(review, "cameraObstructionDisable7d").visible);
        }
        function test_recoveredUnreviewedAndSevenDayGate() {
            var recovered = incident();
            recovered.state = "recovered";
            recovered.alert_pending = false;
            recovered.can_disable_7d = true;
            fixture.reviewIncident = recovered;
            wait(20);
            verify(findChild(review, "cameraObstructionFalseAlarm").visible);
            verify(findChild(review, "cameraObstructionConfirm").visible);
            // A streak from previous incidents does not classify this one.
            verify(!findChild(review, "cameraObstructionDisable7d").visible);
        }
    }
}
