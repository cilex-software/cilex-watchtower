import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls.Basic as C
import Watchtower

// Window title bar — design "Window shell" (36px): wordmark left, three round
// window buttons right (minimize · maximize · close).
//
// The handoff drew this bar as "generic OS-style, replaced by host". The host
// chrome we actually get under GNOME/Wayland is Qt's own client-side decoration,
// which paints a title strip with NO usable window buttons (operator report
// 2026-07-25) — so the window is frameless (Main.qml) and Watchtower draws the
// designed bar itself. Dragging hands a move grab to the compositor,
// double-click maximizes/restores; the resize edges live in Main.qml.
Item {
    id: root

    property var win: null            // the Window this bar drives
    property string subtitle: ""      // the view currently on screen (ink-2)

    implicitHeight: Theme.titleBarHeight

    readonly property bool maximized: root.win !== null && root.win.visibility === Window.Maximized

    function toggleMaximize() {
        if (!root.win) return;
        root.win.visibility = root.maximized ? Window.Windowed : Window.Maximized;
    }

    // ------------------------------------------------------------- surface
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: Theme.titleBarTop }
            GradientStop { position: 1.0; color: Theme.titleBarBottom }
        }
        Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 1
            color: "#000000"
        }
    }

    // ------------------------------------------ drag to move / dbl-click max
    // Declared BEFORE the content row so the window buttons keep their own
    // clicks. The move grab is handed to the compositor only past a small
    // threshold — starting it on press would swallow the second click of a
    // double-click (the same rule Qt's own decoration follows).
    MouseArea {
        anchors.fill: parent
        property real pressX: 0
        property real pressY: 0
        property bool moving: false
        onPressed: (m) => { pressX = m.x; pressY = m.y; moving = false }
        onPositionChanged: (m) => {
            if (!moving && pressed && root.win
                    && (Math.abs(m.x - pressX) > 3 || Math.abs(m.y - pressY) > 3)) {
                moving = true;
                root.win.startSystemMove();
            }
        }
        onDoubleClicked: root.toggleMaximize()
    }

    // Window button: a 14px disc with an 8px glyph at 0.5 opacity (design), the
    // one deliberately round control in an otherwise orthogonal system.
    component WinBtn: Item {
        id: btn
        property string kind: "min"        // min | max | close
        property string tip: ""
        signal activated()

        implicitWidth: 14
        implicitHeight: 14
        Accessible.role: Accessible.Button
        Accessible.name: btn.tip
        Accessible.onPressAction: btn.activated()

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: btn.kind === "close"
                   ? (bMa.containsMouse ? Qt.lighter(Theme.bad, 1.2) : Theme.bad)
                   : (bMa.containsMouse ? Theme.ink3 : Theme.line2)
        }
        Item {
            anchors.fill: parent
            opacity: bMa.containsMouse ? 1.0 : 0.5
            Behavior on opacity { NumberAnimation { duration: 90 } }

            Rectangle {                      // minimize — a single rule
                visible: btn.kind === "min"
                anchors.centerIn: parent
                width: 6; height: 1.4
                color: Theme.windowBackdrop
            }
            Rectangle {                      // maximize / restore — a square outline
                visible: btn.kind === "max"
                anchors.centerIn: parent
                width: 6.4; height: 6.4
                color: "transparent"
                border.width: 1.2; border.color: Theme.windowBackdrop
            }
            Item {                           // close — a cross
                visible: btn.kind === "close"
                anchors.centerIn: parent
                width: 8; height: 8
                Rectangle { anchors.centerIn: parent; width: 7.2; height: 1.4
                            rotation: 45; antialiasing: true; color: Theme.windowBackdrop }
                Rectangle { anchors.centerIn: parent; width: 7.2; height: 1.4
                            rotation: -45; antialiasing: true; color: Theme.windowBackdrop }
            }
        }
        MouseArea {
            id: bMa
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.activated()
        }
        C.ToolTip.visible: bMa.containsMouse
        C.ToolTip.text: btn.tip
        C.ToolTip.delay: 400
    }

    // ------------------------------------------------------------- content
    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        spacing: 12

        // Design: fixed 70px left spacer — now also home to the Warden supervision
        // indicator: a near-invisible eye that is LIT only while Cilex Warden is
        // actually the parent process RIGHT NOW (MemTel keeps it honest with a
        // periodic getppid() check — a dead Warden re-parents us and the eye goes
        // out). Deliberately quiet: ink-3, no red state, no alarm — the guard is
        // never the detector; unsupervised simply shows nothing here. It exists
        // for the OPERATOR's glance ("is this station watched?"), hence the
        // tooltip carries the Warden version.
        Item {
            Layout.preferredWidth: 70
            Layout.fillHeight: true
            Item {
                id: wardenEye
                visible: typeof MemTel !== "undefined" && MemTel.underWarden
                anchors { left: parent.left; leftMargin: 2; verticalCenter: parent.verticalCenter }
                width: 20; height: 20
                Icon {
                    anchors.centerIn: parent
                    name: "eye"; size: 12
                    color: eyeMa.containsMouse ? Theme.ink2 : Theme.ink3
                    opacity: 0.8
                }
                MouseArea { id: eyeMa; anchors.fill: parent; hoverEnabled: true }
                // The Warden's own plate. Roman inscriptional capitals — the Trajan
                // lineage — carried by whatever of the stack the host actually has;
                // Palatino/Constantia/Cambria all descend from humanist letterforms cut
                // from Roman inscriptions, and all carry CYRILLIC, which is not optional
                // on a station whose guards read Russian. Cinzel/Trajan lead the stack so
                // the plate upgrades for free if either is ever bundled.
                //
                // The flourish is entirely typographic. The words stay literally true —
                // the Warden does watch, does restart, does report — because chrome on a
                // security console must not drift into invented lore, and the facts below
                // the rule stay in JetBrains Mono so an operator can read an address off
                // the screen without squinting at a serif.
                // Resolved at runtime rather than declared as a font stack: the QML `font`
                // value type has no `families` list here, so the first installed face wins
                // and anything absent costs nothing. Falls back to the UI sans, never to an
                // unreadable default.
                readonly property string serifFamily: {
                    var stack = ["Cinzel", "Trajan Pro", "Palatino Linotype",
                                 "Constantia", "Book Antiqua", "Cambria", "Georgia"];
                    var have = Qt.fontFamilies();
                    for (var i = 0; i < stack.length; ++i)
                        if (have.indexOf(stack[i]) !== -1)
                            return stack[i];
                    return Theme.fontSans;
                }
                // Warden is the only process that knows whether a station token is configured,
                // so it hands us WT_WARDEN_TOKEN when it spawns the app (warden.py). An older
                // Warden sends nothing at all, and that reads "unknown" — never "set".
                readonly property string tokenState:
                    (typeof wtWardenToken !== "undefined" && wtWardenToken !== "") ? wtWardenToken : "unknown"

                // Where WARDEN posts, which is not necessarily where the APP is signed in.
                // The SERVER row below is AuthController.baseUrl — the app's. On 2026-09-19
                // the office wall had the app on .4 while Warden still carried the
                // installer's .79 default, so the panel read like confirmation while every
                // beat fell on the floor. Empty when the supervisor predates this.
                readonly property string wardenBackend:
                    (typeof wtWardenBackend !== "undefined") ? wtWardenBackend : ""
                readonly property bool backendMismatch:
                    wardenBackend !== "" && cvUrl !== "" && wardenBackend !== cvUrl

                // What we send as X-Watchtower-Station, and whether CV's hint contract can ever
                // join it (StationNam::hintJoinable — lower-cased, ≤63 chars, [a-z0-9-._] only).
                // An unjoinable name is discarded server-side in SILENCE, so the wall says it.
                // (Claim about cilex-vision, written 2026-09-19 and not re-checked since.)
                readonly property string stationName:
                    (typeof wtStationName !== "undefined") ? wtStationName : ""
                readonly property bool stationJoinable:
                    (typeof wtStationJoinable !== "undefined") ? wtStationJoinable : false

                // Whether THIS session could provision the station if it has no token.
                // Mirrors CV's gate (admin | el_padrino) so the plate does not promise an
                // enrolment the server would refuse.
                readonly property bool canEnrol: {
                    if (typeof AuthController === "undefined") return false;
                    var r = (AuthController.role || "").toLowerCase();
                    return r === "admin" || r === "el_padrino";
                }

                readonly property string cvUrl:
                    (typeof AuthController !== "undefined" && AuthController.baseUrl)
                    ? AuthController.baseUrl : ""
                // The backend hands the role back as an English identifier ("operator",
                // "admin"). Known ones are localised so a Russian guard reads a Russian
                // word; an UNKNOWN role is printed verbatim rather than guessed at or
                // hidden — a role we cannot name is still a fact about the session, and
                // inventing a translation for it would be worse than showing the raw id.
                function localizedRole(r) {
                    switch (r.toLowerCase()) {
                    case "operator":       return qsTr("operator");
                    case "admin":
                    case "administrator":  return qsTr("administrator");
                    case "viewer":         return qsTr("viewer");
                    case "manager":        return qsTr("manager");
                    case "installer":      return qsTr("installer");
                    default:               return r;
                    }
                }
                readonly property string sessionLine: {
                    if (typeof AuthController === "undefined" || !AuthController.authenticated)
                        return qsTr("not signed in");
                    return AuthController.role !== ""
                           ? "%1 (%2)".arg(AuthController.username)
                                      .arg(wardenEye.localizedRole(AuthController.role))
                           : AuthController.username;
                }

                C.ToolTip {
                    id: eyePlate
                    visible: eyeMa.containsMouse
                    delay: 400
                    padding: 0
                    margins: 8
                    background: Rectangle {
                        color: Theme.tileBg
                        border.width: 1
                        border.color: Theme.accentDim
                        radius: 2
                    }
                    contentItem: ColumnLayout {
                        spacing: 0

                        Text {                                   // the sigil line
                            Layout.fillWidth: true
                            Layout.topMargin: 11
                            Layout.leftMargin: 18
                            Layout.rightMargin: 18
                            horizontalAlignment: Text.AlignHCenter
                            text: "CILEX WARDEN"
                            font.family: wardenEye.serifFamily
                            font.pixelSize: 15
                            font.letterSpacing: 4.5
                            font.bold: true
                            color: Theme.accent
                        }
                        Rectangle {                              // hairline under the sigil
                            Layout.fillWidth: true
                            Layout.topMargin: 8
                            Layout.leftMargin: 18
                            Layout.rightMargin: 18
                            height: 1
                            color: Theme.accentDim
                        }
                        Text {                                   // the vow — true, not lore
                            Layout.fillWidth: true
                            Layout.topMargin: 7
                            Layout.leftMargin: 18
                            Layout.rightMargin: 18
                            horizontalAlignment: Text.AlignHCenter
                            text: qsTr("Watches · Restarts · Reports")
                            font.family: wardenEye.serifFamily
                            font.pixelSize: 11
                            font.italic: true
                            font.letterSpacing: 1.2
                            color: Theme.ink3
                        }

                        GridLayout {                             // the facts, in mono
                            Layout.topMargin: 12
                            Layout.bottomMargin: 13
                            Layout.leftMargin: 18
                            Layout.rightMargin: 18
                            columns: 2
                            rowSpacing: 4
                            columnSpacing: 14

                            // STATION — the name this wall puts in X-Watchtower-Station, which is
                            // also the JOIN KEY CV stores the station row under. A human types
                            // that string when minting the token and nothing on the server checks
                            // it against what the wall sends, so a friendly label ("Office PC")
                            // produces a station that beats, authenticates, and is attributed to
                            // nobody (CV, letter reply4 §3-4; the `unknown` row is that mistake
                            // made permanent). Always shown: it is the one fact that answers
                            // "which wall am I standing at", and it has to be readable off the
                            // screen BEFORE the token exists.
                            Text {
                                text: qsTr("STATION")
                                font.family: wardenEye.serifFamily
                                font.pixelSize: 10
                                font.letterSpacing: 1.6
                                color: Theme.ink3
                            }
                            Text {
                                text: wardenEye.stationName === "" ? qsTr("unknown")
                                      : wardenEye.stationJoinable ? wardenEye.stationName
                                      : wardenEye.stationName + "\n"
                                        + qsTr("this name cannot be reported — the fleet will not name this station")
                                font.family: Theme.fontMono
                                font.pixelSize: 12
                                color: wardenEye.stationName === "" ? Theme.ink3
                                       : wardenEye.stationJoinable ? Theme.ink : Theme.warn
                            }
                            Text {
                                text: qsTr("SERVER")
                                font.family: wardenEye.serifFamily
                                font.pixelSize: 10
                                font.letterSpacing: 1.6
                                color: Theme.ink3
                            }
                            Text {
                                text: wardenEye.cvUrl !== "" ? wardenEye.cvUrl : qsTr("not configured")
                                font.family: Theme.fontMono
                                font.pixelSize: 12
                                color: wardenEye.cvUrl !== "" ? Theme.ink : Theme.ink3
                            }
                            Text {
                                text: qsTr("SESSION")
                                font.family: wardenEye.serifFamily
                                font.pixelSize: 10
                                font.letterSpacing: 1.6
                                color: Theme.ink3
                            }
                            Text {
                                text: wardenEye.sessionLine
                                font.family: Theme.fontMono
                                font.pixelSize: 12
                                color: (typeof AuthController !== "undefined" && AuthController.authenticated)
                                       ? Theme.ink2 : Theme.ink3
                            }
                            Text {
                                text: qsTr("WARDEN")
                                font.family: wardenEye.serifFamily
                                font.pixelSize: 10
                                font.letterSpacing: 1.6
                                color: Theme.ink3
                            }
                            Text {
                                text: (typeof wtWardenVersion !== "undefined" && wtWardenVersion !== "")
                                      ? wtWardenVersion : qsTr("unknown")
                                font.family: Theme.fontMono
                                font.pixelSize: 12
                                color: Theme.ink2
                            }
                            // TOKEN — shown only when it is NOT set, because a station with no
                            // token is invisible to the fleet: Warden's heartbeat and crash-upload
                            // loops both do nothing, and the server has no row for this machine.
                            // Two machines were lost to that silence (the booth 2026-07-26..08-09,
                            // the office wall for days until the cilex-pro-mobile letter of
                            // 2026-09-19 found it with a database query). The person standing in
                            // front of the wall is the one who can fix it, so it is stated here.
                            // Unknown is NOT healthy: an older Warden sends no WT_WARDEN_TOKEN, and
                            // that reads "unknown", never blank.
                            // Only when Warden posts somewhere OTHER than where the app is
                            // signed in, or when an older Warden cannot say. Silent when they
                            // agree, because then SERVER above is the whole truth.
                            Text {
                                visible: wardenEye.backendMismatch || wardenEye.wardenBackend === ""
                                text: qsTr("WARDEN SENDS TO")
                                font.family: wardenEye.serifFamily
                                font.pixelSize: 10
                                font.letterSpacing: 1.6
                                color: Theme.ink3
                            }
                            Text {
                                visible: wardenEye.backendMismatch || wardenEye.wardenBackend === ""
                                text: wardenEye.backendMismatch ? wardenEye.wardenBackend : qsTr("unknown")
                                font.family: Theme.fontMono
                                font.pixelSize: 12
                                color: wardenEye.backendMismatch ? Theme.warn : Theme.ink3
                            }
                            Text {
                                visible: wardenEye.tokenState !== "set"
                                text: qsTr("TOKEN")
                                font.family: wardenEye.serifFamily
                                font.pixelSize: 10
                                font.letterSpacing: 1.6
                                color: Theme.ink3
                            }
                            Text {
                                visible: wardenEye.tokenState !== "set"
                                // A station with no token enrols ITSELF the first time an
                                // ADMIN signs in on it (StationEnrolment.h — the app mints
                                // via CV's POST /client/stations on that ordinary session and
                                // writes warden.conf). A viewer or operator session cannot:
                                // CV refuses it at client_reports.py:1411, by design, because
                                // minting a credential is a provisioning act.
                                //
                                // So on a wall signed in as anything else the errand is real
                                // but invisible — which is exactly how the office wall stayed
                                // off the fleet: it signs in as `office`, a VIEWER, so nothing
                                // would ever have enrolled it and nothing said so. The person
                                // standing in front of the wall is the one who can fix it in a
                                // minute, so the plate names the act instead of the symptom.
                                text: wardenEye.tokenState !== "missing" ? qsTr("unknown")
                                      : wardenEye.canEnrol
                                        ? qsTr("none — this station is invisible to the fleet")
                                        : qsTr("none — sign in once as an administrator and this station enrols itself")
                                font.family: Theme.fontMono
                                font.pixelSize: 12
                                color: wardenEye.tokenState === "missing" ? Theme.warn : Theme.ink3
                            }
                        }
                    }
                }
            }
        }

        Text {
            Layout.alignment: Qt.AlignVCenter
            text: qsTr("WATCHTOWER")
            color: Theme.ink
            font.family: Theme.fontMono
            font.pixelSize: 11
            font.weight: Font.DemiBold
            font.letterSpacing: 0.66              // 0.06em
        }
        Text {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            text: root.subtitle !== "" ? ("· " + root.subtitle) : ""
            color: Theme.ink2
            font.family: Theme.fontSans
            font.pixelSize: 12
            elide: Text.ElideRight
        }

        Row {
            Layout.alignment: Qt.AlignVCenter
            spacing: 8
            WinBtn {
                kind: "min"; tip: qsTr("Minimize")
                onActivated: if (root.win) root.win.visibility = Window.Minimized
            }
            WinBtn {
                kind: "max"; tip: root.maximized ? qsTr("Restore") : qsTr("Maximize")
                onActivated: root.toggleMaximize()
            }
            WinBtn {
                kind: "close"; tip: qsTr("Close")
                onActivated: if (root.win) root.win.close()
            }
        }
    }
}
