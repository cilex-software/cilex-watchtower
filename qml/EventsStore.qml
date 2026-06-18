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
        "person":     { label:"Person detected",  code:"AI_PERSON",  icon:"person" },
        "vehicle":    { label:"Vehicle detected", code:"AI_VEHICLE", icon:"vehicle" },
        "motion":     { label:"Motion",           code:"MOTION",     icon:"motion" },
        "line_cross": { label:"Line crossing",    code:"LINE_CROSS", icon:"line_cross" },
        "loiter":     { label:"Loitering",        code:"LOITER",     icon:"loiter" },
        "tamper":     { label:"Camera tamper",    code:"TAMPER",     icon:"tamper" },
        "offline":    { label:"Camera offline",   code:"CONN_LOST",  icon:"offline" }
    })

    // disposition vocabulary recorded when an event is closed
    readonly property var dispoDefs: ({
        "verified":    { label:"Verified threat",    cls:"danger", icon:"escalate" },
        "dispatched":  { label:"Dispatched",         cls:"danger", icon:"dispatch" },
        "authorized":  { label:"Authorized activity", cls:"good",  icon:"check" },
        "false_alarm": { label:"False alarm",        cls:"",       icon:"x" },
        "env":         { label:"Environmental",      cls:"",       icon:"x" }
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
    property var operators: []                            // assignable roster (GET /operators), set by EventsArea

    function _ev(o, uid) {
        var t = new Date(store.now.getTime() - o.ago * 1000);
        var subject = (o.type === "person" || o.type === "loiter" || o.type === "line_cross") ? "person"
                    : (o.type === "vehicle" ? "vehicle" : "none");
        var e = { id:"EV-" + (7400 + uid), ts:t, status:"new", conf:null, sx:48, sy:8, tod:"night",
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
        var out = [];
        for (var i = 0; i < rows.length; i++) {
            var r = rows[i];
            var t = (r.ts && r.ts > 0) ? new Date(r.ts) : store.now;
            var cam = (camLookup && camLookup[r.camId]) ? camLookup[r.camId]
                    : { key: r.camId, id: r.camId, name: (r.camName ? r.camName : r.camId), zone: "", x: 50, y: 50 };
            var det = r.detection;                            // null until the AI tier lands
            var subj = det ? (det.cls === "vehicle" ? "vehicle"
                            : (det.cls === "person" || det.cls === "face") ? "person" : "none") : "none";
            var e = {
                id: r.eventId,
                type: store._realTypeBucket(r.type),
                rawType: ("" + r.type),
                ts: t,
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
                durationSec: r.durationMs ? Math.round(r.durationMs / 1000) : 0,
                priority: (r.severity ? r.severity : "medium"),   // real server-computed severity
                recordingId: (r.recordingId ? r.recordingId : ""),
                clipUrl: (r.clipUrl ? r.clipUrl : ""),
                cam: cam
            };
            out.push(e);
        }
        realMode = true;
        events = out;
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
        var inProgress = (d === "dispatched" || d === "verified");
        _patch(id, { status: inProgress ? "progress" : "resolved", dispo:d, note: note || "" });
    }
    // Assign to an operator username, or "" to unassign. Backend (real) transitions
    // an assigned event to in_progress; mock mirrors that.
    function assign(id, who) {
        if (realMode) { if (realAssign) realAssign(id, who || ""); return; }
        _patch(id, who ? { assignedTo: who, status: "progress" } : { assignedTo: "" });
    }
    function find(id) { for (var i = 0; i < events.length; i++) if (events[i].id === id) return events[i]; return null; }

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
