import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as QC
import Watchtower

// One analyser's FINDINGS, to watch (operator request 2026-09-29): opened by clicking an
// analyser in the Labs Statistics view. The list (left) is every finding of that kind in the
// period, newest first, fetched a page at a time as it scrolls -- "All" is a period, never a
// request for everything. The player (right) plays the selected finding from its camera's
// recording, with the Events screen's own inline player (EvHeroPlayer, on a PlaybackClient of
// this view's own), and the finding's details under it (LabsCard: the server's sentence and
// every field and metric it filed). One-button filters sit above the list: the analyser's
// own, from the server (e.g. a colour, a direction, a camera fault), one at a time.
//
// Data: LabsFindingsModel (GET /labs/findings; LabsFindingsData.h). Until the server has the
// endpoint the view says so, and shows nothing it would have had to guess.
Item {
    id: fv

    property var screen: null            // LabsScreen: title(), num(), known()
    property var cameraModel: null
    property string analyzer: ""
    property string period: "24h"
    property string facet: ""
    signal back()

    readonly property bool shown: visible && analyzer !== ""
    property int current: -1
    onAnalyzerChanged: { facet = ""; current = -1 }
    onPeriodChanged: current = -1
    onFacetChanged: current = -1

    function known(v) { return screen ? screen.known(v) : (v !== undefined && v !== null) }
    // The chosen filter as the server lists it ({id, label, count}), or null. Filtered, the
    // header counts the FILTER's rows: the server's `total` stays the whole period's
    // (measured 2026-09-29 on the pilot: colour_histogram 24 h, filter "black" -> total 338,
    // the black button's count 216, and every row black).
    function facetInfo() {
        for (var i = 0; i < fm.facets.length; i++)
            if (fm.facets[i].id === fm.facet) return fm.facets[i]
        return null
    }
    function num(v, d) { return screen ? screen.num(v, d) : String(v) }
    readonly property string periodText: period === "24h" ? qsTr("in the last 24 hours")
                                       : period === "7d" ? qsTr("in the last 7 days")
                                       : qsTr("in all footage")

    LabsFindingsModel {
        id: fm
        analyzer: fv.analyzer
        period: fv.period
        facet: fv.facet
        lang: (typeof Language !== "undefined" && Language.language === "ru") ? "ru" : "en"
        active: fv.shown
        // The first finding plays as soon as a list arrives; an emptied list plays nothing.
        onStateChanged: {
            if (fm.count === 0) fv.current = -1
            else if (fv.current < 0 || fv.current >= fm.count) fv.current = 0
            fv.fitRows(false)
        }
    }
    PlaybackClient { id: findingsClient }

    // camera id -> {id, name, ip, preRollMs, postRollMs}, built as the Events area builds it
    // (EventsArea._buildLookup): the player rolls to each camera's own recording profile.
    property var camLookup: ({})
    function _buildLookup() {
        var lk = ({})
        var n = cameraModel ? cameraModel.total : 0
        for (var i = 0; i < n; i++) {
            var c = cameraModel.get(i)
            if (!c || !c.camId) continue
            lk[c.camId] = { id: c.camId, name: c.name ? c.name : c.camId, ip: c.ip ? c.ip : "",
                            preRollMs: c.recPreRollMs > 0 ? c.recPreRollMs : -1,
                            postRollMs: c.recPostRollMs > 0 ? c.recPostRollMs : -1 }
        }
        camLookup = lk
    }
    onShownChanged: if (shown) _buildLookup()
    function camName(item) {
        var c = item ? camLookup[item.camera_id] : null
        return c ? c.name : (item && item.camera_name ? item.camera_name : (item ? item.camera_id : ""))
    }

    readonly property var currentItem: (current >= 0 && current < fm.count) ? fm.get(current) : null
    readonly property var currentEv: currentItem ? fm.asEvent(current, camLookup[currentItem.camera_id] || ({})) : null

    // The row's second line: what THIS finding found, from its own metrics -- the server's
    // sentence often only repeats the camera and the time already on the row. Each figure is
    // the server's value as filed (nothing inferred); one the row does not carry is left out,
    // and with nothing to say the server's sentence is shown instead.
    function pct(v) { if (!known(v)) return ""; var x = v * 100; return num(x, x < 10 ? 1 : 0) + " %" }
    // A metric VALUE by the server's own name for it, where the analyser's filters are one
    // per value (a colour, a shape class, a direction): "Чёрный", not "black". The names are
    // served in the UI's language (cilex-vision 1.0.98), never kept here; a value the server
    // has no button for is shown as filed.
    function valueLabel(v) {
        for (var i = 0; i < fm.facets.length; i++)
            if (fm.facets[i].id === v && fm.facets[i].label) return fm.facets[i].label
        return String(v).replace(/_/g, " ")
    }
    function headline(it) {
        if (!it) return ""
        var m = it.metrics || ({}), bits = []
        switch (analyzer) {
        case "colour_histogram":
            if (m.colour) bits.push(valueLabel(m.colour))
            if (known(m.colour_share)) bits.push(pct(m.colour_share))
            if (m.runner_up) bits.push(qsTr("then %1").arg(valueLabel(m.runner_up)))
            break
        case "optical_flow":     if (m.dir_label) bits.push(valueLabel(m.dir_label)); break
        case "foreground_mask":
            if (known(m.largest_blob_frac)) bits.push(qsTr("largest %1 of the picture").arg(pct(m.largest_blob_frac)))
            if (known(it.object_count)) bits.push(qsTr("%n object(s)", "", it.object_count))
            break
        case "blob_geometry":    if (it.shape_class) bits.push(valueLabel(it.shape_class)); break
        case "track_linking":    if (known(m.dwell_s)) bits.push(qsTr("stayed %1 s").arg(Math.round(m.dwell_s))); break
        case "frame_difference":
            if (known(m.peak)) bits.push(qsTr("peak %1").arg(num(m.peak, 1)))
            if (known(m.sustained_s)) bits.push(qsTr("%1 s sustained").arg(Math.round(m.sustained_s)))
            break
        case "audio_energy":     if (known(m.loud_db)) bits.push(qsTr("%1 dB").arg(Math.round(m.loud_db))); break
        case "perceptual_hash":  if (known(m.identical_count)) bits.push(qsTr("%n identical frame(s)", "", m.identical_count)); break
        case "camera_health":
            ["obscured", "defocused", "moved", "frozen", "lights_changed"].forEach(function (k) {
                if (m[k] === true) bits.push(k.replace(/_/g, " ")) })
            break
        case "illumination":     if (it.scene_light) bits.push(it.scene_light); break
        }
        return bits.join("  ·  ")
    }

    // ---- the list column's width: FITTED to its rows by default, then wherever the operator
    // drags the divider (operator request 2026-09-29). Measured, not guessed: each loaded row's
    // time, camera and headline, through the fonts the rows use (the Events area's own
    // measured-fit method, EventsArea.qml "Measured fit"). Only rows new to the list are
    // measured as pages arrive, and while a list reloads the column keeps its width, so a
    // changed period or filter moves it once, when the rows land, not twice. A drag lasts for
    // this session (switching analysers or screens keeps it); a double-click on the divider
    // returns to the fit. Never narrower than listMinW; a drag stops where the player keeps
    // playerMinW, and the fit alone never takes more than half the view.
    FontMetrics { id: fmTime; font.family: Theme.fontMono; font.pixelSize: 11 }
    FontMetrics { id: fmName; font.family: Theme.fontSans; font.pixelSize: 13; font.weight: Font.DemiBold }
    FontMetrics { id: fmLine; font.family: Theme.fontSans; font.pixelSize: 12 }
    readonly property int listMinW: 200               // a row's time and a short camera name
    readonly property int playerMinW: 460
    readonly property int rowPad: 18 + 14 + 12          // row margins, and the scrollbar's room
    property real userListW: -1                         // dragged; -1 = fit to the rows
    property real fitListW: 420                         // before any row was measured
    readonly property real listW: Math.max(listMinW, userListW > 0 ? Math.min(width - playerMinW, userListW)
                                                                   : Math.min(width / 2, fitListW))
    function timeText(it) { return Qt.formatDateTime(new Date(it.startMs), "dd.MM  HH:mm:ss") }
    property int _fitRows: 0                            // rows of THIS list measured so far
    property real _fitMax: 0
    function fitRows(again) {
        if (again || fm.count < _fitRows) { _fitRows = 0; _fitMax = 0 }   // another list, or new names
        if (fm.count === _fitRows) return                                  // nothing new: keep the width
        for (var i = _fitRows; i < fm.count; i++) {
            var it = fm.get(i)
            _fitMax = Math.max(_fitMax, fmTime.advanceWidth(timeText(it)) + 10 + fmName.advanceWidth(camName(it)),
                                        fmLine.advanceWidth(headline(it) || (it.text ? it.text : "")))
        }
        _fitRows = fm.count
        fitListW = Math.ceil(_fitMax) + rowPad
    }
    onCamLookupChanged: fitRows(true)

    function select(i) {
        if (i < 0 || i >= fm.count) return
        current = i
        list.positionViewAtIndex(i, ListView.Contain)
        if (i >= fm.count - 6) fm.loadMore()
    }

    component Label10: Text {
        color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
        font.weight: Font.DemiBold; font.letterSpacing: 1.2; font.capitalization: Font.AllUppercase
    }
    component Link: Text {
        id: lk
        signal clicked()
        color: lkMa.containsMouse ? Theme.accent : Theme.ink2
        font.family: Theme.fontMono; font.pixelSize: 11; font.weight: Font.DemiBold
        MouseArea { id: lkMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: lk.clicked() }
    }
    component Chip: Rectangle {
        id: chip
        property string label: ""
        property var count: undefined
        property bool on: false
        signal picked()
        implicitWidth: chipRow.implicitWidth + 24
        implicitHeight: 28
        color: on ? Theme.accent : (chipMa.containsMouse ? Theme.panel : Theme.bg)
        border.width: 1
        border.color: on ? Theme.accent : Theme.line2
        Row {
            id: chipRow
            anchors.centerIn: parent
            spacing: 6
            Text { text: chip.label; color: chip.on ? Theme.bg : Theme.ink
                   font.family: Theme.fontSans; font.pixelSize: 12; font.weight: Font.Medium }
            Text { visible: fv.known(chip.count); text: fv.num(chip.count)
                   color: chip.on ? Theme.bg : Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11 }
        }
        MouseArea { id: chipMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: chip.picked() }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ===== which analyser, which period, how many =====
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 54
            color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 18
                spacing: 14
                Link { text: qsTr("‹ Statistics"); onClicked: fv.back() }
                Rectangle { width: 1; Layout.preferredHeight: 22; color: Theme.line2 }
                Rectangle { width: 12; height: 12; color: LabsNames.color(fv.analyzer) }
                Text {
                    text: fv.screen ? fv.screen.title(fv.analyzer) : fv.analyzer
                    color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 16; font.weight: Font.DemiBold
                }
                Text {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    text: {
                        if (fm.state !== "ok") return ""
                        var f = fv.facetInfo()
                        var total = fm.facet === "" ? fm.total : (f ? f.count : undefined)
                        var n = fv.known(total) ? qsTr("%n finding(s)", "", total) : qsTr("findings")
                        return n + " " + fv.periodText
                               + (fm.facet !== "" ? "  ·  " + (f && f.label ? f.label : qsTr("filtered")) : "")
                    }
                    color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11
                }
                LabsSeg {
                    choices: [ { k: qsTr("24 hours"), v: "24h" }, { k: qsTr("7 days"), v: "7d" }, { k: qsTr("All"), v: "all" } ]
                    value: fv.period
                    onPicked: (v) => fv.period = v
                }
                Link { text: fm.loading ? qsTr("Refreshing…") : qsTr("Refresh"); onClicked: if (!fm.loading) fm.reload() }
            }
        }

        // ===== the analyser's own one-button filters, from the server =====
        Rectangle {
            visible: fm.state === "ok" && fm.facets.length > 0
            Layout.fillWidth: true
            Layout.preferredHeight: facetFlow.implicitHeight + 20
            color: Theme.bg
            Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
            Flow {
                id: facetFlow
                anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: 18; anchors.rightMargin: 18
                spacing: 8
                Chip { label: qsTr("All", "findings filter: no filter"); on: fv.facet === ""; onPicked: fv.facet = "" }
                Repeater {
                    model: fm.facets
                    delegate: Chip {
                        required property var modelData
                        label: modelData.label
                        count: modelData.count
                        on: fv.facet === modelData.id
                        // One at a time; the chosen one again clears the filter.
                        onPicked: fv.facet = (fv.facet === modelData.id) ? "" : modelData.id
                    }
                }
            }
        }

        // ===== the list, and the finding playing =====
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            Item {
                Layout.preferredWidth: fv.listW
                Layout.fillHeight: true

                ListView {
                    id: list
                    anchors.fill: parent
                    clip: true
                    model: fm
                    focus: fv.shown
                    boundsBehavior: Flickable.StopAtBounds
                    cacheBuffer: 400
                    QC.ScrollBar.vertical: QC.ScrollBar { policy: QC.ScrollBar.AsNeeded }
                    // The next page, as the end comes into view -- never the whole list at once.
                    onAtYEndChanged: if (atYEnd && count > 0) fm.loadMore()
                    Keys.onDownPressed: fv.select(fv.current + 1)
                    Keys.onUpPressed: fv.select(Math.max(0, fv.current - 1))

                    delegate: Rectangle {
                        id: row
                        required property var item
                        required property int index
                        readonly property bool sel: index === fv.current
                        width: ListView.view.width
                        height: 60
                        color: sel ? Theme.panel2 : (rowMa.containsMouse ? Theme.panel : "transparent")
                        Rectangle { visible: row.sel; anchors.left: parent.left; anchors.top: parent.top; anchors.bottom: parent.bottom
                                    width: 3; color: LabsNames.color(fv.analyzer) }
                        Rectangle { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom; height: 1; color: Theme.line }
                        Column {
                            anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: 18; anchors.rightMargin: 14
                            spacing: 4
                            Row {
                                spacing: 10
                                Text { id: timeT; text: fv.timeText(row.item)
                                       color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 11 }
                                Text { text: fv.camName(row.item); color: Theme.ink
                                       width: Math.max(0, row.width - 18 - 14 - timeT.width - 10); elide: Text.ElideRight
                                       font.family: Theme.fontSans; font.pixelSize: 13; font.weight: Font.DemiBold }
                            }
                            Text {
                                width: parent.width; elide: Text.ElideRight
                                text: fv.headline(row.item) || (row.item.text ? row.item.text : "")
                                visible: text !== ""
                                color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12
                            }
                        }
                        MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: { fv.select(row.index); list.forceActiveFocus() } }
                        Component.onCompleted: if (index >= fm.count - 6) fm.loadMore()
                    }

                    footer: Item {
                        id: foot
                        width: ListView.view ? ListView.view.width : 0
                        height: fm.count > 0 ? 48 : 0
                        visible: fm.count > 0
                        Text {
                            anchors.centerIn: parent
                            visible: fm.errorText === ""
                            text: fm.loadingMore ? qsTr("Loading more…")
                                 : fm.hasMore ? "" : qsTr("That is all: %n finding(s)", "", fm.count)
                            color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 11
                        }
                        Row {
                            anchors.centerIn: parent
                            visible: fm.errorText !== ""
                            spacing: 10
                            Text { text: qsTr("Could not load more: %1").arg(fm.errorText); color: Theme.warn
                                   width: Math.min(implicitWidth, foot.width - 24 - 10 - tryMore.width); elide: Text.ElideRight
                                   font.family: Theme.fontMono; font.pixelSize: 11 }
                            Link { id: tryMore; text: qsTr("Try again"); onClicked: fm.loadMore() }
                        }
                    }
                }

                // ----- what the list has instead of rows -----
                Column {
                    anchors.centerIn: parent
                    width: Math.min(parent.width - 48, 420)
                    spacing: 10
                    visible: fm.count === 0
                    Text {
                        width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                        text: fm.state === "absent" ? qsTr("The server does not list findings yet")
                            : fm.state === "admin_only" ? qsTr("Only administrators can see Labs findings")
                            : fm.state === "error" ? qsTr("The server could not list them")
                            : (fm.loading || fm.state === "") ? qsTr("Asking the server…")
                            : qsTr("No findings of this kind %1").arg(fv.periodText)
                        color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 14; font.weight: Font.DemiBold
                    }
                    Text {
                        width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                        visible: text !== ""
                        text: fm.state === "absent"
                              ? qsTr("Listing every finding of one analyser across all cameras is a query only cilex-vision can make. It was asked for on 29 September, and this list fills in as soon as the server has it.")
                            : fm.state === "error" ? fm.errorText
                            : (fm.state === "ok" && fv.period !== "all") ? qsTr("A longer period may have some.")
                            : ""
                        color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12
                    }
                    Link {
                        anchors.horizontalCenter: parent.horizontalCenter
                        visible: fm.state === "error"
                        text: qsTr("Try again")
                        onClicked: fm.reload()
                    }
                }
            }

            // ----- the divider: drag to resize the list; double-click to fit it to its rows -----
            Item {
                Layout.preferredWidth: 7
                Layout.fillHeight: true
                Rectangle { anchors.horizontalCenter: parent.horizontalCenter; width: 1; height: parent.height
                            color: (splitHover.hovered || splitMa.pressed) ? Theme.accent : Theme.line }
                // Hover from a HoverHandler, which re-checks the pointer on every move: a MouseArea's
                // containsMouse stays false after a drag that outran the divider, until the pointer
                // leaves and comes back (seen on the vnc platform, 2026-09-29).
                HoverHandler { id: splitHover; cursorShape: Qt.SplitHCursor }
                MouseArea {
                    id: splitMa
                    anchors.fill: parent
                    cursorShape: Qt.SplitHCursor
                    property real startX: 0
                    property real startW: 0
                    onPressed: (m) => { startX = mapToItem(fv, m.x, 0).x; startW = fv.listW }
                    onPositionChanged: (m) => {
                        if (pressed)
                            fv.userListW = Math.max(fv.listMinW, Math.min(fv.width - fv.playerMinW,
                                                                          startW + mapToItem(fv, m.x, 0).x - startX))
                    }
                    onDoubleClicked: fv.userListW = -1
                }
                // Beside the pointer: the attached ToolTip would sit above the divider's top, a full
                // list's height away from where the operator is pointing.
                QC.ToolTip {
                    visible: splitHover.hovered && !splitMa.pressed
                    delay: 800
                    text: qsTr("Drag to resize · double-click to fit the list to its rows")
                    x: parent.width + 6
                    y: Math.round(splitHover.point.position.y) + 14
                }
            }

            // ----- the finding playing, and what was filed about it -----
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 14
                    spacing: 12
                    visible: fv.currentEv !== null
                    EvHeroPlayer {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.round(parent.height * 0.64)
                        ev: fv.currentEv
                        playbackClient: findingsClient
                        surfaced: fv.shown
                        fillStage: true
                    }
                    Flickable {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        contentHeight: card.height
                        boundsBehavior: Flickable.StopAtBounds
                        LabsCard { id: card; width: parent.width; obs: fv.currentItem ? fv.currentItem : ({}) }
                    }
                }
                Text {
                    anchors.centerIn: parent
                    visible: fv.currentEv === null && fm.count > 0
                    text: qsTr("Pick a finding to play it")
                    color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 13
                }
            }
        }
    }
}
