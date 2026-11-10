import QtQuick
import Watchtower

Window {
    id: test
    width: 1200
    height: 800
    visible: false
    property string mode: "__CASE__"
    property int phase: 0
    property int checks: 0
    property int failures: 0
    property int resets: 0
    property int initialResets: 0
    property bool busy: false
    CameraModel { id: cameras }
    LiveMonitor { id: wall; cameraModel: cameras; width: 1100; height: 700; visible: false }
    WallPlayback { id: playback; cameraModel: cameras; client: null; cameras: []; width: 1100; height: 700; visible: false }
    CameraGroups { id: groupScreen; cameraModel: cameras; visible: false; width: 1100; height: 700 }
    GroupSwitcher {
        id: switcher
        options: wall.groupOpts
        cameraModel: cameras
        label: "All cameras"
        visible: false
    }
    GroupSwitcher {
        id: playbackSwitcher
        options: playback.groupOpts
        cameraModel: cameras
        label: "Playback cameras"
        emptySelectable: false
        visible: false
    }
    Connections { target: cameras; function onModelReset() { ++test.resets; } }

    function check(ok, description) {
        ++checks;
        if (!ok) ++failures;
        console.log("[STATION-GROUP-CHECK] " + JSON.stringify({ok: !!ok, check: description}));
    }
    function groups() {
        var values = cameras.groupList();
        var found = {};
        for (var i = 0; i < values.length; ++i) found[values[i].id] = values[i];
        return found;
    }
    function optionsMatch() {
        var source = cameras.groupList();
        if (wall.groupOpts.length !== source.length + 1 || switcher.options.length !== source.length + 1
                || playback.groupOpts.length !== source.length + 1 || playbackSwitcher.options.length !== source.length + 1) return false;
        if (switcher.options[0].id !== "" || switcher.options[0].count !== cameras.total) return false;
        if (playbackSwitcher.options[0].id !== "" || playbackSwitcher.options[0].count !== cameras.total) return false;
        var seen = {};
        for (var i = 1; i < switcher.options.length; ++i) {
            var row = switcher.options[i];
            if (!row.id || seen[row.id]) return false;
            seen[row.id] = true;
            if (row.id !== source[i - 1].id || row.name !== source[i - 1].name || row.count !== source[i - 1].total) return false;
            var playbackRow = playbackSwitcher.options[i];
            if (playbackRow.id !== row.id || playbackRow.name !== row.name || playbackRow.count !== row.count) return false;
        }
        return true;
    }
    function change(name, nextPhase, refresh) {
        busy = true;
        var request = new XMLHttpRequest();
        request.open("POST", AuthController.baseUrl + "/fixture/phase/" + name);
        request.onreadystatechange = function() {
            if (request.readyState !== XMLHttpRequest.DONE) return;
            test.check(request.status === 200, "loopback phase accepted: " + name);
            test.phase = nextPhase;
            if (refresh) cameras.refresh();
            if (name === "mode-loading") {
                test.check(cameras.loading, "controlled old station full refresh enters loading before the mode transition");
                AuthController.loginWithPassword(AuthController.baseUrl, "station-groups-fixture", "disposable");
            }
            test.busy = false;
        };
        request.send("{}");
    }
    function finish() {
        console.log("[STATION-GROUP-SUMMARY] " + JSON.stringify({mode: mode, checks: checks, failures: failures}));
        Qt.exit(failures ? 1 : 0);
    }
    Timer {
        interval: 100
        repeat: true
        running: true
        onTriggered: {
            if (test.busy || cameras.loading || !AuthController.authenticated) return;
            if (test.phase === 0 && cameras.total === 133) {
                var initial = test.groups();
                var values = cameras.groupList();
                test.check(AuthController.stationLive === (test.mode === "station"), "actual authentication mode matches the scenario");
                test.check(groupScreen.canEdit === (test.mode === "operator"), "station groups stay read-only; operator group editing stays available");
                test.check(values.length === (test.mode === "station" ? 6 : 7), "group definitions survive denied station groups API; operator keeps empty definitions");
                var counts = [9, 21, 37, 17, 18, 31];
                for (var i = 0; i < counts.length; ++i)
                    test.check(initial["group-" + i] && initial["group-" + i].total === counts[i], "scoped roster count for group-" + i);
                test.check(test.optionsMatch(), "shipping LiveMonitor, WallPlayback and both GroupSwitcher bindings contain all group options/counts");
                test.check(!playbackSwitcher.emptySelectable, "playback dropdown keeps empty groups nonselectable");
                if (test.mode === "operator") {
                    test.check(initial["empty-group"] && initial["empty-group"].total === 0, "canonical operator group with zero visible cameras is retained");
                    test.check(initial["group-0"] && initial["group-0"].name === "Canonical entrance", "operator canonical name wins over roster fallback label");
                    switcher.open(); switcher.close(); playbackSwitcher.open(); playbackSwitcher.close();
                    test.check(true, "both shipping dropdowns open and close with empty-group options");
                    test.finish();
                } else if (test.failures) test.finish();
                else {
                    test.initialResets = test.resets;
                    test.change("mode-loading", 10, true);
                }
            } else if (test.phase === 10 && !AuthController.stationLive && !AuthController.busy) {
                var operatorGroups = test.groups();
                if (cameras.groupList().length !== 7 || !operatorGroups["empty-group"]) return;
                test.check(!cameras.loading, "discarded old station full refresh cannot leave loading stuck after a mode transition");
                test.check(cameras.total === 133 && test.resets === test.initialResets, "station-to-operator sign-in preserves the unchanged camera model/delegates");
                test.check(operatorGroups["empty-group"].total === 0 && operatorGroups["group-0"].name === "Canonical entrance", "same-process operator sign-in loads canonical names and the genuine empty group");
                test.check(groupScreen.canEdit, "same-process operator sign-in enables the permitted group controls");
                test.check(test.optionsMatch() && switcher.options.length === 8, "both actual dropdown bindings refresh after operator sign-in without a total-count change");
                test.phase = 11;
                AuthController.loginWithStationToken(AuthController.baseUrl, "disposable-station-groups-key");
            } else if (test.phase === 11 && AuthController.stationLive && AuthController.stationSessionCurrent) {
                var stationGroups = test.groups();
                if (cameras.groupList().length !== 6 || !stationGroups["group-0"]) return;
                test.check(cameras.total === 133 && test.resets === test.initialResets, "operator-to-station sign-in preserves the unchanged camera model/delegates");
                test.check(!stationGroups["empty-group"] && stationGroups["group-0"].name === "4стр", "station return removes operator-only empty definitions and uses authorized roster labels");
                test.check(!groupScreen.canEdit, "station return disables group editing again");
                test.check(test.optionsMatch() && switcher.options.length === 7, "both actual dropdown bindings refresh on station return without a total-count change");
                test.change("changed", 1, false);
            } else if (test.phase === 1) {
                var changed = test.groups();
                if (!changed["group-0"] || changed["group-0"].name !== "Переименованная группа") return;
                test.check(cameras.total === 133 && cameras.groupList().length === 5, "normal status poll removes a group after its last camera is reassigned");
                test.check(changed["group-1"] && changed["group-1"].total === 52 && !changed["group-5"], "normal status poll updates deduplicated group membership/counts");
                test.check(test.resets === test.initialResets, "group rename/reassignment uses the normal poll without resetting camera delegates");
                test.check(test.optionsMatch(), "shipping dropdown reacts to rename/removal when total camera count is unchanged");
                test.change("scoped", 2, true);
            } else if (test.phase === 2 && cameras.total === 3) {
                var scoped = test.groups();
                test.check(cameras.groupList().length === 1 && scoped["group-2"] && scoped["group-2"].total === 3, "station group list narrows to its current authorized roster");
                test.check(test.optionsMatch(), "shipping dropdown removes groups outside the narrowed roster");
                test.change("ungrouped", 3, true);
            } else if (test.phase === 3) {
                var ungrouped = test.groups();
                if (!ungrouped["group-2"] || ungrouped["group-2"].total !== 1) return;
                test.check(cameras.groupList().length === 1 && !ungrouped[""] && !ungrouped["null"], "null and empty group identifiers do not invent dropdown groups");
                test.check(ungrouped["group-2"].name === "&lt;Крыша&gt;", "roster group labels remain plain text");
                test.check(test.optionsMatch(), "ungrouped cameras remain in All cameras without a phantom group");
                test.change("missing-name", 4, true);
            } else if (test.phase === 4) {
                var missing = test.groups();
                if (!missing["group-2"] || missing["group-2"].total !== 3) return;
                test.check(cameras.groupList().length === 1 && missing["group-2"].name === "group-2", "missing roster label uses its stable group identifier");
                test.check(test.optionsMatch(), "shipping dropdown keeps the valid group when its label is missing");
                switcher.open(); switcher.close();
                test.check(true, "shipping station dropdown opens and closes");
                AuthController.logout();
                test.phase = 5;
            } else if (test.phase === 5) {
                // Logout is checked by the separate short timer below because
                // the main loop intentionally waits for authentication.
            }
        }
    }
    Timer {
        interval: 100; repeat: true; running: true
        onTriggered: {
            if (test.phase !== 5 || AuthController.authenticated) return;
            test.check(cameras.total === 0 && cameras.groupList().length === 0, "logout clears the roster-derived group identities");
            test.check(test.optionsMatch() && switcher.options.length === 1, "shipping dropdown clears group options on logout");
            test.finish();
        }
    }
    Timer { interval: 45000; running: true; onTriggered: { test.check(false, "loopback group scenario timed out"); test.finish(); } }
}
