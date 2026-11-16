import QtQuick
import QtQuick.Window
import QtTest
import Watchtower

Item {
    id: scene
    width: 1280; height: 960

    QtObject {
        id: roster
        property var cameras: []
        property var wire: ({})
        property int healthRev: 0
        property bool backendEvidenceFresh: true
        property int total: cameras.length
        property int onlineCount: cameras.length
        property int offlineCount: 0
        property int degradedCount: 0
        property int notRecordingCount: 0
        property int archiveDelayedCount: 0
        property int recUnknownCount: 0
        property int archiveUnknownCount: 0
        property int recordingGapCount: 0
        signal countsChanged()
        function page(group, filter, sort, number, size) {
            return cameras.filter(function(cam) {
                return filter !== "offline" || cam.live === CameraStatus.Offline;
            }).map(function(cam) { return JSON.parse(JSON.stringify(cam)); });
        }
        function cameraByBackendId(id) {
            for (var i = 0; i < cameras.length; ++i)
                if (cameras[i].camId === id) return JSON.parse(JSON.stringify(cameras[i]));
            return ({});
        }
        function recordingHealthFor(id) {
            return healthNormalizer.normalize(wire[id] || ({}), Date.now());
        }
        function publish(cams, observations) {
            cameras = cams; wire = observations; ++healthRev; countsChanged();
        }
    }

    TestCase {
        id: test
        name: "RecordingIdleDisplay"
        when: windowShown
        property var objects: []
        property double fixtureNow: Date.now()

        function initTestCase() {
            verify(scene.Window.window !== null);
            scene.Window.window.width = 1280;
            scene.Window.window.height = 960;
            tryCompare(scene.Window.window, "width", 1280);
            tryCompare(scene.Window.window, "height", 960);
        }
        function init() { fixtureNow = Date.now(); }

        function createProduct(name, values) {
            var component = Qt.createComponent(productQmlDirectory + name + ".qml");
            compare(component.status, Component.Ready, component.errorString());
            var object = component.createObject(scene, values || ({}));
            verify(object !== null, component.errorString());
            objects.push(object);
            return object;
        }
        function observation(capture, archive, expired) {
            var now = Date.now();
            var observed = new Date(now - (expired ? 60000 : 1000)).toISOString();
            var until = new Date(now + (expired ? -1000 : 30000)).toISOString();
            var lane = { expected: true, observed_at: observed, valid_until: until,
                capture_state: capture, archive_state: archive, archive_delay_s: 180 };
            return { version: 1, observed_at: observed, valid_until: until,
                capture_state: capture, archive_state: archive,
                streams: { main: lane, sub: lane } };
        }
        function camera(id, name, state) {
            return {camId:id, name:name, groupName:"Fixture", live:CameraStatus.Live,
                recording:state, lastSeen:"", lastSegmentAt:new Date(fixtureNow - 1000).toISOString(), motionKnown:true,
                motionReady:true, motionConfirmed:true, motionLastVmdAt:"", pattern:0};
        }
        function screen() {
            return createProduct("HealthScreen", {cameraModel:roster, width:1280, height:960});
        }
        function cleanup() {
            for (var i = objects.length - 1; i >= 0; --i) objects[i].destroy();
            objects = []; roster.publish([], ({})); wait(20);
        }

        function test_idle_precedes_legacy_data() {
            return [
                {tag:"recording_idle", legacy:CameraStatus.Recording, archive:"idle"},
                {tag:"stalled_idle", legacy:CameraStatus.Stalled, archive:"idle"},
                {tag:"recording_current", legacy:CameraStatus.Recording, archive:"current"},
                {tag:"stalled_current", legacy:CameraStatus.Stalled, archive:"current"},
                {tag:"disabled_idle", legacy:CameraStatus.Disabled, archive:"idle"}
            ];
        }
        function test_idle_precedes_legacy(data) {
            var health = healthNormalizer.normalize(observation("idle", data.archive), Date.now());
            var badge = createProduct("RecordingStatusBadge", {state:data.legacy, health:health,
                lastSegmentAtMs:fixtureNow - 1000});
            compare(health.capture_state, "idle"); verify(health.fresh);
            compare(badge.label, "ARMED"); verify(!badge.issueVisible);
        }
        function test_fresh_faults_stay_visible_data() {
            return [
                {tag:"stopped", capture:"stopped", archive:"current", legacy:CameraStatus.Armed, label:"REC STOPPED"},
                {tag:"delayed_idle", capture:"idle", archive:"delayed", legacy:CameraStatus.Recording, label:"ARCHIVE DELAY"},
                {tag:"unavailable", capture:"progressing", archive:"unavailable", legacy:CameraStatus.Armed, label:"ARCHIVE DELAY"},
                {tag:"unknown_armed", capture:"unknown", archive:"current", legacy:CameraStatus.Armed, label:"REC ?"},
                {tag:"unknown_disabled", capture:"unknown", archive:"current", legacy:CameraStatus.Disabled, label:"REC ?"}
            ];
        }
        function test_fresh_faults_stay_visible(data) {
            var health = healthNormalizer.normalize(observation(data.capture, data.archive), Date.now());
            var badge = createProduct("RecordingStatusBadge", {state:data.legacy, health:health});
            compare(badge.label, data.label); verify(badge.issueVisible);
        }
        function test_expired_idle_is_not_reused() {
            var health = healthNormalizer.normalize(observation("idle", "idle", true), Date.now());
            var badge = createProduct("RecordingStatusBadge", {state:CameraStatus.Recording, health:health});
            compare(health.capture_state, "unknown"); verify(!health.fresh);
            compare(badge.label, "REC ?"); verify(badge.issueVisible);
        }
        function test_motion_and_archive_uncertainty_are_preserved() {
            var idle = healthNormalizer.normalize(observation("idle", "idle"), Date.now());
            var badge = createProduct("RecordingStatusBadge", {state:CameraStatus.Recording,
                health:idle, motionKnown:true, motionReady:false});
            compare(badge.label, "ARMED · NOT READY");
            compare(badge.fg, Theme.bad);
            badge.motionReady = true;
            badge.health = healthNormalizer.normalize(observation("idle", "unknown"), Date.now());
            verify(badge.issueVisible); compare(badge.issueText, "Archive status unknown");
        }
        function test_idle_keeps_motion_age_and_density() {
            var health = healthNormalizer.normalize(observation("idle", "idle"), Date.now());
            var badge = createProduct("RecordingStatusBadge", {state:CameraStatus.Recording,
                health:health, lastMotionAtMs:fixtureNow - 120000, lastSegmentAtMs:fixtureNow - 1000});
            compare(badge.label, "ARMED · 2m"); compare(badge.fg, Theme.ink2);
            badge.tier = 1; compare(badge.label, "ARMED");
            badge.motionKnown = true; badge.motionReady = false;
            compare(badge.label, "ARMED · NOT READY"); compare(badge.fg, Theme.bad);
        }
        function test_idle_keeps_silence_information_without_legacy_archive_fault() {
            var health = healthNormalizer.normalize(observation("idle", "idle"), Date.now());
            var badge = createProduct("RecordingStatusBadge", {state:CameraStatus.Stalled,
                health:health, lastSegmentAtMs:fixtureNow - 86401000});
            compare(badge.label, "ARMED · silent 1d"); compare(badge.fg, Theme.warn);
            badge.lastMotionAtMs = fixtureNow - 120000; badge.lastVmdAtMs = fixtureNow - 1000;
            compare(badge.label, "ARMED · 2m"); verify(!badge._notRecording);
            badge.health = healthNormalizer.normalize(observation("idle", "delayed"), Date.now());
            compare(badge.label, "ARCHIVE DELAY"); verify(badge.issueVisible);
        }
        function test_selected_camera_refreshes_by_id() {
            roster.publish([camera("a", "Original", CameraStatus.Stalled)], {a:observation("unknown", "delayed")});
            var view = screen(); view.sel = view.rows[0];
            roster.publish([camera("a", "Renamed", CameraStatus.Recording)], {a:observation("idle", "idle")});
            compare(view.sel.camId, "a"); compare(view.sel.name, "Renamed");
            compare(view.sel.recording, CameraStatus.Recording);
            compare(view.recText(view.sel), "Motion armed"); compare(view.archiveText(view.sel), "Idle");
        }
        function test_selected_map_refreshes_when_row_signature_unchanged() {
            var a = camera("a", "Same", CameraStatus.Recording); a.model = "old";
            roster.publish([a], {a:observation("idle", "idle")});
            var view = screen(); view.sel = view.rows[0];
            var next = camera("a", "Same", CameraStatus.Recording); next.model = "current";
            roster.publish([next], {a:observation("idle", "idle")});
            compare(view.sel.model, "current");
        }
        function test_removed_camera_is_not_replaced_by_same_name() {
            roster.publish([camera("a", "Shared name", CameraStatus.Recording)], {a:observation("idle", "idle")});
            var view = screen(); view.sel = view.rows[0];
            roster.publish([camera("b", "Shared name", CameraStatus.Recording)], {b:observation("idle", "idle")});
            compare(view.sel, null);
        }
        function test_selected_identity_is_not_filter_membership() {
            roster.publish([camera("a", "Selected", CameraStatus.Recording)], {a:observation("idle", "idle")});
            var view = screen(); view.sel = view.rows[0]; view.activeFilter = "offline";
            compare(view.rows.length, 0); compare(view.sel.camId, "a");
            view.sel = camera("", "Selected", CameraStatus.Recording); roster.healthRev++;
            compare(view.sel, null);
        }
        function test_missing_model_clears_selection() {
            roster.publish([camera("a", "Selected", CameraStatus.Recording)], {a:observation("idle", "idle")});
            var view = screen(); view.sel = view.rows[0]; view.cameraModel = null;
            compare(view.sel, null); compare(view.rows.length, 0);
        }
        function test_visual_idle_selection() {
            roster.publish([camera("a", "Idle motion camera", CameraStatus.Stalled)], {a:observation("idle", "idle")});
            var view = screen(); view.sel = view.rows[0];
            verify(waitForPolish(view, 5000));
            verify(waitForRendering(view, 5000));
            wait(100);
            var done = false, saved = false;
            verify(scene.grabToImage(function(image) {
                saved = image.saveToFile(outputDirectory + "/health-idle.png"); done = true;
            }));
            tryVerify(function() { return done; }); verify(saved);
        }
    }
}
