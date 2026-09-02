import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as QC
import Watchtower

// Saved Views (S04 / design §4 + watchtower.html SavedViewsScreen). A 3-column
// card grid of reusable Live Monitor layouts. Each view stores restorable state
// (layout/filter/group) in SavedViewModel; per-card camera counts are computed
// live from CameraModel. Honest empty state when the operator has saved none
// (the mock set only appears under WT_DEMO).
Item {
    id: root

    property var savedViewModel: null
    property var cameraModel: null

    signal saveCurrentRequested()
    signal openView(var view)

    property string pill: "all"      // all | mine | shared | favorites | issues
    property var rows: []

    function countFor(v)  { return root.cameraModel ? root.cameraModel.countFiltered(v.groupId, v.statusFilter) : 0; }
    function onlineFor(v) { return root.cameraModel ? root.cameraModel.countFiltered(v.groupId, "online") : 0; }
    function issuesFor(v) { return root.cameraModel ? root.cameraModel.countFiltered(v.groupId, "issues") : 0; }
    function relTime(iso) {
        if (!iso) return "—";
        var t = Date.parse(iso);
        if (isNaN(t)) return "—";
        var diff = Date.now() - t;
        if (diff < 60000) return qsTr("Just now");
        var now = new Date(), then = new Date(t);
        if (now.toDateString() === then.toDateString()) return qsTr("Today");
        var days = Math.floor(diff / 86400000);
        if (days <= 1) return qsTr("Yesterday");
        if (days < 7) return days + " days ago";
        return Qt.formatDate(then, "MMM d");
    }

    function filtered() {
        var all = root.savedViewModel ? root.savedViewModel.list() : [];
        var out = [];
        for (var i = 0; i < all.length; i++) {
            var v = all[i];
            if (root.pill === "mine" && v.shared) continue;
            if (root.pill === "shared" && !v.shared) continue;
            if (root.pill === "favorites" && !v.favorite) continue;
            if (root.pill === "issues" && root.issuesFor(v) <= 0) continue;
            out.push(v);
        }
        return out;
    }
    function recompute() { root.rows = filtered(); }
    onPillChanged: recompute()
    Component.onCompleted: recompute()
    Connections {
        target: root.savedViewModel
        enabled: root.savedViewModel !== null
        function onChanged() { root.recompute() }
    }

    component Pill: Rectangle {
        id: p
        property string label: ""
        property bool on: false
        signal clicked()
        implicitHeight: 30
        implicitWidth: pt.implicitWidth + 24
        color: p.on ? Theme.accentSoft : (pma.containsMouse ? Theme.panel2 : Theme.panel)
        border.width: 1
        border.color: p.on ? Theme.accent : (pma.containsMouse ? Theme.ink3 : Theme.line2)
        Text { id: pt; anchors.centerIn: parent; text: p.label; color: p.on ? Theme.accent : Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
        MouseArea { id: pma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: p.clicked() }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // sub-bar
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 56
            color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 16; spacing: 6
                Pill { label: qsTr("All views"); on: root.pill === "all"; onClicked: root.pill = "all" }
                Pill { label: qsTr("Mine"); on: root.pill === "mine"; onClicked: root.pill = "mine" }
                Pill { label: qsTr("Shared"); on: root.pill === "shared"; onClicked: root.pill = "shared" }
                Pill { label: qsTr("Favorites"); on: root.pill === "favorites"; onClicked: root.pill = "favorites" }
                Pill { label: qsTr("Contains issues"); on: root.pill === "issues"; onClicked: root.pill = "issues" }
                Item { Layout.fillWidth: true }
                // + Save current view (primary)
                Rectangle {
                    implicitWidth: scT.implicitWidth + 26; implicitHeight: 34
                    color: scMa.containsMouse ? "#f0b04e" : Theme.accent
                    Text { id: scT; anchors.centerIn: parent; text: qsTr("+ Save current view"); color: Theme.bg; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.DemiBold }
                    MouseArea { id: scMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.saveCurrentRequested() }
                }
            }
        }

        // card grid
        GridView {
            id: grid
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            leftMargin: 14; topMargin: 14; rightMargin: 14; bottomMargin: 14
            cellWidth: Math.floor((width - 28) / 3)
            cellHeight: Math.floor((cellWidth - 12) * 10 / 16) + 112
            model: root.rows
            boundsBehavior: Flickable.StopAtBounds
            QC.ScrollBar.vertical: QC.ScrollBar { }

            delegate: Item {
                required property var modelData
                width: grid.cellWidth
                height: grid.cellHeight
                readonly property int issues: root.issuesFor(modelData)

                Rectangle {
                    id: card
                    width: parent.width - 12
                    height: parent.height - 12
                    color: Theme.panel
                    border.width: 1
                    border.color: cardMa.containsMouse ? Theme.line2 : Theme.line

                    MouseArea { id: cardMa; anchors.fill: parent; hoverEnabled: true }

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 0

                        // 16:10 status mosaic
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: width * 10 / 16
                            color: "#000"
                            // Exact net of THIS view's saved layout (shared LayoutSpec —
                            // same enumeration NetIcon draws), so e.g. "Center + 12" reads
                            // as a big centre tile + 12-cell ring at a glance, not a generic
                            // 4×4. The centre/big tile is accent-emphasised; cells tint to
                            // reflect real issues in the view's scope.
                            Item {
                                id: net
                                anchors.fill: parent; anchors.margins: 4
                                // MERGED CELLS WIN over the layout's canonical net. A view
                                // saved with big tiles used to draw here as a plain grid,
                                // because the card only ever knew the layout id — which is
                                // how the operator discovered (2026-09-02) that merges were
                                // not part of a view at all. `spans` is captured at save
                                // time; absent or unparseable falls back to the plain net.
                                readonly property var sp: {
                                    if (!modelData.spans || modelData.spans.length === 0) return null;
                                    try {
                                        var s = JSON.parse(modelData.spans);
                                        return (s && s.cols > 0 && s.rows > 0
                                                && s.regions && s.regions.length > 0) ? s : null;
                                    } catch (e) { return null; }
                                }
                                // Same row-major enumeration LiveMonitor uses (_spanCells):
                                // a merged region is emitted once, at its anchor cell, and
                                // the cells it covers are skipped — so the card is the same
                                // picture the wall draws, not an approximation of it.
                                readonly property var spCells: {
                                    if (!net.sp) return null;
                                    var covered = ({}), at = ({}), i, c, r;
                                    for (i = 0; i < net.sp.regions.length; i++) {
                                        var g = net.sp.regions[i];
                                        at[g.c + "," + g.r] = g;
                                        for (c = g.c; c < g.c + g.cw; c++)
                                            for (r = g.r; r < g.r + g.ch; r++) covered[c + "," + r] = true;
                                    }
                                    var out = [];
                                    for (r = 0; r < net.sp.rows; r++)
                                        for (c = 0; c < net.sp.cols; c++) {
                                            var reg = at[c + "," + r];
                                            if (reg) out.push({ c: reg.c, r: reg.r, cw: reg.cw, ch: reg.ch });
                                            else if (!covered[c + "," + r]) out.push({ c: c, r: r, cw: 1, ch: 1 });
                                        }
                                    return out;
                                }
                                readonly property var lp: net.sp ? { cols: net.sp.cols, rows: net.sp.rows, big: false }
                                                                 : LayoutSpec.params(modelData.layout)
                                readonly property int cellCount: net.spCells ? net.spCells.length
                                                                             : LayoutSpec.count(modelData.layout)
                                readonly property real gap: 2
                                readonly property real uw: (width - net.gap * (net.lp.cols - 1)) / net.lp.cols
                                readonly property real uh: (height - net.gap * (net.lp.rows - 1)) / net.lp.rows
                                Repeater {
                                    model: net.spCells ? net.spCells : LayoutSpec.cells(modelData.layout)
                                    Rectangle {
                                        required property int index
                                        required property var modelData   // cell { c, r, cw, ch }
                                        // With merges, "big" means any region larger than one
                                        // cell — that is what the operator merged and what
                                        // should read as emphasised at a glance.
                                        readonly property bool isBig: net.sp ? (modelData.cw > 1 || modelData.ch > 1)
                                                                             : (net.lp.big && index === 0)
                                        readonly property bool isIssue: index < Math.min(card.parent.issues, net.cellCount)
                                        x: modelData.c * (net.uw + net.gap)
                                        y: modelData.r * (net.uh + net.gap)
                                        width: modelData.cw * net.uw + (modelData.cw - 1) * net.gap
                                        height: modelData.ch * net.uh + (modelData.ch - 1) * net.gap
                                        radius: 1
                                        color: isIssue ? "#1c1011"
                                             : (isBig ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.12) : "#14181d")
                                        border.width: isBig ? 1 : 0
                                        border.color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.35)
                                    }
                                }
                            }
                            // favorite + delete (top-right)
                            Row {
                                anchors.top: parent.top; anchors.right: parent.right; anchors.margins: 6; spacing: 2
                                IconButton {
                                    visible: cardMa.containsMouse
                                    name: "x"; iconSize: 12; iconColor: "#fff"; hoverIcon: Theme.bad
                                    bgColor: Qt.rgba(0,0,0,0.5); hoverBg: Qt.rgba(0,0,0,0.7); tip: qsTr("Delete view")
                                    onClicked: if (root.savedViewModel) root.savedViewModel.remove(modelData.viewId)
                                }
                                IconButton {
                                    name: "star"; iconSize: 13
                                    iconColor: modelData.favorite ? Theme.violet : "#fff"
                                    hoverIcon: Theme.violet; bgColor: Qt.rgba(0,0,0,0.5); hoverBg: Qt.rgba(0,0,0,0.7)
                                    tip: modelData.favorite ? qsTr("Unfavorite") : qsTr("Favorite")
                                    onClicked: if (root.savedViewModel) root.savedViewModel.toggleFavorite(modelData.viewId)
                                }
                            }
                        }

                        // body
                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.margins: 12
                            spacing: 4
                            Text { text: modelData.name; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13; font.weight: Font.DemiBold; elide: Text.ElideRight; Layout.fillWidth: true }
                            Row {
                                spacing: 10
                                Text { text: modelData.shared ? qsTr("Shared") : qsTr("Mine"); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11 }
                                Text { text: LayoutSpec.label(modelData.layout); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11 }
                                Text { text: root.countFor(modelData) + " cams"; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11 }
                            }
                            RowLayout {
                                Layout.fillWidth: true; Layout.topMargin: 2; spacing: 6
                                Text { text: root.onlineFor(modelData) + " online"; color: Theme.good; font.family: Theme.fontSans; font.pixelSize: 11 }
                                Text { visible: card.parent.issues > 0; text: "· " + card.parent.issues + (card.parent.issues > 1 ? " issues" : " issue"); color: Theme.bad; font.family: Theme.fontSans; font.pixelSize: 11 }
                                Item { Layout.fillWidth: true }
                                Text { text: root.relTime(modelData.lastUsedIso); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
                            }
                            // Open
                            Rectangle {
                                Layout.fillWidth: true; Layout.topMargin: 6; implicitHeight: 30
                                color: openMa.containsMouse ? Theme.panel2 : Theme.bg
                                border.width: 1; border.color: openMa.containsMouse ? Theme.accent : Theme.line2
                                Text { anchors.centerIn: parent; text: qsTr("Open"); color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
                                MouseArea { id: openMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.openView(modelData) }
                            }
                        }
                        Item { Layout.fillHeight: true }
                    }
                }
            }

            // empty state
            Column {
                anchors.centerIn: parent
                spacing: 8
                visible: root.rows.length === 0
                Icon { anchors.horizontalCenter: parent.horizontalCenter; name: "grid"; size: 30; color: Theme.ink3 }
                Text { anchors.horizontalCenter: parent.horizontalCenter
                    text: (root.savedViewModel && root.savedViewModel.total > 0) ? qsTr("No views match this filter.") : qsTr("No saved views yet.")
                    color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 14 }
                Text { anchors.horizontalCenter: parent.horizontalCenter
                    visible: !(root.savedViewModel && root.savedViewModel.total > 0)
                    text: qsTr("Set up the Live Monitor, then “Save current view”.")
                    color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12 }
            }
        }
    }
}
