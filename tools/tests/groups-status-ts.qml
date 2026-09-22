// Pins the ONE narrowing predicate in qml/GroupsStatus.js (St.ms) and the four
// classifier sites that read it.
//
// THE REGRESSION THIS EXISTS FOR (2026-09-22, adopted from cilex-pro-mobile
// b436010). `lastSegmentAt` had TWO "no usable instant" values that behaved
// OPPOSITELY: "" fell to the -1 sentinel, which every site handles, while a
// non-empty unparseable string became NaN — and NaN answers false to every
// comparison, `<= 0` included. So both the "no timestamp" branch and the "too
// old" branch were skipped, and a camera nothing could be said about was
// reported as nothing-wrong. Absent data rendering as healthy is the exact
// house rule this repo keeps; a silent sentinel is how it gets broken anyway.
//
// Run (Qt 6.12):  $QT/bin/qml tools/tests/groups-status-ts.qml
import QtQml
import "../../qml/GroupsStatus.js" as St

QtObject {
    property int fails: 0
    function ok(cond, what) {
        if (!cond) fails++;
        console.log((cond ? "PASS " : "FAIL ") + what);
    }
    // Armed = 5, mirroring CameraStatus.h (checked 2026-09-22).
    function cam(vmd, seg) {
        return { recording: 5, live: 1, motionKnown: true, motionReady: true,
                 motionLastVmdAt: vmd, lastSegmentAt: seg };
    }
    function isoAgo(ms) { return new Date(Date.now() - ms).toISOString(); }

    Component.onCompleted: {
        // ---- the predicate itself
        ok(St.ms("") === -1,          "ms(\"\") is the -1 sentinel");
        ok(St.ms(undefined) === -1,   "ms(undefined) is -1");
        ok(St.ms(null) === -1,        "ms(null) is -1");
        ok(St.ms("not a date") === -1, "REGRESSION: an unparseable string is -1, NOT NaN");
        ok(St.ms("2026-09-22T07:02:08.873+00:00") > 0, "iso_ms() output parses");
        ok(St.ms("2026-09-22T07:02:08.873977+00:00") > 0,
           "six fractional digits parse too (QV4 accepts; measured 2026-09-22)");
        ok(!isNaN(St.ms("garbage")), "ms() can never return NaN — the whole point");

        // ---- the behaviour that was wrong. Motion 10 min ago; footage timestamp
        //      is a non-empty string nothing can read.
        var fresh = isoAgo(600000);
        ok(St.notRecordingNow(cam(fresh, "not a date")) === true,
           "REGRESSION: detecting + unreadable last-segment => NOT RECORDING (was silently false)");
        ok(St.silent(cam(fresh, "not a date")) === true,
           "REGRESSION: unreadable last-segment => silent (was silently false)");
        ok(St.FAULT(cam(fresh, "not a date")) === true,
           "...and it reaches FAULT, so the ring and the facet agree");

        // ---- "" must keep behaving exactly as before: same answers, same reasons
        ok(St.notRecordingNow(cam(fresh, "")) === true,  "\"\" behaves as it always did");
        ok(St.silent(cam(fresh, "")) === true,           "\"\" is still silent");
        ok(St.marker(cam("", "")) === "NO MOTION",       "armed, nothing ever => NO MOTION");

        // ---- and the widening must not paint healthy cameras red
        var seg = isoAgo(120000);           // footage 2 min old
        ok(St.notRecordingNow(cam(fresh, seg)) === false,
           "recent motion WITH recent footage is not a fault");
        ok(St.silent(cam(fresh, seg)) === false, "recent footage is not silent");
        ok(St.FAULT(cam(fresh, seg)) === false,  "healthy armed camera stays healthy");
        ok(St.marker(cam(fresh, seg)) === "",    "healthy armed camera wears no ink");

        // ---- an old-but-READABLE segment must still be caught (the 2026-08-07 P1)
        ok(St.notRecordingNow(cam(fresh, isoAgo(7200000))) === true,
           "motion 10 min ago, newest footage 2 h ago => still the original P1");

        console.log(fails ? (fails + " FAILED") : "all passed");
        Qt.exit(fails ? 1 : 0);
    }
}
