import QtQuick
import Watchtower

// Manual paging for large groups/views (design §35). Prev / range / Next.
// No auto-cycling in MVP.
Row {
    id: root

    property int page: 1
    property int pageCount: 1
    property string rangeText: ""   // e.g. "17–32 of 104"

    signal prev()
    signal next()

    spacing: 8

    IconButton {
        name: "back"
        anchors.verticalCenter: parent.verticalCenter
        enabled: root.page > 1
        bgColor: Theme.bg
        borderColor: Theme.line2
        iconColor: Theme.ink2
        hoverIcon: Theme.accent
        hoverBorder: Theme.accent
        tip: "Previous page"
        onClicked: root.prev()
    }

    Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.rangeText !== "" ? root.rangeText
                                    : ("Page " + root.page + " of " + root.pageCount)
        color: Theme.ink2
        font.family: Theme.fontMono
        font.pixelSize: Theme.fsMono
    }

    IconButton {
        name: "fwd"
        anchors.verticalCenter: parent.verticalCenter
        enabled: root.page < root.pageCount
        bgColor: Theme.bg
        borderColor: Theme.line2
        iconColor: Theme.ink2
        hoverIcon: Theme.accent
        hoverBorder: Theme.accent
        tip: "Next page"
        onClicked: root.next()
    }
}
