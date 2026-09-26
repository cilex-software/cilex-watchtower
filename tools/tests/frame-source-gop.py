#!/usr/bin/env python3
"""frame_source measures GOP from ONE demux pass, and must count what the decoders count.

WHY (2026-09-26). probe(measure_gop=True) used to decode every frame of a segment, then
decode its keyframes, only to learn the keyframe interval that spaces keyframe
timestamps. The Linux box measured that at ~4.1 of ~5.0 CPU-s per main segment. It now
counts packets from one `-c copy -f framecrc` pass: 1.75 CPU-s against 27.67 on 28
-sub files on this booth, with identical counts on all 28.

That is only safe while two things hold, so this pins both, plus the escape hatch:
  1. HERMETIC -- the framecrc parser: a keyframe is a line with no `F=`, or with bit
     0x1 set in it; `F=0x0` and `F=0x4` are not; '#' lines are header; CRLF is fine.
  2. REAL FFMPEG, where one works -- a synthetic clip of known GOP: demux counts equal
     decode counts, and probe reports the GOP. It SKIPs visibly with no ffmpeg or no
     usable encoder; the booth's LGPL build has no libx264, so libopenh264 and
     mpeg2video are tried after it.
  3. The cheap path is the one taken (the decode counter is booby-trapped), and a
     degenerate demux answer (every packet a keyframe, which is what a change to
     framecrc's F= convention would look like) falls back to decoding.

WT_NO_FS_GOP_PIN=1 skips it.
"""
import os, pathlib, subprocess, sys, tempfile

if os.environ.get("WT_NO_FS_GOP_PIN") == "1":
    sys.exit(0)

ROOT = pathlib.Path(__file__).resolve().parents[2]
LABS = pathlib.Path(os.environ.get("WT_FRAME_SOURCE_DIR", ROOT / "tools" / "labs"))
sys.path.insert(0, str(LABS))
import frame_source as fs   # noqa: E402

fails = []
def check(ok, what, detail=""):
    print(("PASS  " if ok else "FAIL  ") + what + ("" if ok else f"\n      {detail}"))
    if not ok:
        fails.append(what)

# ---------------------------------------------------------------- 1. the parser
CANNED = b"""#software: Lavf61.1.100
#tb 0: 1/90000
#media_type 0: video
#codec_id 0: h264
#dimensions 0: 640x360
#sar 0: 1/1
0,          0,          0,     6000,    12345, 0x11111111
0,       6000,       6000,     6000,     2345, 0x22222222, F=0x0
0,      12000,      12000,     6000,     2345, 0x33333333, F=0x0
0,      18000,      18000,     6000,    12345, 0x44444444, F=0x3
0,      24000,      24000,     6000,     2345, 0x55555555, F=0x4
0,      30000,      30000,     6000,    12345, 0x66666666, S=1,        8, 0x00000000
0,      36000,      36000,     6000,     2345, 0x77777777, F=0x0, S=1,        8, 0x00000000

"""
got = fs._parse_framecrc(CANNED)
check(got == (7, 3), "framecrc: 7 packets, 3 keys (no F=; F=0x3 keeps the key bit; S= side data)",
      f"got {got}")
got = fs._parse_framecrc(CANNED.replace(b"\n", b"\r\n"))
check(got == (7, 3), "framecrc: CRLF output (Windows stdout) counts the same", f"got {got}")
check(fs._parse_framecrc(b"") == (0, 0), "framecrc: empty output is (0, 0), not an error")

# ---------------------------------------------------------------- 2 + 3. real ffmpeg
try:
    ff = fs.find_ffmpeg()
except RuntimeError:
    ff = None

GOP, SECONDS, FPS = 15, 4, 15
tmp = tempfile.mkdtemp(prefix="wt-gop-")
clip, used = os.path.join(tmp, "clip.ts"), None
for enc in ("libx264", "libopenh264", "mpeg2video") if ff else ():
    p = subprocess.run(
        [ff, "-hide_banner", "-loglevel", "error", "-y",
         "-f", "lavfi", "-i", f"testsrc2=size=320x180:rate={FPS}", "-t", str(SECONDS),
         "-c:v", enc, "-g", str(GOP), "-bf", "0", "-pix_fmt", "yuv420p", "-f", "mpegts", clip],
        capture_output=True, timeout=60)
    if p.returncode == 0 and os.path.getsize(clip) > 0:
        used = enc
        break

if not used:
    print("SKIP  real-ffmpeg GOP checks -- "
          + ("no working ffmpeg on this box" if not ff else "no usable encoder (libx264/libopenh264/mpeg2video)"))
else:
    demux = fs._count_packets(ff, clip)
    decode = (fs._count_frames(ff, clip, keyframes_only=False),
              fs._count_frames(ff, clip, keyframes_only=True))
    check(demux == decode, f"demux counts == decode counts on a GOP-{GOP} clip ({used})",
          f"demux {demux} vs decode {decode}")
    check(demux == (SECONDS * FPS, SECONDS * FPS // GOP),
          f"demux counts are the clip's: {SECONDS * FPS} packets, {SECONDS * FPS // GOP} keys ({used})",
          f"got {demux}")

    real_count_frames = fs._count_frames
    def trap(*a, **k):
        raise AssertionError("probe DECODED to measure GOP")
    fs._count_frames = trap
    try:
        pr = fs.probe(clip, ff, measure_gop=True)
        check(pr.keyframe_gop == GOP, f"probe measures GOP {GOP} without decoding a frame",
              f"keyframe_gop={pr.keyframe_gop}")
    except AssertionError as e:
        check(False, f"probe measures GOP {GOP} without decoding a frame", str(e))
    finally:
        fs._count_frames = real_count_frames

    calls = []
    def recording(ff_, path, keyframes_only):
        calls.append(keyframes_only)
        return real_count_frames(ff_, path, keyframes_only)
    real_count_packets = fs._count_packets
    fs._count_packets = lambda *a, **k: (SECONDS * FPS, SECONDS * FPS)   # "every packet a key"
    fs._count_frames = recording
    try:
        pr = fs.probe(clip, ff, measure_gop=True)
        check(sorted(calls) == [False, True] and pr.keyframe_gop == GOP,
              "a degenerate demux answer (all keys) is re-counted by decoding, not believed",
              f"decode calls {calls}, keyframe_gop={pr.keyframe_gop}")
    finally:
        fs._count_packets, fs._count_frames = real_count_packets, real_count_frames

try:
    for f in os.listdir(tmp):
        os.unlink(os.path.join(tmp, f))
    os.rmdir(tmp)
except OSError:
    pass

if fails:
    print("\nFAIL  " + "\n\nFAIL  ".join(fails), file=sys.stderr)
    sys.exit(1)
print("all passed")
