import QtQuick
import QtQuick.Controls.Basic as C
import Watchtower

// Playback navigator, TIER 1 — the archive ribbon (spec §2.2). The month
// calendar unrolled onto the axis it was always describing: one cell per
// retention day, week-banded so weekday position is readable by block rather
// than by counting, with a density bar per day and an amber bracket inside the
// selected cell showing where tier 2's window sits.
//
// The height is PINNED at 42. `laneH = navH − 83` subtracts ribbon 42 + header
// 26 + ruler 15 as constants; left content-sized this renders short and the
// difference lands as a dead strip under the last lane at every drag position
// (spec §0).
Item {
    id: rib
    height: 42

    // [{ ms: dayStartMs, key: "yyyy-MM-dd", has: bool, sec: Number, today: bool }]
    property var days: []
    property string selKey: ""
    // Where tier 2's window sits inside the selected day, as fractions 0..1.
    property real winA: -1
    property real winB: -1
    // Selected day's own totals, for the label block.
    property real selSec: 0
    property int selClips: -1        // < 0 = unknown (the coverage contract has no per-day count)
    property double selMs: 0
    // Coverage has not answered (or its answer failed). UNKNOWN IS NOT EMPTY: with
    // this set, no day may render as a confirmed blank and the label block says so
    // outright. On 2026-09-22 a refresh that hit a 111 s API stall wiped the ribbon
    // and it read "no footage this day" for a camera with 74,899 s recorded that day.
    property bool pending: false

    signal daySelected(string key)

    readonly property int labelW: 120
    readonly property real trackW: Math.max(1, width - labelW)
    readonly property int nDays: days ? days.length : 0

    // Cell width is paneWidth/days with the REMAINDER DISTRIBUTED — one extra
    // pixel to each of the first `remainder` cells. floor() alone leaves the
    // ribbon ending short of its track, and here that also misaligns it from
    // the ruler beneath (spec §2.2, the Groups-wall trap made worse).
    readonly property var _cells: {
        var n = nDays;
        if (n <= 0) return { w: [], x: [], base: 0 };
        var total = Math.floor(trackW);
        var base = Math.floor(total / n), extra = total - base * n;
        var w = [], x = [], acc = 0;
        for (var i = 0; i < n; i++) {
            var cw = base + (i < extra ? 1 : 0);
            w.push(cw); x.push(acc); acc += cw;
        }
        return { w: w, x: x, base: base };
    }
    readonly property int cellBase: _cells.base
    // Degradation ladder (spec §2.2) — density is the last thing to survive.
    readonly property bool compact: cellBase < 26
    readonly property bool tiny: cellBase < 15

    // Week banding and month dividers are computed FROM THE DATES, never from a
    // cell index, so they survive any retention length and any start weekday.
    readonly property double _mon0: {
        if (nDays === 0) return 0;
        var d0 = new Date(days[0].ms);
        return days[0].ms - ((d0.getDay() + 6) % 7) * 86400000;
    }
    function _weekOf(ms) { return Math.floor((ms - _mon0) / (7 * 86400000)) }

    Rectangle { anchors.fill: parent; color: "transparent" }
    Rectangle {   // hairline under the whole tier
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 1; color: Theme.line
    }

    // ---- label block · a hard 120px --------------------------------------
    // The ribbon track and the ruler track align on it, so it may not grow to
    // fit its text: the text yields (two lines, 9px, clipped), never the block.
    Item {
        id: lbl
        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
        width: rib.labelW
        clip: true
        Rectangle { anchors { right: parent.right; top: parent.top; bottom: parent.bottom } width: 1; color: Theme.line }

        Column {
            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter
                      leftMargin: 8; rightMargin: 8 }
            spacing: 3
            Item {
                width: parent.width; height: 10
                Text {
                    anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                    text: qsTr("ARCHIVE", "playback navigator tier 1")
                    color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 8
                    font.letterSpacing: 1.4; font.weight: Font.DemiBold
                }
                Text {
                    anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                    text: rib.selMs > 0 ? (PbFmt.wd(rib.selMs) + " " + new Date(rib.selMs).getDate()) : ""
                    color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 8; font.letterSpacing: 1.2
                }
            }
            // The one fact nothing else on this screen states: the QUANTITY behind
            // the dot you just clicked. Not the retention span and not the count of
            // days with footage — the ribbon draws both of those six pixels away.
            Text {
                width: parent.width
                elide: Text.ElideRight
                text: rib.pending ? qsTr("coverage unknown")
                      : rib.tiny ? PbFmt.daysW(rib._daysWithFootage)
                               : (rib.selSec > 0
                                  ? (PbFmt.durM(rib.selSec * 1000)
                                     + (rib.selClips >= 0 ? " · " + PbFmt.clips(rib.selClips) : ""))
                                  : qsTr("no footage this day"))
                color: rib.pending ? Theme.ink3
                       : rib.selSec > 0 || rib.tiny ? Theme.ink2 : Theme.ink3
                font.family: Theme.fontMono; font.pixelSize: 9
            }
        }
    }
    readonly property int _daysWithFootage: {
        var n = 0;
        for (var i = 0; i < nDays; i++) if (days[i].has) n++;
        return n;
    }

    // ---- track ------------------------------------------------------------
    Item {
        id: track
        anchors { left: lbl.right; right: parent.right; top: parent.top; bottom: parent.bottom }
        clip: true

        Repeater {
            model: rib.nDays
            delegate: Item {
                id: cell
                required property int index
                readonly property var d: rib.days[index]
                readonly property bool has: d && d.has
                readonly property bool isSel: d && d.key === rib.selKey
                readonly property bool monthStart: d && new Date(d.ms).getDate() === 1
                x: rib._cells.x[index]
                width: rib._cells.w[index]
                height: track.height

                // alternate week blocks tinted — five weeks read as five bands
                Rectangle {
                    anchors.fill: parent
                    visible: cell.d && (rib._weekOf(cell.d.ms) % 2) !== 0
                    color: Qt.rgba(240 / 255, 236 / 255, 228 / 255, 0.028)
                }
                Rectangle {   // selected day
                    anchors.fill: parent; visible: cell.isSel; color: Theme.accentSoft
                }
                Rectangle {   // hover
                    anchors.fill: parent
                    visible: cell.has && cellMa.containsMouse && !cell.isSel
                    color: Theme.panel2
                }
                Rectangle {   // today: 1px inset ring
                    anchors.fill: parent; visible: cell.d && cell.d.today
                    color: "transparent"; border.width: 1; border.color: Theme.ink3
                }
                Rectangle {   // cell hairline
                    anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
                    width: 1; color: Qt.rgba(52 / 255, 48 / 255, 42 / 255, 0.6)
                }
                Rectangle {   // selected day: 2px accent bottom bar
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                    height: 2; color: Theme.accent; visible: cell.isSel
                }

                Column {
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom; bottomMargin: 3 }
                    spacing: 2
                    // The weekday label carries the ribbon's whole wayfinding argument,
                    // so it sits AT the type floor (8px / 1.2 tracking), never below it.
                    // On the 1st of a month the same slot carries the month name:
                    // drawn as a free-floating label it landed on top of the weekday
                    // and destroyed exactly the label the ribbon's argument rests on.
                    Text {
                        visible: !rib.tiny
                        width: parent.width; horizontalAlignment: Text.AlignHCenter
                        elide: Text.ElideRight
                        text: !cell.d ? ""
                              : cell.monthStart ? PbFmt.mon(new Date(cell.d.ms).getMonth())
                              : rib.compact ? PbFmt.wd1(cell.d.ms) : PbFmt.wd(cell.d.ms)
                        color: cell.isSel ? Theme.accent
                               : cell.monthStart ? Theme.ink2
                               : cell.has ? Theme.ink3
                               : rib.pending ? Theme.ink3
                               : Qt.rgba(110 / 255, 102 / 255, 87 / 255, 0.32)
                        font.family: Theme.fontMono; font.pixelSize: 8; font.letterSpacing: 1.2
                    }
                    Text {
                        visible: !rib.compact
                        width: parent.width; horizontalAlignment: Text.AlignHCenter
                        text: cell.d ? new Date(cell.d.ms).getDate() : ""
                        color: cell.isSel ? Theme.accent
                               : cell.has ? Theme.ink2
                               : rib.pending ? Theme.ink3
                               : Qt.rgba(110 / 255, 102 / 255, 87 / 255, 0.42)
                        font.family: Theme.fontMono; font.pixelSize: 10
                        font.weight: cell.isSel ? Font.DemiBold : Font.Normal
                    }
                    Item {   // 4px density track — day minutes against a 6-hour ceiling
                        width: parent.width; height: 4
                        Rectangle {
                            anchors { left: parent.left; right: parent.right; bottom: parent.bottom
                                      leftMargin: 3; rightMargin: 3 }
                            visible: cell.has
                            height: Math.max(1, Math.round(Math.min(1, cell.d.sec / 21600) * 4))
                            color: Theme.good
                        }
                        // The unknown mark. A day with no green bar and nothing else
                        // reads as "measured, and there is nothing here" - which is the
                        // lie. A 1px neutral dash says we have not been told, and it can
                        // never be mistaken for the green bar's "this much".
                        Rectangle {
                            anchors { left: parent.left; right: parent.right; bottom: parent.bottom
                                      leftMargin: 3; rightMargin: 3 }
                            visible: rib.pending && !cell.has
                            height: 1
                            color: Qt.rgba(110 / 255, 102 / 255, 87 / 255, 0.45)
                        }
                    }
                }

                // window bracket — inside the selected cell only: where tier 2 looks
                Rectangle {
                    visible: cell.isSel && rib.winA >= 0 && rib.winB > rib.winA
                    x: Math.round(rib.winA * cell.width)
                    width: Math.max(2, Math.round((rib.winB - rib.winA) * cell.width))
                    anchors { top: parent.top; bottom: parent.bottom }
                    color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.20)
                    border.width: 1; border.color: Theme.accent
                }

                MouseArea {
                    id: cellMa
                    anchors.fill: parent
                    enabled: cell.has                                  // days without footage are INERT
                    hoverEnabled: cell.has
                    cursorShape: cell.has ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: rib.daySelected(cell.d.key)
                }
                C.ToolTip.visible: cellMa.containsMouse
                C.ToolTip.delay: 400
                C.ToolTip.text: cell.d
                    ? (PbFmt.wd(cell.d.ms) + " " + PbFmt.dmy(cell.d.ms)
                       + (cell.has ? " · " + PbFmt.durM(cell.d.sec * 1000) : " · " + qsTr("no footage")))
                    : ""
            }
        }

        // week dividers — before every Monday
        Repeater {
            model: rib.nDays
            delegate: Rectangle {
                required property int index
                readonly property var d: rib.days[index]
                visible: index > 0 && d && new Date(d.ms).getDay() === 1
                x: rib._cells.x[index]; width: 1
                anchors { top: parent.top; bottom: parent.bottom }
                color: Qt.rgba(68 / 255, 63 / 255, 55 / 255, 0.55)
            }
        }
        // month dividers — stronger than the week rule, and computed from the
        // date so they survive any retention length. The month NAME is in the
        // cell itself (above), where it cannot collide with the weekday.
        Repeater {
            model: rib.nDays
            delegate: Rectangle {
                required property int index
                readonly property var d: rib.days[index]
                visible: index > 0 && d && new Date(d.ms).getDate() === 1
                x: rib._cells.x[index]; width: 1
                anchors { top: parent.top; bottom: parent.bottom }
                color: Theme.line2
            }
        }
    }
}
