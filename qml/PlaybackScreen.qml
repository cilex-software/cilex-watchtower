import QtQuick
import QtQuick.Layouts
import QtQuick.Controls.Basic as C
import QtMultimedia
import Watchtower

// Playback (S06): recorded playback of one camera from cilex-vision. Main player
// + 340px info aside + full-width bottom timeline. The HLS stream is served
// through the app's local auth proxy (PlaybackClient/HlsProxy). The timeline,
// footage/gap shading, and playhead↔wall-clock mapping all come from the real
// session manifest fragments — no fabricated coverage.
Item {
    id: root

    property var camera: null          // camera map (name, ip, mac, groupName, …)
    property var client: null          // PlaybackClient
    property var cameraModel: null
    property var eventsModel: null   // events feed: Last-motion row + sidebar badge freshness

    signal closed()                    // back — returns to the previous (detail) view
    signal returnToLive()              // red control — back to Live Monitor

    // session state
    property string sessionId: ""
    property var frags: []             // ready fragments of the LOADED PLAYER session (compact↔wall)
    property double compactDuration: 0
    property double winStartMs: 0      // loaded PLAYER window (the media the pipeline currently holds)
    property double winEndMs: 0
    // The TIMELINE the scrubber shows — the operator's whole review window (a span or a day). It is
    // DECOUPLED from the player window: a far seek re-opens a short player session at the target (so the
    // FFmpeg HLS demuxer never seeks across discontinuities — the freeze fix) WITHOUT shrinking the
    // scrubber. tlFrags = the timeline's footage segments (wall coords only, for the footage track);
    // win*/frags stay the player session for posToWall/seek. Set on a fresh open, preserved on seekFar.
    property double tlStartMs: 0
    property double tlEndMs: 0
    property var tlFrags: []
    property bool _seekReopen: false   // true => the next session-ready is a far-seek re-open, keep the timeline
    property bool _continuous: false   // continuous-timeline session ⇒ seek directly within the loaded run
    property int _frameSeq: 0          // ++ on every rendered frame — input to the freeze-watchdog
    property bool _frameModeRepause: false   // re-open under frame mode: pause on the first frame
    property int _seekWatchSeq: -1     // _frameSeq when a direct continuous seek was issued; -1 = idle
    property double _seekWatchWall: 0  // that seek's target, for the watchdog's fallback re-open
    // Zoomable scrubber view — a subset of [tlStartMs, tlEndMs] so you can zoom
    // in on a long (12h/24h) timeline to place an export In/Out precisely
    // (Premiere-style: +/− keys around the playhead, scroll to zoom on the cursor,
    // Shift+scroll to pan, 0/Fit to reset).
    property double viewStartMs: 0
    property double viewEndMs: 0
    readonly property bool tlZoomed: (tlEndMs - tlStartMs) > 0 && (viewEndMs - viewStartMs) < (tlEndMs - tlStartMs) - 1
    property int zoomMin: 60           // 15 / 60 / 1440
    property bool loading: false
    property string errorText: ""

    // clip selection (wall ms), -1 = none
    property double selStartMs: -1
    property double selEndMs: -1
    readonly property bool hasSelection: selStartMs >= 0 && selEndMs > selStartMs

    // client.loggedIn is read for its NOTIFY: cameraIdForIp() is a plain lookup
    // into a map that only fills once the client's /streams resolves — without
    // the loggedIn dependency, a fast boot evaluated this to "" and it STAYED ""
    // (silently disabling coverage, the ribbon, everything camId-keyed).
    readonly property string camId: (client && client.loggedIn && camera)
        ? (client.cameraIdForIp(camera.ip) || client.cameraIdForMac(camera.mac || "")) : ""
    // Coverage feeds the archive ribbon; if the first request ran before camId
    // resolved (the same boot race), re-issue it the moment the id lands.
    onCamIdChanged: if (camId !== "" && client) client.fetchCoverage(camId)

    // ---- events on the scrubber: motion episodes + point events ----------
    // Motion = amber spans; other event types = point ticks. Sources below:
    // motionEpisodes/Buckets come from /events/timeline (see loadTimeline); the
    // dedicated EventModel supplies non-motion point events + the recent list.
    property var motionEpisodes: []      // motion spans from /events/timeline (episodes mode)
    property var motionBuckets: []       // density bins from /events/timeline (buckets mode)
    property bool bucketMode: false      // true when a very busy window switched to bucket rendering
    readonly property int bucketThreshold: 2000   // episode count above which we switch to density buckets
    property var pointEvents: []
    property var eventList: []           // [{type, ts}] for the aside list, newest-first (excl. motion_ended)
    // Motion episodes come PRE-JOINED from the backend /events/timeline endpoint
    // (server pairs motion_started↔motion_ended by recording_id) — no client paging
    // or pairing. The EventModel below still supplies non-motion point events + the
    // recent list (its first page is enough; those are rare/recent).
    function loadTimeline() {
        motionEpisodes = []; motionBuckets = []; bucketMode = false;
        if (!client || camId === "" || tlEndMs <= tlStartMs) return;
        client.fetchTimeline(camId, new Date(tlStartMs).toISOString(), new Date(tlEndMs).toISOString(), 0);
    }
    function loadMotionEvents() {
        pointEvents = []; eventList = [];
        if (camId === "" || tlEndMs <= tlStartMs) return;
        motionEvents.search(camId, new Date(tlStartMs).toISOString(), new Date(tlEndMs).toISOString());
    }
    function rebuildEvents() {
        var all = motionEvents.all(), pts = [], evl = [];
        for (var i = 0; i < all.length; i++) {
            var ev = all[i];
            if (ev.camId !== camId) continue;                       // ignore the instance's initial global fetch
            if (ev.type !== "motion_ended") evl.push({ type: ev.type, ts: ev.ts });
            if (!EventStyle.isMotionSpan(ev.type)) pts.push({ ms: ev.ts, type: ev.type });   // non-motion → tick
        }
        pts.sort(function (a, b) { return a.ms - b.ms; });
        pointEvents = pts;
        eventList = evl;
    }
    // per-type show/hide (legend keys: "motion" for the span lane, raw event_type
    // for point ticks). Persisted in Settings.hiddenScrubberEventTypes.
    function typeHidden(key) { return Settings.hiddenScrubberEventTypes.indexOf(key) >= 0; }
    // Type visibility is the CHIPS only. Whether the motion lane is drawn at all
    // is the navigator header's MOTION toggle (Settings.eventsOnScrubber) — two
    // different questions that used to share one predicate.
    function typeVisible(key) { return !typeHidden(key); }
    function toggleType(key) {
        var h = Settings.hiddenScrubberEventTypes.slice(), i = h.indexOf(key);
        if (i >= 0) h.splice(i, 1); else h.push(key);
        Settings.hiddenScrubberEventTypes = h;
    }
    // legend keys present in the window: "motion" (if any episodes) + each distinct point type
    readonly property var eventTypesPresent: {
        var seen = ({}), out = [];
        if (motionEpisodes.length > 0 || motionBuckets.length > 0) out.push("motion");
        for (var i = 0; i < pointEvents.length; i++) {
            var t = pointEvents[i].type;
            if (!seen[t]) { seen[t] = true; out.push(t); }
        }
        return out;
    }
    // most-recent events (visible types) for the aside list; motion_ended omitted
    // (the start is the meaningful row).
    readonly property var recentList: {
        var src = eventList, out = [];
        for (var i = 0; i < src.length && out.length < 12; i++) {
            var key = EventStyle.isMotionSpan(src[i].type) ? "motion" : src[i].type;
            if (!typeVisible(key)) continue;
            out.push(src[i]);
        }
        return out;
    }

    // ---- helpers ---------------------------------------------------------
    function pad(n) { return (n < 10 ? "0" : "") + n }
    function fmtClock(ms) {
        if (!ms || isNaN(ms)) return "—";
        return Settings.clock(ms, true);   // honors the Time-format preference
    }
    function fmtDur(sec) {
        sec = Math.max(0, Math.round(sec));
        var m = Math.floor(sec / 60), s = sec % 60;
        return m + ":" + pad(s);
    }
    // compact player-seconds -> wall ms (via ready fragments)
    function posToWall(sec) {
        for (var i = 0; i < frags.length; i++) {
            var f = frags[i];
            if (sec >= f.cs && sec <= f.ce) {
                var frac = (f.ce > f.cs) ? (sec - f.cs) / (f.ce - f.cs) : 0;
                return f.ws + frac * (f.we - f.ws);
            }
        }
        return frags.length ? frags[0].ws : winStartMs;
    }
    // wall ms -> compact player-seconds (nearest covered fragment)
    function wallToPos(ms) {
        for (var i = 0; i < frags.length; i++) {
            var f = frags[i];
            if (ms >= f.ws && ms <= f.we) {
                var frac = (f.we > f.ws) ? (ms - f.ws) / (f.we - f.ws) : 0;
                return f.cs + frac * (f.ce - f.cs);
            }
        }
        // not inside footage — snap to the next fragment that starts after ms
        for (var j = 0; j < frags.length; j++)
            if (frags[j].ws >= ms) return frags[j].cs;
        return compactDuration;
    }
    // Nearest recorded instant to wall `ms` on the operator's timeline (tlFrags; falls
    // back to the loaded window's frags). Inside footage → unchanged; in a gap → the
    // nearer island's head, or its tail −3s (EOS headroom) when past the end.
    function _snapToFootage(ms) {
        var f = tlFrags.length ? tlFrags : frags;
        var best = ms, bestD = Infinity;
        for (var i = 0; i < f.length; i++) {
            if (ms >= f[i].ws && ms <= f[i].we) return ms;
            var head = ms < f[i].ws;
            var d = head ? f[i].ws - ms : ms - f[i].we;
            if (d < bestD) { bestD = d; best = head ? f[i].ws : Math.max(f[i].ws, f[i].we - 3000); }
        }
        return best;
    }
    function seekToWall(ms) {
        if (!isFinite(ms)) { console.warn("[PB] seekToWall(non-finite) ignored"); return; }
        root._nudgeAnchor = -1;   // an absolute seek re-bases the relative-move pointer
        stepper.cancelStep();   // cancel any in-flight step; cache stays (in-session pts remain valid)
        // A far-seek open is in flight: route straight to seekFar, which COALESCES
        // (replaces the pending target — last click wins). Deterministic, instead of
        // depending on the stopped-mid-swap player's seekable/duration quirks, where
        // rapid clicks previously either dispatched a redundant re-open or vanished.
        if (_farInFlight) { seekFar(ms); return; }
        if (!player.seekable && player.duration <= 0) {
            // Player unloaded/unseekable — e.g. a far seek landed in dead air and its
            // session came back (near-)empty (the 2026-07-02 strand: scrubber shows
            // footage, playhead gone, every click dead; reproduced with frags=1 too —
            // a stray fragment, then all seeks silently ate here). A scrubber click
            // must RECOVER — re-open at the (footage-snapped) target — never no-op
            // into a trap state. (Clicks during an in-flight FAR open never reach
            // here — the _farInFlight guard above coalesces them.)
            if (!loading && tlFrags.length > 0 && client && camera)
                seekFar(ms);
            return;
        }
        var pos = wallToPos(ms);
        // CONTINUOUS timeline (Cilex Vision route B, now the default): direct seeks land within a contiguous
        // run. Re-open only when the target is OUTSIDE the loaded window (to fetch that region — the wall
        // holds a ~30min sub-window of a multi-hour timeline) or the jump crosses a kept boundary
        // (gap/codec/profile/pts_wrap). The 6s freeze-watchdog re-opens only a genuine hang; the cold-base
        // latency tail (~2-4s) lands on its own, and re-opening would hit the same cold base.
        if (_continuous && frags.length > 0) {
            var inWindow = ms >= winStartMs && ms <= winEndMs;
            if (inWindow && !_crossesBoundary(player.position / 1000, pos)) {
                if (compactDuration > 3) pos = Math.min(pos, compactDuration - 3);
                var pd = Math.round(Math.max(0, pos) * 1000);
                // Deep never-rendered target: the serve-time remux at a fresh
                // offset is cold (fsoak-measured: 2-4 s of nothing) — a direct
                // seek just burns the cold-watchdog before re-opening anyway.
                // Re-open straight away: the fresh session starts remuxing AT
                // the target (first frame ~1-2 s). Rendered regions stay on the
                // instant direct path (15-173 ms measured).
                if (pd > root._maxPosSeen + 300000) { seekFar(ms); return; }
                player.position = pd; root._scanPos = pd;
                // Operator aimed somewhere new: the same-target recovery budget resets.
                if (Math.abs(ms - root._mislandWall) > 2000) { root._mislandWall = -1; root._mislandCount = 0; }
                _seekWatchSeq = _frameSeq; _seekWatchWall = ms; _seekWatchPosMs = pd;
                _seekWatchGen = _openGen;
                seekWatch.interval = (pd > root._maxPosSeen + 60000) ? 2500 : 6000;
                seekWatch.restart();
                return;
            }
            seekFar(ms);
            return;
        }
        // LEGACY (WT_SEEK_MODE=legacy): a direct seek to a target outside the playout buffer stalls the FFmpeg
        // HLS demuxer across the per-fragment discontinuities — playhead moves, NO frame renders. So a far jump
        // re-opens a short window starting just before the target; near jumps keep the cheap direct seek.
        if (frags.length > 0 && compactDuration > 60 && Math.abs(pos * 1000 - player.position) > 20000) {
            seekFar(ms);
            return;
        }
        // Keep a little headroom before end-of-footage: seeking to the exact last
        // instant strands the pipeline at EOS (frozen frame, endless re-fetch of
        // the final segment). Found 2026-06-14 jumping to motion events whose time
        // is past the camera's last recorded frame.
        if (compactDuration > 3) pos = Math.min(pos, compactDuration - 3);
        var p = Math.round(Math.max(0, pos) * 1000);
        player.position = p;
        root._scanPos = p;        // keep the scan accumulator in step with manual seeks
    }
    // Does the COMPACT jump [from,to] step over a kept discontinuity:true fragment? (The leading "start" sits
    // at cs≤from, so a normal in-run seek never crosses it — only real gaps/codec/profile/pts_wrap.)
    function _crossesBoundary(fromPos, toPos) {
        var lo = Math.min(fromPos, toPos), hi = Math.max(fromPos, toPos);
        for (var i = 0; i < frags.length; i++)
            if (frags[i].disc && frags[i].cs > lo && frags[i].cs <= hi) return true;
        return false;
    }
    // Re-open a short session beginning ~15s before a far seek target (then seek to it on load), so the
    // demuxer never has to seek across the full session's discontinuities. The target lands near the
    // start of a fresh short HLS and renders. Mirrors EvHeroPlayer's event-open window.
    property double _lastFarMs: -1        // last far-seek target (empty-manifest retry replays it)
    function seekFar(ms, preserveMark) {
        if (!client || !camera) return;
        // A non-finite target would serialize as "Invalid Date" and open a session
        // the backend answers with an empty manifest — tearing down a healthy
        // player for nothing (soak rounds 1-3, NaN wall-times from a bad caller).
        if (!isFinite(ms)) { console.warn("[PB] seekFar(non-finite) ignored"); return; }
        _lastFarMs = ms;
        stepper.invalidate();   // a re-open supersedes any cache-step state / in-flight step
        // A far target in DEAD AIR (most of a sparse day) must not open a ±30 min
        // session around nothing — that returns zero ready fragments and strands the
        // player unloaded while the scrubber still shows footage (reported 2026-07-02,
        // 23 Jun day-open). VMS-standard: snap to the nearest recording edge first.
        ms = _snapToFootage(ms);
        // COALESCE rapid far clicks: one open in flight, later clicks only move the
        // target. If the landing window covers the newest target the deferred seek
        // applies it directly; otherwise onSessionReady issues ONE follow-up open.
        if (_farInFlight) {
            _farLatestMs = ms;
            _pendingSeekMs = ms;
            if (_skActive || (typeof wtTrace !== "undefined" && wtTrace))
                console.log("[PB] far-coalesce tgt=" + Qt.formatDateTime(new Date(ms), "HH:mm:ss") + " t=" + Date.now());
            return;
        }
        // preserveMark: the bounded day-open bootstrap re-opens THROUGH this path but
        // must keep timing ([PBTIME]/TTFF) attributed to the operator's calendar click.
        if (!preserveMark) _obMark("seekfar");
        if (_skActive) console.log("[SK] REOPEN cont=" + _continuous + " t=" + Date.now());   // re-open count
        seekWatch.stop(); _seekWatchSeq = -1;        // a re-open supersedes any pending direct-seek watch
        // Phase A #1 (2026-08-02): anchor the window at target−2s, NOT −15s. The
        // playlist head then IS the target — playback starts there and the whole
        // deferred-seek stage (preroll wait + verify-retry, 150–450 ms measured,
        // plus its historical fragility) disappears from the scrubber path.
        // The EVENT-jump lead-in is untouched: openAt() bakes its −15 s into the
        // pending target BEFORE this runs, so its window anchors at (event−15s)−2s
        // and the operator still gets the context breath. Light days (no bounded
        // bootstrap) never pass through here and keep the in-window pending jump.
        _explicitStart = ms - 2000;
        _explicitEnd = Math.min(ms - 2000 + 1800000, Date.now());   // ~30 min window from the target
        _seekReopen = true;             // keep the scrubber timeline (tl*) — only the player window moves
        _pendingSeekMs = -1;            // no inner seek: the window head is the landing point
        _pendingArmed = false;
        _farInFlight = true;            // coalesce further far clicks until this open lands/fails
        _farLatestMs = ms;
        _pendingOpen = true;
        tryOpen();
    }
    // Freeze-watchdog (LAST RESORT): on a continuous session direct seeks land — slow ones are cold BASE
    // renditions (S3 fetch, ~2-4s) that DO land, and re-opening hits the same cold base, so this is long: it
    // re-opens only a genuine >6s hang, never the cold tail. _frameSeq ticks on every rendered frame.
    // Highest position actually RENDERED this session — a direct seek into a
    // region never played yet hits the serve-time remux cold (measured on .67
    // bounded sessions: ~6 s of nothing, then the watchdog re-open lands in
    // <1 s because the fresh session starts remuxing AT the target). Cold-region
    // seeks get a fast 2.5 s watchdog; warm regions keep the patient 6 s.
    property double _maxPosSeen: 0
    property double _seekWatchPosMs: -1
    // Watch lifecycle scoping (night3x 2026-07-14): a watch armed under one open
    // must never judge — or re-open toward — a LATER open. _openGen bumps on every
    // fresh openFor/openForDay; the watch captures it at arm time.
    property int _openGen: 0
    // Per-INSTANCE session-ownership uid: several PlaybackScreen tabs plus the
    // events hero player all share PlaybackClient's broadcast signals; tagged
    // opens + filtered handlers keep every consumer to its own sessions
    // (2026-08-04 cross-hijack — triage black square).
    property string _pcUid: "pb" + Math.floor(Math.random() * 1000000)
    property int _seekWatchGen: -1
    // Same-target recovery budget: re-opening cannot fix a target whose footage
    // genuinely sits elsewhere (sparse day, snapped landing) — unbounded
    // watch→seekFar→watch cycles churned a fresh session every ~6 s (night3x
    // chains up to 9 deep). Two recoveries, then accept what renders.
    property double _mislandWall: -1
    property int _mislandCount: 0
    Timer {
        id: seekWatch; interval: 6000; repeat: false
        onTriggered: {
            // Stale watch from a previous open: the operator has moved on (new
            // day/camera). Firing here hijacked the fresh open back to the old
            // target (night3x: fired 3.4 s into the next day-open). Void it.
            if (root._seekWatchGen !== root._openGen) {
                root._seekWatchSeq = -1; root._seekWatchPosMs = -1;
                return;
            }
            // Landed = frames advanced AND they came from NEAR THE TARGET. A cold
            // direct seek can fail silently: position reports the target while the
            // demuxer resumes rendering from its old buffer (fsoak n=142: clicked
            // 35 s, watched 0.2 s — frames advanced, the watchdog was satisfied,
            // the operator was at the wrong moment). Continuous sessions restamp
            // pts ≈ position, so rendered pts far from the target = not landed.
            //
            // BUT the pts check is only meaningful when frame pts actually spans
            // the position domain. On some serves (observed 2026-07-31, cold-tier
            // days) QVideoFrame::startTime is SEGMENT-RELATIVE — it cycles 0..~6 s
            // forever — and comparing it to a >8 s in-window position declared
            // EVERY far seek mislanded: re-open → play 6 s → mislanded again →
            // budget burned → settled ~15 s BEHIND the target (caught by the
            // 10k-seek harness; the playhead visibly walked backwards). Gate:
            // trust pts for the misland verdict only if it has plausibly LEFT the
            // segment-relative range (> 12 s ≈ 2 segments), or the target itself
            // is inside that range. Otherwise fall back to frames-advanced only —
            // an undetected misland degrades to the operator re-clicking, which
            // beats an automatic loop that reliably lands them in the wrong place.
            var ptsUsable = FrameClock.lastPtsMs > 12000 || root._seekWatchPosMs < 12000;
            var mislanded = ptsUsable && root._seekWatchPosMs >= 0 && FrameClock.lastPtsMs >= 0
                            && Math.abs(FrameClock.lastPtsMs - root._seekWatchPosMs) > 8000;
            if (root._seekWatchSeq >= 0 && (root._frameSeq <= root._seekWatchSeq || mislanded)) {
                if (Math.abs(root._seekWatchWall - root._mislandWall) < 2000) root._mislandCount++;
                else { root._mislandWall = root._seekWatchWall; root._mislandCount = 1; }
                if (root._mislandCount <= 2) {
                    if (mislanded && (typeof wtTrace !== "undefined") && wtTrace)
                        console.log("[PB] seek MISLANDED (pts=" + FrameClock.lastPtsMs.toFixed(0)
                                    + " target=" + root._seekWatchPosMs + ") — re-opening");
                    root.seekFar(root._seekWatchWall);
                } else if ((typeof wtTrace !== "undefined") && wtTrace) {
                    console.log("[PB] seek-watch GIVE-UP after 2 recoveries (target="
                                + root._seekWatchPosMs + ") — accepting rendered position");
                }
            } else {
                root._mislandWall = -1; root._mislandCount = 0;   // landed clean: budget resets
            }
            root._seekWatchSeq = -1; root._seekWatchPosMs = -1;
        }
    }
    Connections {
        target: vout.videoSink
        function onVideoFrameChanged(frame) {
            root._frameSeq++;
            if (player.position > root._maxPosSeen) root._maxPosSeen = player.position;
            // A re-open under frame mode: the new session needed play() to decode
            // anything, so park it on the very first frame it delivers and re-seed
            // the strip's centre tile from it — the enterFrameMode() pairing.
            if (root._frameModeRepause) {
                root._frameModeRepause = false;
                if (root.frameMode) {
                    root.paused = true;
                    root.applyTransport();
                    FrameClock.attach(vout.videoSink);
                    FrameCache.attach(vout.videoSink);
                    FrameCache.captureCurrent();
                }
            }
            if (root._ttffPending) {       // first frame of a fresh open — the TTFF endpoint
                root._ttffPending = false;
                root.lastTtffMs = Date.now() - root._obT0;
                if (root._pbTime) console.log("[PBTIME] first_frame dt=" + Math.round(root.lastTtffMs)
                                              + "ms tag=" + root._obTag);
            }
        }
    }

    // Smoothly-interpolated player position (compact ms). MediaPlayer.position over
    // HLS only ticks a few times a second in coarse steps, so binding the playhead
    // straight to it makes the marker lurch ~twice a second — and the eye catches the
    // tall stick jumping a beat before the small knob, which reads as the two being
    // "out of sync". We run a local 60fps clock while playing and snap it back to the
    // real position on a seek / scan jump / drift, so the whole playhead glides as one.
    property double _smoothMs: 0
    Timer {
        interval: 16; repeat: true
        running: !root.paused && root.frags.length > 0 && root.playSpeed <= root.maxDecodeRate
                 && player.playbackState === MediaPlayer.PlayingState
        onTriggered: {
            var d = player.duration;
            root._smoothMs = Math.min(d > 0 ? d : root._smoothMs, root._smoothMs + interval * player.playbackRate);
        }
    }
    Connections {
        target: player
        // snap when paused (sit exactly on the frame), during high-speed scan (follow
        // its big jumps), or on a real seek / drift > ~0.4s; else let the clock glide.
        function onPositionChanged() {
            if (root.paused || root.playSpeed > root.maxDecodeRate
                    || Math.abs(player.position - root._smoothMs) > 400)
                root._smoothMs = player.position;
        }
        function onPlaybackStateChanged() {
            if (player.playbackState !== MediaPlayer.PlayingState) root._smoothMs = player.position;
        }
    }

    // current playhead wall ms (driven by the smooth clock, not raw position)
    readonly property double playheadMs: posToWall(_smoothMs / 1000)

    // ---- playback speed / fast-forward ----------------------------------
    // playbackRate carries low speeds, but the HEVC-1440p decoder caps near ~14×
    // realtime on this hardware, so x20…x200 can't decode every frame. Above
    // maxDecodeRate we "scan": the player keeps playing (so frames render) while
    // a timer jumps the playhead forward by rate×interval — a true high-speed
    // fast-forward (how VMS clients race through hours of footage).
    // ¼×/½× = slow-motion review (research §1: fractional rates for detail analysis
    // without clicking); they ride the same playbackRate path as 2×/4×.
    readonly property var speeds: [0.25, 0.5, 1, 2, 4, 10, 20, 50, 100, 200]
    readonly property real maxDecodeRate: 10
    function fmtSpeed(s) { return s === 0.25 ? "¼×" : s === 0.5 ? "½×" : s + "×"; }
    property real playSpeed: 1
    property bool paused: false
    property double _scanPos: -1          // scan accumulator (compact ms)
    readonly property bool advancing: !paused && frags.length > 0
    function applyTransport() {
        if (paused || frags.length === 0) { scanTimer.stop(); player.pause(); return; }
        // Resuming while a cache-stepped frame is shown: park the player just behind
        // the shown frame first, so playback continues from what the operator sees.
        if (stepper.diverged) stepper.resumeForPlay();
        if (playSpeed <= maxDecodeRate) {
            scanTimer.stop();
            player.playbackRate = playSpeed;
            player.play();
        } else {
            scanTimer.stop();
            player.playbackRate = 1;
            _scanPos = player.position;
            player.play();                // keep rendering frames between jumps
            scanTimer.start();
        }
    }
    function setSpeed(s) { playSpeed = s; paused = false; applyTransport(); }
    function togglePlay() { paused = !paused; applyTransport(); }

    // ---- timeline zoom (precise export selection on long windows) -----------
    function resetView() { viewStartMs = tlStartMs; viewEndMs = tlEndMs; }
    // Zoom the view by `factor` (<1 = in, >1 = out) keeping centerMs under the
    // same x; clamp to the timeline window, 2s minimum span.
    function zoomView(factor, centerMs) {
        var full = tlEndMs - tlStartMs;
        if (full <= 0) return;
        var cur = viewEndMs - viewStartMs; if (cur <= 0) cur = full;
        var span = Math.max(2000, Math.min(full, cur * factor));
        if (centerMs < viewStartMs || centerMs > viewEndMs) centerMs = (viewStartMs + viewEndMs) / 2;
        var frac = (centerMs - viewStartMs) / cur;
        var ns = centerMs - frac * span, ne = ns + span;
        if (ns < tlStartMs) { ns = tlStartMs; ne = ns + span; }
        if (ne > tlEndMs) { ne = tlEndMs; ns = ne - span; }
        viewStartMs = Math.max(tlStartMs, ns);
        viewEndMs = Math.min(tlEndMs, ne);
    }
    function panView(deltaMs) {
        var span = viewEndMs - viewStartMs;
        var ns = viewStartMs + deltaMs, ne = viewEndMs + deltaMs;
        if (ns < tlStartMs) { ns = tlStartMs; ne = ns + span; }
        if (ne > tlEndMs) { ne = tlEndMs; ns = ne - span; }
        viewStartMs = ns; viewEndMs = ne;
    }
    // Human span label for the "Custom" zoom chip, e.g. "2h 14m", "45m", "30s".
    function fmtSpan(ms) {
        var s = Math.round(ms / 1000);
        if (s < 60) return s + "s";
        var m = Math.round(s / 60);
        if (m < 60) return m + "m";
        var h = Math.floor(m / 60), mm = m % 60;
        return mm ? (h + "h " + mm + "m") : (h + "h");
    }

    // ---- timeline ruler (adaptive tick marks, Premiere/FCP-style) -----------
    // Nice major intervals, each with a clock-aligned minor subdivision, so ticks
    // always land on round local times. Picked so a labeled tick is ~every 90px.
    readonly property var _niceIntervals: [
        { major: 1000, minor: 1 },     { major: 5000, minor: 5 },     { major: 10000, minor: 2 },
        { major: 15000, minor: 3 },    { major: 30000, minor: 2 },    { major: 60000, minor: 4 },
        { major: 120000, minor: 4 },   { major: 300000, minor: 5 },   { major: 600000, minor: 2 },
        { major: 900000, minor: 3 },   { major: 1800000, minor: 2 },  { major: 3600000, minor: 4 },
        { major: 7200000, minor: 4 },  { major: 10800000, minor: 3 }, { major: 21600000, minor: 6 },
        { major: 43200000, minor: 2 }, { major: 86400000, minor: 4 }
    ]
    function _localMidnight(ms) { var d = new Date(ms); d.setHours(0, 0, 0, 0); return d.getTime(); }
    function _rulerLabel(ms, interval) {
        var d = new Date(ms);
        return interval < 60000 ? Qt.formatTime(d, "HH:mm:ss") : Qt.formatTime(d, "HH:mm");
    }
    // Tick marks for the visible [startMs,endMs] over widthPx: [{ms, major, lbl}].
    function computeTicks(startMs, endMs, widthPx) {
        var span = endMs - startMs;
        if (span <= 0 || widthPx <= 0) return [];
        var target = span * 90 / widthPx;            // aim for a labeled tick ~every 90px
        var pick = _niceIntervals[_niceIntervals.length - 1];
        for (var i = 0; i < _niceIntervals.length; i++)
            if (_niceIntervals[i].major >= target) { pick = _niceIntervals[i]; break; }
        var minorStep = pick.major / pick.minor;
        var anchor = _localMidnight(startMs);        // align to local midnight (round local times)
        var first = anchor + Math.ceil((startMs - anchor) / minorStep) * minorStep;
        var out = [];
        for (var t = first; t <= endMs && out.length < 600; t += minorStep) {
            var rel = Math.round((t - anchor) / minorStep);
            var isMajor = (rel % pick.minor) === 0;
            out.push({ ms: t, major: isMajor, lbl: isMajor ? _rulerLabel(t, pick.major) : "" });
        }
        return out;
    }

    // ---- open-path stage timing ------------------------------------------
    // [PBTIME] logs each stage of an open (dispatch → session HTTP → source set →
    // first rendered frame) so "playback is slow to start" reports can be localized
    // in one run. Active under WT_TRACE or the WT_TTFF_DAYS harness; inert otherwise.
    readonly property bool _pbTime: (typeof wtTrace !== "undefined" && wtTrace)
                                    || (typeof wtTtffDays !== "undefined" && wtTtffDays !== "")
    property double _obT0: 0           // when the current open began
    property string _obTag: ""
    property bool _ttffPending: false  // armed on source-set; cleared by the first rendered frame
    property double lastTtffMs: -1     // last open→first-frame (read by the WT_TTFF_DAYS harness)
    function _obMark(tag) {
        _obT0 = Date.now(); _obTag = tag; _ttffPending = false;
        if (_pbTime) console.log("[PBTIME] open tag=" + tag + " t=" + _obT0);
    }

    // ---- session open ----------------------------------------------------
    property bool _pendingOpen: false
    // When >= 0, tryOpen() uses this explicit wall window (a calendar day)
    // instead of the rolling "last zoomMin minutes" window.
    property double _explicitStart: -1
    property double _explicitEnd: -1
    property double _pendingSeekMs: -1     // after the session loads, seek here (event open-at, −15s lead-in)
    property int _pendingTries: 0          // verify-and-retry budget for the pending seek (see applyPendingSeek)
    // Drives applyPendingSeek until the position PROVABLY lands (or the budget
    // caps). Signals alone lost seeks on same-duration source swaps.
    // 60 ms tick (phase A #3): the retry quantization is pure added latency on
    // the event-jump path; budget below keeps the same ~4.5 s time cap.
    Timer {
        interval: 60; repeat: true
        running: root._pendingArmed && root._pendingSeekMs >= 0
        onTriggered: player.applyPendingSeek()
    }
    property bool _pendingArmed: false     // true only once THIS open's session is ready (race-safe deferred seek)
    // Far-seek COALESCING (2026-07-03, operator report "click the bar fast → freezes"):
    // rapid chaotic scrubber clicks used to dispatch one session re-open PER CLICK —
    // overlapping opens, serial source swaps, seconds of dead video (and clicks landing
    // mid-open were silently dropped). Now at most ONE far-seek open is in flight;
    // later far clicks only replace the pending target. On land: in-window targets
    // apply via the normal deferred seek; an outside-window latest triggers ONE
    // follow-up re-open. See [SPAM] driver + docs/perf/2026-07-03 wedge prompt.
    property bool _farInFlight: false
    property double _farLatestMs: -1
    // One silent retry for a FRESH open whose manifest came back empty. Observed
    // 2026-07-03 under backend load: a 22 Jun day-open returned 0 fragments (200 OK)
    // while the same request minutes later returned 4760 ready — a transient. Showing
    // the terminal "No footage recorded in this range." for a blip reads as data loss
    // to the operator (reported, screenshot). Retry once ~1.5 s later; still empty →
    // the honest error stands. (Far-seek empties keep their own snap/recover path.)
    property bool _emptyRetried: false
    Timer {
        id: emptyRetry
        interval: 1500; repeat: false
        onTriggered: { root._pendingOpen = true; root.tryOpen(); }
    }
    // Same transient, far-seek flavor (soak-caught 2026-07-10): a fragment click on
    // an archived day re-opened via seekFar and the backend answered 200 with ZERO
    // fragments in 19 ms — for a window that provably holds fragments (the click
    // target). One silent replay of the same target before the honest error.
    Timer {
        id: farEmptyRetry
        interval: 900; repeat: false
        onTriggered: if (root._lastFarMs > 0) root.seekFar(root._lastFarMs)
    }
    property string selectedDay: ""        // "yyyy-MM-dd" loaded from the calendar, else ""

    // The /review/thumbnails consumers (hover keyframe preview + the 24-tile
    // day-overview strip) lived in the old bottom timeline band and were
    // removed with it: the "One Axis" navigator is 115px in total and tier 1
    // answers "what is in this day" as a QUANTITY across all 35 days, which is
    // what those two were approximating. PlaybackClient.fetchThumbnails is
    // unchanged and still serves the events hero player.

    // footage-calendar coverage state (fed by PlaybackClient.coverageReady)
    property int retentionDays: 35         // longest tier retention = calendar span
    property var footageDays: []           // dates with recorded footage
    property bool coveragePending: true    // coverage API not yet answered/available
    // Coverage is fetched at open, but footage keeps accruing while the operator
    // reviews (e.g. a camera recovering mid-shift) — refresh quietly once a minute
    // so today's dot appears without re-opening the screen. (2026-07-08: .201
    // resumed recording after 7 days; the calendar kept showing Jul 1 as last.)
    Timer {
        interval: 60000; repeat: true
        running: root.visible && root.camId !== "" && root.client !== null
        onTriggered: root.client.fetchCoverage(root.camId)
    }

    function openFor(cam, spanMin) {
        camera = cam;
        zoomMin = spanMin || zoomMin;
        _obMark("span" + zoomMin);
        _explicitStart = -1; _explicitEnd = -1; selectedDay = ""; _pendingSeekMs = -1; _seekReopen = false;
        _farInFlight = false; _farLatestMs = -1;
        seekWatch.stop(); _seekWatchSeq = -1; _seekWatchPosMs = -1; _openGen++;   // void any pending watch
        _emptyRetried = false; emptyRetry.stop();
        coveragePending = true; footageDays = [];   // reset for the (possibly new) camera
        dayInfo = ({}); _autoLanded = false;
        hoverId = ""; selId = ""; ladderOpen = false;
        errorText = ""; selStartMs = -1; selEndMs = -1;
        // Fresh screen entry: no frame-mode leftovers, no stale timeline. (Operator-
        // reported 2026-07-09: re-entering playback on an empty day still showed the
        // previous visit's filmstrip + green footage bars.)
        exitFrameMode();
        stepper.invalidate();
        frags = []; tlFrags = [];
        if (!client) return;
        client.ensureReady();
        if (root.camId !== "") client.fetchCoverage(root.camId);
        _pendingOpen = true;
        tryOpen();
    }
    // Load a single calendar day's full 24h (gaps included), clamped to now.
    function openForDay(dateStr) {
        if (!camera) return;
        _obMark("day:" + dateStr);
        var startD = new Date(dateStr + "T00:00:00");   // local midnight
        var s = startD.getTime();
        _explicitStart = s;
        _explicitEnd = Math.min(s + 86400000, Date.now());
        selectedDay = dateStr;
        zoomMin = 1440;
        errorText = ""; selStartMs = -1; selEndMs = -1; _pendingSeekMs = -1; _seekReopen = false;
        _farInFlight = false; _farLatestMs = -1;
        seekWatch.stop(); _seekWatchSeq = -1; _seekWatchPosMs = -1; _openGen++;   // void any pending watch
        _emptyRetried = false; emptyRetry.stop();
        // Coverage already tells us this day has no recorded footage (it has no
        // calendar dot) — show an honest empty state instead of opening a session
        // that can only come back empty (or, on a transport hiccup, as a cryptic
        // "Session error"). Only short-circuit when coverage is actually known.
        if (!coveragePending && footageDays.indexOf(dateStr) < 0) {
            _pendingOpen = false; loading = false;
            frags = []; sessionId = ""; compactDuration = 0;
            _teardownPlayer("emptyday");
            errorText = "No footage recorded on this day.";
            return;
        }
        if (!client) return;
        client.ensureReady();
        _pendingOpen = true;
        tryOpen();
    }
    // Open playback at a specific wall instant (e.g. from an event), loading that
    // day and seeking to 15s before the moment so the operator sees the lead-up.
    function openAt(cam, atMs) {
        if (!cam || !atMs || atMs <= 0) { openFor(cam, 60); return; }
        camera = cam;
        openForDay(Qt.formatDate(new Date(atMs), "yyyy-MM-dd"));
        _pendingSeekMs = atMs - 15000;     // set AFTER openForDay (which clears it); applied on session load
        _pendingArmed = false;             // disarm until this day's session reports ready
    }
    // Synchronous player teardown before a session switch. On Qt 6.4's GStreamer
    // media backend, unloading a PLAYING HLS pipeline blocks the GUI thread while the
    // streaming task unwinds — ~300ms on a healthy backend, up to ~1s when the backend
    // is degraded (segments starved). Bounded (souphttpsrc/GStreamer cap it ~1s), not
    // an unbounded hang, and NOT reducible by teardown ordering or proxy-side socket
    // tricks (both measured ineffective, 2026-07-01) — it's internal to the pipeline
    // NULL transition. [PBSTOP] times it under wtTrace; WT_CAL_STRESS exercises it.
    function _teardownPlayer(tag, keepSource) {
        if (!player) return;
        var wasPlaying = player.playbackState === MediaPlayer.PlayingState;
        var t0 = Date.now();
        player.stop();
        // Skip the intermediate full-unload (source="") when a new source will be set
        // immediately (a session SWITCH). Clearing the source tears down the FFmpeg
        // backend's media objects; a frame/state event the decode thread already posted,
        // delivered AFTER that teardown, is a use-after-free — SIGSEGV in
        // libffmpegmediaplugin under ~38+ rapid session opens (2026-07-02 night soak,
        // reproduced on BOTH Qt 6.8.3 and 6.12). Letting onSessionReady do a single
        // setSource(newUrl) swaps the backend in one transition, closing that race.
        // The empty-day / hide paths pass keepSource=false to clear the video.
        if (!keepSource) player.source = "";
        if (typeof wtTrace !== "undefined" && wtTrace)
            console.log("[PBSTOP] " + tag + " took=" + (Date.now() - t0) + "ms wasPlaying=" + wasPlaying
                        + " keepSrc=" + (keepSource === true));
    }
    function tryOpen() {
        if (!_pendingOpen || !client || !camera) return;
        // Playback off → playback-service is stopped; no session can be created.
        // Skip the doomed attempt (the player overlay explains it) and keep
        // _pendingOpen so re-enabling Playback re-creates the session. (CV split
        // playback out of live_view — migration 0052, 2026-07-07.)
        if (root.cameraModel && root.cameraModel.playbackEnabled === false) {
            loading = false; errorText = "";
            return;
        }
        var id = client.cameraIdForIp(camera.ip) || client.cameraIdForMac(camera.mac || "");
        if (!id) {
            if (!client.loggedIn) return;          // /streams not resolved yet — wait
            _pendingOpen = false;
            errorText = "This camera is not in the recording backend.";
            return;
        }
        _pendingOpen = false;
        loading = true;
        frags = [];            // drop the prior session's fragments — a deferred seek or
                               // overlay must never resolve against stale coverage mid-swap
        // Stop the old pipeline but KEEP its source — onSessionReady swaps to the new
        // URL in a single setSource, avoiding the source="" teardown that races decode-
        // thread posted events into a use-after-free under rapid churn (see _teardownPlayer).
        _teardownPlayer("switch", true);
        var start, end;
        if (_explicitStart >= 0) { start = _explicitStart; end = _explicitEnd; }
        else { end = Date.now(); start = end - zoomMin * 60000; }
        // hevc_capable=true: we decode HEVC, so prefer the hot 1440p main stream
        // where it exists (backend serves sub/h264 elsewhere). The 2026-06-11
        // hevc_capable 500 is fixed server-side (131d1b6) — see
        // docs/letters/2026-06-11-session-hevc-capable-500.reply.md.
        client.openSession(id, new Date(start).toISOString(),
                           new Date(end).toISOString(), true,
                           root._pcUid + ":" + root._openGen);
    }
    function setZoom(spanMin) { openFor(camera, spanMin); }

    // ===== Seek-latency test driver (WT_SEEK_TEST) =====
    // Drives N jumps per step size and times each from the seek COMMAND to the ACTUAL frame update.
    // The FFmpeg/HLS backend renders nothing on a PAUSED seek, so we keep playing and detect the seek
    // landing as a >400ms single-frame jump in the frame's media timestamp (normal 1x playback advances
    // ~33-66ms/frame). Works in compact-position space (player.position). [SK] lines feed the analyzer.
    property int    _skFrames: 0
    property var    _skJobs: []
    property int    _skJi: -1
    property double _skT0: 0
    property int    _skDir: 1
    property string _skLabel: ""
    property int    _skReq: 0
    property real   _skAct: 0
    property bool   _skWaiting: false
    property int    _skFramesAtSeek: 0
    property string _skCurStep: ""
    property int    _skStepFail: 0
    property int    _skStepSeen: 0
    readonly property bool _skActive: (typeof wtSeekTest !== "undefined" && wtSeekTest === true)
    Connections {
        target: vout.videoSink; enabled: root._skActive
        function onVideoFrameChanged(frame) {
            root._skFrames++;
            // Single-threaded QML guarantees no frame fires between _skFramesAtSeek=_skFrames and the
            // player.position write in _skSeek, and the HLS backend flushes the sink on seek — so the
            // FIRST frame delivered after a seek IS the new position rendering. (frame.startTime is
            // unavailable on these frames, so content-based detection isn't possible — count is.)
            if (root._skWaiting && root._skFrames > root._skFramesAtSeek) {
                root._skWaiting = false;
                root._skFinish(Date.now() - root._skT0, true);
            }
        }
    }
    Connections {
        target: root.client; enabled: root._skActive
        function onSessionReady(sid, dur, fragments, meta, tag) {
            if (tag === undefined || String(tag).indexOf(root._pcUid + ":") !== 0) return;
            if (root._skJi === -1) _skStart.restart();
        }
    }
    Timer { id: _skStart; interval: 2500; onTriggered: root._skBegin() }
    Timer {
        id: _skWait; interval: 50; repeat: true; running: false
        property double deadline: 0
        onTriggered: { if (Date.now() > deadline && root._skWaiting) root._skFinish(Date.now() - root._skT0, false); }
    }
    function _skBegin() {
        if (root._skJi !== -1) return;
        var steps = [["1s",1000],["10s",10000],["30s",30000],["1m",60000],["5m",300000],["10m",600000],
                     ["20m",1200000],["45m",2700000],["1h",3600000],["2h",7200000],["3h",10800000],
                     ["5h",18000000],["7.5h",27000000],["12h",43200000],["17h",61200000],["24h",86400000]];
        var N = (typeof wtSeekIters !== "undefined" && wtSeekIters > 0) ? wtSeekIters : 100;
        root._skJobs = [];
        for (var s = 0; s < steps.length; s++)
            for (var k = 0; k < N; k++) root._skJobs.push({ l: steps[s][0], d: steps[s][1] });
        console.log("[SK] BEGIN n=" + root._skJobs.length + " iters=" + N +
                    " compactDur_h=" + (compactDuration / 3600).toFixed(2) + " t=" + Date.now());
        player.play();
        _skWarmup.start();
    }
    Timer {
        id: _skWarmup; interval: 100; repeat: true; running: false
        property double t0: 0
        onRunningChanged: if (running) t0 = Date.now()
        onTriggered: {
            if (root._skFrames > 5) {                              // decoder live + frames flowing
                _skWarmup.stop();
                console.log("[SK] WARMED frames=" + root._skFrames + " pos=" + player.position + " t=" + Date.now());
                root._skJi = 0; root._skSeek();
            } else if (Date.now() - t0 > 12000) {
                _skWarmup.stop();
                console.log("[SK] WARMUP-FAIL frames=" + root._skFrames + " t=" + Date.now()); Qt.quit();
            }
        }
    }
    function _skSeek() {
        // Skip a step's remaining iters once it has deterministically frozen (3/3 timeouts) — keeps the
        // run feasible instead of burning 100x the timeout on a dead step.
        while (root._skJi < root._skJobs.length) {
            var jb = root._skJobs[root._skJi];
            if (jb.l !== root._skCurStep) { root._skCurStep = jb.l; root._skStepFail = 0; root._skStepSeen = 0; }
            if (root._skStepSeen >= 3 && root._skStepFail >= 3) { root._skJi++; continue; }
            break;
        }
        if (root._skJi >= root._skJobs.length) { console.log("[SK] DONE n=" + root._skJi + " t=" + Date.now()); Qt.quit(); return; }
        var job = root._skJobs[root._skJi];
        root._skStepSeen++;
        // Targets span the TIMELINE (tl*) in wall-ms. The decoupled player window now moves under us as
        // far seeks re-open, so anchor to the stable timeline + the current playhead — not player.position.
        var lo = root.tlStartMs + 1000, hi = root.tlEndMs - 4000;
        var base = root.playheadMs;
        root._skDir = -root._skDir;
        var tgt = base + root._skDir * job.d;
        if (tgt < lo || tgt > hi) tgt = base - root._skDir * job.d;   // reflect off the timeline edge
        if (tgt < lo) tgt = lo;
        if (tgt > hi) tgt = hi;
        root._skAct = Math.abs(tgt - base);
        root._skLabel = job.l; root._skReq = job.d;
        root._skFramesAtSeek = root._skFrames;                    // detect the first frame delivered after this seek
        root._skWaiting = true; root._skT0 = Date.now();
        seekToWall(tgt);                                          // route through the real user seek path (tests the fix)
        _skWait.deadline = Date.now() + 8000; _skWait.start();
    }
    function _skFinish(lat, ok) {
        _skWait.stop(); root._skWaiting = false;
        if (!ok) root._skStepFail++;
        console.log("[SK] s=" + root._skLabel + " req=" + root._skReq + " act=" + Math.round(root._skAct) +
                    " lat=" + lat + " " + (ok ? "ok" : qsTr("TIMEOUT")) + " t=" + Date.now());
        root._skJi++; root._skSeek();
    }

    Connections {
        target: root.client
        enabled: root.client !== null
        function onSessionReady(sid, dur, fragments, meta, tag) {
            if (tag === undefined || String(tag).indexOf(root._pcUid + ":") !== 0) return;
            var _tReady = Date.now();
            if (root._pbTime) console.log("[PBTIME] session_ready dt=" + (_tReady - root._obT0)
                                          + "ms frags=" + fragments.length + " tag=" + root._obTag);
            root.loading = false;
            root._farInFlight = false;     // this open landed — the far-click coalescing window is over
            var farNext = root._farLatestMs; root._farLatestMs = -1;
            root._pendingArmed = true;     // fragments below are now THIS session's — safe to apply a pending seek
            root._pendingTries = 0;        // fresh verify-and-retry budget for this open
            root.sessionId = sid;
            root._maxPosSeen = 0;              // fresh session → all regions cold
            root.compactDuration = dur;
            root.winStartMs = Date.parse(meta.wall_start);
            root.winEndMs = Date.parse(meta.wall_end);
            root._continuous = !!(meta && meta.seek_mode === "continuous");   // ⇒ direct seeks within a run
            var out = [];
            for (var i = 0; i < fragments.length; i++) {
                // Positional primitive row (pre-filtered "ready" in PlaybackClient):
                // [cs, ce, wsMs, weMs, disc, boundary, codec, tier, resolution, stream_type].
                // Per-fragment QVariantMaps here fed the QV4 heap until a forced GC
                // stalled the GUI thread for minutes (the 2026-07-02 HANG #1).
                var f = fragments[i];
                out.push({ cs: f[0], ce: f[1], ws: f[2], we: f[3],
                           codec: f[6], tier: f[7], resolution: f[8],
                           stream_type: f[9],                  // "main" = high-res original retained; "sub" = standard only
                           disc: !!f[4], boundary: f[5] || "" });   // kept-discontinuity markers (§4-ii)
            }
            root.frags = out;
            if (out.length === 0) {
                if (root._seekReopen) {
                    // A far-seek window came back empty. Far targets snap to footage
                    // first, so this is either the transient empty-manifest blip
                    // (retry once, same target) or genuinely gone footage (honest
                    // error; any footage click re-opens via seekToWall's
                    // unloaded-player branch).
                    root._seekReopen = false;
                    if (!root._emptyRetried && root._lastFarMs > 0) {
                        root._emptyRetried = true;
                        root.loading = true;
                        if (typeof wtTrace !== "undefined" && wtTrace)
                            console.log("[PB] empty-manifest retry (seekfar) target=" + root._lastFarMs);
                        farEmptyRetry.restart();
                    } else {
                        root.errorText = "No footage at that moment — click a green section of the timeline.";
                    }
                } else if (!root._emptyRetried) {
                    // Transient backend blip (empty manifest with 200 under load) —
                    // retry ONCE silently before declaring the range footage-less.
                    root._emptyRetried = true;
                    root.loading = true;
                    if (typeof wtTrace !== "undefined" && wtTrace)
                        console.log("[PB] empty-manifest retry tag=" + root._obTag);
                    emptyRetry.restart();
                } else {
                    root.errorText = "No footage recorded in this range.";
                }
                return;
            }
            root.errorText = "";
            root._emptyRetried = false; emptyRetry.stop();   // a non-empty session re-arms the transient-empty retry
            // A far-seek re-open only swaps the player window — keep the scrubber timeline, its footage
            // track and its markers. A fresh open (span/day/camera) adopts this session AS the timeline.
            if (root._seekReopen) {
                root._seekReopen = false;
                if (typeof wtTrace !== "undefined" && wtTrace)
                    console.log("[PB] far-seek re-open: player win=" + Math.round((root.winEndMs - root.winStartMs) / 60000)
                                + "min, timeline KEPT=" + Math.round((root.tlEndMs - root.tlStartMs) / 60000) + "min");
            } else {
                root.tlStartMs = root.winStartMs;
                root.tlEndMs = root.winEndMs;
                root.tlFrags = out;
                root.resetView();           // fresh open → scrubber shows the full window
                root.loadMotionEvents();    // point events + recent list (EventModel)
                root.loadTimeline();        // motion episode spans from /events/timeline
                if (typeof wtTrace !== "undefined" && wtTrace)
                    console.log("[PB] fresh open: timeline=" + Math.round((root.tlEndMs - root.tlStartMs) / 60000) + "min");
                // BOUNDED INITIAL WINDOW (heavy days): keep this DAY session as the scrubber
                // timeline (tl* above) but do NOT attach its huge playlist — prerolling
                // thousands of segments is what pushed heavy-day TTFF over 1 s (soak
                // 2026-07-02: p99 6.9 s, 3542-frag day). Bootstrap a ~30 min player session
                // at the open target (event instant, else the day's first footage) through
                // the far-seek machinery; EndOfMedia rolls the window forward (see the
                // MediaPlayer handler), so watching straight through the day still works.
                // Gated to genuinely heavy manifests so light days keep the proven
                // single-session path. WT_PB_WINDOW_FRAGS overrides the threshold (test:
                // 1 forces bounded; huge disables).
                var thr = (typeof wtPbWindowFrags !== "undefined" && wtPbWindowFrags > 0) ? wtPbWindowFrags : 1200;
                if (out.length > thr) {
                    var tgt = root._pendingSeekMs >= 0 ? root._pendingSeekMs : out[0].ws;
                    if (root._pbTime) console.log("[PBTIME] bounded_bootstrap frags=" + out.length
                                                  + " tgt=" + Qt.formatDateTime(new Date(tgt), "HH:mm:ss")
                                                  + " tag=" + root._obTag);
                    root.frags = [];            // the day session never becomes the player window
                    root.loading = true;        // spinner holds until the short session lands
                    root.seekFar(tgt, true);    // preserveMark: TTFF stays attributed to the calendar click
                    return;
                }
            }
            root.playSpeed = 1; root._scanPos = -1;
            // Frame mode is a PAUSED mode, and a re-open must not quietly leave it.
            // It used to: a far seek / window roll / day change landed here, dropped
            // the frame cache (correctly — the PTS domain changed) and started 1×
            // playback underneath the filmstrip. The cursor was then moving, so no
            // slot could resolve against the refilled cache and every cell fell back
            // to its placeholder dot while the picture played on. Operator-reported
            // 2026-08-10 ("all frames in the strip disappeared"); measured as
            // lit=0/9 with cache=288f for 60 s+.
            root.paused = root.frameMode;
            root._frameModeRepause = root.frameMode;
            scanTimer.stop(); player.playbackRate = 1;
            stepper.invalidate();                       // new source: cached frames are stale
            player.source = root.client.playlistUrl(sid);
            if (typeof MemTel !== "undefined") MemTel.noteOpen();
            player.play();      // decode must start for a frame to land; _frameModeRepause parks it there
            root._ttffPending = true;      // next rendered frame completes the TTFF measurement
            if (root._pbTime) console.log("[PBTIME] source_set dt=" + (Date.now() - root._obT0)
                                          + "ms marshal=" + (Date.now() - _tReady) + "ms tag=" + root._obTag);
            // A newer far target arrived while this open was in flight (coalesced
            // clicks) and it is OUTSIDE the landed window — ONE follow-up open for
            // the newest target; every intermediate click is dropped by design.
            if (farNext >= 0 && (farNext < root.winStartMs || farNext > root.winEndMs))
                root.seekFar(farNext);
        }
        function onSessionFailed(err, tag) {
            if (tag === undefined || String(tag).indexOf(root._pcUid + ":") !== 0) return;
            root.loading = false; root.errorText = err; root._ttffPending = false;
            root._farInFlight = false; root._farLatestMs = -1;   // coalescing must not outlive a failed open
            emptyRetry.stop(); farEmptyRetry.stop();             // a real failure outranks a pending blip-retry
            if (player) player.source = "";   // we kept the old source for the swap; a failed open must clear it (rare path, not the churn hot path)
        }
        function onCamerasResolved() {
            root.tryOpen();
            if (root.camId !== "") root.client.fetchCoverage(root.camId);
        }
        function onCoverageReady(cameraId, available, retentionDays, days) {
            if (cameraId !== root.camId) return;
            root.coveragePending = !available;
            if (available && retentionDays > 0) root.retentionDays = retentionDays;
            var out = [], info = ({});
            for (var i = 0; i < days.length; i++) {
                var d = days[i];
                if (d.has_footage === undefined || d.has_footage) {
                    out.push(d.date);
                    // seconds / coverage_ratio / first are additive fields the
                    // contract already carries; the ribbon's density bar and
                    // label block read them. Absent → 0, never a guess.
                    info[d.date] = { sec: d.seconds !== undefined ? d.seconds : 0,
                                     ratio: d.coverage_ratio !== undefined ? d.coverage_ratio : 0,
                                     firstMs: d.first ? Date.parse(d.first) : -1 };
                }
            }
            root.footageDays = out;
            root.dayInfo = info;
            root._maybeLandOnNewestFootage();
        }
        // Motion episode spans (or density buckets) from /events/timeline — the
        // backend pairs motion_started↔motion_ended server-side, so no client paging.
        function onTimelineReady(cid, mode, blocks) {
            if (cid !== root.camId) return;
            if (mode === "buckets") {
                var bk = [];
                for (var i = 0; i < blocks.length; i++) {
                    var b = blocks[i];
                    bk.push({ sMs: Date.parse(b.bucket_start), eMs: Date.parse(b.bucket_end),
                              count: b.episode_count, seconds: b.motion_seconds });
                }
                root.motionBuckets = bk; root.bucketMode = true; root.motionEpisodes = [];
                return;
            }
            var eps = [];
            for (var j = 0; j < blocks.length; j++) {
                var ep = blocks[j];
                var st = Date.parse(ep.start_time);
                var en = ep.end_time ? Date.parse(ep.end_time) : Math.min(Date.now(), root.tlEndMs);
                if (en < st) { var t = st; st = en; en = t; }
                eps.push({ startMs: st, endMs: en });
            }
            if (eps.length > root.bucketThreshold) {     // very busy → bounded density buckets
                root.motionEpisodes = []; root.bucketMode = true;
                root.client.fetchTimeline(root.camId, new Date(root.tlStartMs).toISOString(),
                                          new Date(root.tlEndMs).toISOString(), 600);
                return;
            }
            eps.sort(function (a, b) { return a.startMs - b.startMs; });
            root.motionEpisodes = eps; root.bucketMode = false;
        }
    }

    // Dedicated event feed for the playback scrubber's NON-MOTION point events +
    // the aside recent list — a SEPARATE EventModel from the shared global one so
    // scoping it to this camera+window doesn't clobber the Events screen / Live
    // "recent" query. (Motion spans come from /events/timeline; see onTimelineReady.)
    EventModel { id: motionEvents }
    Connections {
        target: motionEvents
        function onChanged() { root.rebuildEvents(); }   // first page is enough for points + recent list
    }

    // Playback came back on → (re)create the playback session if we're showing
    // this screen for a camera (covers a gated open, and a session that died when
    // Playback was switched off mid-review).
    Connections {
        target: root.cameraModel
        function onFunctionsChanged() {
            if (root.visible && root.camera && root.cameraModel
                && root.cameraModel.playbackEnabled !== false) {
                root._pendingOpen = true;
                root.tryOpen();
            }
        }
    }

    // pause streams when hidden; tidy player on hide
    focus: true
    onVisibleChanged: {
        if (visible) {
            forceActiveFocus();
            // Restore the sink dropped on hide (macOS branch below) BEFORE warming
            // the PTS ring — attach order matters for frame stepping.
            if (player.videoOutput !== vout) player.videoOutput = vout;
            FrameClock.attach(vout.videoSink);  // warm the PTS ring for frame steps
        } else {
            // macOS: the scene graph releases the hidden VideoOutput's Metal texture
            // cache while stop() drains the decode pipeline asynchronously — every
            // in-flight frame then logs "cannot create texture, Metal texture cache
            // was released?" (2 planes x ~25fps for seconds, operator log 2026-08-22).
            // Detaching the sink FIRST stops frames reaching the dead cache; stop()
            // then drains silently. Linux/Windows keep the plain stop() path.
            if (Qt.platform.os === "osx") player.videoOutput = null;
            player.stop(); scanTimer.stop()
        }
    }
    // ---- keyboard (spec §3) ----------------------------------------------
    // Bindings must survive a Russian layout. Qt exposes no portable physical
    // key code (nativeScanCode means different things on X11 and Windows), so
    // every binding is declared as its Latin key PLUS the Cyrillic character the
    // SAME PHYSICAL KEY emits on ЙЦУКЕН — Qt reports those as the uppercase
    // Unicode codepoint. Matching the Latin key alone is what dies silently.
    function _key(e, latin, cyr) { return e.key === latin || e.key === cyr }
    // Every relative move goes through ONE synchronously-updated pointer.
    // playheadMs is derived from the player's position, which lands
    // asynchronously — so two `→` presses inside one tick would both read the
    // same value and the second would overwrite the first, moving 10 s for two
    // presses. It looks exactly like a dropped keypress. The anchor is read AND
    // written inside the handler; any other seek clears it (seekToWall does),
    // and it expires shortly after the last press so it re-syncs to reality.
    property double _nudgeAnchor: -1
    Timer { id: nudgeExpire; interval: 700; onTriggered: root._nudgeAnchor = -1 }
    function nudge(deltaMs) {
        if (frags.length === 0) return;
        var target = (_nudgeAnchor >= 0 ? _nudgeAnchor : playheadMs) + deltaMs;
        seekToWall(target);
        _nudgeAnchor = target;
        nudgeExpire.restart();
    }
    function rateStep(dir) {
        var i = speeds.indexOf(playSpeed);
        if (i < 0) i = speeds.indexOf(1);
        setSpeed(speeds[Math.max(0, Math.min(speeds.length - 1, i + dir))]);
    }
    Keys.onPressed: (e) => {
        // 1–5 = span; they work even with no session loaded (§5: nothing is
        // disabled that would leave the operator unable to confirm emptiness).
        if (e.key >= Qt.Key_1 && e.key <= Qt.Key_5 && !(e.modifiers & (Qt.ControlModifier | Qt.AltModifier))) {
            root.setSpan([15, 60, 360, 720, 1440][e.key - Qt.Key_1]); e.accepted = true; return;
        }
        if (root._key(e, Qt.Key_F, 0x0410) && !(e.modifiers & (Qt.ControlModifier | Qt.AltModifier)) && !e.isAutoRepeat) {
            if (e.modifiers & Qt.ShiftModifier) root.fullscreenRequested();     // advertised, so it must act
            else root.frameMode ? root.exitFrameMode() : root.enterFrameMode();
            e.accepted = true; return;
        }
        // [ and ] ENTER frame mode: gating the cells while leaving the keys
        // ungated lets a range be created that is drawn, counted, and has no
        // export control anywhere on screen.
        if (root._key(e, Qt.Key_BracketLeft, 0x0425)) { root.markIn(); e.accepted = true; return; }
        if (root._key(e, Qt.Key_BracketRight, 0x042A)) { root.markOut(); e.accepted = true; return; }
        if (root._key(e, Qt.Key_S, 0x042B) && !(e.modifiers & (Qt.ControlModifier | Qt.AltModifier))) {
            if (e.modifiers & Qt.ShiftModifier) root.snapshotStamped(); else root.snapshot();
            e.accepted = true; return;
        }
        if (root._key(e, Qt.Key_X, 0x0427) && !(e.modifiers & (Qt.ControlModifier | Qt.AltModifier))) {
            if (root.hasSelection) root.openExportDrawer();
            e.accepted = true; return;
        }
        if (root.frags.length === 0) return;
        if (e.key === Qt.Key_Space) { root.togglePlay(); e.accepted = true; }
        else if (root._key(e, Qt.Key_Comma, 0x0411)) { root.stepBackVisible(); e.accepted = true; }
        else if (root._key(e, Qt.Key_Period, 0x042E)) { if (!stepper.busy) stepper.stepForward(); e.accepted = true; }
        // J is NOT reverse shuttle: reverse playback decodes from a keyframe for
        // every delivered frame (§3.6 forbids it). J walks the rate ladder down —
        // the honest neighbour of L, and the rate cell's tooltip says so.
        else if (root._key(e, Qt.Key_J, 0x041E)) { root.rateStep(-1); e.accepted = true; }
        else if (root._key(e, Qt.Key_K, 0x041B)) { if (!root.paused) root.togglePlay(); e.accepted = true; }
        else if (root._key(e, Qt.Key_L, 0x0414)) {
            if (root.paused) root.togglePlay(); else root.rateStep(1);
            e.accepted = true;
        }
        else if (e.key === Qt.Key_Left) { root.nudge(-((e.modifiers & Qt.ShiftModifier) ? 60000 : 10000)); e.accepted = true; }
        else if (e.key === Qt.Key_Right) { root.nudge((e.modifiers & Qt.ShiftModifier) ? 60000 : 10000); e.accepted = true; }
    }

    // ---- frame-by-frame MODE (F): filmstrip UI + hold-to-shuttle arrows ----------
    // The bottom toolbar row swaps for a big-thumbnail filmstrip (current frame
    // centered/accented); ←/→ step one frame and, held, ramp from slow to fast.
    property bool frameMode: false
    function enterFrameMode() {
        if (frags.length === 0 || !stepper.ready) return;
        // Entering pauses and returns the rate to 1× — stepping frames at 50×
        // is not a thing (spec §2.4).
        paused = true; playSpeed = 1; ladderOpen = false; applyTransport();
        FrameClock.attach(vout.videoSink);
        FrameCache.attach(vout.videoSink);
        FrameCache.captureCurrent();   // the shown frame IS the strip's center tile — instantly
        frameMode = true;      // the harvester activates off this and fills the strip
    }
    function exitFrameMode() {
        frameMode = false;
        clearMark();       // leaving the mode clears the range, as part of leaving
        rampStop();
    }
    // Map a cached frame's PTS to a wall clock with milliseconds (filmstrip labels).
    function frameClockOf(pts) {
        var wall = posToWall((pts + stepper.anchorOffMs) / 1000);
        return fmtClock(wall) + "." + String(Math.floor(wall % 1000)).padStart(3, "0");
    }
    // Hold-to-shuttle ramp: first step immediate, then accelerating cadence
    // 400→66 ms (×0.85 per step) — a held arrow grows from careful single steps
    // into a fast scrub. Backward rides the cache (instant); forward flushes
    // (~60–130 ms) naturally cap near the ramp floor.
    property int _rampDir: 0
    property real _rampIv: 400
    function rampStart(dir) {
        if (rampT.running && _rampDir === dir) return;
        _rampDir = dir; _rampIv = 400;
        _rampStep();
        rampT.interval = _rampIv; rampT.restart();
    }
    function rampStop() { _rampDir = 0; rampT.stop(); }
    function _rampStep() {
        if (_rampDir > 0) stepper.stepForward();
        else if (_rampDir < 0) stepper.stepBackward();
    }
    Timer {
        id: rampT; repeat: true
        onTriggered: {
            if (root._rampDir === 0) { stop(); return; }
            root._rampStep();
            root._rampIv = Math.max(66, root._rampIv * 0.85);
            interval = root._rampIv;
        }
    }
    Timer {                    // dev/test hook: WT_FRAME_MODE auto-enters once footage renders
        interval: 500; repeat: true
        running: (typeof wtFrameMode !== "undefined") && wtFrameMode && !root.frameMode
        onTriggered: if (root._frameSeq > 8 && root.frags.length > 0) root.enterFrameMode()
    }
    // Dev/verification hooks for the redesign's interaction-only surfaces, so a
    // screenshot can show them instead of a prose claim. They drive the REAL
    // controls (the ladder's own flag, the real mark functions) — no fake data,
    // no state the operator could not reach by hand. Inert unless set.
    Timer {
        id: pbDemoT
        interval: 600; repeat: true
        running: ((typeof wtPbLadder !== "undefined" && wtPbLadder)
                  || (typeof wtPbMark !== "undefined" && wtPbMark)) && !_pbDemoDone
        onTriggered: {
            if (root._frameSeq <= 8 || root.frags.length === 0) return;
            root._pbDemoDone = true;
            if (typeof wtPbMark !== "undefined" && wtPbMark) {
                var p = root.playheadMs;
                root.markIn();
                root.selEndMs = p + 252000;      // [ then ] four minutes later
            }
            if (typeof wtPbLadder !== "undefined" && wtPbLadder) root.ladderOpen = true;
        }
    }
    property bool _pbDemoDone: false

    // ===== filmstrip-blank investigation (WT_TRACE) =========================
    // The strip empties when EITHER FrameClock.lastPtsMs goes <= 0 (every slot
    // resolves off it) OR the cache empties. Sample both, plus everything that
    // could drive them, so the ORDER of events is readable rather than guessed.
    function _xt(s) {
        if (typeof wtTrace !== "undefined" && wtTrace)
            console.log("[STRIP] " + s + " t=" + Date.now());
    }
    Timer {
        interval: 300; repeat: true
        running: (typeof wtTrace !== "undefined") && wtTrace && root.frameMode
        onTriggered: {
            var lit = 0;
            for (var i = 0; i < 9; i++) if (frameStripItem.ptsForIndex(i) >= 0) lit++;   // pts 0 counts
            root._xt("strip lit=" + lit + "/9"
                     + " pts=" + FrameClock.lastPtsMs.toFixed(0)
                     + " cache=" + FrameCache.frames + "f rev=" + FrameCache.rev
                     + " loading=" + root.loading + " frags=" + root.frags.length
                     + " harv=" + harvester.active + "/" + harvester.prearm
                     + " paused=" + root.paused + " pstate=" + player.playbackState
                     + " drawer=" + exportDrawer.visible + " vis=" + root.visible);
        }
    }
    // Dev hook: WT_PB_EXPORT drives the REAL export controls once a range is
    // marked and frame mode is up. 1 = open the drawer only (NO backend write);
    // 2 = open and confirm (ONE real export job on the live backend).
    Timer {
        id: xExport
        interval: 900; repeat: true
        property int fired: 0
        running: (typeof wtPbExport !== "undefined") && wtPbExport > 0 && fired < 2
        onTriggered: {
            if (!root.frameMode || !root.hasSelection || root.loading) return;
            if (fired === 0 && wtPbExport >= 3) {    // re-open / play probes: no drawer in the way
                fired = 1; interval = 6000; return;
            }
            if (fired === 0) {
                // match the operator's report exactly, and keep the live write tiny
                root.selEndMs = root.selStartMs + 10000;
                root._xt("HOOK openExportDrawer (marked "
                         + Math.round((root.selEndMs - root.selStartMs) / 1000) + "s)");
                root.openExportDrawer();
                fired = 1;
                interval = 2500;      // let the strip settle before the write
                return;
            }
            fired = 2;
            if (wtPbExport === 3) {          // no export: force a session re-open in frame mode
                var far = root.playheadMs + 25 * 60000;
                root._xt("HOOK far seek → session re-open (frameMode=" + root.frameMode + ")");
                root.seekToWall(far);
                return;
            }
            if (wtPbExport === 4) {          // no export: press play while frame mode is on
                root._xt("HOOK play under frameMode=" + root.frameMode);
                root.togglePlay();
                return;
            }
            if (wtPbExport < 2) { root._xt("HOOK stop (drawer-only run)"); return; }
            root._xt("HOOK confirm export → ONE real job");
            exportDrawer.confirming = true;
            exportDrawer.confirmed(exportDrawer.startMs, exportDrawer.endMs, exportDrawer.mode,
                                   exportDrawer.effectivePurpose, exportDrawer.effectiveQuality,
                                   exportDrawer.effectiveCompHeight, exportDrawer.overlayTs,
                                   exportDrawer.overlayName);
            exportDrawer.close();
        }
    }

    // Shift+←/→ = ±5 frames (the Premiere "step many" convention, research §5): a burst
    // of single steps chained on the stepper's completion — the busy-guard stays intact
    // and any failure (edge/timeout) cancels the remainder.
    property int _burstLeft: 0
    property int _burstDir: 0
    function stepBurst(dir, n) {
        if (stepper.busy) return;
        _burstDir = dir; _burstLeft = n - 1;
        if (!(dir > 0 ? stepper.stepForward() : stepper.stepBackward())) _burstLeft = 0;
    }
    Connections {
        target: stepper
        function onStepped(dir, ptsDeltaMs, latMs, retries) {
            if (root._burstLeft <= 0) return;
            root._burstLeft--;
            if (!(root._burstDir > 0 ? stepper.stepForward() : stepper.stepBackward())) root._burstLeft = 0;
        }
        function onStepFailed(dir, reason) { root._burstLeft = 0; }
    }

    // Single-frame stepping (docs/plans/2026-07-08-frame-step-plan.md P1+P2). The busy-guard
    // inside drops auto-repeat overflow; requestPause routes through the transport so the
    // scan timer / speed machinery stay consistent with the paused state. Edge/boundary
    // steps route into seekToWall (the far/re-open machinery).
    // A frame stepped-to before its async full-res encode landed was painted
    // from its thumbnail — upgrade it in place the moment the full JPEG exists.
    Connections {
        target: FrameCache
        enabled: root.frameMode
        function onFullResReady(pts) {
            if (Math.abs(FrameClock.lastPtsMs - pts) <= 2)
                FrameCache.repaint(pts, 5);
        }
    }
    FrameStepper {
        id: stepper
        mediaPlayer: player
        videoSink: vout.videoSink
        requestPause: function() { if (!root.paused) { root.paused = true; root.applyTransport(); } }
        crossesDisc: function(fromMs, toMs) { return root._crossesBoundary(fromMs / 1000, toMs / 1000); }
        edgeFallback: function(dir) {
            var dur = Math.max(40, FrameClock.medianFrameDurMs > 1 ? FrameClock.medianFrameDurMs : 50);
            var target = root.playheadMs + dir * dur;
            // At the absolute head/tail of footage there is nowhere to go — leave the
            // shown frame and the filmstrip intact instead of issuing a no-op seek
            // (which used to wipe the strip; operator-reported 2026-07-09).
            if (dir < 0 && target <= root.tlStartMs + 40) return;
            if (dir > 0 && target >= root.tlEndMs - 40) return;
            root.seekToWall(target);
        }
        veilGrab: function() {
            vout.grabToImage(function(res) { root._veilRes = res; veilImg.source = res.url; });
        }
    }
    property var _veilRes: null   // keeps the grab result alive while the veil shows it
    // Hidden second decoder: keeps the frame cache filled around the operator's
    // position while frame mode is on, so steps and strip slots are always
    // cache-served (docs/plans/2026-07-08-frame-step-plan.md — filmstrip v2).
    FrameHarvester {
        id: harvester
        source: player.source
        // Pre-arm (load the playlist, stay paused) as soon as a session is up: the
        // manifest+probe cost (~0.5-1.5 s) is paid BEFORE the operator presses F,
        // so the filmstrip fills in hundreds of ms, not seconds (fsoak strip_ms
        // p95 finding, 2026-07-10). Decode still only runs in frame mode.
        prearm: root.visible && root.frags.length > 0 && !root.loading
        // loading-gated: during session swaps the fragment list flaps empty — the
        // harvester pauses instead of tearing down (churn-safe either way, but no
        // point burning decode on a session that's being replaced).
        active: root.frameMode && root.frags.length > 0 && !root.loading
        userPts: FrameClock.lastPtsMs
        anchorOffMs: stepper.anchorOffMs
        mainPosMs: player.position
        frameDurMs: FrameClock.medianFrameDurMs > 1 ? FrameClock.medianFrameDurMs : 50
        crossesDisc: function(fromMs, toMs) { return root._crossesBoundary(fromMs / 1000, toMs / 1000); }
    }

    // While the shown frame comes from the cache, the player's position is parked
    // elsewhere — drive the playhead marker from the stepper's cursor instead.
    Connections {
        target: stepper
        function onStepped(dir, ptsDeltaMs, latMs, retries) {
            if (stepper.diverged) {
                root._smoothMs = Math.max(0, stepper.cursorPosEstMs);
                root._scanPos = root._smoothMs;
            }
        }
    }

    // Drives the playhead during high-speed scan (playSpeed > maxDecodeRate):
    // accumulate rate×interval ms of footage per tick and seek there; stop at the
    // end of footage. The player stays playing so frames render between jumps.
    Timer {
        id: scanTimer
        interval: 200; repeat: true
        onTriggered: {
            if (root.playSpeed <= root.maxDecodeRate || root.frags.length === 0) { stop(); return; }
            if (root._scanPos < 0) root._scanPos = player.position;
            root._scanPos += root.playSpeed * interval;        // ms of footage advanced per tick
            var endMs = Math.max(0, (root.compactDuration - 0.4) * 1000);
            if (root.compactDuration > 0 && root._scanPos >= endMs) {
                player.position = Math.round(endMs);
                root.playSpeed = 1; root.paused = true; root.applyTransport();   // reached the end
                return;
            }
            player.position = Math.round(root._scanPos);
        }
    }

    // ---- P0 frame-step spike (WT_STEPSPIKE=<D-phase reps>) ------------------------------------
    // Measures, on the REAL playback path, the unknowns that gate the frame-step design
    // (docs/plans/2026-07-08-frame-step-plan.md §P0): (A) QVideoFrame PTS validity + cadence,
    // (B) whether a paused seek renders, (C) seek landing accuracy at sub-frame offsets,
    // (D) forward play→pause-on-first-frame advance/overshoot + latency. Logs [SPIKE] lines
    // and quits. Inert unless WT_STEPSPIKE is set.
    Item {
        id: spike
        visible: false
        readonly property bool on: (typeof wtStepSpike !== "undefined") && wtStepSpike > 0
        property string phase: "idle"      // idle → cruise → pausedSeek → landing → flush → done
        property int rep: 0
        property int subIdx: 0
        readonly property var landingDeltas: [25, 50, 75, 250]   // ms; ½/1/1.5/5 frames at 20fps
        property double ptsBefore: -1
        property double posBefore: -1
        property int seqBefore: -1
        property bool waitFlush: false     // pause on the NEXT rendered frame
        property double tCmd: 0
        property var flushAdv: []          // D: frames advanced per rep
        property var flushPts: []          // D: pts advance per rep (ms)
        property var flushLat: []          // D: latency per rep (ms)
        readonly property int flushReps: (typeof wtStepSpike !== "undefined" && wtStepSpike > 1) ? wtStepSpike : 100

        function slog(s) { console.log("[SPIKE] " + s); }

        Timer {                            // arm once footage is open and rendering
            interval: 300; repeat: true
            running: spike.on && spike.phase === "idle"
            onTriggered: if (root._frameSeq > 8 && root.frags.length > 0) spike.start()
        }
        function start() {
            FrameClock.attach(vout.videoSink);
            phase = "cruise";
            root.paused = false; root.applyTransport();
            spike.slog("START frags=" + root.frags.length + " qt=" + wtQtRuntime);
            cruiseT.start();
        }
        Timer { id: cruiseT; interval: 6000; onTriggered: spike.phaseB() }

        function phaseB() {
            slog("A frames=" + FrameClock.frameCount + " validPts=" + FrameClock.validPts
                 + " invalidPts=" + FrameClock.invalidPts
                 + " medianFrameDurMs=" + FrameClock.medianFrameDurMs.toFixed(1)
                 + " lastPtsMs=" + FrameClock.lastPtsMs.toFixed(1) + " posMs=" + player.position);
            phase = "pausedSeek"; rep = 0;
            root.paused = true; player.pause();
            settleT.restart();
        }
        Timer { id: settleT; interval: 700; onTriggered: spike.tick() }

        function tick() {
            if (phase === "pausedSeek") {
                if (rep >= 3) { phaseC(); return; }
                seqBefore = root._frameSeq;
                player.position = Math.max(0, player.position - 2000);
                rep++;
                judgeT.restart();
            } else if (phase === "landing") {
                if (subIdx >= landingDeltas.length) { phaseD(); return; }
                if (rep >= 5) { rep = 0; subIdx++; tick(); return; }
                ptsBefore = FrameClock.lastPtsMs; posBefore = player.position;
                player.position = Math.max(0, posBefore - landingDeltas[subIdx]);
                waitFlush = true; tCmd = Date.now();
                player.play();             // flush — the first rendered frame is the landing
                rep++;
            } else if (phase === "flush") {
                if (rep >= flushReps) { finish(); return; }
                ptsBefore = FrameClock.lastPtsMs; seqBefore = root._frameSeq;
                waitFlush = true; tCmd = Date.now();
                player.play();
                rep++;
            }
        }
        Timer {                            // B: did the paused seek paint anything?
            id: judgeT; interval: 1500
            onTriggered: {
                if (spike.phase !== "pausedSeek") return;
                spike.slog("B rep=" + spike.rep + " paused_seek_rendered=" + (root._frameSeq > spike.seqBefore)
                           + " framesDelta=" + (root._frameSeq - spike.seqBefore) + " posMs=" + player.position);
                spike.tick();
            }
        }
        function phaseC() {
            phase = "landing"; rep = 0; subIdx = 0;
            slog("C landing-accuracy deltas=" + JSON.stringify(landingDeltas) + " x5 each");
            tick();
        }
        function phaseD() {
            phase = "flush"; rep = 0;
            slog("D forward-flush x" + flushReps);
            tick();
        }
        Connections {                      // C/D: first frame after play() → freeze + measure
            target: vout.videoSink
            enabled: spike.on && spike.waitFlush
            function onVideoFrameChanged() {
                if (!spike.waitFlush) return;
                spike.waitFlush = false;
                player.pause();
                measureT.restart();
            }
        }
        Timer {
            id: measureT; interval: 300    // let pause take hold; then read the FINAL displayed frame
            onTriggered: {
                if (spike.phase === "landing") {
                    spike.slog("C d=" + spike.landingDeltas[spike.subIdx] + " rep=" + spike.rep
                               + " ptsDeltaMs=" + (FrameClock.lastPtsMs - spike.ptsBefore).toFixed(1)
                               + " posDeltaMs=" + (player.position - spike.posBefore)
                               + " latMs=" + (Date.now() - spike.tCmd));
                    spike.tick();
                } else if (spike.phase === "flush") {
                    spike.flushAdv.push(root._frameSeq - spike.seqBefore);
                    spike.flushPts.push(FrameClock.lastPtsMs - spike.ptsBefore);
                    spike.flushLat.push(Date.now() - spike.tCmd);
                    if (spike.rep % 20 === 0)
                        spike.slog("D rep=" + spike.rep + "/" + spike.flushReps);
                    spike.tick();
                }
            }
        }
        function finish() {
            var h = ({}); var i;
            for (i = 0; i < flushAdv.length; i++) h[flushAdv[i]] = (h[flushAdv[i]] || 0) + 1;
            var hp = ({});
            for (i = 0; i < flushPts.length; i++) {
                var b = Math.round(flushPts[i] / 25) * 25;   // bucket pts-advance to 25ms
                hp[b] = (hp[b] || 0) + 1;
            }
            var lat = flushLat.slice().sort(function(a, b) { return a - b; });
            slog("D-SUMMARY advHist=" + JSON.stringify(h) + " ptsAdvHist=" + JSON.stringify(hp)
                 + " latP50=" + lat[Math.floor(lat.length * 0.5)]
                 + " latP95=" + lat[Math.floor(lat.length * 0.95)] + " n=" + lat.length);
            slog("PTS-SUMMARY valid=" + FrameClock.validPts + " invalid=" + FrameClock.invalidPts
                 + " medianFrameDurMs=" + FrameClock.medianFrameDurMs.toFixed(1));
            slog("DONE");
            Qt.quit();
        }
    }

    // ---- WT_STEPTEST=<N>: FrameStepper alternating soak (P2 acceptance). Alternating
    // blocks of 10 forward / 12 backward until ~N steps — the net 2-frame backward drift
    // per cycle pushes below the cache bottom so every path gets exercised (cache hits,
    // direct seeks, overseek+walk refills). Asserts step direction per step, tallies the
    // path histogram + per-direction latency percentiles; [STEPT] lines; quits. Inert
    // unless set.
    Item {
        id: stepTest
        readonly property bool on: (typeof wtStepTest !== "undefined") && wtStepTest !== 0
        readonly property int total: on ? Math.abs(wtStepTest) : 0
        property int done: 0
        property int inBlock: 0
        property bool backBlock: false     // start forward (warm the cache going up)
        property int wrongWay: 0           // fwd steps that didn't move fwd / back that didn't move back
        property int fails: 0
        property var fwdLats: []
        property var backLats: []
        property var paths: ({})

        Timer {                            // arm when footage renders; pause first for a clean baseline
            interval: 400; repeat: true
            running: stepTest.on && stepTest.done === 0 && root._frameSeq > 8 && root.frags.length > 0
            onTriggered: {
                running = false;
                root.paused = true; root.applyTransport();
                console.log("[STEPT] START total=" + stepTest.total + " pattern=10fwd/12back qt=" + wtQtRuntime);
                kick.start();
            }
        }
        Timer { id: kick; interval: 250; onTriggered: stepTest.next() }

        function next() {
            if (done >= total) { finish(); return; }
            // Negative WT_STEPTEST = pure backward run of |N| steps (repro tooling).
            if ((typeof wtStepTest !== "undefined") && wtStepTest < 0) { inBlock++; stepper.stepBackward(); return; }
            var blockLen = backBlock ? 12 : 10;
            if (inBlock >= blockLen) { backBlock = !backBlock; inBlock = 0; }
            inBlock++;
            if (backBlock) stepper.stepBackward(); else stepper.stepForward();
        }

        Connections {
            target: stepper
            enabled: stepTest.on
            function onStepped(dir, ptsDeltaMs, latMs, retries) {
                stepTest.done++;
                stepTest.paths[stepper.lastPath] = (stepTest.paths[stepper.lastPath] || 0) + 1;
                if (dir > 0) { stepTest.fwdLats.push(latMs); if (ptsDeltaMs <= 0.5) stepTest.wrongWay++; }
                else { stepTest.backLats.push(latMs); if (ptsDeltaMs >= -0.5) stepTest.wrongWay++; }
                if (stepTest.done % 25 === 0)
                    console.log("[STEPT] " + stepTest.done + "/" + stepTest.total
                                + " cache=" + FrameCache.frames + "f/" + FrameCache.bytesMB.toFixed(1) + "MB");
                stepTest.next();
            }
            function onStepFailed(dir, reason) {
                stepTest.done++;
                stepTest.fails++;
                console.log("[STEPT] FAIL dir=" + dir + " reason=" + reason + " at " + stepTest.done);
                if (stepTest.fails > 8) { stepTest.finish(); return; }
                stepTest.next();
            }
        }
        function pct(a, p) {
            if (!a.length) return -1;
            var s = a.slice().sort(function(x, y) { return x - y; });
            return s[Math.floor(s.length * p)];
        }
        function finish() {
            console.log("[STEPT] SUMMARY steps=" + done + " wrongWay=" + wrongWay + " fails=" + fails
                        + " paths=" + JSON.stringify(paths)
                        + " fwd(n=" + fwdLats.length + " p50=" + pct(fwdLats, 0.5) + " p95=" + pct(fwdLats, 0.95) + ")"
                        + " back(n=" + backLats.length + " p50=" + pct(backLats, 0.5) + " p95=" + pct(backLats, 0.95) + ")"
                        + " cache=" + FrameCache.frames + "f/" + FrameCache.bytesMB.toFixed(1) + "MB");
            console.log("[STEPT] DONE");
            Qt.quit();
        }
    }

    // ---- WT_CHURNTEST=<N>: session-churn soak (P0 2026-07-10 segfault repro). With
    // frame mode held active (pair with WT_FRAME_MODE=1), alternates openForDay between
    // the boot day (WT_PLAYBACK_DAY — use a gappy motion day) and WT_CHURN_ALT (a
    // continuous day) every 4.5 s, with a mid-session fragment click 2.6 s after each
    // switch — the operator gesture that crashed 2026-07-10: the harvester is mid-fill
    // (often stalled on a kept discontinuity) when the session churns under it. Pass =
    // all switches survived, frames still rendering, fragments loaded. Inert unless set.
    Item {
        id: churnTest
        readonly property bool on: (typeof wtChurnTest !== "undefined") && wtChurnTest > 0
        readonly property string baseDay: (typeof wtPlaybackDay !== "undefined") && wtPlaybackDay !== "" ? wtPlaybackDay.split("T")[0] : ""
        readonly property string altDay: (typeof wtChurnAlt !== "undefined") ? wtChurnAlt : ""
        property int done: 0
        property bool toAlt: true

        Timer {                        // arm once the first session actually renders
            interval: 400; repeat: true
            running: churnTest.on && churnTest.done === 0 && !switchT.running
                     && root._frameSeq > 8 && root.frags.length > 0
            onTriggered: {
                running = false;
                console.log("[CHURN] START switches=" + wtChurnTest + " base=" + churnTest.baseDay
                            + " alt=" + churnTest.altDay + " qt=" + wtQtRuntime);
                switchT.start();
            }
        }
        Timer {
            id: switchT
            interval: 4500; repeat: true
            onTriggered: {
                if (churnTest.done >= wtChurnTest) { stop(); churnSettleT.start(); return; }
                var d = churnTest.toAlt ? churnTest.altDay : churnTest.baseDay;
                churnTest.toAlt = !churnTest.toAlt;
                churnTest.done++;
                console.log("[CHURN] " + churnTest.done + "/" + wtChurnTest + " openForDay " + d
                            + " (frameMode=" + root.frameMode + " frags=" + root.frags.length
                            + " cache=" + FrameCache.frames + "f harv=" + harvester.mode + ")");
                root.openForDay(d);
                poke.restart();
            }
        }
        Timer {                        // the "clicked another fragment" poke, mid-fill
            id: poke
            interval: 2600
            onTriggered: {
                if (churnTest.done > 0 && churnTest.done <= wtChurnTest && root.frags.length > 3) {
                    var k = (churnTest.done * 7) % root.frags.length;
                    console.log("[CHURN] poke frag#" + k + " (of " + root.frags.length + ")");
                    root.seekToWall(root.frags[k].ws + 300);   // rows are objects, not arrays
                }
            }
        }
        Timer {
            id: churnSettleT
            interval: 12000          // final poke's re-open + harvester refill must land
            onTriggered: {
                // PASS = the final (gappy) day is fully alive: fragments loaded, frames
                // rendered, and the harvester actually cached strip content — the exact
                // "blank filmstrip on today's footage" symptom from the P0 report.
                var pass = root.frags.length > 0 && root._frameSeq > 8 && FrameCache.frames > 0;
                console.log("[CHURN] SUMMARY switches=" + churnTest.done + " frags=" + root.frags.length
                            + " frameSeq=" + root._frameSeq + " frameMode=" + root.frameMode
                            + " cache=" + FrameCache.frames + "f/" + FrameCache.bytesMB.toFixed(1) + "MB"
                            + " harv=" + harvester.mode + " -> " + (pass ? qsTr("PASS") : qsTr("FAIL")));
                console.log("[CHURN] DONE");
                Qt.quit();
            }
        }
    }

    // ======================================================================
    // "ONE AXIS" — the 2026-08-09 redesign (designs/handoff-playback/).
    //
    // The calendar and the zoom buttons were not two navigators; they were one
    // axis at two scales. So there is now ONE navigator in two tiers sharing a
    // horizontal time axis — a 35-day archive ribbon over the loaded window's
    // FOOTAGE/MOTION lanes, with an amber bracket in the selected day cell
    // showing where the window sits. The info rail is dissolved: five of its
    // seven blocks were duplicates of the picture or restatements of a control;
    // `Coverage` is promoted onto the navigator header beside the lanes it
    // describes, and `Last motion` became the jump it always was.
    // ======================================================================

    // ---- archive ribbon data ---------------------------------------------
    // Per-day totals from GET /review/coverage. `days[]` carries
    // {date, has_footage, seconds, coverage_ratio, first, last}; there is no
    // per-day SEGMENT count in the contract, so the ribbon's label block states
    // the day's duration and (when the day is loaded) its real segment count —
    // never an invented one.
    property var dayInfo: ({})            // "yyyy-MM-dd" → {sec, ratio, firstMs}
    function _dayMs(key) { var d = new Date(key + "T00:00:00"); return d.getTime() }

    readonly property var ribbonDays: {
        var n = Math.max(1, Math.min(120, retentionDays));
        var t0 = new Date(); t0.setHours(0, 0, 0, 0);
        var out = [];
        for (var i = n - 1; i >= 0; i--) {
            var d = new Date(t0.getTime()); d.setDate(t0.getDate() - i); d.setHours(0, 0, 0, 0);
            var key = Qt.formatDate(d, "yyyy-MM-dd");
            var inf = dayInfo[key];
            out.push({ ms: d.getTime(), key: key, has: !!inf,
                       sec: inf ? inf.sec : 0, today: i === 0 });
        }
        return out;
    }
    readonly property bool archiveEmpty: {
        if (coveragePending) return false;               // unknown is never rendered as empty
        for (var i = 0; i < ribbonDays.length; i++) if (ribbonDays[i].has) return false;
        return true;
    }
    // The ribbon always highlights the day the playhead is in, whether it got
    // there from a day click or from a rolling window.
    readonly property string selDayKey: selectedDay !== "" ? selectedDay
        : (frags.length > 0 ? Qt.formatDate(new Date(playheadMs), "yyyy-MM-dd")
                            : Qt.formatDate(new Date(), "yyyy-MM-dd"))
    readonly property double _selDay0: _dayMs(selDayKey)
    readonly property real selDaySec: dayInfo[selDayKey] ? dayInfo[selDayKey].sec : 0
    // The day's own segment count is honest only when the loaded window IS that
    // whole day; otherwise the label block states duration alone.
    // The day's own segment count is honest only when the loaded timeline spans
    // that whole day; on a 1H window the count would be the window's, not the
    // day's, and the block claims to state the day.
    readonly property int selDayClips: {
        if (selectedDay === "" || tlEndMs <= tlStartMs) return -1;
        var dayEnd = Math.min(_selDay0 + 86400000, Date.now());
        return (tlStartMs <= _selDay0 + 60000 && tlEndMs >= dayEnd - 60000) ? tlFrags.length : -1;
    }
    // Where tier 2's window sits inside the selected day cell (fractions 0..1).
    readonly property real winFracA: {
        if (!(viewEndMs > viewStartMs)) return -1;
        var a = (viewStartMs - _selDay0) / 86400000;
        return (a > 1 || (viewEndMs - _selDay0) / 86400000 < 0) ? -1 : Math.max(0, Math.min(1, a));
    }
    readonly property real winFracB: {
        if (winFracA < 0) return -1;
        return Math.max(winFracA, Math.min(1, (viewEndMs - _selDay0) / 86400000));
    }

    // ---- coverage readout (promoted onto the navigator header) -----------
    readonly property var _cov: {
        var s = viewStartMs, e = viewEndMs, n = 0, tot = 0;
        if (!(e > s)) return { n: 0, pct: 0 };
        for (var i = 0; i < tlFrags.length; i++) {
            var f = tlFrags[i];
            if (f.we <= s || f.ws >= e) continue;
            n++; tot += Math.min(f.we, e) - Math.max(f.ws, s);
        }
        return { n: n, pct: Math.round(tot / (e - s) * 100) };
    }

    // ---- ONE selection model for the lane and the list -------------------
    // Both are built from the same array, so there is no state in which they
    // can disagree (spec §2.6, brief problem 5).
    readonly property bool showMotionLane: Settings.eventsOnScrubber
    readonly property var winItems: {
        var s = viewStartMs, e = viewEndMs, out = [];
        if (!(e > s)) return out;
        if (!typeHidden("motion")) {
            var eps = motionEpisodes;
            for (var i = 0; i < eps.length && out.length < 1500; i++) {
                var ep = eps[i];
                if (ep.endMs < s || ep.startMs > e) continue;
                out.push({ id: "m" + ep.startMs, ms: ep.startMs,
                           len: Math.max(0, ep.endMs - ep.startMs), type: "motion",
                           label: EventStyle.label("motion"), color: Theme.accent });
            }
        }
        var pts = pointEvents;
        for (var j = 0; j < pts.length && out.length < 1800; j++) {
            var p = pts[j];
            if (p.ms < s || p.ms > e || typeHidden(p.type)) continue;
            // Operator rule (2026-08-21): a confirmed detection inside a motion span is
            // the SAME fact to a guard — one movement, one row. The span row carries it;
            // the detection only stands alone when no displayed span contains it (span
            // outside the fetched window, or the Motion chip hiding spans — hiding spans
            // must surface incidents again, never silently drop them).
            if (p.type === "motion_detected" && !typeHidden("motion")
                    && _insideEpisode(p.ms)) continue;
            out.push({ id: "p" + p.ms + "_" + p.type, ms: p.ms, len: 0, type: p.type,
                       label: EventStyle.label(p.type), color: EventStyle.color(p.type) });
        }
        out.sort(function (a, b) { return a.ms - b.ms; });
        return out;
    }
    function _insideEpisode(ms) {
        var eps = motionEpisodes;   // ±2s pad: detected stamps ride the span edge
        for (var i = 0; i < eps.length; i++)
            if (ms >= eps[i].startMs - 2000 && ms <= eps[i].endMs + 2000) return true;
        return false;
    }
    readonly property var winItemsNewest: {
        var a = winItems.slice(); a.reverse(); return a;
    }
    // Events in the window BEFORE the type chips — so the empty state can name
    // its filter instead of claiming there is nothing here.
    readonly property int winItemsUnfiltered: {
        var s = viewStartMs, e = viewEndMs, n = 0;
        if (!(e > s)) return 0;
        for (var i = 0; i < motionEpisodes.length; i++) {
            var ep = motionEpisodes[i];
            if (ep.endMs >= s && ep.startMs <= e) n++;
        }
        for (var j = 0; j < pointEvents.length; j++) {
            var p = pointEvents[j];
            if (p.ms < s || p.ms > e) continue;
            // mirror winItems' span-absorption, else the empty state promises more
            // rows than un-hiding the chips would actually reveal
            if (p.type === "motion_detected" && _insideEpisode(p.ms)) continue;
            n++;
        }
        return n;
    }
    readonly property var typeChips: {
        var out = [];
        for (var i = 0; i < eventTypesPresent.length; i++) {
            var k = eventTypesPresent[i];
            out.push({ key: k, label: EventStyle.label(k === "motion" ? "motion" : k),
                       color: EventStyle.color(k), on: !typeHidden(k) });
        }
        return out;
    }
    property string hoverId: ""
    property string selId: ""
    function pickItem(id, ms) { selId = id; seekToWall(ms); }

    readonly property double lastMotionMs: eventsModel
        ? (eventsModel.motionRev, eventsModel.lastMotionAtMs(camId)) : -1

    // ---- marked range = the export selection (spec §2.7) -----------------
    readonly property double markMs: hasSelection ? (selEndMs - selStartMs) : -1
    function markIn() {
        if (!frameMode) enterFrameMode();
        var p = playheadMs;
        selStartMs = p;
        if (!(selEndMs > p)) selEndMs = p + 30000;
    }
    function markOut() {
        if (!frameMode) enterFrameMode();
        var p = playheadMs;
        selEndMs = p;
        if (!(selStartMs >= 0 && selStartMs < p)) selStartMs = Math.max(0, p - 30000);
    }
    function clearMark() { selStartMs = -1; selEndMs = -1 }

    // ---- resizable navigator + rail (spec §2.2b) -------------------------
    // NAV_MIN is derived from the lane floor, not stated twice: 83 fixed chrome
    // (ribbon 42 + header 26 + ruler 15) + LANE_MIN 18. Given as two independent
    // numbers they disagree at the extreme and the lanes overflow the container.
    readonly property int navFixed: 83
    readonly property int laneMin: 18
    readonly property int navMin: navFixed + laneMin
    readonly property int navDefault: navFixed + 32
    property real navH: Settings.pbNavH
    property real panelW: Settings.pbPanelW
    property bool railOpen: Settings.pbEventsPanel
    readonly property real laneH: Math.max(laneMin, navH - navFixed)
    // A drag writes a QSettings key on every pointer move otherwise.
    Timer {
        id: prefSave; interval: 400
        onTriggered: { Settings.pbNavH = Math.round(root.navH); Settings.pbPanelW = Math.round(root.panelW) }
    }
    readonly property int footageLaneH: showMotionLane ? Math.max(8, Math.round(laneH * 14 / 32)) : laneH
    readonly property int motionLaneH: showMotionLane ? (laneH - footageLaneH) : 0

    // ---- transport / mode state ------------------------------------------
    property bool ladderOpen: false
    property bool fullscreenOn: false          // bound to the shell's fullscreen by Main.qml
    property bool backFetching: false          // the backward step's cache fetch, made visible
    Timer { id: backFetchT; interval: 340; onTriggered: root.backFetching = false }
    function stepBackVisible() {
        if (stepper.busy) return;              // key-repeat is rate-limited to the cache refill
        backFetching = true; backFetchT.restart();
        stepper.stepBackward();
    }

    // ---- honest states (spec §4) -----------------------------------------
    readonly property bool stPlaybackOff: cameraModel ? (cameraModel.playbackEnabled === false) : false
    // "No footage …" is not a session failure — it is the archive telling the
    // truth about a gap, and it gets the FOOTAGE banner with its nearest-footage
    // offer rather than an ERROR tag and a Retry that would retry nothing.
    readonly property bool _errEmptyRange: errorText.indexOf("No footage") === 0
    readonly property bool stSessionError: errorText !== "" && !_errEmptyRange && !stPlaybackOff
    readonly property bool stRecOff: cameraModel ? (cameraModel.recordingEnabled === false) : false
    readonly property bool stOffline: camera ? (camera.live === CameraStatus.Offline) : false
    // Only playbackOff and sessionError block. `recordingOff` and `offline` are
    // facts about the LIVE stream and about the future, not about the archive —
    // a camera that dropped an hour ago still has a complete, playable archive.
    readonly property bool blocked: stPlaybackOff || stSessionError
    readonly property bool inFootage: frags.length > 0 && msInFootage(playheadMs)
    readonly property bool stNoFootageHere: !blocked && !archiveEmpty && !loading
                                            && (_errEmptyRange || (tlFrags.length > 0 && !inFootage))
    readonly property double nearestFootageMs: {
        var f = tlFrags.length ? tlFrags : frags;
        if (!f.length) return -1;
        var ph = playheadMs, best = -1, bd = Infinity;
        for (var i = 0; i < f.length; i++) {
            if (ph >= f[i].ws && ph <= f[i].we) return -1;
            var head = ph < f[i].ws;
            var d = head ? f[i].ws - ph : ph - f[i].we;
            if (d < bd) { bd = d; best = head ? f[i].ws + 500 : Math.max(f[i].ws, f[i].we - 3000); }
        }
        return best;
    }

    // ---- day selection: the SPAN is the operator's -----------------------
    // Picking a day moves the day and the playhead, and nothing else. An earlier
    // build forced 24H on every day click while first paint opened at 1H, so the
    // same day showed a 1H slice on arrival and a 24H sweep after a day-hop and
    // back — 24× the window with no visible cause, which operators read as the
    // archive changing under them.
    function selectDay(key) {
        if (!camera || key === "") return;
        var inf = dayInfo[key];
        var day0 = _dayMs(key);
        var dayEnd = Math.min(day0 + 86400000, Date.now());
        // Land just inside the day's first segment, so the window always opens
        // on real footage rather than on its own honest empty state.
        var land = (inf && inf.firstMs > 0) ? Math.min(dayEnd - 2000, inf.firstMs + 3000)
                                            : Math.min(dayEnd - 2000, day0 + 43200000);
        _openWindow(key, land);
    }
    function _openWindow(dayKey, atMs) {
        var day0 = _dayMs(dayKey);
        var dayEnd = Math.min(day0 + 86400000, Date.now());
        var span = Math.max(60000, zoomMin * 60000);
        var s = Math.min(Math.max(day0, atMs - span * 0.35), Math.max(day0, dayEnd - span));
        var e = Math.min(day0 + 86400000, s + span);       // a day is a session boundary (§3.6)
        if (e <= s) e = s + span;
        _obMark("day:" + dayKey);
        _explicitStart = s; _explicitEnd = e;
        selectedDay = dayKey;
        errorText = ""; clearMark(); _pendingSeekMs = -1; _seekReopen = false;
        _farInFlight = false; _farLatestMs = -1;
        seekWatch.stop(); _seekWatchSeq = -1; _seekWatchPosMs = -1; _openGen++;
        _emptyRetried = false; emptyRetry.stop();
        hoverId = ""; selId = "";
        if (!client) return;
        client.ensureReady();
        _pendingOpen = true;
        tryOpen();
    }
    // The span is tier 2's zoom. On a day it resizes the window around the
    // playhead; on a rolling window it keeps the "ending now" meaning.
    function setSpan(minutes) {
        if (!camera) { zoomMin = minutes; return; }
        if (selectedDay === "") { openFor(camera, minutes); return; }
        zoomMin = minutes;
        _openWindow(selectedDay, frags.length > 0 ? playheadMs : (_dayMs(selectedDay) + 43200000));
    }

    // ---- WT_PB_SOAK: whole-surface playback exercise (operator order 2026-08-21) ----
    // Drives the navigator the way a guard does, through the SAME public entry points the
    // UI calls — selectDay / setSpan / seekFar — so the harness cannot pass on a path the
    // operator never touches: pick a camera, pick a day that has footage, pick a scale,
    // jump to a random time, let it PLAY, jump again, repeat a random number of times,
    // then move to another camera. Inert unless WT_PB_SOAK=1.
    //
    // One [PBSOAK] verdict per jump. "played" is the load-bearing column: it is decided by
    // the playhead ADVANCING over the dwell, not by the absence of an error — a frozen
    // picture and a healthy session look identical to every other signal we log.
    readonly property bool _psRun: (typeof wtPbSoak !== "undefined" && wtPbSoak === true)
    readonly property var _psSpans: [15, 60, 360, 720, 1440]
    property string _psState: "init"
    property int _psWaits: 0
    property int _psRounds: 0
    property int _psCamN: 0
    property int _psSeekN: 0
    property int _psDwell: 0
    property double _psTarget: -1
    property double _psTtffBefore: -1
    property double _psPosBefore: -1
    property double _psSeekT0: 0
    Timer { interval: 250; repeat: true; running: root._psRun; onTriggered: root._psTick() }
    function _psPick(a) { return a[Math.floor(Math.random() * a.length)] }
    function _psRand(lo, hi) { return lo + Math.floor(Math.random() * (hi - lo + 1)) }
    function _psSay(msg) { console.log("[PBSOAK] " + msg + " t=" + Date.now()); }

    function _psTick() {
        if (_psState === "init") {
            if (!cameraModel || cameraModel.total <= 0) return;
            _psSay("BEGIN cameras=" + cameraModel.total);
            _psState = "cam"; return;
        }
        if (_psState === "cam") {
            var n = cameraModel ? cameraModel.total : 0;
            if (n <= 0) return;
            var cam = cameraModel.get(_psRand(0, n - 1));
            if (!cam || !cam.camId) return;
            _psCamN++; _psRounds = _psRand(3, 8);
            _psSay("CAMERA #" + _psCamN + " id=" + cam.camId + " jumps=" + _psRounds);
            _autoLanded = true;                 // never let the auto-lander fight the harness
            openFor(cam, _psPick(_psSpans));
            _psWaits = 0; _psState = "wait-cov"; return;
        }
        if (_psState === "wait-cov") {
            // Coverage decides which days actually hold footage; jumping before it lands
            // would measure the empty state instead of playback.
            var has = false;
            for (var i = 0; i < ribbonDays.length; i++) if (ribbonDays[i].has) { has = true; break; }
            if (!coveragePending && has) { _psWaits = 0; _psState = "day"; return; }
            if (++_psWaits > 120) {             // 30 s
                _psSay("NO-COVERAGE cam=" + root.camId + " -> next camera");
                _psState = "cam"; _psWaits = 0;
            }
            return;
        }
        if (_psState === "day") {
            var days = [];
            for (var j = 0; j < ribbonDays.length; j++) if (ribbonDays[j].has) days.push(ribbonDays[j].key);
            if (days.length === 0) { _psState = "cam"; return; }
            var key = _psPick(days);
            _psSay("DAY cam=" + root.camId + " day=" + key + " of=" + days.length + " days_with_footage");
            selectDay(key);
            _psWaits = 0; _psState = "wait-day"; return;
        }
        if (_psState === "wait-day") {
            if (!loading) { _psWaits = 0; _psState = "span"; return; }
            if (++_psWaits > 160) { _psSay("DAY-TIMEOUT day=" + selectedDay); _psState = "cam"; _psWaits = 0; }
            return;
        }
        if (_psState === "span") {
            var m = _psPick(_psSpans);
            _psSay("SPAN cam=" + root.camId + " day=" + selectedDay + " span=" + m + "m");
            setSpan(m);
            _psWaits = 0; _psState = "wait-span"; return;
        }
        if (_psState === "wait-span") {
            if (!loading) { _psWaits = 0; _psState = "seek"; return; }
            if (++_psWaits > 160) { _psSay("SPAN-TIMEOUT span=" + zoomMin + "m"); _psState = "cam"; _psWaits = 0; }
            return;
        }
        if (_psState === "seek") {
            if (_psRounds <= 0) { _psState = "cam"; return; }
            if (selectedDay === "") { _psState = "day"; return; }
            var d0 = _dayMs(selectedDay);
            var d1 = Math.min(d0 + 86400000, Date.now());
            if (d1 - d0 < 120000) { _psState = "day"; return; }
            _psTarget = d0 + Math.floor(Math.random() * (d1 - d0 - 60000));
            _psTtffBefore = lastTtffMs;
            _psSeekT0 = Date.now();
            _psSeekN++; _psRounds--;
            seekFar(_psTarget);
            _psWaits = 0; _psState = "wait-seek"; return;
        }
        if (_psState === "wait-seek") {
            // Ready = the open settled AND a frame arrived for THIS jump (ttff moved).
            if (!loading && (lastTtffMs !== _psTtffBefore || frags.length > 0)) {
                _psPosBefore = player.position;
                _psDwell = _psRand(24, 56);          // 6-14 s of real playback
                _psWaits = 0; _psState = "dwell"; return;
            }
            if (++_psWaits > 160) {                  // 40 s
                _psSay("VERDICT cam=" + root.camId + " day=" + selectedDay + " span=" + zoomMin
                       + "m target=" + Qt.formatDateTime(new Date(_psTarget), "HH:mm:ss")
                       + " ttffMs=timeout frags=" + frags.length + " played=no"
                       + " err=" + (errorText === "" ? "none" : "\"" + errorText + "\""));
                _psWaits = 0; _psState = "seek";
            }
            return;
        }
        if (_psState === "dwell") {
            if (--_psDwell > 0) return;
            var adv = Math.round(player.position - _psPosBefore);
            var ttff = (lastTtffMs !== _psTtffBefore && lastTtffMs >= 0) ? Math.round(lastTtffMs)
                                                                        : Math.round(Date.now() - _psSeekT0);
            _psSay("VERDICT cam=" + root.camId + " day=" + selectedDay + " span=" + zoomMin
                   + "m target=" + Qt.formatDateTime(new Date(_psTarget), "HH:mm:ss")
                   + " ttffMs=" + ttff + " frags=" + frags.length
                   + " played=" + (adv > 500 ? "yes" : "no") + " advancedMs=" + adv
                   + " err=" + (errorText === "" ? "none" : "\"" + errorText + "\""));
            // Re-scale mid-camera about a third of the time, so every span is exercised
            // against a window that is already playing rather than only on a fresh day.
            _psState = (_psRounds > 0 && Math.random() < 0.34) ? "span"
                     : (_psRounds > 0 ? "seek" : "cam");
            return;
        }
    }

    // First paint opens on the newest footage in retention, because "what
    // happened most recently" is the commonest arrival. Only when the rolling
    // window the caller asked for holds nothing at all — never overriding an
    // explicit day, and never while a measurement harness is driving.
    property bool _autoLanded: false
    function _maybeLandOnNewestFootage() {
        if (_autoLanded || coveragePending || selectedDay !== "" || !camera || loading) return;
        if (_skActive || (typeof wtTtffDays !== "undefined" && wtTtffDays !== "")
                || (typeof wtSeekSpam !== "undefined" && wtSeekSpam > 0)) { _autoLanded = true; return; }
        if (tlFrags.length > 0) { _autoLanded = true; return; }
        var best = "";
        for (var i = 0; i < ribbonDays.length; i++) if (ribbonDays[i].has) best = ribbonDays[i].key;
        _autoLanded = true;
        if (best !== "") selectDay(best);
    }

    // Esc unwinds exactly ONE layer, most-nested first: fullscreen → open speed
    // ladder → frame mode → selection and mark. Written flat it cleared the mark
    // and left the operator inside the very mode the on-picture chip advertises
    // exiting. Called from Main.qml's global Escape shortcut, which pre-empts
    // item key handlers. Returns true when a layer was consumed.
    function escapeLayer() {
        // The export drawer is the most nested layer of all: without this, Esc
        // with the drawer open would clear the very range the drawer is about.
        if (exportDrawer.visible) { exportDrawer.close(); return true; }
        if (fullscreenOn) { fullscreenRequested(); return true; }
        if (ladderOpen) { ladderOpen = false; return true; }
        if (frameMode) { exitFrameMode(); return true; }
        if (hasSelection || selId !== "") { clearMark(); selId = ""; return true; }
        return false;
    }

    // ======================================================================
    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // Crash-prone runtime → warn persistently, right where the risk is. Qt <6.5
        // means QtMultimedia's GStreamer backend, which SIGSEGVs in libsoup under
        // playback seek/day-switch churn (P0, root-caused 2026-07-01; both 6.4.2
        // backends crash — no clean fix). The supported runtime is Qt 6.8.3 via
        // ./run.sh (FFmpeg backend, 8.8 h soak, 0 crashes).
        Rectangle {
            id: qtBanner
            readonly property var _v: (typeof wtQtRuntime !== "undefined") ? String(wtQtRuntime).split(".") : []
            readonly property bool oldQt: _v.length >= 2
                && (parseInt(_v[0]) < 6 || (parseInt(_v[0]) === 6 && parseInt(_v[1]) < 5))
            Layout.fillWidth: true
            visible: oldQt
            Layout.preferredHeight: visible ? 34 : 0
            color: Qt.rgba(Theme.bad.r, Theme.bad.g, Theme.bad.b, 0.12)
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.bad }
            Row {
                anchors { left: parent.left; leftMargin: 16; right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
                spacing: 8
                Icon { anchors.verticalCenter: parent.verticalCenter; name: "off"; size: 14; color: Theme.bad }
                Text { anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 24; elide: Text.ElideRight
                    text: qsTr("Unstable build for playback — this launch runs Qt ") + (qtBanner._v.join(".")
                          ) + " (GStreamer backend), which can crash on seeks. Close and start via ./run.sh (Qt 6.8.3)."
                    color: Theme.ink; font.family: Theme.fontSans; font.pixelSize: 12 }
            }
        }

        // ---- video stage + right rail ------------------------------------
        // The rail is a COLUMN the stage shrinks around, never an overlay: a
        // single continuous frame overlaid is larger but a third hidden and the
        // visible part is off-centre, and every centred element — the honest
        // states above all — would then centre on a stage the operator can only
        // partly see. Smaller and whole beats larger and half-hidden.
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            Item {
                id: stage
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true

                // The letterbox is a BINDING on the stage's own size, so it is
                // recomputed synchronously with the navigator drag, the rail
                // width and the window width — not one drag-step behind an
                // observer. A frame taller than its stage is CROPPED, not
                // letterboxed, and a cropped evidentiary frame contradicts the
                // letterbox rule outright.
                readonly property real vW: Math.max(0, Math.min(width, height * 16 / 9))
                readonly property real vH: Math.max(0, Math.round(vW * 9 / 16))
                readonly property real vL: Math.round((width - vW) / 2)
                readonly property real vT: Math.round((height - vH) / 2)
                readonly property real gut: vL + 11        // 11px inside the visible video

                Rectangle { anchors.fill: parent; color: "#0b0a0a" }

                VideoOutput {
                    id: vout
                    x: stage.vL; y: stage.vT; width: stage.vW; height: stage.vH
                    fillMode: VideoOutput.PreserveAspectFit
                }
                // Freeze-frame veil: while a backward step's recovery machinery
                // (overseek + frame-walk) churns frames underneath, hold the
                // pre-step image so the operator sees their frame "held".
                Image {
                    id: veilImg
                    x: stage.vL; y: stage.vT; width: stage.vW; height: stage.vH
                    fillMode: Image.PreserveAspectFit
                    cache: false
                    visible: stepper.veiled && status === Image.Ready
                }
                MediaPlayer {
                    id: player
                    videoOutput: vout
                    audioOutput: null
                    onPlaybackStateChanged: {
                        if (typeof MemTel !== "undefined") MemTel.setPlaying(2, playbackState === MediaPlayer.PlayingState)
                        if (root._pbTime) console.log("[PBTIME] playbackState=" + playbackState + " status=" + mediaStatus
                                                      + " pos=" + position + " dur=" + duration);
                    }
                    // Apply a deferred open-at seek (event −15s jump / WT_PLAYBACK_DAY
                    // instant). Must wait for `seekable` — a position set on
                    // durationChanged is silently dropped by the not-yet-prerolled
                    // pipeline (found 2026-06-12: event jumps landed at day start).
                    function applyPendingSeek() {
                        // _pendingArmed ensures frags belong to THIS session — a seekable/
                        // duration signal from the prior session (or the source swap) must
                        // not apply the pending seek against stale fragments.
                        if (!root._pendingArmed || root.loading || !(seekable && duration > 0 && root._pendingSeekMs >= 0)) return;
                        if (root.frags.length === 0) { root.seekToWall(root._pendingSeekMs); root._pendingSeekMs = -1; return; }
                        // Event/open-at jump: land on the recorded footage CLOSEST to the
                        // event, not a blind forward-snap (which can jump minutes across a
                        // gap) or a freeze at EOS. Motion-triggered cams often detect motion
                        // they never record; if the nearest footage is far, say so honestly.
                        var evt = root._pendingSeekMs + 15000;     // pending = event − 15s lead-in
                        var bestWall = -1, bestD = Infinity;
                        for (var i = 0; i < root.frags.length; i++) {
                            var f = root.frags[i], d, w;
                            if (evt >= f.ws && evt <= f.we) { d = 0; w = root._pendingSeekMs; }   // inside → keep the −15s lead-in
                            else if (evt > f.we) { d = evt - f.we; w = f.we - 3000; }             // gap after → this clip's tail
                            else { d = f.ws - evt; w = f.ws; }                                    // gap before → this clip's head
                            if (d < bestD) { bestD = d; bestWall = w; }
                        }
                        if (bestD > 90000) {     // no footage within 90s of the event
                            root.errorText = "No footage was recorded around this moment.";
                            root._pendingSeekMs = -1;
                            return;
                        }
                        // VERIFY-AND-RETRY (2026-07-31, found by the 10k-seek harness):
                        // a not-yet-prerolled pipeline SILENTLY DROPS position sets — and
                        // no signal reliably marks "now it would stick" across a source
                        // swap into a same-duration window (seekable/duration don't
                        // re-fire; LoadedMedia is still too early on cold serves). So the
                        // pending seek stays ARMED until the player's position provably
                        // lands within 2 s of the wanted spot; the retry timer below
                        // re-issues every 150 ms, capped at ~4.5 s before giving up loudly.
                        var wantedPos = root.wallToPos(bestWall) * 1000;
                        if (Math.abs(position - wantedPos) < 2000) {
                            root._pendingSeekMs = -1;               // landed — done
                            return;
                        }
                        if (++root._pendingTries > 75) {   // 60ms ticks — same ~4.5s budget
                            if ((typeof wtTrace !== "undefined") && wtTrace)
                                console.log("[PB] pending seek DROPPED after " + root._pendingTries
                                            + " tries (pos=" + position + " wanted=" + Math.round(wantedPos) + ")");
                            root._pendingSeekMs = -1;
                            return;
                        }
                        root.seekToWall(bestWall);                  // keep pending; verified next tick
                    }
                    onSeekableChanged: applyPendingSeek()
                    onDurationChanged: applyPendingSeek()
                    onMediaStatusChanged: {
                        if (root._pbTime) console.log("[PBTIME] mediaStatus=" + mediaStatus
                                                      + " dt=" + (Date.now() - root._obT0) + "ms")
                        // Third application edge for the deferred open-at seek. seekable/
                        // durationChanged are NOT re-emitted when a source swap lands a
                        // window with the SAME duration/seekability — which is every
                        // far-seek-after-far-seek (identical 30 min windows), so the
                        // pending seek was silently dropped and the player ran from the
                        // window head, ~15 s behind the target (caught by the 10k-seek
                        // harness 2026-07-31: uniform ~11.5 s "landings" = 10 s of playing
                        // to within tolerance instead of one seek). mediaStatus provably
                        // fires on every swap; the guards inside keep this idempotent.
                        if (mediaStatus === MediaPlayer.LoadedMedia || mediaStatus === MediaPlayer.BufferedMedia)
                            applyPendingSeek()
                        // WINDOW ROLL-OVER: with a bounded player window (far-seek re-open or
                        // the heavy-day bootstrap), reaching the end of the LOADED window must
                        // not halt the review — open the next window at the following footage
                        // and keep playing. (Also fixes the long-standing far-seek
                        // stop-at-window-end.) The next window is ≥ ~30 min away, so this
                        // cannot tight-loop; an empty re-open is caught by the safety net in
                        // onSessionReady.
                        if (mediaStatus === MediaPlayer.EndOfMedia && !root.paused && !root.loading
                                && root.frags.length > 0 && root.tlFrags.length > 0
                                && root.tlEndMs > root.winEndMs + 2000) {
                            for (var i = 0; i < root.tlFrags.length; i++) {
                                if (root.tlFrags[i].we > root.winEndMs + 1000) {
                                    var nxt = Math.max(root.tlFrags[i].ws, root.winEndMs + 100);
                                    if (typeof wtTrace !== "undefined" && wtTrace)
                                        console.log("[PB] window roll-over -> " + Qt.formatDateTime(new Date(nxt), "HH:mm:ss"));
                                    root.seekFar(nxt);
                                    break;
                                }
                            }
                        }
                    }
                }
                // A press anywhere on the picture dismisses the speed ladder and
                // returns key focus to the screen; it never eats the press.
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton
                    onPressed: (m) => { root.ladderOpen = false; root.forceActiveFocus(); m.accepted = false }
                }

                LoadingState {
                    anchors.centerIn: parent
                    // Honest gap-cover (booth playback soak, letter §6 2026-08-21): fragments
                    // in hand but not one frame of THIS open rendered yet must read as
                    // loading — never as a still the guard could write up as what the camera
                    // saw. _ttffPending arms on every source set and clears on the first
                    // rendered frame, so the veil now holds across the whole no-picture gap
                    // (session settled → first frame), not just session fetch + preroll.
                    visible: (root.loading || (player.mediaStatus === MediaPlayer.LoadingMedia)
                              || (root._ttffPending && root.frags.length > 0))
                             && root.errorText === "" && !root.blocked
                    label: qsTr("Loading recording…")
                }

                // ---- top-left overlay: back · mode chips · camera ----------
                Row {
                    id: tlOvl
                    x: stage.gut; y: stage.vT + 11
                    spacing: 9
                    z: 6
                    IconButton {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "back"; iconColor: "#fff"; hoverIcon: Theme.accent
                        tip: qsTr("Back"); onClicked: root.closed()
                    }
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: pbChipT.implicitWidth + 16; height: 18; color: Theme.accent
                        Text { id: pbChipT; anchors.centerIn: parent; text: qsTr("PLAYBACK", "video mode chip")
                            color: "#241a08"; font.family: Theme.fontMono; font.pixelSize: 10
                            font.weight: Font.DemiBold; font.letterSpacing: 1.3 }
                    }
                    // Above 10× the picture skips frames. The boundary is disclosed
                    // by COLOUR and by the rate cell's plain-language tooltip — not
                    // by the words "SCAN"/"frames skipped", which read as a fault
                    // report to a guard under pressure (spec §2.4).
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: root.playSpeed > root.maxDecodeRate
                        width: scanChipT.implicitWidth + 16; height: 18; color: Theme.bad
                        Text { id: scanChipT; anchors.centerIn: parent; text: xbar.fmtRate(root.playSpeed)
                            color: "#ffffff"; font.family: Theme.fontMono; font.pixelSize: 10
                            font.weight: Font.DemiBold; font.letterSpacing: 1.3 }
                    }
                    // The exit legend belongs HERE, beside the mode chip, not
                    // inside the filmstrip: in the band it cost picture-grade
                    // width and clipped away the exit instruction it exists to
                    // give, and it gave the band two more frames to leave.
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: root.frameMode
                        width: frmChipT.implicitWidth + 16; height: 18
                        color: Theme.accentSoft; border.width: 1; border.color: Theme.accentDim
                        Text { id: frmChipT; anchors.centerIn: parent
                            text: qsTr("FRAME-BY-FRAME") + " · " + qsTr("ESC TO EXIT")
                            color: Theme.accent; font.family: Theme.fontMono; font.pixelSize: 10
                            font.letterSpacing: 1.3 }
                    }
                    Item {
                        anchors.verticalCenter: parent.verticalCenter
                        width: camNm.implicitWidth; height: camNm.implicitHeight
                        Text { x: 1; y: 1; text: camNm.text; color: Qt.rgba(0, 0, 0, 0.9)
                            font: camNm.font }
                        Text { id: camNm
                            // Several fleet names already carry the octet; do not
                            // print it twice.
                            text: {
                                if (!root.camera) return "";
                                var n = root.camera.name || "", ip = root.camera.ip || "";
                                return (ip === "" || n.indexOf(ip) >= 0) ? n : n + " (" + ip + ")";
                            }
                            color: Qt.rgba(1, 1, 1, 0.82); font.family: Theme.fontSans; font.pixelSize: 13 }
                        C.ToolTip.visible: qualMa.containsMouse && qualTip !== ""
                        C.ToolTip.delay: 400
                        // `Quality` left the rail for hover: it is static per
                        // session and did not earn a permanent row.
                        readonly property string qualTip: {
                            var f = root.fragAt(player.position / 1000);
                            if (!f) return "";
                            var c = f.codec === "hevc" ? qsTr("HEVC") : "H.264";
                            return (f.resolution && f.resolution !== "") ? f.resolution + " (" + c + ")"
                                   : (f.codec === "hevc" ? qsTr("HD 1440p (HEVC)") : qsTr("SD 720p (H.264)"));
                        }
                        C.ToolTip.text: qualTip
                        MouseArea { id: qualMa; anchors.fill: parent; hoverEnabled: true }
                    }
                }

                // recording off / offline — facts about the LIVE stream and about
                // the future, not about the archive. A camera that dropped an hour
                // ago still has a complete, playable archive, so neither blocks.
                Row {
                    x: stage.gut; y: stage.vT + 40
                    spacing: 9
                    z: 6
                    visible: root.stOffline || root.stRecOff
                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: stChipT.implicitWidth + 16; height: 17
                        color: root.stOffline ? Theme.bad : Theme.accent
                        Text { id: stChipT; anchors.centerIn: parent
                            text: root.stOffline ? qsTr("OFFLINE", "camera state chip")
                                                 : qsTr("NOT RECORDING", "camera state chip")
                            color: root.stOffline ? "#ffffff" : "#241a08"
                            font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 1.3 }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.stOffline
                              ? qsTr("Its archive is complete up to the moment it dropped, and is fully playable below.")
                              : qsTr("The archive below is everything this camera has. It will not grow while recording is off.")
                        color: Qt.rgba(1, 1, 1, 0.72); font.family: Theme.fontSans; font.pixelSize: 12
                    }
                }

                // ---- top-right: the evidentiary timestamp ------------------
                // The single most-read element on the screen. One reading, not a
                // caption on a value: hierarchy is carried by CONTRAST — 62%
                // white for the date qualifier, full white for the time, accent
                // for the milliseconds, all at the same size. May never be
                // occluded, so it clears the visible video's right edge by 11px.
                Item {
                    id: tsOvl
                    z: 6
                    visible: root.frags.length > 0
                    x: stage.vL + stage.vW - width - 13
                    y: stage.vT + 11
                    width: tsRow.implicitWidth; height: tsRow.implicitHeight
                    readonly property int fs: root.width < 1300 ? 16 : 20
                    Row {
                        x: 1; y: 1; spacing: 0
                        Text { text: tsDate.text; color: Qt.rgba(0, 0, 0, 0.95); font: tsDate.font }
                        Text { text: tsTime.text; color: Qt.rgba(0, 0, 0, 0.95); font: tsTime.font }
                        Text { text: tsMs.text; color: Qt.rgba(0, 0, 0, 0.95); font: tsMs.font }
                    }
                    Row {
                        id: tsRow
                        spacing: 0
                        Text { id: tsDate
                            text: PbFmt.wd(root.playheadMs) + " " + PbFmt.dmy(root.playheadMs) + " · "
                            color: Qt.rgba(1, 1, 1, 0.62)
                            font.family: Theme.fontMono; font.pixelSize: tsOvl.fs
                            font.weight: Font.DemiBold; font.letterSpacing: 0.4 }
                        Text { id: tsTime
                            text: PbFmt.hms(root.playheadMs)
                            color: "#ffffff"
                            font.family: Theme.fontMono; font.pixelSize: tsOvl.fs
                            font.weight: Font.DemiBold; font.letterSpacing: 0.4 }
                        Text { id: tsMs
                            text: "." + PbFmt.ms3(root.playheadMs)
                            color: Theme.accent
                            font.family: Theme.fontMono; font.pixelSize: tsOvl.fs
                            font.weight: Font.DemiBold; font.letterSpacing: 0.4 }
                    }
                }

                // ---- honest states (spec §4) -------------------------------
                // Each is a TAG, a FACT and a CONSEQUENCE, and an action where
                // one exists. None says "something went wrong". They centre on
                // the picture because the rail is a column, not an overlay.
                PbBanner {
                    x: stage.vL; y: stage.vT; width: stage.vW; height: stage.vH; z: 7
                    visible: root.stPlaybackOff
                    tag: qsTr("PLAYBACK", "honest-state tag")
                    tagInk: Theme.accent; tagBg: Theme.accentSoft; tagRing: Theme.accentDim
                    fact: qsTr("Playback is switched off — recorded playback and export are paused.")
                    consequence: qsTr("An operator turned this off in settings. Live view is unaffected.")
                    action: qsTr("Open settings")
                    onActionClicked: root.openSettingsRequested()
                }
                PbBanner {
                    x: stage.vL; y: stage.vT; width: stage.vW; height: stage.vH; z: 7
                    visible: root.stSessionError
                    tag: qsTr("ERROR", "honest-state tag")
                    tagInk: Theme.bad; tagBg: Theme.badSoft; tagRing: Theme.bad
                    fact: qsTr("Could not open a playback session for this camera.")
                    consequence: qsTr("The recording service did not answer. Nothing has been lost — this is a connection problem.")
                    action: qsTr("Retry")
                    onActionClicked: { root.errorText = ""; root._pendingOpen = true; root.tryOpen() }
                }
                PbBanner {
                    x: stage.vL; y: stage.vT; width: stage.vW; height: stage.vH; z: 7
                    visible: !root.stPlaybackOff && !root.stSessionError && root.archiveEmpty
                    tag: qsTr("ARCHIVE", "honest-state tag")
                    fact: qsTr("This camera has no recorded footage in the last %n day(s).", "", root.retentionDays)
                    consequence: qsTr("Nothing to play back. The archive ribbon is empty because the archive is empty.")
                }
                PbBanner {
                    x: stage.vL; y: stage.vT; width: stage.vW; height: stage.vH; z: 7
                    visible: !root.stPlaybackOff && !root.stSessionError && !root.archiveEmpty
                             && root.stNoFootageHere
                    tag: qsTr("FOOTAGE", "honest-state tag")
                    fact: qsTr("No footage recorded around this moment.")
                    consequence: qsTr("The archive has a gap here. The nearest recorded footage is below.")
                    // A gap-seek never SNAPS. It lands where the operator dropped
                    // the playhead, states the gap, and offers the nearest footage
                    // as a button — snapping silently is the player deciding where
                    // they meant to look.
                    action: root.nearestFootageMs > 0
                            ? qsTr("Nearest footage %1 →").arg(PbFmt.hms(root.nearestFootageMs)) : ""
                    onActionClicked: root.seekToWall(root.nearestFootageMs)
                }

                // ---- transport ---------------------------------------------
                PbTransport {
                    id: xbar
                    // On the PICTURE, like the overlays above it: when the video is
                    // width-bound the bar rides the frame's bottom edge instead of
                    // floating in the letterbox below it.
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom
                              bottomMargin: stage.vT }
                    height: 64
                    z: 8
                    padL: stage.gut
                    padR: stage.gut
                    playing: root.advancing
                    canPlay: !root.blocked && root.frags.length > 0
                    blocked: root.blocked
                    rate: root.playSpeed
                    rates: root.speeds
                    maxDecodeRate: root.maxDecodeRate
                    frameMode: root.frameMode
                    rangeTools: root.frameMode || root.hasSelection
                    ladderOpen: root.ladderOpen
                    fullscreenOn: root.fullscreenOn
                    markMs: root.markMs
                    backFetching: root.backFetching
                    onBack10: root.nudge(-10000)
                    onStepBack: root.stepBackVisible()
                    onPlayPause: root.togglePlay()
                    onStepFwd: if (!stepper.busy) stepper.stepForward()
                    onFwd10: root.nudge(10000)
                    onLadderToggled: root.ladderOpen = !root.ladderOpen
                    onRatePicked: (r) => { root.setSpeed(r); root.ladderOpen = false }
                    onFrameToggled: root.frameMode ? root.exitFrameMode() : root.enterFrameMode()
                    onMarkIn: root.markIn()
                    onMarkOut: root.markOut()
                    onExportClicked: root.openExportDrawer()
                    onFullscreenToggled: root.fullscreenRequested()
                    onSnapshot: root.snapshot()
                    onSnapshotStamped: root.snapshotStamped()
                    onReturnToLive: root.returnToLive()
                }
            }

            PbEventsPanel {
                id: evPanel
                Layout.preferredWidth: root.panelW
                Layout.fillHeight: true
                // Fullscreen means the video fills the window: chrome, rail,
                // filmstrip and navigator all stand down. Shift F advertises
                // that, so it must actually happen.
                visible: root.railOpen && !root.fullscreenOn
                items: root.winItemsNewest
                unfilteredCount: root.winItemsUnfiltered
                types: root.typeChips
                hoverId: root.hoverId
                selId: root.selId
                onHovered: (id) => root.hoverId = id
                onPicked: (id, ms) => root.pickItem(id, ms)
                onTypeToggled: (k) => root.toggleType(k)
                onCloseRequested: { root.railOpen = false; Settings.pbEventsPanel = false }
                onResizeDragged: (dx) => {
                    root.panelW = Math.max(232, Math.min(560, root.panelW + dx));
                    prefSave.restart();
                }
                onResizeReset: { root.panelW = 296; Settings.pbPanelW = 296 }
            }
        }

        // ---- filmstrip band — frame mode only -----------------------------
        // Stepping through a 25 fps archive changes the picture almost
        // imperceptibly frame to frame; the strip makes the step legible by
        // showing the neighbours it moved between, and puts the expensive
        // backward direction on screen instead of behind a keypress.
        Item {
            id: stripBand
            Layout.fillWidth: true
            Layout.preferredHeight: (root.frameMode && !root.fullscreenOn) ? 96 : 0
            visible: root.frameMode && !root.fullscreenOn
            Behavior on Layout.preferredHeight { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            Rectangle { anchors.fill: parent; color: Theme.bg }
            Rectangle { anchors { left: parent.left; right: parent.right; top: parent.top }
                        height: 1; color: Theme.line2 }
            FrameStrip {
                id: frameStripItem
                anchors.fill: parent
                anchors.leftMargin: 12
                // padded by the rail so the frames sit under the PICTURE, not the rail
                anchors.rightMargin: (root.railOpen ? root.panelW : 0) + 12
                anchors.topMargin: 8; anchors.bottomMargin: 8
                currentPts: FrameClock.lastPtsMs
                clockOf: function (pts) { return root.frameClockOf(pts); }
                onJumpRequested: (pts) => stepper.jumpToCachedPts(pts)
            }
        }

        // ---- the navigator: ONE axis, two tiers ---------------------------
        Item {
            id: navigator
            Layout.fillWidth: true
            Layout.preferredHeight: root.fullscreenOn ? 0 : root.navH
            visible: !root.fullscreenOn

            Rectangle { anchors.fill: parent; color: Theme.bg }
            Rectangle { anchors { left: parent.left; right: parent.right; top: parent.top }
                        height: 1; color: Theme.line2 }

            PbRibbon {
                id: ribbon
                anchors { left: parent.left; right: parent.right; top: parent.top }
                days: root.ribbonDays
                selKey: root.selDayKey
                selMs: root._selDay0
                selSec: root.selDaySec
                selClips: root.selDayClips
                winA: root.winFracA
                winB: root.winFracB
                onDaySelected: (key) => root.selectDay(key)
            }

            PbNavHeader {
                id: navHdr
                anchors { left: parent.left; right: parent.right; top: ribbon.bottom }
                playheadMs: root.playheadMs
                hasPlayhead: root.frags.length > 0
                segCount: root._cov.n
                coveredPct: root._cov.pct
                lastMotionMs: root.lastMotionMs
                markMs: root.markMs
                showMotion: root.showMotionLane
                showEvents: root.railOpen
                spanMin: root.zoomMin
                zoomed: root.tlZoomed
                onJumpLastMotion: root.seekToWall(root.lastMotionMs)
                onClearMark: root.clearMark()
                onToggleMotion: Settings.eventsOnScrubber = !Settings.eventsOnScrubber
                onToggleEvents: { root.railOpen = !root.railOpen; Settings.pbEventsPanel = root.railOpen }
                onSpanPicked: (m) => root.setSpan(m)
                onFitRequested: root.resetView()
            }

            PbLanes {
                id: lanesItem
                anchors { left: parent.left; right: parent.right; top: navHdr.bottom }
                height: 15 + root.footageLaneH + root.motionLaneH
                winS: root.viewStartMs
                winE: root.viewEndMs
                segs: root.tlFrags
                items: root.winItems
                ph: root.playheadMs
                markS: root.selStartMs
                markE: root.selEndMs
                hoverId: root.hoverId
                selId: root.selId
                showMotion: root.showMotionLane
                footageH: root.footageLaneH
                motionH: root.motionLaneH
                onSeekRequested: (ms) => root.seekToWall(ms)
                onZoomRequested: (factor, atMs) => root.zoomView(factor, atMs)
                // Plain drag marks the export range. It deliberately does NOT enter
                // frame mode the way [ and ] do: those are keyboard marks that would
                // otherwise leave a range with no visible export control, whereas the
                // transport's range tools already appear on hasSelection — and pausing
                // playback because the operator dragged would be a side effect nobody
                // asked for.
                onMarkRequested: (s, e) => { root.selStartMs = s; root.selEndMs = e }
                onMarkCleared: root.clearMark()
                onPanRequested: (deltaMs) => root.panView(deltaMs)
                onHovered: (id) => root.hoverId = id
                onPicked: (id, ms) => root.pickItem(id, ms)
            }

            // Height grip: straddles the navigator's TOP edge, absolutely
            // positioned, so it costs 0px of picture. Only the lanes absorb the
            // change — ribbon, header and ruler are fixed.
            Item {
                id: navGrip
                anchors { left: parent.left; right: parent.right }
                y: -3; height: 7; z: 12
                Rectangle { anchors.fill: parent; color: Theme.accentSoft
                            visible: gripMa.containsMouse || gripMa.pressed }
                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 3; width: 36
                    height: gripMa.containsMouse || gripMa.pressed ? 2 : 1
                    color: gripMa.containsMouse || gripMa.pressed ? Theme.accent : Theme.line2
                }
                MouseArea {
                    id: gripMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.SizeVerCursor
                    property real _y0: 0
                    onPressed: (m) => { _y0 = mapToItem(null, m.x, m.y).y }
                    onPositionChanged: (m) => {
                        if (!pressed) return;
                        var ny = mapToItem(null, m.x, m.y).y;
                        root.navH = Math.max(root.navMin,
                            Math.min(Math.round(root.height * 0.52), root.navH + (_y0 - ny)));
                        _y0 = ny;
                        prefSave.restart();
                    }
                    onDoubleClicked: { root.navH = root.navDefault; Settings.pbNavH = root.navDefault }
                }
                C.ToolTip.visible: gripMa.containsMouse
                C.ToolTip.delay: 600
                C.ToolTip.text: qsTr("Drag to resize · double-click to reset")
            }
        }
    }

    // returns the ready fragment covering compact-seconds s (or null)
    function fragAt(s) {
        for (var i = 0; i < frags.length; i++)
            if (s >= frags[i].cs && s <= frags[i].ce) return frags[i];
        return null;
    }

    signal fullscreenRequested()           // toggles the shell's fullscreen (Shift F / ⛶ / Esc)
    signal openSettingsRequested()         // the playbackOff banner's action — wired, never inert
    signal snapshotSaved(string path, string camName)
    // Snapshot with the PLAYHEAD instant burned in — the recorded frame's wall
    // clock (matches the header readout), not the capture time.
    function snapshotStamped() {
        var stamp = Qt.formatDate(new Date(root.playheadMs), "yyyy-MM-dd") + " "
                    + root.fmtClock(root.playheadMs)
                    + "  " + (root.camera ? root.camera.name : "");
        vout.grabToImage(function(res) {
            var p = Artifacts.saveImageWithTimestamp(res.image,
                        root.camera ? root.camera.camId : "cam", stamp);
            if (p !== "") root.snapshotSaved(p, root.camera ? root.camera.name : "");
        });
    }

    function snapshot() {
        vout.grabToImage(function(res) {
            var p = Artifacts.newSnapshotPath((root.camera ? root.camera.camId : "playback") + "_pb");
            if (res.saveToFile(p)) root.snapshotSaved(p, root.camera ? root.camera.name : "");
        });
    }
    // Open the export drawer for the current selection, seeding it with a grabbed
    // preview frame. The drawer collects the full export form and emits confirmed()
    // with the fields cilex-vision's API supports today (range + mode).
    function openExportDrawer() {
        if (!hasSelection || !client) return;
        _xt("openExportDrawer ENTER cache=" + FrameCache.frames + "f pts=" + FrameClock.lastPtsMs.toFixed(0));
        exportDrawer.openWith(camera, camId, selStartMs, selEndMs, tlFrags, playheadMs);
        _xt("openExportDrawer after openWith cache=" + FrameCache.frames + "f pts=" + FrameClock.lastPtsMs.toFixed(0));
        vout.grabToImage(function(res) {
            if (res) exportDrawer.previewSource = res.url;
            root._xt("grabToImage CB cache=" + FrameCache.frames + "f pts=" + FrameClock.lastPtsMs.toFixed(0));
        });
        _xt("openExportDrawer EXIT cache=" + FrameCache.frames + "f pts=" + FrameClock.lastPtsMs.toFixed(0));
    }
    // Test-only (WT_GRAB_STORM): one fire-and-forget VideoOutput readback — the same
    // grabToImage path as the export-drawer preview, without the drawer. Used by the
    // GUI-wedge repro to amplify the rare grab/render race. Inert unless driven.
    function stormGrab() { vout.grabToImage(function(res) {}); }
    // Export-drawer state exposed for the WT_NIGHT_SOAK harness (Esc/cancel checks).
    readonly property bool exportDrawerVisible: exportDrawer.visible
    readonly property bool exportDrawerFocus: exportDrawer.activeFocus
    function closeExportDrawer() { if (exportDrawer) exportDrawer.close(); }
    // Is wall-ms inside recorded footage on the operator timeline? (seek-land verification)
    function msInFootage(ms) {
        var f = tlFrags;
        for (var i = 0; i < f.length; i++) if (ms >= f[i].ws && ms <= f[i].we) return true;
        return false;
    }

    ExportDrawer {
        id: exportDrawer
        z: 50
        onConfirmed: (s, e, mode, purpose, quality, compHeight, burnTs, burnName) => {
            if (!root.client) return;
            root._xt("export CONFIRMED cache=" + FrameCache.frames + "f pts=" + FrameClock.lastPtsMs.toFixed(0));
            var base = (root.camera && root.camera.name) ? root.camera.name : root.camId;
            var dest = Artifacts.newExportPath(base, "mp4");
            // High = the H.265 main original (hevc_capable=true → ~1440p); Standard =
            // the H.264 720p sub (false). Backend ships the selector (migration 0045);
            // a High request over an aged span 422s, surfaced as an export error.
            // Client post-processing (ffmpeg, local): downscale to compHeight (0 = keep)
            // and/or burn in the camera caption + per-frame footage wall-clock.
            var post = {};
            if (compHeight > 0 || burnTs || burnName) {
                var label = root.camera ? (root.camera.name + " (" + root.camera.ip + ")") : root.camId;
                post = { height: compHeight, timestamp: burnTs, name: burnName,
                         label: label, startEpochMs: s, durationMs: (e - s) };
            }
            root.client.createExport(root.camId, new Date(s).toISOString(),
                                     new Date(e).toISOString(), mode, dest, "", purpose,
                                     quality === "high", post);
        }
    }

    // ===== Chaotic scrubber click-spam driver (WT_SEEK_SPAM=1) =====
    // Reproduces the operator gesture "click the seek bar fast and chaotically"
    // (2026-07-03 report: ~5 apparent freezes/min doing this). Bursts of 12 rapid
    // (140 ms) DETERMINISTIC random-target seekToWall calls with no waiting —
    // overlapping far-seek re-opens — then a settle window that measures recovery:
    // last click → next rendered frame ([SPAM] recovered after_ms=…). 40 bursts,
    // then DONE. Pair with WT_SMOOTHTEST (GUI-freeze detector) to separate a GUI
    // stall from video dead-time. Inert unless WT_SEEK_SPAM is set.
    Item {
        id: spam
        property bool on: typeof wtSeekSpam !== "undefined" && wtSeekSpam > 0
        property int burst: 0
        property int clicksLeft: 0
        property int clickNo: 0
        property double lastClickT: 0
        property int frameAtLast: 0
        property bool waitingRecover: false
        Timer {                      // click cadence within a burst
            interval: 140; repeat: true
            running: spam.on && spam.clicksLeft > 0 && root.tlFrags.length > 0
            onTriggered: {
                var lo = root.tlStartMs, hi = root.tlEndMs;
                spam.clickNo++;      // deterministic LCG → identical target sequence across A/B runs
                var r = ((spam.clickNo * 1103515245 + 12345) >>> 4) % 1000 / 1000.0;
                var ms = lo + r * (hi - lo);
                spam.clicksLeft--;
                spam.lastClickT = Date.now(); spam.frameAtLast = root._frameSeq;
                console.log("[SPAM] click burst=" + spam.burst + " left=" + spam.clicksLeft
                            + " tgt=" + Qt.formatDateTime(new Date(ms), "HH:mm:ss") + " t=" + Date.now());
                root.seekToWall(ms);
                if (spam.clicksLeft === 0) spam.waitingRecover = true;
            }
        }
        Timer {                      // recovery watch + burst pacing
            interval: 40; repeat: true
            running: spam.on
            property double settleUntil: 0
            onTriggered: {
                if (spam.waitingRecover && root._frameSeq > spam.frameAtLast) {
                    console.log("[SPAM] recovered burst=" + spam.burst + " after_ms=" + (Date.now() - spam.lastClickT) + " t=" + Date.now());
                    spam.waitingRecover = false;
                    settleUntil = Date.now() + 4000;
                } else if (spam.waitingRecover && Date.now() - spam.lastClickT > 15000) {
                    console.log("[SPAM] RECOVER-TIMEOUT burst=" + spam.burst + " t=" + Date.now());
                    spam.waitingRecover = false;
                    settleUntil = Date.now() + 4000;
                } else if (!spam.waitingRecover && spam.clicksLeft === 0
                           && Date.now() > settleUntil && root.tlFrags.length > 0 && !root.loading) {
                    spam.burst++;
                    if (spam.burst > 40) { console.log("[SPAM] DONE bursts=40 t=" + Date.now()); spam.on = false; return; }
                    spam.clicksLeft = 12;
                    console.log("[SPAM] burst=" + spam.burst + " begin t=" + Date.now());
                }
            }
        }
    }
    // QA self-test (WT_SMOOTHTEST=<seconds>): verifies playback SMOOTHNESS (video
    // frames keep arriving while the playhead advances — no frozen frame while the
    // timer ticks) and FRAME/TIMER SYNC (the displayed frame's PTS tracks the
    // playhead). Prints WTSMOOTH lines and quits after the window. A "freeze" =
    // playing + position advancing + no new presented frame.
    Item {
        id: probe
        property bool on: (typeof wtSmoothTest !== "undefined") && wtSmoothTest !== ""
        property int runSec: probe.on ? (parseInt(wtSmoothTest) || 45) : 0
        property int frames: 0
        property double lastFrameMs: -1     // presented frame PTS (ms), if exposed
        property int stalls: 0
        property double maxStallMs: 0
        property double maxDesyncMs: 0
        property double lastPos: -1
        property int lastFrames: 0
        property double freezeStart: -1
        Connections {
            target: vout.videoSink
            enabled: probe.on
            function onVideoFrameChanged(frame) {
                probe.frames++;
                if (frame !== undefined && frame !== null && frame.startTime !== undefined && frame.startTime >= 0)
                    probe.lastFrameMs = frame.startTime / 1000;
            }
        }
        Timer {                       // 100ms sampler: freeze + desync detection
            running: probe.on; interval: 100; repeat: true
            onTriggered: {
                if (player.playbackState !== MediaPlayer.PlayingState) {
                    probe.lastPos = player.position; probe.lastFrames = probe.frames; probe.freezeStart = -1; return;
                }
                var now = Date.now(), pos = player.position;
                var posAdv = probe.lastPos >= 0 && (pos - probe.lastPos) > 40;
                var frmAdv = probe.frames > probe.lastFrames;
                // ignore the initial open/preroll — only flag mid-playback freezes
                if (posAdv && !frmAdv && probe.frames > 8) {
                    if (probe.freezeStart < 0) probe.freezeStart = now;
                    probe.maxStallMs = Math.max(probe.maxStallMs, now - probe.freezeStart);
                } else if (frmAdv) {
                    if (probe.freezeStart >= 0 && (now - probe.freezeStart) > 400) {
                        probe.stalls++;
                        console.log("WTSMOOTH STALL " + Math.round(now - probe.freezeStart) + "ms near playhead=" + root.fmtClock(root.playheadMs));
                    }
                    probe.freezeStart = -1;
                }
                if (probe.lastFrameMs >= 0)
                    probe.maxDesyncMs = Math.max(probe.maxDesyncMs, Math.abs(pos - probe.lastFrameMs));
                probe.lastPos = pos; probe.lastFrames = probe.frames;
            }
        }
        Timer {                       // 1s heartbeat + final summary
            running: probe.on; interval: 1000; repeat: true
            property int sec: 0
            onTriggered: {
                sec++;
                console.log("WTSMOOTH t=" + sec + "s frames=" + probe.frames + " pos=" + player.position
                    + " playhead=" + root.fmtClock(root.playheadMs) + " status=" + player.mediaStatus + " state=" + player.playbackState);
                if (sec >= probe.runSec) {
                    console.log("WTSMOOTH SUMMARY stalls=" + probe.stalls + " maxStall=" + Math.round(probe.maxStallMs)
                        + "ms maxDesync=" + Math.round(probe.maxDesyncMs) + "ms frames=" + probe.frames + " over=" + sec + "s");
                    Qt.quit();
                }
            }
        }
    }

    // TTFF harness (WT_TTFF_DAYS="d1,d2,…"): on a warm app, opens each listed day in
    // turn and logs [TTFF] day=… ttff=…ms — the operator's "click a calendar day →
    // first rendered frame" latency through the REAL open path — then a summary and
    // quits. Pair with WT_PLAYBACK_IP (+ optionally WT_PLAYBACK_DAY for the boot
    // open); the [PBTIME] stage logs break each open down.
    Item {
        id: ttffRun
        property bool on: (typeof wtTtffDays !== "undefined") && wtTtffDays !== ""
        property var days: on ? String(wtTtffDays).split(",") : []
        property int idx: -1
        property var results: []
        Timer {
            running: ttffRun.on; interval: 1000; repeat: true
            property int tick: 0
            property int nextAt: 12          // boot grace: let the WT_PLAYBACK_DAY open settle
            onTriggered: {
                tick++;
                // WT_TTFF_EOS=1: 10 s after each open, seek near the END of the loaded
                // player window so EndOfMedia fires within seconds → deterministically
                // exercises the bounded-window ROLL-OVER (playback must continue into
                // the next window, not halt). Inert unless the env is set.
                if ((typeof wtTtffEos !== "undefined") && wtTtffEos === true
                        && ttffRun.idx >= 0 && tick === nextAt - 20
                        && root.frags.length > 0 && !root.loading && player.duration > 8000) {
                    // Set position DIRECTLY (not seekToWall — a near-end wall target on a
                    // gappy day crosses a boundary and slides the window instead): jump to
                    // duration−4 s so playback runs off the end within seconds.
                    console.log("[TTFF-EOS] kick: position -> dur-4s (dur=" + player.duration + ")");
                    player.position = player.duration - 4000;
                }
                if (tick < nextAt) return;
                if (ttffRun.idx >= 0) {      // record the previous open's outcome
                    var d = ttffRun.days[ttffRun.idx];
                    var r = root.lastTtffMs >= 0 ? Math.round(root.lastTtffMs) : -1;
                    ttffRun.results.push(r);
                    console.log("[TTFF] day=" + d + " ttff=" + r + "ms err=" + (root.errorText || "-"));
                }
                ttffRun.idx++;
                if (ttffRun.idx >= ttffRun.days.length) {
                    var ok = ttffRun.results.filter(function (x) { return x >= 0; });
                    var sum = 0;
                    for (var i = 0; i < ok.length; i++) sum += ok[i];
                    console.log("[TTFF] SUMMARY n=" + ttffRun.results.length + " played=" + ok.length
                                + " meanTtff=" + (ok.length ? Math.round(sum / ok.length) : -1) + "ms");
                    Qt.quit();
                    return;
                }
                root.lastTtffMs = -1;
                root.openForDay(ttffRun.days[ttffRun.idx]);
                nextAt = tick + 30;          // fixed dwell — bounds even a pathological open
            }
        }
    }
}
