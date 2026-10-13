pragma Singleton
import QtQml

// In-memory API fixture. Real Settings serialization is covered by the C++
// regression; this fixture proves the shipping screen writes/reloads its API.
QtObject {
    property int maxLiveDecodes: 32
    property var cells: ({})
    property var layouts: ({})
    property var spans: ({})
    function reset() { cells = ({}); layouts = ({}); spans = ({}); }
    function hasLiveCells(group) { return Object.prototype.hasOwnProperty.call(cells, group); }
    function liveCells(group) { return hasLiveCells(group) ? cells[group].slice() : []; }
    function setLiveCells(group, ids) { cells[group] = ids.slice(); }
    function liveLayout(group) { return layouts[group] ? layouts[group].slice() : []; }
    function setLiveLayout(group, ids) { layouts[group] = ids.slice(); }
    function clearLiveLayout(group) { delete cells[group]; delete layouts[group]; }
    function liveSpans(group, layout) { return spans[group + ":" + layout] || ""; }
    function setLiveSpans(group, layout, value) { spans[group + ":" + layout] = value; }
    function clearLiveSpans(group, layout) { delete spans[group + ":" + layout]; }
}
