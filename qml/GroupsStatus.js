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

// two independent axes -------------------------------------------------------
function recBroken(c) { var r = _rec(c); return r === REC.NotRecording || r === REC.Stalled; }
function detBroken(c) { return !!(c && c.motionKnown === true && c.motionReady === false); }
// detecting motion recently while the newest footage is older than that
// detection = the recorder is not writing this camera (the 2026-08-07 P1).
function notRecordingNow(c) {
    if (!c || _rec(c) !== REC.Armed || !c.motionLastVmdAt) return false;
    var v = Date.parse(c.motionLastVmdAt);
    var s = c.lastSegmentAt ? Date.parse(c.lastSegmentAt) : -1;
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
    var s = c.lastSegmentAt ? Date.parse(c.lastSegmentAt) : -1;
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
        var s = c.lastSegmentAt ? Date.parse(c.lastSegmentAt) : -1;
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
        var s = c.lastSegmentAt ? Date.parse(c.lastSegmentAt) : -1;
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
