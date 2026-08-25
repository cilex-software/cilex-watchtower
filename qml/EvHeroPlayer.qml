import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import QtMultimedia
import Watchtower

// Imagery part 2 — REAL inline player for the Triage hero. Opens a cilex-vision
// review session around the event moment and plays the recorded HLS via
// QtMultimedia (the same stable path PlaybackScreen uses), seeked to the event.
// Uses its OWN PlaybackClient (passed in) so it never clobbers the main Playback
// screen's session. Mock mode uses EvPlayer (procedural) instead — EvTriage swaps
// between them. While the session loads, the real event frame (EvSnapshot) is the
// poster.
Item {
    id: hp
    property var ev: null
    property var playbackClient: null
    // variant B §4: the 52px transport and the 44px tool row merge into ONE
    // 40px control bar; the host opts in and receives the tool-cell signals.
    property bool toolCells: false
    // fillStage: the host gives the player a real height and the video stage
    // takes ALL of it (operator 2026-08-07: the 21:9-capped slot left a 4:1
    // black band that a 16:9 clip could never fill, while the leftover height
    // went to an empty info panel). Off = legacy self-sizing 21:9 stage.
    property bool fillStage: false
    property int maxStageH: 372          // only used when fillStage is false
    property bool bookmarkOn: false
    signal exportRequested()
    signal linkRequested()
    signal assignRequested()
    signal bookmarkRequested()

    // 21:9 surface + 52px transport (drive our own implicit height for the layout)
    implicitHeight: fillStage ? 200 : (width > 0 ? Math.min(maxStageH, Math.round(width * 9 / 21)) + 40 : 0)

    property string _sid: ""
    property var _frags: []
    property real _compactDur: 0
    property bool _loading: false
    property string _error: ""
    property int _pendingSeekMs: -1
    property bool _armed: false
    property int _speed: 1
    property real _smoothMs: 0                          // interpolated playhead (smooth)
    // Clip hard-stop latch (2026-08-25): segment-range sessions can SERVE more
    // media than the playlist DECLARES (measured: 6.3s declared / 31.9s served,
    // 5x worst case — CV letter of today). FFmpeg stops at the declared
    // timeline; AVFoundation plays the bytes — the operator's Mac clip ran 20s+
    // past its own scrubber and the bar wrapped. The clip must end where it
    // says it ends, on every backend.
    property bool _winStopped: false
    property bool _blindSaid: false                     // one blind-scanner log line per session
    property real _extInPlaceMs: 0                      // window growth not yet baked into a session's _compactDur
    property bool _endFinal: false                      // measured end landed INSIDE the window: band frozen, no more extensions
    // LEARNED WINDOWS (operator, 08-26: "when starts playing is still showing 0:25
    // whereas it should probably be 0:35"): once a clip's true extent is measured —
    // extensions followed the movement, or the end verdict landed — REPLAYS of that
    // event open with the full window instead of re-discovering it. Per-run memory,
    // keyed by event id; endWall is the learned window end (wall ms).
    property var _learnedWin: ({})
    // Motion-follows extension (operator goal 2026-08-25): when the scan says motion
    // is still active at the window tail, the clip GROWS (+15s per step, max +60s)
    // instead of ending on the camera's early stamp — the reopen happens from the
    // PAUSED hard-stop, the same proven path as tap-to-retry, never mid-play churn.
    property int _extGen: 0
    property int _extMs: 0
    property double _extResumeWall: -1
    property bool _extending: false
    // The EPISODE timeline the scrubber shows — [start, end] from EventsStore.episodeWindow, set on a fresh
    // open and KEPT across far-seek re-opens (so a far seek doesn't shrink/jump the scrubber to the loaded
    // sub-window). The player session (_frags) is a window inside it. Mirrors PlaybackScreen's tl*/win*.
    property double tlStartMs: 0
    property double tlEndMs: 0
    // The MOVEMENT span inside the padded timeline (operator ask 2026-08-06:
    // pre/post-roll are ON the scrubber now — playhead moves from the first
    // played frame — and this span renders as the thin accent underline).
    property double mkStartMs: 0
    property double mkEndMs: 0
    // Movement span start MEASURED from the decoded footage (MotionScan): camera motion
    // stamps skew per camera (−20 s / +2 s / +7 s measured 2026-08-17), so once the scan
    // has covered the window head and finds sustained pixel motion, the yellow span snaps
    // to it. −1 = no measurement yet (detector stamp shown). CV-side clock fix tracked in
    // docs/letters/2026-08-17-null-clock-fields-block-marker-sync.md — both were ordered.
    property double mkMeasuredMs: -1
    // Movement span END, measured (2026-08-19 marker soak): valid once the scan has covered
    // the window TAIL; the scrubber's yellow then ends where motion ended, not where the
    // camera's duration guess ended. −1 = unmeasured (stamp end shown).
    property double mkMeasuredEndMs: -1
    property bool _mktDone: false
    Timer {   // window-completion check: scan covered head AND tail → apply end + emit [MKT]
        interval: 500; repeat: true
        running: hp._started && hp._lit && !hp._mktDone && hp._frags.length > 0
        onTriggered: {
            if (MotionScan.latestPtsMs < 0) return;
            var tailWall = hp._posToWall(MotionScan.latestPtsMs);
            // Tail covered = scanned to the window end, OR the media genuinely ended earlier
            // (recordings often stop short of the padded window; EndOfMedia is honest coverage).
            var ended = player.mediaStatus === MediaPlayer.EndOfMedia
                        || hp._winStopped
                        || (player.duration > 0 && player.position >= player.duration - 800);
            if (tailWall < hp.tlEndMs - 1500 && !ended) return;
            if (hp._extGen === 0
                    && hp._posToWall(MotionScan.earliestPtsMs) > hp.tlStartMs + 2500) return;   // head never covered (waived on extensions: head was covered pre-extension)
            hp._mktDone = true;
            var mEnd = MotionScan.lastMotionPtsMs >= 0 ? hp._posToWall(MotionScan.lastMotionPtsMs) : -1;
            // Tail never actually scanned (verdict forced by the stop latch) while motion was
            // still running at the last SCANNED frame: the unscanned tail cannot testify that
            // movement stopped — the honest band reaches the clip's edge.
            if (mEnd > 0 && tailWall < hp.tlEndMs - 1500
                    && player.mediaStatus !== MediaPlayer.EndOfMedia
                    && tailWall - mEnd <= 2500)
                mEnd = hp.tlEndMs;
            // Motion outliving the window used to REFUSE the end-snap (mEnd > tlEndMs
            // fell through), leaving the camera's early stamp on screen — the
            // operator's 08-25 case: stamp said 20s, movement ran past the clip.
            // Cap to the window end instead: yellow reaching the clip's edge is the
            // honest statement "movement continues past this clip".
            if (mEnd > hp.tlEndMs) mEnd = hp.tlEndMs;
            // The END measures INDEPENDENTLY of the start (operator, 08-25: "i don't mind
            // where it starts" — the end is what the guard needs). A rejected/absent start
            // measurement must not doom the end to the camera's early stamp.
            // MONOTONIC: re-verdicts (after window extensions) may only move the end RIGHT —
            // the band the guard is staring at never shrinks (operator, 08-26: it "shrank
            // and expanded without any apparent logic" as re-measures landed).
            var bandStart = hp.mkMeasuredMs > 0 ? hp.mkMeasuredMs : hp.mkStartMs;
            if (mEnd > hp.tlStartMs && mEnd > bandStart + 500 && mEnd > hp.mkMeasuredEndMs)
                hp.mkMeasuredEndMs = mEnd;
            // FINAL once the measured end sits clearly INSIDE the window: motion ended in
            // view, the verdict is complete — no re-measure, no further extensions. Night
            // wind on foliage scores above the floor at the 360p rendition (operator's Mac:
            // 0.128 at 49-51s with nobody in frame) and used to walk the band to 68s and
            // the clip to 70s after the subject left at 30s.
            if (mEnd > 0 && mEnd < hp.tlEndMs - 2500) {
                hp._endFinal = true;
                if (hp.ev && hp.ev.id)
                    hp._learnedWin[String(hp.ev.id)] =
                        { endWall: Math.max(hp.mkEndMs + hp.padPostMs, mEnd + hp.padPostMs) };
            }
            // One verdict line per fully-scanned clip — the marker-soak datum.
            var ds = hp.mkMeasuredMs > 0 ? Math.round(hp.mkMeasuredMs - hp.mkStartMs) : "nolock";
            var de = mEnd > 0 ? Math.round(mEnd - hp.mkEndMs) : "nolock";
            console.log("[MKT] ev=" + (hp.ev ? hp.ev.id : "?") + " cam=" + (hp.ev && hp.ev.cam ? hp.ev.cam.id : "?")
                        + " startDeltaMs=" + ds + " endDeltaMs=" + de
                        + " win=" + Math.round((hp.tlEndMs - hp.tlStartMs) / 1000) + "s");
        }
    }
    Connections {
        target: MotionScan
        // No-PTS backends (macOS darwin): feed the player position as the frame time source.
        function onFrameScanned() {
            // LIVE sessions only: during teardown/loading the player still holds the OLD
            // clip's clock, and one stale note mislabels the next frame (Mac 08-25).
            if (hp._armed && !hp._loading) MotionScan.notePosition(player.position)
        }
        function onFirstMotionChanged() {
            var pts = MotionScan.firstMotionPtsMs;
            if (pts < 0 || !hp._armed || hp._frags.length === 0) return;
            // Trust only a scan that covered the window HEAD — a mid-window start would
            // miss earlier movement and shift the span to wherever playback began.
            if (hp.mkMeasuredMs > 0) return;              // LATCH-ONCE: a re-fire must never
                                                          // drag the band's left edge to the
                                                          // playhead (operator: band shrank as
                                                          // the clip played, 08-25)
            if (hp._extGen === 0 && hp._posToWall(MotionScan.earliestPtsMs) > hp.tlStartMs + 2500) return;
            if (hp._mktDone) return;                      // verdict rendered — the band is frozen
            // COVERAGE-HOLE gate: the claimed head→lock stretch must actually have been
            // scanned. A scanner that woke mid-clip (Mac 08-25: readback dead for the first
            // seconds) can pass the earliest-guard yet have scanned only a sliver — its
            // lock is the playhead masquerading as the head. The stamp is honest; that isn't.
            if (MotionScan.scannedSpanMs + 1500 < (pts - MotionScan.earliestPtsMs)) {
                console.log("[MKT] start-lock REJECTED: coverage hole (scanned="
                            + Math.round(MotionScan.scannedSpanMs) + "ms of claimed "
                            + Math.round(pts - MotionScan.earliestPtsMs) + "ms)");
                return;
            }
            var wall = hp._posToWall(pts);
            // Head dead-zone is tiny on purpose: "already moving at window start" is a REAL
            // verdict (fixture C: stamp trails entry by 20 s — the span belongs at the head).
            if (wall <= hp.tlStartMs + 50 || wall >= hp.mkEndMs - 1000) return;
            hp.mkMeasuredMs = wall;
            console.log("[MSCAN] span start MEASURED wall=" + Math.round(wall)
                        + " detectorDeltaMs=" + Math.round(wall - hp.mkStartMs));
            if (hp._p1AEv !== "") p1ShotB.restart();        // P1: pair shot after the snap applies
        }
    }
    // Displayed pre/post-roll around the movement (operator ask 2026-08-06):
    // reads the camera's EFFECTIVE recording profile from /streams (da3be8e,
    // via the events camera lookup). Recordings may CONTAIN 15-25s of roll;
    // the timeline clips the DISPLAY to the profile so every clip feels the
    // same. Absent profile (no assignment) → 5s/5s default, matching today's
    // Motion profile; mode "continuous" → no roll contract exists, show a
    // generous 15s of context instead (CV reply, 2026-08-06).
    // Displayed pre/post-roll = the camera profile's OWN roll values, nothing more
    // (operator, 2026-08-18: "no more than what's currently defined in the camera profile" —
    // supersedes the 2026-08-17 15s pre-roll floor and the continuous-mode 15s default; the
    // profile carries real values for continuous cameras too, measured: .110 = 5s/5s).
    // Stated consequence the operator accepted: on cameras that stamp motion late (−20s
    // measured), a 5s pre-roll can start the clip after the approach — the profile is the
    // contract. Absent profile → 5s/5s, mirroring the fleet's Motion profile.
    readonly property int padPreMs: (ev && ev.cam && ev.cam.preRollMs > 0) ? ev.cam.preRollMs : 5000
    readonly property int padPostMs: (ev && ev.cam && ev.cam.postRollMs > 0) ? ev.cam.postRollMs : 5000
    property double _seekingToWall: -1                  // target held on the scrubber while a far-seek re-opens
    property bool _continuous: false                    // continuous-timeline session ⇒ direct seeks land within a run
    property int _frameSeq: 0                            // ++ on every rendered frame — input to the freeze-watchdog
    // A frame of the CURRENT session has actually rendered. This — not MediaPlayer.mediaStatus —
    // gates the poster and the wall-clock OSD: the FFmpeg backend's status enum is not portable
    // (macOS parks below BufferedMedia over HLS while frames flow, so the poster covered a playing
    // video and its live-frame fallback said "LIVE" over a recording — operator report 2026-08-17).
    // Frames rendered is the only cross-platform truth about whether there is a picture.
    property bool _lit: false
    property int _seekWatchSeq: -1                       // _frameSeq when a direct continuous seek was issued; -1 = idle
    property double _seekWatchWall: 0                    // that seek's target, for the watchdog's fallback re-open
    // wall-clock time of the frame currently on screen (compact playhead → wall, via the ready fragments)
    readonly property double _playheadWallMs: _seekingToWall >= 0 ? _seekingToWall
                                            : (_frags.length ? Math.min(tlEndMs, _posToWall(_smoothMs)) : tlStartMs)

    // Advance the playhead continuously at 30fps; the raw MediaPlayer.position
    // updates coarsely/jitterily over HLS, so we interpolate and only snap on a
    // real seek (large divergence) — keeps the scrubber gliding, not twitching.
    Timer {
        interval: 33; repeat: true
        // _lit gate (2026-08-17): during preroll the player reports PlayingState before any
        // frame exists, so the glide advanced a counter over a poster and the first real
        // frame snapped it back to ~0 — read by the operator as "plays 2-3s then resets".
        // No frames rendered yet = no time to glide over.
        running: player.playbackState === MediaPlayer.PlayingState && hp._lit
        onTriggered: {
            var cap = player.duration > 0 ? player.duration : hp._smoothMs + 33 * player.playbackRate;
            if (hp._compactDur > 0) cap = Math.min(cap, hp._compactDur * 1000 + hp._extInPlaceMs);   // AVFoundation grows duration past the declared clip
            hp._smoothMs = Math.min(cap, hp._smoothMs + 33 * player.playbackRate);
        }
    }
    // ---- WT_HERO_TEST instrumentation (inert unless wtHeroTest set) ------------------------------------
    // Precise latency from the seek/open COMMAND to the first ACTUALLY-RENDERED frame, via the video sink's
    // frame signal (a paused seek renders nothing and player.position over HLS is coarse, so we detect the
    // first frame the backend flushes after the command). EvTriage drives the events + jumps; we log [HT].
    readonly property bool _htOn: (typeof wtHeroTest !== "undefined" && wtHeroTest === true)
    property int testFrames: 0
    property bool _htOpenPending: false
    property double _htOpenT0: 0
    property bool _htSeekPending: false
    property double _htSeekT0: 0
    property int _htSeekFramesAt: 0
    property int _htSeekReq: 0
    readonly property real testDurMs: player.duration
    function testSeek(deltaMs) {
        if (player.playbackState !== MediaPlayer.PlayingState) player.play();   // paused seeks render nothing
        _htSeekReq = deltaMs; _htSeekT0 = Date.now(); _htSeekFramesAt = testFrames; _htSeekPending = true;
        if (typeof wtSeekDirect !== "undefined" && wtSeekDirect)               // validation: direct demuxer seek, NO re-open
            _seekWall(Math.max(tlStartMs, Math.min(tlEndMs, _playheadWallMs + deltaMs)));   // lands iff the session is continuous
        else
            seekToWall(_playheadWallMs + deltaMs);                              // the REAL seek path (near direct / far re-open)
    }
    // ---- soak iteration-two probe hooks (2026-08-20, mac). All inert without WT_HERO_TEST. ----
    function testPause()  { player.pause() }
    function testResume() { player.play() }
    // P6 (paused-seek staleness): the USER's path — a scrubber click while paused goes through
    // seekToWall with NO play(); testSeek() deliberately force-plays, which is exactly what
    // would mask the stale-frame suspect this probe hunts. So this hook stays paused.
    function testSeekPausedWall(wallMs) { seekToWall(Math.max(tlStartMs, Math.min(tlEndMs, wallMs))) }
    readonly property bool   testLoading: _loading
    readonly property string testError: _error
    readonly property double testWallMs: _playheadWallMs
    readonly property double testTlStartMs: tlStartMs
    readonly property double testTlEndMs: tlEndMs
    readonly property bool   testPaused: player.playbackState === MediaPlayer.PausedState
    readonly property double testPosMs: player.position     // raw media position — P6 needs it to tell
                                                             // "seek ignored" from "seek landed, OSD stale"
    function testShotVideo(path) { _probeGrab(vout, path) }
    function _probeGrab(item, path) {
        if (!_htOn || !item || !item.visible) return;
        try {
            item.grabToImage(function (r) {
                console.log("[SHOT] " + (r.saveToFile(path) ? "saved " : "FAILED ") + path);
            });
        } catch (e) { console.log("[SHOT] grab threw: " + e); }
    }
    // P1 (measured-snap application): the yellow must VISIBLY move once measurement exists.
    // Shot A = scrubber drawn from the camera stamp (taken when the clip lights, measurement
    // still −1); shot B = right after [MSCAN] span start MEASURED applies. Paired PNGs +
    // a numeric [P1] line (normalized draw positions + px offset) — quota 12 pairs per run.
    property int _p1Pairs: 0
    property string _p1AEv: ""
    Timer {
        id: p1ShotA; interval: 400; repeat: false
        onTriggered: {
            if (!hp._lit || hp.mkMeasuredMs > 0 || !hp.ev) return;
            hp._p1AEv = hp.ev.id;
            hp._probeGrab(scrub, "scratchpad/soak-mac/shots/p1-" + hp.ev.id + "-A.png");
        }
    }
    Timer {
        id: p1ShotB; interval: 400; repeat: false
        onTriggered: {
            if (!hp.ev || hp.ev.id !== hp._p1AEv || hp.mkMeasuredMs <= 0) return;
            var span = hp.tlEndMs - hp.tlStartMs;
            if (span <= 0) return;
            var stampN = (hp.mkStartMs - hp.tlStartMs) / span;
            var measN  = (hp.mkMeasuredMs - hp.tlStartMs) / span;
            console.log("[P1] pair ev=" + hp.ev.id + " stampN=" + stampN.toFixed(4)
                        + " measN=" + measN.toFixed(4) + " dxPx=" + (scrub._w * (measN - stampN)).toFixed(1));
            hp._probeGrab(scrub, "scratchpad/soak-mac/shots/p1-" + hp.ev.id + "-B.png");
            hp._p1Pairs++; hp._p1AEv = "";
        }
    }
    on_LitChanged: if (_htOn && _lit && typeof wtMarkerTest !== "undefined" && wtMarkerTest
                       && mkMeasuredMs < 0 && _p1Pairs < 12) p1ShotA.restart()
    // Mid-play stall rescue: review-session segments are cut LAZILY server-side, and the FFmpeg
    // demuxer can abandon a VOD playlist after 404s on a not-yet-ready segment (measured
    // 2026-08-17, CV logs: the Mac's sessions fetched seg 0-1, retried seg 2 four times in
    // ~1.2 s, then never asked again — the picture froze while PlayingState kept running).
    // If the player claims Playing but ZERO frames render for ~6 s and the media hasn't ended,
    // re-open at the current wall position — the fresh playlist carries the now-cut segments.
    // Two rescues per user-initiated session, then the honest error path (no silent freeze,
    // no endless churn). Distinct from seekWatch (post-seek only); if both race, whichever
    // re-opens first sets _loading and disarms the other.
    property int _stallRescues: 0
    Timer {
        id: stallWatch
        interval: 3000; repeat: true
        running: hp._started && !hp._loading && hp._error === ""
                 && player.playbackState === MediaPlayer.PlayingState
                 && player.mediaStatus !== MediaPlayer.EndOfMedia
        property int _seqAt: -1
        property int _strikes: 0
        onRunningChanged: { _seqAt = -1; _strikes = 0; }
        onTriggered: {
            if (hp._frameSeq === _seqAt) {
                if (++_strikes >= 2) {                   // two 3s ticks = ~6s playing with no rendered frame
                    _strikes = 0;
                    if (hp._stallRescues < 2) {
                        hp._stallRescues++;
                        console.log("[HERO] STALL reopen #" + hp._stallRescues
                                    + " wall=" + Math.round(hp._playheadWallMs) + " seq=" + hp._frameSeq);
                        hp._seekFar(hp._playheadWallMs);
                    } else {
                        console.log("[HERO] STALL gave up after 2 reopens");
                        player.pause();
                        hp._error = qsTr("Playback stalled — the recording backend stopped serving this window. Tap play to retry.");
                    }
                }
            } else {
                _strikes = 0;
            }
            _seqAt = hp._frameSeq;
        }
    }
    // Freeze-watchdog (LAST RESORT only): on a continuous session direct seeks land ~99% — the slow ones are
    // cold BASE renditions (S3 fetch, ~2-4s) that DO land, and re-opening hits the same cold base, so a tight
    // watchdog just churns. So it's deliberately long: it re-opens only a genuine >6s hang, never the cold tail.
    Timer {
        id: seekWatch; interval: 6000; repeat: false
        onTriggered: {
            if (hp._seekWatchSeq >= 0 && hp._frameSeq <= hp._seekWatchSeq) hp._seekFar(hp._seekWatchWall);
            hp._seekWatchSeq = -1;
        }
    }
    Connections {
        target: vout.videoSink
        function onVideoFrameChanged(frame) {
            hp._frameSeq++;
            hp.testFrames++;
            // Ignore the sink's clearing flush: stop()/source="" emits one EMPTY frame (measured:
            // "first frame" with status=0 dur=0 during teardown) — counting it would yield the
            // poster to a black stage. Real frames only arrive while a source is set.
            if (!hp._lit && String(player.source) !== "") {
                hp._lit = true;   // one line per session generation — the Mac-vs-Linux render discriminator
                console.log("[HERO] first frame gen=" + hp._gen + " status=" + player.mediaStatus
                            + " dur=" + player.duration);
            }
            if (hp._htOpenPending) {
                hp._htOpenPending = false;
                console.log("[HT] OPEN lat=" + (Date.now() - hp._htOpenT0) + " dur=" + Math.round(player.duration / 1000)
                            + " ev=" + (hp.ev ? hp.ev.id : "?") + " t=" + Date.now());
            } else if (hp._htSeekPending && !hp._loading && hp.testFrames > hp._htSeekFramesAt) {
                hp._htSeekPending = false;   // !_loading excludes a far-seek re-open's stop-flush; the real
                console.log("[HT] SEEK req=" + hp._htSeekReq + " lat=" + (Date.now() - hp._htSeekT0) + " t=" + Date.now());
            }
        }
    }

    Connections {
        target: player
        function onPositionChanged() {
            var d = player.duration;
            if (hp._compactDur > 0 && d > hp._compactDur * 1000 + hp._extInPlaceMs)
                d = hp._compactDur * 1000 + hp._extInPlaceMs;   // AVFoundation grows duration as it discovers over-served bytes
            var p = player.position;
            if (d > 0 && p > d) p = d;               // never track media beyond the declared clip
            if (Math.abs(p - hp._smoothMs) > 500) hp._smoothMs = p;
            // Authority = the CLIP WINDOW (tl*), not the session and not player.duration:
            // AVFoundation grows duration over the over-served bytes, and a far-seek
            // session is deliberately WIDER than the window (±15s margins) — a latch
            // anchored to either sails past the clip into black tail bytes (operator's
            // Mac 08-26: counter 01:25 of a 01:10 window, stopped on a black frame).
            var endMs = hp._frags.length > 0 ? hp._wallToPos(hp.tlEndMs) * 1000
                        : (hp._compactDur > 0 ? hp._compactDur * 1000 + hp._extInPlaceMs : d);
            if (endMs > 0 && player.position >= endMs - 120 && !hp._winStopped
                    && player.playbackState === MediaPlayer.PlayingState) {
                if (MotionScan.framesScanned === 0) {
                    // Scanner blind (map+readback both dead): no evidence whether movement
                    // continues, so never strand a possibly-live subject behind a hard stop —
                    // play the over-served tail out; counter/scrubber stay pinned at the
                    // declared end by the caps above. One line so the next log names it.
                    if (!hp._blindSaid) {
                        hp._blindSaid = true;
                        console.log("[HERO] declared end reached but the motion scanner saw 0 frames — playing through, extension unavailable (see [MSCAN])");
                    }
                    return;
                }
                hp._winStopped = true;               // cleared by seeks / replay / reopen
                player.pause();
                hp._smoothMs = Math.min(endMs, d > 0 ? d : endMs);
                var tailMotion = MotionScan.lastMotionPtsMs >= 0
                                 && hp._posToWall(MotionScan.lastMotionPtsMs) >= hp.tlEndMs - 2500;
                if (tailMotion && !hp._endFinal && hp._extGen < 4) {
                    hp._extGen++;
                    hp._extMs += 15000;
                    if (player.duration >= endMs + 14000 || hp._compactDur * 1000 >= endMs + 14000) {
                        // The +15s of footage is ALREADY decoded: the server serves whole
                        // source segments past the declared slice (08-25 letter), and
                        // player.duration just proved the bytes are here. Extend IN PLACE —
                        // no session reopen, no AVFoundation reload risk, no picture gap.
                        console.log("[HERO] motion continues at clip end — extending IN PLACE (+15s, step "
                                    + hp._extGen + "/4, media holds " + Math.round(player.duration / 1000) + "s)");
                        hp._extendInPlace(15000);
                    } else {
                        hp._extResumeWall = hp.tlEndMs;
                        console.log("[HERO] motion continues at clip end — extending window (+15s, step "
                                    + hp._extGen + "/4)");
                        hp._extending = true;
                        hp._open();
                        if (hp.ev && hp.ev.id) hp._learnedWin[String(hp.ev.id)] = { endWall: hp.tlEndMs };
                    }
                } else if (typeof wtTrace !== "undefined" && wtTrace) {
                    console.log("[HERO] window hard-stop at declared end (" + Math.round(endMs) + "ms)");
                }
            }
        }
        function onPlaybackStateChanged() {
            if (player.playbackState !== MediaPlayer.PlayingState) {
                var cap = player.duration > 0 ? player.duration : player.position;
                if (hp._compactDur > 0) cap = Math.min(cap, hp._compactDur * 1000 + hp._extInPlaceMs);
                hp._smoothMs = Math.min(player.position, cap);
            }
        }
    }

    // On-demand: a new event shows its snapshot poster; the recording loads only on a play-tap.
    // Auto-loading + the tab-switch teardown were the two events-browsing leaks (each ~+44 MB/min).
    property bool _started: false
    // Session OWNERSHIP: the shared PlaybackClient broadcasts sessionReady to
    // every consumer (playback tabs + this hero). Tag every open with uid+gen
    // and drop foreign/stale replies — the 2026-08-04 black-square bug was a
    // playback tab and the hero consuming each other's sessions.
    property string _uid: ""
    property int _gen: 0
    Component.onCompleted: { _uid = "hero" + Date.now() % 1000000; MotionScan.attach(vout.videoSink); }
    readonly property string _curTag: _uid + ":" + _gen
    // PREFETCH-ON-SELECTION (500 ms clip budget, 2026-08-04): the moment an
    // event is selected, open its review session in the BACKGROUND and hold
    // only the JSON payload — no player.source, no decode (the +44 MB/min
    // events leak was autoplay DECODE, not session JSON). The play-tap then
    // ADOPTS the held session and pays decode only. A new selection
    // supersedes; misses fall back to the normal open silently.
    property var _pre: null              // { evId, tag, sid, dur, fragments, meta, bornMs }
    property int _preGen: 0
    property string _preTag: ""
    function _prefetch() {
        if (!ev || !ev.id || !playbackClient) return;
        _preGen++;
        _preTag = _uid + ":pre" + _preGen;
        _pre = null;
        var w = EventsStore.episodeWindow(ev);
        playbackClient.ensureReady();
        playbackClient.openSession(ev.cam.id,
            new Date(w.startMs - padPreMs).toISOString(),
            new Date((w.endMs > w.startMs ? w.endMs : w.startMs + 1000) + padPostMs).toISOString(),
            true, _preTag);
    }
    Timer {
        id: autoplayDelay
        interval: (typeof wtHeroAutoplayMs !== "undefined" && wtHeroAutoplayMs > 0) ? wtHeroAutoplayMs : 1
        repeat: false
        onTriggered: hp._open()
    }
    // Identity guard (the LiveThumb lesson, same day): every events refresh rebuilds ALL row
    // objects (EventsStore.ingestReal ends with `events = out`; ack/dispose remap the list),
    // so EvTriage._cur hands this player a NEW object for the SAME episode on every poll and
    // on every triage action. Without the guard each refresh ran _reset() — player.stop(),
    // source = "", playhead to 0 — so a playing clip rewound to 00:00 at poll cadence, which
    // lands right as the playhead reaches the motion span (pre-roll ≈ poll interval; operator
    // report 2026-08-17, reproduced: 6 session re-dispatches in 52 s with zero user input).
    // Tear down only when the EPISODE ID actually changes. An in-progress episode keeps the
    // window it was opened with (no silent re-open mid-watch); reselecting re-opens fresh.
    property string _evId: ""
    property int _zeroFragRetries: 0
    Timer {   // in-progress event, no fragments cut yet: re-open until footage appears (bounded)
        id: zeroFragRetry
        interval: 5000; repeat: false
        onTriggered: if (hp.ev && hp.ev.id === hp._evId && hp._error !== "") hp._open()
    }
    onEvChanged: {
        var nid = (ev && ev.id) ? String(ev.id) : "";
        if (nid !== "" && nid === hp._evId) return;      // same episode, rebuilt object — keep the session
        hp._evId = nid;
        hp._zeroFragRetries = 0; zeroFragRetry.stop();
        hp._extGen = 0; hp._extMs = 0; hp._extInPlaceMs = 0; hp._extResumeWall = -1; hp._extending = false; hp._endFinal = false;
        hp._reset(); hp._pre = null; hp._preTag = "";
        // The timeline is knowable from event data alone — set it NOW so the scrubber has real
        // geometry and the transport shows the true duration before the first play-tap (it read
        // 00:00/00:00 pre-play, and a pre-play scrubber click had no span to map the X into).
        if (ev && ev.id) {
            var w0 = EventsStore.episodeWindow(ev);
            hp.mkStartMs = w0.startMs; hp.mkEndMs = (w0.endMs > w0.startMs ? w0.endMs : w0.startMs + 1000);
            hp.tlStartMs = hp.mkStartMs - hp.padPreMs; hp.tlEndMs = hp.mkEndMs + hp.padPostMs;
            var lw0 = hp._learnedWin[nid];
            if (lw0 && lw0.endWall > hp.tlEndMs)
                hp.tlEndMs = Math.min(lw0.endWall, hp.mkStartMs + 120000);
        }
        hp._prefetch();
        if (typeof wtHeroAutoplay !== "undefined" && wtHeroAutoplay) {
            if (typeof wtHeroAutoplayMs !== "undefined" && wtHeroAutoplayMs > 0) autoplayDelay.restart();
            else hp._open();
        }
    }
    Component.onDestruction: { player.stop(); player.source = ""; }

    // Views are kept alive (StackLayout), so pause the recording when Triage isn't the shown tab.
    property bool surfaced: true
    onSurfacedChanged: if (!surfaced && player.playbackState === MediaPlayer.PlayingState) player.pause()

    function _reset() {
        heroStepper.invalidate();   // cached frames belong to the torn-down clip
        _started = false; _loading = false; _error = ""; _sid = ""; _frags = []; _armed = false; _lit = false;
        mkMeasuredMs = -1; mkMeasuredEndMs = -1; _mktDone = false; MotionScan.reset();
        if (typeof MemTel !== "undefined") MemTel.trimNow();   // return retained decode arenas at teardown
        _pendingSeekMs = -1; _smoothMs = 0; _seekingToWall = -1; _continuous = false;
        seekWatch.stop(); _seekWatchSeq = -1; player.stop(); player.source = "";
    }
    function _open() {
        if (!ev || !ev.id || !playbackClient) return;
        heroStepper.invalidate();   // fresh session: cache/divergence are stale
        _started = true;
        if (_htOn) { _htOpenT0 = Date.now(); _htOpenPending = false; _htSeekPending = false; }   // armed in onSessionReady
        _gen++;
        openDeadline.restart();
        _loading = true; _error = ""; _sid = ""; _frags = []; _armed = false; _speed = 1; _smoothMs = 0; _seekingToWall = -1; _winStopped = false; _blindSaid = false;
        _lit = false;                                    // fresh session: poster holds until ITS first frame
        // Extension reopen keeps the measured START (wall-anchored, session-independent);
        // the end re-measures against the wider window. A fresh event wipes everything.
        if (!_extending) { mkMeasuredMs = -1; _extGen = 0; _extMs = 0; _extInPlaceMs = 0; _extResumeWall = -1; _endFinal = false; }
        mkMeasuredEndMs = -1; _mktDone = false;
        MotionScan.attach(vout.videoSink);               // re-claim on every open (parity with _seekFar)
        MotionScan.reset();
        player.stop(); player.source = ""; player.playbackRate = 1;
        // Open EXACTLY the episode [start, end] (+15s margins) so a clip never spills into a neighbouring
        // episode's footage. EventsStore joins the motion lifecycle and normalises ev.ts to the episode
        // START, so this is a forward window with the footage (recording is motion-triggered: the episode's
        // recording_id covers [start, end]). Verified live on .106: 188 / 28 ready fragments.
        var w = EventsStore.episodeWindow(ev);
        mkStartMs = w.startMs; mkEndMs = (w.endMs > w.startMs ? w.endMs : w.startMs + 1000);   // the movement span
        // Timeline = the OPENED window (episode ± the profile roll), not the bare
        // episode: playback starts in the pre-roll, and a scrubber that clamps the
        // pre-roll to 00:00 reads as "not playing" while the picture visibly runs
        // (operator screenshots, 2026-08-06: OSD ticking with the counter frozen).
        tlStartMs = mkStartMs - padPreMs; tlEndMs = mkEndMs + padPostMs + _extMs;   // _extMs: motion-follows growth
        var lw = (ev && ev.id) ? _learnedWin[String(ev.id)] : null;
        if (lw && lw.endWall > tlEndMs) {
            tlEndMs = Math.min(lw.endWall, mkStartMs + 120000);
            console.log("[HERO] learned window applied: total " + Math.round((tlEndMs - tlStartMs) / 1000) + "s");
        }
        // Extension: resume just before the previous end for continuity; fresh open lands at the head.
        _pendingSeekMs = (_extending && _extResumeWall > 0)
                         ? Math.max(tlStartMs, _extResumeWall - 1500) : tlStartMs;
        // ADOPT a fresh prefetched session: the tap pays decode only.
        if (!_extending && _pre && ev && _pre.evId === ev.id && _pre.fragments.length > 0
            && Date.now() - _pre.bornMs < 120000) {
            if (_htOn) console.log("[HT] ADOPT pre age=" + (Date.now() - _pre.bornMs) + " t=" + Date.now());
            openDeadline.stop();
            var pre = _pre; _pre = null;
            _applySession(pre.sid, pre.dur, pre.fragments, pre.meta);
            return;
        }
        playbackClient.ensureReady();
        playbackClient.openSession(ev.cam.id,
            new Date(tlStartMs).toISOString(),
            new Date(tlEndMs).toISOString(), true, _curTag);
        _extending = false; _extResumeWall = _extResumeWall > 0 ? -1 : _extResumeWall;   // consumed (pendingSeek already holds the resume)
    }
    // Seek to a WALL time on the episode timeline.
    //  • CONTINUOUS session (Cilex Vision route B): direct seeks land within a contiguous run, so we seek
    //    directly and only RE-OPEN proactively when the jump crosses a kept boundary (gap/codec/profile/
    //    pts_wrap — a discontinuity:true fragment). The freeze-watchdog re-opens the rare flaky tail.
    //  • LEGACY session: every fragment is a discontinuity the FFmpeg demuxer can't seek across (56% of
    //    jumps froze, 58-79% for ≥10s), so anything past a tiny in-buffer nudge re-opens a short window at
    //    the target — the A1 PlaybackScreen workaround. Either way the episode timeline (tl*) is kept.
    function seekToWall(wall) {
        // Pre-play (or failed) scrub: a silent no-op is a banned dead control — load the
        // recording AND land on the clicked moment. _open() sets _pendingSeekMs to the display
        // start; override it with the click target after the call (tl* are valid pre-open now).
        if (!_started || _error !== "") {
            if (!ev || !ev.id || !playbackClient) return;
            _open();
            _pendingSeekMs = Math.max(tlStartMs, Math.min(tlEndMs, wall));
            _seekingToWall = _pendingSeekMs;   // hold the scrubber at the click while the session loads
            return;
        }
        heroStepper.invalidate();   // a real seek supersedes any cache-step state / in-flight step
        _winStopped = false;        // a scrub away from the end re-arms the hard-stop latch
        wall = Math.max(tlStartMs, Math.min(tlEndMs, wall));
        if (_continuous) {
            if (_armed && _frags.length > 0 && _crossesBoundary(_playheadWallMs, wall)) { _seekFar(wall); return; }
            _seekWall(wall);
            _seekWatchSeq = _frameSeq; _seekWatchWall = wall; seekWatch.restart();   // arm the freeze-watchdog
            return;
        }
        if (_armed && _frags.length > 0 && Math.abs(wall - _playheadWallMs) <= 3000) { _seekWall(wall); return; }
        _seekFar(wall);
    }
    // Does the wall jump [from,to] step over a kept discontinuity:true fragment? (The leading "start" sits at
    // the run start ≤ from, so a normal mid-clip seek never crosses it — only real gaps/codec/profile/wrap.)
    function _crossesBoundary(fromWall, toWall) {
        var lo = Math.min(fromWall, toWall), hi = Math.max(fromWall, toWall);
        for (var i = 0; i < _frags.length; i++)
            if (_frags[i].disc && _frags[i].ws > lo && _frags[i].ws <= hi) return true;
        return false;
    }
    function _seekFar(wall) {
        if (!ev || !playbackClient) return;
        heroStepper.invalidate();   // re-open supersedes cache/divergence
        var ep = EventsStore.episodeWindow(ev);
        if (_htOn) console.log("[HT] REOPEN cont=" + _continuous + " t=" + Date.now());   // re-open count = the leak proxy
        seekWatch.stop(); _seekWatchSeq = -1;                            // a re-open supersedes any pending direct-seek watch
        _gen++;
        openDeadline.restart();
        _loading = true; _armed = false; _frags = []; _pendingSeekMs = wall; _seekingToWall = wall;
        _lit = false;                                    // re-open: poster holds until the landed frame renders
        MotionScan.attach(vout.videoSink);               // re-claim every open: an attach lost to sink churn = blind scanner
        MotionScan.reset();                              // new compact timeline: old PTS mapping is void
        player.stop(); player.source = "";
        playbackClient.ensureReady();
        playbackClient.openSession(ev.cam.id,
            new Date(wall - 15000).toISOString(),
            new Date(Math.max(ep.endMs, wall) + 15000).toISOString(), true, _curTag);
    }

    // compact player-seconds ↔ wall ms (via the session's ready fragments)
    function _wallToPos(ms) {
        for (var i = 0; i < _frags.length; i++) {
            var f = _frags[i];
            if (ms >= f.ws && ms <= f.we)
                return f.cs + ((f.we > f.ws) ? (ms - f.ws) / (f.we - f.ws) : 0) * (f.ce - f.cs);
        }
        for (var j = 0; j < _frags.length; j++) if (_frags[j].ws >= ms) return _frags[j].cs;
        return _compactDur;
    }
    // compact player-position (ms) → wall ms — inverse of _wallToPos, for the on-screen timestamp
    function _posToWall(compactMs) {
        var sec = compactMs / 1000;
        for (var i = 0; i < _frags.length; i++) {
            var f = _frags[i];
            if (sec >= f.cs && sec <= f.ce)
                return f.ws + ((f.ce > f.cs) ? (sec - f.cs) / (f.ce - f.cs) : 0) * (f.we - f.ws);
        }
        if (!_frags.length) return 0;
        // Beyond the DECLARED media (backends can serve more bytes than the playlist
        // declares — the 08-25 over-serve): clamp to the window END. The old fallback
        // returned frags[0].ws, which WRAPPED the playhead to the window start the
        // moment position outran the declaration — the operator's original symptom.
        if (sec > _frags[_frags.length - 1].ce) return _frags[_frags.length - 1].we;
        return _frags[0].ws;
    }
    // Motion-follows growth WITHOUT a reopen: the over-served tail is already decoded, so
    // the window, the fragment map and the transport just widen around it. The end
    // re-measures against the wider window (MKT re-runs); the measured START is untouched.
    function _extendInPlace(ms) {
        _extInPlaceMs += ms;
        tlEndMs += ms;
        if (_frags.length > 0) {
            var last = _frags[_frags.length - 1];
            last.ce += ms / 1000; last.we += ms;
            _frags = _frags.slice();                     // reassign so bindings see the wider map
        }
        mkMeasuredEndMs = -1; _mktDone = false;
        _winStopped = false;
        if (ev && ev.id) _learnedWin[String(ev.id)] = { endWall: tlEndMs };
        player.play();
    }
    function _seekWall(ms) {
        var pos = _wallToPos(ms);
        var cd = _compactDur + _extInPlaceMs / 1000;     // in-place growth is seekable media
        // Dead zone at the end is 1s, not 3: the old -3 made the scrubber refuse
        // everything past 0:37 of an extended 40s window (operator, 08-26).
        if (cd > 1) pos = Math.min(pos, cd - 1);
        player.position = Math.round(Math.max(0, pos) * 1000);
    }
    function _fmt(ms) { var s = Math.max(0, Math.round(ms / 1000)); return EventsStore._p2(Math.floor(s / 60)) + ":" + EventsStore._p2(s % 60); }
    // Session-open deadline: the backend's session opens are known to flap
    // (day-open letters); without this, a hang left the hero black on
    // "Loading recording…" forever — the 2026-08-04 report. Honest error +
    // tap-to-retry instead.
    Timer {
        id: openDeadline
        interval: 25000; repeat: false
        onTriggered: if (hp._loading) {
            hp._loading = false;
            hp._error = qsTr("The recording backend did not answer in 25 s — tap play to retry.");
            console.log("[HERO] OPEN DEADLINE ev=" + (hp.ev ? hp.ev.id : "?"));
        }
    }
    function toggle() {   // Space / play button: first press loads the recording on demand
        if (!hp._started) { hp._open(); return; }
        if (hp._error !== "") { hp._open(); return; }    // tap-to-retry after deadline/failure
        if (player.playbackState === MediaPlayer.PlayingState) {
            player.pause();
        } else {
            // Play at the hard-stopped end = replay: restart the clip, don't resume
            // into the undeclared tail bytes the server over-served.
            if (hp._winStopped) { hp._winStopped = false; player.position = 0; hp._smoothMs = 0; }
            heroStepper.resumeForPlay();   // if a cache-stepped frame is shown, play from IT
            player.play();
        }
    }

    // Single-frame stepping on the hero player (docs/plans/2026-07-08-frame-step-plan.md P4)
    // — the same engine as PlaybackScreen. Event clips are short single-window sessions,
    // so the simple paths dominate; edge steps route into the hero's own wall-seek.
    FrameStepper {
        id: heroStepper
        mediaPlayer: player
        videoSink: vout.videoSink
        requestPause: function() { if (player.playbackState === MediaPlayer.PlayingState) player.pause(); }
        crossesDisc: function(fromMs, toMs) {
            return hp._armed && hp._frags.length > 0
                   && hp._crossesBoundary(hp._posToWall(fromMs), hp._posToWall(toMs));
        }
        edgeFallback: function(dir) {
            var dur = FrameClock.medianFrameDurMs > 1 ? FrameClock.medianFrameDurMs : 50;
            hp.seekToWall(hp._playheadWallMs + dir * Math.max(40, dur));
        }
        veilGrab: function() {
            vout.grabToImage(function(res) { hp._veilRes = res; heroVeil.source = res.url; });
        }
    }
    property var _veilRes: null   // keeps the grab result alive while the veil shows it
    Connections {                 // playhead follows the step cursor while diverged
        target: heroStepper
        function onStepped(dir, ptsDeltaMs, latMs, retries) {
            if (heroStepper.diverged) hp._smoothMs = Math.max(0, heroStepper.cursorPosEstMs);
        }
    }

    // The single application path for a ready session — used by the LIVE
    // handler below and by prefetch ADOPTION in _open() (never duplicated:
    // the seek-path lesson).
    function _applySession(sid, dur, fragments, meta) {
        hp._sid = sid; hp._compactDur = dur; hp._extInPlaceMs = 0;   // a fresh session declares its WHOLE window
        hp.__applyRest(fragments, meta);
    }
    Connections {
        target: hp.playbackClient
        enabled: hp.playbackClient !== null
        function onSessionReady(sid, dur, fragments, meta, tag) {
            if (tag === hp._preTag) {                    // background prefetch landed: HOLD, no decode
                hp._pre = { evId: (hp.ev ? hp.ev.id : ""), sid: sid, dur: dur,
                            fragments: fragments, meta: meta, bornMs: Date.now() };
                if (hp._htOn) console.log("[HT] PRE ready ev=" + (hp.ev ? hp.ev.id : "?") + " t=" + Date.now());
                return;
            }
            if (tag !== hp._curTag) return;              // foreign consumer's session, or our own stale re-open
            openDeadline.stop();
            hp._applySession(sid, dur, fragments, meta);
        }
        function onSessionFailed(err, tag) {
            if (tag === hp._preTag) { hp._preTag = ""; return; }   // speculation dies silently
            if (tag !== hp._curTag) return;
            openDeadline.stop();
            hp._loading = false; hp._error = err;
            if (typeof wtTrace !== "undefined" && wtTrace) console.log("[HERO] session FAILED: " + err);
        }
    }
    function __applyRest(fragments, meta) {
        var out = [];
        for (var i = 0; i < fragments.length; i++) {
            // Positional primitive row (pre-filtered "ready" in PlaybackClient):
            // [cs, ce, wsMs, weMs, disc, boundary, …] — see PlaybackScreen.onSessionReady.
            var f = fragments[i];
            out.push({ cs: f[0], ce: f[1], ws: f[2], we: f[3],
                       disc: !!f[4], boundary: f[5] || "" });   // kept-discontinuity markers (§4-ii)
        }
        hp._frags = out;
        hp._continuous = !!(meta && meta.seek_mode === "continuous");   // ⇒ direct seeks, re-open only at boundaries
        hp._armed = true;
        if (typeof wtTrace !== "undefined" && wtTrace)
            console.log("[HERO] session ready: " + out.length + " ready fragments · ev=" + (ev ? ev.rawType : "?")
                        + " dur=" + (ev ? ev.durationSec : 0) + "s");
        if (out.length === 0) {
            hp._loading = false;
            // A seconds-old in-progress event legitimately has NO cut fragments yet — declaring
            // "no footage" there is premature (operator hit it twice, 2026-08-17). Say the true
            // state and retry; only an event old enough that footage MUST exist gets the verdict.
            var ageMs = (hp.ev && hp.ev.ts) ? (Date.now() - hp.ev.ts.getTime()) : 1e9;
            if (ageMs < 90000 && hp._zeroFragRetries < 6) {
                hp._zeroFragRetries++;
                hp._error = qsTr("Recording in progress — waiting for the first footage…");
                zeroFragRetry.restart();
            } else {
                hp._error = qsTr("No footage recorded around this moment.");
            }
            return;
        }
        hp._zeroFragRetries = 0;
        hp._loading = false; hp._error = "";
        if (typeof wtHeroNoplay === "undefined" || !wtHeroNoplay) {   // leak bisect: WT_HERO_NOPLAY skips the decode
            player.source = hp.playbackClient.playlistUrl(hp._sid);
            if (typeof MemTel !== "undefined") MemTel.noteOpen();
            player.play();
        }
        if (hp._htOn) {                                   // arm the latency detector for the new session
            hp.testFrames = 0;
            if (hp._htSeekPending) hp._htSeekFramesAt = 0;   // far-seek re-open: next frame = the seek landing
            else hp._htOpenPending = true;                    // fresh event open
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ---- video surface ----
        Rectangle {
            Layout.fillWidth: true
            // fillStage → every spare pixel is picture (PreserveAspectFit inside,
            // so the frame scales to the largest size that fits, never stretched).
            Layout.fillHeight: hp.fillStage
            Layout.minimumHeight: hp.fillStage ? 140 : 0
            Layout.preferredHeight: hp.fillStage ? -1 : Math.min(hp.maxStageH, Math.round(width * 9 / 21))
            color: "#000"; clip: true

            VideoOutput { id: vout; anchors.fill: parent; fillMode: VideoOutput.PreserveAspectFit }
            // Freeze-frame veil: holds the pre-step image while a backward step's
            // recovery (overseek + frame-walk) churns frames underneath.
            Image {
                id: heroVeil
                anchors.fill: parent
                fillMode: Image.PreserveAspectFit
                cache: false
                visible: heroStepper.veiled && status === Image.Ready
            }
            MediaPlayer {
                id: player
                videoOutput: vout
                audioOutput: null
                playbackRate: hp._speed
                onPlaybackStateChanged: if (typeof MemTel !== "undefined") MemTel.setPlaying(1, playbackState === MediaPlayer.PlayingState)
                // Errors are rare and precious — always logged. Status flaps over HLS — trace only.
                onErrorOccurred: (error, errorString) =>
                    console.log("[HERO] player ERROR " + error + " '" + errorString + "' status=" + mediaStatus)
                onMediaStatusChanged: if (typeof wtTrace !== "undefined" && wtTrace)
                    console.log("[HERO] status=" + mediaStatus + " state=" + playbackState + " pos=" + position)
                // Seek to the event once the pipeline is seekable (a position set on
                // durationChanged before preroll is dropped). Land on the recorded
                // footage CLOSEST to the event — same logic as PlaybackScreen.
                function _applySeek() {
                    if (!hp._armed || hp._loading || !(seekable && duration > 0 && hp._pendingSeekMs >= 0)) return;
                    var target = hp._pendingSeekMs;      // wall ms to LAND on (display start, or the scrub click)
                    var bestWall = -1, bestD = Infinity;
                    for (var i = 0; i < hp._frags.length; i++) {
                        var f = hp._frags[i], d, w;
                        if (target >= f.ws && target <= f.we) { d = 0; w = target; }
                        else if (target > f.we) { d = target - f.we; w = f.we - 3000; }
                        else { d = f.ws - target; w = f.ws; }
                        if (d < bestD) { bestD = d; bestWall = w; }
                    }
                    hp._seekWall(bestWall >= 0 ? bestWall : target);
                    hp._pendingSeekMs = -1; hp._seekingToWall = -1;   // landed → release the held scrubber playhead
                }
                onSeekableChanged: _applySeek()
                onDurationChanged: _applySeek()
            }

            // poster: the real event frame until the recording is rendering. The player
            // draws its OWN top-left identity (below), so suppress the poster's to avoid
            // the PLAYBACK chip overlapping it.
            EvSnapshot {
                anchors.fill: parent
                // Yield to the video on RENDERED FRAMES (_lit), never on mediaStatus: macOS's FFmpeg
                // backend plays HLS without ever reporting BufferedMedia, so the enum gate left this
                // poster (and its "● LIVE" fallback chip) covering a playing recording forever.
                visible: hp._loading || hp._error !== "" || !hp._lit
                ev: hp.ev; showOsd: true; showIdent: false; showPlayhead: false; fitMode: true
                probeTag: hp._htOn ? "hero" : ""            // P4 poster-honesty telemetry (soak only)
            }
            // on-demand affordance: tap the poster to load + play (recordings are NOT auto-loaded — see _reset)
            MouseArea {
                anchors.fill: parent
                visible: !hp._started && !hp._loading && hp._error === ""
                enabled: visible; cursorShape: Qt.PointingHandCursor
                onClicked: hp._open()
            }
            Rectangle {
                anchors.centerIn: parent
                visible: !hp._started && !hp._loading && hp._error === ""
                width: 56; height: 56; radius: 28
                color: Qt.rgba(0, 0, 0, 0.55); border.width: 1.5; border.color: "#ffffff"
                EvIcon { anchors.centerIn: parent; anchors.horizontalCenterOffset: 2; name: "play"; size: 22; color: "#ffffff" }
            }
            Text { visible: hp._loading; anchors.bottom: parent.bottom; anchors.left: parent.left; anchors.margins: 8
                text: qsTr("Loading recording…"); color: Theme.ink2; font.family: Theme.fontMono; font.pixelSize: 10 }
            Text { visible: hp._error !== ""; anchors.centerIn: parent; width: parent.width * 0.7
                text: hp._error; color: Theme.ink2; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
                font.family: Theme.fontSans; font.pixelSize: 12 }

            // top-left header: playback-state chip + camera identity (name · IP), laid
            // out in one Row so the chip never overlaps the identity (the reported bug).
            Row {
                anchors.top: parent.top; anchors.left: parent.left; anchors.topMargin: 8; anchors.leftMargin: 10
                anchors.right: parent.right; anchors.rightMargin: 10
                visible: !hp._loading && hp._error === ""
                spacing: 8
                Rectangle {                                // playback state chip
                    anchors.verticalCenter: parent.verticalCenter
                    color: Qt.rgba(0, 0, 0, 0.55); height: 18; width: stC.implicitWidth + 14
                    Text { id: stC; anchors.centerIn: parent
                        text: (player.playbackState === MediaPlayer.PlayingState ? "▶ " : "❚❚ ") + "PLAYBACK"
                        color: Theme.accent; font.family: Theme.fontMono; font.pixelSize: 9; font.letterSpacing: 0.9 }
                }
                Rectangle {                                // camera identity: name · IP (backend id dropped — useless)
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !!(hp.ev && hp.ev.cam)
                    color: Qt.rgba(0, 0, 0, 0.55); height: 18
                    width: Math.min(idT.implicitWidth + 14, hp.width - stC.implicitWidth - 150)
                    Text { id: idT; anchors.centerIn: parent; width: parent.width - 12; elide: Text.ElideRight
                        // name + IP; skip the IP if the name already carries it (avoid doubling)
                        text: {
                            if (!hp.ev || !hp.ev.cam) return "";
                            var nm = hp.ev.cam.name || "", ip = hp.ev.cam.ip || "";
                            return (ip && nm.indexOf(ip) < 0) ? (nm + "   ·   " + ip) : nm;
                        }
                        color: Qt.rgba(1, 1, 1, 0.92); font.family: Theme.fontMono; font.pixelSize: 11 }
                }
            }

            // wall-clock timestamp of the frame on screen (top-right OSD) — YYYY-MM-DD HH:MM:SS
            Rectangle {
                anchors.top: parent.top; anchors.right: parent.right; anchors.topMargin: 8; anchors.rightMargin: 10
                visible: hp._started && !hp._loading && hp._error === "" && hp._frags.length > 0
                         && hp._lit
                color: Qt.rgba(0, 0, 0, 0.6); height: 24; width: tsT.implicitWidth + 16
                Text { id: tsT; anchors.centerIn: parent
                    text: Qt.formatDateTime(new Date(hp._playheadWallMs), "yyyy-MM-dd HH:mm:ss")
                    color: "#ffffff"; font.family: Theme.fontMono; font.pixelSize: 14; font.weight: Font.Medium }
            }
        }

        // ---- merged control bar (40px, gapless cells — variant B §4) ----
        Rectangle {
            Layout.fillWidth: true; Layout.preferredHeight: 40; color: Theme.panel
            Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: Theme.line }

            component CtlCell: Rectangle {
                id: cc
                property string txt: ""
                property string ic: ""
                property string tip: ""
                property bool en: true
                property bool accented: false
                signal tapped()
                ToolTip.text: cc.tip
                ToolTip.visible: cc.tip !== "" && ccMa.containsMouse
                ToolTip.delay: 400
                Layout.fillHeight: true
                Layout.preferredWidth: Math.max(34, ccRow.implicitWidth + 16)
                color: ccMa.containsMouse && cc.en ? Theme.panel2 : "transparent"
                opacity: cc.en ? 1 : 0.4
                Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.line }
                Row {
                    id: ccRow; anchors.centerIn: parent; spacing: 0
                    EvIcon { visible: cc.ic !== ""; anchors.verticalCenter: parent.verticalCenter
                        name: cc.ic; size: 13; color: cc.accented ? Theme.accent : (ccMa.containsMouse ? Theme.ink : Theme.ink2) }
                    Text { visible: cc.txt !== ""; anchors.verticalCenter: parent.verticalCenter
                        text: cc.txt; color: ccMa.containsMouse ? Theme.ink : Theme.ink2
                        font.family: Theme.fontMono; font.pixelSize: 10 }
                }
                MouseArea { id: ccMa; anchors.fill: parent; hoverEnabled: true
                    cursorShape: cc.en ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: if (cc.en) cc.tapped() }
            }

            RowLayout {
                anchors.fill: parent; spacing: 0
                CtlCell { ic: "stepBack"; tip: qsTr("Previous frame"); en: hp._started && !heroStepper.busy
                    onTapped: heroStepper.stepBackward() }
                Rectangle {                                // play / pause
                    Layout.fillHeight: true; Layout.preferredWidth: 38
                    color: ppMa.containsMouse ? Theme.panel2 : "transparent"
                    Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.line }
                    Row { anchors.centerIn: parent; spacing: 3; visible: player.playbackState === MediaPlayer.PlayingState
                        Rectangle { width: 3; height: 12; color: Theme.ink } Rectangle { width: 3; height: 12; color: Theme.ink } }
                    EvIcon { anchors.centerIn: parent; visible: player.playbackState !== MediaPlayer.PlayingState; name: "play"; size: 14; color: Theme.ink }
                    MouseArea { id: ppMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: hp.toggle() }
                    ToolTip.text: player.playbackState === MediaPlayer.PlayingState ? qsTr("Pause") : qsTr("Play")
                    ToolTip.visible: ppMa.containsMouse
                    ToolTip.delay: 400
                }
                CtlCell { ic: "stepFwd"; tip: qsTr("Next frame"); en: hp._started && !heroStepper.busy
                    onTapped: heroStepper.stepForward() }
                CtlCell { txt: "\u221210"; tip: qsTr("Back 10 seconds"); onTapped: hp.seekToWall(hp._playheadWallMs - 10000) }
                CtlCell { txt: "+10"; tip: qsTr("Forward 10 seconds"); onTapped: hp.seekToWall(hp._playheadWallMs + 10000) }
                Rectangle {
                    Layout.fillHeight: true; Layout.preferredWidth: ctimeT.implicitWidth + 20
                    color: "transparent"
                    Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.line }
                    Text { id: ctimeT; anchors.centerIn: parent; textFormat: Text.StyledText
                        text: hp._fmt(hp._playheadWallMs - hp.tlStartMs) + " <font color='" + Theme.ink3 + "'>/</font> " + hp._fmt(hp.tlEndMs - hp.tlStartMs)
                        color: Theme.ink; font.family: Theme.fontMono; font.pixelSize: 11 }
                }
                Item {                                      // scrubber — spans the whole EPISODE timeline (tl*), not the loaded window
                    id: scrub
                    Layout.fillWidth: true; Layout.fillHeight: true
                    readonly property real _pad: 11
                    readonly property real _w: width - 2 * _pad
                    readonly property real _span: hp.tlEndMs - hp.tlStartMs
                    readonly property real _f: _span > 0 ? Math.max(0, Math.min(1, (hp._playheadWallMs - hp.tlStartMs) / _span)) : 0
                    function _seekX(x) { if (_span > 0) hp.seekToWall(hp.tlStartMs + Math.max(0, Math.min(_w, x - _pad)) / _w * _span); }
                    readonly property real _m0: _span > 0 ? Math.max(0, Math.min(1, ((hp.mkMeasuredMs > 0 ? hp.mkMeasuredMs : hp.mkStartMs) - hp.tlStartMs) / _span)) : 0
                    readonly property real _m1: _span > 0 ? Math.max(0, Math.min(1, ((hp.mkMeasuredEndMs > 0 ? hp.mkMeasuredEndMs : hp.mkEndMs) - hp.tlStartMs) / _span)) : 0
                    Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Theme.line }
                    Rectangle { x: parent._pad; anchors.verticalCenter: parent.verticalCenter; width: parent._w; height: 5; color: Theme.panel3 }
                    Rectangle { x: parent._pad; anchors.verticalCenter: parent.verticalCenter; height: 5; color: Theme.accent; width: parent._w * parent._f }
                    Rectangle {                            // movement start→finish — thin accent underline
                        anchors.verticalCenter: parent.verticalCenter; anchors.verticalCenterOffset: 7
                        x: parent._pad + parent._w * parent._m0
                        width: Math.max(2, parent._w * (parent._m1 - parent._m0)); height: 2
                        color: Theme.accent; opacity: 0.9
                    }
                    Rectangle { anchors.verticalCenter: parent.verticalCenter; width: 3; height: 15; color: Theme.ink
                        x: parent._pad + parent._w * parent._f - 1.5 }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                        onPressed: (m) => parent._seekX(m.x)
                        onReleased: (m) => parent._seekX(m.x) }
                }
                CtlCell { txt: hp._speed + "\u00d7"; tip: qsTr("Playback speed"); onTapped: hp._speed = (hp._speed === 1 ? 2 : hp._speed === 2 ? 4 : 1) }
                CtlCell { visible: hp.toolCells; ic: "link";     tip: qsTr("Copy share link"); onTapped: hp.linkRequested() }
                CtlCell { visible: hp.toolCells; ic: "export";   tip: qsTr("Export clip"); onTapped: hp.exportRequested() }
                CtlCell { visible: hp.toolCells; ic: "assign";   tip: qsTr("Assign to operator"); onTapped: hp.assignRequested() }
                CtlCell { visible: hp.toolCells; ic: hp.bookmarkOn ? "bookmarkF" : "bookmark"; accented: hp.bookmarkOn
                    tip: hp.bookmarkOn ? qsTr("Remove bookmark") : qsTr("Bookmark"); onTapped: hp.bookmarkRequested() }
            }
        }
    }
}