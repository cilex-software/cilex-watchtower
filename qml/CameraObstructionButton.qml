import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import Watchtower

// Watchtower's square, token-based action treatment with native button semantics.
Button {
    id: control
    property string leadingIcon: ""
    property string variant: "secondary" // secondary | primary | danger
    readonly property color foreground: variant === "primary" ? Theme.bg
                                        : variant === "danger" ? Theme.bad : Theme.ink
    implicitWidth: Math.ceil(labelMetrics.advanceWidth) + 2 + leftPadding + rightPadding
                   + (leadingIcon !== "" ? Theme.s16 + Theme.s8 : 0)
    implicitHeight: Math.max(Theme.s36, contentItem.implicitHeight + topPadding + bottomPadding)
    leftPadding: Theme.s12
    rightPadding: Theme.s12
    topPadding: Theme.s8
    bottomPadding: Theme.s8
    font.family: Theme.fontSans
    font.pixelSize: Theme.fsSmall
    font.weight: Font.DemiBold
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    opacity: enabled ? 1 : 0.45
    Accessible.name: text
    Keys.onReturnPressed: (event) => { if (enabled) clicked(); event.accepted = true; }
    Keys.onEnterPressed: (event) => { if (enabled) clicked(); event.accepted = true; }

    TextMetrics { id: labelMetrics; text: control.text; font: control.font }

    background: Rectangle {
        color: control.variant === "primary" ? (control.down ? Theme.warnDim
                                                   : control.hovered ? Qt.lighter(Theme.accent, 1.08) : Theme.accent)
               : control.variant === "danger" ? (control.down ? Theme.badDim : Theme.badSoft)
               : control.down ? Theme.bg : control.hovered ? Theme.panel3 : Theme.panel
        border.width: Theme.borderThin
        border.color: control.visualFocus ? Theme.accent
                      : control.variant === "primary" ? Theme.accent
                      : control.variant === "danger" ? Theme.bad
                      : control.hovered ? Theme.ink3 : Theme.line2
        Rectangle {
            anchors { fill: parent; margins: 3 }
            color: "transparent"
            visible: control.visualFocus
            border.color: control.variant === "primary" ? Theme.bg : Theme.accent
            border.width: Theme.borderThin
        }
    }
    contentItem: RowLayout {
        spacing: Theme.s8
        Icon {
            Layout.minimumWidth: Theme.s16
            Layout.maximumWidth: Theme.s16
            visible: control.leadingIcon !== ""
            name: control.leadingIcon
            size: Theme.s16
            color: control.foreground
        }
        Text {
            id: label
            Layout.fillWidth: true
            text: control.text
            font: control.font
            color: control.foreground
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
        }
    }
}
