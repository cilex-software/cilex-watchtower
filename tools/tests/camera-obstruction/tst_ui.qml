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
            screen.width = 1100;
            screen.height = 700;
            fixture.pendingIncident = {};
            fixture.reviewIncident = {};
            fixture.actionBusy = false;
            fixture.canManage = true;
            fixture.errorString = "";
            fixture.lastAction = [];
            openedCamera = "";
            openedIncident = "";
        }
        function cleanup() {
            var dialog = findChild(review, "cameraObstructionDisableConfirmation");
            if (dialog.visible) dialog.close();
        }
        function boundsIn(item, container) {
            var pos = item.mapToItem(container, 0, 0);
            return {x: pos.x, y: pos.y, width: item.width, height: item.height};
        }
        function verifyContained(item, container) {
            verify(item.visible, item.objectName + " is visible");
            var bounds = boundsIn(item, container);
            verify(bounds.width > 0 && bounds.height > 0, item.objectName + " has a hit area");
            verify(bounds.x >= -1 && bounds.y >= -1 &&
                   bounds.x + bounds.width <= container.width + 1 &&
                   bounds.y + bounds.height <= container.height + 1,
                   item.objectName + " is inside its container: " + JSON.stringify(bounds));
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
        function test_responsiveActions_data() {
            return [{tag: "wide", width: 1100}, {tag: "narrow", width: 420}];
        }
        function test_responsiveActions(data) {
            screen.width = data.width;
            fixture.pendingIncident = incident();
            wait(100);
            verifyContained(findChild(alarm, "cameraObstructionOpenLive"), screen);
            fixture.pendingIncident = {};
            fixture.reviewIncident = incident();
            wait(100);
            var falseButton = findChild(review, "cameraObstructionFalseAlarm");
            var confirm = findChild(review, "cameraObstructionConfirm");
            verifyContained(falseButton, review);
            verifyContained(confirm, review);
            var a = boundsIn(falseButton, review), b = boundsIn(confirm, review);
            verify(a.x + a.width <= b.x || b.x + b.width <= a.x ||
                   a.y + a.height <= b.y || b.y + b.height <= a.y,
                   "Classification buttons do not overlap");
            var response = incident();
            response.disposition = "false_alarm";
            response.suppressed = true;
            response.can_disable_7d = true;
            fixture.reviewIncident = response;
            wait(100);
            verifyContained(findChild(review, "cameraObstructionDisable7d"), review);
        }
        function test_keyboardActivationAndGuards() {
            fixture.pendingIncident = incident();
            wait(100);
            var open = findChild(alarm, "cameraObstructionOpenLive");
            open.forceActiveFocus(Qt.TabFocusReason);
            verify(open.activeFocus);
            keyClick(Qt.Key_Space);
            compare(openedCamera, "camera-109");
            compare(openedIncident, "incident-109");
            var falseButton = findChild(review, "cameraObstructionFalseAlarm");
            verify(falseButton.visible);
            falseButton.forceActiveFocus(Qt.TabFocusReason);
            verify(falseButton.activeFocus);
            keyClick(Qt.Key_Space);
            compare(fixture.lastAction, ["incident-109", "false_alarm"]);
            fixture.lastAction = [];
            fixture.actionBusy = true;
            verify(!falseButton.enabled);
            keyClick(Qt.Key_Space);
            compare(fixture.lastAction, []);
            fixture.actionBusy = false;
            fixture.canManage = false;
            verify(!falseButton.enabled);
            verify(!findChild(review, "cameraObstructionConfirm").enabled);
            keyClick(Qt.Key_Space);
            compare(fixture.lastAction, []);
        }
        function test_disableDialogKeyboardAndPermissionChange() {
            var response = incident();
            response.disposition = "false_alarm";
            response.can_disable_7d = true;
            fixture.reviewIncident = response;
            wait(100);
            var trigger = findChild(review, "cameraObstructionDisable7d");
            var dialog = findChild(review, "cameraObstructionDisableConfirmation");
            mouseClick(trigger);
            tryCompare(dialog, "visible", true);
            var cancel = findChild(review, "cameraObstructionDisableCancel");
            tryCompare(cancel, "activeFocus", true);
            keyClick(Qt.Key_Escape);
            tryCompare(dialog, "visible", false);
            compare(fixture.lastAction, []);
            mouseClick(trigger);
            tryCompare(dialog, "visible", true);
            var accept = findChild(review, "cameraObstructionDisableAccept");
            fixture.canManage = false;
            verify(!accept.enabled);
            keyClick(Qt.Key_Return);
            compare(fixture.lastAction, []);
            // Reopen after the focused Cancel consumed Return. The enabled
            // confirmation requires an explicit focus change and activation.
            fixture.canManage = true;
            if (!dialog.visible) mouseClick(trigger);
            tryCompare(dialog, "visible", true);
            accept.forceActiveFocus(Qt.TabFocusReason);
            keyClick(Qt.Key_Return);
            compare(fixture.lastAction, ["incident-109", "disable_7d"]);
        }
    }
}
