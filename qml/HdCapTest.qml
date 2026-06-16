import QtQuick
import Watchtower

// Headless self-test for the live-wall HD concurrency cap. It drives the REAL
// LiveMonitor.requestHdPromotion / releaseHd / hdLimitReached — the exact calls
// the per-tile SD→HD button makes — with no backend, so the behaviour (6 succeed,
// the 7th is blocked, demotions free slots, teardown releases) is asserted
// directly. Run:
//   QT_QPA_PLATFORM=offscreen WT_TEST_HDCAP=1 ./build/watchtower
// Prints "HDCAP-TEST: PASS|FAIL …" and exits 0 (pass) / 1 (fail). Not shipped UI.
Item {
    width: 64; height: 64

    // Minimal stub so LiveMonitor constructs with no backend; the HD budget is
    // model-independent, so an empty roster is fine. eventModel stays null (all
    // its uses in LiveMonitor are null-guarded).
    QtObject {
        id: stubModel
        property int total: 0
        property bool loading: false
        function groupList() { return []; }
        function countFiltered(g, f) { return 0; }
        function page(g, f, s, p, c) { return []; }
        function setRecentCameras(ids) {}
        function toggleFavoriteById(id) {}
    }

    LiveMonitor { id: wall; cameraModel: stubModel }

    property int limitHits: 0
    Connections { target: wall; function onHdLimitReached() { limitHits++; } }

    Component.onCompleted: {
        var fails = [];
        var n = 0;
        function check(label, cond) { n++; if (!cond) fails.push(label); }

        // A tile feeds its current HD state in and adopts the returned state —
        // exactly the delegate wiring: useMainStream = requestHdPromotion(useMainStream).
        var on = {};
        function toggle(t) { on[t] = wall.requestHdPromotion(!!on[t]); }

        check("cap == 6", wall.hdCap === 6);
        check("count starts at 0", wall.hdCount === 0);

        // 6 distinct promotions all succeed
        for (var i = 0; i < 6; i++) toggle("t" + i);
        check("6 promotions -> count 6", wall.hdCount === 6);
        check("t0 & t5 are HD", on.t0 === true && on.t5 === true);
        check("no limit hit yet", limitHits === 0);

        // 7th and 8th are blocked: count holds, tile stays SD, hint fires each time
        toggle("t6");
        check("7th blocked -> count 6", wall.hdCount === 6);
        check("t6 stayed SD", on.t6 === false);
        check("limit hint fired x1", limitHits === 1);
        toggle("t7");
        check("8th blocked -> count 6", wall.hdCount === 6);
        check("limit hint fired x2", limitHits === 2);

        // demoting an HD tile frees a slot
        toggle("t0");
        check("demote -> count 5", wall.hdCount === 5);
        check("t0 now SD", on.t0 === false);

        // a promotion now succeeds (budget freed), with no new hint
        toggle("t6");
        check("promote after demote -> count 6", wall.hdCount === 6);
        check("t6 now HD", on.t6 === true);
        check("still 2 hints total", limitHits === 2);

        // teardown releases slots; an SD teardown is a no-op
        wall.releaseHd(true);
        check("release HD -> count 5", wall.hdCount === 5);
        wall.releaseHd(false);
        check("release SD -> count unchanged (5)", wall.hdCount === 5);

        // the floor never goes negative
        wall.hdCount = 0;
        wall.releaseHd(true);
        check("release floors at 0", wall.hdCount === 0);

        if (fails.length === 0) {
            console.log("HDCAP-TEST: PASS (" + n + " checks)");
            Qt.exit(0);
        } else {
            console.log("HDCAP-TEST: FAIL (" + fails.length + "/" + n + ") -> " + JSON.stringify(fails));
            Qt.exit(1);
        }
    }
}
