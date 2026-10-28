.pragma library
// Groups "Wall" — the ONE place camera status is classified (spec §2.5).
// Every count on the screen (Faults facet, bad rings, "N not recording", the
// console summary, the health bars) resolves from these predicates. Ad-hoc
// filters at call sites are how a facet says 21 while 13 tiles wear the ring.

// CameraStatus mirrors — values MUST match src/models/CameraStatus.h exactly
// (they are ints across the QML boundary; a wrong mirror silently reclassifies
// the whole fleet — it briefly rendered all 39 cameras as OFF).
var REC  = { Unknown: 0, Recording: 1, NotRecording: 2, Gap: 3, Stalled: 4, Armed: 5, Disabled: 6 };
var LIVE = { Unknown: 0, Live: 1, Offline: 2, Degraded: 3, Loading: 4, NoSignal: 5, PermissionDenied: 6 };

function _rec(c) { return c ? c.recording : REC.Unknown; }

// ---------------------------------------------------------------------------
// ONE narrowing predicate for "is this an instant I can compare?".
//
// Adopted from cilex-pro-mobile (b436010, 2026-09-22) after the same family of
// defect cost them three hours: a timestamp that is ABSENT and one that is
// UNPARSEABLE are the same answer — "no usable instant" — and they must not take
// opposite branches. Here they did. `""` fell to the -1 sentinel every site
// below handles correctly; a non-empty string Date.parse cannot read became NaN,
// and NaN answers FALSE to every comparison, `<= 0` included. So the "no
// timestamp" branch was skipped AND the "too old" branch was skipped, and the
// predicate returned "nothing wrong" about a camera it could say nothing about.
// It does not throw. It quietly stops being true.
//
// STANDING: insurance, not a repair. cilex-vision serialises every field below
// through iso_ms() (services/_common/timefmt.py:35) off TIMESTAMPTZ columns, so
// a non-empty unparseable value has never been observed on this wire. Same
// footing as the 200/0-byte session guards — and labelled the same way.
//
// AND A SECOND RULE, measured here 2026-09-22 and true of BOTH our parsers: an
// ISO string with NO timezone is read as LOCAL time — by QV4's Date.parse in
// this file, and by QDateTime::fromString(.., Qt::ISODate) in src/ (verified
// Qt 6.12: naive input yields timeSpec=0). On this box, MSK, that is a silent
// 3-hour shift; in a UTC container it is none — so a dev box and the guard booth
// would disagree and neither would say so. A client cannot recover the right
// INSTANT from such a string — but it CAN see that the string is the wrong
// SHAPE, and src/models/WireTime.h now names any field that arrives without an
// offset. (This comment said "nothing on this side can detect it" when first
// written, on 2026-09-22; cilex-pro-mobile drew the distinction and was right.)
// What prevents it is on the SERVER: iso_ms() emits an offset if and only if the
// datetime handed to it is tz-aware, and the columns behind these fields are
// TIMESTAMPTZ (alembic 0053/0054; 0028 for last_vmd_event_at). That is a
// cross-repo dependency no test on either side pins: cilex-vision's route tests
// assert `wire == iso_ms(input)`, which passes just as well if BOTH sides are
// naive. If these ever start arriving without an offset, the damage lands here,
// three hours wide, and the parse will look fine.
function ms(iso) {
    if (!iso) return -1;
    var t = Date.parse(iso);
    return t > 0 ? t : -1;        // NaN, 0 and negatives all mean "cannot compare"
}


