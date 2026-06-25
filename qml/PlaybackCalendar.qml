import QtQuick
import QtQuick.Layouts
import Watchtower

// Footage calendar for the playback aside. Shows the last `retentionDays` days
// (the longest storage-tier retention window). Days that have recorded footage
// are marked from the coverage feed; clicking an in-window day asks the screen
// to load that day's full 24h (gaps included). Until the backend coverage API
// ships, `pending` is true and per-day footage marks are suppressed (honest —
// we never fabricate coverage), but every in-window day stays clickable so the
// operator can still load any day and see its real footage/gaps.
ColumnLayout {
    id: cal
    spacing: 0

    property int retentionDays: 35          // longest tier retention = calendar span
    property var footageDays: []            // ["yyyy-MM-dd", …] that have footage
    property bool pending: true             // coverage API not yet answered/available
    property string selectedDate: ""        // "yyyy-MM-dd" currently loaded, or ""

    signal daySelected(string dateStr)

    function ymd(d) { return Qt.formatDate(d, "yyyy-MM-dd") }
    function midnight(d) { return new Date(d.getFullYear(), d.getMonth(), d.getDate()) }

    // The week grid (Mon-first) spanning the retention window. Rebuilt only when
    // the span changes; footage/selection are reactive bindings in the delegate.
    property var _cells: []
    property string _rangeLabel: ""
    function rebuild() {
        var today = midnight(new Date());
        var windowStart = new Date(today);
        windowStart.setDate(today.getDate() - (retentionDays - 1));
        // Pad to whole weeks: Monday of windowStart's week … Sunday of today's.
        var gridStart = new Date(windowStart);
        gridStart.setDate(gridStart.getDate() - ((gridStart.getDay() + 6) % 7));
        var gridEnd = new Date(today);
        gridEnd.setDate(gridEnd.getDate() + (6 - ((gridEnd.getDay() + 6) % 7)));
        var cells = [];
        for (var d = new Date(gridStart); d <= gridEnd; d.setDate(d.getDate() + 1)) {
            var ds = ymd(d);
            cells.push({
                dateStr: ds,
                day: d.getDate(),
                inWindow: (d >= windowStart && d <= today),
                isToday: ds === ymd(today),
                isFuture: d > today
            });
        }
        _cells = cells;
        _rangeLabel = Qt.formatDate(windowStart, "d MMM") + " – " + Qt.formatDate(today, "d MMM yyyy");
    }
    Component.onCompleted: rebuild()
    onRetentionDaysChanged: rebuild()

    // header: "FOOTAGE" + status (pending / N days)
    RowLayout {
        Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.bottomMargin: 6
        Text {
            text: "Footage"; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
            font.weight: Font.DemiBold; font.letterSpacing: 1.4; font.capitalization: Font.AllUppercase
        }
        Item { Layout.fillWidth: true }
        Text {
            text: cal.pending ? "availability pending" : (cal.footageDays.length + " days w/ footage")
            color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9
        }
    }
    Text {
        Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.bottomMargin: 8
        text: cal._rangeLabel + "  ·  last " + cal.retentionDays + "d"
        color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11
    }

    // weekday header + day grid. Grid POSITIONER (not GridLayout): QQuickGridLayout SIGSEGVs on
    // minimize/restore in Qt 6.4.2 (see LiveMonitor camera grid). Cells get an explicit equal width.
    Grid {
        id: dayGrid
        Layout.fillWidth: true; Layout.leftMargin: 12; Layout.rightMargin: 12; Layout.bottomMargin: 4
        columns: 7; columnSpacing: 2; rowSpacing: 2

        Repeater {
            model: ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
            Text {
                width: (dayGrid.width - 6 * dayGrid.columnSpacing) / 7; horizontalAlignment: Text.AlignHCenter
                text: modelData; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9
                font.capitalization: Font.AllUppercase
            }
        }

        Repeater {
            model: cal._cells
            delegate: Item {
                width: (dayGrid.width - 6 * dayGrid.columnSpacing) / 7
                height: 30
                readonly property bool active: modelData.inWindow && !modelData.isFuture
                readonly property bool marked: !cal.pending && cal.footageDays.indexOf(modelData.dateStr) >= 0
                readonly property bool selected: modelData.dateStr === cal.selectedDate

                Rectangle {
                    anchors.fill: parent; anchors.margins: 1
                    color: selected ? Theme.accent
                         : marked ? Theme.accentSoft
                         : (active && cellMa.containsMouse) ? Theme.panel2 : "transparent"
                    border.width: (modelData.isToday && !selected) ? 1 : 0
                    border.color: Theme.line2

                    Text {
                        anchors.centerIn: parent
                        text: modelData.day
                        color: selected ? Theme.bg
                             : !active ? Qt.rgba(Theme.ink3.r, Theme.ink3.g, Theme.ink3.b, 0.4)
                             : marked ? Theme.accent : Theme.ink2
                        font.family: Theme.fontMono; font.pixelSize: 11
                        font.weight: (marked || selected) ? Font.DemiBold : Font.Normal
                    }
                    // footage dot
                    Rectangle {
                        visible: marked && !selected
                        width: 3; height: 3; radius: 1.5; color: Theme.accent
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom; anchors.bottomMargin: 3
                    }
                    MouseArea {
                        id: cellMa
                        anchors.fill: parent
                        enabled: active
                        hoverEnabled: active
                        cursorShape: active ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: cal.daySelected(modelData.dateStr)
                    }
                }
            }
        }
    }

    // legend
    RowLayout {
        Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.topMargin: 4
        spacing: 12
        RowLayout {
            spacing: 5
            Rectangle { width: 3; height: 3; radius: 1.5; color: Theme.accent }
            Text { text: "has footage"; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9 }
        }
        RowLayout {
            spacing: 5
            Rectangle { width: 7; height: 7; color: "transparent"; border.width: 1; border.color: Theme.line2 }
            Text { text: "today"; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9 }
        }
        Item { Layout.fillWidth: true }
    }
}
