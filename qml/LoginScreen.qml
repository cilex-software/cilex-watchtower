import QtQuick
import QtQuick.Layouts
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
        property alias label: lbl.text
        property alias text: input.text
        property alias echoMode: input.echoMode
        property alias placeholder: ph.text
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
                anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
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
            }

            // password tab
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.s16
                visible: root.tab === "password"
                Field { id: userField; label: qsTr("Username"); placeholder: qsTr("operator") }
                Field { id: passField; label: qsTr("Password"); echoMode: TextInput.Password }
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
