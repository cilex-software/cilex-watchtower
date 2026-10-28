import QtQuick
import Watchtower

Window {
    id: test
    visible: false
    property int phase: 0
    property int checks: 0
    property int failures: 0
    property bool busy: false
    CameraModel { id: cameras }
    function check(ok, description) {
        ++checks;
        if (!ok) ++failures;
        console.log("[AVAILABILITY-MODEL-CHECK] " + JSON.stringify({ok: !!ok, check: description}));
    }
    function server(name, next) {
        busy = true;
        var request = new XMLHttpRequest();
        request.open("POST", AuthController.baseUrl + "/fixture/" + name);
        request.onreadystatechange = function() {
            if (request.readyState !== XMLHttpRequest.DONE) return;
            test.check(request.status === 200, "fixture control accepted: " + name);
            test.phase = next;
            cameras.refresh();
            test.busy = false;
        };
        request.send("{}");
    }
    Timer {
        interval: 100; repeat: true; running: true
        onTriggered: {
            if (test.busy || cameras.loading || !AuthController.authenticated) return;
            if (test.phase === 0 && cameras.total === 133 && cameras.backendEvidenceFresh) {
                test.check(cameras.offlineCount === 0, "133 initial online reports are fresh");
                test.server("unavailable", 1);
            } else if (test.phase >= 1 && test.phase <= 3 && !cameras.backendEvidenceFresh) {
                test.check(cameras.total === 133 && cameras.offlineCount === 0,
                           "API failure retains last-known cameras without fleet outage: " + test.phase);
                if (test.phase === 3) test.server("healthy", 4);
                else { ++test.phase; cameras.refresh(); }
            } else if (test.phase === 4 && cameras.backendEvidenceFresh) {
                test.check(cameras.total === 133 && cameras.offlineCount === 0, "API reconnection restores evidence freshness");
                test.server("offline", 5);
            } else if (test.phase === 5 && cameras.offlineCount === 1) {
                test.check(cameras.backendEvidenceFresh, "one explicitly reported outage is received as fresh evidence");
                test.phase = 6; cameras.refresh();
            } else if (test.phase === 6 && cameras.offlineCount === 1) {
                test.server("healthy", 7);
            } else if (test.phase === 7 && cameras.backendEvidenceFresh && cameras.offlineCount === 0) {
                test.check(true, "explicit camera recovery remains separate from API reconnection");
                test.phase = 8;
                finish.start();
            }
        }
    }
    Timer {
        id: finish; interval: 1500
        onTriggered: {
            console.log("[AVAILABILITY-MODEL-SUMMARY] " + JSON.stringify({checks: test.checks, failures: test.failures}));
            Qt.exit(test.failures ? 1 : 0);
        }
    }
    Timer { interval: 30000; running: true; onTriggered: { test.check(false, "model fixture timed out"); Qt.exit(1); } }
}
