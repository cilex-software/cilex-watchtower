// Shipping shell/model/widgets against run-ui.py's isolated loopback fixture.
import QtQuick
import Watchtower
import "qrc:/qt/qml/Watchtower/qml" as Product

Product.Main {
    id: test
    width: 1440; height: 960
    property var model: null
    property int phase: 0
    property int checks: 0
    property int failures: 0
    property double expiryEntered: 0
    property string output: ""
    property bool captured: false
    property bool busy: false
    function snapshot(name, nextPhase) {
        busy=true;
        contentItem.grabToImage(function(img) {
            test.check(img.saveToFile(test.output+"/"+name+".png"),"save shipping "+name+" UI");
            if(nextPhase===4) test.goToSection("health");
            if(nextPhase===5) test.goToSection("groups");
            if(nextPhase===6) test.goToSection("live");
            test.busy=false;test.phase=nextPhase;
        });
    }
    function findAll(root, name) {
        var seen=[],result=[];
        function visit(item) {
            if (!item || seen.indexOf(item)>=0) return;
            seen.push(item);
            if (String(item).indexOf(name + "_QML")===0) result.push(item);
            var lists=[item.children||[],item.data||[]];
            for(var l=0;l<lists.length;++l) for(var i=0;i<lists[l].length;++i) visit(lists[l][i]);
        }
        visit(root); return result;
    }
    function check(ok, description, value) {
        ++checks; if(!ok) ++failures;
        console.log("[RECORDING-HEALTH-CHECK] " + JSON.stringify({ok:!!ok,check:description,value:value===undefined?null:value}));
    }
    function next(name) {
        var request=new XMLHttpRequest(); request.open("POST",AuthController.baseUrl+"/fixture/"+name);
        request.onreadystatechange=function(){ if(request.readyState===XMLHttpRequest.DONE) model.refresh(); };
        request.send("{}");
    }
    function finish() {
        pulse.stop();watchdog.stop();
        console.log("[RECORDING-HEALTH-SUMMARY] "+JSON.stringify({checks:checks,failures:failures,
            shipping_model:true,shipping_widgets_exercised:phase>=2,
            language:typeof Language!=="undefined"?Language.language:"not measured",production_connections:false,real_video_verified:false}));
        Qt.exit(failures?1:0);
    }
    Timer {
        id: pulse; interval: 150; repeat: true; running: true
        onTriggered: {
            if(test.busy) return;
            try {
                if(phase===0) {
                    if(!AuthController.authenticated) return;
                    var walls=test.findAll(test.contentItem,"LiveMonitor");
                    if(!walls.length) return;
                    test.model=walls[0].cameraModel;
                    if(!test.model || test.model.total!==1) return;
                    var args=Qt.application.arguments;
                    for(var a=0;a<args.length;++a) if(args[a].indexOf("--health-output=")===0) test.output=args[a].slice(16);
                    test.width = 1280;
                    test.check(test.model.notRecordingCount===0,
                        "REGRESSION: legacy catalogue stalled is not a confirmed capture stop",test.model.notRecordingCount);
                    if(typeof test.model.recordingHealthFor!=="function") {
                        test.check(false,"additive recording-health accessor absent");test.finish();return;
                    }
                    test.check(test.model.archiveDelayedCount===1,"legacy fault remains visible as archive delayed",test.model.archiveDelayedCount);
                    test.check(test.model.recUnknownCount===1,"legacy capture remains explicitly unknown",test.model.recUnknownCount);
                    test.next("all");test.phase=1;
                } else if(phase===1) {
                    if(test.model.total!==10) return;
                    test.check(test.model.notRecordingCount===2,"confirmed capture failures count cameras once",test.model.notRecordingCount);
                    test.check(test.model.archiveDelayedCount===2,"archive faults counted independently",test.model.archiveDelayedCount);
                    test.check(test.model.recUnknownCount===4,"unknown capture visible in fleet count",test.model.recUnknownCount);
                    test.check(test.model.archiveUnknownCount===4,"archive-only unknown remains visible",test.model.archiveUnknownCount);
                    test.check(test.model.recordingHealthUnknownCount===5,"fleet unknown deduplicates capture and archive dimensions",test.model.recordingHealthUnknownCount);
                    test.check(test.model.countFiltered("","healthunknown")===5,"unknown filter includes archive-only unknown");
                    test.check(test.model.countFiltered("","notrec")===2,"NOT REC filter agrees with counter");
                    test.check(test.model.countFiltered("","archive")===2,"archive filter agrees with counter");
                    test.check(test.model.countFiltered("","recunknown")===4,"unknown filter agrees with counter");
                    test.check(test.model.recordingHealthFor("masked").capture_state==="stopped","healthy sub does not mask main capture failure");
                    test.check(test.model.recordingHealthFor("stale").capture_state==="unknown","stale main invalidates optimistic aggregate");
                    test.check(test.model.recordingHealthFor("motion").capture_state==="idle","motion idle is not capture failure");
                    test.check(test.model.recordingHealthFor("disabled").capture_state==="disabled","disabled is not unknown or failure");
                    test.check(test.model.offlineCount===1,"offline is independent of recent catalogue data");
                    var tiles=test.findAll(test.contentItem,"CameraTile"), delayed=null,stopped=null;
                    for(var i=0;i<tiles.length;++i) {
                        if(tiles[i].camId==="delayed") delayed=tiles[i];
                        if(tiles[i].camId==="stopped") stopped=tiles[i];
                    }
                    if(!delayed || !stopped) return;
                    var db=test.findAll(delayed,"RecordingStatusBadge")[0];
                    var sb=test.findAll(stopped,"RecordingStatusBadge")[0];
                    test.check(db.captureProgressing && db.archiveDelayed && !db.captureStopped,
                        "shipping badge distinguishes local progress from archive delay",db.issueText);
                    test.check(sb.captureStopped && !sb.archiveDelayed,"shipping badge distinguishes actual capture stop",sb.issueText);
                    test.check(db.sinceMs===-1 && sb.sinceMs===-1,"no catalogue timestamp invented as incident onset");
                    test.check(db.issueText.indexOf("since")<0,"archive message has no false since timestamp",db.issueText);
                    test.snapshot("fleet",4);
                } else if(phase===4) {
                    var healthScreens=test.findAll(test.contentItem,"HealthScreen");
                    if(!healthScreens.length || !healthScreens[0].visible) return;
                    healthScreens[0].sel=test.model.cameraByBackendId("delayed");
                    test.check(healthScreens[0].rows.length===10,"shipping Health screen retains full cohort");
                    test.snapshot("health",5);
                } else if(phase===5) {
                    var groups=test.findAll(test.contentItem,"CameraGroups");
                    if(!groups.length || !groups[0].visible) return;
                    test.check(groups[0].nNotRec===2,"Groups confirmed-capture count agrees with fleet",groups[0].nNotRec);
                    test.check(groups[0].nFaults===4,"Groups preserves archive and capture faults",groups[0].nFaults);
                    test.snapshot("groups",6);
                } else if(phase===6) {
                    test.next("expiry");test.phase=2;
                } else if(phase===2) {
                    if(test.model.total!==1 || !test.model.cameraByBackendId("expiry").camId) return;
                    test.check(test.model.recordingCount===1,"fresh progress accepted before expiry");
                    test.expiryEntered=Date.now();test.phase=3;
                    test.next("unavailable");
                } else if(phase===3) {
                    if(Date.now()-test.expiryEntered<3500) return;
                    test.check(test.model.recordingCount===0 && test.model.recUnknownCount===1,
                        "expired progress becomes unknown while HTTP refresh fails",test.model.recUnknownCount);
                    test.check(test.model.archiveDelayedCount===0 && test.model.archiveUnknownCount===1,
                        "unavailable health transport is not a fabricated archive/capture failure");
                    test.check(test.model.recordingHealthFor("expiry").capture_state==="unknown","no stale capture proof retained");
                    var healthScreens=test.findAll(test.contentItem,"HealthScreen");
                    test.check(healthScreens.length===1 && healthScreens[0].backendStatusStale===true,
                        "Health labels retained camera statuses as last known when Vision updates fail");
                    test.finish();
                }
            } catch(error) {
                test.check(false,"unexpected harness exception",String(error));test.finish();
            }
        }
    }
    Timer { id: watchdog; interval: 35000; running:true; onTriggered:{test.check(false,"fixture timeout",test.phase);test.finish();} }
}
