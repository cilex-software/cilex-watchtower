import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as QC
import Watchtower

// Export drawer (S06 / P4) — design handoff README §353-363 + watchtower.html
// ExportDrawer/ConfirmModal. A 440px right drawer driven by a Playback timeline
// selection: 16:9 preview frame, KV facts, HH:MM:SS.mmm range editors with
// nudges, options, required Purpose, a gap-warning ribbon computed from the real
// session fragments, and a centered confirmation modal.
//
// Backend reality: cilex-vision's POST /review/exports accepts only
// {camera_id, wall_start, wall_end, mode}. Purpose, the timestamp/camera-name
// overlays and audio have no server field yet — and exports are stream-copy, so
// burn-in overlays need a new backend path. The full UI is built per design and
// those choices are collected here for the upcoming API (see the functional spec
// in docs/letters/), but only the supported fields are sent on confirm.
Item {
    id: root
    anchors.fill: parent
    visible: false

    // ---- inputs (set by openWith) ---------------------------------------
    property var camera: null
    property string cameraId: ""
    property var frags: []             // [{cs,ce,ws,we,codec,...}] ready fragments
    property double selStartMs: -1
    property double selEndMs: -1
    property double playheadMs: 0
    property url previewSource: ""     // grabbed video frame

    // ---- editable state -------------------------------------------------
    property double startMs: 0
    property double endMs: 0
    property string purpose: "Incident review"
    property string customPurpose: ""
    property bool overlayTs: true
    property bool overlayName: true
    property bool audioOn: false
    property bool confirming: false

    signal confirmed(double startMs, double endMs, string mode)
    signal closed()

    function openWith(cam, camId, sStart, sEnd, fragments, phMs) {
        camera = cam; cameraId = camId;
        frags = fragments || [];
        selStartMs = sStart; selEndMs = sEnd;
        startMs = sStart; endMs = sEnd;
        playheadMs = phMs;
        previewSource = "";
        purpose = "Incident review"; customPurpose = "";
        overlayTs = true; overlayName = true; audioOn = false;
        confirming = false;
        visible = true;
    }
    function close() { visible = false; confirming = false; closed(); }

    // ---- helpers --------------------------------------------------------
    function pad(n, w) { var s = "" + Math.floor(n); while (s.length < (w || 2)) s = "0" + s; return s; }
    function fmtClock(ms) {
        var d = new Date(ms);
        return pad(d.getHours()) + ":" + pad(d.getMinutes()) + ":" + pad(d.getSeconds()) + "." + pad(d.getMilliseconds(), 3);
    }
    function fmtClockShort(ms) {
        var d = new Date(ms);
        return pad(d.getHours()) + ":" + pad(d.getMinutes()) + ":" + pad(d.getSeconds());
    }
    function fmtDur(ms) {
        var s = Math.max(0, Math.round(ms / 1000));
        var m = Math.floor(s / 60); s = s % 60;
        return m + "m " + pad(s) + "s";
    }
    // parse "HH:MM:SS(.mmm)" on the calendar day of baseMs; NaN if malformed
    function parseClock(text, baseMs) {
        var m = /^(\d{1,2}):(\d{2}):(\d{2})(?:\.(\d{1,3}))?$/.exec(("" + text).trim());
        if (!m) return NaN;
        var d = new Date(baseMs);
        d.setHours(parseInt(m[1]), parseInt(m[2]), parseInt(m[3]),
                   m[4] ? parseInt((m[4] + "000").slice(0, 3)) : 0);
        return d.getTime();
    }

    // footage bounds + coverage from the real fragments
    readonly property double minWs: {
        var v = Infinity;
        for (var i = 0; i < frags.length; i++) v = Math.min(v, frags[i].ws);
        return frags.length ? v : startMs;
    }
    readonly property double maxWe: {
        var v = -Infinity;
        for (var i = 0; i < frags.length; i++) v = Math.max(v, frags[i].we);
        return frags.length ? v : endMs;
    }
    function clampStart(ms) { return Math.max(minWs, Math.min(ms, endMs - 1000)); }
    function clampEnd(ms)   { return Math.min(maxWe, Math.max(ms, startMs + 1000)); }

    function coveredMs(a, b) {
        var tot = 0;
        for (var i = 0; i < frags.length; i++) {
            var lo = Math.max(a, frags[i].ws), hi = Math.min(b, frags[i].we);
            if (hi > lo) tot += hi - lo;
        }
        return tot;
    }
    // recording gaps inside [a,b] -> [{s,e}] (>250ms counts as a real gap)
    function gapsIn(a, b) {
        var cov = [];
        for (var i = 0; i < frags.length; i++) {
            var lo = Math.max(a, frags[i].ws), hi = Math.min(b, frags[i].we);
            if (hi > lo) cov.push({ s: lo, e: hi });
        }
        cov.sort(function (x, y) { return x.s - y.s; });
        var gaps = [], cur = a;
        for (var j = 0; j < cov.length; j++) {
            if (cov[j].s > cur + 250) gaps.push({ s: cur, e: cov[j].s });
            cur = Math.max(cur, cov[j].e);
        }
        if (b > cur + 250) gaps.push({ s: cur, e: b });
        return gaps;
    }

    readonly property double durMs: Math.max(0, endMs - startMs)
    readonly property var gapList: gapsIn(startMs, endMs)
    readonly property bool hasGap: gapList.length > 0
    // codec covering the midpoint (resolution isn't yet in the manifest, so the
    // tier/resolution shown is inferred from codec: hot HEVC = 1440p, warm = 720p)
    readonly property string domCodec: {
        var mid = (startMs + endMs) / 2;
        for (var i = 0; i < frags.length; i++)
            if (mid >= frags[i].ws && mid <= frags[i].we) return frags[i].codec || "hevc";
        return frags.length ? (frags[0].codec || "hevc") : "hevc";
    }
    readonly property string resLabel: domCodec === "hevc" ? "1440p" : "720p"
    // honest ~estimate: covered seconds × a rough per-tier bitrate
    readonly property double estMb: coveredMs(startMs, endMs) / 1000 * (domCodec === "hevc" ? 6.0 : 2.0) / 8
    readonly property string tzLabel: {
        var off = -(new Date(startMs).getTimezoneOffset());
        var sign = off >= 0 ? "+" : "−"; off = Math.abs(off);
        return "UTC" + sign + pad(off / 60) + ":" + pad(off % 60);
    }
    readonly property string availLabel: {
        if (!frags.length || durMs <= 0) return "—";
        var cov = coveredMs(startMs, endMs);
        if (cov >= durMs - 500) return "Continuous";
        if (cov <= 0) return "No footage";
        return "Partial · " + gapList.length + (gapList.length === 1 ? " gap" : " gaps");
    }
    readonly property string effectivePurpose: purpose === "Other…" ? customPurpose.trim() : purpose
    readonly property string overlaySummary: {
        var ov = [];
        if (overlayTs) ov.push("timestamp");
        if (overlayName) ov.push("camera-name");
        return ov.length ? (ov.join(" + ") + " overlay" + (ov.length > 1 ? "s" : "")) : "no overlays";
    }
    readonly property string camLabel: camera ? (camera.name + " (" + camera.ip + ")") : ""
    readonly property bool exportEnabled: durMs > 0 && effectivePurpose !== ""

    // ===== faint scrim (click-away closes the drawer) =====================
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.2)
        MouseArea { anchors.fill: parent; onClicked: root.close() }
    }

    // ===== faux left shadow ==============================================
    Rectangle {
        anchors.right: panel.left; anchors.top: parent.top; anchors.bottom: parent.bottom
        width: 40
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.35) }
        }
    }

    // ===== drawer panel ==================================================
    Rectangle {
        id: panel
        anchors.top: parent.top; anchors.bottom: parent.bottom; anchors.right: parent.right
        width: 440
        color: Theme.panel

        // absorb clicks on empty panel area so they don't reach the scrim
        MouseArea { anchors.fill: parent }
        // left border
        Rectangle { anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom; width: 1; color: Theme.line2 }

        // ---- header ----
        Rectangle {
            id: head
            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
            anchors.leftMargin: 1
            height: 48
            color: Theme.panel
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 16; anchors.rightMargin: 10; spacing: 8
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 1
                    Text { text: "Export clip"; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13; font.weight: Font.DemiBold }
                    Text { text: "From timeline selection"; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11 }
                }
                IconButton { name: "x"; iconColor: Theme.ink2; hoverIcon: Theme.ink; hoverBg: Theme.panel2; hoverBorder: Theme.line2; tip: "Close"; onClicked: root.close() }
            }
        }

        // ---- footer ----
        Rectangle {
            id: foot
            anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
            anchors.leftMargin: 1
            height: 58
            color: Theme.panel
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; height: 1; color: Theme.line }
            Row {
                anchors.right: parent.right; anchors.rightMargin: 16; anchors.verticalCenter: parent.verticalCenter; spacing: 8
                // Cancel (ghost)
                Rectangle {
                    implicitWidth: cancT.implicitWidth + 28; implicitHeight: 34
                    color: cancMa.containsMouse ? Theme.panel2 : "transparent"
                    Text { id: cancT; anchors.centerIn: parent; text: "Cancel"; color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
                    MouseArea { id: cancMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.close() }
                }
                // Export clip (primary)
                Rectangle {
                    implicitWidth: expRow.implicitWidth + 28; implicitHeight: 34
                    opacity: root.exportEnabled ? 1.0 : 0.55
                    color: !root.exportEnabled ? Theme.line2 : (expMa.containsMouse ? "#f0b04e" : Theme.accent)
                    Row {
                        id: expRow; anchors.centerIn: parent; spacing: 7
                        Icon { anchors.verticalCenter: parent.verticalCenter; name: "download"; size: 13; color: Theme.bg }
                        Text { anchors.verticalCenter: parent.verticalCenter; text: "Export clip"; color: Theme.bg; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.DemiBold }
                    }
                    MouseArea { id: expMa; anchors.fill: parent; enabled: root.exportEnabled; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.confirming = true }
                }
            }
        }

        // ---- body ----
        Flickable {
            id: bodyFlick
            anchors.left: parent.left; anchors.right: parent.right
            anchors.top: head.bottom; anchors.bottom: foot.top
            anchors.leftMargin: 1
            clip: true
            contentHeight: bodyCol.implicitHeight + 28
            QC.ScrollBar.vertical: QC.ScrollBar { }

            ColumnLayout {
                id: bodyCol
                x: 16; y: 14
                width: bodyFlick.width - 32
                spacing: 6

                // section eyebrow
                component SecLabel: Text {
                    Layout.fillWidth: true; Layout.topMargin: 8
                    color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11
                    font.capitalization: Font.AllUppercase; font.letterSpacing: 0.9
                }
                // KV fact row
                component KV: RowLayout {
                    id: kv
                    property string k: ""
                    property string v: ""
                    property color vColor: Theme.ink
                    Layout.fillWidth: true; spacing: 8
                    Text { text: kv.k; color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12; Layout.fillWidth: true }
                    Text { text: kv.v; color: kv.vColor; font.family: Theme.fontMono; font.pixelSize: 11; horizontalAlignment: Text.AlignRight }
                }
                // option checkbox
                component OptCheck: Item {
                    id: cb
                    property string label: ""
                    property bool isOn: false
                    property bool active: true
                    property string hint: ""
                    signal toggled()
                    Layout.fillWidth: true
                    implicitHeight: 30
                    Row {
                        anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter; spacing: 10
                        Rectangle {
                            width: 16; height: 16; anchors.verticalCenter: parent.verticalCenter
                            color: cb.isOn ? Theme.accent : "transparent"
                            border.width: 1; border.color: cb.isOn ? Theme.accent : Theme.line2
                            opacity: cb.active ? 1 : 0.4
                            Icon { anchors.centerIn: parent; visible: cb.isOn; name: "check"; size: 11; color: Theme.bg }
                        }
                        Text { anchors.verticalCenter: parent.verticalCenter; text: cb.label; color: cb.active ? Theme.ink : Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 13 }
                        Text { anchors.verticalCenter: parent.verticalCenter; visible: cb.hint !== ""; text: cb.hint; color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12 }
                    }
                    MouseArea { anchors.fill: parent; enabled: cb.active; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: cb.toggled() }
                }
                // ghost nudge button
                component Nudge: Rectangle {
                    id: nb
                    property string label: ""
                    signal clicked()
                    implicitWidth: nbT.implicitWidth + 16; implicitHeight: 24
                    color: nbMa.containsMouse ? Theme.panel2 : "transparent"
                    border.width: 1; border.color: nbMa.containsMouse ? Theme.accent : Theme.line2
                    Text { id: nbT; anchors.centerIn: parent; text: nb.label; color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 11 }
                    MouseArea { id: nbMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: nb.clicked() }
                }

                // --- 16:9 preview ---
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: width * 9 / 16
                    color: "#000"
                    border.width: 1; border.color: Theme.line2
                    Image {
                        anchors.fill: parent; anchors.margins: 1
                        source: root.previewSource
                        fillMode: Image.PreserveAspectFit
                        visible: root.previewSource != ""
                    }
                    Text {
                        anchors.centerIn: parent; visible: root.previewSource == ""
                        text: "No preview frame"; color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12
                    }
                    Rectangle {
                        anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.margins: 6
                        color: Qt.rgba(11 / 255, 14 / 255, 18 / 255, 0.85)
                        implicitWidth: rib.implicitWidth + 12; implicitHeight: 18
                        Text { id: rib; anchors.centerIn: parent; text: "PREVIEW · NOT LIVE"; color: Theme.warn; font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 0.6 }
                    }
                }

                // --- KV facts ---
                Item { Layout.preferredHeight: 4 }
                KV { k: "Camera"; v: root.camLabel }
                KV { k: "Group"; v: root.camera ? root.camera.groupName : "—" }
                KV { k: "Timezone"; v: root.tzLabel }
                KV { k: "Recording avail."; v: root.availLabel; vColor: root.availLabel === "Continuous" ? Theme.accent : (root.availLabel.indexOf("Partial") === 0 ? Theme.warn : Theme.ink) }
                KV { k: "Est. size"; v: "~ " + Math.max(1, Math.round(root.estMb)) + " MB" }

                // --- range ---
                SecLabel { text: "Range" }
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    // start
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 6
                        Text { text: "Start"; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10; font.capitalization: Font.AllUppercase; font.letterSpacing: 1.2; font.weight: Font.DemiBold }
                        Rectangle {
                            Layout.fillWidth: true; implicitHeight: 34
                            color: Theme.bg; border.width: 1; border.color: startInp.activeFocus ? Theme.accent : Theme.line2
                            TextInput {
                                id: startInp
                                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                                verticalAlignment: TextInput.AlignVCenter
                                color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 13
                                selectByMouse: true
                                Component.onCompleted: text = root.fmtClock(root.startMs)
                                onEditingFinished: {
                                    var ms = root.parseClock(text, root.startMs);
                                    if (!isNaN(ms)) root.startMs = root.clampStart(ms);
                                    text = root.fmtClock(root.startMs);
                                }
                                Connections {
                                    target: root
                                    function onStartMsChanged() { if (!startInp.activeFocus) startInp.text = root.fmtClock(root.startMs); }
                                }
                            }
                        }
                    }
                    // end
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 6
                        Text { text: "End"; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10; font.capitalization: Font.AllUppercase; font.letterSpacing: 1.2; font.weight: Font.DemiBold }
                        Rectangle {
                            Layout.fillWidth: true; implicitHeight: 34
                            color: Theme.bg; border.width: 1; border.color: endInp.activeFocus ? Theme.accent : Theme.line2
                            TextInput {
                                id: endInp
                                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                                verticalAlignment: TextInput.AlignVCenter
                                color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 13
                                selectByMouse: true
                                Component.onCompleted: text = root.fmtClock(root.endMs)
                                onEditingFinished: {
                                    var ms = root.parseClock(text, root.endMs);
                                    if (!isNaN(ms)) root.endMs = root.clampEnd(ms);
                                    text = root.fmtClock(root.endMs);
                                }
                                Connections {
                                    target: root
                                    function onEndMsChanged() { if (!endInp.activeFocus) endInp.text = root.fmtClock(root.endMs); }
                                }
                            }
                        }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true; Layout.topMargin: 2; spacing: 4
                    Nudge { label: "−1s"; onClicked: root.endMs = root.clampEnd(root.endMs - 1000) }
                    Nudge { label: "+1s"; onClicked: root.endMs = root.clampEnd(root.endMs + 1000) }
                    Nudge { label: "Set start from playhead"; onClicked: root.startMs = root.clampStart(root.playheadMs) }
                    Item { Layout.fillWidth: true }
                }

                // --- options ---
                SecLabel { text: "Options" }
                OptCheck { label: "Include timestamp overlay"; isOn: root.overlayTs; onToggled: root.overlayTs = !root.overlayTs }
                OptCheck { label: "Include camera-name overlay"; isOn: root.overlayName; onToggled: root.overlayName = !root.overlayName }
                OptCheck { label: "Include audio"; isOn: root.audioOn; active: false; hint: "(unavailable — video export only)" }
                Text {
                    Layout.fillWidth: true; Layout.topMargin: 2
                    text: "Overlays & purpose travel with your request; server-side application is pending Cilex Vision support (exports are stream-copy today). Video export works now."
                    color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11; wrapMode: Text.WordWrap; lineHeight: 1.3
                }

                // --- purpose (required) ---
                RowLayout {
                    Layout.fillWidth: true; Layout.topMargin: 8; spacing: 4
                    Text { text: "Purpose"; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11; font.capitalization: Font.AllUppercase; font.letterSpacing: 0.9 }
                    Text { text: "*"; color: Theme.bad; font.family: Theme.fontMono; font.pixelSize: 11 }
                    Item { Layout.fillWidth: true }
                }
                Rectangle {
                    id: purposeField
                    Layout.fillWidth: true; implicitHeight: 34
                    color: Theme.bg; border.width: 1; border.color: purposePop.visible ? Theme.accent : Theme.line2
                    Text { anchors.left: parent.left; anchors.leftMargin: 12; anchors.right: chev.left; anchors.verticalCenter: parent.verticalCenter; elide: Text.ElideRight; text: root.purpose; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13 }
                    Icon { id: chev; anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter; name: "chev"; size: 12; color: Theme.ink3 }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: purposePop.visible ? purposePop.close() : purposePop.open() }
                    QC.Popup {
                        id: purposePop
                        y: parent.height + 2; x: 0; width: parent.width
                        padding: 1
                        background: Rectangle { color: Theme.panel2; border.width: 1; border.color: Theme.line2 }
                        contentItem: Column {
                            Repeater {
                                model: ["Incident review", "Police request", "Customer complaint", "Internal investigation", "Maintenance check", "Other…"]
                                delegate: Rectangle {
                                    required property string modelData
                                    width: purposePop.width - 2; height: 30
                                    color: optMa.containsMouse ? Theme.accentSoft : "transparent"
                                    Text { anchors.left: parent.left; anchors.leftMargin: 11; anchors.verticalCenter: parent.verticalCenter; text: modelData; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13 }
                                    MouseArea { id: optMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: { root.purpose = modelData; purposePop.close(); } }
                                }
                            }
                        }
                    }
                }
                // free-text when "Other…"
                Rectangle {
                    Layout.fillWidth: true; implicitHeight: 34; visible: root.purpose === "Other…"
                    color: Theme.bg; border.width: 1; border.color: custInp.activeFocus ? Theme.accent : Theme.line2
                    TextInput {
                        id: custInp
                        anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                        verticalAlignment: TextInput.AlignVCenter
                        color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13
                        selectByMouse: true
                        text: root.customPurpose
                        onTextChanged: root.customPurpose = text
                    }
                    Text { visible: custInp.text === ""; anchors.left: parent.left; anchors.leftMargin: 12; anchors.verticalCenter: parent.verticalCenter; text: "Describe the purpose…"; color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 13 }
                }

                // --- gap warning ---
                Rectangle {
                    Layout.fillWidth: true; Layout.topMargin: 8
                    visible: root.hasGap
                    color: Theme.accentSoft; border.width: 1; border.color: Theme.warnDim
                    implicitHeight: gapCol.implicitHeight + 20
                    Column {
                        id: gapCol
                        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 10
                        spacing: 4
                        Text {
                            width: parent.width; wrapMode: Text.WordWrap
                            text: "⚠ Selection spans " + (root.gapList.length === 1 ? "a recording gap" : root.gapList.length + " recording gaps") + ". The export will contain a freeze frame for:"
                            color: Theme.warn; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.DemiBold; lineHeight: 1.3
                        }
                        Repeater {
                            model: root.gapList
                            delegate: Text {
                                required property var modelData
                                text: "· " + root.fmtClockShort(modelData.s) + " – " + root.fmtClockShort(modelData.e) + "  (" + Math.round((modelData.e - modelData.s) / 1000) + "s)"
                                color: Theme.warn; font.family: Theme.fontMono; font.pixelSize: 11
                            }
                        }
                    }
                }
            }
        }
    }

    // ===== confirmation modal ============================================
    Rectangle {
        anchors.fill: parent
        visible: root.confirming
        color: Qt.rgba(0, 0, 0, 0.65)
        MouseArea { anchors.fill: parent; onClicked: root.confirming = false }

        Rectangle {
            anchors.centerIn: parent
            width: 500
            implicitHeight: mHead.height + mBody.implicitHeight + mFoot.height
            color: Theme.panel
            border.width: 1; border.color: Theme.accent
            MouseArea { anchors.fill: parent }   // eat clicks inside the modal

            Rectangle {
                id: mHead
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                height: 56; color: Theme.panel
                Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
                Text { anchors.left: parent.left; anchors.leftMargin: 22; anchors.verticalCenter: parent.verticalCenter; text: "Confirm export"; color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 16; font.weight: Font.DemiBold }
                IconButton { anchors.right: parent.right; anchors.rightMargin: 14; anchors.verticalCenter: parent.verticalCenter; name: "x"; iconColor: Theme.ink2; hoverIcon: Theme.ink; hoverBg: Theme.panel2; hoverBorder: Theme.line2; tip: "Cancel"; onClicked: root.confirming = false }
            }

            ColumnLayout {
                id: mBody
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: mHead.bottom
                anchors.leftMargin: 22; anchors.rightMargin: 22; anchors.topMargin: 20
                spacing: 12
                Text {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap; textFormat: Text.StyledText
                    text: "You are about to export footage from <b>" + root.camLabel + "</b> for <b>"
                          + root.fmtClockShort(root.startMs) + " – " + root.fmtClockShort(root.endMs)
                          + "</b> (<b>" + root.fmtDur(root.durMs) + "</b>) for purpose <b>"
                          + (root.effectivePurpose === "" ? "—" : root.effectivePurpose) + "</b>."
                    color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13; lineHeight: 1.5
                }
                Rectangle {
                    Layout.fillWidth: true
                    color: Theme.bg
                    implicitHeight: factCol.implicitHeight + 20
                    Column {
                        id: factCol
                        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 10
                        spacing: 4
                        Text { text: "• MP4 · " + root.resLabel + " · " + root.overlaySummary; color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12 }
                        Text { text: "• This export will be visible to your supervisor"; color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12 }
                        Text { text: "• Estimated size: ~ " + Math.max(1, Math.round(root.estMb)) + " MB"; color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12 }
                        Text { visible: root.overlayTs || root.overlayName; text: "• Overlays pending backend support — not applied to this export yet"; color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12 }
                    }
                }
            }

            Rectangle {
                id: mFoot
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: mBody.bottom
                anchors.topMargin: 16
                height: 60; color: Theme.bg
                Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; height: 1; color: Theme.line }
                Row {
                    anchors.right: parent.right; anchors.rightMargin: 22; anchors.verticalCenter: parent.verticalCenter; spacing: 8
                    Rectangle {
                        implicitWidth: cT.implicitWidth + 28; implicitHeight: 34
                        color: cMa.containsMouse ? Theme.panel2 : "transparent"
                        Text { id: cT; anchors.centerIn: parent; text: "Cancel"; color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
                        MouseArea { id: cMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.confirming = false }
                    }
                    Rectangle {
                        implicitWidth: okT.implicitWidth + 28; implicitHeight: 34
                        color: okMa.containsMouse ? "#f0b04e" : Theme.accent
                        Text { id: okT; anchors.centerIn: parent; text: "Confirm export"; color: Theme.bg; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.DemiBold }
                        MouseArea {
                            id: okMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: { root.confirmed(root.startMs, root.endMs, "wallclock"); root.close(); }
                        }
                    }
                }
            }
        }
    }

    // Esc closes the modal first, then the drawer
    Keys.onEscapePressed: (e) => { if (root.confirming) root.confirming = false; else root.close(); e.accepted = true; }
    focus: visible
}