// Capture proof is independent of catalogue freshness. CameraModel supplies
// normalized v1 health; a missing/stale observation never certifies capture.
function capture(c) {
    var h = c && c.recordingHealth;
    if (h && h.fresh === true) return h.capture_state || "unknown";
    return _rec(c) === REC.Disabled ? "disabled" : "unknown";
}
function archiveMissing(c) {
    if (!c || _rec(c) !== REC.Armed) return false;
    var v = ms(c.motionLastVmdAt), s = ms(c.lastSegmentAt);
    return v > 0 && (Date.now() - v) < 10800000 && (s <= 0 || (v - s) > 3600000);
}
function archiveBroken(c) {
    var h = c && c.recordingHealth;
    if (h && h.version === 1) return h.archive_state === "delayed" || h.archive_state === "unavailable";
    var r = _rec(c);
    return r === REC.NotRecording || r === REC.Stalled || r === REC.Gap || archiveMissing(c);
}
function recBroken(c) { return capture(c) === "stopped"; }
function detBroken(c) { return !!(c && c.motionKnown === true && c.motionReady === false); }
function notRecordingNow(c) { return recBroken(c); }
function archiveUnknown(c) { return !!(c && c.recordingHealth && c.recordingHealth.archive_state === "unknown"); }
function unknown(c) { return capture(c) === "unknown" || archiveUnknown(c); }
function offline(c) { return !!(c && (c.live === LIVE.Offline || c.live === LIVE.NoSignal)); }
function REC_BROKEN(c) { return recBroken(c); }
function DET_BROKEN(c) { return detBroken(c); }
function FAULT(c) { return REC_BROKEN(c) || DET_BROKEN(c) || archiveBroken(c); }

function silent(c) {
    if (!c || _rec(c) !== REC.Armed) return false;
    var s = ms(c.lastSegmentAt);
    return s <= 0 || (Date.now() - s) > 86400000;
}
function warn(c) {
    if (FAULT(c)) return false;
    var r = _rec(c);
    return unknown(c) || r === REC.Disabled || offline(c) || silent(c);
}
function ok(c) { return !FAULT(c) && !warn(c); }
function unnamed(c) { return !!(c && /\(\d+\.\d+\.\d+\.\d+\)\s*$/.test(String(c.name || ""))); }

// marker short form — recording BEFORE detector, else the wall's red tiles
// undercount the header (spec §2.5). "" = healthy, no ink.
function marker(c) {
    var r = _rec(c);
    if (offline(c)) return "OFF";
    if (REC_BROKEN(c)) return qsTranslate("RecordingStatusBadge", "REC STOPPED");
    if (archiveBroken(c)) return qsTranslate("RecordingStatusBadge", "ARCHIVE DELAY");
    if (DET_BROKEN(c)) return "NOT READY";
    if (archiveUnknown(c)) return qsTranslate("RecordingStatusBadge", "ARCHIVE ?");
    if (r === REC.Disabled || capture(c) === "disabled") return "OFF";
    if (silent(c)) {
        var s = ms(c.lastSegmentAt);
        return s <= 0 ? "NO MOTION" : "SILENT";
    }
    if (unknown(c)) return "REC ?";
    return "";
}
function markerIsFault(c) { return (REC_BROKEN(c) || DET_BROKEN(c)) && !offline(c); }

function badgeText(c) {
    if (offline(c)) return "OFF";
    if (REC_BROKEN(c)) return qsTranslate("RecordingStatusBadge", "REC STOPPED");
    if (archiveBroken(c)) return qsTranslate("RecordingStatusBadge", "ARCHIVE DELAY");
    if (archiveUnknown(c)) return qsTranslate("RecordingStatusBadge", "ARCHIVE ?");
    if (capture(c) === "progressing") return "REC";
    if (capture(c) === "disabled") return "OFF";
    if (_rec(c) === REC.Armed) return DET_BROKEN(c) ? "ARMED · NOT READY" : "ARMED · REC ?";
    return "REC ?";
}

function octet(c) {
    var m = /\.(\d+)$/.exec((c && c.ip) || "");
    return m ? "." + m[1] : "";
}
// model string = the vendor name minus its "(ip)" tail — the FALLBACK label
function modelOf(c) {
    return String((c && c.name) || "").replace(/\s*\((?:\d+\.){3}\d+\)\s*$/, "");
}
function matches(c, q) {
    if (!q) return true;
    q = q.toLowerCase();
    var o = octet(c);
    return (o && o.indexOf(q.charAt(0) === "." ? q : "." + q) === 0)
        || String(c.ip || "").toLowerCase().indexOf(q) >= 0
        || String(c.name || "").toLowerCase().indexOf(q) >= 0
        || String(c.model || "").toLowerCase().indexOf(q) >= 0;
}
