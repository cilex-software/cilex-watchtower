import QtQuick
import Watchtower

// Bottom-right toast stack (design §25). Phase 1: shows feedback toasts (e.g.
// snapshot captured) that auto-dismiss. Full alert grouping / max-3 behavior
// arrives with the Events & Alerts work.
Item {
    id: root
    anchors.fill: parent

    // kind: "bad" (single alert) | "accent" (info/grouped). The action button either opens
    // actionUrl externally, OR — if actionId is set — emits actionInvoked(actionId) so the host
    // can run an in-app callback (e.g. re-export as High). Pass one or the other.
    signal actionInvoked(string actionId)
    function show(title, subtitle, kind, actionLabel, actionUrl, actionId) {
        toastModel.append({
            t: title || "",
            s: subtitle || "",
            kind: kind || "accent",
            aLabel: actionLabel || "",
            aUrl: actionUrl || "",
            aId: actionId || ""
        });
    }

    ListModel { id: toastModel }

    Column {
        anchors { right: parent.right; bottom: parent.bottom; margins: 20 }
        spacing: 8

        Repeater {
            model: toastModel
            delegate: Toast {
                required property int index
                required property string t
                required property string s
                required property string kind
                required property string aLabel
                required property string aUrl
                required property string aId

                title: t
                subtitle: s
                edgeColor: kind === "bad" ? Theme.bad : Theme.accent
                actionLabel: aLabel

                onActionClicked: {
                    if (aId !== "")
                        root.actionInvoked(aId);
                    else if (aUrl !== "")
                        Qt.openUrlExternally(aUrl);
                    toastModel.remove(index);
                }
                onClosed: toastModel.remove(index)

                Timer { running: true; interval: 7000; onTriggered: toastModel.remove(index) }
            }
        }
    }
}
