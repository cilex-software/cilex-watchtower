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
// would disagree and neither would say so. Nothing on this side can detect it.
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


// two independent axes -------------------------------------------------------
function recBroken(c) { var r = _rec(c); return r === REC.NotRecording || r === REC.Stalled; }
function detBroken(c) { return !!(c && c.motionKnown === true && c.motionReady === false); }
// detecting motion recently while the newest footage is older than that
// detection = the recorder is not writing this camera (the 2026-08-07 P1).
function notRecordingNow(c) {
    if (!c || _rec(c) !== REC.Armed) return false;
    var v = ms(c.motionLastVmdAt);          // -1 covers the old `!c.motionLastVmdAt` guard
    var s = ms(c.lastSegmentAt);
    return v > 0 && (Date.now() - v) < 10800000 && (s <= 0 || (v - s) > 3600000);
}
function unknown(c) { return _rec(c) === REC.Unknown; }
function offline(c) { return !!(c && (c.live === LIVE.Offline || c.live === LIVE.NoSignal)); }

// REC_BROKEN feeds the "N not recording" readout AND the top-bar pill.
function REC_BROKEN(c) { return recBroken(c) || notRecordingNow(c); }
function DET_BROKEN(c) { return detBroken(c); }
// FAULT feeds the 2px bad ring AND the Faults facet — one predicate, both.
function FAULT(c) { return REC_BROKEN(c) || DET_BROKEN(c); }

function silent(c) {
    if (!c || _rec(c) !== REC.Armed) return false;
    var s = ms(c.lastSegmentAt);
    return s <= 0 || (Date.now() - s) > 86400000;
}
function warn(c) {
    if (FAULT(c)) return false;
    var r = _rec(c);
    return r === REC.Gap || r === REC.Unknown || r === REC.Disabled || offline(c) || silent(c);
}
function ok(c) { return !FAULT(c) && !warn(c); }
function unnamed(c) { return !!(c && /\(\d+\.\d+\.\d+\.\d+\)\s*$/.test(String(c.name || ""))); }

// marker short form — recording BEFORE detector, else the wall's red tiles
// undercount the header (spec §2.5). "" = healthy, no ink.
function marker(c) {
    var r = _rec(c);
    if (offline(c)) return "OFF";
    if (REC_BROKEN(c)) return r === REC.Stalled ? "STALLED" : "NOT REC";
    if (DET_BROKEN(c)) return "NOT READY";
    if (r === REC.Unknown) return "REC ?";
    if (r === REC.Disabled) return "OFF";
    if (r === REC.Gap) return "GAP";
    if (silent(c)) {
        var s = ms(c.lastSegmentAt);
        return s <= 0 ? "NO MOTION" : "SILENT";
    }
    return "";
}
function markerIsFault(c) { return FAULT(c) && !offline(c); }

// the compound hover badge keeps what the marker had to drop
function badgeText(c) {
    var r = _rec(c), out;
    if (r === REC.Recording) return "REC";
    if (r === REC.Stalled) return "STALLED";
    if (r === REC.Disabled) return "OFF";
    if (r === REC.NotRecording) return "NOT REC";
    if (r === REC.Gap) return "GAP";
    if (r === REC.Unknown) return "REC ?";
    out = "ARMED";
    if (notRecordingNow(c)) out += " · NOT RECORDING";
    if (DET_BROKEN(c)) out += (notRecordingNow(c) ? " + NOT READY" : " · NOT READY");
    if (out === "ARMED" && silent(c)) {
        var s = ms(c.lastSegmentAt);
        out = s <= 0 ? "no motion ever"
            : "ARMED · silent " + Math.floor((Date.now() - s) / 86400000) + "d";
    }
    return out;
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
