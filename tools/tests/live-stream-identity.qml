// Isolated integration regression: use WT_DEMO=1, WT_NO_SCHEME_REG=1,
// WT_TEST_QML=<this file>, WT_RTSP_TCP=1, and isolated XDG directories.
// Start tools/tests/live-stream-identity/rtsp_fixture.py first. Arguments:
// --identity-output=<existing directory> --identity-port=18554
// The roster and authenticated-shell visibility are fixtures. Navigation,
// tab state, wall tiles, detail views, decoders and rendering are shipping code.
// PNG identities must also pass verify_qml_captures.py; QML exit 0 alone does
// not establish that the pixels belong to the selected camera.
import QtQuick
import Watchtower
import "qrc:/qt/qml/Watchtower/qml" as Product

Product.Main {
    id: harness
    width: 1280
    height: 900
    property var wall: null
    property var detail: null
    property var cameras: []
    property int failures: 0
    property int checks: 0
    property int phase: -1
    property double enteredAt: 0
    property bool capturing: false
    property int savedShots: 0
    property string output: argument("--identity-output=", "")
    property int fixturePort: Number(argument("--identity-port=", "18554"))
    property var legs: [
        {kind:"wall",name:"01-initial-wall"},
        {kind:"open",camera:0,name:"02-open-red"},
        {kind:"wall",name:"03-wall-after-red"},
        {kind:"open",camera:1,name:"04-open-green"},
        {kind:"tab",camera:0,name:"05-return-red-after-green"},
        {kind:"wall",name:"06-wall-after-green"},
        {kind:"open",camera:2,name:"07-open-blue"},
        {kind:"tab",camera:1,name:"08-return-green-after-blue"},
        {kind:"tab",camera:0,name:"09-return-red-after-blue"},
        {kind:"wall",name:"10-final-wall"}
    ]

    QtObject {
        id: fixtureModel
        property int total: harness.cameras.length
        property int stateRev: 0
        property bool recordingEnabled: true
        property bool liveViewEnabled: true
        property bool loading: false
        property bool listUnavailable: false
        function page(group, filter, sort, pageNumber, pageSize) {
            return harness.cameras.slice((pageNumber - 1) * pageSize, pageNumber * pageSize);
        }
        function countFiltered(group, filter) { return total; }
        function groupList() { return [{id:"fixture",name:"Synthetic streams",total:total}]; }
        function cameraByBackendId(id) {
            for (var i=0;i<harness.cameras.length;++i)
                if (harness.cameras[i].camId === id) return harness.cameras[i];
            return {};
        }
        function liveSinceMs(id) { return -1; }
        function recSinceMs(id) { return -1; }
        function setRecentCameras(ids) {}
    }

    function argument(prefix, fallback) {
        var args = Qt.application.arguments;
        for (var i=0;i<args.length;++i)
            if (args[i].indexOf(prefix) === 0) return args[i].slice(prefix.length);
        return fallback;
    }
    function descendants(root, predicate) {
        var found=[], seen=[];
        function walk(node) {
            if (!node || seen.indexOf(node) >= 0) return;
            seen.push(node);
            if (predicate(node)) found.push(node);
            var lists=[node.children || [],node.data || []];
            for (var l=0;l<lists.length;++l)
                for (var i=0;i<lists[l].length;++i) walk(lists[l][i]);
        }
        walk(root);
        return found;
    }
    function component(root, name) {
        var matches=descendants(root,function(item) {
            return String(item).indexOf(name + "_QML") === 0;
        });
        return matches.length ? matches[0] : null;
    }
    function check(ok, name, detailValue) {
        ++checks;
        if (!ok) ++failures;
        console.log("[LIVE-IDENTITY-CHECK] " + JSON.stringify({
            ok:!!ok,name:name,detail:detailValue || null
        }));
    }
    function finish() {
        pulse.stop();
        watchdog.stop();
        console.log("[LIVE-IDENTITY-SUMMARY] " + JSON.stringify({
            checks:checks,failures:failures,saved_shots:savedShots,
            completed_legs:phase,expected_legs:legs.length,
            pixel_verification:"requires verify_qml_captures.py",
            fixture_roster:true,shipping_navigation:true
        }));
        Qt.exit(failures ? 1 : 0);
    }
    function initialize() {
        check(typeof wtDemo !== "undefined" && wtDemo,
              "demo roster required; no production roster",{});
        check(output.length > 0,"output directory supplied",{});
        if (failures) { finish(); return; }
        Settings.defaultStreamHd=false;
        Settings.maxLiveDecodes=3;
        var colors=["red","green","blue"], rows=[];
        for (var i=0;i<colors.length;++i) {
            var url="rtsp://127.0.0.1:" + fixturePort + "/" + colors[i];
            rows.push({camId:"fixture-"+colors[i],name:"Fixture " + colors[i],
                ip:"127.0.0."+(i+1),mac:"fixture-"+colors[i],
                groupId:"fixture",groupName:"Synthetic streams",model:"",favorite:false,
                live:CameraStatus.Live,recording:CameraStatus.Recording,
                timestamp:"",lastSeen:"",lastSegmentAt:"",pattern:0,
                rtspUrl:url,rtspSubUrl:url,snapshotUrl:"",hasAudio:false});
        }
        cameras=rows;
        wall=component(contentItem,"LiveMonitor");
        detail=component(contentItem,"SingleCameraDetail");
        var login=component(contentItem,"LoginScreen");
        check(wall !== null && detail !== null && login !== null,
              "shipping wall/detail/login components located",{});
        if (failures) { finish(); return; }
        wall.cameraModel=fixtureModel;
        detail.cameraModel=fixtureModel;
        // This test is about live-camera ownership; do not authenticate or fetch
        // production cameras. Override only the top shell visibility in this
        // disposable test instance. Preserve wall/detail visibility bindings.
        var ancestor=wall.parent;
        while (ancestor && ancestor !== contentItem) {
            ancestor.visible=true;
            ancestor=ancestor.parent;
        }
        login.visible=false;
        gridLayout="4";
        sortMode="default";
        opsSidebarOpen=false;
        nextLeg();
    }
    function nextLeg() {
        ++phase;
        if (phase >= legs.length) { finish(); return; }
        var leg=legs[phase];
        if (leg.kind === "wall") activateTab(0);
        else if (leg.kind === "open") wall.cameraOpenedNewTab(cameras[leg.camera]);
        else activateTab(leg.camera+1);
        enteredAt=Date.now();
        console.log("[LIVE-IDENTITY-LEG] " + JSON.stringify(leg));
    }
    function surfaces(root) {
        return descendants(root,function(item) {
            return typeof item._hasRecentFrame !== "undefined"
                && typeof item.tiers !== "undefined" && item.active && item.visible;
        });
    }
    function targetsForLeg() {
        var leg=legs[phase], targets=[];
        if (leg.kind === "wall") {
            var tiles=descendants(wall,function(item) {
                return typeof item.camId === "string" && typeof item.streamPlaying !== "undefined";
            });
            for (var i=0;i<cameras.length;++i) {
                var tile=null;
                for (var j=0;j<tiles.length;++j)
                    if (tiles[j].camId === cameras[i].camId) tile=tiles[j];
                if (!tile || !tile.streamPlaying) return [];
                var hits=surfaces(tile);
                if (hits.length !== 1 || !hits[0].playing) return [];
                targets.push({surface:hits[0],camera:cameras[i]});
            }
        } else {
            var views=surfaces(detail);
            if (!detail.visible || views.length !== 1 || !views[0].playing) return [];
            targets.push({surface:views[0],camera:cameras[leg.camera]});
        }
        return targets;
    }
    function captureTargets(targets,index) {
        if (index >= targets.length) { capturing=false; nextLeg(); return; }
        var target=targets[index],leg=legs[phase];
        var filename=output+"/"+leg.name+"-"+target.camera.camId+".png";
        check(target.surface.url === target.camera.rtspSubUrl,
              leg.name+" selected URL",{expected:target.camera.rtspSubUrl,actual:target.surface.url});
        target.surface.grabToImage(function(result) {
            var saved=result.saveToFile(filename);
            check(saved,leg.name+" rendered pixels saved",{file:filename});
            if (saved) ++savedShots;
            console.log("[LIVE-IDENTITY-SHOT] " + JSON.stringify({
                file:filename,expected:target.camera.camId.slice("fixture-".length),
                leg:leg.name,camera_id:target.camera.camId,url:target.surface.url,
                width:target.surface.width,height:target.surface.height
            }));
            captureTargets(targets,index+1);
        });
    }
    Timer {
        id: pulse
        interval:100; repeat:true; running:true
        onTriggered: {
            try {
                if (harness.phase < 0) { harness.initialize(); return; }
                if (harness.capturing) return;
                var elapsed=Date.now()-harness.enteredAt;
                if (elapsed > 12000) {
                    harness.check(false,"leg produced no ready video within 12 seconds",harness.legs[harness.phase]);
                    harness.finish(); return;
                }
                if (elapsed < 700) return;
                var targets=harness.targetsForLeg();
                if (targets.length === 0) return;
                var leg=harness.legs[harness.phase];
                if (leg.kind !== "wall") {
                    harness.check(harness.focusedCamera.camId === harness.cameras[leg.camera].camId
                        && harness.activeTabLabel() === harness.cameras[leg.camera].name,
                        leg.name+" camera identity and title",{id:harness.focusedCamera.camId,title:harness.activeTabLabel()});
                }
                harness.capturing=true;
                harness.captureTargets(targets,0);
            } catch (error) {
                harness.check(false,"unexpected exception",String(error));
                harness.finish();
            }
        }
    }
    Timer {
        id: watchdog
        interval:100000; running:true
        onTriggered: { harness.check(false,"overall timeout",{}); harness.finish(); }
    }
}
