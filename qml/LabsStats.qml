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
// Data: LabsModel.stats. Until the server has GET /labs/stats, "all" comes from
// /labs/pipeline and the two periods say they are waiting for the server. Colours are the
// analysers' own, as on the Playback timeline's Labs lane (LabsNames), so an analyser
// looks the same everywhere. Absent figures show as absent ("—"), never as 0.
Item {
    id: st

    property var labs: null
    property var screen: null                // LabsScreen: title(), num(), known()
    property string window: "24h"
    signal pickWindow(string w)

    readonly property var sdata: labs ? labs.stats : ({})
    readonly property string source: labs ? labs.statsState : ""
    readonly property var win: (sdata && sdata.windows) ? sdata.windows[window] : undefined
    readonly property var srows: win ? win.rows : []
    readonly property bool waitingForServer: source === "pipeline" && window !== "all"

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
                            bits.push(qsTr("in camera-hours, each analyser counted separately"))
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
                }
                Figure {
                    visible: !st.waitingForServer
                    readonly property var v: st.total("checked")
                    value: st.num(v)
                    unit: st.known(v) ? qsTr("h") : ""
                    label: qsTr("Checked")
                    tip: qsTr("Camera-hours the analysers have finished. An analyser may look at only part of each hour it checks.")
                }
                Figure {
                    visible: !st.waitingForServer
                    readonly property var v: st.total("waiting")
                    readonly property bool floor: st.someUnknown("waiting")
                    value: st.known(v) ? ((floor ? "≥ " : "") + st.num(v)) : "—"
                    unit: st.known(v) ? qsTr("h") : ""
                    label: qsTr("Waiting")
                    tip: floor ? qsTr("At least this much: the server has not counted the waiting footage of every analyser that is switched on")
                               : qsTr("Camera-hours of footage the analysers that are switched on have still to check")
                }
                Figure {
                    visible: !st.waitingForServer
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
            visible: !st.waitingForServer && st.srows.length > 0
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
            visible: !st.waitingForServer
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
                MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }

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
                                    bits.push(qsTr("%1 % checked").arg(st.num(pct, pct > 0 && pct < 10 ? 1 : 0)))
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
