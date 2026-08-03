import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Watchtower

// PTZ / motorized-lens control panel (maximized/fullscreen live view only).
// Capability truth comes from PtzClient.probe() against the backend; the
// hardware pre-gate (whether the toolbar button shows at all) lives in
// SingleCameraDetail. While the backend endpoint is pending (letter
// 2026-07-16-ptz-lens-control-endpoint.md) the panel renders an HONEST
// disabled state with the reason — controls never silently no-op.
Rectangle {
    id: root

    property var camera: null
    readonly property string camId: camera ? (camera.camId || "") : ""

    // "probing" | "pending" | "ready" | "unsupported"
    property string phase: "probing"
    property string caps: "none"          // "none" | "lens" | "ptz"
    property bool homeSupported: false
    property bool focusDead: false        // a focus command 501'd on this camera (cached)
    property string lastError: ""
    property bool resetBusy: false

    signal closed()

    width: 232
    color: Qt.rgba(0, 0, 0, 0.82)
    border.width: 1; border.color: Theme.line2
    implicitHeight: col.implicitHeight + 24
    visible: camId !== ""
    focus: visible

    onVisibleChanged: if (visible && camId !== "") { phase = "probing"; lastError = ""; focusDead = Ptz.focusDead(camId); Ptz.probe(camId) }
    onCamIdChanged:   if (visible && camId !== "") { phase = "probing"; lastError = ""; focusDead = Ptz.focusDead(camId); Ptz.probe(camId) }

    Connections {
        target: Ptz
        function onCapsReady(id, supported, home, pendingBackend) {
            if (id !== root.camId) return;
            root.caps = supported; root.homeSupported = home;
            root.phase = pendingBackend ? "pending"
                        : (supported === "none" ? "unsupported" : "ready");
        }
        function onFocusSupportChanged(id, supported) {
            if (id === root.camId) root.focusDead = !supported;
        }
        function onOpFailed(id, what, message) {
            if (id !== root.camId) return;
            if (what === "reset") root.resetBusy = false;
            root.lastError = qsTr("Command failed") + " (" + what + "): " + message;
        }
        function onOpDone(id, what) {
            if (id !== root.camId) return;
            if (what === "reset") root.resetBusy = false;
            root.lastError = "";
        }
    }

    // Keyboard drive while the panel has focus: arrows = pan/tilt, +/- = zoom.
    Keys.onPressed: (ev) => {
        if (ev.isAutoRepeat || root.phase !== "ready") return;
        switch (ev.key) {
        case Qt.Key_Left:  if (root.caps === "ptz") Ptz.continuousMove(root.camId, -0.5, 0, 0); break;
        case Qt.Key_Right: if (root.caps === "ptz") Ptz.continuousMove(root.camId,  0.5, 0, 0); break;
        case Qt.Key_Up:    if (root.caps === "ptz") Ptz.continuousMove(root.camId, 0,  0.5, 0); break;
        case Qt.Key_Down:  if (root.caps === "ptz") Ptz.continuousMove(root.camId, 0, -0.5, 0); break;
        case Qt.Key_Plus: case Qt.Key_Equal: Ptz.continuousMove(root.camId, 0, 0,  0.5); break;
        case Qt.Key_Minus:                   Ptz.continuousMove(root.camId, 0, 0, -0.5); break;
        default: return;
        }
        ev.accepted = true;
    }
    Keys.onReleased: (ev) => {
        if (ev.isAutoRepeat) return;
        switch (ev.key) {
        case Qt.Key_Left: case Qt.Key_Right: case Qt.Key_Up: case Qt.Key_Down:
        case Qt.Key_Plus: case Qt.Key_Equal: case Qt.Key_Minus:
            Ptz.stopMove(root.camId); ev.accepted = true; break;
        }
    }

    // Hold-to-move button: press starts a continuous op, release/cancel stops it.
    component HoldBtn: Rectangle {
        id: hb
        property string glyph: "chev"
        property int glyphRotation: 0
        property string tip: ""
        signal started()
        signal stopped()
        width: 34; height: 30
        color: hma.pressed ? Theme.accent : (hma.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : Qt.rgba(0, 0, 0, 0.55))
        border.width: 1; border.color: hma.containsMouse ? Theme.accent : Theme.line2
        opacity: enabled ? 1.0 : 0.35
        Icon { anchors.centerIn: parent; name: hb.glyph; size: 15
               rotation: hb.glyphRotation
               color: hma.pressed ? Theme.bg : "#ffffff" }
        MouseArea {
            id: hma; anchors.fill: parent; hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onPressed: hb.started()
            onReleased: hb.stopped()
            onCanceled: hb.stopped()
        }
        ToolTip.text: hb.tip
        ToolTip.visible: hb.tip !== "" && hma.containsMouse
        ToolTip.delay: 400
    }

    ColumnLayout {
        id: col
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
        spacing: 10

        RowLayout {
            Layout.fillWidth: true; spacing: 8
            Icon { name: "ptz"; size: 15; color: Theme.accent }
            Text { text: qsTr("PTZ / LENS"); color: Theme.ink
                   font.family: Theme.fontMono; font.pixelSize: 12; font.weight: Font.Bold }
            Text { Layout.fillWidth: true; elide: Text.ElideRight
                   text: root.camera ? (root.camera.model || "") : ""
                   color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10 }
            IconButton { name: "x"; iconSize: 13; tip: qsTr("Close")
                         iconColor: Theme.ink2; hoverIcon: Theme.ink
                         onClicked: root.closed() }
        }

        Text {
            visible: root.phase === "probing"
            text: qsTr("Checking camera capabilities…")
            color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11
        }

        // HONEST pending state: hardware can do it, backend endpoint not shipped.
        Text {
            visible: root.phase === "pending"
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: qsTr("This camera's lens is remotely controllable, but the backend does not expose PTZ/lens control yet. Specification sent to Cilex Vision (2026-07-16).")
            color: Theme.warn; font.family: Theme.fontMono; font.pixelSize: 10; lineHeight: 1.25
        }

        // Pan/tilt pad — full PTZ hardware only.
        GridLayout {
            visible: root.phase === "ready" && root.caps === "ptz"
            Layout.alignment: Qt.AlignHCenter
            columns: 3; rowSpacing: 4; columnSpacing: 4
            Item { width: 34; height: 30 }
            HoldBtn { glyph: "chev"; glyphRotation: 180; tip: qsTr("Tilt up")
                      onStarted: Ptz.continuousMove(root.camId, 0, 0.5, 0); onStopped: Ptz.stopMove(root.camId) }
            Item { width: 34; height: 30 }
            HoldBtn { glyph: "back"; tip: qsTr("Pan left")
                      onStarted: Ptz.continuousMove(root.camId, -0.5, 0, 0); onStopped: Ptz.stopMove(root.camId) }
            Item { width: 34; height: 30
                   Icon { anchors.centerIn: parent; name: "ptz"; size: 14; color: Theme.ink3 } }
            HoldBtn { glyph: "fwd"; tip: qsTr("Pan right")
                      onStarted: Ptz.continuousMove(root.camId, 0.5, 0, 0); onStopped: Ptz.stopMove(root.camId) }
            Item { width: 34; height: 30 }
            HoldBtn { glyph: "chev"; tip: qsTr("Tilt down")
                      onStarted: Ptz.continuousMove(root.camId, 0, -0.5, 0); onStopped: Ptz.stopMove(root.camId) }
            Item { width: 34; height: 30 }
        }

        // Lens rows — motorized lens and full PTZ alike.
        RowLayout {
            visible: root.phase === "ready"
            Layout.fillWidth: true; spacing: 6
            Text { text: qsTr("Zoom"); color: Theme.ink2; font.family: Theme.fontMono
                   font.pixelSize: 11; Layout.preferredWidth: 44 }
            HoldBtn { glyph: "stepBack"; tip: qsTr("Zoom out (wide)")
                      onStarted: Ptz.continuousMove(root.camId, 0, 0, -0.5); onStopped: Ptz.stopMove(root.camId) }
            HoldBtn { glyph: "stepFwd"; tip: qsTr("Zoom in (tele)")
                      onStarted: Ptz.continuousMove(root.camId, 0, 0, 0.5); onStopped: Ptz.stopMove(root.camId) }
            Item { Layout.fillWidth: true }
        }
        RowLayout {
            // Hidden once a focus command 501'd (this hardware cannot focus —
            // reply² §3); zoom above stays, the classifier's `lens` is a hint.
            visible: root.phase === "ready" && !root.focusDead
            Layout.fillWidth: true; spacing: 6
            Text { text: qsTr("Focus"); color: Theme.ink2; font.family: Theme.fontMono
                   font.pixelSize: 11; Layout.preferredWidth: 44 }
            HoldBtn { glyph: "jumpBack"; tip: qsTr("Focus near")
                      onStarted: Ptz.focusMove(root.camId, -0.5); onStopped: Ptz.focusMove(root.camId, 0) }
            HoldBtn { glyph: "jumpFwd"; tip: qsTr("Focus far")
                      onStarted: Ptz.focusMove(root.camId, 0.5); onStopped: Ptz.focusMove(root.camId, 0) }
            Rectangle {
                width: afTxt.implicitWidth + 16; height: 30
                color: afMa.containsMouse ? Theme.accent : Qt.rgba(0, 0, 0, 0.55)
                border.width: 1; border.color: afMa.containsMouse ? Theme.accent : Theme.line2
                Text { id: afTxt; anchors.centerIn: parent; text: qsTr("Auto")
                       color: afMa.containsMouse ? Theme.bg : "#ffffff"
                       font.family: Theme.fontMono; font.pixelSize: 11 }
                MouseArea { id: afMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            // Debounced entry point — one physical actuator command
                            // per camera per 5 s regardless of trigger (letter §4).
                            onClicked: Ptz.focusAutoRequest(root.camId) }
            }
            Item { Layout.fillWidth: true }
        }

        // THE single restore button — one click returns the camera to its
        // default PTZ/lens state (home preset / default zoom + autofocus).
        Rectangle {
            visible: root.phase === "ready"
            Layout.fillWidth: true; height: 32
            enabled: !root.resetBusy
            opacity: enabled ? 1.0 : 0.5
            color: rstMa.containsMouse ? Theme.accent : Qt.rgba(0, 0, 0, 0.55)
            border.width: 1; border.color: Theme.accent
            RowLayout {
                anchors.centerIn: parent; spacing: 6
                Icon { name: "ptzReset"; size: 14
                       color: rstMa.containsMouse ? Theme.bg : Theme.accent }
                Text { text: root.resetBusy ? qsTr("Restoring…") : qsTr("Restore defaults")
                       color: rstMa.containsMouse ? Theme.bg : Theme.accent
                       font.family: Theme.fontMono; font.pixelSize: 11; font.weight: Font.Bold }
            }
            MouseArea { id: rstMa; anchors.fill: parent; hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { root.resetBusy = true; Ptz.restoreDefaults(root.camId) } }
        }

        Text {
            visible: root.lastError !== ""
            Layout.fillWidth: true; wrapMode: Text.Wrap
            text: root.lastError
            color: Theme.bad; font.family: Theme.fontMono; font.pixelSize: 10
        }
    }
}
