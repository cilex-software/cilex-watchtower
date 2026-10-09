import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as QC
import Watchtower

// Labs — "status and switches" (operator decision 2026-09-26). There is no design
// handoff for this screen yet, so it is built in the app's own idiom — the Health
// screen's status strip, stat cards and table, Preferences' segmented control and the
// Save-view modal — for the operator to review. Two sources, never mixed on one line:
//   * cilex-vision (LabsModel): which analysers are switched on, how much of the
//     archive each has covered, what each costs, and the ON/OFF switch (admin only);
//   * this station (LabsModel.station): whether THIS machine is scanning, Pause/Resume.
// Absent data renders as unknown (an em dash, with the reason), never as zero.
Item {
    id: root

    property var labs: null
    readonly property var st: (labs && labs.station) ? labs.station : ({})
    readonly property var rows: labs ? labs.analyzers : []
    readonly property bool admin: labs ? labs.canEdit : false
    // "stats": what each analyser has checked and found (LabsStats.qml, operator request
    // 2026-09-28), for the period in statsWindow; "table": the analysers and their switches.
    // Statistics is the FIRST tab and the one the screen opens on, and the table's tab is
    // "Analyser Settings" (the operator, 2026-09-30).
    property string view: "stats"
    property string statsWindow: "24h"
    // Statistics grouped "analyser" (one row per analyser) or "camera" (one row per camera,
    // its records split by analyser -- the operator, 2026-09-30).
    property string statsBy: "analyser"
    // An analyser's findings, opened from Statistics (LabsFindings); "" = not open.
    property string findingsSlug: ""
    property var cameraModel: null
    // The tracking workspace's model (LabsTracking, main/Main.qml). Passed in rather
    // than created here so the "Tracking" tab owns no second engine.
    property var tracking: null
    // The Stage 3 semantic analysers' model (LabsDetection, Main.qml).
    property var detection: null
    // The Stage 4 A/B analysers' model (LabsStage4, Main.qml).
    property var stage4: null
    function openFindings(slug) { findings.period = root.statsWindow; root.findingsSlug = slug }

    onVisibleChanged: if (visible && labs) { labs.refresh(); labs.refreshStation() }
    // WT_LABS_CONFIRM (main.cpp): open the real dialog for review screenshots.
    onRowsChanged: {
        if (typeof wtLabsConfirm === "undefined" || wtLabsConfirm === "" || confirm.visible) return;
        for (var i = 0; i < rows.length; i++)
            if (rows[i].slug === wtLabsConfirm) { view = "table"; confirm.row = rows[i]; confirm.visible = true; return; }
    }
    Component.onCompleted: {
        if (visible && labs) labs.refresh()
        // WT_LABS_VIEW (main.cpp): "stats", "stats:<24h|7d|all>" or "stats:<period>:camera"
        // opens the statistics view, for review screenshots; "table" the settings.
        if (typeof wtLabsView !== "undefined" && wtLabsView !== "") {
            var p = wtLabsView.split(":")
            if (p[0] === "table") view = "table"
            // "tracking" opens the tracking workspace (run/review/verify).
            if (p[0] === "tracking") view = "tracking"
            // "detection" opens the Stage 3 semantic-analyser workspace.
            if (p[0] === "detection") view = "detection"
            // "stage4" opens the Stage 4 A/B workspace (objects, size, colour).
            if (p[0] === "stage4") view = "stage4"
            if (p[0] === "stats") {
                view = "stats"
                if (p.length > 1 && ["24h", "7d", "all"].indexOf(p[1]) >= 0) statsWindow = p[1]
                if (p.length > 2 && ["camera", "analyser"].indexOf(p[2]) >= 0) statsBy = p[2]
            }
            // "findings:<analyser>[:<period>[:<filter>]]" opens that analyser's findings.
            if (p[0] === "findings" && p.length > 1) {
                view = "stats"
                if (p.length > 2 && ["24h", "7d", "all"].indexOf(p[2]) >= 0) statsWindow = p[2]
                openFindings(p[1])
                if (p.length > 3) findings.facet = p[3]
            }
        }
    }
    // Server status at most every 30 minutes while open, or on Refresh: the work behind it
    // is not cheap for the pilot's database (LabsModel.h). The local station file is
    // free: every 5 s.
    Timer { interval: 1800000; running: root.visible && root.labs !== null; repeat: true; onTriggered: root.labs.refresh() }
    Timer { interval: 5000; running: root.visible && root.labs !== null; repeat: true; onTriggered: root.labs.refreshStation() }

    // ---- words -------------------------------------------------------------------
    // One name per analyser, everywhere: LabsNames (the operator's names, 2026-09-29).
    function title(slug) { return LabsNames.title(slug) }
    function blurb(slug) {
        switch (slug) {
        case "illumination":     return qsTr("Whether each hour was daylight, dusk, night or infrared.");
        case "frame_difference": return qsTr("How violent the movement was, and how long it lasted.");
        case "camera_health":    return qsTr("Lens covered, out of focus, camera moved, picture frozen, lights changed.");
        case "foreground_mask":  return qsTr("How much of the picture moved, and how many moving areas.");
        case "blob_geometry":    return qsTr("Size and shape of whatever moved. It never says what it is.");
        case "colour_histogram": return qsTr("The main colour of whatever moved. Not under infrared.");
        case "optical_flow":     return qsTr("Which way things moved, how fast, and whether together.");
        case "track_linking":    return qsTr("Follows each moving thing: how long it stayed, where it came and went.");
        case "perceptual_hash":  return qsTr("Finds hours where nothing changed, and scenes that repeat.");
        case "audio_energy":     return qsTr("Loudness and sudden sounds, on cameras that record audio.");
        case "object_profile":   return qsTr("The main colour of each thing that passes, and a picture of it. Aimed at vehicles; not under infrared.");
        case "image_embedding":  return qsTr("Search by picture. Not built yet.");
        default:                 return "";
        }
    }
    function scopeText(s) {
        switch (s) {
        case "outside": return qsTr("outdoor cameras");
        case "inside":  return qsTr("indoor cameras");
        case "all":     return qsTr("all cameras");
        default:        return s ? s : qsTr("unknown cameras");
        }
    }
    function known(v) { return v !== undefined && v !== null && !(typeof v === "number" && isNaN(v)); }
    // In the INTERFACE language's style, not the system's: in Russian a comma is the
    // decimal mark, so "11,884 ч" reads as eleven-point-something hours.
    readonly property var loc: Qt.locale((typeof Language !== "undefined" && Language.language === "ru") ? "ru_RU" : "en_US")
    function num(v, decimals) {
        if (!known(v)) return "—";
        return Number(v).toLocaleString(root.loc, "f", decimals === undefined ? 0 : decimals);
    }
    function ago(s) {
        if (!known(s) || s < 0) return "";
        if (s < 60) return qsTr("%1 s ago").arg(s);
        if (s < 3600) return qsTr("%1 min ago").arg(Math.round(s / 60));
        return qsTr("%1 h ago").arg(Math.round(s / 3600));
    }
    function stationText() {
        switch (st.view) {
        case "absent":      return qsTr("No Labs scanner has run on this computer");
        case "unreadable":  return qsTr("The scanner's status file cannot be read");
        case "not_running": return qsTr("Not running — last heard from %1").arg(ago(st.ageS));
        case "stopped":     return qsTr("Stopped");
        case "starting":    return qsTr("Starting");
        case "paused":      return st.governed ? qsTr("Paused by the server") : qsTr("Paused");
        case "stopped_by_server": return qsTr("Stopped by the server");
        case "waiting":     return qsTr("Waiting for the server's orders");
        case "held":        return qsTr("Held on this station");
        case "running":     return st.current ? qsTr("Scanning: %1").arg(title(st.current)) : qsTr("Scanning");
        case "idle":        return qsTr("Waiting — nothing to scan right now");
        case "unreachable": return qsTr("Cannot reach the server — will retry");
        // It ANSWERED (503 labs_busy, or a 5xx with no code): "cannot reach" would be false.
        case "busy":        return qsTr("The server is busy — will retry");
        case "fatal":       return qsTr("Cannot work until fixed");
        default:            return qsTr("Status unknown");
        }
    }
    function stationColor() {
        switch (st.view) {
        case "running": case "idle": return Theme.good;
        case "paused": case "unreachable": case "busy": case "starting": case "waiting": case "held": return Theme.warn;
        case "not_running": case "fatal": case "unreadable": return Theme.bad;
        default: return Theme.ink3;
        }
    }
    function stationDetail() {
        var bits = [];
        if (st.view === "paused" && st.controlWhy === "absent") bits.push(qsTr("never started on this station"));
        if ((st.view === "fatal" || st.view === "unreachable" || st.view === "busy") && st.note) bits.push(st.note);
        // The control plane: WHY this station is not scanning, in the server's words or the
        // safety check's. A hold names who set it and when.
        var h = st.hold;
        if (h && h.why) bits.push(qsTr("%1 · by %2").arg(h.why).arg(h.by || "?") + (h.at ? " · " + h.at : ""));
        else if (st.governed && (st.view === "paused" || st.view === "stopped_by_server" || st.view === "waiting") && st.note)
            bits.push(st.note);
        var lu = st.lastUnit;
        if (lu && lu.analyzer) {
            var what = lu.outcome === "done" ? qsTr("%n row(s)", "", lu.observations || 0)
                     : lu.outcome === "failed" ? qsTr("filed as failed") : qsTr("given back");
            bits.push(qsTr("last: %1 · %2 · %3").arg(title(lu.analyzer)).arg(lu.camera_id || "").arg(what));
        }
        // Why the Start / Pause button is missing (st.switchable): nothing here would act on it.
        if (st.view === "absent") bits.push(qsTr("Start and Pause appear here once the scanner runs"));
        else if (st.view === "stopped" || st.view === "not_running")
            bits.push(qsTr("Start and Pause appear here once the scanner runs again"));
        return bits.join("  ·  ");
    }

    // ---- shared pieces --------------------------------------------------------------
    component Btn: Rectangle {
        id: b
        property string label: ""
        property bool enabledLook: true
        signal clicked()
        implicitHeight: 28
        implicitWidth: bt.implicitWidth + 24
        color: bma.containsMouse && b.enabledLook ? Theme.panel : Theme.bg
        border.width: 1
        border.color: bma.containsMouse && b.enabledLook ? Theme.accent : Theme.line2
        opacity: b.enabledLook ? 1.0 : 0.45
        Text { id: bt; anchors.centerIn: parent; text: b.label; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
        MouseArea { id: bma; anchors.fill: parent; hoverEnabled: true; cursorShape: b.enabledLook ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: b.clicked() }
    }
    component Label10: Text {
        color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
        font.weight: Font.DemiBold; font.letterSpacing: 1.2; font.capitalization: Font.AllUppercase
    }
    // Preferences' segmented control, as an OFF | ON switch.
    component OnOff: Rectangle {
        id: sw
        property bool on: false
        property bool live: true         // false: shown, not operable (and says why)
        property string why: ""
        signal picked(bool v)
        implicitWidth: 2 * 52 + 2; implicitHeight: 28
        color: Theme.bg; border.width: 1; border.color: Theme.line2
        opacity: sw.live ? 1.0 : 0.55
        Row {
            x: 1; y: 1
            Repeater {
                model: [ { k: qsTr("OFF"), v: false }, { k: qsTr("ON"), v: true } ]
                delegate: Rectangle {
                    required property var modelData
                    width: 52; height: 26
                    color: sw.on === modelData.v ? (modelData.v ? Theme.accent : Theme.panel2) : "transparent"
                    Text { anchors.centerIn: parent; text: modelData.k
                           color: sw.on === modelData.v ? (modelData.v ? Theme.bg : Theme.ink) : Theme.ink3
                           font.family: Theme.fontMono; font.pixelSize: 11; font.weight: Font.DemiBold }
                    MouseArea { id: segMa; anchors.fill: parent; hoverEnabled: true
                                cursorShape: sw.live ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onClicked: if (sw.live && sw.on !== modelData.v) sw.picked(modelData.v) }
                    QC.ToolTip.visible: !sw.live && sw.why !== "" && segMa.containsMouse
                    QC.ToolTip.text: sw.why
                    QC.ToolTip.delay: 300
                }
            }
        }
    }

    // column widths (header and rows share them; the analyser column fills the rest)
    readonly property int wSwitch: 200
    readonly property int wCover: 250
    readonly property int wCost: 210
    readonly property int wHere: 190

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ===== this station =====
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 44
            color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 18
                spacing: 8
                Rectangle { width: 7; height: 7; radius: 4; color: root.stationColor() }
                Label10 { text: qsTr("This station") }
                Text { text: root.stationText(); color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.DemiBold }
                Text {
                    Layout.fillWidth: true
                    text: root.stationDetail(); color: Theme.ink3
                    font.family: Theme.fontMono; font.pixelSize: 11; elide: Text.ElideRight
                }
                Text {
                    visible: root.labs && root.labs.stationError !== ""
                    text: root.labs ? qsTr("could not save: %1").arg(root.labs.stationError) : ""
                    color: Theme.bad; font.family: Theme.fontMono; font.pixelSize: 11
                }
                // WHO the button asks follows who governs (operator decisions 2026-09-28):
                //  * a HOLD (the wall's safety check) -> Release, here, admins;
                //  * GOVERNED (the worker reports to cilex-vision's control plane) -> the
                //    SERVER, for this workstation: Start / Pause, admin, audited there;
                //  * otherwise the local flag, as before: Pause for anyone (always safe),
                //    Resume for administrators (it spends this station's CPU).
                // Start / Resume / Pause only while a scanner that can work runs HERE
                // (st.switchable, LabsStation.h). Without one, the button wrote control.json
                // for nobody and flipped to "Pause scanning" (operator 2026-09-28: a bug).
                Btn {
                    visible: root.labs !== null && (held || root.st.switchable === true)
                    readonly property bool held: !!(root.st.hold && root.st.hold.why)
                    readonly property bool gov: root.st.governed === true
                    readonly property bool paused: gov ? root.st.serverMode !== "running" : root.st.paused !== false
                    readonly property bool busy: root.labs !== null && root.labs.stationBusy
                    label: held ? qsTr("Release hold")
                         : busy ? qsTr("Asking the server…")
                         : paused ? (gov ? qsTr("Start scanning") : qsTr("Resume scanning")) : qsTr("Pause scanning")
                    enabledLook: !busy && (held || gov ? root.admin : (!paused || root.admin))
                    onClicked: {
                        if (!enabledLook) return;
                        if (held) root.labs.releaseHold();
                        else if (gov) root.labs.setStationRunning(paused);
                        else root.labs.setStationPaused(!paused);
                    }
                    QC.ToolTip.visible: !enabledLook && !busy && hovered2.containsMouse
                    QC.ToolTip.text: held ? qsTr("Only an administrator can release the hold")
                                          : qsTr("Only an administrator can start or pause scanning")
                    MouseArea { id: hovered2; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                }
            }
        }

        // ===== stat cards =====
        Rectangle {
            visible: root.findingsSlug === ""
            Layout.fillWidth: true
            Layout.preferredHeight: 84
            color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }

            component Card: Item {
                id: card
                property string value: "—"
                property string unit: ""
                property string label: ""
                property string tip: ""
                property bool last: false
                Layout.fillWidth: true
                Layout.fillHeight: true
                Rectangle { visible: !card.last; anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 1; color: Theme.line }
                Column {
                    anchors.left: parent.left; anchors.top: parent.top
                    anchors.leftMargin: 18; anchors.topMargin: 16
                    spacing: 8
                    Row {
                        spacing: 6
                        Text { text: card.value; color: card.value === "—" ? Theme.ink3 : Theme.ink
                               font.family: Theme.fontSans; font.pixelSize: 30; font.weight: Font.Bold; font.letterSpacing: -1 }
                        Text { visible: card.unit !== ""; anchors.baseline: parent.children[0].baseline
                               text: card.unit; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11 }
                    }
                    Label10 { text: card.label; font.letterSpacing: 1.4 }
                }
                MouseArea { id: cma; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                QC.ToolTip.visible: card.tip !== "" && cma.containsMouse
                QC.ToolTip.text: card.tip
                QC.ToolTip.delay: 300
            }

            RowLayout {
                anchors.fill: parent
                spacing: 0
                Card {
                    value: (root.labs && root.labs.loaded) ? (root.labs.enabledCount + " / " + root.rows.length) : "—"
                    label: qsTr("Switched on")
                    tip: (root.labs && root.labs.loaded) ? "" : qsTr("No answer from the server yet")
                }
                Card {
                    readonly property bool someUnmeasured: root.labs ? root.labs.projectedIsFloor : false
                    value: (root.labs && root.labs.loaded && root.known(root.labs.projectedCpuHoursPerDay))
                           ? ((someUnmeasured ? "≥ " : "") + root.num(root.labs.projectedCpuHoursPerDay, 1)) : "—"
                    unit: value === "—" ? "" : qsTr("CPU-h / day")
                    label: qsTr("Projected load")
                    tip: someUnmeasured ? qsTr("At least this much: an analyser that is switched on has no measured cost yet")
                                        : qsTr("CPU time per day across the stations that scan, for the analysers switched on")
                }
                Card {
                    readonly property var total: {
                        if (!root.labs || !root.labs.loaded || root.rows.length === 0) return null;
                        var s = 0, any = false;
                        for (var i = 0; i < root.rows.length; i++)
                            if (root.known(root.rows[i].done)) { s += root.rows[i].done; any = true; }
                        return any ? s : null;
                    }
                    value: root.num(total)
                    label: qsTr("Camera-hours analysed")
                    tip: qsTr("Every analyser counted separately, since Labs started")
                }
                Card {
                    last: true
                    readonly property var t: root.st.totals
                    value: (root.st.present && t && root.known(t.done)) ? root.num(t.done) : "—"
                    unit: (root.st.present && t && root.known(t.failed) && t.failed > 0) ? qsTr("+%1 failed").arg(t.failed) : ""
                    label: qsTr("Done by this station")
                    tip: root.st.present ? qsTr("Since the scanner last started") : root.stationText()
                }
            }
        }

        // ===== what the server could not tell us, or refused =====
        Rectangle {
            id: banner
            readonly property string text: {
                if (!root.labs) return "";
                if (root.labs.changeError === "admin_only") return qsTr("Only an administrator can switch analysers on or off.");
                if (root.labs.changeError !== "") return qsTr("The server refused the change: %1").arg(root.labs.changeError);
                switch (root.labs.errorCode) {
                case "admin_only":   return qsTr("Only administrators can see the Labs programme.");
                case "unreachable":  return qsTr("The server is not answering. Showing what it said at %1.").arg(root.labs.generatedAt || "—");
                case "refused":      return qsTr("The server refused: %1").arg(root.labs.errorText);
                }
                if (!root.admin && root.labs.loaded) return qsTr("Only an administrator can switch analysers on or off.");
                return "";
            }
            readonly property bool bad: root.labs && (root.labs.errorCode === "unreachable" || root.labs.errorCode === "refused"
                                                      || (root.labs.changeError !== "" && root.labs.changeError !== "admin_only"))
            visible: text !== ""
            Layout.fillWidth: true
            Layout.preferredHeight: visible ? 34 : 0
            color: bad ? Theme.badSoft : Theme.accentSoft
            Rectangle { anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 3; color: banner.bad ? Theme.bad : Theme.accent }
            Text {
                anchors.left: parent.left; anchors.leftMargin: 18; anchors.right: parent.right; anchors.rightMargin: 18
                anchors.verticalCenter: parent.verticalCenter
                text: banner.text; color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12; elide: Text.ElideRight
            }
        }

        // ===== which view, and (statistics) which period =====
        Rectangle {
            visible: root.findingsSlug === ""
            Layout.fillWidth: true
            Layout.preferredHeight: 46
            color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 18
                spacing: 14
                LabsSeg {
                    choices: [ { k: qsTr("Statistics"), v: "stats" },
                               { k: qsTr("Analyser Settings"), v: "table" },
                               { k: qsTr("Tracking"), v: "tracking" },
                               { k: qsTr("Detection"), v: "detection" },
                               { k: qsTr("Stage 4"), v: "stage4" } ]
                    value: root.view
                    onPicked: (v) => root.view = v
                }
                Item { Layout.fillWidth: true }
                LabsSeg {
                    visible: root.view === "stats"
                    choices: [ { k: qsTr("By camera"), v: "camera" }, { k: qsTr("By analyser"), v: "analyser" } ]
                    value: root.statsBy
                    onPicked: (v) => root.statsBy = v
                }
                LabsSeg {
                    visible: root.view === "stats"
                    choices: [ { k: qsTr("24 hours"), v: "24h" }, { k: qsTr("7 days"), v: "7d" }, { k: qsTr("All"), v: "all" } ]
                    value: root.statsWindow
                    onPicked: (v) => root.statsWindow = v
                }
                Text {
                    visible: root.view === "stats" && root.labs !== null
                    text: (root.labs && root.labs.loading) ? qsTr("Refreshing…") : qsTr("Refresh")
                    color: statsRefreshMa.containsMouse && !(root.labs && root.labs.loading) ? Theme.accent : Theme.ink2
                    font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.DemiBold
                    MouseArea { id: statsRefreshMa; anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: if (root.labs && !root.labs.loading) root.labs.refresh(true) }
                    QC.ToolTip.visible: statsRefreshMa.containsMouse
                    QC.ToolTip.text: qsTr("Ask the server now. It refreshes on its own every 30 minutes: the counts cost the server real work.")
                    QC.ToolTip.delay: 300
                }
            }
        }

        // ===== statistics =====
        LabsStats {
            visible: root.view === "stats" && root.findingsSlug === ""
            Layout.fillWidth: true
            Layout.fillHeight: true
            labs: root.labs
            screen: root
            window: root.statsWindow
            by: root.statsBy
            cameraModel: root.cameraModel
            onPickWindow: (w) => root.statsWindow = w
            onPickBy: (b) => root.statsBy = b
            onOpenFindings: (slug) => root.openFindings(slug)
        }

        // ===== tracking: run the engine over a recording, review, verify =====
        LabsTrackingPanel {
            visible: root.view === "tracking" && root.findingsSlug === ""
            Layout.fillWidth: true
            Layout.fillHeight: true
            tracking: root.tracking
            cameraModel: root.cameraModel
        }

        // ===== detection: the Stage 3 semantic analysers =====
        LabsDetectionPanel {
            visible: root.view === "detection" && root.findingsSlug === ""
            Layout.fillWidth: true
            Layout.fillHeight: true
            detection: root.detection
        }

        // ===== stage 4: object, apparent size, colour and colour location =====
        LabsStage4Panel {
            visible: root.view === "stage4" && root.findingsSlug === ""
            Layout.fillWidth: true
            Layout.fillHeight: true
            stage4: root.stage4
        }

        // ===== one analyser's findings, to watch =====
        LabsFindings {
            id: findings
            visible: root.findingsSlug !== ""
            Layout.fillWidth: true
            Layout.fillHeight: true
            screen: root
            cameraModel: root.cameraModel
            analyzer: root.findingsSlug
            onPeriodChanged: root.statsWindow = period      // the same period back in Statistics
            onBack: root.findingsSlug = ""
        }

        // ===== table header =====
        Rectangle {
            visible: root.view === "table"
            Layout.fillWidth: true
            Layout.preferredHeight: 34
            color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 18
                spacing: 0
                Label10 { Layout.fillWidth: true; text: qsTr("Analyser") }
                Label10 {
                    Layout.preferredWidth: root.wSwitch
                    // The server's answer is minutes old by design (LabsModel::refresh), so
                    // it carries its time.
                    readonly property string asOf: (root.labs && root.labs.generatedAt)
                        ? Qt.formatTime(new Date(root.labs.generatedAt), "HH:mm") : ""
                    text: asOf ? qsTr("On the server · %1").arg(asOf) : qsTr("On the server")
                }
                Item {
                    Layout.preferredWidth: root.wCover
                    Layout.fillHeight: true
                    Label10 { anchors.verticalCenter: parent.verticalCenter; text: qsTr("Covered") }
                    Text {
                        id: refreshLink
                        anchors.right: parent.right; anchors.rightMargin: 16; anchors.verticalCenter: parent.verticalCenter
                        visible: root.labs !== null
                        text: (root.labs && root.labs.loading) ? qsTr("Refreshing…") : qsTr("Refresh")
                        color: refreshMa.containsMouse && !(root.labs && root.labs.loading) ? Theme.accent : Theme.ink2
                        font.family: Theme.fontMono; font.pixelSize: 10; font.weight: Font.DemiBold
                        MouseArea { id: refreshMa; anchors.fill: parent; hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: if (root.labs && !root.labs.loading) root.labs.refresh(true) }
                        QC.ToolTip.visible: refreshMa.containsMouse
                        QC.ToolTip.text: qsTr("Ask the server now. It refreshes on its own every 30 minutes: the counts cost the server real work.")
                        QC.ToolTip.delay: 300
                    }
                }
                Label10 { Layout.preferredWidth: root.wCost; text: qsTr("Cost") }
                Label10 { Layout.preferredWidth: root.wHere; text: qsTr("This station") }
            }
        }

        // ===== one row per analyser =====
        ListView {
            id: list
            visible: root.view === "table"
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: root.rows
            boundsBehavior: Flickable.StopAtBounds
            QC.ScrollBar.vertical: QC.ScrollBar { policy: QC.ScrollBar.AsNeeded }

            delegate: Rectangle {
                id: row
                required property var modelData
                readonly property var r: modelData
                width: ListView.view.width
                height: 76
                color: rowMa.containsMouse ? Theme.panel : "transparent"
                Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
                MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }

                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 18
                    spacing: 0

                    // analyser
                    Column {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 3
                        Text { text: root.title(row.r.slug); color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13; font.weight: Font.DemiBold }
                        Text { width: parent.width - 16; text: root.blurb(row.r.slug); color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12; elide: Text.ElideRight }
                        Text { text: row.r.slug + (row.r.scope ? "  ·  " + root.scopeText(row.r.scope) : ""); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                    }

                    // on the server
                    Item {
                        Layout.preferredWidth: root.wSwitch
                        Layout.fillHeight: true
                        OnOff {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: root.labs && root.labs.busySlug !== row.r.slug
                            on: row.r.enabled === true
                            live: root.admin && root.labs && root.labs.busySlug === ""
                            why: !root.admin ? qsTr("Only an administrator can switch analysers on or off") : ""
                            onPicked: (v) => {
                                if (v) { confirm.row = row.r; confirm.visible = true; }
                                else root.labs.setAnalyzerEnabled(row.r.slug, false);
                            }
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: root.labs && root.labs.busySlug === row.r.slug
                            text: qsTr("Changing…"); color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11
                        }
                    }

                    // covered
                    Column {
                        Layout.preferredWidth: root.wCover
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 5
                        // The server's own counts: hours done, and (while switched on) the
                        // hours still waiting. No percentage: the server gives no
                        // denominator here, and its waiting count can include failed hours
                        // that will not be handed out again, so a ratio would overstate
                        // precision.
                        Text {
                            text: row.r.enabled
                                  ? (root.known(row.r.done) ? qsTr("done: %1 h").arg(root.num(row.r.done)) : "—")
                                  : (root.known(row.r.done) && row.r.done > 0 ? qsTr("done while on: %1 h").arg(root.num(row.r.done)) : "—")
                            color: row.r.enabled && root.known(row.r.done) ? Theme.ink : Theme.ink3
                            font.family: Theme.fontMono; font.pixelSize: 11
                        }
                        Text {
                            visible: row.r.enabled
                            text: root.known(row.r.waiting) ? qsTr("waiting: %1").arg(root.num(row.r.waiting))
                                                            : qsTr("waiting: counted at the next refresh")
                            color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                        }
                        Text {
                            visible: root.known(row.r.failed) && row.r.failed > 0
                            text: qsTr("%1 failed").arg(root.num(row.r.failed))
                            color: Theme.warn; font.family: Theme.fontMono; font.pixelSize: 10
                        }
                    }

                    // cost
                    Column {
                        Layout.preferredWidth: root.wCost
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 4
                        Text {
                            text: root.known(row.r.costCpuS) ? qsTr("%1 CPU-s per camera-hour").arg(root.num(row.r.costCpuS, 1)) : qsTr("not measured")
                            color: root.known(row.r.costCpuS) ? Theme.ink : Theme.ink3
                            font.family: Theme.fontMono; font.pixelSize: 11
                        }
                        Text {
                            visible: root.known(row.r.cpuHoursPerDay)
                            text: row.r.enabled ? qsTr("≈ %1 CPU-h per day").arg(root.num(row.r.cpuHoursPerDay, 1))
                                                : qsTr("≈ %1 CPU-h per day if on").arg(root.num(row.r.cpuHoursPerDay, 1))
                            color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                        }
                    }

                    // this station
                    Text {
                        Layout.preferredWidth: root.wHere
                        Layout.alignment: Qt.AlignVCenter
                        readonly property var reg: root.st.registered
                        text: {
                            if (!root.st.present) return "—";
                            if (!reg || reg.indexOf(row.r.slug) < 0) return qsTr("Cannot run here");
                            if (row.r.slug === "camera_health" && !root.st.cameraHealth) return qsTr("Not here (one station only)");
                            if (root.st.skipped && root.st.skipped.indexOf(row.r.slug) >= 0) return qsTr("Needs a server update");
                            return qsTr("Runs here");
                        }
                        color: text === qsTr("Runs here") ? Theme.ink2 : Theme.ink3
                        font.family: Theme.fontMono; font.pixelSize: 11
                        wrapMode: Text.WordWrap
                    }
                }
            }

            Text {
                anchors.centerIn: parent
                visible: list.count === 0
                text: (!root.labs || root.labs.loading) ? qsTr("Asking the server…") : qsTr("No answer from the server yet")
                color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 13
            }
        }
    }

    // ===== switching one ON asks first: it spends station CPU and everyone sees it =====
    Item {
        id: confirm
        anchors.fill: parent
        visible: false
        property var row: null
        Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.65)
                    MouseArea { anchors.fill: parent; onClicked: confirm.visible = false } }
        Rectangle {
            anchors.centerIn: parent
            width: 480
            implicitHeight: cHead.height + cBody.implicitHeight + cFoot.height + 36
            color: Theme.panel
            border.width: 1; border.color: Theme.accent
            MouseArea { anchors.fill: parent }
            Rectangle {
                id: cHead
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                height: 56; color: Theme.panel
                Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
                Text { anchors.left: parent.left; anchors.leftMargin: 22; anchors.verticalCenter: parent.verticalCenter
                       text: confirm.row ? qsTr("Switch on “%1”?").arg(root.title(confirm.row.slug)) : ""
                       color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 16; font.weight: Font.DemiBold }
            }
            Column {
                id: cBody
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: cHead.bottom
                anchors.leftMargin: 22; anchors.rightMargin: 22; anchors.topMargin: 18
                spacing: 10
                Text {
                    width: parent.width; wrapMode: Text.WordWrap
                    text: confirm.row ? qsTr("Stations that scan will start analysing footage for it (%1). The change is visible to everyone using this system.")
                                        .arg(root.scopeText(confirm.row.scope)) : ""
                    color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 13
                }
                Text {
                    width: parent.width; wrapMode: Text.WordWrap
                    text: !confirm.row ? ""
                          : root.known(confirm.row.cpuHoursPerDay)
                            ? qsTr("Projected load: about %1 CPU-hours per day across the stations that scan.").arg(root.num(confirm.row.cpuHoursPerDay, 1))
                            : qsTr("Nobody has measured its cost yet, so its load is unknown.")
                    color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13; font.weight: Font.Medium
                }
            }
            Row {
                id: cFoot
                anchors.right: parent.right; anchors.rightMargin: 22
                anchors.bottom: parent.bottom; anchors.bottomMargin: 18
                height: 28; spacing: 10
                Btn { label: qsTr("Cancel"); onClicked: confirm.visible = false }
                Btn {
                    label: qsTr("Switch on")
                    onClicked: { var s = confirm.row.slug; confirm.visible = false; root.labs.setAnalyzerEnabled(s, true) }
                }
            }
        }
    }
}
