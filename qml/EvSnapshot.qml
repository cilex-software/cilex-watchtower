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
    property bool mini: false
    property bool showPlayhead: true             // Player hides this; its transport owns the scrub
    clip: true

    readonly property string _type: ev ? ev.type : "motion"
    readonly property string _tod: ev ? ev.tod : "night"
    readonly property string _subject: ev ? ev.subject : "none"
    readonly property bool _isThreat: ev ? (ev.priority === "critical" || _type === "line_cross" || _type === "tamper") : false
    readonly property int _conf: (ev && ev.conf) ? Math.round(ev.conf * 100) : 0
    // Real mode → show the actual event-moment frame (GET /events/{id}/snapshot via
    // the cvframe image provider) instead of the procedural scene. Mock keeps the
    // procedural still (no backend).
    readonly property bool _real: EventsStore.realMode && !!ev && !!ev.id
    // event still 404'd but the camera's live frame loaded → showing a "now" frame
    readonly property bool _showingLive: root._real && evImg.status === Image.Error && liveImg.status === Image.Ready

    Rectangle { anchors.fill: parent; color: "#0b0d10" }

    // ---- real frame (real mode): event-moment still, else the live frame ----
    Item {
        id: realFrame
        visible: root._real && root._type !== "offline"
        anchors.fill: parent
        Image {                                          // live frame fallback (below)
            id: liveImg
            anchors.fill: parent; fillMode: Image.PreserveAspectCrop
            asynchronous: true; cache: true
            source: (root._real && root.ev && root.ev.cam && root.ev.cam.snapshotUrl) ? root.ev.cam.snapshotUrl : ""
            visible: status === Image.Ready && evImg.status !== Image.Ready
        }
        Image {                                          // event-moment still (primary, on top)
            id: evImg
            anchors.fill: parent; fillMode: Image.PreserveAspectCrop
            asynchronous: true; cache: true
            source: (root._real && root.ev) ? ("image://cvframe/events/" + root.ev.id + "/snapshot") : ""
            visible: status === Image.Ready
        }
        // honest "no frame" only when neither the still nor the live frame loaded
        Item {
            anchors.fill: parent
            visible: evImg.status === Image.Error && liveImg.status !== Image.Ready
            Column { anchors.centerIn: parent; spacing: 5
                EvIcon { visible: !root.mini; anchors.horizontalCenter: parent.horizontalCenter; name: "clock"; size: 18; color: Theme.ink3 }
                Text { visible: !root.mini; text: "NO FRAME AT EVENT TIME"; color: Theme.ink3
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
                    text: ((EventsStore.types[root._type] ? EventsStore.types[root._type].label : "OBJECT").split(" ")[0]).toUpperCase()
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
        Text { visible: !root.mini; anchors.centerIn: parent; text: "VIEW OBSTRUCTED"; color: Theme.bad
            font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 1.8 }
    }
    Item {                                               // offline lost signal
        visible: _type === "offline"; anchors.fill: parent
        Rectangle { anchors.fill: parent; color: "#0a0a0a" }
        Column { anchors.centerIn: parent; spacing: 6
            EvIcon { anchors.horizontalCenter: parent.horizontalCenter; name: "offline"; size: 20; color: Theme.bad }
            Text { text: "SIGNAL LOST"; color: Theme.bad; font.family: Theme.fontMono; font.pixelSize: 11; font.letterSpacing: 2.2 } }
    }

    // ---- on-screen display (OSD) overlays ----
    Item {
        visible: root.showOsd; anchors.fill: parent
        Row {                                            // top-left: REC + cam id
            anchors { top: parent.top; left: parent.left; topMargin: 6; leftMargin: 8 }
            spacing: 5
            Rectangle { id: recDot; anchors.verticalCenter: parent.verticalCenter; width: 6; height: 6; radius: 3; color: Theme.rec
                SequentialAnimation on opacity { running: true; loops: Animation.Infinite
                    NumberAnimation { to: 0.3; duration: 800 } NumberAnimation { to: 1.0; duration: 800 } } }
            Text { anchors.verticalCenter: parent.verticalCenter; text: ev ? ev.cam.id.slice(0, 16) : ""
                color: Qt.rgba(1,1,1,0.7); font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 0.36 }
        }
        Text {                                           // bottom-right: event time, or LIVE on fallback
            anchors { bottom: parent.bottom; right: parent.right; bottomMargin: 6; rightMargin: 8 }
            text: root._showingLive ? "● LIVE"
                : (ev ? (Qt.formatDate(ev.ts, "dd MMM").toUpperCase() + " " + EventsStore.hhmmss(ev.ts)) : "")
            color: root._showingLive ? Theme.rec : Qt.rgba(1,1,1,0.78)
            font.family: Theme.fontMono; font.pixelSize: 9
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
