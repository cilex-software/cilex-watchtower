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
    property var client: null          // PlaybackClient — for sessionHevcCapable, below
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
    property string mode: "wallclock"   // wallclock = freeze gaps (timeline preserved); compact = drop gaps
    property string quality: "high"     // "high" = HEVC 1440p original (main); "standard" = H.264 720p (sub)
    property int compHeight: 0          // client compression target height (0 = original size)
    property bool confirming: false

    signal confirmed(double startMs, double endMs, string mode, string purpose, string quality,
                     int compHeight, bool burnTimestamp, bool burnName)
    signal closed()

    function openWith(cam, camId, sStart, sEnd, fragments, phMs) {
        camera = cam; cameraId = camId;
        frags = fragments || [];
        selStartMs = sStart; selEndMs = sEnd;
        startMs = sStart; endMs = sEnd;
        playheadMs = phMs;
        previewSource = "";
        purpose = "Incident review"; customPurpose = "";
        mode = "wallclock";
        quality = "high";   // default to the best; falls back to standard if the original has aged out
        compHeight = 0;     // original size by default
        overlayTs = false; overlayName = false; audioOn = false;   // pristine clip by default; overlays opt-in (they re-encode)
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
    // Quality model: the footage is dual-recorded — a high-res HEVC 1440p "original"
    // (main stream, kept a limited time) and an H.264 720p "standard" (sub stream,
    // kept the full retention). The manifest carries codec + resolution per fragment,
    // so we know — per slice of the selection — whether the original is still there.
    function _isHigh(f) {
        // CORRECTION 2026-09-22. This said `stream_type` was "the backend's
        // authoritative 'is the high-res original retained for this span'".
        // MEASURED FALSE by cilex-vision against the live DB: `10 Улица 15`,
        // 02:55–03:01 that morning, carried 12 main/hot segments AND 12 sub/warm
        // segments one-for-one — the H.265 original fully retained — while the
        // manifest reported every fragment as `sub`.
        //
        // `stream_type` reports which stream the manifest SELECTED, and that is
        // chosen by the `hevc_capable` the SESSION asked for: main-first when
        // true, sub-first when false (cilex-vision review.py:209-211, and the
        // merge at :155-175 takes every sub segment, filling only uncovered
        // spans with main). So it is evidence about retention ONLY on a
        // main-first session. Our macOS build must send false — Apple's HLS
        // rules forbid HEVC-in-MPEG-TS (PlaybackClient.cpp:295-303) — so there
        // every fragment is `sub` and this function answers "aged out" about
        // footage minutes old. That is the defect in
        // docs/letters/2026-09-22-the-export-drawer-tells-mac-operators-...md.
        //
        // Do NOT reach for `tier` instead: THREE combinations are live, not two
        // — hot/main, warm/main and warm/sub (cilex-vision, measured same day),
        // so warm does not imply sub. And do not infer "main exists wherever a
        // fragment exists": sub-without-main is currently zero across 10,779
        // camera-hours, but that zero is disk pressure, not an invariant —
        // `rebalancer._expire_hot_with_twin` is shipped and armed to delete a
        // hot main wherever a sub twin spans its midpoint, at hot_days=8, and
        // has never fired only because the governor evicts at ~5.5 days. Two
        // 22 TB disks landed 2026-09-17. When retention crosses eight days that
        // rule starts lying OPTIMISTICALLY, which is the direction that misleads
        // an operator.
        //
        // Fall back to a codec/resolution guess only for legacy fragments that
        // predate stream_type.
        var st = ("" + (f.stream_type || "")).toLowerCase();
        if (st === "main") return true;
        if (st === "sub") return false;
        var c = ("" + (f.codec || "")).toLowerCase();
        if (c === "hevc" || c === "h265") return true;
        var r = "" + (f.resolution || "");
        return r.indexOf("2160") >= 0 || r.indexOf("1440") >= 0 || r.indexOf("1080") >= 0;
    }
    // High-quality export is only offered if the WHOLE selection is still covered by
    // the high-res original; if any covered span has aged to the 720p sub, it isn't.
    // CAN THE MANIFEST TESTIFY AT ALL? Only if we asked the server for the high-res
    // original. macOS forces hevc_capable=false on the playback session (Apple's HLS
    // rules bar HEVC-in-TS), so every fragment comes back as the 720p sub REGARDLESS of
    // what is in storage — and reading retention out of that says "aged out" for
    // footage recorded one minute ago. Verified the other way round on 2026-09-22:
    // POST /review/exports with hevc_capable=true for 02:58 that morning returned
    // 2560x1440, while this drawer was calling the same window aged out.
    //
    // So when we cannot know, we OFFER High and let CV adjudicate. Its 422 path already
    // exists and already carries the backend's own explanation
    // (PlaybackClient.cpp, createExport), which is a true statement from the party that
    // knows, in place of a false one from the party that cannot. Diagnosis and fix from
    // the Linux dev box (letter 2026-09-22, "the export drawer tells mac operators
    // their footage aged out when it did not", option (a) + the copy half of (b)).
    readonly property bool retentionKnowable: client ? client.sessionHevcCapable !== false : true

    readonly property bool highAvailable: {
        if (!retentionKnowable) return true;          // unknown is not "aged out"
        if (!frags.length || durMs <= 0) return false;
        var anyHigh = false;
        for (var i = 0; i < frags.length; i++) {
            var lo = Math.max(startMs, frags[i].ws), hi = Math.min(endMs, frags[i].we);
            if (hi <= lo) continue;                       // fragment doesn't overlap the selection
            if (_isHigh(frags[i])) anyHigh = true; else return false;
        }
        return anyHigh;
    }
    readonly property bool highMixed: {                   // some original, some aged-out within the selection
        if (!retentionKnowable) return false;             // never claim a mix we cannot see
        var hi = false, lo = false;
        for (var i = 0; i < frags.length; i++) {
            var a = Math.max(startMs, frags[i].ws), b = Math.min(endMs, frags[i].we);
            if (b <= a) continue;
            if (_isHigh(frags[i])) hi = true; else lo = true;
        }
        return hi && lo;
    }
    readonly property string highUnavailReason: highMixed
        ? "Part of this selection has aged into standard-quality storage (720p), so the high-quality original can't cover the whole clip."
        : "The high-quality original (1440p) is kept for a limited time, and this footage has aged into standard-quality storage (720p)."
    // Standard existence is now a per-camera FACT on the roster (has_sub_recording,
    // observed-not-declared; CV d690e52). Tri-state: -1 old-server/unknown (behave as
    // before), 0 = this camera never records the sub (motion cameras) — Standard is
    // not offered rather than offered-then-failed, 1 = sub present.
    readonly property int camSub: (camera && camera.hasSubRecording !== undefined) ? camera.hasSubRecording : -1
    readonly property bool standardKnownAbsent: camSub === 0
    // The quality actually used: the pick, unless high was chosen but isn't available.
    // A camera with no Standard rendition always exports High (its main IS the
    // full-retention copy for motion cameras, so highAvailable holds in practice).
    readonly property string effectiveQuality: standardKnownAbsent ? "high"
        : (quality === "high" && highAvailable) ? "high" : "standard"
    // Source rendition height (confirmed against real exports): High = the 1440p main
    // original; Standard = the 720p sub, now delivered natively at 720p (CV shipped the
    // h264-main-720p rendition — no more 1080p upscale; the job's resolution reports 1280×720).
    readonly property int sourceHeight: effectiveQuality === "high" ? 1440 : 720
    // Compression-ladder target (0 = keep source). A target ≥ the source height would be
    // an upscale / no-op, so it collapses to Original.
    readonly property int effectiveCompHeight: (compHeight > 0 && compHeight < sourceHeight) ? compHeight : 0
    readonly property int outHeight: effectiveCompHeight > 0 ? effectiveCompHeight : sourceHeight
    readonly property string resLabel: outHeight + "p"
    // We transcode locally only when there's actual work (downscale and/or overlays).
    readonly property bool willTranscode: effectiveCompHeight > 0 || overlayTs || overlayName
    // honest ~estimate: covered seconds × a rough per-output-height bitrate
    readonly property double estMb: {
        var br = outHeight >= 1440 ? 6.0 : outHeight >= 1080 ? 4.0 : outHeight >= 720 ? 2.0 : 1.0;
        return coveredMs(startMs, endMs) / 1000 * br / 8;
    }
    readonly property string tzLabel: {
        var off = -(new Date(startMs).getTimezoneOffset());
        var sign = off >= 0 ? "+" : "−"; off = Math.abs(off);
        return qsTr("UTC") + sign + pad(off / 60) + ":" + pad(off % 60);
    }
    readonly property string availLabel: {
        if (!frags.length || durMs <= 0) return "—";
        var cov = coveredMs(startMs, endMs);
        if (cov >= durMs - 500) return qsTr("Continuous");
        if (cov <= 0) return qsTr("No footage");
        return qsTr("Partial · ") + gapList.length + (gapList.length === 1 ? " gap" : " gaps");
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
                    Text { text: qsTr("Export clip"); color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 13; font.weight: Font.DemiBold }
                    Text { text: qsTr("From timeline selection"); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11 }
                }
                IconButton { name: "x"; iconColor: Theme.ink2; hoverIcon: Theme.ink; hoverBg: Theme.panel2; hoverBorder: Theme.line2; tip: qsTr("Close"); onClicked: root.close() }
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
                    Text { id: cancT; anchors.centerIn: parent; text: qsTr("Cancel"); color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
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
                        Text { anchors.verticalCenter: parent.verticalCenter; text: qsTr("Export clip"); color: Theme.bg; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.DemiBold }
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
                        asynchronous: true
                        sourceSize.width: 800
                        visible: root.previewSource != ""
                    }
                    Text {
                        anchors.centerIn: parent; visible: root.previewSource == ""
                        text: qsTr("No preview frame"); color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12
                    }
                    Rectangle {
                        anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.margins: 6
                        color: Qt.rgba(11 / 255, 14 / 255, 18 / 255, 0.85)
                        implicitWidth: rib.implicitWidth + 12; implicitHeight: 18
                        Text { id: rib; anchors.centerIn: parent; text: qsTr("PREVIEW · NOT LIVE"); color: Theme.warn; font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 0.6 }
                    }
                }

                // --- KV facts ---
                Item { Layout.preferredHeight: 4 }
                KV { k: "Camera"; v: root.camLabel }
                KV { k: "Group"; v: root.camera ? root.camera.groupName : "—" }
                KV { k: "Timezone"; v: root.tzLabel }
                KV { k: "Recording avail."; v: root.availLabel; vColor: root.availLabel === "Continuous" ? Theme.accent : (root.availLabel.indexOf("Partial") === 0 ? Theme.warn : Theme.ink) }
                KV { k: "Est. size"; v: "~ " + Math.max(1, Math.round(root.estMb)) + " MB" }
                KV { k: "Saves to"; v: Artifacts.exportDir }

                // --- range ---
                SecLabel { text: qsTr("Range") }
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    // start
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 6
                        Text { text: qsTr("Start"); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10; font.capitalization: Font.AllUppercase; font.letterSpacing: 1.2; font.weight: Font.DemiBold }
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
                        Text { text: qsTr("End"); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10; font.capitalization: Font.AllUppercase; font.letterSpacing: 1.2; font.weight: Font.DemiBold }
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
                    Nudge { label: qsTr("−1s"); onClicked: root.endMs = root.clampEnd(root.endMs - 1000) }
                    Nudge { label: qsTr("+1s"); onClicked: root.endMs = root.clampEnd(root.endMs + 1000) }
                    Nudge { label: qsTr("Set start from playhead"); onClicked: root.startMs = root.clampStart(root.playheadMs) }
                    Item { Layout.fillWidth: true }
                }

                // --- quality: high-res original vs standard sub ---
                SecLabel { text: qsTr("Quality") }
                RowLayout {
                    Layout.fillWidth: true; spacing: 6
                    // High quality (HEVC 1440p original) — grays out (with a tooltip)
                    // when the original has aged out of storage for any part of the
                    // selection; the user's explicit ask.
                    Rectangle {
                        id: hqBtn
                        Layout.fillWidth: true; implicitHeight: 46
                        readonly property bool on: root.effectiveQuality === "high"
                        color: !root.highAvailable ? Theme.bg
                             : (on ? Theme.accentSoft : (hqMa.containsMouse ? Theme.panel2 : Theme.bg))
                        border.width: 1; border.color: on ? Theme.accent : Theme.line2
                        opacity: root.highAvailable ? 1 : 0.45
                        Column {
                            anchors.centerIn: parent; spacing: 1
                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: qsTr("High quality")
                                color: hqBtn.on ? Theme.accent : Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: qsTr("1440p · original")
                                color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 9 }
                        }
                        MouseArea {
                            id: hqMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: root.highAvailable ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: if (root.highAvailable) root.quality = "high"
                        }
                        // explain the gray-out on hover
                        Rectangle {
                            visible: hqMa.containsMouse && !root.highAvailable
                            z: 100
                            anchors.left: parent.left; anchors.top: parent.bottom; anchors.topMargin: 4
                            width: Math.min(300, root.width - 80)
                            implicitHeight: ttT.implicitHeight + 14
                            color: "#10141a"; border.width: 1; border.color: Theme.warnDim; radius: 2
                            Text {
                                id: ttT; anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                                anchors.margins: 7; wrapMode: Text.WordWrap
                                text: root.highUnavailReason
                                color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 11; lineHeight: 1.25
                            }
                        }
                    }
                    // Standard quality (H.264 720p sub) — full retention WHERE RECORDED.
                    // Motion cameras never record it (has_sub_recording=false): the
                    // option renders disabled with the truth, instead of the old
                    // offer -> 422 -> apologize flow (operator report 2026-08-22).
                    Rectangle {
                        id: sqBtn
                        Layout.fillWidth: true; implicitHeight: 46
                        readonly property bool on: root.effectiveQuality === "standard"
                        readonly property bool absent: root.standardKnownAbsent
                        opacity: absent ? 0.45 : 1
                        color: on ? Theme.accentSoft : (sqMa.containsMouse && !absent ? Theme.panel2 : Theme.bg)
                        border.width: 1; border.color: on ? Theme.accent : Theme.line2
                        Column {
                            anchors.centerIn: parent; spacing: 1
                            Text { anchors.horizontalCenter: parent.horizontalCenter; text: qsTr("Standard quality")
                                color: sqBtn.on ? Theme.accent : Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
                            Text { anchors.horizontalCenter: parent.horizontalCenter
                                text: sqBtn.absent ? qsTr("not recorded on this camera") : qsTr("720p · smaller file")
                                color: sqBtn.absent ? Theme.warn : Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 9 }
                        }
                        MouseArea { id: sqMa; anchors.fill: parent; hoverEnabled: true
                            cursorShape: sqBtn.absent ? Qt.ArrowCursor : Qt.PointingHandCursor
                            onClicked: if (!sqBtn.absent) root.quality = "standard" }
                    }
                }
                Text {
                    Layout.fillWidth: true; Layout.topMargin: 2
                    text: qsTr("High quality is the full-resolution original (1440p, kept a limited time); standard is the smaller, universally-playable copy. The original ages out of storage after a few days — once it has, only standard is available for that footage.")
                    color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11; wrapMode: Text.WordWrap; lineHeight: 1.3
                }

                // --- compression (client-side local re-encode) ---
                SecLabel { text: qsTr("Compression") }
                RowLayout {
                    Layout.fillWidth: true; spacing: 6
                    Repeater {
                        model: [ { h: 0, l: "Original" }, { h: 1080, l: "1080p" }, { h: 720, l: "720p" }, { h: 480, l: "480p" } ]
                        delegate: Rectangle {
                            id: compBtn
                            required property var modelData
                            Layout.fillWidth: true; implicitHeight: 38
                            // a size at/above the source is an upscale → unavailable
                            readonly property bool avail: modelData.h === 0 || modelData.h < root.sourceHeight
                            readonly property bool on: root.effectiveCompHeight === modelData.h
                            color: !avail ? Theme.bg : (on ? Theme.accentSoft : (compMa.containsMouse ? Theme.panel2 : Theme.bg))
                            border.width: 1; border.color: on ? Theme.accent : Theme.line2
                            opacity: avail ? 1 : 0.4
                            Text { anchors.centerIn: parent; text: compBtn.modelData.l
                                color: compBtn.on ? Theme.accent : Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
                            MouseArea { id: compMa; anchors.fill: parent; hoverEnabled: true
                                cursorShape: compBtn.avail ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onClicked: if (compBtn.avail) root.compHeight = compBtn.modelData.h }
                        }
                    }
                }

                // --- options ---
                SecLabel { text: qsTr("Options") }
                OptCheck { label: qsTr("Burn in timestamp overlay"); isOn: root.overlayTs; onToggled: root.overlayTs = !root.overlayTs }
                OptCheck { label: qsTr("Burn in camera-name overlay"); isOn: root.overlayName; onToggled: root.overlayName = !root.overlayName }
                OptCheck { label: qsTr("Include audio"); isOn: root.audioOn; active: false; hint: qsTr("(unavailable — video export only)") }
                Text {
                    Layout.fillWidth: true; Layout.topMargin: 2
                    text: root.willTranscode
                        ? "Smaller sizes + overlays are produced on this machine after download (local re-encode); the footage wall-clock and camera name are burned into each frame. Audio has no path yet."
                        : "Original size with no overlays exports the pristine clip as-is (no re-encode). Turn on a smaller size or an overlay to re-encode locally. Audio has no path yet."
                    color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11; wrapMode: Text.WordWrap; lineHeight: 1.3
                }

                // --- timeline mode: wallclock (freeze gaps) vs compact (drop gaps) ---
                SecLabel { text: qsTr("Timeline") }
                RowLayout {
                    Layout.fillWidth: true; spacing: 6
                    Repeater {
                        model: [ { m: "wallclock", l: "Keep gaps", h: "freeze-frame through gaps" },
                                 { m: "compact", l: "Drop gaps", h: "shorter clip, gaps removed" } ]
                        delegate: Rectangle {
                            id: mb
                            required property var modelData
                            Layout.fillWidth: true; implicitHeight: 42
                            readonly property bool on: root.mode === mb.modelData.m
                            color: mb.on ? Theme.accentSoft : (mbMa.containsMouse ? Theme.panel2 : Theme.bg)
                            border.width: 1; border.color: mb.on ? Theme.accent : Theme.line2
                            Column {
                                anchors.centerIn: parent; spacing: 1
                                Text { anchors.horizontalCenter: parent.horizontalCenter; text: mb.modelData.l; color: mb.on ? Theme.accent : Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
                                Text { anchors.horizontalCenter: parent.horizontalCenter; text: mb.modelData.h; color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 9 }
                            }
                            MouseArea { id: mbMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.mode = mb.modelData.m }
                        }
                    }
                }

                // --- purpose (required) ---
                RowLayout {
                    Layout.fillWidth: true; Layout.topMargin: 8; spacing: 4
                    Text { text: qsTr("Purpose"); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11; font.capitalization: Font.AllUppercase; font.letterSpacing: 0.9 }
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
                    Text { visible: custInp.text === ""; anchors.left: parent.left; anchors.leftMargin: 12; anchors.verticalCenter: parent.verticalCenter; text: qsTr("Describe the purpose…"); color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 13 }
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
                            text: qsTr("⚠ Selection spans ") + (root.gapList.length === 1 ? "a recording gap" : root.gapList.length + " recording gaps") + ". " + (root.mode === "compact" ? "These gaps will be dropped from the clip:" : "The export will freeze-frame through:")
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
                Text { anchors.left: parent.left; anchors.leftMargin: 22; anchors.verticalCenter: parent.verticalCenter; text: qsTr("Confirm export"); color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 16; font.weight: Font.DemiBold }
                IconButton { anchors.right: parent.right; anchors.rightMargin: 14; anchors.verticalCenter: parent.verticalCenter; name: "x"; iconColor: Theme.ink2; hoverIcon: Theme.ink; hoverBg: Theme.panel2; hoverBorder: Theme.line2; tip: qsTr("Cancel"); onClicked: root.confirming = false }
            }

            ColumnLayout {
                id: mBody
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: mHead.bottom
                anchors.leftMargin: 22; anchors.rightMargin: 22; anchors.topMargin: 20
                spacing: 12
                Text {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap; textFormat: Text.StyledText
                    text: qsTr("You are about to export footage from <b>") + root.camLabel + "</b> for <b>"
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
                        Text { text: qsTr("• MP4 · ") + (root.effectiveQuality === "high" ? "High quality · " : "Standard · ") + root.resLabel + " · " + root.overlaySummary; color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12 }
                        Text { visible: root.quality === "high" && !root.highAvailable; text: qsTr("• High-quality original unavailable for this range — exporting standard (720p)"); color: Theme.warn; font.family: Theme.fontSans; font.pixelSize: 12 }
                        Text { text: qsTr("• This export will be visible to your supervisor"); color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12 }
                        Text { text: qsTr("• Estimated size: ~ ") + Math.max(1, Math.round(root.estMb)) + " MB"; color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12 }
                        Text { visible: root.willTranscode; text: qsTr("• Re-encoded on this machine after download") + ((root.overlayTs || root.overlayName) ? " · " + root.overlaySummary + " burned in" : ""); color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12 }
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
                        Text { id: cT; anchors.centerIn: parent; text: qsTr("Cancel"); color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
                        MouseArea { id: cMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.confirming = false }
                    }
                    Rectangle {
                        implicitWidth: okT.implicitWidth + 28; implicitHeight: 34
                        color: okMa.containsMouse ? "#f0b04e" : Theme.accent
                        Text { id: okT; anchors.centerIn: parent; text: qsTr("Confirm export"); color: Theme.bg; font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.DemiBold }
                        MouseArea {
                            id: okMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: { root.confirmed(root.startMs, root.endMs, root.mode, root.effectivePurpose, root.effectiveQuality,
                                                        root.effectiveCompHeight, root.overlayTs, root.overlayName); root.close(); }
                        }
                    }
                }
            }
        }
    }

    // Esc closes the modal first, then the drawer. forceActiveFocus() on open so the
    // key reaches THIS handler even though the drawer opens over the focused
    // PlaybackScreen (focus:visible alone doesn't steal active focus reliably).
    Keys.onEscapePressed: (e) => { if (root.confirming) root.confirming = false; else root.close(); e.accepted = true; }
    focus: visible
    onVisibleChanged: if (visible) forceActiveFocus()
    onConfirmingChanged: if (visible) forceActiveFocus()
}
