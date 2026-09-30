import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as QC
import Watchtower

// Labs statistics (operator request 2026-09-28): for each analyser, how much of the footage
// recorded in a period it has CHECKED, how much is still WAITING, and what it FOUND -- for
// the last 24 hours, the last 7 days, or all footage.
//
// Operator decisions, same day (LabsStatsData.h has the detail):
//   * a period means FOOTAGE RECORDED in it, so each bar is a true progress bar: checked +
//     in progress + waiting + given up = all of that footage;
//   * an event is a FINDING, a record where the analyser found something. Which records
//     are findings is cilex-vision's rule, per analyser.
//
// BY CAMERA (the operator, 2026-09-30): one row per camera, busiest first. Its line is the
// camera's records split by analyser -- each colour an analyser, the line normalised to 100 %
// of that camera -- and its total, with a bar against the busiest camera, is on the right.
// An event here is any RECORD an analyser filed (the operator's choice). The per-camera
// counts are the server's (`records_by_camera`, asked 2026-09-30); until it gives them the
// mode says so, and nothing is estimated from other figures.
//
// Data: LabsModel.stats. Until the server has GET /labs/stats, "all" comes from
// /labs/pipeline and the two periods say they are waiting for the server. Colours are the
// analysers' own, as on the Playback timeline's Labs lane (LabsNames), so an analyser
// looks the same everywhere. Absent figures show as absent ("—"), never as 0.
Item {
    id: st

    property var labs: null
    property var screen: null                // LabsScreen: title(), num(), known()
    property string window: "24h"
    property string by: "analyser"           // "analyser" | "camera" (LabsScreen.statsBy)
    property var cameraModel: null           // camera names are this station's own
    signal pickWindow(string w)
    signal pickBy(string b)
    // An analyser clicked: open the list of its findings, to watch (LabsFindings).
    signal openFindings(string slug)

    readonly property var sdata: labs ? labs.stats : ({})
    readonly property string source: labs ? labs.statsState : ""
    readonly property var win: (sdata && sdata.windows) ? sdata.windows[window] : undefined
    readonly property var srows: win ? win.rows : []
    readonly property bool waitingForServer: source === "pipeline" && window !== "all"
    readonly property bool byCam: by === "camera"
    readonly property bool camCounted: !!(win && win.byCamera)
    readonly property var cams: (win && win.cameras) ? win.cameras : []
    readonly property real maxCamRecords: {
        var m = 0
        for (var i = 0; i < cams.length; i++) m = Math.max(m, cams[i].records)
        return m
    }
    readonly property real camTotal: {
        var t = 0
        for (var i = 0; i < cams.length; i++) t += cams[i].records
        return t
    }
    // The analysers that filed anything in this period, in the window's order: the legend.
    readonly property var camLegend: {
        var out = [], seen = ({})
        for (var i = 0; i < cams.length; i++) {
            var ps = cams[i].parts
            for (var j = 0; j < ps.length; j++)
                if (ps[j].records > 0) seen[ps[j].slug] = true
        }
        for (var k = 0; k < srows.length; k++)
            if (seen[srows[k].slug]) out.push(srows[k].slug)
        return out
    }
    // camera id -> {name, ip}, from this station's camera list (names are the operator's own).
    property var camLookup: ({})
    function _buildLookup() {
        var lk = ({})
        var n = cameraModel ? cameraModel.total : 0
        for (var i = 0; i < n; i++) {
            var c = cameraModel.get(i)
            if (!c || !c.camId) continue
            lk[c.camId] = { name: c.name ? c.name : c.camId, ip: c.ip ? c.ip : "" }
        }
        camLookup = lk
    }
    onVisibleChanged: if (visible) _buildLookup()
    onCameraModelChanged: _buildLookup()
    Component.onCompleted: _buildLookup()
    // The camera list can arrive after this view is shown (the Labs screen opened at start, or
    // before the list has loaded): names follow it, never stay as bare ids.
    Connections {
        target: st.cameraModel
        ignoreUnknownSignals: true
        function onCountsChanged() { st._buildLookup() }
    }
    function camName(id) { var c = camLookup[id]; return c ? c.name : id }
    function camIp(id) { var c = camLookup[id]; return c ? c.ip : "" }
    // "77 %", "< 1 %": a share too small to show is never "0 %" (it is not none).
    function pct(part, whole) {
        if (!(whole > 0)) return "—"
        var v = 100 * part / whole
        return (v > 0 && v < 1) ? "< 1 %" : Math.round(v) + " %"
    }

    readonly property int wName: 260
    readonly property int wFind: 230

    function known(v) { return screen ? screen.known(v) : (v !== undefined && v !== null) }
    function num(v, d) { return screen ? screen.num(v, d) : (known(v) ? String(v) : "—") }
    function built(r) { return r.slug !== "image_embedding" }
    function total(key) {
        var s = 0, any = false
        for (var i = 0; i < srows.length; i++)
            if (known(srows[i][key])) { s += srows[i][key]; any = true }
        return any ? s : null
    }
    // "At least": an analyser that runs has no figure for it, so the sum is a floor.
    function someUnknown(key) {
        for (var i = 0; i < srows.length; i++)
            if (built(srows[i]) && srows[i].enabled && !known(srows[i][key])) return true
        return false
    }
    readonly property real maxFindings: {
        var m = 0
        for (var i = 0; i < srows.length; i++)
            if (known(srows[i].findings)) m = Math.max(m, srows[i].findings)
        return m
    }
    readonly property string caption: window === "24h" ? qsTr("Footage recorded in the last 24 hours")
                                    : window === "7d" ? qsTr("Footage recorded in the last 7 days")
                                    : qsTr("All footage")
    readonly property string asOf: {
        var t = sdata ? (sdata.computedAt || sdata.generatedAt) : ""
        return t ? Qt.formatTime(new Date(t), "HH:mm") : ""
    }

    component Label10: Text {
        color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
        font.weight: Font.DemiBold; font.letterSpacing: 1.2; font.capitalization: Font.AllUppercase
    }
    component Figure: Item {
        id: fig
        property string value: "—"
        property string unit: ""
        property string label: ""
        property string tip: ""
        implicitWidth: Math.max(figRow.implicitWidth, figLabel.implicitWidth) + 36
        implicitHeight: 60
        Column {
            anchors.left: parent.left; anchors.leftMargin: 18; anchors.verticalCenter: parent.verticalCenter
            spacing: 6
            Row {
                id: figRow
                spacing: 5
                Text { id: figVal; text: fig.value; color: fig.value === "—" ? Theme.ink3 : Theme.ink
                       font.family: Theme.fontSans; font.pixelSize: 24; font.weight: Font.Bold; font.letterSpacing: -0.6 }
                Text { visible: fig.unit !== ""; anchors.baseline: figVal.baseline
                       text: fig.unit; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11 }
            }
            Label10 { id: figLabel; text: fig.label }
        }
        Rectangle { anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom; anchors.topMargin: 12; anchors.bottomMargin: 12; width: 1; color: Theme.line }
        MouseArea { id: figMa; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
        QC.ToolTip.visible: fig.tip !== "" && figMa.containsMouse
        QC.ToolTip.text: fig.tip
        QC.ToolTip.delay: 300
    }
    component Swatch: Row {
        property color swatch: Theme.ink3
        property string label: ""
        spacing: 6
        Rectangle { width: 10; height: 10; anchors.verticalCenter: parent.verticalCenter; color: parent.swatch }
        Text { text: parent.label; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ===== the period, and its totals =====
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 76
            color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 18
                spacing: 0
                Column {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 5
                    Text { text: st.caption; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 15; font.weight: Font.DemiBold }
                    Text {
                        width: parent.width - 12; elide: Text.ElideRight
                        text: {
                            var bits = []
                            if (st.waitingForServer) return ""      // nothing here is counted yet
                            if (st.asOf) bits.push(qsTr("counted at %1").arg(st.asOf))
                            bits.push(st.byCam ? qsTr("records per camera, each line split by analyser")
                                               : qsTr("in camera-hours, each analyser counted separately"))
                            if (st.source === "pipeline" && st.window === "all")
                                bits.push(qsTr("until the server counts by period: from the analyser list"))
                            return bits.join("  ·  ")
                        }
                        color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                    }
                    Text {
                        visible: st.labs !== null && st.labs.statsError !== ""
                        text: st.labs ? qsTr("statistics: %1").arg(st.labs.statsError) : ""
                        color: Theme.warn; font.family: Theme.fontMono; font.pixelSize: 10
                    }
                    Text {
                        visible: st.byCam && st.camCounted && st.win && st.win.camerasAddUp === false
                        text: qsTr("the server's counts by camera do not add up to its totals for every analyser")
                        color: Theme.warn; font.family: Theme.fontMono; font.pixelSize: 10
                    }
                }
                Figure {
                    visible: !st.waitingForServer && st.byCam && st.camCounted
                    value: st.num(st.camTotal)
                    label: qsTr("Records")
                    tip: qsTr("Every record the analysers filed from the footage of this period, all cameras together")
                }
                Figure {
                    visible: !st.waitingForServer && st.byCam && st.camCounted
                    value: st.num(st.cams.length)
                    label: qsTr("Cameras")
                    tip: qsTr("Cameras with at least one record in this period. A camera kept out of Labs is not counted.")
                }
                Figure {
                    visible: !st.waitingForServer && !st.byCam
                    readonly property var v: st.total("checked")
                    value: st.num(v)
                    unit: st.known(v) ? qsTr("h") : ""
                    label: qsTr("Checked")
                    tip: qsTr("Camera-hours the analysers have finished. An analyser may look at only part of each hour it checks.")
                }
                Figure {
                    visible: !st.waitingForServer && !st.byCam
                    readonly property var v: st.total("waiting")
                    readonly property bool floor: st.someUnknown("waiting")
                    value: st.known(v) ? ((floor ? "≥ " : "") + st.num(v)) : "—"
                    unit: st.known(v) ? qsTr("h") : ""
                    label: qsTr("Waiting")
                    tip: floor ? qsTr("At least this much: the server has not counted the waiting footage of every analyser that is switched on")
                               : qsTr("Camera-hours of footage the analysers that are switched on have still to check")
                }
                Figure {
                    visible: !st.waitingForServer && !st.byCam
                    readonly property var v: st.total("findings")
                    readonly property bool floor: st.someUnknown("findings")
                    value: st.known(v) ? ((floor ? "≥ " : "") + st.num(v)) : "—"
                    label: qsTr("Findings")
                    tip: st.known(v) ? qsTr("Records where an analyser found something. Routine readings are not counted.")
                                     : qsTr("Which records count as findings is the server's rule, and it does not give them yet")
                }
            }
        }

        // ===== column heads, and what the colours mean =====
        Rectangle {
            visible: !st.waitingForServer && !st.byCam && st.srows.length > 0
            Layout.fillWidth: true
            Layout.preferredHeight: 34
            color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 18
                spacing: 0
                Label10 { Layout.preferredWidth: st.wName; text: qsTr("Analyser") }
                Row {
                    Layout.fillWidth: true
                    spacing: 16
                    Swatch { swatch: Theme.ink2; label: qsTr("checked") }
                    Swatch { swatch: Qt.rgba(Theme.ink2.r, Theme.ink2.g, Theme.ink2.b, 0.4); label: qsTr("in progress") }
                    Swatch { swatch: Theme.line2; label: qsTr("waiting") }
                    Swatch { visible: st.source === "server"; swatch: Theme.bad; label: qsTr("given up") }
                }
                Label10 { Layout.preferredWidth: st.wFind; text: qsTr("Findings") }
            }
        }

        // ===== one row per analyser =====
        ListView {
            id: list
            visible: !st.waitingForServer && !st.byCam
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: st.srows
            boundsBehavior: Flickable.StopAtBounds
            QC.ScrollBar.vertical: QC.ScrollBar { policy: QC.ScrollBar.AsNeeded }

            delegate: Rectangle {
                id: row
                required property var modelData
                readonly property var r: modelData
                readonly property bool isBuilt: st.built(r)
                readonly property color hue: isBuilt ? LabsNames.color(r.slug) : Theme.ink3
                width: ListView.view.width
                height: 60
                color: rowMa.containsMouse ? Theme.panel : "transparent"
                Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
                MouseArea {
                    id: rowMa; anchors.fill: parent; hoverEnabled: true
                    cursorShape: row.isBuilt ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: if (row.isBuilt) st.openFindings(row.r.slug)
                }
                QC.ToolTip.visible: row.isBuilt && rowMa.containsMouse
                QC.ToolTip.text: qsTr("Open its findings, to watch them")
                QC.ToolTip.delay: 600

                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 18
                    spacing: 0

                    // ---- the analyser
                    Column {
                        Layout.preferredWidth: st.wName
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 4
                        Row {
                            spacing: 8
                            Rectangle { width: 10; height: 10; anchors.verticalCenter: parent.verticalCenter; color: row.hue }
                            Text { text: st.screen ? st.screen.title(row.r.slug) : row.r.slug
                                   color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13; font.weight: Font.DemiBold }
                        }
                        Text {
                            leftPadding: 18
                            text: !row.isBuilt ? qsTr("not built yet") : (row.r.enabled ? "" : qsTr("switched off"))
                            visible: text !== ""
                            color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                        }
                    }

                    // ---- checked | in progress | waiting | given up
                    Column {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        Layout.rightMargin: 24
                        spacing: 7
                        visible: row.isBuilt
                        Item {
                            id: barBox
                            width: parent.width
                            height: 12
                            // Given up is a segment only where the server counts it; before
                            // /labs/stats it is unknown, and the bar is drawn without it
                            // rather than with a guessed one.
                            readonly property var vals: st.known(row.r.givenUp)
                                ? [row.r.checked, row.r.inProgress, row.r.waiting, row.r.givenUp]
                                : [row.r.checked, row.r.inProgress, row.r.waiting]
                            readonly property var widths: (st.labs && width > 0) ? st.labs.barWidths(vals, width, 3) : []
                            readonly property var colors: [row.hue, Qt.rgba(row.hue.r, row.hue.g, row.hue.b, 0.4), Theme.line2, Theme.bad]
                            // No outline when there is no bar: an empty outline reads as "0 %
                            // done", and "not counted" is not that. The line below says why.
                            Row {
                                Repeater {
                                    model: barBox.widths.length
                                    delegate: Rectangle {
                                        required property int index
                                        width: barBox.widths[index]; height: barBox.height
                                        color: barBox.colors[index]
                                    }
                                }
                            }
                            MouseArea { id: barMa; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                            QC.ToolTip.visible: barMa.containsMouse && tipText !== ""
                            QC.ToolTip.delay: 300
                            readonly property string tipText: {
                                var t = []
                                if (st.known(row.r.segmentsScanned)) t.push(qsTr("%1 segments read").arg(st.num(row.r.segmentsScanned)))
                                if (st.known(row.r.records)) t.push(qsTr("%1 records filed").arg(st.num(row.r.records)))
                                if (st.source === "pipeline")
                                    t.push(qsTr("Waiting can include failed hours, some of which will not be tried again: the server does not say which yet."))
                                return t.join(" · ")
                            }
                            QC.ToolTip.text: tipText
                        }
                        Text {
                            width: parent.width; elide: Text.ElideRight
                            text: {
                                var r = row.r, bits = []
                                bits.push(qsTr("checked %1 h").arg(st.num(r.checked)))
                                if (st.known(r.inProgress) && r.inProgress > 0) bits.push(qsTr("in progress %1").arg(st.num(r.inProgress)))
                                if (st.known(r.waiting)) bits.push(qsTr("waiting %1 h").arg(st.num(r.waiting)))
                                else bits.push(r.enabled ? qsTr("waiting not counted yet") : qsTr("waiting not counted while switched off"))
                                if (st.known(r.givenUp) && r.givenUp > 0) bits.push(qsTr("given up %1").arg(st.num(r.givenUp)))
                                if (!st.known(r.givenUp) && st.known(r.failed) && r.failed > 0) bits.push(qsTr("%1 failed").arg(st.num(r.failed)))
                                if (st.known(r.cameraHours) && r.cameraHours > 0 && st.known(r.checked)) {
                                    var pct = 100 * r.checked / r.cameraHours
                                    // A share too small to show at one decimal is "< 0.1", never "0.0":
                                    // 12 hours checked must not read as none (seen live, 2026-09-28).
                                    var shown = (pct > 0 && pct < 0.1) ? "< " + st.num(0.1, 1)
                                              : st.num(pct, pct > 0 && pct < 10 ? 1 : 0)
                                    bits.push(qsTr("%1 % checked").arg(shown))
                                }
                                if (st.window === "all" && st.known(r.checkedEver) && st.known(r.checked) && r.checkedEver > r.checked)
                                    bits.push(qsTr("%1 h checked in all, footage since deleted included").arg(st.num(r.checkedEver)))
                                return bits.join("  ·  ")
                            }
                            color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11
                        }
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: !row.isBuilt
                        text: "—"; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11
                    }

                    // ---- findings
                    Column {
                        Layout.preferredWidth: st.wFind
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 6
                        Row {
                            spacing: 6
                            Text { id: fVal; text: st.num(row.r.findings)
                                   color: st.known(row.r.findings) ? Theme.ink : Theme.ink3
                                   font.family: Theme.fontSans; font.pixelSize: 16; font.weight: Font.Bold }
                            Text {
                                anchors.baseline: fVal.baseline
                                text: !row.isBuilt ? ""
                                    : !st.known(row.r.findings) ? qsTr("waiting for the server")
                                    : st.known(row.r.records) ? qsTr("in %1 records").arg(st.num(row.r.records)) : ""
                                color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                            }
                        }
                        Rectangle {
                            visible: st.known(row.r.findings) && st.maxFindings > 0
                            width: !visible ? 0 : Math.max(row.r.findings > 0 ? 2 : 0, (st.wFind - 24) * row.r.findings / st.maxFindings)
                            height: 4
                            color: row.hue
                        }
                    }
                }
            }

            Text {
                anchors.centerIn: parent
                visible: list.count === 0
                text: (!st.labs || st.labs.loading) ? qsTr("Asking the server…") : qsTr("No answer from the server yet")
                color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 13
            }
        }

        // ===== BY CAMERA: column heads, and which colour is which analyser =====
        Rectangle {
            visible: !st.waitingForServer && st.byCam && st.camCounted && st.cams.length > 0
            Layout.fillWidth: true
            Layout.preferredHeight: Math.max(34, legendFlow.implicitHeight + 18)
            color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 18
                spacing: 0
                Label10 { Layout.preferredWidth: st.wName; text: qsTr("Camera") }
                Flow {
                    id: legendFlow
                    Layout.fillWidth: true
                    Layout.rightMargin: 24
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 14
                    Repeater {
                        model: st.camLegend
                        delegate: Swatch {
                            required property var modelData
                            swatch: LabsNames.color(modelData)
                            label: st.screen ? st.screen.title(modelData) : modelData
                        }
                    }
                }
                Label10 { Layout.preferredWidth: st.wFind; text: qsTr("Records") }
            }
        }

        // ===== BY CAMERA: one row per camera, busiest first =====
        ListView {
            id: camList
            visible: !st.waitingForServer && st.byCam && st.camCounted
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: st.cams
            boundsBehavior: Flickable.StopAtBounds
            QC.ScrollBar.vertical: QC.ScrollBar { policy: QC.ScrollBar.AsNeeded }

            delegate: Rectangle {
                id: crow
                required property var modelData
                readonly property var c: modelData
                // Its analysers, largest share first: the words under the line, and its tooltip.
                readonly property var shares: {
                    var out = []
                    for (var i = 0; i < c.parts.length; i++)
                        if (c.parts[i].records > 0) out.push(c.parts[i])
                    out.sort(function (a, b) { return b.records - a.records })
                    return out
                }
                width: ListView.view.width
                height: 60
                color: "transparent"
                Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }

                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 18
                    spacing: 0

                    // ---- the camera: its name here, and its address (two cameras can share a name)
                    Column {
                        Layout.preferredWidth: st.wName
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 4
                        Text {
                            width: st.wName - 16; elide: Text.ElideRight
                            text: st.camName(crow.c.cameraId)
                            color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13; font.weight: Font.DemiBold
                        }
                        Text {
                            width: st.wName - 16; elide: Text.ElideRight
                            // The address tells two cameras with one name apart; a camera this
                            // station does not know shows its id once, as its name, not twice.
                            visible: text !== ""
                            text: st.camIp(crow.c.cameraId) !== "" ? st.camIp(crow.c.cameraId)
                                : (st.camName(crow.c.cameraId) !== crow.c.cameraId ? crow.c.cameraId : "")
                            color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                        }
                    }

                    // ---- its records, split by analyser: the whole line is this camera (100 %)
                    Column {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        Layout.rightMargin: 24
                        spacing: 7
                        Item {
                            id: cbar
                            width: parent.width
                            height: 12
                            readonly property var vals: {
                                var v = []
                                for (var i = 0; i < crow.c.parts.length; i++) v.push(crow.c.parts[i].records)
                                return v
                            }
                            readonly property var widths: (st.labs && width > 0) ? st.labs.barWidths(vals, width, 3) : []
                            Row {
                                Repeater {
                                    model: cbar.widths.length
                                    delegate: Rectangle {
                                        required property int index
                                        width: cbar.widths[index]; height: cbar.height
                                        color: LabsNames.color(crow.c.parts[index].slug)
                                    }
                                }
                            }
                            MouseArea { id: cbarMa; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
                            QC.ToolTip.visible: cbarMa.containsMouse
                            QC.ToolTip.delay: 300
                            QC.ToolTip.text: {
                                var t = []
                                for (var i = 0; i < crow.shares.length; i++) {
                                    var p = crow.shares[i]
                                    t.push(qsTr("%1: %2 records, %3").arg(st.screen ? st.screen.title(p.slug) : p.slug)
                                                                      .arg(st.num(p.records)).arg(st.pct(p.records, crow.c.records)))
                                }
                                return t.join("\n")
                            }
                        }
                        Text {
                            width: parent.width; elide: Text.ElideRight
                            text: {
                                var bits = []
                                for (var i = 0; i < crow.shares.length; i++)
                                    bits.push((st.screen ? st.screen.title(crow.shares[i].slug) : crow.shares[i].slug)
                                              + " " + st.pct(crow.shares[i].records, crow.c.records))
                                return bits.join("  ·  ")
                            }
                            color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11
                        }
                    }

                    // ---- how many, against the busiest camera
                    Column {
                        Layout.preferredWidth: st.wFind
                        Layout.alignment: Qt.AlignVCenter
                        spacing: 6
                        Row {
                            spacing: 6
                            Text {
                                id: cVal
                                text: st.num(crow.c.records)
                                color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 16; font.weight: Font.Bold
                            }
                            Text {
                                anchors.baseline: cVal.baseline
                                text: qsTr("%1 of all").arg(st.pct(crow.c.records, st.camTotal))
                                color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                            }
                        }
                        Rectangle {
                            visible: st.maxCamRecords > 0
                            width: !visible ? 0 : Math.max(crow.c.records > 0 ? 2 : 0, (st.wFind - 24) * crow.c.records / st.maxCamRecords)
                            height: 4
                            color: Theme.ink2
                        }
                    }
                }
            }

            Text {
                anchors.centerIn: parent
                visible: camList.count === 0
                text: qsTr("No camera has any records in this period")
                color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 13
            }
        }

        // ===== BY CAMERA, before the server counts by camera (or before any answer) =====
        Item {
            visible: !st.waitingForServer && st.byCam && !st.camCounted
            Layout.fillWidth: true
            Layout.fillHeight: true
            Column {
                anchors.centerIn: parent
                width: Math.min(560, parent.width - 48)
                spacing: 12
                Text {
                    width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                    text: !st.win ? ((!st.labs || st.labs.loading) ? qsTr("Asking the server…") : qsTr("No answer from the server yet"))
                                  : qsTr("The server does not count by camera yet")
                    color: st.win ? Theme.ink : Theme.ink3
                    font.family: Theme.fontSans; font.pixelSize: st.win ? 15 : 13; font.weight: st.win ? Font.DemiBold : Font.Normal
                }
                Text {
                    visible: !!st.win
                    width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                    text: qsTr("How many records each camera produced, analyser by analyser, is a count only cilex-vision can make. It was asked for on 30 September, and this view fills in as soon as the server has it. Nothing here is estimated.")
                    color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 13; lineHeight: 1.2
                }
                Text {
                    visible: !!st.win
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: qsTr("Show by analyser")
                    color: byAnMa.containsMouse ? Theme.accent : Theme.ink2
                    font.family: Theme.fontMono; font.pixelSize: 11; font.weight: Font.DemiBold; font.underline: byAnMa.containsMouse
                    MouseArea { id: byAnMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: st.pickBy("analyser") }
                }
            }
        }

        // ===== a period the server does not count yet =====
        Item {
            visible: st.waitingForServer
            Layout.fillWidth: true
            Layout.fillHeight: true
            Column {
                anchors.centerIn: parent
                width: Math.min(560, parent.width - 48)
                spacing: 12
                Text {
                    width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                    text: qsTr("The server does not count by period yet")
                    color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 15; font.weight: Font.DemiBold
                }
                Text {
                    width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                    text: qsTr("How much of the last 24 hours or 7 days of footage has been checked, and what was found in it, is a count only cilex-vision can make. It was asked for on 28 September, and this view fills in as soon as the server has it. Nothing here is estimated.")
                    color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 13; lineHeight: 1.2
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: qsTr("Show all footage")
                    color: allMa.containsMouse ? Theme.accent : Theme.ink2
                    font.family: Theme.fontMono; font.pixelSize: 11; font.weight: Font.DemiBold; font.underline: allMa.containsMouse
                    MouseArea { id: allMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: st.pickWindow("all") }
                }
            }
        }
    }
}
