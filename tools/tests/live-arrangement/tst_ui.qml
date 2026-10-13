import QtQuick
import QtTest
import Watchtower

Rectangle {
    id: screen
    width: 1600
    height: 1100
    color: Theme.bg
    FontLoader { source: "../../../assets/fonts/SpaceGrotesk-Variable.ttf" }
    FontLoader { source: "../../../assets/fonts/JetBrainsMono-Regular.ttf" }

    QtObject {
        id: roster
        property var cameras: []
        property int total: cameras.length
        property int stateRev: 0
        property bool loading: false
        property bool listUnavailable: false
        property bool liveViewEnabled: true
        property bool recordingEnabled: true
        function page(group, filter, sort, number, size) {
            var rows = cameras.filter(function(cam) {
                return (group === "" || cam.groupId === group)
                    && (filter === "" || (filter === "online" && cam.live === CameraStatus.Live)
                        || (filter === "offline" && cam.live === CameraStatus.Offline)
                        || (filter === "favorites" && cam.favorite));
            });
            if (sort === "alpha") rows.sort(function(a,b) { return a.name.localeCompare(b.name); });
            else if (sort === "ip") rows.sort(function(a,b) { return Number(a.ip.split(".")[3]) - Number(b.ip.split(".")[3]); });
            else if (sort === "status" || sort === "live")
                rows.sort(function(a,b) { return a.live - b.live; });
            return rows.slice((number - 1) * size, number * size);
        }
        function countFiltered(group, filter) { return page(group, filter, "default", 1, total).length; }
        function groupList() {
            return [{id:"street", name:"Street", total:31}, {id:"inside", name:"Inside", total:9}];
        }
        function cameraByBackendId(id) {
            for (var i = 0; i < cameras.length; ++i)
                if (cameras[i].camId === id) return cameras[i];
            return {};
        }
        function setRecentCameras(ids) {}
        function liveSinceMs(id) { return -1; }
        function recSinceMs(id) { return -1; }
        function refresh() {}
        function toggleFavoriteById(id) {}
    }

    Component {
        id: wallComponent
        LiveMonitor {
            anchors.fill: parent
            cameraModel: roster
            layout: "5x7"
            sortMode: "alpha"
            groupId: "street"
            groupLabel: "Street"
            arrangeMode: true
            onPageRequested: (nextPage) => page = nextPage
            onSortRequested: (mode) => sortMode = mode
        }
    }

    TestCase {
        id: test
        name: "LiveArrangementUi"
        when: windowShown
        property var wall: null
        property string originalRoster: ""

        function rows() {
            // Deliberately reverse stream order: the picker cannot accidentally
            // pass alphabetical checks merely by preserving the fixture order.
            var result = [];
            for (var n = 40; n >= 1; --n) {
                var suffix = (n < 10 ? "0" : "") + n;
                result.push({camId:"c" + suffix, name:"Camera " + suffix,
                    ip:"192.0.2." + (41 - n), groupId:n <= 31 ? "street" : "inside",
                    groupName:n <= 31 ? "Street" : "Inside", model:"Fixture", favorite:n % 2 === 0,
                    live:n % 4 === 0 ? CameraStatus.Offline : CameraStatus.Live,
                    recording:CameraStatus.Recording, timestamp:"", lastSeen:"", lastSegmentAt:"",
                    pattern:0, rtspUrl:"", rtspSubUrl:"", snapshotUrl:"", hasAudio:false});
            }
            return result;
        }
        function init() {
            Settings.reset();
            roster.cameras = rows();
            originalRoster = JSON.stringify(roster.cameras);
            wall = wallComponent.createObject(screen);
            verify(wall !== null, "production LiveMonitor created");
            wait(60);
        }
        function cleanup() {
            compare(JSON.stringify(roster.cameras), originalRoster, "arrangement must not alter roster/group membership");
            if (wall) { wall.destroy(); wall = null; }
            wait(0);
        }
        function ids(cameras) {
            return cameras.map(function(cam) { return cam ? cam.camId : ""; });
        }
        function members() { return ids(wall.arrangedFull).filter(function(id) { return id !== ""; }); }
        function assertUnique() {
            var current = members();
            compare(current.filter(function(id, index) { return current.indexOf(id) === index; }).length,
                    current.length, "each camera occurs once across the entire view");
        }
        function clickNamed(name) {
            var item = findChild(wall, name);
            verify(item !== null, name + " exists");
            verify(item.visible && item.width > 0 && item.height > 0, name + " is clickable");
            mouseClick(item);
            wait(20);
        }
        function snapshot(name) {
            var image = grabImage(screen);
            compare(image.width, screen.width);
            compare(image.height, screen.height);
            // QtTest's image.save() is void; verify the capture above and let
            // the runner verify that each expected output file was written.
            image.save("/tmp/watchtower-live-arrangement-" + name + ".png");
        }

        function test_emptyCellAddsOutsideGroupByClick() {
            compare(wall.total, 31);
            compare(wall.perPage, 35);
            for (var slot = 31; slot < 35; ++slot) {
                var empty = findChild(wall, "emptyLiveCell_" + slot);
                verify(empty && empty.visible, "trailing empty slot " + slot + " is visible");
            }
            snapshot("31-cameras-35-cells");
            clickNamed("emptyLiveCell_34");
            compare(wall.pickerCell, 34);
            clickNamed("cameraPicker_c40");
            compare(wall.pickerCell, -1);
            compare(wall.total, 32);
            compare(wall.slotCount, 35);
            compare(ids(wall.arrangedFull)[34], "c40");
            compare(ids(wall.arrangedFull).slice(31, 34), ["", "", ""]);
            compare(roster.countFiltered("street", ""), 31);
            verify(Settings.hasLiveCells("street"));
            compare(Settings.liveCells("street")[34], "c40");
            snapshot("outside-group-added");
            assertUnique();
        }

        function test_removeArbitraryThenEveryCameraAndReAdd() {
            clickNamed("arrangeLiveCell_6");
            clickNamed("removeCameraFromView");
            compare(wall.total, 30);
            compare(ids(wall.arrangedFull)[6], "");
            verify(members().indexOf("c07") < 0);
            clickNamed("emptyLiveCell_6");
            compare(wall.pickerCell, 6);
            wall.pickerCell = -1;
            var slots = wall.arrangedFull.length;
            for (var slot = 0; slot < slots; ++slot)
                if (wall.arrangedFull[slot]) wall.removeFromCell(slot);
            wait(50);
            compare(wall.total, 0);
            compare(members(), []);
            verify(Settings.hasLiveCells("street"), "empty view remains an explicit saved choice");
            clickNamed("emptyLiveCell_34");
            clickNamed("cameraPicker_c32");
            compare(wall.total, 1);
            compare(ids(wall.arrangedFull)[34], "c32");
            snapshot("one-camera-after-clear");
        }

        function test_noDuplicatesWhenSelectingAnotherPageCamera() {
            wall.layout = "4";
            wait(30);
            compare(wall.pageCount, 8);
            var first = ids(wall.arrangedFull)[0], other = ids(wall.arrangedFull)[5];
            wall.assignToCell(0, other);
            compare(ids(wall.arrangedFull)[0], other);
            compare(ids(wall.arrangedFull)[5], first);
            compare(wall.total, 31);
            assertUnique();
            wall.page = 8;
            wall.assignToCell(3, other);
            compare(ids(wall.arrangedFull)[31], other);
            compare(ids(wall.arrangedFull)[0], "");
            compare(wall.total, 31);
            assertUnique();
            wall.pickerHideShown = true;
            compare(wall.pickModel.length, 9, "Hide on-wall covers every page of this view");
        }

        function test_arbitraryEmptyLayouts_data() {
            return [{tag:"single", layout:"1"}, {tag:"four", layout:"4"},
                    {tag:"nine", layout:"9"}, {tag:"thirty-five", layout:"5x7"},
                    {tag:"hundred", layout:"10x10"}, {tag:"feature", layout:"plus4"},
                    {tag:"center", layout:"center13"}];
        }
        function test_arbitraryEmptyLayouts(data) {
            Settings.setLiveCells("street", []);
            wall.arrangeRev++;
            wall.layout = data.layout;
            wait(30);
            compare(wall.total, 0);
            compare(wall.visibleCellCount, wall.perPage);
            var last = wall.visibleCellCount - 1;
            clickNamed("emptyLiveCell_" + last);
            clickNamed("cameraPicker_c40");
            compare(wall.total, 1);
            compare(ids(wall.arrangedFull)[last], "c40");
            compare(ids(wall.arrangedFull).filter(function(id) { return id === ""; }).length, last);
            clickNamed("removeLiveCell_" + last);
            compare(wall.total, 0, "direct tile remove button empties this layout");
            clickNamed("emptyLiveCell_0");
            clickNamed("cameraPicker_c01");
            compare(wall.total, 1);
            compare(ids(wall.arrangedFull)[0], "c01");
            assertUnique();
        }

        function test_addPageAllowsAssignmentsBeyondSingleGrid() {
            wall.layout = "10x10";
            wait(30);
            compare(wall.perPage, 100);
            clickNamed("addViewPage");
            compare(wall.page, 2);
            compare(wall.pageCount, 2);
            compare(wall.total, 31);
            compare(wall.slotCount, 200);
            clickNamed("emptyLiveCell_99");
            clickNamed("cameraPicker_c40");
            compare(ids(wall.arrangedFull)[199], "c40");
            compare(wall.total, 32);
            clickNamed("addViewPage");
            compare(wall.page, 3);
            compare(wall.pageCount, 3);
            clickNamed("emptyLiveCell_0");
            clickNamed("cameraPicker_c01");
            compare(ids(wall.arrangedFull)[200], "c01");
            compare(ids(wall.arrangedFull)[0], "");
            compare(wall.total, 32, "moving an existing camera to a new page does not duplicate it");
            assertUnique();
        }

        function test_filteredOccupiedCellShowsItsCameraBeforeEditing() {
            wall.removeFromCell(0); // Establish explicit cells without touching c04.
            wall.arrangeMode = false;
            wall.statusFilter = "online";
            wait(30);
            compare(ids(wall.arrangedFull)[3], "");
            var hidden = findChild(wall, "emptyLiveCell_3");
            verify(hidden && hidden.parent.filterHidden, "filtered occupied position differs from an empty cell");
            snapshot("filtered-occupied-cells");
            clickNamed("emptyLiveCell_3");
            verify(wall.arrangeMode, "editing a filtered member reveals the real camera");
            compare(ids(wall.pagedCameras)[3], "c04");
            compare(wall.pickerCell, 3);
            clickNamed("removeCameraFromView");
            verify(wall._fullIds().indexOf("c04") < 0);
            verify(wall._fullIds().indexOf("c08") >= 0, "other previously filtered cameras remain members");
        }

        function test_pickerFollowsEverySortAndIndependentFilters() {
            var modes = ["alpha", "ip", "default", "status", "live"];
            for (var i = 0; i < modes.length; ++i) {
                wall.selectSort(modes[i]);
                compare(ids(wall.pickModel), ids(roster.page("", "", modes[i], 1, 40)),
                        "picker follows the wall's selected " + modes[i] + " order");
            }
            wall.selectSort("alpha");
            clickNamed("arrangeLiveCell_0");
            snapshot("picker-all-sorted");
            clickNamed("cameraPickerGroup_inside");
            compare(wall.pickModel.length, 9);
            wall.pickerSearch = "Camera 40";
            compare(ids(wall.pickModel), ["c40"]);
            wall.pickerSearch = "192.0.2.2";
            compare(ids(wall.pickModel), ["c39"]);
            wall.pickerSearch = "";
            clickNamed("cameraPickerGroup_");
            clickNamed("cameraPickerHideShown");
            compare(wall.pickModel.length, 9);
            verify(wall.pickModel.every(function(cam) { return cam.groupId === "inside"; }));
        }

        function test_filtersAndSortPreserveExplicitMembershipAndGaps() {
            wall.removeFromCell(1);
            wall.assignToCell(34, "c40");
            var expected = members().slice().sort();
            var persisted = Settings.liveCells("street").slice();
            wall.arrangeMode = false;
            wall.statusFilter = "online";
            verify(members().every(function(id) { return roster.cameraByBackendId(id).live === CameraStatus.Live; }));
            compare(Settings.liveCells("street"), persisted);
            wall.statusFilter = "";
            compare(members().slice().sort(), expected);
            wall.selectSort("ip");
            compare(members().slice().sort(), expected);
            compare(ids(wall.arrangedFull)[1], "", "explicit sort keeps an interior empty cell");
            compare(ids(wall.arrangedFull).slice(31, 34), ["", "", ""], "explicit sort keeps trailing gaps");
            var sortedMembers = ids(roster.page("", "", "ip", 1, 40)).filter(function(id) {
                return expected.indexOf(id) >= 0;
            });
            compare(members(), sortedMembers);
            wall.arrangeMode = true;
            compare(members().slice().sort(), expected);
            verify(members().indexOf("c02") < 0, "sorting cannot re-add a removed camera");
            verify(members().indexOf("c40") >= 0, "sorting cannot discard a camera from another group");
            assertUnique();
        }

        function test_firstEditOnFilteredWallRetainsHiddenMembers() {
            wall.arrangeMode = false;
            wall.statusFilter = "online";
            wait(30);
            var before = ids(wall.baseCells), shown = ids(wall.pagedCameras);
            verify(before.length > shown.length, "fixture contains cameras hidden by the filter");
            verify(wall.visibleCellCount > shown.length, "filtered auto-fit wall has a trailing empty cell");
            var emptySlot = wall.visibleCellCount - 1;
            clickNamed("emptyLiveCell_" + emptySlot);
            clickNamed("cameraPicker_c39"); // An online camera in the other group.
            compare(wall._fullIds().filter(function(id) { return id !== ""; }).slice().sort(),
                    before.concat(["c39"]).sort(), "adding through a filtered gap retains hidden group cameras");
            compare(ids(wall.pagedCameras).slice(0, shown.length), shown,
                    "adding through a filtered gap keeps earlier visible cells in place");
            compare(ids(wall.pagedCameras)[emptySlot], "c39");
            var removed = shown[1];
            wall.openCellPicker(1);
            wait(20);
            clickNamed("removeCameraFromView");
            wall.statusFilter = "";
            compare(members().slice().sort(), before.filter(function(id) { return id !== removed; }).concat(["c39"]).sort(),
                    "removing a filtered visible slot affects only the chosen camera");
            assertUnique();
        }

        function test_reloadEmptyViewAndResetToGroup() {
            wall.removeFromCell(2);
            wall.assignToCell(34, "c40");
            var saved = ids(wall.arrangedFull);
            wall.destroy();
            wait(0);
            wall = wallComponent.createObject(screen);
            wait(20);
            compare(ids(wall.arrangedFull), saved, "screen recreation restores cells and gaps");
            for (var slot = 0; slot < wall.arrangedFull.length; ++slot)
                if (wall.arrangedFull[slot]) wall.removeFromCell(slot);
            wall.destroy();
            wait(0);
            wall = wallComponent.createObject(screen);
            wait(20);
            compare(wall.total, 0, "screen recreation does not refill an explicitly empty view");
            wall.resetArrangement();
            compare(wall.total, 31);
            verify(!Settings.hasLiveCells("street"));
            compare(members(), ids(roster.page("street", "", "alpha", 1, 40)));
        }

        function test_groupViewsStayIndependent() {
            wall.removeFromCell(1);
            wall.assignToCell(34, "c40");
            var street = Settings.liveCells("street");
            wall.groupId = "inside";
            compare(wall.total, 9);
            wall.removeFromCell(0);
            compare(wall.total, 8);
            wall.groupId = "street";
            compare(ids(wall.arrangedFull), street);
            compare(wall.total, 31);
        }

        function test_syncRetainsExistingCameraDelegateIdentity() {
            wall.removeFromCell(1);
            wall.assignToCell(34, "c40");
            wait(20);
            var before = findChild(wall, "fixtureCamera_c01");
            var outside = findChild(wall, "fixtureCamera_c40");
            verify(before !== null && outside !== null);
            for (var i = 0; i < 12; ++i) {
                wall.syncGrid(JSON.parse(JSON.stringify(wall.pagedCameras)));
                compare(findChild(wall, "fixtureCamera_c01"), before);
                compare(findChild(wall, "fixtureCamera_c40"), outside);
            }
            wall.assignToCell(0, "c40");
            wait(20);
            compare(findChild(wall, "fixtureCamera_c01"), before, "swap moves the existing delegate");
            compare(findChild(wall, "fixtureCamera_c40"), outside, "swap preserves the outside-group delegate");
            assertUnique();
        }
    }
}
