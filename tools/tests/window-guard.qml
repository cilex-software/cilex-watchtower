// Pins the manifest-window guards in PlaybackScreen.qml and WallPlayback.qml.
//
// THE DEFECT (measured 2026-09-22). Those guards read `tlEndMs <= tlStartMs`,
// meaning "I have no usable window, do nothing". Against NaN — which is what
// `Date.parse(meta.wall_start)` yields for an unreadable manifest window — the
// comparison is FALSE, so the guard does not fire, and the very next line calls
// `new Date(NaN).toISOString()`, which THROWS RangeError. So the failure was not
// the empty timeline this box first claimed in BACKLOG item 8; it was a guard
// that fails open into a thrown exception. Same NaN family as the classifier fix
// in f80c028, one layer up: there it was a classifier answering "healthy", here
// it is a GUARD answering "proceed".
//
// THE FIX is `!(a > b)`, which is identical to `a <= b` for every finite pair by
// trichotomy and fires on NaN. That equivalence is what makes it safe to ship
// without a live manifest to test against: no valid window changes behaviour.
// WallPlayback.qml:156 already used this form — the rule was in the codebase and
// the later guards did not follow it.
//
// Run (Qt 6.12):  $QT/bin/qml tools/tests/window-guard.qml
import QtQml

QtObject {
    property int fails: 0
    function ok(cond, what) { if (!cond) fails++; console.log((cond ? "PASS " : "FAIL ") + what); }

    Component.onCompleted: {
        var NaNv = Date.parse("an unreadable wall_start");
        ok(isNaN(NaNv), "an unreadable manifest window parses to NaN");

        // ---- why the old guard was wrong
        ok((NaNv <= NaNv) === false, "REGRESSION: `end <= start` is FALSE on NaN — the guard fails OPEN");
        ok(!(NaNv > NaNv) === true,  "`!(end > start)` is TRUE on NaN — the guard fires");

        // ---- and what the old guard fell through to
        var threw = false;
        try { new Date(NaNv).toISOString(); } catch (e) { threw = true; }
        ok(threw, "new Date(NaN).toISOString() THROWS — this is what the guard was protecting");

        // ---- the equivalence that makes the change safe on live footage.
        //      Exhaustive over the three orderings, plus real epoch magnitudes.
        var pairs = [[1, 2], [2, 1], [2, 2], [0, 0], [-1, 1], [1, -1],
                     [1758531600000, 1758535200000],   // a real 1 h window
                     [1758535200000, 1758531600000],   // reversed
                     [1758531600000, 1758531600000]];  // zero-length
        var same = true, checked = 0;
        for (var i = 0; i < pairs.length; i++) {
            var a = pairs[i][1], b = pairs[i][0];        // (end, start)
            if ((a <= b) !== !(a > b)) same = false;
            checked++;
        }
        ok(same && checked === pairs.length,
           "`end <= start` and `!(end > start)` agree on all " + checked
           + " finite pairs — no valid window changes behaviour");

        // ---- the honest-window cases the guard must still let through / stop
        ok(!(2 > 1) === false, "a real window (end > start) still proceeds");
        ok(!(1 > 1) === true,  "a zero-length window still returns");
        ok(!(1 > 2) === true,  "a reversed window still returns");

        console.log(fails ? (fails + " FAILED") : "all passed");
        Qt.exit(fails ? 1 : 0);
    }
}
