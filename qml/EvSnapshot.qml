import QtQuick
import QtQuick.Shapes
import Watchtower

// Procedural CCTV still — a 1:1 QML port of designs/events-v2 data.jsx `Snapshot`
// + styles.css `.snap`. The ONLY "video" in the Events redesign (no real stream).
// Pass `ev` (a store event), and `playing` / `showOsd` / `mini` variants.
// Caller sizes it (16:9 recommended); it fills the given width/height.
Item {
    id: root
    property var ev: null
    property bool playing: false
    property bool showOsd: true
    property bool showIdent: true                // top-left camera identity; a host that draws its own
                                                 // header (EvHeroPlayer) sets this false to avoid overlap
    property bool mini: false
    property bool showPlayhead: true             // Player hides this; its transport owns the scrub
    clip: true

    // Network-scheduling priority for the cvframe image provider (see CvImageProvider):
    // 2=High (focal/large frames — what the operator is actively looking at), 1=Normal
    // (visible list thumbnails), 0=Low (background). Large/non-mini snapshots default
    // High, minis Normal. The live-frame FALLBACK below fetches one tier LOWER than the
    // still, so a visible row's real still always beats another row's go2rtc fallback
    // (each fallback also wakes a VA-API transcode — the storm we want to yield). The
    // token is stable per instance (fixed with mini), so it never churns the cache /
    // refetches on scroll. Normal (1) emits no token → identical URL to before.
    property int netPriority: mini ? 1 : 2
    function _prioPfx(p) { p = Math.max(0, Math.min(2, p)); return p === 1 ? "" : ("wtp" + p + "/"); }
    // Camera identity for the OSD: "Name · IP", appending the IP only when the name
    // doesn't already contain it (backend names are often "Model (192.168.x.y)").
    function _identText(e) {
        if (!e || !e.cam) return "";
        var nm = e.cam.name || "";
        var ip = e.cam.ip || "";
        return (ip && nm.indexOf(ip) < 0) ? (nm + "   ·   " + ip) : nm;
    }

    readonly property string _type: ev ? ev.type : "motion"
    readonly property string _tod: ev ? ev.tod : "night"
    readonly property string _subject: ev ? ev.subject : "none"
    readonly property bool _isThreat: ev ? (ev.priority === "critical" || _type === "line_cross" || _type === "tamper") : false
    readonly property int _conf: (ev && ev.conf) ? Math.round(ev.conf * 100) : 0
    // Real mode → show the actual event-moment frame (GET /events/{id}/snapshot via
    // the cvframe image provider) instead of the procedural scene. Mock keeps the
    // procedural still (no backend).
    readonly property bool _real: EventsStore.realMode && !!ev && !!ev.id

    // NO EPISODE → DON'T ASK. `events/{id}/snapshot` does not serve a stored still: it
    // EXTRACTS a JPEG from recorded video at the event moment, so a 404 means exactly one
    // thing — no footage covers that moment. CV blessed the event payload itself as the
    // cheap negative (letter 2026-08-09, reply §1.3), deliberately refusing a `has_snapshot`
    // alias because "a second name for one fact is how contracts rot":
    //
    //   recordingId ""      → no episode; the request WILL 404 → skip it (this property)
    //   recordingId set,    → episode still being written; may 404 for ~60 s (fragment-flush
    //     durationSec 0       lag) → still ask, the live-frame fallback below is the bridge
    //   both set            → extraction should succeed; a 404 here is retention (>35 d) or
    //                         a server defect, and is worth reporting (warned below)
    //
    // Measured cost of not doing this: 17 218 such 404s in one 8 h session on
    // wt-sm-vnutri-01 (91% of ALL log output) — see docs/perf/2026-08-08-win-8h-soak.md.
    // Most were the motion-without-recording P1; events born inside that outage window have
    // no footage that could ever be extracted, so they 404 forever and this skip is
    // permanent for them, not a transient optimisation.
    readonly property bool _noEpisode: root._real && !!root.ev && !root.ev.recordingId

    // "The still is not coming." Skipping the request leaves evImg at status Null, NOT Error
    // — so every consumer below must test THIS, not `evImg.status === Image.Error`, or the
    // live-frame fallback and the honest "no frame" state would both silently stop firing
    // for exactly the events that need them most.
    readonly property bool _stillUnavailable: root._noEpisode || evImg.status === Image.Error

    // event still unavailable but the camera's live frame loaded → showing a "now" frame
    readonly property bool _showingLive: root._real && root._stillUnavailable && liveImg.status === Image.Ready

    Rectangle { anchors.fill: parent; color: "#0b0d10" }

    // ---- real frame (real mode): event-moment still, else the live frame ----
    Item {
        id: realFrame
        visible: root._real && root._type !== "offline"
        anchors.fill: parent
        Image {                                          // live frame fallback (below)
            id: liveImg
            anchors.fill: parent; fillMode: Image.PreserveAspectCrop
            asynchronous: true; cache: false
            sourceSize: Qt.size(width, height)           // decode at display size — full 1440p stills are ~14MB each

            // go2rtc frame.jpeg can 503 transiently / return a transient "between
            // frames" still; cache:false so one bad shared-cache entry can't blank
            // every thumbnail, + retry a few times with a cache-busting suffix.
            // (Lists are virtualised, so only the ~visible thumbnails fetch.)
            property int _retry: 0
            readonly property string _base: (root._real && root.ev && root.ev.cam && root.ev.cam.snapshotUrl) ? root.ev.cam.snapshotUrl : ""
            // LAZY: only fetch the go2rtc live frame once the event-still has actually FAILED. Fetching it
            // eagerly for every event (the old behaviour) hammered go2rtc — each frame.jpeg wakes a VA-API
            // ffmpeg transcode, and at scale this contributed to go2rtc OOM-kills (2026-06-29). Gating on
            // evImg.status===Error confines go2rtc traffic to the genuine no-stored-still fallback case.
            // Route via the cvframe provider (attaches the auth cookie) — the cached snapshot endpoint
            // requires auth and a bare QML Image sends none → 401. Strip scheme+host (backend echoes our host).
            // (…and it now also fires when we skipped the still outright — `_stillUnavailable`
            // covers both "asked and 404'd" and "knew better than to ask".)
            //
            // TIMING CHANGE worth a reviewer's eye: for a no-episode event the fallback used to
            // wait for the still's 404 to come back; now it starts immediately, so a list of
            // such events reaches go2rtc together rather than staggered by their round trips.
            // The TOTAL number of go2rtc fetches is unchanged (those events always ended up
            // here), and the cvframe provider still queues by netPriority with the fallback one
            // tier below the still — but this file's own history says eager go2rtc fetching
            // contributed to the 2026-06-29 OOM-kills, so the burstiness is the thing to watch
            // when this is exercised against a real fleet. Unmeasured from the station box.
            source: (_base === "" || !root._stillUnavailable) ? ""
                    : ("image://cvframe/" + root._prioPfx(root.netPriority - 1) + _base.replace(/^[a-z]+:\/\/[^\/]+\//, "") + (_retry > 0 ? ("?_r=" + _retry) : ""))
            visible: status === Image.Ready && evImg.status !== Image.Ready
            onStatusChanged: if (status === Image.Error && _retry < 3) liveRetry.restart()
            Timer { id: liveRetry; interval: 700; onTriggered: liveImg._retry++ }
        }
        Image {                                          // event-moment still (primary, on top)
            id: evImg
            anchors.fill: parent; fillMode: Image.PreserveAspectCrop
            asynchronous: true; cache: true
            sourceSize: Qt.size(width, height)           // requestedSize → provider downscales before caching
            source: (root._real && root.ev && !root._noEpisode)
                    ? ("image://cvframe/" + root._prioPfx(root.netPriority) + "events/" + root.ev.id + "/snapshot") : ""
            visible: status === Image.Ready
            // A 404 on an event that HAS a finished episode is the interesting one: per CV it
            // means retention (>35 d) or a server defect, unlike the two boring cases we now
            // either skip or expect. Say so once, so it is distinguishable in the flight
            // recorder instead of drowning in the noise this change removes.
            onStatusChanged: if (status === Image.Error && root.ev && root.ev.recordingId && root.ev.durationSec > 0)
                                 console.warn("EvSnapshot: snapshot 404 on a COMPLETE episode (event="
                                              + root.ev.id + " recording=" + root.ev.recordingId
                                              + " dur=" + root.ev.durationSec + "s) — retention or server-side")
        }
        // honest "no frame" only when neither the still nor the live frame loaded
        Item {
            anchors.fill: parent
            visible: root._stillUnavailable && liveImg.status !== Image.Ready
            Column { anchors.centerIn: parent; spacing: 5
                EvIcon { visible: !root.mini; anchors.horizontalCenter: parent.horizontalCenter; name: "clock"; size: 18; color: Theme.ink3 }
                Text { visible: !root.mini; text: qsTr("NO FRAME AT EVENT TIME"); color: Theme.ink3
                    font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 1.0 } }
        }
    }

    // ---- scene gradient by time-of-day ----
    Rectangle {
        anchors.fill: parent
        visible: !_real && _type !== "offline"
        gradient: Gradient {
            GradientStop { position: 0.0;  color: _tod === "night" ? "#0c1118" : _tod === "dusk" ? "#241a16" : "#2a2c2b" }
            GradientStop { position: _tod === "day" ? 0.55 : (_tod === "dusk" ? 0.5 : 0.45)
                           color: _tod === "night" ? "#0e1620" : _tod === "dusk" ? "#1a1714" : "#232423" }
            GradientStop { position: 1.0;  color: _tod === "night" ? "#0a0f15" : _tod === "dusk" ? "#100d0b" : "#191a19" }
        }
    }

    // ---- perspective grid floor + structures (scene only) ----
    Canvas {
        id: floor
        anchors.fill: parent
        visible: !_real && _type !== "offline"
        opacity: 0.16
        onPaint: {
            var ctx = getContext("2d"); ctx.reset();
            var w = width, h = height, horizon = h * 0.58;
            ctx.strokeStyle = "rgba(255,255,255,0.5)"; ctx.lineWidth = 1;
            var vpx = w * 0.5;
            // converging verticals
            for (var i = 0; i <= 12; i++) {
                var bx = (i / 12) * w * 1.4 - w * 0.2;
                ctx.beginPath(); ctx.moveTo(bx, h); ctx.lineTo(vpx, horizon); ctx.stroke();
            }
            // perspective horizontals (denser toward horizon)
            for (var j = 1; j <= 7; j++) {
                var t = j / 8, y = horizon + (h - horizon) * (t * t);
                ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(w, y); ctx.stroke();
            }
        }
        onWidthChanged: requestPaint(); onHeightChanged: requestPaint()
    }
    Rectangle { visible: !_real && _type !== "offline"; color: Qt.rgba(0,0,0,0.45)
        x: parent.width*0.04; y: parent.height*0.18; width: parent.width*0.16; height: parent.height*0.40
        Rectangle { width: parent.width; height: 1; color: Qt.rgba(1,1,1,0.06) } }
    Rectangle { visible: !_real && _type !== "offline"; color: Qt.rgba(0,0,0,0.45)
        x: parent.width*0.72; y: parent.height*0.12; width: parent.width*0.22; height: parent.height*0.30
        Rectangle { width: parent.width; height: 1; color: Qt.rgba(1,1,1,0.06) } }
    Rectangle { visible: !_real && _type !== "offline"; opacity: 0.5
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: parent.height * 0.46
        gradient: Gradient { GradientStop { position: 0; color: "transparent" } GradientStop { position: 1; color: Qt.rgba(1,1,1,0.05) } } }

    // ---- subject (person / vehicle) + AI bounding box ----
    Item {
        id: subj
        visible: !_real && _subject !== "none" && _type !== "offline" && _type !== "tamper"
        readonly property real gh: root.height * (_subject === "vehicle" ? 0.34 : 0.62)
        readonly property real gw: _subject === "vehicle" ? gh * 2.1 : gh * 0.42
        width: gw; height: gh
        x: root.width * ((ev ? ev.sx : 48) / 100)
        y: root.height - height - root.height * ((ev ? ev.sy : 8) / 100)
        Behavior on x { enabled: root.playing; NumberAnimation { duration: 2400 } }

        EvPersonGlyph { visible: _subject === "person"; anchors.fill: parent }
        EvVehicleGlyph { visible: _subject === "vehicle"; anchors.fill: parent }

        // AI detection box framing the subject (accent, or red when a threat)
        Rectangle {
            anchors.fill: parent; anchors.margins: -2
            color: "transparent"
            border.width: 1.5
            border.color: root._isThreat ? Theme.bad : Theme.accent
            Rectangle {                                  // label tab (hidden in mini)
                visible: !root.mini
                anchors.bottom: parent.top; anchors.left: parent.left; anchors.leftMargin: -1.5
                height: 14; width: lab.implicitWidth + 8
                color: root._isThreat ? Theme.bad : Theme.accent
                Text {
                    id: lab; anchors.centerIn: parent
                    text: ((EventsStore.types[root._type] ? EventsStore.types[root._type].label : qsTr("OBJECT")).split(" ")[0]).toUpperCase()
                          + (root._conf ? (" " + root._conf + "%") : "")
                    color: root._isThreat ? "#1a0f0c" : "#14110c"
                    font.family: Theme.fontMono; font.pixelSize: 9; font.weight: Font.Bold; font.letterSpacing: 0.34
                }
            }
        }
    }

    // ---- tamper / offline states ----
    Rectangle {                                          // tamper obscure
        visible: !_real && _type === "tamper"; anchors.fill: parent
        color: Qt.rgba(20/255,12/255,10/255,0.45)
        Text { visible: !root.mini; anchors.centerIn: parent; text: qsTr("VIEW OBSTRUCTED"); color: Theme.bad
            font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 1.8 }
    }
    Item {                                               // offline lost signal
        visible: _type === "offline"; anchors.fill: parent
        Rectangle { anchors.fill: parent; color: "#0a0a0a" }
        Column { anchors.centerIn: parent; spacing: 6
            EvIcon { anchors.horizontalCenter: parent.horizontalCenter; name: "offline"; size: 20; color: Theme.bad }
            Text { text: qsTr("SIGNAL LOST"); color: Theme.bad; font.family: Theme.fontMono; font.pixelSize: 11; font.letterSpacing: 2.2 } }
    }

    // ---- on-screen display (OSD) overlays ----
    Item {
        visible: root.showOsd; anchors.fill: parent
        Row {                                            // top-left: REC + camera name · IP (not the backend id)
            visible: root.showIdent
            anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 6; leftMargin: 8; rightMargin: 8 }
            spacing: 5
            Rectangle { id: recDot; anchors.verticalCenter: parent.verticalCenter; width: 6; height: 6; radius: 3; color: Theme.rec
                SequentialAnimation on opacity { running: true; loops: Animation.Infinite
                    NumberAnimation { to: 0.3; duration: 800 } NumberAnimation { to: 1.0; duration: 800 } } }
            Text { anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, root.width - 40); elide: Text.ElideRight
                // name + IP; append the IP only when the name doesn't already carry it
                // (backend names are often "Model (192.168.x.y)" — avoid doubling).
                text: root._identText(ev)
                color: Qt.rgba(1,1,1,0.8); font.family: Theme.fontMono; font.pixelSize: root.mini ? 9 : 11; font.letterSpacing: 0.3 }
        }
        Rectangle {                                      // bottom-right: event date + time, or LIVE on fallback
            anchors { bottom: parent.bottom; right: parent.right; bottomMargin: 6; rightMargin: 8 }
            color: Qt.rgba(0,0,0,0.5); radius: 2
            width: tsOsd.implicitWidth + 12; height: tsOsd.implicitHeight + 6
            Text { id: tsOsd; anchors.centerIn: parent
                text: root._showingLive ? "● LIVE"
                    : (ev ? (Qt.formatDate(ev.ts, "dd MMM").toUpperCase() + "  " + EventsStore.hhmmss(ev.ts)) : "")
                color: root._showingLive ? Theme.rec : Qt.rgba(1,1,1,0.92)
                font.family: Theme.fontMono; font.pixelSize: root.mini ? 9 : 14; font.weight: Font.Medium }
        }
        Text {                                           // bottom-left: channel / playback
            anchors { bottom: parent.bottom; left: parent.left; bottomMargin: 6; leftMargin: 8 }
            text: root.playing ? "▶ PLAYBACK" : ("CH " + (ev && ev.cam.name.match(/\d+/) ? ev.cam.name.match(/\d+/)[0] : "1"))
            color: root.playing ? Theme.accent : Qt.rgba(1,1,1,0.55); font.family: Theme.fontMono; font.pixelSize: 9
        }
    }

    // ---- scanlines + vignette + playhead ----
    Rectangle { anchors.fill: parent; color: "transparent"
        // faint scanline texture
        Repeater { model: Math.ceil(root.height / 3)
            Rectangle { y: index * 3; width: root.width; height: 1; color: Qt.rgba(0,0,0,0.10) } } }
    Rectangle { anchors.fill: parent; color: "transparent"
        // inner vignette
        gradient: Gradient { GradientStop { position: 0.0; color: "transparent" } GradientStop { position: 1.0; color: Qt.rgba(0,0,0,0.32) } } }
    Rectangle { id: ph; visible: root.playing && root.showPlayhead; anchors.bottom: parent.bottom; height: 3; color: Theme.accent
        x: 0; width: 0
        SequentialAnimation on width { running: root.playing; loops: Animation.Infinite
            NumberAnimation { from: 0; to: root.width; duration: 2600 } } }
}
