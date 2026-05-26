import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C
import QtQuick.Dialogs
import Watchtower

// Live Monitor (design §14): grid of live tiles with a layout segmented control,
// filter pills, status-first sort, manual paging, and a full-screen variant.
// View state is owned by the shell and passed in; this screen requests changes.
Item {
    id: root

    property var cameraModel: null
    property int layoutSize: 16          // cameras per page (1 / 4 / 9 / 16)
    property int page: 1
    property string statusFilter: ""
    property string sortMode: "default"
    property string groupId: ""
    property string groupLabel: "All cameras"
    property bool fullscreen: false

    signal layoutRequested(int size)
    signal pageRequested(int p)
    signal statusFilterRequested(string f)
    signal sortRequested(string s)
    signal fullscreenToggled()
    signal saveViewRequested()
    signal snapshotSaved(string path, string camName)
    signal cameraOpened(var cam)

    readonly property int cols: Math.round(Math.sqrt(layoutSize))
    readonly property int total: cameraModel ? cameraModel.countFiltered(groupId, statusFilter) : 0
    readonly property int pageCount: Math.max(1, Math.ceil(total / layoutSize))
    readonly property var pagedCameras: cameraModel
        ? cameraModel.page(groupId, statusFilter, sortMode, page, layoutSize) : []
    readonly property string rangeText: {
        if (total === 0)
            return "0 of 0";
        const start = (page - 1) * layoutSize + 1;
        const end = Math.min(page * layoutSize, total);
        return start + "–" + end + " of " + total;
    }

    readonly property var sortLabels: ({ "default": "Layout order", "status": "Status first", "alpha": "Alphabetical" })

    FileDialog {
        id: importDialog
        title: "Import cameras — Cilex Provisioner export"
        nameFilters: ["Provisioning JSON (*.json)", "All files (*)"]
        onAccepted: { if (root.cameraModel) root.cameraModel.importProvisioning(importDialog.selectedFile); }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---------------------------------------------------------- sub-bar
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: Theme.subBarHeight
            visible: !root.fullscreen
            color: Theme.bg
            Rectangle {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: 1; color: Theme.line
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 20
                anchors.rightMargin: 20
                spacing: 12

                // layout segmented control
                Rectangle {
                    Layout.preferredHeight: 38
                    implicitWidth: segRow.implicitWidth
                    color: Theme.panel
                    border.width: 1
                    border.color: Theme.line2
                    Row {
                        id: segRow
                        height: 38
                        Repeater {
                            model: [
                                { lbl: "1",   n: 1 },
                                { lbl: "2×2", n: 4 },
                                { lbl: "3×3", n: 9 },
                                { lbl: "4×4", n: 16 }
                            ]
                            delegate: Item {
                                id: seg
                                required property var modelData
                                required property int index
                                width: 46
                                height: 38
                                readonly property bool active: root.layoutSize === modelData.n
                                Rectangle {
                                    anchors.fill: parent
                                    color: seg.active ? Theme.accent : (segMa.containsMouse ? Theme.panel2 : "transparent")
                                }
                                Rectangle {
                                    visible: seg.index > 0
                                    anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                                    width: 1; color: Theme.line
                                }
                                Text {
                                    anchors.centerIn: parent
                                    text: seg.modelData.lbl
                                    color: seg.active ? Theme.bg : (segMa.containsMouse ? Theme.ink : Theme.ink2)
                                    font.family: Theme.fontMono
                                    font.pixelSize: 12
                                    font.weight: Font.DemiBold
                                }
                                MouseArea {
                                    id: segMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.layoutRequested(seg.modelData.n)
                                }
                            }
                        }
                    }
                }

                Rectangle { Layout.preferredWidth: 1; Layout.preferredHeight: 24; color: Theme.line2 }

                // filter pills
                FilterPill {
                    label: "Online"
                    active: root.statusFilter === "online"
                    removable: root.statusFilter === "online"
                    onClicked: root.statusFilterRequested(root.statusFilter === "online" ? "" : "online")
                    onRemoved: root.statusFilterRequested("")
                }
                FilterPill {
                    label: "Recent events"
                    active: root.statusFilter === "recent"
                    onClicked: root.statusFilterRequested(root.statusFilter === "recent" ? "" : "recent")
                }
                FilterPill {
                    label: root.statusFilter === "issues" ? "Issues" : "Filter"
                    leadingPlus: root.statusFilter !== "issues"
                    removable: root.statusFilter === "issues"
                    active: ["offline", "degraded", "recording", "notrec", "favorites", "issues"].indexOf(root.statusFilter) >= 0
                    onClicked: root.statusFilterRequested(root.statusFilter === "issues" ? "" : "issues")
                    onRemoved: root.statusFilterRequested("")
                }

                Item { Layout.fillWidth: true }

                // save current view (ghost)
                Rectangle {
                    Layout.preferredHeight: 34
                    implicitWidth: saveTxt.implicitWidth + 28
                    color: saveMa.containsMouse ? Theme.panel : "transparent"
                    border.width: 1
                    border.color: saveMa.containsMouse ? Theme.accent : "transparent"
                    Text {
                        id: saveTxt
                        anchors.centerIn: parent
                        text: "Save current view"
                        color: Theme.ink2
                        font.family: Theme.fontSans
                        font.pixelSize: 12
                        font.weight: Font.Medium
                    }
                    MouseArea {
                        id: saveMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.saveViewRequested()
                    }
                }

                // sort dropdown
                Rectangle {
                    id: sortControl
                    Layout.preferredHeight: 38
                    implicitWidth: sortRow.implicitWidth + 24
                    color: Theme.panel
                    border.width: 1
                    border.color: sortMa.containsMouse ? Theme.accent : Theme.line2
                    Row {
                        id: sortRow
                        anchors.centerIn: parent
                        spacing: 8
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Sort: " + root.sortLabels[root.sortMode]
                            color: Theme.ink
                            font.family: Theme.fontSans
                            font.pixelSize: 12
                        }
                        Icon { anchors.verticalCenter: parent.verticalCenter; name: "chev"; size: 12; color: Theme.ink3 }
                    }
                    MouseArea {
                        id: sortMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: sortPopup.open()
                    }
                    C.Popup {
                        id: sortPopup
                        y: sortControl.height + 4
                        x: 0
                        width: 160
                        padding: 0
                        background: Rectangle { color: Theme.panel; border.color: Theme.line2; border.width: 1 }
                        contentItem: Column {
                            Repeater {
                                model: [
                                    { id: "default", lbl: "Layout order" },
                                    { id: "status",  lbl: "Status first" },
                                    { id: "alpha",   lbl: "Alphabetical" }
                                ]
                                delegate: Rectangle {
                                    required property var modelData
                                    width: 160
                                    height: 34
                                    color: optMa.containsMouse ? Theme.panel2 : "transparent"
                                    Text {
                                        anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                                        text: modelData.lbl
                                        color: root.sortMode === modelData.id ? Theme.accent : Theme.ink
                                        font.family: Theme.fontSans
                                        font.pixelSize: 12
                                    }
                                    MouseArea {
                                        id: optMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: { root.sortRequested(modelData.id); sortPopup.close() }
                                    }
                                }
                            }
                        }
                    }
                }

                // full-screen
                IconButton {
                    name: "full"
                    iconColor: Theme.ink2
                    borderColor: Theme.line2
                    bgColor: Theme.panel
                    hoverIcon: Theme.accent
                    hoverBorder: Theme.accent
                    tip: "Full-screen monitoring (F)"
                    implicitWidth: 38
                    implicitHeight: 38
                    onClicked: root.fullscreenToggled()
                }
            }
        }

        // ---------------------------------------------------------- grid
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: root.fullscreen ? 4 : 20
                anchors.rightMargin: root.fullscreen ? 4 : 20
                anchors.topMargin: root.fullscreen ? 4 : 14
                anchors.bottomMargin: root.fullscreen ? 4 : 14
                color: Theme.line2
                visible: root.total > 0

                GridLayout {
                    anchors.fill: parent
                    anchors.margins: 1
                    columns: root.cols
                    rowSpacing: 1
                    columnSpacing: 1

                    Repeater {
                        id: gridRepeater
                        model: root.pagedCameras
                        delegate: CameraTile {
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            gridMode: true
                            camName: modelData.name
                            camId: modelData.camId
                            groupId: modelData.groupId
                            live: modelData.live
                            recording: modelData.recording
                            favorite: modelData.favorite
                            hasAudio: modelData.hasAudio
                            timestamp: modelData.timestamp
                            lastSeen: modelData.lastSeen
                            pattern: modelData.pattern
                            rtspUrl: modelData.rtspUrl
                            rtspSubUrl: modelData.rtspSubUrl
                            // Only play when Live Monitor is the visible section (so other
                            // screens don't hold open streams / hit cameras). WT_TEST_IP
                            // (dev) further restricts streaming to a single camera.
                            videoActive: root.visible
                                && ((typeof wtTestIp !== "undefined" && wtTestIp !== "")
                                    ? (modelData.ip === wtTestIp) : true)
                            onSnapshotSaved: (p, n) => root.snapshotSaved(p, n)
                            onOpened: root.cameraOpened(modelData)
                        }
                    }
                }
            }

            // No cameras yet — first-run import.
            EmptyState {
                anchors.fill: parent
                anchors.margins: 24
                visible: root.total === 0 && !root.fullscreen
                icon: "monitor"
                title: "No cameras yet"
                subtitle: "Import your cameras from a Cilex Vision Provisioner export "
                          + "(cilex-provisioning-*.json) to start monitoring."
                actionLabel: "Import cameras…"
                onAction: importDialog.open()
            }

            // floating exit button in full-screen
            Rectangle {
                visible: root.fullscreen
                anchors { top: parent.top; right: parent.right; topMargin: 12; rightMargin: 12 }
                implicitWidth: exitRow.implicitWidth + 24
                height: 34
                color: Qt.rgba(0.10, 0.094, 0.086, 0.85)
                border.width: 1
                border.color: Theme.line2
                Row {
                    id: exitRow
                    anchors.centerIn: parent
                    spacing: 8
                    Icon { anchors.verticalCenter: parent.verticalCenter; name: "x"; size: 14; color: Theme.ink }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Exit full-screen"
                        color: Theme.ink
                        font.family: Theme.fontSans
                        font.pixelSize: 12
                        font.weight: Font.Medium
                    }
                }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.fullscreenToggled() }
            }
        }

        // ---------------------------------------------------------- page bar
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 40
            visible: !root.fullscreen
            color: Theme.bg
            Rectangle {
                anchors { left: parent.left; right: parent.right; top: parent.top }
                height: 1; color: Theme.line
            }
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 20
                anchors.rightMargin: 20
                spacing: 12
                Text {
                    text: root.groupLabel + " · " + root.total + " cameras · Page " + root.page + " of " + root.pageCount
                    color: Theme.ink3
                    font.family: Theme.fontMono
                    font.pixelSize: Theme.fsMono
                }
                Item { Layout.fillWidth: true }
                PaginationControl {
                    page: root.page
                    pageCount: root.pageCount
                    rangeText: root.rangeText
                    onPrev: root.pageRequested(root.page - 1)
                    onNext: root.pageRequested(root.page + 1)
                }
            }
        }
    }
}
