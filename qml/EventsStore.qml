pragma Singleton
import QtQuick

// ONE shared Events store — a faithful QML port of designs/events-v2/data.jsx +
// app.jsx's shared state. All four views (Triage / Verify / Timeline / Map) read
// EventsStore.events and mutate it ONLY through ack / bookmark / dispose, so the
// top-bar OPEN / CRITICAL / CLEARED counts and the same event update everywhere,
// live. Mock domain only (the design prototype is not wired to the backend yet).
QtObject {
    id: store

    // "now" — the mock design clock (2026-06-17 20:49) under loadMock, or the real
    // current time under ingestReal (so the Timeline window + "X ago" are correct).
    property var now: new Date(2026, 5, 17, 20, 49, 0)
    // REAL mode: the wall clock must TICK. It used to update only inside
    // ingestReal(), i.e. only when a new event arrived — on a quiet afternoon
    // every window/relative-time computation drifted hours into the past
    // (2026-08-04: timeline "now 09:11" at 14:47, empty lanes, wrong "ago"
    // labels). 30 s granularity is plenty for hh:mm displays.
    property Timer _nowTick: Timer {    // QtObject root: children must be properties
        interval: 30000; running: store.realMode; repeat: true
        onTriggered: store.now = new Date()
    }

    // active camera set the views' axes read (Timeline lanes, Map pins). Set by
    // loadMock() (the mock 8) or ingestReal() (real cameras from the lookup).
    property var cams: ({})

    // cameras — id, name, zone, and schematic map position (x/y %, for View 04)
    readonly property var _mockCams: ({
        "A": { key:"A", id:"hiwatch-083bc14eff9a", name:"Loading Bay — Dock 2",       zone:"Loading Bay",     x:24, y:70 },
        "B": { key:"B", id:"hiwatch-2f5e1ac033",   name:"North Perimeter — Fence 4",  zone:"North Perimeter", x:50, y:14 },
        "C": { key:"C", id:"hiwatch-9c4d77ab12",   name:"Main Entrance — Lobby",      zone:"Main Entrance",   x:50, y:88 },
        "D": { key:"D", id:"axis-p3265-east12",    name:"Parking East — Row C",       zone:"Parking — East",  x:84, y:46 },
        "E": { key:"E", id:"hiwatch-66aa0142f1",   name:"Stockroom — Aisle 1",        zone:"Stockroom",       x:30, y:42 },
        "F": { key:"F", id:"hiwatch-7b9e23cc40",   name:"Server Room — Rack A",       zone:"Server Room",     x:68, y:30 },
        "G": { key:"G", id:"axis-q1786-recep",     name:"Reception Desk",             zone:"Reception",       x:60, y:70 },
        "H": { key:"H", id:"hiwatch-1d8f90bb77",   name:"Rear Yard — Gate",           zone:"Rear Yard",       x:16, y:30 }
    })

    readonly property var types: ({
        "person":     { label:qsTr("Person detected"),  code:"AI_PERSON",  icon:"person" },
        "vehicle":    { label:qsTr("Vehicle detected"), code:"AI_VEHICLE", icon:"vehicle" },
        "motion":     { label:qsTr("Motion"),           code:"MOTION",     icon:"motion" },
        "line_cross": { label:qsTr("Line crossing"),    code:"LINE_CROSS", icon:"line_cross" },
        "loiter":     { label:qsTr("Loitering"),        code:"LOITER",     icon:"loiter" },
        "tamper":     { label:qsTr("Camera tamper"),    code:"TAMPER",     icon:"tamper" },
        "offline":    { label:qsTr("Camera offline"),   code:"CONN_LOST",  icon:"offline" }
    })

    // disposition vocabulary recorded when an event is closed
    readonly property var dispoDefs: ({
        "verified":    { label:qsTr("Verified threat"),    cls:"danger", icon:"escalate" },
        "dispatched":  { label:qsTr("Dispatched"),         cls:"danger", icon:"dispatch" },
        "authorized":  { label:qsTr("Authorized activity"), cls:"good",  icon:"check" },
        "false_alarm": { label:qsTr("False alarm"),        cls:"",       icon:"x" },
        "env":         { label:qsTr("Environmental"),      cls:"",       icon:"x" }
    })

    readonly property var sevRank: ({ "critical":0, "high":1, "medium":2, "low":3 })

    // the shared, mutable event list (reassigned wholesale on every mutation so
    // QML bindings — counts, lists, every view — re-evaluate)
    property var events: []

    // Real-data mode: events came from the live cilex-vision /events feed (via
    // ingestReal). The backend now emits severity + the full acknowledge/disposition
    // lifecycle (cilex-vision 2026-06-18), so real mode carries real severity and
    // the actions are routed to the server endpoints below — nothing is pending or
    // faked. (AI detection is null until the AI tier lands; we show it cleanly absent.)
    property bool realMode: false
    readonly property bool actionsPending: false         // backend shipped acknowledge/disposition/bookmark
    property var realAck: null                            // function(id)            → EventModel.acknowledgeById
    property var realDispose: null                        // function(id, dispo, note) → EventModel.setDisposition
    property var realBookmark: null                       // function(id, value)     → EventModel.setBookmark
    property var realAssign: null                         // function(id, assignee)  → EventModel.assignEvent
    property var realCameraScope: null                    // function(camIdOrEmpty)   → EventModel.search (server-side lane scope)
    property var realFetchOne: null                       // function(id)            → EventModel.fetchOne (share-link by-id resolve)
    signal linkResolved(var row)                          // relayed from EventModel.oneFetched by EventsArea
    signal linkResolveFailed(string eventId, int code)
    // Share-link OPEN progress (operator ask 2026-08-28). Opening a linked clip can take
    // up to ~30 s — the feed ingests asynchronously, and a CLOSED or aged event is not in
    // the loaded queue at all and needs a by-id round-trip (Main.qml linkWait). Until this
    // ask the entire wait was SILENT: `open cilex://…` raised the window onto a static
    // queue with nothing to say the clip was being looked for, which reads as "the link
    // did nothing". Lives on the store rather than on Main so every view can show it
    // without threading a property through EventsArea.
    property string linkSearchId: ""                      // "" = idle; else the event being opened
    readonly property bool linkSearching: linkSearchId !== ""
    function resolveById(id) {                            // true = a fetch is in flight, wait for the signals
        if (realMode && realFetchOne) { realFetchOne(id); return true; }
        return false;
    }
    property var operators: []                            // assignable roster (GET /operators), set by EventsArea

    function _ev(o, uid) {
        var t = new Date(store.now.getTime() - o.ago * 1000);
        var subject = (o.type === "person" || o.type === "loiter" || o.type === "line_cross") ? "person"
                    : (o.type === "vehicle" ? "vehicle" : "none");
        var e = { id:qsTr("EV-") + (7400 + uid), ts:t, status:"new", conf:null, sx:48, sy:8, tod:"night",
                  subject:subject, bookmarked:false, assignedTo:"", dispo:null, note:"", restricted:false, durationSec:0 };
        for (var k in o) e[k] = o[k];          // raw overrides defaults
        e.cam = store.cams[o.cam];             // resolve camera key → object
        return e;
    }

    // ---- MOCK source (events-v2 design demo; used under WT_DEMO / standalone) ----
    function loadMock() {
        realMode = false;
        now = new Date(2026, 5, 17, 20, 49, 0);  // anchor to the mock event ages
        cams = store._mockCams;                // views' camera axis = the mock 8
        // meaningful, mixed-priority stream over the last ~3.5h (verbatim from data.jsx)
        var raw = [
            { ago:74,   type:"person",     cam:"F", priority:"critical", conf:0.94, tod:"night", sx:54, sy:6,  durationSec:38,  restricted:true, note:"Unscheduled presence in Server Room after hours." },
            { ago:240,  type:"tamper",     cam:"A", priority:"critical", conf:0.88, tod:"night", subject:"none", durationSec:12, note:"Lens obstructed / field of view lost." },
            { ago:355,  type:"line_cross", cam:"B", priority:"critical", conf:0.91, tod:"night", sx:40, sy:10, durationSec:9,   note:"Perimeter line crossed, inbound direction." },
            { ago:520,  type:"person",     cam:"H", priority:"high",     conf:0.83, tod:"night", sx:60, sy:8,  durationSec:64,  note:"Person at rear gate, no badge event paired." },
            { ago:690,  type:"vehicle",    cam:"D", priority:"high",     conf:0.79, tod:"night", sx:30, sy:18, durationSec:182, note:"Vehicle stationary in fire lane > 3 min." },
            { ago:880,  type:"loiter",     cam:"C", priority:"high",     conf:0.74, tod:"night", sx:52, sy:9,  durationSec:214, note:"Loitering at main entrance." },
            { ago:1180, type:"person",     cam:"E", priority:"medium",   conf:0.81, tod:"night", sx:44, sy:10, durationSec:27 },
            { ago:1500, type:"vehicle",    cam:"D", priority:"medium",   conf:0.69, tod:"dusk",  sx:62, sy:20, durationSec:44 },
            { ago:1760, type:"motion",     cam:"A", priority:"medium",   subject:"none", durationSec:18, tod:"night" },
            { ago:2010, type:"person",     cam:"G", priority:"low",      conf:0.77, tod:"day",   sx:48, sy:12, durationSec:52,  note:"Likely reception staff (badge-in 18:08)." },
            { ago:2300, type:"motion",     cam:"B", priority:"low",      subject:"none", durationSec:8,  tod:"night" },
            { ago:2640, type:"motion",     cam:"E", priority:"low",      subject:"none", durationSec:14, tod:"night" },
            { ago:2980, type:"offline",    cam:"H", priority:"medium",   subject:"none", durationSec:0,  tod:"night", note:"Stream dropped — reconnect pending." },
            { ago:3260, type:"person",     cam:"C", priority:"low",      conf:0.72, tod:"dusk",  sx:40, sy:11, durationSec:33 },
            { ago:3600, type:"vehicle",    cam:"D", priority:"low",      conf:0.66, tod:"dusk",  sx:34, sy:22, durationSec:71 },
            { ago:4200, type:"motion",     cam:"A", priority:"low",      subject:"none", durationSec:21, tod:"dusk" },
            { ago:5100, type:"person",     cam:"H", priority:"medium",   conf:0.8,  tod:"dusk",  sx:55, sy:9,  durationSec:40 },
            { ago:6400, type:"motion",     cam:"G", priority:"low",      subject:"none", durationSec:11, tod:"day" },
            { ago:7600, type:"vehicle",    cam:"D", priority:"low",      conf:0.7,  tod:"day",   sx:28, sy:24, durationSec:96 },
            { ago:8800, type:"motion",     cam:"B", priority:"low",      subject:"none", durationSec:7,  tod:"day" }
        ];
        var out = [];
        for (var i = 0; i < raw.length; i++) out.push(_ev(raw[i], i));
        // pre-resolve a couple so states are visibly mixed
        out[9].status = "resolved";  out[9].dispo = "authorized";
        out[13].status = "dismissed"; out[13].dispo = "false_alarm";
        out[16].status = "ack";
        events = out;
    }

    // ---- REAL source (live cilex-vision /events via EventModel.all()) ----
    // `rows` are EventModel maps (eventId/type/camId/ts/desc/ack/durationMs/…);
    // `camLookup` resolves camId → { id, name, zone }. Every design-only field the
    // backend doesn't emit is honest-pending here — NEVER fabricated:
    //   priority → "medium" (neutral; no invented critical/high until the backend
    //              emits severity), conf → null, subject → "none" (no AI box),
    //              restricted → false, dispo → null. tod is derived from the real
    //              local time; durationSec from duration_ms.
    function ingestReal(rows, camLookup) {
        now = new Date();                      // real wall clock for window/relative-time math
        cams = camLookup ? camLookup : ({});   // views' camera axis = the real cameras
        // Collapse the motion lifecycle into ONE episode per recording_id. The backend emits motion_started
        // (exact start, null duration), motion_detected (dropped — isSuppressedType) and motion_ended (exact
        // END + duration) for EVERY episode. Shown raw, each episode duplicated into a started row AND an
        // ended row, and the wide-window player then overlapped the neighbouring episode's footage. We pair
        // started↔ended by recording_id (eventModel.all() spans every loaded page) and emit ONE row keyed
        // off the exact START with the true span [start, end].
        // Primary join key: raw_motion_event_id (CV bf49af6 — all cameras, all modes).
        // recording_id remains a LEGACY secondary (motion-enrolled cameras' history carries
        // it on all three rows; continuous cameras are honestly null there by design — the
        // "regression" we reported was a misread, owned in the 08-20 reply). Proximity
        // pairing below now runs ONLY for rows with NEITHER key — pre-bf49af6 continuous
        // history — and therefore self-clears as that history ages out.
        // FEED-SHAPE TRUTH (established 2026-08-20, the hard way): EventModel excludes
        // motion_started AND motion_ended at the wire (kExcludeTypes) — the feed is
        // motion_detected-only, one summary row per episode with duration + keys. The
        // started/ended grouping below therefore idles on this path and exists for any
        // future consumer that fetches the full lifecycle; the [EVGRP] counters make the
        // active join source visible under WT_TRACE. Yesterday's "doubled queue" claim
        // (v1.1.125 commit message) was inferred from a wrong model and is retracted in
        // docs/letters/2026-08-20 — the real defect fixed that day was the still gate.
        var groups = ({}); var order = []; var singles = [];
        var nKeyed = 0, nLegacy = 0;
        for (var i = 0; i < rows.length; i++) {
            var r = rows[i];
            var jk = r.rawMotionEventId ? ("k:" + r.rawMotionEventId)
                   : (r.recordingId ? ("r:" + r.recordingId) : "");
            if (jk !== "" && (r.type === "motion_started" || r.type === "motion_ended")) {
                if (!groups[jk]) { groups[jk] = { started: null, ended: null }; order.push(jk); }
                if (r.type === "motion_started") groups[jk].started = r; else groups[jk].ended = r;
                if (r.rawMotionEventId) nKeyed++; else nLegacy++;
            } else {
                singles.push(r);
            }
        }
        var out = [];
        for (var k = 0; k < order.length; k++) {
            var g = groups[order[k]];
            var base = g.started || g.ended;
            var sMs, eMs;
            if (g.started && g.ended) { sMs = g.started.ts; eMs = g.ended.ts; }              // exact span
            else if (g.started)       { sMs = g.started.ts; eMs = g.started.ts; }            // ended not loaded yet
            else                      { eMs = g.ended.ts; sMs = g.ended.ts - (g.ended.durationMs || 0); }  // started not loaded
            out.push(store._mkEvent(base, camLookup, sMs, Math.max(0, eMs - sMs)));
        }
        // Proximity join — THE CORRECT PATH FOR CONTINUOUS CAMERAS, not a fallback.
        // Named "fallback" here since 2026-08-20, when recording_id vanished from CV's
        // rows and this was written as damage control for what looked like their
        // storage-agent incident. It is not: CV measured 6 h of events on 2026-09-23 and
        // split them by camera profile —
        //
        //   continuous cameras   4,519 episode rows   key present on all, NON-NULL ON ZERO
        //   motion cameras       2,347 episode rows   non-null on all 2,347
        //
        // A continuous recording has no motion episode to name, so the null is permanent
        // and by design. Pairing started↔ended by the next ended on the SAME camera
        // within 10 min is therefore the RIGHT answer there, and the lifecycle guarantees
        // that ordering.
        //
        // The rule is PER ROW, not per camera: non-null recording_id → use it; null →
        // join by time. Rows WITH a key never enter this path. Per-row survives an
        // operator moving a camera between profiles, which a per-camera cache would not.
        var endedByCam = ({});
        for (var j3 = 0; j3 < singles.length; j3++) {
            var r3 = singles[j3];
            if (r3.type === "motion_ended") {
                if (!endedByCam[r3.camId]) endedByCam[r3.camId] = [];
                endedByCam[r3.camId].push(j3);
            }
        }
        var used = ({});
        var nProx = 0;
        for (var j = 0; j < singles.length; j++) {
            if (used[j]) continue;
            var sr = singles[j];
            if (sr.type === "motion_started") {
                var best = -1, bestDt = 600001;
                var cands = endedByCam[sr.camId] || [];
                for (var c = 0; c < cands.length; c++) {
                    var ei = cands[c];
                    if (used[ei]) continue;
                    var dt = singles[ei].ts - sr.ts;
                    if (dt >= 500 && dt < bestDt) { bestDt = dt; best = ei; }
                }
                if (best >= 0) {
                    used[best] = true; nProx++;
                    out.push(store._mkEvent(sr, camLookup, sr.ts, bestDt));
                    continue;
                }
            }
            out.push(store._mkEvent(sr, camLookup, sr.ts, sr.durationMs || 0));
        }
        if (typeof wtTrace !== "undefined" && wtTrace)
            console.log("[EVGRP] keyed=" + nKeyed + " legacyRec=" + nLegacy + " proximity=" + nProx
                        + " singles=" + (singles.length - nProx * 2));
        out.sort(function (a, b) { return b.ts.getTime() - a.ts.getTime(); });   // newest episode (by start) first
        realMode = true;
        events = out;
    }
    // Build one ev object from a backend row, with an explicit episode start (tsMs) + span (durMs in ms).
    function _mkEvent(r, camLookup, tsMs, durMs) {
        var t = (tsMs && tsMs > 0) ? new Date(tsMs) : store.now;
        var cam = (camLookup && camLookup[r.camId]) ? camLookup[r.camId]
                : { key: r.camId, id: r.camId, name: (r.camName ? r.camName : r.camId), zone: "", x: 50, y: 50 };
        var det = r.detection;                            // null until the AI tier lands
        var subj = det ? (det.cls === "vehicle" ? "vehicle"
                        : (det.cls === "person" || det.cls === "face") ? "person" : "none") : "none";
        return {
            id: r.eventId,
            type: store._realTypeBucket(r.type),
            rawType: ("" + r.type),
            ts: t,                                        // the episode START
            status: store._triageToStatus(r.triageState, r.ack),
            conf: (det && det.confidence >= 0) ? det.confidence : null,
            sx: 48, sy: 8,
            bbox: (det && det.bbox && det.bbox.length === 4) ? det.bbox : null,
            tod: store._todFromDate(t),                   // derived from real time
            subject: subj,                                // from detection.class (none until AI)
            bookmarked: !!r.bookmarked,
            assignedTo: (r.assignedTo ? r.assignedTo : ""),
            dispo: (r.disposition ? r.disposition : null),
            note: (r.dispositionNote ? r.dispositionNote : (r.desc ? r.desc : "")),
            restricted: !!r.zoneRestricted,
            durationSec: durMs ? Math.round(durMs / 1000) : 0,
            priority: (r.severity ? r.severity : "medium"),   // real server-computed severity
            recordingId: (r.recordingId ? r.recordingId : ""),
            clipUrl: (r.clipUrl ? r.clipUrl : ""),
            cam: cam
        };
    }

    // The wall-time span that contains an event's footage. ingestReal normalises ev.ts to the episode START
    // and ev.durationSec to the [start,end] span, so the footage is simply [ts, ts+dur]. The Triage hero
    // (session window + seek) and Export (clip range) both use this so they can't disagree on where the
    // video is.
    function episodeWindow(ev) {
        if (!ev || !ev.ts) return { startMs: 0, endMs: 0 };
        var ts = ev.ts.getTime();
        var dur = Math.max((ev.durationSec || 0) * 1000, 0);
        return { startMs: ts, endMs: ts + dur };
    }

    // backend event_type → the design's 7 display buckets (icon/pill/snapshot).
    // A documented categorisation of a REAL type, not invented data.
    function _realTypeBucket(t) {
        t = ("" + t).toLowerCase();
        if (t.indexOf("motion") === 0) return "motion";
        if (t === "line_crossing") return "line_cross";
        if (t === "intrusion" || t === "region_entrance" || t === "region_exiting") return "line_cross";
        if (t === "tamper" || t === "defocus") return "tamper";
        if (t === "video_loss" || t === "offline") return "offline";
        if (t === "face_detected") return "person";
        if (t === "loitering") return "loiter";
        return "motion";   // pir/scene_change/camera_event/online/gap/bookmark/unknown → neutral
    }
    function _todFromDate(d) {
        var h = d.getHours();
        if (h >= 19 || h < 6) return "night";
        if (h < 8 || h >= 17) return "dusk";
        return "day";
    }
    // backend triage_state → the views' status vocabulary
    function _triageToStatus(ts, ack) {
        if (ts === "acknowledged") return "ack";
        if (ts === "in_progress") return "progress";
        if (ts === "resolved") return "resolved";
        if (ts === "dismissed") return "dismissed";
        if (ts === "new") return "new";
        return ack ? "ack" : "new";        // fallback if a row lacks triage_state
    }

    // ---- shared actions (the ONLY way views mutate events) ----
    function _clone(e) { var n = {}; for (var k in e) n[k] = e[k]; return n; }
    function _patch(id, p) {
        events = events.map(function (e) {
            if (e.id !== id) return e;
            var n = store._clone(e);
            for (var k in p) n[k] = p[k];
            return n;
        });
    }
    // Real mode routes to the live EventModel POST endpoints; the model's `changed`
    // re-runs ingestReal so the row reflects the server's returned state. Mock mode
    // patches the local array.
    function ack(id) {
        if (realMode) { if (realAck) realAck(id); return; }
        _patch(id, { status:"ack" });
    }
    function bookmark(id) {
        if (realMode) {
            var cur = store.find(id);
            if (realBookmark) realBookmark(id, !(cur && cur.bookmarked));
            return;
        }
        events = events.map(function (e) {
            if (e.id !== id) return e;
            var n = store._clone(e); n.bookmarked = !e.bookmarked; return n;
        });
    }
    function dispose(id, d, note) {
        if (realMode) { if (realDispose) realDispose(id, d, note || ""); return; }
        // Mirror the backend's disposition→state map (CV 2026-06-19): verify/dispatch
        // are mid-investigation (in_progress), authorized resolves, the rest dismiss.
        var st = (d === "verified" || d === "dispatched") ? "progress"
               : (d === "false_alarm" || d === "dismissed") ? "dismissed" : "resolved";
        _patch(id, { status: st, dispo: d, note: note || "" });
    }
    // Assign to an operator username, or "" to unassign. Backend (real) transitions
    // an assigned event to in_progress; mock mirrors that.
    function assign(id, who) {
        if (realMode) { if (realAssign) realAssign(id, who || ""); return; }
        _patch(id, who ? { assignedTo: who, status: "progress" } : { assignedTo: "" });
    }
    function find(id) { for (var i = 0; i < events.length; i++) if (events[i].id === id) return events[i]; return null; }
    // Server-side camera scope for a soloed lane (2026-08-17): the loaded feed is only the
    // newest ~page of a fleet firing ~20 rows/min, so a camera quiet for minutes scrolls out
    // and a client-side solo reads as "no events" while the server holds hundreds. One
    // soloed camera asks the SERVER for its history; "" restores the shared feed.
    function cameraScope(camId) { if (realMode && realCameraScope) realCameraScope(camId || ""); }

    // ---- derived counts (top-bar chips + nav badge) ----
    readonly property int openCount:    events.filter(function (e) { return e.status === "new"; }).length
    readonly property int critCount:    events.filter(function (e) { return e.status === "new" && e.priority === "critical"; }).length
    readonly property int clearedCount: events.filter(function (e) { return e.status === "resolved"; }).length

    // ---- time helpers (port of data.jsx) ----
    function _p2(n) { return (n < 10 ? "0" : "") + n; }
    function hhmm(d)   { return _p2(d.getHours()) + ":" + _p2(d.getMinutes()); }
    function hhmmss(d) { return _p2(d.getHours()) + ":" + _p2(d.getMinutes()) + ":" + _p2(d.getSeconds()); }
    function rel(d) {
        var s = Math.round((store.now.getTime() - d.getTime()) / 1000);
        if (s < 60) return s + "s ago";
        var m = Math.round(s / 60);
        if (m < 60) return m + "m ago";
        var h = Math.floor(m / 60); return h + "h " + (m % 60) + "m ago";
    }
    function dur(sec) { var m = Math.floor(sec / 60), s = sec % 60; return m ? (m + "m " + s + "s") : (s + "s"); }
}
