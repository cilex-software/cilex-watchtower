import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C
import Watchtower

// Login gate. Two tabs: Password (username+password -> /auth/login) and Token
// (paste a JWT -> validated via /auth/me). Both yield a session held by
// AuthController; the app shell stays hidden until authenticated. Orthogonal,
// dark, Theme-driven — no new colors, no decoration beyond the spec.
Item {
    id: root
    property string tab: "password"   // "password" | "token"

    // Start focus in the first credential field (classic login UX).
    Component.onCompleted: userField.takeFocus()

    function submit() {
        if (AuthController.busy)
            return;
        if (root.tab === "password")
            AuthController.loginWithPassword(serverField.text.trim(),
                                             userField.text.trim(),
                                             passField.text);
        else
            AuthController.loginWithToken(serverField.text.trim(), tokenEdit.text);
    }

    // Single-line labelled input (server / username / password).
    component Field: ColumnLayout {
        id: fieldRoot
        property alias label: lbl.text
        property alias text: input.text
        property alias echoMode: input.echoMode
        property alias placeholder: ph.text
        // Optional trailing chevron (saved-servers dropdown). Hidden unless the
        // page enables it — an empty history gets no dead control.
        property bool showHistory: false
        signal historyRequested()
        function takeFocus() { input.forceActiveFocus() }
        Layout.fillWidth: true
        spacing: 6
        Text {
            id: lbl
            color: Theme.ink2; font.family: Theme.fontMono
            font.pixelSize: Theme.fsLabel; font.capitalization: Font.AllUppercase
            font.letterSpacing: 1.0
        }
        Rectangle {
            Layout.fillWidth: true
            height: 38
            color: Theme.bg
            border.width: 1
            border.color: input.activeFocus ? Theme.accent : Theme.line2
            TextInput {
                id: input
                anchors { fill: parent; leftMargin: 12; rightMargin: fieldRoot.showHistory ? 38 : 12 }
                verticalAlignment: TextInput.AlignVCenter
                color: Theme.ink
                font.family: Theme.fontSans; font.pixelSize: Theme.fsBody
                selectionColor: Theme.accent
                selectByMouse: true
                activeFocusOnTab: true
                clip: true
                enabled: !AuthController.busy
                onAccepted: root.submit()
                onTextChanged: if (AuthController.errorString !== "") AuthController.clearError()
                Text {
                    id: ph
                    anchors.verticalCenter: parent.verticalCenter
                    color: Theme.ink3; font: input.font
                    visible: input.text === ""
                }
            }
            IconButton {
                anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 4 }
                visible: fieldRoot.showHistory
                name: "chev"
                iconSize: 14
                tip: qsTr("Saved servers")
                onClicked: fieldRoot.historyRequested()
            }
        }
    }

    Rectangle { anchors.fill: parent; color: Theme.bg }

    // Build identifier (short git SHA from CMake), bottom-right corner. Lets a
    // relaunch confirm at a glance that the expected binary is running.
    Text {
        anchors.right: parent.right; anchors.bottom: parent.bottom
        anchors.rightMargin: Theme.s12; anchors.bottomMargin: Theme.s8
        text: qsTr("build ") + ((typeof wtBuild !== "undefined") ? wtBuild : "dev")
        color: Theme.ink3
        font.family: Theme.fontMono
        font.pixelSize: Theme.fsLabel
        font.letterSpacing: 1.0
    }

    Rectangle {
        anchors.centerIn: parent
        width: 420
        height: col.implicitHeight + 2 * Theme.s32
        color: Theme.panel
        border.width: 1
        border.color: Theme.line2

        ColumnLayout {
            id: col
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: Theme.s32 }
            spacing: Theme.s16

            // brand
            ColumnLayout {
                spacing: 2
                Text {
                    text: qsTr("CILEX VISION"); color: Theme.ink3
                    font.family: Theme.fontMono; font.pixelSize: Theme.fsLabel
                    font.letterSpacing: 1.6; font.capitalization: Font.AllUppercase
                }
                Text {
                    text: "Watchtower"; color: Theme.ink
                    font.family: Theme.fontSans; font.pixelSize: Theme.fsH1
                    font.weight: Font.DemiBold; font.letterSpacing: -0.24
                }
                Text {
                    text: qsTr("Sign in to the surveillance backend"); color: Theme.ink2
                    font.family: Theme.fontSans; font.pixelSize: Theme.fsSmall
                }
            }

            // tab switch
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: Theme.s8
                spacing: 0
                Repeater {
                    model: [ { id: "password", lbl: qsTr("Password") }, { id: "token", lbl: qsTr("Token") } ]
                    delegate: Item {
                        id: tabBtn
                        required property var modelData
                        Layout.fillWidth: true
                        implicitHeight: 36
                        activeFocusOnTab: true
                        function activate() { root.tab = tabBtn.modelData.id; AuthController.clearError() }
                        Keys.onReturnPressed: tabBtn.activate()
                        Keys.onEnterPressed: tabBtn.activate()
                        Keys.onSpacePressed: tabBtn.activate()
                        Text {
                            anchors.centerIn: parent
                            text: tabBtn.modelData.lbl
                            color: root.tab === tabBtn.modelData.id ? Theme.ink : Theme.ink3
                            font.family: Theme.fontSans; font.pixelSize: Theme.fsSmall
                            font.weight: root.tab === tabBtn.modelData.id ? Font.DemiBold : Font.Normal
                        }
                        // keyboard focus ring
                        Rectangle {
                            anchors.fill: parent
                            color: "transparent"
                            border.width: 1; border.color: Theme.accent
                            visible: tabBtn.activeFocus
                        }
                        Rectangle {
                            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                            height: 2
                            color: root.tab === tabBtn.modelData.id ? Theme.accent : Theme.line
                        }
                        MouseArea {
                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: tabBtn.activate()
                        }
                    }
                }
            }

            Field {
                id: serverField
                label: qsTr("Server")
                placeholder: "http://host:8000"
                Component.onCompleted: text = AuthController.baseUrl
                showHistory: AuthController.serverHistory.length > 0
                onHistoryRequested: serverMenu.open()

                // Saved-servers dropdown: every server that has accepted a login,
                // most recent first, with an operator-assigned nickname (pencil to
                // edit, ✕ to forget). Picking a row fills the field — nothing else.
                C.Popup {
                    id: serverMenu
                    y: serverField.height + 4
                    width: serverField.width
                    padding: 0
                    modal: false
                    background: Rectangle { color: Theme.panel; border.color: Theme.line2; border.width: 1 }
                    // The last row can be forgotten while open — an empty menu is
                    // a dead control, so it closes itself.
                    property int n: AuthController.serverHistory.length
                    onNChanged: if (n === 0) close()

                    contentItem: Column {
                        Repeater {
                            model: AuthController.serverHistory
                            delegate: Item {
                                id: row
                                required property var modelData
                                property bool editing: false
                                width: serverMenu.width
                                height: 44

                                function commitNick() {
                                    AuthController.setServerNickname(row.modelData.url, nickEdit.text.trim());
                                    row.editing = false;
                                }

                                Rectangle {
                                    anchors.fill: parent
                                    color: rowMa.containsMouse && !row.editing ? Theme.bg : "transparent"
                                }
                                MouseArea {
                                    id: rowMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    visible: !row.editing
                                    onClicked: { serverField.text = row.modelData.url; serverMenu.close() }
                                }

                                // normal state: nickname (or the url itself), url subline when nicknamed
                                Column {
                                    anchors { left: parent.left; right: btns.left; verticalCenter: parent.verticalCenter; leftMargin: 12 }
                                    spacing: 1
                                    visible: !row.editing
                                    Text {
                                        width: parent.width; elide: Text.ElideRight
                                        text: row.modelData.nick !== "" ? row.modelData.nick : row.modelData.url
                                        color: Theme.ink
                                        font.family: row.modelData.nick !== "" ? Theme.fontSans : Theme.fontMono
                                        font.pixelSize: Theme.fsSmall
                                    }
                                    Text {
                                        width: parent.width; elide: Text.ElideMiddle
                                        visible: row.modelData.nick !== ""
                                        text: row.modelData.url
                                        color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: Theme.fsLabel
                                    }
                                }

                                // edit state: nickname input in place of the labels
                                Rectangle {
                                    visible: row.editing
                                    anchors { left: parent.left; right: btns.left; verticalCenter: parent.verticalCenter; leftMargin: 8 }
                                    height: 28
                                    color: Theme.bg
                                    border.width: 1; border.color: Theme.accent
                                    TextInput {
                                        id: nickEdit
                                        anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
                                        verticalAlignment: TextInput.AlignVCenter
                                        color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: Theme.fsSmall
                                        selectionColor: Theme.accent; selectByMouse: true; clip: true
                                        onAccepted: row.commitNick()
                                        Keys.onEscapePressed: row.editing = false
                                        Text {
                                            anchors.verticalCenter: parent.verticalCenter
                                            visible: nickEdit.text === ""
                                            text: qsTr("Nickname")
                                            color: Theme.ink3; font: nickEdit.font
                                        }
                                    }
                                }

                                Row {
                                    id: btns
                                    anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 4 }
                                    IconButton {
                                        name: row.editing ? "check" : "pencil"
                                        iconSize: 13
                                        tip: row.editing ? qsTr("Save nickname") : qsTr("Set a nickname")
                                        onClicked: {
                                            if (row.editing) {
                                                row.commitNick();
                                            } else {
                                                nickEdit.text = row.modelData.nick;
                                                row.editing = true;
                                                nickEdit.forceActiveFocus();
                                            }
                                        }
                                    }
                                    IconButton {
                                        name: "x"
                                        iconSize: 12
                                        tip: qsTr("Forget this server")
                                        visible: !row.editing
                                        onClicked: AuthController.forgetServer(row.modelData.url)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // password tab
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.s16
                visible: root.tab === "password"
                Field { id: userField; label: qsTr("Username"); placeholder: qsTr("operator") }
                Field { id: passField; label: qsTr("Password"); echoMode: TextInput.Password
                    // The login screen is hidden, not destroyed, after sign-in, so the
                    // plaintext password would otherwise sit in the QML heap for the
                    // whole session (audit 2026-09-03, Info). Clear it on acceptance;
                    // the C++ side already clears its own copy.
                    Connections {
                        target: AuthController
                        function onAuthenticatedChanged() { if (AuthController.authenticated) passField.text = "" }
                    }
                }
            }

            // token tab
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 6
                visible: root.tab === "token"
                Text {
                    text: qsTr("TOKEN"); color: Theme.ink2; font.family: Theme.fontMono
                    font.pixelSize: Theme.fsLabel; font.capitalization: Font.AllUppercase
                    font.letterSpacing: 1.0
                }
                Rectangle {
                    Layout.fillWidth: true
                    height: 92
                    color: Theme.bg
                    border.width: 1
                    border.color: tokenEdit.activeFocus ? Theme.accent : Theme.line2
                    clip: true
                    Flickable {
                        anchors { fill: parent; margins: 10 }
                        contentWidth: width
                        contentHeight: tokenEdit.implicitHeight
                        TextEdit {
                            id: tokenEdit
                            width: parent.width
                            wrapMode: TextEdit.WrapAnywhere
                            color: Theme.ink
                            font.family: Theme.fontMono; font.pixelSize: Theme.fsMono
                            selectionColor: Theme.accent
                            selectByMouse: true
                            activeFocusOnTab: true
                            enabled: !AuthController.busy
                            onTextChanged: if (AuthController.errorString !== "") AuthController.clearError()
                        }
                    }
                }
                Text {
                    text: qsTr("Paste a token issued by Cilex Vision.")
                    color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: Theme.fsSmall
                }
            }

            // error
            Text {
                Layout.fillWidth: true
                visible: AuthController.errorString !== ""
                text: AuthController.errorString
                color: Theme.bad
                font.family: Theme.fontSans; font.pixelSize: Theme.fsSmall
                wrapMode: Text.WordWrap
            }

            // submit
            Rectangle {
                id: signBtn
                Layout.fillWidth: true
                Layout.topMargin: Theme.s4
                height: 40
                activeFocusOnTab: true
                color: AuthController.busy ? Theme.accentDim
                                           : (btnMa.containsMouse ? Qt.lighter(Theme.accent, 1.06) : Theme.accent)
                border.width: signBtn.activeFocus ? 2 : 0
                border.color: Theme.ink
                Keys.onReturnPressed: root.submit()
                Keys.onEnterPressed: root.submit()
                Keys.onSpacePressed: root.submit()
                Text {
                    anchors.centerIn: parent
                    text: AuthController.busy ? qsTr("Signing in…") : qsTr("Sign in")
                    color: Theme.bg; font.family: Theme.fontSans
                    font.pixelSize: Theme.fsBody; font.weight: Font.DemiBold
                }
                MouseArea {
                    id: btnMa; anchors.fill: parent; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    enabled: !AuthController.busy
                    onClicked: root.submit()
                }
            }
        }
    }
}
