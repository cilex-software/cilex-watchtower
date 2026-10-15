# Repeated Live stalls: read-only engineering review

Scope: installed development candidate DMG SHA-256
`d74c31e64feba38f71052b12c9153064cd8cad28a67b78cc01e9c00ee2973594`.
The retained Watchtower PID 56287 session is selected by its start marker.
Rows at uptime 30–420 seconds describe the original 31-source wall. The source
set changes to one at uptime 450 and then to playback; those later rows are
excluded from the wall diagnosis. No application, network, security, decoder,
or startup settings were changed by this investigation.

## Observed failure

This is recurrent delivery loss, not just startup latency. At uptime 60 and 90,
17 sources had not delivered for more than 25 seconds. The C++ backstop rebuilt
17 pipelines and all 31 delivered again at uptime 120–180. Later the wall lost
sources again: lit counts 30, 29, 28, 29, 27, 13, 15, 30 at uptime
210/240/270/300/330/360/390/420. Before the UI selection changed, the log had 39
`WT-SWD stall` and 39 `WT-SWD recovered` messages; no first-frame backstop cases.

All 31 pipelines remained decoder-bound and `err=0` throughout these wall
samples. `framesIn` also slowed when sink delivery slowed. Cumulative mailbox
coalescing was 4.0–7.6%, with RSS 726–882 MiB. Other sources continued to reach
the GUI during each failure. This weakens a global GUI delivery blockage as
the sole explanation, but aggregate counters cannot locate an individual
source's blocked stage. `framesIn` is counted only after successful NV12 mapping,
copying and empty-green filtering, so its name must not be mistaken for raw
RTP arrival or every decoder output.

Numeric evidence: `current-session-stream-counter-review.json`. Raw URLs,
tokens, camera names and configuration values are not copied into that file.

## Confirmed recovery defect

`qml/VideoSurface.qml:296` invokes `backend.item.reconnect()` only when the
backend wrapper exposes that method. The `qtmmComp` wrapper implements it at
line 416. The actual `lowLatencyComp` wrapper at lines 444–460 exposes only
playing/error properties and its nested `RtspVideoSource`; it has no reconnect
method forwarding to `rtsp.reconnect()`.

Consequently normal QML silent-stall retry calls become silent no-ops for this
RTSP backend. The independent C++ 75-second backstop remains able to recover.
The observed `recon == swd` for all 39 recoveries is consistent with this exact
omission. This explains unnecessarily long outages, not their initiating cause.
The frozen source snapshot and current `VideoSurface.qml` were byte-identical
when reviewed (SHA-256
`d8c2fb277e310192f560d610fd2f6d558e496818137ff59d0756c0077cce4957`).

Suggested repair, subject to parent coordination: expose the guarded RTSP
reconnect forwarding method and exercise the actual QML wrapper with a local
RTSP source that pauses after delivering frames. Prove QML-driven recovery
before the 75-second backstop; retain source-stall failure as a separate issue.

## Plausible initiating mechanisms, not established causes

1. **Transport backpressure or decoder/output blockage.** The default pipeline
   at `src/models/RtspVideoSource.cpp:761` has no explicit queue between rtspsrc
   and decodebin. The opt-in `WT_RTSP_QUEUE_MS` path at lines 738–758 documents
   a previously investigated TCP reader/decoder coupling failure on other
   platforms. `onNewSample` maps the decoded buffer, allocates and copies an
   NV12 QVideoFrame on the streaming thread (lines 913–974). A blocked decoder,
   map or copy can delay downstream progress. Existing evidence does not prove
   actual negotiated transport, blocked stack, packet arrival or VideoToolbox
   capacity on this run. The source comment is prior investigation evidence,
   not proof of this Mac's cause.
2. **Transport/server delivery interruption or timestamp/keyframe recovery.**
   Multiple independent streams fail while others work. The configured latency
   defaults to 150 ms in `VideoSurface.qml:456`; `drop-on-latency=true` is enabled.
   Network jitter, lost media or a producer issue remain possible. No network
   capture, server state or decoder warning establishes one here. The default
   allowed protocols include TCP and UDP, so absent `WT_RTSP_TCP` does not itself
   establish which transport was negotiated.
3. **A package-specific decoder change is presently a weaker explanation.**
   The generic bundle isolates 16 GStreamer plugins. However, the relevant
   bundled applemedia/rtsp/rtpmanager/playback/app/videoconvertscale binaries have
   the same Mach-O UUIDs as the host Homebrew 1.28.6 binaries used by the legacy
   workflow. `vtdec_hw` rank is 257; `vtdec` rank is 128. Both current Homebrew
   metadata lookups for `avdec_h264` and `openh264dec` fail too, so their absence
   in the bundle is not an observed fallback regression. Factory choice in the
   actual process remains unlogged; UUID comparison does not replace a runtime
   A/B test. Metadata and exact host hashes are in
   `current-session-gstreamer-metadata.json`.

The package's intentionally clean LaunchAgent environment removes the legacy
launchd `WT_TRACE=1`. The current LaunchAgent and allowlisted Warden APP_ENV have
no transport/decode/reconnect override. Consequently absence of decoder and
GUI-stall trace lines is missing evidence, not proof that those paths are healthy.

## Next discriminating evidence

Capture a bounded native thread sample during an actually stalled 31-source
wall, alongside per-source packet/decoder-output/mapped-frame/delivered-frame
counters and the selected decoder/transport. Compare against a healthy interval.
This can separate network silence, decoder wait, NV12 mapping/filtering and GUI
backpressure. An isolated multi-stream local RTSP comparison using bundled versus
host plugins can test package behavior without contacting cameras. Do not
declare a fix solely because earlier reconnects hide the outage, and do not
change watchdog thresholds, stream frame rates or network/security settings
without a measured reason.

Primary references consulted: GStreamer's [queue documentation](https://gstreamer.freedesktop.org/documentation/coreelements/queue.html)
describes the explicit thread boundary and queue blocking/leaky behavior;
[appsink documentation](https://gstreamer.freedesktop.org/documentation/app/appsink.html)
describes streaming-thread callbacks; [vtdec_hw documentation](https://gstreamer.freedesktop.org/documentation/applemedia/vtdec_hw.html)
identifies the hardware-only VideoToolbox factory and rank. These explain the
mechanisms and do not establish the observed Mac stall's cause.
