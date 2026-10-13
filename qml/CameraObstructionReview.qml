import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Watchtower

// A compact status strip above the picture; alarm colour stays on the edge/icon.
Rectangle {
    id: root
    required property var controller
    readonly property var incident: controller.reviewIncident
    readonly property string disposition: String(incident.disposition || "pending")
    readonly property bool suppressed: !!incident.suppressed
    readonly property bool confirmed: disposition === "confirmed" || disposition === "true_incident"
    readonly property bool falseAlarm: disposition === "false_alarm"
    readonly property bool resolved: incident.state === "resolved" || incident.state === "healthy" || incident.state === "recovered"
    readonly property color statusColor: resolved ? Theme.good : suppressed || falseAlarm ? Theme.ink2
                                        : confirmed ? Theme.accent : Theme.bad
    readonly property bool needsClassification: !falseAlarm && !confirmed
    readonly property bool canDisable: controller.canManage && falseAlarm && incident.can_disable_7d === true
    readonly property bool stacked: width < actions.naturalWidth + 460
    visible: !!incident.incident_id
    color: Theme.panel
    implicitHeight: body.implicitHeight + Theme.s24

    Rectangle { anchors { left: parent.left; top: parent.top; bottom: parent.bottom } width: Theme.edgeAccent; color: root.statusColor }
    Rectangle { anchors { left: parent.left; right: parent.right; bottom: parent.bottom } height: Theme.borderThin; color: Theme.line }

    function localTime(value) {
        var d = new Date(value || "");
        return isNaN(d.getTime()) ? String(value || "") : d.toLocaleString(Qt.locale(), Locale.ShortFormat);
    }
    ColumnLayout {
        id: body
        anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: Theme.s20; rightMargin: Theme.s20; topMargin: Theme.s12 }
        spacing: Theme.s8
        GridLayout {
            Layout.fillWidth: true
            columns: root.stacked || !actions.visible ? 1 : 2
            columnSpacing: Theme.s24
            rowSpacing: Theme.s12
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.s12
                Rectangle {
                    Layout.alignment: Qt.AlignTop
                    implicitWidth: Theme.s36
                    implicitHeight: Theme.s36
                    color: root.resolved ? Theme.goodSoft : root.suppressed || root.falseAlarm ? Theme.panel2
                           : root.confirmed ? Theme.accentSoft : Theme.badSoft
                    Icon {
                        anchors.centerIn: parent
                        size: Theme.s18
                        name: root.resolved ? "check" : root.suppressed || root.falseAlarm ? "history" : "alert"
                        color: root.statusColor
                    }
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Theme.s4
                    Text {
                        Layout.fillWidth: true
                        text: root.resolved ? qsTr("Camera visibility restored")
                              : root.suppressed ? qsTr("Camera obstruction alerts snoozed")
                              : root.confirmed ? qsTr("Obstruction confirmed — incident acknowledged")
                              : root.falseAlarm ? qsTr("Reported as false alarm")
                              : qsTr("Potential obstruction — review this camera")
                        color: Theme.ink
                        font.family: Theme.fontSans
                        font.weight: Font.DemiBold
                        font.pixelSize: Theme.fsBody
                        wrapMode: Text.WordWrap
                        Accessible.role: Accessible.StaticText
                        Accessible.name: text
                    }
                    Text {
                        Layout.fillWidth: true
                        text: root.suppressed && root.incident.suppressed_until
                              ? qsTr("Alerts suppressed until %1. Monitoring and recording continue.").arg(root.localTime(root.incident.suppressed_until))
                              : root.confirmed
                                ? qsTr("Acknowledged as a true incident. The obstruction remains active until visibility recovers.")
                                : qsTr("False alarm snoozes this camera for 6 hours and queues a report with the triggering 30-second clip.")
                        color: Theme.ink2
                        font.family: Theme.fontSans
                        font.pixelSize: Theme.fsSmall
                        wrapMode: Text.WordWrap
                    }
                }
            }
            Flow {
                id: actions
                objectName: "cameraObstructionActions"
                visible: root.needsClassification || root.canDisable
                Layout.fillWidth: root.stacked
                Layout.preferredWidth: root.stacked ? -1 : naturalWidth
                Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                spacing: Theme.s8
                readonly property real naturalWidth: root.needsClassification
                    ? falseButton.implicitWidth + confirmButton.implicitWidth + spacing
                    : disableButton.implicitWidth
                CameraObstructionButton {
                    id: falseButton
                    objectName: "cameraObstructionFalseAlarm"
                    width: Math.min(implicitWidth, actions.width)
                    visible: root.needsClassification
                    enabled: root.controller.canManage && !root.controller.actionBusy
                    leadingIcon: "history"
                    text: qsTr("False alarm — snooze 6 hours")
                    onClicked: root.controller.act(root.incident.incident_id, "false_alarm")
                }
                CameraObstructionButton {
                    id: confirmButton
                    objectName: "cameraObstructionConfirm"
                    width: Math.min(implicitWidth, actions.width)
                    visible: root.needsClassification
                    enabled: root.controller.canManage && !root.controller.actionBusy
                    leadingIcon: "check"
                    variant: "primary"
                    text: qsTr("Confirm true incident")
                    onClicked: root.controller.act(root.incident.incident_id, "confirm")
                }
                CameraObstructionButton {
                    id: disableButton
                    objectName: "cameraObstructionDisable7d"
                    width: Math.min(implicitWidth, actions.width)
                    visible: root.canDisable
                    enabled: !root.controller.actionBusy
                    leadingIcon: "off"
                    text: qsTr("Disable this camera's alerts for 7 days")
                    onClicked: disableConfirmation.open()
                }
            }
        }
        Text {
            Layout.fillWidth: true
            visible: !root.controller.canManage
            text: qsTr("An authorised operator or administrator must classify this alarm.")
            color: Theme.ink2
            font.family: Theme.fontSans
            font.pixelSize: Theme.fsSmall
            wrapMode: Text.WordWrap
        }
        Text {
            Layout.fillWidth: true
            visible: root.falseAlarm && (!!root.incident.report_status || !!root.incident.evidence_status)
            text: qsTr("False-alarm report: %1 · evidence: %2")
                    .arg(root.incident.report_status || qsTr("pending"))
                    .arg(root.incident.evidence_status || qsTr("pending"))
            color: Theme.ink2
            font.family: Theme.fontSans
            font.pixelSize: Theme.fsSmall
            wrapMode: Text.WordWrap
        }
        Text {
            Layout.fillWidth: true
            visible: root.controller.errorString !== ""
            text: root.controller.errorString
            color: Theme.warn
            font.family: Theme.fontSans
            font.pixelSize: Theme.fsSmall
            wrapMode: Text.WordWrap
        }
    }
    Dialog {
        id: disableConfirmation
        objectName: "cameraObstructionDisableConfirmation"
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(560, parent.width - Theme.s32)
        padding: Theme.s24
        modal: true
        closePolicy: Popup.CloseOnEscape
        title: qsTr("Disable obstruction alerts for 7 days?")
        onOpened: cancelDisable.forceActiveFocus(Qt.PopupFocusReason)
        onAccepted: root.controller.act(root.incident.incident_id, "disable_7d")
        background: Rectangle { color: Theme.panel; border.color: Theme.line2; border.width: Theme.borderThin }
        header: null
        footer: null
        implicitHeight: dialogBody.implicitHeight + topPadding + bottomPadding
        contentItem: ColumnLayout {
            id: dialogBody
            spacing: Theme.s20
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.s12
                Icon { name: "alert"; size: Theme.s20; color: Theme.accent }
                Text {
                    Layout.fillWidth: true
                    text: disableConfirmation.title
                    font.family: Theme.fontSans
                    font.pixelSize: Theme.fsTitle
                    font.weight: Font.DemiBold
                    color: Theme.ink
                    wrapMode: Text.WordWrap
                }
            }
            Text {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                font.family: Theme.fontSans
                font.pixelSize: Theme.fsBody
                color: Theme.ink2
                text: qsTr("This camera has repeated false alarms. Alerts will be disabled for 7 days; recording and monitoring continue.")
            }
            Rectangle { Layout.fillWidth: true; implicitHeight: Theme.borderThin; color: Theme.line }
            Flow {
                id: confirmationActions
                Layout.fillWidth: true
                spacing: Theme.s8
                layoutDirection: Qt.RightToLeft
                CameraObstructionButton {
                    objectName: "cameraObstructionDisableAccept"
                    enabled: root.controller.canManage && !root.controller.actionBusy && root.incident.can_disable_7d === true
                    width: Math.min(implicitWidth, confirmationActions.width)
                    variant: "danger"
                    leadingIcon: "off"
                    text: qsTr("Disable this camera's alerts for 7 days")
                    onClicked: disableConfirmation.accept()
                }
                CameraObstructionButton {
                    id: cancelDisable
                    objectName: "cameraObstructionDisableCancel"
                    text: qsTranslate("SaveViewModal", "Cancel")
                    onClicked: disableConfirmation.reject()
                }
            }
        }
    }
}
