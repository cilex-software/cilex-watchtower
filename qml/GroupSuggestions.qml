import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C
import Watchtower

// Group suggestions derived from camera NAMES.
//
// Why this can exist now: the 2026-08-07 Groups brief recorded the fleet as
// "names are long and nearly identical (HiWatch DS-I202(E) (192.168.1.146),
// same prefix on 30+ of them)" — there was no information in a name to group by.
// The fleet has since been renamed to a structured scheme, and measurement on
// 2026-08-16 found the operator's own groups ARE the location-word axis:
// Внутри 100% Холл, Лифты 100% Лифт, Крыша 100% Крыша. 75 of 133 cameras sit
// outside any group once the retired "Корпус 2" goes, and a name rule can place
// nearly all of them.
//
// So this does not invent a taxonomy. It COMPLETES the operator's own, and the
// mapping is learned from their existing assignments rather than hard-coded —
// add a group tomorrow and put five «Крыша» cameras in it and this follows.
//
// Honesty rules this screen is bound by:
//  - **Nothing is applied without a click.** Every suggestion is a proposal with
//    per-camera checkboxes; there is no "apply all" that runs on open.
//  - **A suggested group name is editable before it is created.** Group names are
//    the operator's data, and inventing one silently is the thing we do not do.
//  - **Cameras a rule cannot place are counted and named**, never dropped, so the
//    panel can never imply coverage it does not have.
//  - **A word with no confident home offers a choice**, not a guess.
Item {
    id: root

    property var cameraModel: null
    // Bumped by the host when groups/cameras change, to recompute.
    property int rev: 0
    signal applied(string message)

    // `analysis` reads cameraModel.page(), a Q_INVOKABLE that QML cannot track, so it
    // only re-runs when something it DOES track changes. The host's `rev` is
    // groups.length + fleet.length, and neither moves when a camera changes group —
    // so after an apply the panel kept showing the same card and the operator could
    // click it repeatedly (reported 2026-08-16). setCameraGroup emits groupsChanged +
    // countsChanged per camera on success; listen to those instead, coalesced.
    property int _modelRev: 0
    Timer { id: recalc; interval: 250; onTriggered: root._modelRev++ }
    Connections {
        target: root.cameraModel
        ignoreUnknownSignals: true
        function onGroupsChanged() { recalc.restart(); root._noteWriteLanded() }
        function onCountsChanged() { recalc.restart() }
        function onModelReset()    { recalc.restart() }
    }

    // ONE batch of writes at a time, and every apply button is disabled while it runs.
    // Assignments are individual PUTs; without this the second click re-sends the ones
    // still in flight.
    property string _busyWord: ""
    property int _busyRemaining: 0
    property string _busyTarget: ""
    function _noteWriteLanded() {
        if (_busyWord === "") return;
        if (--_busyRemaining > 0) return;
        var n = _busyTotal, tgt = _busyTarget;
        _busyWord = ""; _busyTarget = ""; busyWatchdog.stop();
        _modelRev++;
        applied(qsTr("Moved %n camera(s) to %1", "", n).arg(tgt));
    }
    property int _busyTotal: 0
    Timer {
        id: busyWatchdog
        interval: 20000
        // A failed assignment only qWarns in CameraModel — QML gets no signal at all,
        // so silence here means "some writes never landed", not "success".
        onTriggered: {
            if (root._busyWord === "") return;
            root._busyWord = ""; root._busyTarget = "";
            root._modelRev++;
            root.applied(qsTr("Some cameras did not move — check the group and retry"));
        }
    }

    // The location vocabulary, as DATA and in both alphabets the fleet actually
    // uses (measured: 129 Cyrillic names, 4 Latin — "10 street 6", "10.1.6 hall").
    // A matcher that only knew one alphabet would silently skip cameras, which is
    // the failure mode this whole panel exists to expose.
    readonly property var vocab: [
        { key: "Холл",  words: ["холл", "hall"],                        suggest: qsTr("Halls") },
        { key: "Улица", words: ["улица", "street"],                     suggest: qsTr("Streets") },
        { key: "Вход",  words: ["вход", "enter", "entrance"],           suggest: qsTr("Entrances") },
        { key: "Лифт",  words: ["лифт", "lift"],                        suggest: qsTr("Lifts") },
        { key: "Крыша", words: ["крыша", "roof"],                       suggest: qsTr("Roofs") }
    ]
    // A group counts as the home for a word when this share of its members carry
    // that word. Below it we do not guess — see `homeless` in the model below.
    readonly property real homeThreshold: 0.8

    function _wordOf(name) {
        var toks = ("" + name).toLowerCase().match(/[a-zа-яё]+/g) || [];
        for (var i = 0; i < toks.length; i++)
            for (var v = 0; v < vocab.length; v++)
                if (vocab[v].words.indexOf(toks[i]) >= 0)
                    return vocab[v].key;
        return "";
    }

    // ---- the model -------------------------------------------------------------
    readonly property var analysis: {
        root.rev; root._modelRev;                        // recompute triggers
        var out = { suggestions: [], mismatches: [], unmatched: [], total: 0 };
        if (!cameraModel) return out;

        var cams = cameraModel.page("", "", "alpha", 1, 5000);
        var groups = cameraModel.groupList();
        out.total = cams.length;

        var groupName = {}, i, c, w;
        for (i = 0; i < groups.length; i++) groupName[groups[i].id] = groups[i].name;

        // Learn each group's dominant word from what the operator already put in it.
        var counts = {};                                  // groupId -> {word: n}, plus _n
        for (i = 0; i < cams.length; i++) {
            c = cams[i];
            if (!c.groupId) continue;
            if (!counts[c.groupId]) counts[c.groupId] = { _n: 0 };
            w = _wordOf(c.name);
            counts[c.groupId]._n++;
            if (w) counts[c.groupId][w] = (counts[c.groupId][w] || 0) + 1;
        }
        var homeOf = {};                                  // word -> groupId
        for (var gid in counts) {
            var best = "", bestN = 0;
            for (var k in counts[gid]) {
                if (k === "_n") continue;
                if (counts[gid][k] > bestN) { bestN = counts[gid][k]; best = k; }
            }
            if (best !== "" && counts[gid]._n > 0
                && bestN / counts[gid]._n >= root.homeThreshold)
                homeOf[best] = gid;
        }

        // Bucket every camera by word, and note where it currently sits.
        var byWord = {};
        for (i = 0; i < cams.length; i++) {
            c = cams[i];
            w = _wordOf(c.name);
            if (w === "") { out.unmatched.push(c); continue; }
            if (!byWord[w]) byWord[w] = [];
            byWord[w].push(c);
        }

        for (var v = 0; v < vocab.length; v++) {
            var key = vocab[v].key;
            var list = byWord[key] || [];
            if (list.length === 0) continue;
            var home = homeOf[key] || "";
            var movers = [];
            for (i = 0; i < list.length; i++) {
                c = list[i];
                if (home === "") { if (!c.groupId) movers.push(c); }
                else if (c.groupId !== home) movers.push(c);
            }
            if (movers.length === 0) continue;
            out.suggestions.push({
                word: key,
                homeId: home,
                homeName: home === "" ? "" : (groupName[home] || ""),
                suggestName: vocab[v].suggest,
                cameras: movers,
                total: list.length
            });
        }

        // A camera sitting in a group whose dominant word is not its own. Reported,
        // never auto-corrected — the operator may have filed it deliberately.
        for (i = 0; i < cams.length; i++) {
            c = cams[i];
            if (!c.groupId) continue;
            w = _wordOf(c.name);
            if (w === "" || !homeOf[w]) continue;
            if (homeOf[w] !== c.groupId && counts[c.groupId]
                && (counts[c.groupId][w] || 0) / counts[c.groupId]._n < root.homeThreshold)
                out.mismatches.push({ cam: c, word: w,
                                      inGroup: groupName[c.groupId] || "",
                                      shouldBe: groupName[homeOf[w]] || "" });
        }
        return out;
    }

    // camId -> false explicitly excludes it; absent means included.
    property var _excluded: ({})
    function _isOn(id) { return _excluded[id] !== true; }
    function _toggle(id) {
        var e = {};
        for (var k in _excluded) e[k] = _excluded[k];
        e[id] = !(e[id] === true);
        _excluded = e;
    }
    function _onCount(cams) {
        var n = 0;
        for (var i = 0; i < cams.length; i++) if (_isOn(cams[i].camId)) n++;
        return n;
    }

    implicitHeight: col.implicitHeight
    // The host pane is a fixed 320 px. Nothing in here may report an implicitWidth
    // larger than that, or the ColumnLayout it sits in widens and the cards spill
    // over the camera wall (operator screenshot, 2026-08-16). Every button below
    // therefore carries Layout.minimumWidth: 0 and an ELIDING contentItem — a
    // Button's default implicitWidth is its full untruncated label.
    clip: true

    ColumnLayout {
        id: col
        anchors.fill: parent
        spacing: 10

        Text {
            text: qsTr("Suggested from camera names")
            color: Theme.ink3; font.family: Theme.fontMono
            font.pixelSize: 11; font.letterSpacing: 1.2
        }

        // "Nothing to suggest" and "nothing to suggest FROM" are different facts.
        // Caught 2026-08-16: a run where /streams returned no cameras rendered the
        // all-clear below, which is a false reassurance built out of missing data —
        // the exact thing this repo forbids. An empty roster now says so.
        Text {
            visible: root.analysis.total === 0
            Layout.fillWidth: true; wrapMode: Text.WordWrap
            text: qsTr("No cameras loaded — nothing can be suggested yet.")
            color: Theme.warn; font.pixelSize: 12
        }
        Text {
            visible: root.analysis.total > 0
                     && root.analysis.suggestions.length === 0
                     && root.analysis.mismatches.length === 0
            Layout.fillWidth: true; wrapMode: Text.WordWrap
            text: qsTr("Every camera whose name matches a known location is already in the matching group.")
            color: Theme.ink3; font.pixelSize: 12
        }

        Repeater {
            model: root.analysis.suggestions
            delegate: Rectangle {
                required property var modelData
                id: card
                Layout.fillWidth: true
                Layout.minimumWidth: 0
                implicitHeight: cardCol.implicitHeight + 20
                color: Theme.panel2; radius: 3
                border.width: 1; border.color: Theme.line2
                property bool expanded: false
                // A word with no group at ≥80% one location — we do not guess a home.
                readonly property bool homeless: modelData.homeId === ""
                property string newName: modelData.suggestName

                ColumnLayout {
                    id: cardCol
                    anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10 }
                    spacing: 8

                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        Text {
                            Layout.fillWidth: true; wrapMode: Text.WordWrap
                            // %n, not %1: Russian needs three plural forms and the
                            // count is genuinely 1 for some words ("1 cameras named" was
                            // on screen before this).
                            text: card.homeless
                                  ? qsTr("%n camera(s) named “%1” are in no matching group",
                                         "", card.modelData.cameras.length).arg(card.modelData.word)
                                  : qsTr("%n camera(s) named “%1” are not in %2",
                                         "", card.modelData.cameras.length)
                                        .arg(card.modelData.word).arg(card.modelData.homeName)
                            color: Theme.ink; font.pixelSize: 13
                        }
                        C.Button {
                            id: revBtn
                            Layout.minimumWidth: 0
                            implicitWidth: revLabel.implicitWidth + 14
                            implicitHeight: revLabel.implicitHeight + 8
                            text: card.expanded ? qsTr("Hide") : qsTr("Review")
                            onClicked: card.expanded = !card.expanded
                            background: Rectangle { color: "transparent"; border.width: 1
                                                    border.color: Theme.line2; radius: 2 }
                            contentItem: Text {
                                id: revLabel; text: revBtn.text; color: Theme.ink2
                                font.pixelSize: 12
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                            }
                        }
                    }

                    // No confident home: offer a NEW group with an editable name, never
                    // an invented one applied silently.
                    RowLayout {
                        visible: card.homeless; Layout.fillWidth: true; spacing: 6
                        Text { text: qsTr("Create group"); color: Theme.ink3; font.pixelSize: 12 }
                        Rectangle {
                            Layout.fillWidth: true; Layout.minimumWidth: 0
                            height: 26; radius: 2
                            color: Theme.panel3; border.width: 1; border.color: Theme.line2
                            C.TextField {
                                id: nameField
                                anchors.fill: parent; anchors.leftMargin: 6
                                text: card.modelData.suggestName
                                color: Theme.ink; font.pixelSize: 12
                                background: null
                                onTextChanged: card.newName = text
                            }
                        }
                    }

                    // Per-camera checkboxes. Everything starts included; unchecking is
                    // how the operator disagrees with a row.
                    ColumnLayout {
                        visible: card.expanded
                        Layout.fillWidth: true; spacing: 2
                        Repeater {
                            model: card.modelData.cameras
                            delegate: RowLayout {
                                required property var modelData
                                Layout.fillWidth: true; spacing: 6
                                Rectangle {
                                    width: 13; height: 13; radius: 2
                                    color: root._isOn(modelData.camId) ? Theme.accent : "transparent"
                                    border.width: 1
                                    border.color: root._isOn(modelData.camId) ? Theme.accent : Theme.line2
                                    MouseArea {
                                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: root._toggle(modelData.camId)
                                    }
                                }
                                Text {
                                    Layout.fillWidth: true; elide: Text.ElideRight
                                    text: modelData.name
                                    color: root._isOn(modelData.camId) ? Theme.ink2 : Theme.ink3
                                    font.pixelSize: 12
                                }
                                Text {
                                    Layout.maximumWidth: 78
                                    elide: Text.ElideRight
                                    text: modelData.groupId ? qsTr("in %1").arg(modelData.groupName || "—")
                                                            : qsTr("ungrouped")
                                    color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                                }
                            }
                        }
                    }

                    C.Button {
                        id: applyBtn
                        Layout.fillWidth: true
                        Layout.minimumWidth: 0
                        implicitWidth: 0                      // fillWidth decides, not the label
                        implicitHeight: applyLabel.implicitHeight + 10
                        enabled: root._onCount(card.modelData.cameras) > 0
                                 && (!card.homeless || card.newName.trim() !== "")
                        text: card.homeless
                              ? qsTr("Create “%1” with %n camera(s)", "",
                                     root._onCount(card.modelData.cameras)).arg(card.newName.trim())
                              : qsTr("Add %n camera(s) to %1", "",
                                     root._onCount(card.modelData.cameras)).arg(card.modelData.homeName)
                        onClicked: root._apply(card.modelData, card.homeless, card.newName.trim())
                        background: Rectangle { radius: 2
                                                color: applyBtn.enabled ? Theme.accent : Theme.panel3 }
                        contentItem: Text {
                            id: applyLabel
                            text: applyBtn.text; font.pixelSize: 12
                            elide: Text.ElideRight; wrapMode: Text.NoWrap
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            color: applyBtn.enabled ? "#1a1408" : Theme.ink3
                        }
                    }
                }
            }
        }

        // Reported, not corrected.
        Rectangle {
            visible: root.analysis.mismatches.length > 0
            Layout.fillWidth: true
            implicitHeight: misCol.implicitHeight + 18
            color: "transparent"; radius: 3
            border.width: 1; border.color: Theme.warnDim
            ColumnLayout {
                id: misCol
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 9 }
                spacing: 3
                Text {
                    text: qsTr("Filed against their name — check, do not assume these are wrong")
                    color: Theme.warn; font.pixelSize: 12; Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                }
                Repeater {
                    model: root.analysis.mismatches
                    delegate: Text {
                        required property var modelData
                        Layout.fillWidth: true; elide: Text.ElideRight
                        text: "· " + modelData.cam.name + " — "
                              + qsTr("in %1, named %2").arg(modelData.inGroup).arg(modelData.word)
                        color: Theme.ink3; font.pixelSize: 11
                    }
                }
            }
        }

        // Never let the panel imply it covered the whole fleet.
        Text {
            visible: root.analysis.unmatched.length > 0
            Layout.fillWidth: true; wrapMode: Text.WordWrap
            text: qsTr("%1 of %2 cameras have no recognised location word and are not covered here: %3")
                  .arg(root.analysis.unmatched.length).arg(root.analysis.total)
                  .arg(root._unmatchedNames())
            color: Theme.ink3; font.pixelSize: 11
        }
    }

    function _unmatchedNames() {
        var u = analysis.unmatched, out = [];
        for (var i = 0; i < u.length && i < 4; i++) out.push(u[i].name);
        return out.join(", ") + (u.length > 4 ? " …" : "");
    }

    // Applying is the ONLY place anything is written, and only for checked rows.
    function _apply(sug, makeNew, newName) {
        if (!cameraModel) return;
        var picked = [];
        for (var i = 0; i < sug.cameras.length; i++)
            if (_isOn(sug.cameras[i].camId)) picked.push(sug.cameras[i]);
        if (picked.length === 0) return;

        if (makeNew) {
            // createGroup is async (POST then refresh); the id does not exist yet, so
            // assignment waits for the group to appear rather than guessing an id.
            cameraModel.createGroup(newName);
            _pendingName = newName;
            _pendingCams = picked;
            pendingTimer.restart();
            applied(qsTr("Creating “%1”…").arg(newName));
            return;
        }
        // Announce nothing yet. The previous version toasted "Moved N cameras"
        // immediately after ISSUING the PUTs, i.e. it reported a success it had not
        // observed. _noteWriteLanded() says it once the writes actually land, and the
        // watchdog says the opposite if they do not.
        _busyWord = sug.word;
        _busyTarget = sug.homeName;
        _busyRemaining = picked.length;
        _busyTotal = picked.length;
        busyWatchdog.restart();
        for (var j = 0; j < picked.length; j++)
            cameraModel.setCameraGroup(picked[j].camId, sug.homeId);
    }

    property string _pendingName: ""
    property var _pendingCams: []
    property int _pendingTries: 0
    Timer {
        id: pendingTimer
        interval: 400; repeat: true
        running: root._pendingName !== ""
        onTriggered: {
            var groups = root.cameraModel ? root.cameraModel.groupList() : [];
            for (var i = 0; i < groups.length; i++) {
                if (groups[i].name === root._pendingName) {
                    for (var j = 0; j < root._pendingCams.length; j++)
                        root.cameraModel.setCameraGroup(root._pendingCams[j].camId, groups[i].id);
                    root.applied(qsTr("Created “%1” with %n camera(s)", "",
                                      root._pendingCams.length).arg(root._pendingName));
                    root._pendingName = ""; root._pendingCams = []; root._pendingTries = 0;
                    root.rev++;
                    return;
                }
            }
            // Say so rather than leaving a half-done action silent.
            if (++root._pendingTries > 15) {
                root.applied(qsTr("Group “%1” was not created — no cameras were moved")
                             .arg(root._pendingName));
                root._pendingName = ""; root._pendingCams = []; root._pendingTries = 0;
            }
        }
    }
}
