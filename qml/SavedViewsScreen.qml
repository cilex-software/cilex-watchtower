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
        if (diff < 60000) return "Just now";
        var now = new Date(), then = new Date(t);
        if (now.toDateString() === then.toDateString()) return "Today";
        var days = Math.floor(diff / 86400000);
        if (days <= 1) return "Yesterday";
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
                Pill { label: "All views"; on: root.pill === "all"; onClicked: root.pill = "all" }
                Pill { label: "Mine"; on: root.pill === "mine"; onClicked: root.pill = "mine" }
                Pill { label: "Shared"; on: root.pill === "shared"; onClicked: root.pill = "shared" }
                Pill { label: "Favorites"; on: root.pill === "favorites"; onClicked: root.pill = "favorites" }
                Pill { label: "Contains issues"; on: root.pill === "issues"; onClicked: root.pill = "issues" }
                Item { Layout.fillWidth: true }
                // + Save current view (primary)
                Rectangle {
                    implicitWidth: scT.implicitWidth + 26; implicitHeight: 34
                    color: scMa.containsMouse ? "#f0b04e" : Theme.accent
                    Text { id: scT; anchors.centerIn: parent; text: "+ Save current view"; color: Theme.bg; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.DemiBold }
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
                            Grid {
                                anchors.fill: parent; anchors.margins: 4
                                columns: 4; rows: 4; spacing: 2
                                Repeater {
                                    model: 16
                                    Rectangle {
                                        required property int index
                                        width: (parent.width - 6) / 4
                                        height: (parent.height - 6) / 4
                                        // tint cells to reflect real issues in the view's scope
                                        color: index < Math.min(card.parent.issues, 16) ? "#1c1011"
                                             : (index === 9 && card.parent.issues > 0 ? "#1c1810" : "#14181d")
                                    }
                                }
                            }
                            // favorite + delete (top-right)
                            Row {
                                anchors.top: parent.top; anchors.right: parent.right; anchors.margins: 6; spacing: 2
                                IconButton {
                                    visible: cardMa.containsMouse
                                    name: "x"; iconSize: 12; iconColor: "#fff"; hoverIcon: Theme.bad
                                    bgColor: Qt.rgba(0,0,0,0.5); hoverBg: Qt.rgba(0,0,0,0.7); tip: "Delete view"
                                    onClicked: if (root.savedViewModel) root.savedViewModel.remove(modelData.viewId)
                                }
                                IconButton {
                                    name: "star"; iconSize: 13
                                    iconColor: modelData.favorite ? Theme.violet : "#fff"
                                    hoverIcon: Theme.violet; bgColor: Qt.rgba(0,0,0,0.5); hoverBg: Qt.rgba(0,0,0,0.7)
                                    tip: modelData.favorite ? "Unfavorite" : "Favorite"
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
                                Text { text: modelData.shared ? "Shared" : "Mine"; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11 }
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
                                Text { anchors.centerIn: parent; text: "Open"; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
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
                    text: (root.savedViewModel && root.savedViewModel.total > 0) ? "No views match this filter." : "No saved views yet."
                    color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 14 }
                Text { anchors.horizontalCenter: parent.horizontalCenter
                    visible: !(root.savedViewModel && root.savedViewModel.total > 0)
                    text: "Set up the Live Monitor, then “Save current view”."
                    color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12 }
            }
        }
    }
}
