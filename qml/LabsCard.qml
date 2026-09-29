import QtQuick
import Watchtower

// One Labs observation, as its analyser filed it -- the card over the Playback navigator
// while a Labs marker is hovered. Everything on it is the server's row, nothing inferred:
// the sentence cilex-vision rendered (in the UI language), the typed fields that are
// present, and EVERY metric the analyser sent (the "enriched" part the operator asked for),
// by its own key. A value the row does not carry is simply not listed.
Rectangle {
    id: card
    property var obs: ({})
    readonly property string key: obs && obs.analyzer ? obs.analyzer : ""
    readonly property double s: obs && obs.startMs !== undefined ? obs.startMs : 0
    readonly property double e: obs && obs.endMs !== undefined ? obs.endMs : 0

    width: 380
    height: body.implicitHeight + 20
    color: Theme.panel
    border.width: 1
    border.color: Theme.line2

    // Numbers as the analyser meant them: integers whole, fractions to four significant
    // digits, the very small or very large in exponent form -- never rounded to zero.
    function fmt(v) {
        if (v === null || v === undefined) return "—";
        if (typeof v === "boolean") return v ? qsTr("yes") : qsTr("no");
        if (typeof v === "number") {
            if (Number.isInteger(v)) return String(v);
            var a = Math.abs(v);
            if (a !== 0 && (a < 0.001 || a >= 1e6)) return v.toExponential(2);
            return String(parseFloat(v.toPrecision(4)));
        }
        if (Array.isArray(v)) return v.length ? v.join(", ") : "—";
        return String(v);
    }

    readonly property var fields: {
        var o = card.obs, out = [];
        if (!o || !o.analyzer) return out;
        function add(k, v) { if (v !== null && v !== undefined && v !== "") out.push({ k: k, v: card.fmt(v) }); }
        add("shape_class", o.shape_class);
        add("shape_confidence", o.shape_confidence);
        // NOT shape_suggests. It is no part of what the analyser measured: the server looks it
        // up per shape class (labs_shape_classes, cilex-vision 0086), so EVERY wide blob reads
        // "car, truck, bus" -- on 2026-09-29 a 35 x 23 px crow on 5 Улица 7 (15:57:58) did, on
        // this card, beside real measurements, where it read as a detection. Nothing here
        // recognises objects; object_class, below, would say so if anything did.
        add("object_class", o.object_class);
        add("confidence", o.confidence);
        add("object_count", o.object_count);
        add("scene_light", o.scene_light);
        if (o.bbox_x !== null && o.bbox_x !== undefined)
            out.push({ k: "bbox", v: card.fmt(o.bbox_x) + ", " + card.fmt(o.bbox_y) + "  "
                                     + card.fmt(o.bbox_w) + " × " + card.fmt(o.bbox_h) });
        var m = o.metrics || {}, ks = Object.keys(m).sort();
        for (var i = 0; i < ks.length; i++) add(ks[i], m[ks[i]]);
        return out;
    }

    Column {
        id: body
        x: 10; y: 10
        width: card.width - 20
        spacing: 6

        Row {
            spacing: 7
            Rectangle { width: 8; height: 8; y: 4; color: LabsNames.color(card.key) }
            Text { text: LabsNames.title(card.key); color: Theme.ink
                   font.family: Theme.fontSans; font.pixelSize: 13; font.weight: Font.DemiBold }
            Text { y: 3; text: card.key; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9 }
        }
        Text {
            text: PbFmt.wd(card.s) + " " + PbFmt.hms(card.s)
                  + (card.e > card.s ? " – " + PbFmt.hms(card.e) + "  (" + PbFmt.dur(card.e - card.s) + ")" : "")
            color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 10
        }
        Text {
            width: parent.width
            visible: text !== ""
            text: card.obs && card.obs.text ? card.obs.text : ""
            wrapMode: Text.WordWrap
            color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12
        }
        Rectangle { width: parent.width; height: 1; color: Theme.line; visible: card.fields.length > 0 }
        // Short values pair up two to a line; a long one (an illumination note, a track's
        // path code) takes a whole line and wraps, rather than being cut to "…".
        Flow {
            width: parent.width
            spacing: 0
            Repeater {
                model: card.fields
                delegate: Item {
                    required property var modelData
                    readonly property bool wide: modelData.v.length > 13 || modelData.k.length > 16   // what a half line holds at 9 px mono
                    width: wide ? body.width : body.width / 2
                    height: pairRow.implicitHeight + 2
                    Row {
                        id: pairRow
                        width: parent.width - 8
                        spacing: 6
                        Text { id: kT; width: parent.parent.wide ? Math.min(implicitWidth, 150) : parent.width * 0.52
                               elide: Text.ElideRight; text: parent.parent.modelData.k
                               color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9 }
                        Text { width: parent.width - kT.width - 6
                               wrapMode: parent.parent.wide ? Text.WrapAnywhere : Text.NoWrap
                               elide: parent.parent.wide ? Text.ElideNone : Text.ElideRight
                               text: parent.parent.modelData.v
                               color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 9 }
                    }
                }
            }
        }
        Text {
            text: qsTr("analyser build %1").arg(card.obs && card.obs.analyzer_version ? card.obs.analyzer_version : "—")
            color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 8
        }
    }
}
