pragma Singleton
import QtQuick
import Watchtower

// Playback "One Axis" — the screen's localized names and number formats in one
// place (spec §6). Weekday and month names are LOCALISED ARRAYS, not strftime:
// the ribbon needs a full form ("Thu") *and* a single letter ("Ч"), and Russian's
// genitive month forms differ from the nominative ones Qt.formatDate would give.
// Qt.formatDate follows the SYSTEM locale, which is not the app's language — the
// app switches language with a QTranslator — so every visible name goes through
// qsTr() here and nowhere else.
QtObject {
    id: fmt

    // ---- names ----------------------------------------------------------
    // Index 0 = Sunday, matching JS Date.getDay().
    readonly property var wdShort: [
        qsTr("Sun", "weekday, short"), qsTr("Mon", "weekday, short"), qsTr("Tue", "weekday, short"),
        qsTr("Wed", "weekday, short"), qsTr("Thu", "weekday, short"), qsTr("Fri", "weekday, short"),
        qsTr("Sat", "weekday, short")
    ]
    // Single letter for the ribbon's compact rendering (15–26px cells).
    readonly property var wdLetter: [
        qsTr("S", "weekday, one letter: Sunday"), qsTr("M", "weekday, one letter: Monday"),
        qsTr("T", "weekday, one letter: Tuesday"), qsTr("W", "weekday, one letter: Wednesday"),
        qsTr("T", "weekday, one letter: Thursday"), qsTr("F", "weekday, one letter: Friday"),
        qsTr("S", "weekday, one letter: Saturday")
    ]
    readonly property var monShort: [
        qsTr("Jan", "month, short"), qsTr("Feb", "month, short"), qsTr("Mar", "month, short"),
        qsTr("Apr", "month, short"), qsTr("May", "month, short"), qsTr("Jun", "month, short"),
        qsTr("Jul", "month, short"), qsTr("Aug", "month, short"), qsTr("Sep", "month, short"),
        qsTr("Oct", "month, short"), qsTr("Nov", "month, short"), qsTr("Dec", "month, short")
    ]

    function wd(ms) { return wdShort[new Date(ms).getDay()] }
    function wd1(ms) { return wdLetter[new Date(ms).getDay()] }
    function mon(i) { return monShort[((i % 12) + 12) % 12] }

    // ---- clocks ----------------------------------------------------------
    function pad2(n) { return (n < 10 ? "0" : "") + n }
    function pad3(n) { return n < 10 ? "00" + n : n < 100 ? "0" + n : "" + n }
    function hm(ms)  { return Settings.clock(ms, false) }         // honours the 12/24h preference
    function hms(ms) { return Settings.clock(ms, true) }
    function ms3(ms) { return pad3(Math.floor(((ms % 1000) + 1000) % 1000)) }
    // "9 Aug 2026" — the evidentiary timestamp's date qualifier.
    function dmy(ms) {
        var d = new Date(ms);
        return d.getDate() + " " + mon(d.getMonth()) + " " + d.getFullYear();
    }

    // ---- durations -------------------------------------------------------
    // A marked range / event length: "4m 12s", "1h 04m", "38s".
    function dur(msSpan) {
        var s = Math.max(0, Math.round(msSpan / 1000));
        if (s < 60) return s + qsTr("s", "seconds, compact duration suffix");
        var m = Math.floor(s / 60), rs = s % 60;
        if (m < 60) return m + qsTr("m", "minutes, compact duration suffix")
                           + (rs ? " " + pad2(rs) + qsTr("s", "seconds, compact duration suffix") : "");
        var h = Math.floor(m / 60), rm = m % 60;
        return h + qsTr("h", "hours, compact duration suffix")
               + (rm ? " " + pad2(rm) + qsTr("m", "minutes, compact duration suffix") : "");
    }
    // A day's recorded total, rounded to whole minutes (spec §2.2): "50m", "1h 13m".
    function durM(msSpan) {
        var m = Math.round(msSpan / 60000);
        if (m < 60) return m + qsTr("m", "minutes, compact duration suffix");
        var h = Math.floor(m / 60), rm = m % 60;
        return h + qsTr("h", "hours, compact duration suffix")
               + (rm ? " " + rm + qsTr("m", "minutes, compact duration suffix") : "");
    }

    // ---- counted things (EN 2-form, RU 3-form) ---------------------------
    function segs(n)  { return qsTr("%n segment(s)", "recorded segments in the loaded window", n) }
    function clips(n) { return qsTr("%n clip(s)", "recorded segments on one archive day", n) }
    function daysW(n) { return qsTr("%n day(s) w/ footage", "", n) }
    function evs(n)   { return qsTr("%n event(s)", "", n) }
}
