import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Watchtower

// Above the camera surface, so reviewing an alarm never hides evidence pixels.
Rectangle {
    id: root
    required property var controller
    readonly property var incident: controller.reviewIncident
    readonly property string disposition: String(incident.disposition || "pending")
    readonly property bool suppressed: !!incident.suppressed
    readonly property bool confirmed: disposition === "confirmed" || disposition === "true_incident"
    readonly property bool falseAlarm: disposition === "false_alarm"
    readonly property bool resolved: incident.state === "resolved" || incident.state === "healthy" || incident.state === "recovered"
    visible: !!incident.incident_id
    color: confirmed || resolved ? Theme.panel2 : Theme.badDim
    implicitHeight: body.implicitHeight + 24
    border.color: confirmed || resolved ? Theme.line2 : Theme.bad

    function localTime(value) {
        var d = new Date(value || "");
        return isNaN(d.getTime()) ? String(value || "") : d.toLocaleString(Qt.locale(), Locale.ShortFormat);
    }
    ColumnLayout {
        id: body
        anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
        spacing: 8
        Text {
            Layout.fillWidth: true
            text: root.resolved ? qsTr("Camera visibility restored")
                  : root.suppressed ? qsTr("Camera obstruction alerts snoozed")
                  : root.confirmed ? qsTr("Obstruction confirmed — incident acknowledged")
                  : root.falseAlarm ? qsTr("Reported as false alarm")
                  : qsTr("Potential obstruction — review this camera")
            color: Theme.ink
            font.family: Theme.fontSans
            font.bold: true
            font.pixelSize: 16
            wrapMode: Text.WordWrap
        }
        Text {
            Layout.fillWidth: true
            text: root.suppressed && root.incident.suppressed_until
                  ? qsTr("Alerts suppressed until %1. Monitoring and recording continue.").arg(root.localTime(root.incident.suppressed_until))
                  : root.confirmed
                    ? qsTr("Acknowledged as a true incident. The obstruction remains active until visibility recovers.")
                    : qsTr("False alarm snoozes this camera for 6 hours and queues a report with the triggering 30-second clip.")
            color: Theme.ink2
            font.pixelSize: 12
            wrapMode: Text.WordWrap
        }
        Flow {
            Layout.fillWidth: true
            spacing: 8
            Button {
                objectName: "cameraObstructionFalseAlarm"
                visible: !root.falseAlarm && !root.confirmed
                enabled: root.controller.canManage && !root.controller.actionBusy
                text: qsTr("False alarm — snooze 6 hours")
                onClicked: root.controller.act(root.incident.incident_id, "false_alarm")
            }
            Button {
                objectName: "cameraObstructionConfirm"
                visible: !root.confirmed && !root.falseAlarm
                enabled: root.controller.canManage && !root.controller.actionBusy
                text: qsTr("Confirm true incident")
                onClicked: root.controller.act(root.incident.incident_id, "confirm")
            }
            Button {
                objectName: "cameraObstructionDisable7d"
                visible: root.controller.canManage && root.falseAlarm && root.incident.can_disable_7d === true
                enabled: !root.controller.actionBusy
                text: qsTr("Disable this camera's alerts for 7 days")
                onClicked: disableConfirmation.open()
            }
        }
        Text {
            Layout.fillWidth: true
            visible: !root.controller.canManage
            text: qsTr("An authorised operator or administrator must classify this alarm.")
            color: Theme.ink2
            wrapMode: Text.WordWrap
        }
        Text {
            Layout.fillWidth: true
            visible: root.falseAlarm && (!!root.incident.report_status || !!root.incident.evidence_status)
            text: qsTr("False-alarm report: %1 · evidence: %2")
                    .arg(root.incident.report_status || qsTr("pending"))
                    .arg(root.incident.evidence_status || qsTr("pending"))
            color: Theme.ink2
            font.pixelSize: 12
            wrapMode: Text.WordWrap
        }
        Text {
            Layout.fillWidth: true
            visible: root.controller.errorString !== ""
            text: root.controller.errorString
            color: Theme.warn
            wrapMode: Text.WordWrap
        }
    }
    Dialog {
        id: disableConfirmation
        objectName: "cameraObstructionDisableConfirmation"
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(520, parent.width - 40)
        implicitHeight: 240
        modal: true
        title: qsTr("Disable obstruction alerts for 7 days?")
        standardButtons: Dialog.Ok | Dialog.Cancel
        onAccepted: root.controller.act(root.incident.incident_id, "disable_7d")
        contentItem: Label {
            wrapMode: Text.WordWrap
            text: qsTr("This camera has repeated false alarms. Alerts will be disabled for 7 days; recording and monitoring continue.")
        }
    }
}
