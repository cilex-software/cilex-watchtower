// Shipping Main, AuthController, roster, navigation and obstruction controller.
// All network traffic uses the loopback fixture; no real alarms are classified.
import QtQuick
import Watchtower
import "qrc:/qt/qml/Watchtower/qml" as Product

Product.Main {
    id: test
    width: 1280; height: 900
    property int phase: 0
    property int checks: 0
    property int failures: 0
    property bool capturing: false
    property string output: ""
    property var alert: null
    property var review: null
    property var wall: null
    property var detail: null
    function find(root, name) {
        var seen = [], result = null;
        function visit(node) {
            if (!node || result || seen.indexOf(node) >= 0) return;
            seen.push(node);
            if (node.objectName === name || String(node).indexOf(name + "_QML") === 0) { result = node; return; }
            var lists = [node.children || [], node.data || []];
            for (var n = 0; n < lists.length; ++n)
                for (var i = 0; i < lists[n].length; ++i) visit(lists[n][i]);
        }
        visit(root);
        return result;
    }
    function check(ok, description, value) {
        ++checks;
        if (!ok) ++failures;
        console.log("[OBSTRUCTION-UI-CHECK] " + JSON.stringify({ok:!!ok,check:description,value:value || null}));
        return !!ok;
    }
    function capture(name, next) {
        capturing = true;
        contentItem.grabToImage(function(image) {
            check(image.saveToFile(output + "/" + name + ".png"), "save " + name);
            capturing = false;
            phase = next;
        });
    }
    function advanceFixture() {
        var request = new XMLHttpRequest();
        request.open("POST", AuthController.baseUrl + "/fixture/next");
        request.send("{}");
    }
    function finish() {
        pulse.stop();
        console.log("[OBSTRUCTION-UI-SUMMARY] " + JSON.stringify({checks:checks,failures:failures,
            production_shell:true,production_navigation:true,production_controller:true,
            authenticated_loopback_fixture:true,real_camera_pixels:false,real_incident_mutations:false}));
        Qt.exit(failures ? 1 : 0);
    }
    Timer {
        id: pulse
        interval: 150; repeat: true; running: true
        onTriggered: {
            if (test.capturing) return;
            try {
                if (test.phase === 0) {
                    if (!AuthController.authenticated || !CameraObstruction.available) return;
                    test.alert = test.find(test.contentItem, "CameraObstructionAlert");
                    test.review = test.find(test.contentItem, "CameraObstructionReview");
                    test.wall = test.find(test.contentItem, "LiveMonitor");
                    test.detail = test.find(test.contentItem, "SingleCameraDetail");
                    if (!test.wall || !test.wall.cameraModel.cameraByBackendId("fixture-camera-a").camId) return;
                    var args = Qt.application.arguments;
                    for (var i = 0; i < args.length; ++i)
                        if (args[i].indexOf("--obstruction-output=") === 0) test.output = args[i].slice(21);
                    if (!test.check(test.alert && test.review && test.detail && test.output.length > 0, "shipping components and output available")) { test.finish(); return; }
                    test.check(test.alert.visible && !test.review.visible, "central initial alarm visible");
                    test.check(CameraObstruction.pendingIncident.camera_id === "fixture-camera-a", "initial alarm camera A");
                    test.capture("01-central-alert", 1);
                } else if (test.phase === 1) {
                    test.find(test.alert, "cameraObstructionOpenLive").clicked();
                    test.phase = 2;
                } else if (test.phase === 2) {
                    if (CameraObstruction.currentCameraId !== "fixture-camera-a") return;
                    test.check(test.focusedCamera.camId === "fixture-camera-a" && test.activeTabLabel() === "Fixture Hall A", "button opens correct camera A tab", test.activeTabLabel());
                    test.check(test.detail.camera.camId === "fixture-camera-a" && test.detail.visible, "live surface receives camera A identity");
                    test.check(!test.alert.visible && test.review.visible, "central alarm yields to review strip");
                    test.capture("02-camera-a-review", 3);
                } else if (test.phase === 3) {
                    test.find(test.review, "cameraObstructionFalseAlarm").clicked();
                    test.phase = 4;
                } else if (test.phase === 4) {
                    if (CameraObstruction.reviewIncident.disposition !== "false_alarm") return;
                    test.check(CameraObstruction.reviewIncident.suppressed === true && !test.alert.visible, "server false-alarm action suppresses popup");
                    test.capture("03-snoozed-report-queued", 5);
                } else if (test.phase === 5) {
                    test.advanceFixture();
                    test.phase = 6;
                } else if (test.phase === 6) {
                    if (CameraObstruction.pendingIncident.camera_id !== "fixture-camera-b") return;
                    test.check(test.alert.visible, "second camera alarm appears independently");
                    test.find(test.alert, "cameraObstructionOpenLive").clicked();
                    test.phase = 7;
                } else if (test.phase === 7) {
                    if (CameraObstruction.currentCameraId !== "fixture-camera-b") return;
                    test.check(test.focusedCamera.camId === "fixture-camera-b" && test.activeTabLabel() === "Fixture Hall B", "second alarm opens B not stale A", test.activeTabLabel());
                    test.check(CameraObstruction.reviewIncident.camera_id === "fixture-camera-b" && test.detail.camera.camId === "fixture-camera-b", "review and live surface agree on B");
                    test.find(test.review, "cameraObstructionConfirm").clicked();
                    test.phase = 8;
                } else if (test.phase === 8) {
                    if (CameraObstruction.reviewIncident.disposition !== "confirmed") return;
                    test.check(!test.alert.visible && test.focusedCamera.camId === "fixture-camera-b", "confirmed incident remains in live view without popup");
                    test.capture("04-camera-b-confirmed", 9);
                } else if (test.phase === 9) {
                    AuthController.logout();
                    test.check(CameraObstruction.incidents.length === 0 && !test.alert.visible && !test.review.visible, "logout clears alarm and review");
                    test.finish();
                }
            } catch (error) {
                test.check(false, "unexpected integration exception", String(error));
                test.finish();
            }
        }
    }
    Timer { interval: 30000; running: true; onTriggered: { test.check(false, "integration timed out", test.phase); test.finish(); } }
}
