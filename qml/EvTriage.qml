import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic
import Watchtower

// VIEW 01 — TRIAGE QUEUE (port of view-triage.jsx / triage-queue-spec.md).
// 2-column: 384px priority list | fluid detail pane that plays the event clip
// inline, with the facts grid, per-type SOP checklist, disposition note, and the
// action bar. Reads EventsStore; mutates only via EventsStore.ack/bookmark/dispose.
Item {
    id: tri
    property string selId: ""                    // shared selection (owned by EventsArea)
    property var playbackClient: null            // real-mode inline playback (EvHeroPlayer)
    property bool active: false                   // Events screen visible → keyboard shortcuts live
    signal select(string id)
    signal exportClip(string camId, double startMs, double endMs, string purpose)   // bubbles to Main's export flow

    // move the selection up/down the sorted queue (keyboard ↑/↓)
    function _moveSel(d) {
        var l = tri._list; if (!l.length) return;
        var idx = 0;
        for (var i = 0; i < l.length; i++) if (tri._cur && l[i].id === tri._cur.id) { idx = i; break; }
        tri.select(l[Math.max(0, Math.min(l.length - 1, idx + d))].id);
    }
    // E acknowledge · ↑/↓ move selection · Space play/pause — only when the Events
    // screen is up and the disposition note isn't being typed in.
    Shortcut { sequence: "E"; enabled: tri.active && tri._cur && tri._cur.status === "new" && !noteIn.activeFocus
        onActivated: if (tri._cur) EventsStore.ack(tri._cur.id) }
    Shortcut { sequence: "Up"; enabled: tri.active && !noteIn.activeFocus; onActivated: tri._moveSel(-1) }
    Shortcut { sequence: "Down"; enabled: tri.active && !noteIn.activeFocus; onActivated: tri._moveSel(1) }
    Shortcut { sequence: "Space"; enabled: tri.active && !noteIn.activeFocus
        onActivated: if (heroLoader.item && heroLoader.item.toggle) heroLoader.item.toggle() }

    // ---- WT_HERO_TEST: random-event + scrubber-jump latency stress (inert unless wtHeroTest set) ----
    // Randomly select events (→ hero auto-opens via WT_HERO_AUTOPLAY; we time click→first-frame), then jump
    // +/-1s/10s/30s/1m/5m as the episode length allows, 100 iters/step, timing seek→first-rendered-frame.
    // The hero logs the precise [HT] latencies (frame-signal based); this state machine just sequences them.
    property var _htSteps: [1000, 10000, 30000, 60000, 300000]
    property var _htCount: ({})
    property int _htJumps: 0
    property int _htEvSeeks: 0
    property int _htWaits: 0
    property string _htState: "init"
    readonly property var _ht: heroLoader.item
    readonly property bool _htRun: (typeof wtHeroTest !== "undefined" && wtHeroTest === true) && tri.active && EventsStore.realMode
    readonly property bool _htOpenonly: (typeof wtHeroOpenonly !== "undefined" && wtHeroOpenonly === true)  // leak bisect: open events, no seeks
    // openonly per-open dwell in 30ms ticks (WT_HERO_SETTLE_MS, default 70≈2.1s) — raise to hold fewer opens
    // at equal playback time, discriminating open-driven vs playback-time-driven RSS growth.
    readonly property int _htSettleTicks: (typeof wtHeroSettleMs !== "undefined" && wtHeroSettleMs > 0) ? Math.max(1, Math.round(wtHeroSettleMs / 30)) : 70
    property int _htOpens: 0
    // ---- soak iteration-two state (2026-08-20 mac): per-clip seek budget + probes 3/5/6/8 ----
    property int _htSeekCapThis: 20        // marker mode: re-rolled 15–30 per clip (operator order, iteration two)
    property int _htSelCount: 0
    property bool _p3Done: false           // P3: one queue-integrity scan per app run
    property string _p5Ev: ""              // P5: deliberately-selected seconds-old event
    property double _p5T0: 0
    property int _p6Clip: 0                // P6: paused-seek staleness battery, every ~12th clip
    property int _p6F0: 0
    property double _p6Wall0: 0
    property double _p6Pos0: 0
    property int _p8Clip: 0                // P8: export-window announce, every ~10th clip
    Timer {
        interval: 30; repeat: true; running: tri._htRun
        onTriggered: tri._htTick()
    }
    function _htTick() {
        if (_htState === "init") {
            if (EventsStore.events.length === 0) return;        // wait for the real feed to load
            for (var i = 0; i < _htSteps.length; i++) _htCount[_htSteps[i]] = 0;
            console.log("[HT] BEGIN events=" + EventsStore.events.length + " t=" + Date.now());
            _htState = "sel"; return;
        }
        if (_htState === "sel") { _htSelect(); _htState = "waitopen"; _htWaits = 0; return; }
        if (_htState === "waitopen") {
            var ready = _htOpenonly ? (_ht && _ht._armed && !_ht._loading)             // openonly: session ready (no decode/frame needed)
                                    : (_ht && !_ht._htOpenPending && _ht.testFrames > 0 && _ht.testDurMs > 1500);
            if (ready) {
                if (_p5Ev !== "" && selId === _p5Ev) {     // P5: seconds-old event reached first frame
                    console.log("[P5] firstframe ev=" + _p5Ev + " ms=" + (Date.now() - _p5T0));
                    _p5Ev = "";
                }
                _htEvSeeks = 0; _htWaits = 0; _htState = "settle";
                // P8: every ~10th clip, announce the episode window for the external export prober
                if (typeof wtMarkerTest !== "undefined" && wtMarkerTest && (++_p8Clip % 10 === 0)
                        && _ht && _ht.ev && _ht.ev.cam)
                    console.log("[P8] ev=" + selId + " cam=" + _ht.ev.cam.id
                                + " s=" + new Date(_ht.testTlStartMs).toISOString()
                                + " e=" + new Date(_ht.testTlEndMs).toISOString());
            }
            else {
                ++_htWaits;
                if (_p5Ev !== "" && selId === _p5Ev && _ht && _ht.testError !== "" && _htWaits % 100 === 0)
                    console.log("[P5] state ev=" + _p5Ev + " tMs=" + (Date.now() - _p5T0) + " err=\"" + _ht.testError + "\"");
                // P5 picks get 60 s — the probe's datum IS time-to-first-frame on an
                // in-progress recording; 15 s only proves the driver's impatience.
                var lim = (_p5Ev !== "" && selId === _p5Ev) ? 2000 : 500;
                if (_htWaits > lim) {                      // 15s (60s for P5)
                    if (_p5Ev !== "" && selId === _p5Ev) { // P5: never lit within the driver's patience
                        console.log("[P5] timeout ev=" + _p5Ev + " ms=" + (Date.now() - _p5T0)
                                    + " err=\"" + (_ht ? _ht.testError : "?") + "\"");
                        _p5Ev = "";
                    }
                    console.log("[HT] OPEN TIMEOUT t=" + Date.now()); _htState = "sel";
                }
            }
            return;
        }
        if (_htState === "settle") {                    // let the player play + buffer ahead before seeking
            // Marker-soak mode (WT_MARKER_TEST): play the WHOLE window through at 2x so
            // MotionScan covers head AND tail (the [MKT] verdict fires from the hero);
            // move on when the hero marks the scan complete or a window-sized timeout lapses.
            if (typeof wtMarkerTest !== "undefined" && wtMarkerTest) {
                if (_ht && _ht._speed !== 2) _ht._speed = 2;   // playbackRate binds to _speed; _open() resets to 1
                var winTicks = _ht ? Math.round(((_ht.tlEndMs - _ht.tlStartMs) / 2 + 12000) / 30) : 700;
                if ((_ht && _ht._mktDone) || ++_htWaits >= Math.max(200, winTicks)) {
                    _htWaits = 0; _htState = "seek";
                }
                return;
            }
            if (++_htWaits >= _htSettleTicks) {          // dwell (default ~2.1s; WT_HERO_SETTLE_MS)
                _htWaits = 0;
                if (_htOpenonly) { _htOpens++; if (_htOpens % 20 === 0) console.log("[HT] OPENONLY opens=" + _htOpens + " t=" + Date.now()); _htState = "sel"; }
                else _htState = "seek";
            }
            return;
        }
        if (_htState === "seek") {
            if (_htDone()) { console.log("[HT] DONE jumps=" + _htJumps + _htSummary() + " t=" + Date.now()); Qt.quit(); return; }
            // Iteration two (operator order): marker mode's battery back to first-iteration
            // strength — a random 15–30 per clip, re-rolled in _htSelect (was 5; supersedes
            // 8721a4c's deterministic per-event variant, same operator order both sides).
            var seekCap = (typeof wtMarkerTest !== "undefined" && wtMarkerTest) ? _htSeekCapThis : 20;
            if (_htEvSeeks >= seekCap) {                                  // battery done for this clip
                // P6: every ~12th clip, run the paused-seek staleness probe before moving on
                if (typeof wtMarkerTest !== "undefined" && wtMarkerTest
                        && (++_p6Clip % 12 === 0) && _ht && !_ht.testLoading && _ht.testFrames > 0) {
                    _ht.testPause(); _htState = "p6pause"; _htWaits = 0; return;
                }
                _htState = "sel"; return;                                 // periodically re-open for fresh events too
            }
            var step = _htPickStep();
            if (step <= 0) { _htState = "sel"; return; }
            _ht.testSeek((Math.random() < 0.5 ? 1 : -1) * step);
            _htCount[step] = (_htCount[step] || 0) + 1; _htJumps++; _htEvSeeks++;
            _htState = "waitseek"; _htWaits = 0; return;
        }
        if (_htState === "waitseek") {
            if (_ht && !_ht._htSeekPending) { _htState = "seek"; _htWaits = 0; }       // rendered → next seek same episode
            else if (++_htWaits > 300) {                                               // ~9s with no frame = frozen (tolerates cold-base + the 6s last-resort watchdog)
                console.log("[HT] SEEK TIMEOUT req=" + (_ht ? _ht._htSeekReq : 0) + " t=" + Date.now());
                if (_ht) _ht._htSeekPending = false;
                _htState = "sel"; _htWaits = 0;                                        // a frozen seek sticks the episode → re-open
            }
            return;
        }
        // ---- P6 (paused-seek staleness, open item E12): pause, click elsewhere on the
        // scrubber via the USER's code path, and demand the PICTURE moved with the playhead.
        // testFrames is the rendered-frame counter — unchanged after 1.2 s = stale frame.
        if (_htState === "p6pause") {
            if (!_ht) { _htState = "sel"; return; }
            if (++_htWaits < 24) return;                                               // ~0.7s: let the pause take
            _p6F0 = _ht.testFrames; _p6Wall0 = _ht.testWallMs; _p6Pos0 = _ht.testPosMs;
            var lo = _ht.testTlStartMs + 2000, hi = _ht.testTlEndMs - 2000;
            var d = (8000 + Math.random() * 12000) * (Math.random() < 0.5 ? -1 : 1);
            var tgt = _p6Wall0 + d;
            if (tgt < lo || tgt > hi) tgt = _p6Wall0 - d;
            _ht.testSeekPausedWall(Math.max(lo, Math.min(hi, tgt)));
            _htState = "p6wait"; _htWaits = 0; return;
        }
        if (_htState === "p6wait") {
            if (!_ht) { _htState = "sel"; return; }
            if (++_htWaits < 40) return;                                               // ~1.2s after the paused click
            var f1 = _ht.testFrames;
            var stale = (f1 === _p6F0);
            var wallMoved = Math.abs(_ht.testWallMs - _p6Wall0) > 1000;
            var posMoved = Math.abs(_ht.testPosMs - _p6Pos0) > 1000;
            console.log("[P6] ev=" + selId + " f0=" + _p6F0 + " f1=" + f1
                        + " wall0=" + Math.round(_p6Wall0) + " wall1=" + Math.round(_ht.testWallMs)
                        + " pos0=" + Math.round(_p6Pos0) + " pos1=" + Math.round(_ht.testPosMs)
                        + " paused=" + _ht.testPaused + " loading=" + _ht.testLoading
                        + " stale=" + stale + " wallMoved=" + wallMoved + " posMoved=" + posMoved);
            // evidence shot whenever ANY leg is suspicious: no new frame, or the media
            // position / displayed playhead failed to move after a landed paused click
            if (stale || !wallMoved || !posMoved)
                _ht.testShotVideo("scratchpad/soak-mac/shots/p6-" + selId + "-suspect.png");
            _ht.testResume();
            _htState = "sel"; _htWaits = 0; return;
        }
    }
    function _htSelect() {
        if (_htOpenonly) {                                  // leak bisect: just open a fresh event (≠ current), no seeks
            var es = EventsStore.events.filter(function (e) { return e.cam && e.cam.id && e.durationSec >= 2 && e.id !== tri.selId; });
            if (es.length) tri.select(es[Math.floor(Math.random() * es.length)].id);
            return;
        }
        _htSeekCapThis = 15 + Math.floor(Math.random() * 16);   // iteration two: random 15–30 per clip
        _htSelCount++;
        if (!_p3Done && EventsStore.events.length > 0) { _p3Scan(); _p3Done = true; }
        // P5: every ~15th selection, deliberately take a seconds-old event if one exists —
        // expect "Recording in progress…" with bounded retries, never an instant "No footage".
        if (typeof wtMarkerTest !== "undefined" && wtMarkerTest && _htSelCount % 15 === 0) {
            var fresh = EventsStore.events.filter(function (e) {
                return e.cam && e.cam.id && e.ts && (Date.now() - e.ts.getTime()) < 120000; });
            if (fresh.length) {
                fresh.sort(function (a, b) { return b.ts.getTime() - a.ts.getTime(); });
                _p5Ev = fresh[0].id; _p5T0 = Date.now();
                console.log("[P5] pick ev=" + _p5Ev + " ageS="
                            + Math.round((Date.now() - fresh[0].ts.getTime()) / 1000));
                tri.select(_p5Ev);
                return;
            }
            console.log("[P5] none-available t=" + Date.now());
        }
        var need = _htSteps.filter(function (s) { return (_htCount[s] || 0) < 100; });
        var want = need.length ? need[Math.floor(Math.random() * need.length)] : _htSteps[Math.floor(Math.random() * _htSteps.length)];
        var evs = EventsStore.events.filter(function (e) { return e.cam && e.cam.id && (e.durationSec * 1000) >= (want + 4000); });
        if (!evs.length) evs = EventsStore.events.filter(function (e) { return e.cam && e.cam.id && e.durationSec >= 2; });
        if (evs.length) tri.select(evs[Math.floor(Math.random() * evs.length)].id);
    }
    // P3 (recording_id resilience): one queue-integrity scan per app run — zero-duration
    // rows, recordingId-less rows, and same-camera rows closer than 1.5 s (duplicate
    // started/ended rows would betray a proximity-pairing regression, v1.1.125).
    function _p3Scan() {
        var evs = EventsStore.events;
        var dur0 = 0, noRec = 0, byCam = {};
        for (var i = 0; i < evs.length; i++) {
            var e = evs[i];
            if (!(e.durationSec > 0)) dur0++;
            if (!e.recordingId) noRec++;
            var c = e.cam && e.cam.id ? e.cam.id : "?";
            if (!byCam[c]) byCam[c] = [];
            byCam[c].push(e.ts ? e.ts.getTime() : 0);
        }
        var dup = 0;
        for (var c2 in byCam) {
            var ts = byCam[c2]; ts.sort(function (a, b) { return a - b; });
            for (var j = 1; j < ts.length; j++) if (ts[j] - ts[j - 1] < 1500) dup++;
        }
        console.log("[P3] rows=" + evs.length + " dur0=" + dur0 + " noRec=" + noRec + " dupPairs=" + dup);
    }
    function _htPickStep() {
        var dur = _ht ? _ht.testDurMs : 0;
        var feas = _htSteps.filter(function (s) { return (s + 4000) <= dur && (_htCount[s] || 0) < 100; });
        if (!feas.length) feas = _htSteps.filter(function (s) { return (s + 4000) <= dur; });
        if (!feas.length) return -1;
        feas.sort(function (a, b) { return (_htCount[a] || 0) - (_htCount[b] || 0); });
        return feas[0];
    }
    function _htDone() {
        if (_htJumps >= 360) return true;                       // hard cap (frozen seeks force a slow re-open each)
        if (_htJumps < 300) return false;
        for (var i = 0; i < _htSteps.length; i++) if ((_htCount[_htSteps[i]] || 0) < 100) return false;
        return true;
    }
    function _htSummary() { var s = ""; for (var i = 0; i < _htSteps.length; i++) s += " " + (_htSteps[i] / 1000) + "s=" + (_htCount[_htSteps[i]] || 0); return s; }

    property string filter: "open"               // open | critical | all
    property string note: ""
    property var done: ({})                       // local SOP ticks, reset per event

    // ===================== variant B "Lanes" state =====================
    // designs/handoff-camera-filter/2026-08-06-triage-camera-filter-variant-b-lanes.md
    property var solo: []                         // camera KEYS (stable ids), in solo order
    // Server-side scope for a single soloed lane (operator, 2026-08-17: ".189 shows none
    // while the server holds 243"): the loaded feed is only the newest ~page fleet-wide,
    // so a camera quiet for minutes scrolls out and its solo showed a false zero. Lane
    // keys ARE camera ids (EventsArea._buildLookup), so one soloed camera fetches ITS
    // events from the server; solo off (or multi-solo) restores the shared feed. Lane
    // muting/visuals stay client-side and unchanged.
    onSoloChanged: if (EventsStore.realMode) EventsStore.cameraScope(solo.length === 1 ? solo[0] : "")
    // Fixture hook (WT_HERO_EVENT): select one known event by id the moment the feed
    // carries it — pairs with WT_HERO_SCOPE_CAM + WT_HERO_AUTOPLAY for scanner fixtures.
    property bool _devSelected: false
    Connections {
        target: EventsStore
        function onEventsChanged() {
            if (tri._devSelected) return;
            if (typeof wtHeroEvent === "undefined" || wtHeroEvent === "") { tri._devSelected = true; return; }
            if (EventsStore.find(wtHeroEvent)) { tri._devSelected = true; tri.select(wtHeroEvent); }
        }
    }
    property var fold: []                         // per-lane fold (alt-click)
    property string buf: ""                       // digit type-ahead buffer (max 3)
    readonly property int rowH: 44                // dense (compact 48 / ultra 36)
    readonly property int headH: 26
    readonly property int emptyH: 36
    property bool stickyHeads: true

    Timer { id: bufClear; interval: 1400; onTriggered: tri.buf = "" }

    function _tabPred(e) {
        if (tri.filter === "open") return e.status === "new" || e.status === "ack" || e.status === "progress";
        if (tri.filter === "critical") return e.priority === "critical";
        return true;
    }
    function _octNum(c) {
        var m = /\.(\d+)$/.exec(c.ip || "");
        if (m) return parseInt(m[1]);
        var m2 = /\((?:\d+\.){3}(\d+)\)/.exec(c.name || "");
        return m2 ? parseInt(m2[1]) : -1;
    }
    // model string = camera name minus its "(ip)" tail — the lane header names it once
    function _modelOf(c) { return String(c.name || c.id || "").replace(/\s*\((?:\d+\.){3}\d+\)\s*$/, ""); }

    // One computed pass builds everything the lanes need. Every item carries a
    // precomputed y so the sticky header is resolved from CONTENT geometry, not
    // from loaded delegates — deterministic at any scroll position and cheap.
    readonly property var _L: {
        var evs = EventsStore.events.filter(tri._tabPred);
        var by = ({});
        for (var i = 0; i < evs.length; i++) {
            var e = evs[i], k = e.cam ? e.cam.key : "?";
            (by[k] = by[k] || []).push(e);
        }
        for (var k0 in by)
            by[k0].sort(function (x, y) {
                return (EventsStore.sevRank[x.priority] - EventsStore.sevRank[y.priority])
                       || (y.ts.getTime() - x.ts.getTime());
            });
        var cams = [];
        for (var ck in EventsStore.cams) {
            var c = EventsStore.cams[ck];
            var sv = { critical: 0, high: 0, medium: 0, low: 0 };
            (by[ck] || []).forEach(function (e2) { if (sv[e2.priority] !== undefined) sv[e2.priority]++; });
            cams.push({ key: ck, cam: c, oct: tri._octNum(c),
                        lbl: (tri._octNum(c) >= 0 ? "." + tri._octNum(c) : String(c.id || ck)),
                        model: tri._modelOf(c), offline: c.offline === true,
                        n: (by[ck] || []).length, sev: sv });
        }
        var active = cams.filter(function (c) { return c.n > 0; });
        active.sort(function (a, b) { return (b.n - a.n) || (a.oct - b.oct); });
        // soloed lanes first, in solo order; a soloed zero-count camera still gets
        // a lane (the filter must not vanish — it shows the inline empty state)
        var sol = [], rest = [];
        active.forEach(function (c) { (tri.solo.indexOf(c.key) >= 0 ? sol : rest).push(c); });
        tri.solo.forEach(function (sk) {
            if (!sol.some(function (c) { return c.key === sk; })) {
                var zc = cams.filter(function (c) { return c.key === sk; })[0];
                if (zc) sol.push(zc);
            }
        });
        sol.sort(function (a, b) { return tri.solo.indexOf(a.key) - tri.solo.indexOf(b.key); });
        var laneCams = sol.concat(rest);
        var items = [], y = 0, soloOn = tri.solo.length > 0;
        laneCams.forEach(function (c) {
            var on = tri.solo.indexOf(c.key) >= 0;
            var muted = soloOn && !on;
            var folded = tri.fold.indexOf(c.key) >= 0;
            var collapsed = muted || folded;
            items.push({ t: "h", lane: c, on: on, muted: muted, folded: folded,
                         laneKey: c.key, y: y, h: tri.headH });
            y += tri.headH;
            if (!collapsed) {
                if (c.n === 0) {
                    items.push({ t: "x", lane: c, laneKey: c.key, y: y, h: tri.emptyH });
                    y += tri.emptyH;
                } else {
                    (by[c.key] || []).forEach(function (ev) {
                        items.push({ t: "e", ev: ev, lane: c, laneKey: c.key, y: y, h: tri.rowH });
                        y += tri.rowH;
                    });
                }
            }
        });
        var zeros = cams.filter(function (c) { return c.n === 0 && tri.solo.indexOf(c.key) < 0; });
        zeros.sort(function (a, b) { return a.oct - b.oct; });
        var shown = soloOn ? tri.solo.reduce(function (n, sk) { return n + (by[sk] || []).length; }, 0)
                           : evs.length;
        var vis = [];
        items.forEach(function (it) { if (it.t === "e" && (!soloOn || tri.solo.indexOf(it.laneKey) >= 0)) vis.push(it.ev); });
        return { items: items, total: y, inTab: evs.length, activeCams: active.length,
                 shown: shown, zeros: zeros, visible: vis, by: by };
    }
    // downstream (detail pane, selection) keeps reading _list: the events a guard
    // can currently see, lane order
    readonly property var _list: tri._L.visible

    function toggleSolo(key, add) {
        var s = tri.solo.slice();
        if (add) {
            var i = s.indexOf(key);
            if (i >= 0) s.splice(i, 1); else s.push(key);
        } else {
            s = (s.length === 1 && s[0] === key) ? [] : [key];
        }
        tri.solo = s;
        lanesView.contentY = 0;   // soloed lanes sort to the TOP — positional, never a measured scroll
    }
    function toggleFold(key) {
        var f = tri.fold.slice();
        var i = f.indexOf(key);
        if (i >= 0) f.splice(i, 1); else f.push(key);
        tri.fold = f;
    }
    function jumpTo(key) {
        tri.solo = [key];
        tri.fold = tri.fold.filter(function (x) { return x !== key; });
        lanesView.contentY = 0;
    }
    function clearSolo() { tri.solo = []; tri.buf = ""; }
    function _tabLabel() {
        return tri.filter === "open" ? qsTr("Open queue")
             : tri.filter === "critical" ? qsTr("Critical") : qsTr("All");
    }
    // digit roster matching (octet prefix, honest ambiguity rule)
    function _hits(prefix) {
        var out = [];
        for (var ck in EventsStore.cams) {
            var o = tri._octNum(EventsStore.cams[ck]);
            if (o >= 0 && String(o).indexOf(prefix) === 0) out.push({ key: ck, oct: o });
        }
        out.sort(function (a, b) { return a.oct - b.oct; });
        return out;
    }
    function typeDigit(d) {
        var nb = (tri.buf + d).slice(-3);
        tri.buf = nb;
        var hits = tri._hits(nb);
        // commit only when unambiguous — or at the third digit ('14' still matches
        // .140 .143 .144 .145 .146; jumping early would jump WRONG)
        if (hits.length === 1 || (nb.length >= 3 && hits.length > 0)) tri.jumpTo(hits[0].key);
        bufClear.restart();
    }
    Keys.onPressed: (ev) => {
        if (ev.key >= Qt.Key_0 && ev.key <= Qt.Key_9) { tri.typeDigit(String(ev.key - Qt.Key_0)); ev.accepted = true; }
        else if (ev.key === Qt.Key_Backspace) { tri.buf = tri.buf.slice(0, -1); ev.accepted = true; }
        else if (ev.key === Qt.Key_Escape) { tri.clearSolo(); ev.accepted = true; }
    }
    onActiveChanged: if (active) tri.forceActiveFocus()
    // Dev (WT_TRIAGE_TEST="solo:146" | "type:14"): drives the lane filter for
    // screenshot verification — same code paths as the mouse/keys.
    Timer {
        interval: 9000; running: typeof wtTriageTest !== "undefined" && wtTriageTest !== "" && tri.active
        onTriggered: {
            var m = /^(solo|type):(\d+)$/.exec(wtTriageTest);
            if (!m) return;
            if (m[1] === "solo") { var h = tri._hits(m[2]); if (h.length) tri.jumpTo(h[0].key); }
            else m[2].split("").forEach(function (d) { tri.typeDigit(d); });
        }
    }
    Component.onCompleted: if (active) tri.forceActiveFocus()
    // group-scope change re-ingests the store; prune soloed cameras that left scope
    Connections {
        target: EventsStore
        function onCamsChanged() {
            var keep = tri.solo.filter(function (k) { return EventsStore.cams[k] !== undefined; });
            if (keep.length !== tri.solo.length) tri.solo = keep;
        }
    }

    readonly property var _cur: EventsStore.find(tri.selId) || (_list.length ? _list[0] : null)
    readonly property int _openCount: EventsStore.events.filter(function (e) { return e.status === "new" || e.status === "ack" || e.status === "progress"; }).length
    readonly property int _critTab: EventsStore.events.filter(function (e) { return e.priority === "critical"; }).length

    // reset note + SOP ticks whenever the selected event changes
    property string _curId: _cur ? _cur.id : ""
    on_CurIdChanged: { note = ""; done = ({}); }

    readonly property var _sops: ({
        "_default":   ["Watch the clip + confirm subject type", "Confirm intent", "Record disposition"],
        "person":     ["Watch playback at event time", "Confirm person vs. authorized staff (check badge log)", "If unauthorized after-hours → dispatch / call keyholder", "Record disposition + notes"],
        "line_cross": ["Watch the crossing clip", "Verify direction (inbound = priority)", "Escalate to supervisor + dispatch patrol", "Notify keyholder, log incident"],
        "tamper":     ["Switch to nearest overlapping camera", "Verify obstruction vs. fault", "Dispatch to inspect device", "Raise maintenance ticket"],
        "vehicle":    ["Watch playback, read plate if visible", "Check against expected deliveries", "If in fire lane > limit → tannoy / dispatch", "Record disposition"],
        "loiter":     ["Watch the dwell clip", "Assess intent / duration", "Tannoy warning or dispatch", "Log disposition"],
        "offline":    ["Check device health page", "Confirm network vs. power", "Raise maintenance ticket", "Cover area with adjacent camera"],
        // "motion" deliberately has NO checklist (operator, 2026-08-07): its mock
        // steps duplicated the disposition buttons and read as noise. Typed SOPs
        // above stay for when richer event types arrive.
        "motion":     []
    })
    readonly property var _sop: {
        if (!_cur) return [];
        var s = _sops[_cur.type];
        return s !== undefined ? s : _sops["_default"];
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ======================= LEFT — the queue (variant B lanes) =======================
        Rectangle {
            id: queueCol
            readonly property bool collapsed: Settings.triageQueueCollapsed
            Layout.preferredWidth: collapsed ? 26 : 384
            Layout.fillHeight: true
            color: "transparent"
            Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.line }

            // collapsed rail: count + name, one click to reopen
            Item {
                visible: queueCol.collapsed
                anchors.fill: parent
                Text {
                    anchors.centerIn: parent
                    rotation: -90
                    text: tri._openCount + " \u00b7 " + qsTr("Open queue")
                    color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 1.1
                }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                    onClicked: Settings.triageQueueCollapsed = false }
            }
            // edge toggle chevron (always present)
            Rectangle {
                width: 12; height: 34
                anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                z: 40
                color: qtogMa.containsMouse ? Theme.panel2 : Theme.panel
                border.width: 1; border.color: Theme.line2
                Text { anchors.centerIn: parent; text: queueCol.collapsed ? "\u203a" : "\u2039"
                    color: qtogMa.containsMouse ? Theme.ink : Theme.ink3
                    font.family: Theme.fontSans; font.pixelSize: 11 }
                MouseArea { id: qtogMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: Settings.triageQueueCollapsed = !Settings.triageQueueCollapsed }
            }

            // shared lane-header look: used by the list delegate AND the pinned sticky copy
            component LaneHead: Rectangle {
                id: lh
                property var it: null            // {lane,on,muted,folded,laneKey}
                readonly property var lane: it ? it.lane : null
                readonly property bool collapsed: it ? (it.muted || it.folded) : false
                height: tri.headH
                color: (it && it.on) ? "#2b2318" : (lhMa.containsMouse ? Theme.panel2 : Theme.panel)
                opacity: (it && it.muted && !lhMa.containsMouse) ? 0.6 : 1   // 60% floor keeps the octet ≥4.5:1
                Rectangle { visible: it && it.on; anchors.left: parent.left; width: 2; height: parent.height; color: Theme.accent }
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
                Row {
                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                    spacing: 8
                    Text { width: 8; anchors.verticalCenter: parent.verticalCenter
                        text: lh.collapsed ? "\u25b8" : "\u25be"; color: Theme.ink3
                        font.family: Theme.fontSans; font.pixelSize: 8 }
                    Text { anchors.verticalCenter: parent.verticalCenter
                        text: lh.lane ? lh.lane.lbl : ""              // ONE text run — never ". 144"
                        color: (lh.it && lh.it.on) ? Theme.accent : Theme.ink
                        font.family: Theme.fontMono; font.pixelSize: 12; font.weight: Font.DemiBold }
                    Rectangle { visible: lh.lane && lh.lane.offline; width: 5; height: 5; radius: 2.5
                        anchors.verticalCenter: parent.verticalCenter; color: Theme.bad }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(0, parent.width - 8 - 8 - (lh.lane && lh.lane.offline ? 13 : 0)
                               - octM.width - 38 - 8 - cntM.width - 16)
                        text: lh.lane ? lh.lane.model : ""; elide: Text.ElideRight
                        color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 10
                    }
                    Row {                                          // severity mix — 38×3, the lane's backlog makeup
                        anchors.verticalCenter: parent.verticalCenter; spacing: 1
                        Repeater {
                            model: lh.lane ? ["critical", "high", "medium", "low"].filter(function (k) { return lh.lane.sev[k] > 0; }) : []
                            delegate: Rectangle {
                                required property var modelData
                                height: 3
                                width: Math.max(2, Math.round(38 * lh.lane.sev[modelData] / Math.max(1, lh.lane.n)))
                                color: Theme.sevColor(modelData === "critical" ? "critical" : modelData)
                            }
                        }
                    }
                    Text { id: cntM
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(20, implicitWidth); horizontalAlignment: Text.AlignRight
                        text: lh.lane ? lh.lane.n : ""
                        color: (lh.it && lh.it.on) ? Theme.accent : Theme.ink2
                        font.family: Theme.fontMono; font.pixelSize: 11 }
                }
                Text { id: octM; visible: false; text: lh.lane ? lh.lane.lbl : ""
                    font.family: Theme.fontMono; font.pixelSize: 12; font.weight: Font.DemiBold }
                MouseArea {
                    id: lhMa
                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton
                    onClicked: (m) => {
                        tri.forceActiveFocus();
                        if (!lh.it) return;
                        if (m.modifiers & Qt.AltModifier) tri.toggleFold(lh.it.laneKey);
                        else tri.toggleSolo(lh.it.laneKey, (m.modifiers & Qt.ControlModifier) || (m.modifiers & Qt.MetaModifier));
                    }
                }
                ToolTip.visible: lhMa.containsMouse && lh.lane !== null
                ToolTip.delay: 600
                ToolTip.text: lh.lane ? (lh.lane.cam.name + " \u00b7 " + qsTr("%n event(s)", "", lh.lane.n)
                                         + (lh.it && lh.it.on ? " \u00b7 " + qsTr("soloed") : "")) : ""
            }

            ColumnLayout {
                visible: !queueCol.collapsed
                anchors.fill: parent
                spacing: 0

                // ---- status tabs (32px, gapless) + scope readout ----
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 32
                    color: "transparent"
                    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
                    RowLayout {
                        anchors.fill: parent
                        spacing: 0
                        Repeater {
                            model: [ { k: "open",     l: qsTr("Open queue"), n: tri._openCount },
                                     { k: "critical", l: qsTr("Critical"),   n: tri._critTab },
                                     { k: "all",      l: qsTr("All"),        n: EventsStore.events.length } ]
                            delegate: Rectangle {
                                required property var modelData
                                readonly property bool _active: tri.filter === modelData.k
                                Layout.fillHeight: true
                                Layout.preferredWidth: qtRow.implicitWidth + 22
                                color: _active ? Theme.panel : (qtMa.containsMouse ? Theme.panel2 : "transparent")
                                Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.line }
                                Rectangle { visible: parent._active; anchors.bottom: parent.bottom; width: parent.width; height: 2; color: Theme.accent }
                                Row {
                                    id: qtRow; anchors.centerIn: parent; spacing: 6
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.l
                                        color: parent.parent._active ? Theme.ink : Theme.ink3
                                        font.family: Theme.fontSans; font.pixelSize: 11; font.weight: Font.DemiBold }
                                    Text { anchors.verticalCenter: parent.verticalCenter; text: modelData.n
                                        color: parent.parent._active ? Theme.accent : Theme.ink3
                                        font.family: Theme.fontMono; font.pixelSize: 10 }
                                }
                                MouseArea { id: qtMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: { tri.filter = modelData.k; tri.forceActiveFocus() } }
                            }
                        }
                        // scope readout — replaces a whole filter ribbon at zero height cost
                        Rectangle {
                            Layout.fillWidth: true; Layout.fillHeight: true
                            color: "transparent"
                            Rectangle { anchors.left: parent.left; width: 1; height: parent.height; color: Theme.line }
                            Row {
                                anchors.right: parent.right; anchors.rightMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 6
                                Text {
                                    visible: tri.solo.length === 0
                                    text: tri._L.inTab + " \u00b7 " + tri._L.activeCams + " cam"
                                    color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                                }
                                Text {
                                    visible: tri.solo.length > 0
                                    textFormat: Text.StyledText
                                    text: "<font color='" + Theme.accent + "'><b>" + tri._L.shown + "</b></font> "
                                          + qsTr("of") + " " + tri._L.inTab + " \u00b7 "
                                          + tri.solo.map(function (k) {
                                                var c = EventsStore.cams[k];
                                                return c ? ((tri._octNum(c) >= 0 ? "." + tri._octNum(c) : c.id)) : "";
                                            }).join(" ")
                                    color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 10
                                }
                                Text {
                                    visible: tri.solo.length > 0
                                    text: "\u2715"; color: Theme.accent
                                    font.family: Theme.fontMono; font.pixelSize: 10
                                    MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor
                                        onClicked: tri.clearSolo() }
                                }
                            }
                        }
                    }
                }

                // ---- lanes ----
                Item {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    clip: true
                    ListView {
                        id: lanesView
                        anchors.fill: parent
                        model: tri._L.items
                        boundsBehavior: Flickable.StopAtBounds
                        reuseItems: false
                        cacheBuffer: 400
                        ScrollBar.vertical: ScrollBar { }
                        delegate: Loader {
                            required property var modelData
                            width: lanesView.width
                            sourceComponent: modelData.t === "h" ? headC : modelData.t === "e" ? rowC : emptyC
                            onLoaded: item.it = modelData
                        }
                    }
                    Component { id: headC; LaneHead { width: lanesView.width } }
                    Component {
                        id: emptyC
                        Item {
                            property var it: null
                            width: lanesView.width; height: tri.emptyH
                            Text {
                                anchors.left: parent.left; anchors.leftMargin: 30
                                anchors.verticalCenter: parent.verticalCenter
                                // the lane IS the filter, so the filter can never silently vanish
                                text: it ? qsTr("No events on %1 in %2.").arg(it.lane.lbl).arg(tri._tabLabel()) : ""
                                color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 11
                            }
                            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
                        }
                    }
                    Component {
                        id: rowC
                        Rectangle {
                            id: erow
                            property var it: null
                            readonly property var e: it ? it.ev : null
                            readonly property bool _on: e && tri._cur && tri._cur.id === e.id
                            width: lanesView.width; height: tri.rowH
                            color: _on ? Theme.panel2 : (erMa.containsMouse ? Theme.panel : "transparent")
                            opacity: (e && e.status !== "new") ? 0.45 : 1
                            Rectangle { visible: erow._on; anchors.left: parent.left; width: 3; height: parent.height; color: Theme.accent }
                            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 10; anchors.rightMargin: 10
                                spacing: 9
                                Item {
                                    Layout.preferredWidth: 7; Layout.preferredHeight: 7; Layout.alignment: Qt.AlignVCenter
                                    Rectangle { visible: erow.e && erow.e.priority === "critical"; anchors.centerIn: parent
                                        width: 13; height: 13; radius: 6.5; color: Theme.badSoft }
                                    Rectangle { anchors.centerIn: parent; width: 7; height: 7; radius: 3.5
                                        color: erow.e ? Theme.sevColor(erow.e.priority) : Theme.ink3 }
                                }
                                Rectangle {
                                    Layout.preferredWidth: Math.round(tri.rowH * 1.32)
                                    Layout.preferredHeight: Math.round(tri.rowH * 0.75)
                                    Layout.alignment: Qt.AlignVCenter
                                    color: "#000"; border.width: 1; border.color: Theme.line; clip: true
                                    EvSnapshot { anchors.fill: parent; anchors.margins: 1; ev: erow.e; mini: true; showOsd: false }
                                    Rectangle {
                                        visible: erow.e && erow.e.durationSec > 0
                                        anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 1
                                        color: Qt.rgba(0, 0, 0, 0.72); height: 11; width: durB.implicitWidth + 6
                                        Text { id: durB; anchors.centerIn: parent
                                            text: erow.e ? EventsStore.dur(erow.e.durationSec) : ""
                                            color: "#fff"; font.family: Theme.fontMono; font.pixelSize: 8 }
                                    }
                                }
                                Text { text: erow.e ? EventsStore.hhmmss(erow.e.ts) : ""; color: Theme.ink
                                    font.family: Theme.fontMono; font.pixelSize: 11 }
                                Text { text: erow.e ? EventsStore.rel(erow.e.ts).replace(" ago", "").replace(" назад", "") : ""
                                    color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9 }
                                Item { Layout.fillWidth: true }
                                TypePill { type: erow.e ? erow.e.type : "motion" }
                                StateTag { visible: erow.e !== null; state: erow.e ? erow.e.status : "new"
                                    dotOnly: true; dotSize: 6; Layout.alignment: Qt.AlignVCenter }
                            }
                            MouseArea { id: erMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { if (erow.e) tri.select(erow.e.id); tri.forceActiveFocus() } }
                        }
                    }

                    // pinned sticky lane header — resolved from precomputed content
                    // geometry, so it can't disagree with a layout that no longer exists
                    readonly property var pinnedIt: {
                        var cy = lanesView.contentY;
                        if (!tri.stickyHeads || cy <= 0) return null;
                        var arr = tri._L.items, it = null;
                        for (var i = 0; i < arr.length; i++)
                            if (arr[i].t === "h") { if (arr[i].y <= cy) it = arr[i]; else break; }
                        return (it && it.y < cy) ? it : null;
                    }
                    LaneHead {
                        visible: parent.pinnedIt !== null
                        it: parent.pinnedIt
                        width: lanesView.width
                        anchors.top: parent.top
                        z: 6
                    }

                    // echo chip — the type-ahead's only feedback; no field, no cursor
                    Rectangle {
                        visible: tri.buf !== ""
                        anchors.top: parent.top; anchors.right: parent.right
                        anchors.topMargin: 6; anchors.rightMargin: 9
                        z: 20
                        color: Theme.panel3; border.width: 1; border.color: Theme.accent
                        width: echoRow.implicitWidth + 16; height: 22
                        Row {
                            id: echoRow; anchors.centerIn: parent; spacing: 6
                            Text { anchors.verticalCenter: parent.verticalCenter
                                text: "." + tri.buf
                                color: Theme.accent; font.family: Theme.fontMono; font.pixelSize: 13
                                font.weight: Font.DemiBold; font.letterSpacing: 1 }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: { var h = tri._hits(tri.buf).length; return h === 1 ? qsTr("jump") : h + " cam"; }
                                color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 0.6
                            }
                        }
                    }
                }

                // ---- zero-count strip: the honesty rule in one 30px row ----
                Rectangle {
                    visible: tri._L.zeros.length > 0
                    Layout.fillWidth: true
                    Layout.preferredHeight: 30
                    color: "transparent"
                    Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Theme.line }
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 6
                        spacing: 8
                        Text { text: qsTr("NO EVENTS IN TAB"); color: Theme.ink3
                            font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 1.2 }
                        ListView {
                            Layout.fillWidth: true; Layout.fillHeight: true
                            orientation: ListView.Horizontal
                            spacing: 5; clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            model: tri._L.zeros
                            delegate: Item {
                                required property var modelData
                                width: zBtn.width + 2; height: 30
                                Rectangle {
                                    id: zBtn
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: zTxt.implicitWidth + 10; height: 17
                                    color: zMa.containsMouse ? Theme.panel2 : "transparent"
                                    border.width: 1; border.color: zMa.containsMouse ? Theme.line2 : Theme.line
                                    Text { id: zTxt; anchors.centerIn: parent; text: modelData.lbl
                                        color: zMa.containsMouse ? Theme.ink2 : Theme.ink3
                                        font.family: Theme.fontMono; font.pixelSize: 10 }
                                    MouseArea { id: zMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                        onClicked: { tri.jumpTo(modelData.key); tri.forceActiveFocus() } }
                                }
                            }
                        }
                    }
                }
            }
        }

        // ======================= RIGHT — the detail =======================
        Item {
            Layout.fillWidth: true; Layout.fillHeight: true

            // empty state
            Text {
                visible: !tri._cur; anchors.centerIn: parent
                text: qsTr("Queue clear — no open events."); color: Theme.ink3
                font.family: Theme.fontSans; font.pixelSize: 14
            }

            Popup {
                id: assignPop
                x: parent.width - 300; y: heroBlock.height + 4
                width: 214; padding: 1
                closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
                background: Rectangle { color: Theme.panel2; border.width: 1; border.color: Theme.line2 }
                contentItem: Column {
                    id: pickCol
                    Text { width: parent.width; height: 26; leftPadding: 10; verticalAlignment: Text.AlignVCenter
                        text: qsTr("ASSIGN TO"); color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 1.0 }
                    Repeater {
                        model: EventsStore.operators
                        delegate: Rectangle {
                            required property var modelData
                            readonly property bool _isCur: tri._cur && tri._cur.assignedTo === modelData.username
                            width: pickCol.width; height: 30
                            color: opMa.containsMouse ? Theme.panel3 : (_isCur ? Theme.accentSoft : "transparent")
                            Text { anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter
                                text: modelData.display_name ? modelData.display_name : modelData.username
                                color: parent._isCur ? Theme.accent : Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12 }
                            Text { anchors.right: parent.right; anchors.rightMargin: 10; anchors.verticalCenter: parent.verticalCenter
                                text: modelData.role; color: Theme.ink3; font.family: Theme.fontMono; font.pixelSize: 9 }
                            MouseArea { id: opMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { if (tri._cur) EventsStore.assign(tri._cur.id, modelData.username); assignPop.close() } }
                        }
                    }
                    Rectangle { visible: tri._cur && tri._cur.assignedTo; width: pickCol.width; height: 1; color: Theme.line }
                    Rectangle {
                        visible: tri._cur && tri._cur.assignedTo
                        width: pickCol.width; height: 30; color: unMa.containsMouse ? Theme.panel3 : "transparent"
                        Text { anchors.left: parent.left; anchors.leftMargin: 10; anchors.verticalCenter: parent.verticalCenter
                            text: qsTr("Unassign"); color: Theme.ink2; font.family: Theme.fontSans; font.pixelSize: 12 }
                        MouseArea { id: unMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: { if (tri._cur) EventsStore.assign(tri._cur.id, ""); assignPop.close() } }
                    }
                    Text { visible: !EventsStore.operators || EventsStore.operators.length === 0
                        width: parent.width; height: 30; leftPadding: 10; verticalAlignment: Text.AlignVCenter
                        text: qsTr("No operators available"); color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 12 }
                }
            }

            ColumnLayout {
                visible: tri._cur !== null
                anchors.fill: parent
                spacing: 0

                // ---- hero: inline player (tool cells live in its merged bar) ----
                Rectangle {
                    id: heroBlock
                    Layout.fillWidth: true
                    Layout.fillHeight: true              // video first: takes every pixel the info panel doesn't reserve
                    Layout.minimumHeight: 180
                    color: "#000"
                    ColumnLayout {
                        id: heroCol
                        anchors.fill: parent
                        spacing: 0
                        // mock → procedural EvPlayer; real → EvHeroPlayer (live recording)
                        Loader {
                            id: heroLoader
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            sourceComponent: EventsStore.realMode ? heroRealC : heroMockC
                        }
                    }
                }

                // drag grip: sizes the INFO PANEL (persisted). Drag UP = smaller
                // panel = bigger video; the stage always absorbs the remainder.
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 7
                    color: gripMa.containsMouse || gripMa.pressed ? Theme.panel2 : Theme.panel
                    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.line }
                    Rectangle { anchors.centerIn: parent; width: 34; height: 2; color: gripMa.containsMouse || gripMa.pressed ? Theme.ink3 : Theme.line2 }
                    MouseArea {
                        id: gripMa
                        anchors.fill: parent; anchors.margins: -3
                        hoverEnabled: true
                        cursorShape: Qt.SizeVerCursor
                        property real _startY: 0
                        property int _startH: 0
                        onPressed: (m) => { _startY = m.y; _startH = Settings.triageBodyH }
                        onPositionChanged: (m) => {
                            if (!pressed) return;
                            Settings.triageBodyH = _startH - Math.round(m.y - _startY);
                        }
                    }
                }

                // ---- body (scrolls) ----
                Flickable {
                    id: bodyFlick
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(Settings.triageBodyH, body.implicitHeight + 20)
                    clip: true
                    contentWidth: width
                    contentHeight: body.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { }

                    ColumnLayout {
                        id: body
                        width: parent.width
                        x: 14; y: 12
                        // 14px right padding too → cap width (variant B body density)
                        Component.onCompleted: width = parent.width - 28
                        Connections { target: body.parent; function onWidthChanged() { body.width = body.parent.width - 28; } }
                        spacing: 0

                        // headline
                        RowLayout {
                            Layout.fillWidth: true; spacing: 16
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 4
                                RowLayout {
                                    spacing: 12
                                    Text { text: tri._cur ? EventsStore.types[tri._cur.type].label : ""; color: Theme.ink
                                        font.family: Theme.fontSans; font.pixelSize: 20; font.weight: Font.DemiBold }
                                    Rectangle {
                                        visible: tri._cur && tri._cur.restricted
                                        height: 18; width: rzT.implicitWidth + 12; color: "transparent"
                                        border.width: 1; border.color: Theme.badDim
                                        Text { id: rzT; anchors.centerIn: parent; text: qsTr("RESTRICTED ZONE"); color: Theme.bad
                                            font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 0.9 }
                                    }
                                }
                                Text { Layout.fillWidth: true; text: (tri._cur && tri._cur.note) ? tri._cur.note : "—"; color: Theme.ink2
                                    wrapMode: Text.WordWrap; font.family: Theme.fontSans; font.pixelSize: 13 }
                            }
                            Sev { level: tri._cur ? tri._cur.priority : "low"; Layout.alignment: Qt.AlignTop }
                        }

                        // facts grid (3-col, 1px gridlines — variant B §4)
                        Rectangle {
                            Layout.fillWidth: true; Layout.topMargin: 14; Layout.bottomMargin: 14
                            color: Theme.line
                            Layout.preferredHeight: facts.implicitHeight + 2
                            // Grid POSITIONER (not GridLayout): a QQuickGridLayout SIGSEGVs on
                            // minimize/restore in Qt 6.4.2 (see LiveMonitor camera grid). Grid has no
                            // layout engine to corrupt. Cells get an explicit width (2 equal columns).
                            Grid {
                                id: facts
                                x: 1; y: 1; width: parent.width - 2
                                columns: 3; rowSpacing: 1; columnSpacing: 1
                                Repeater {
                                    model: tri._cur ? [
                                        { k: qsTr("Camera"),        v: tri._cur.cam.name, mono: false },
                                        { k: qsTr("Device"),        v: tri._cur.cam.id,   mono: true },
                                        { k: qsTr("Zone"),          v: tri._cur.cam.zone, mono: false },
                                        { k: qsTr("Time"),          v: EventsStore.hhmmss(tri._cur.ts) + " \u00b7 " + Qt.formatDate(tri._cur.ts, "ddd dd MMM"), mono: true },
                                        { k: qsTr("Clip length"),   v: tri._cur.durationSec ? EventsStore.dur(tri._cur.durationSec) : "\u2014", mono: true },
                                        { k: qsTr("AI confidence"), v: tri._cur.conf ? (Math.round(tri._cur.conf * 100) + "%") : "n/a", mono: true }
                                    ] : []
                                    delegate: Rectangle {
                                        required property var modelData
                                        width: (facts.width - 2 * facts.columnSpacing) / 3
                                        height: 46
                                        color: Theme.bg
                                        ColumnLayout {
                                            anchors.left: parent.left; anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            anchors.leftMargin: 13; anchors.rightMargin: 13
                                            spacing: 3
                                            Text { text: modelData.k.toUpperCase(); color: Theme.ink3
                                                font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 1.1 }
                                            Text { Layout.fillWidth: true; text: modelData.v; color: Theme.ink; elide: Text.ElideRight
                                                font.family: modelData.mono ? Theme.fontMono : Theme.fontSans; font.pixelSize: 12 }
                                        }
                                    }
                                }
                            }
                        }

                        // response procedure (SOP)
                        Text { visible: tri._sop.length > 0; text: qsTr("RESPONSE PROCEDURE"); color: Theme.ink3; Layout.bottomMargin: 8
                            font.family: Theme.fontMono; font.pixelSize: 10; font.letterSpacing: 1.2 }
                        Repeater {
                            model: tri._sop
                            delegate: Item {
                                id: sopItem
                                required property int index
                                required property var modelData
                                readonly property bool _checked: tri.done[index] === true
                                Layout.fillWidth: true
                                implicitHeight: Math.max(32, sopText.implicitHeight)
                                RowLayout {
                                    anchors.fill: parent; spacing: 10
                                    Rectangle {
                                        Layout.preferredWidth: 18; Layout.preferredHeight: 18; Layout.alignment: Qt.AlignTop; Layout.topMargin: 7
                                        color: sopItem._checked ? Theme.good : "transparent"
                                        border.width: 1; border.color: sopItem._checked ? Theme.good : Theme.line2
                                        EvIcon { anchors.centerIn: parent; visible: sopItem._checked; name: "check"; size: 12; color: Theme.bg }
                                    }
                                    Text {
                                        id: sopText
                                        Layout.fillWidth: true; topPadding: 7; bottomPadding: 7
                                        text: sopItem.modelData; wrapMode: Text.WordWrap
                                        color: sopItem._checked ? Theme.ink3 : Theme.ink2
                                        font.family: Theme.fontSans; font.pixelSize: 13
                                        font.strikeout: sopItem._checked
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: { var d = Object.assign({}, tri.done); d[sopItem.index] = !sopItem._checked; tri.done = d; }
                                }
                            }
                        }

                        // disposition note
                        Rectangle {
                            Layout.fillWidth: true; Layout.preferredHeight: 40; Layout.topMargin: 16
                            color: Theme.panel; border.width: 1; border.color: noteIn.activeFocus ? Theme.accent : Theme.line2
                            TextInput {
                                id: noteIn
                                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                                verticalAlignment: TextInput.AlignVCenter
                                clip: true; color: Theme.ink; selectionColor: Theme.accentDim
                                font.family: Theme.fontSans; font.pixelSize: 13
                                text: tri.note
                                onTextChanged: tri.note = text
                                Text { visible: noteIn.text === ""; text: qsTr("Add disposition note (what happened, who responded)\u2026")
                                    color: Theme.ink3; font.family: Theme.fontSans; font.pixelSize: 13
                                    anchors.verticalCenter: parent.verticalCenter }
                            }
                        }
                        Item { Layout.preferredHeight: 6 }   // bottom breathing room
                    }
                }

                // ---- action bar (fixed footer) ----
                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: 44; color: Theme.panel
                    Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Theme.line }
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 18; anchors.rightMargin: 18; spacing: 8
                        EvButton { small: true; variant: "good"; icon: "check"; label: qsTr("Authorized"); enabledBtn: !EventsStore.actionsPending
                            onClicked: if (tri._cur) EventsStore.dispose(tri._cur.id, "authorized", tri.note) }
                        EvButton { small: true; variant: ""; icon: "x"; label: qsTr("False alarm"); enabledBtn: !EventsStore.actionsPending
                            onClicked: if (tri._cur) EventsStore.dispose(tri._cur.id, "false_alarm", tri.note) }
                        EvButton { small: true; variant: "danger"; icon: "dispatch"; label: qsTr("Dispatch guard"); enabledBtn: !EventsStore.actionsPending
                            onClicked: if (tri._cur) EventsStore.dispose(tri._cur.id, "dispatched", tri.note) }
                        Item { Layout.fillWidth: true }
                        EvButton {
                            visible: tri._cur && tri._cur.status === "new"
                            small: true; variant: "pri"; icon: "check"; label: qsTr("Acknowledge"); kbd: "E"
                            onClicked: if (tri._cur) EventsStore.ack(tri._cur.id)
                        }
                        StateTag {
                            visible: tri._cur && tri._cur.status !== "new"
                            Layout.rightMargin: 8
                            state: tri._cur ? tri._cur.status : "new"
                            label: tri._cur ? (tri._cur.status.toUpperCase() + (tri._cur.dispo ? " · " + EventsStore.dispoDefs[tri._cur.dispo].label : "")) : ""
                        }
                    }
                }
            }
        }
    }

    function _doExport() {
        if (!tri._cur) return;
        var w = EventsStore.episodeWindow(tri._cur);   // export the whole episode (footage span), not a forward 1-min window
        tri.exportClip(tri._cur.cam.id, w.startMs - 15000,
            w.endMs > w.startMs ? w.endMs + 15000 : w.startMs + 45000,
            "Event · " + (EventsStore.types[tri._cur.type] ? EventsStore.types[tri._cur.type].label : tri._cur.type));
    }
    Component { id: heroMockC; EvPlayer { ev: tri._cur } }
    Component {
        id: heroRealC
        EvHeroPlayer {
            ev: tri._cur; playbackClient: tri.playbackClient; surfaced: tri.active
            fillStage: true
            toolCells: true
            bookmarkOn: tri._cur ? tri._cur.bookmarked === true : false
            onExportRequested: if (EventsStore.realMode) tri._doExport()
            onAssignRequested: assignPop.opened ? assignPop.close() : assignPop.open()
            onBookmarkRequested: if (tri._cur && !EventsStore.actionsPending) EventsStore.bookmark(tri._cur.id)
        }
    }
}
