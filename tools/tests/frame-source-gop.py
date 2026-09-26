#!/usr/bin/env python3
"""frame_source reads GOP AND keyframe times from ONE demux pass, and must agree with
what the decoders count and the packets say.

WHY (2026-09-26), in two steps on one day:
  * COST. probe(measure_gop=True) decoded every frame of a segment, then its keyframes,
    only to learn the keyframe interval. The Linux box measured that at ~4.1 of ~5.0
    CPU-s per main segment. It now counts packets from one `-c copy -f framecrc` pass:
    1.75 CPU-s against 27.67 on 28 -sub files on the booth, identical counts on all 28.
  * TIMES. Keyframe times were t0 + i * round(total/keys) / fps. On a 15 s GOP-50
    segment, 5 keys in ~227 frames give 45, not 50: up to 1.28 s off, and 2.53 s on
    cameras that open each segment with two keys at one PTS. They are now each key
    packet's own PTS, from the same pass.

What is pinned:
  1. HERMETIC -- the framecrc parser: a keyframe is a line with no `F=`, or with bit
     0x1 set; `F=0x0`/`F=0x4` are not; '#' lines are header, `#tb` sets the time base;
     CRLF is fine; a same-PTS key pair is KEPT, twice; a key with no PTS, or no time
     base, times nothing rather than some.
  2. REAL FFMPEG, where one works (SKIP otherwise; the booth's LGPL build has no
     libx264, so libopenh264 and mpeg2video are tried after it):
     - demux counts == decode counts on a GOP-15 clip, and probe reports 15 with the
       decode counter booby-trapped; an all-keys demux answer falls back to decoding;
     - on a 15 s GOP-50 clip -- where the old constant step is ~1.3 s off -- every
       keyframe's t_offset_s equals its key packet's PTS, through iter_frames AND
       iter_concat (two files laid end to end).
  3. BOOTH FOOTAGE, only where the file exists (SKIP elsewhere): a real camera that
     opens every segment with TWO key packets one PTS tick apart (PTS 0 and 1 at
     90 kHz: 11 us) still yields BOTH frames, each at its own packet's time.
     (Corrected 2026-09-26: first reported as "two keys at one PTS". Rounded to 0.01 s
     they look identical; they are one tick apart. The hermetic case above still pins
     that an IDENTICAL-PTS pair is kept too.)

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

def close(a, b, eps=1e-6):
    return a is not None and b is not None and len(a) == len(b) and \
        all(abs(x - y) <= eps for x, y in zip(a, b))

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
pk = fs._parse_framecrc(CANNED)
check((pk.total, pk.keys) == (7, 3), "framecrc: 7 packets, 3 keys (no F=; F=0x3 keeps the key bit; S= side data)",
      f"got {(pk.total, pk.keys)}")
check(close(pk.key_times_s, (0.0, 0.2, 30000 / 90000)), "framecrc: key times are each key packet's PTS in #tb units",
      f"got {pk.key_times_s}")
check(pk.span_s is not None and abs(pk.span_s - 42000 / 90000) < 1e-9,
      "framecrc: span runs from the first PTS to the end of the last packet", f"got {pk.span_s}")
pk = fs._parse_framecrc(CANNED.replace(b"\n", b"\r\n"))
check((pk.total, pk.keys) == (7, 3) and close(pk.key_times_s, (0.0, 0.2, 30000 / 90000)),
      "framecrc: CRLF output (Windows stdout) parses the same", f"got {pk}")
pk = fs._parse_framecrc(b"")
check((pk.total, pk.keys, pk.key_times_s) == (0, 0, None), "framecrc: empty output is (0, 0), untimed, not an error",
      f"got {pk}")
DUP = b"#tb 0: 1/90000\n0, 0, 0, 6000, 9, 0x1\n0, 0, 0, 6000, 9, 0x2\n0, 6000, 6000, 6000, 9, 0x3, F=0x0\n" \
      b"0, 12000, 12000, 6000, 9, 0x4\n"
pk = fs._parse_framecrc(DUP)
check((pk.keys, pk.key_times_s) == (3, (0.0, 0.0, 12000 / 90000)),
      "framecrc: a same-PTS key PAIR is kept -- two keys, one time -- not deduplicated", f"got {pk}")
pk = fs._parse_framecrc(DUP.replace(b"0, 12000, 12000,", b"0, 12000, -9223372036854775808,"))
check(pk.keys == 3 and pk.key_times_s is None, "framecrc: a key packet with NO PTS leaves the segment untimed",
      f"got {pk}")
pk = fs._parse_framecrc(DUP.replace(b"#tb 0: 1/90000\n", b""))
check(pk.keys == 3 and pk.key_times_s is None, "framecrc: no #tb line, no times", f"got {pk}")

# ---------------------------------------------------------------- 2. real ffmpeg
try:
    ff = fs.find_ffmpeg()
except RuntimeError:
    ff = None

tmp = tempfile.mkdtemp(prefix="wt-gop-")

def make_clip(name, gop, seconds, fps=15):
    out = os.path.join(tmp, name)
    for enc in ("libx264", "libopenh264", "mpeg2video") if ff else ():
        p = subprocess.run(
            [ff, "-hide_banner", "-loglevel", "error", "-y",
             "-f", "lavfi", "-i", f"testsrc2=size=320x180:rate={fps}", "-t", str(seconds),
             "-c:v", enc, "-g", str(gop), "-bf", "0", "-pix_fmt", "yuv420p", "-f", "mpegts", out],
            capture_output=True, timeout=60)
        if p.returncode == 0 and os.path.getsize(out) > 0:
            return out, enc
    return None, None

clip, used = make_clip("gop15.ts", 15, 4)
if not clip:
    print("SKIP  real-ffmpeg checks -- "
          + ("no working ffmpeg on this box" if not ff else "no usable encoder (libx264/libopenh264/mpeg2video)"))
else:
    pk = fs._read_packets(ff, clip)
    decode = (fs._count_frames(ff, clip, keyframes_only=False),
              fs._count_frames(ff, clip, keyframes_only=True))
    check((pk.total, pk.keys) == decode, f"demux counts == decode counts on a GOP-15 clip ({used})",
          f"demux {(pk.total, pk.keys)} vs decode {decode}")
    check((pk.total, pk.keys) == (60, 4), f"demux counts are the clip's: 60 packets, 4 keys ({used})",
          f"got {(pk.total, pk.keys)}")

    real_count_frames = fs._count_frames
    def trap(*a, **k):
        raise AssertionError("probe DECODED to measure GOP")
    fs._count_frames = trap
    try:
        pr = fs.probe(clip, ff, measure_gop=True)
        check(pr.keyframe_gop == 15, "probe measures GOP 15 without decoding a frame",
              f"keyframe_gop={pr.keyframe_gop}")
    except AssertionError as e:
        check(False, "probe measures GOP 15 without decoding a frame", str(e))
    finally:
        fs._count_frames = real_count_frames

    calls = []
    def recording(ff_, path, keyframes_only):
        calls.append(keyframes_only)
        return real_count_frames(ff_, path, keyframes_only)
    real_read = fs._read_packets
    fs._read_packets = lambda *a, **k: fs._Packets(60, 60, tuple(float(i) for i in range(60)), 4.0)
    fs._count_frames = recording
    try:
        pr = fs.probe(clip, ff, measure_gop=True)
        check(sorted(calls) == [False, True] and pr.keyframe_gop == 15 and pr.key_times_s is None,
              "a degenerate demux answer (all keys) is re-counted by decoding, and times nothing",
              f"decode calls {calls}, keyframe_gop={pr.keyframe_gop}, key_times_s={pr.key_times_s}")
    finally:
        fs._read_packets, fs._count_frames = real_read, real_count_frames

    # A 15 s GOP-50 clip: 225 frames, keys at 0, 50, ..., 200 -> round(225/5) = 45, so
    # the old constant step put key 4 at 12.0 s where it is 13.33 s.
    g50, used50 = make_clip("gop50.ts", 50, 15)
    pk = fs._read_packets(ff, g50)
    want = pk.key_times_s
    pr = fs.probe(g50, ff, measure_gop=True)
    old = [i * pr.keyframe_gop / pr.fps for i in range(len(want or ()))]
    old_err = max((abs(a - b) for a, b in zip(old, want or ())), default=0.0)
    check(want is not None and len(want) == 5 and old_err > 1.2,
          f"GOP-50 15 s clip reproduces the old error: constant step {old_err:.2f} s off ({used50})",
          f"key times {want}, GOP estimate {pr.keyframe_gop}")
    got = [f.t_offset_s for f in fs.iter_frames(g50, ffmpeg=ff, keyframes_only=True)]
    check(close(got, want), "iter_frames: every keyframe's t_offset_s is its key packet's PTS",
          f"got {got}\n      want {want}")
    got = [f.t_offset_s for f in fs.iter_frames(g50, ffmpeg=ff, keyframes_only=True, t0=100.0)]
    check(close(got, [100.0 + t for t in want]), "iter_frames: exact times are offset by t0",
          f"got {got}")
    got = [f.t_offset_s for f in fs.iter_frames(g50, ffmpeg=ff, keyframes_only=True, step_s=2.0)]
    check(close(got, [2.0 * i for i in range(len(want))]), "iter_frames: a caller's step_s is still honoured exactly",
          f"got {got}")
    lst = os.path.join(tmp, "list.txt")
    got = [f.t_offset_s for f in fs.iter_concat([g50, g50], lst, ffmpeg=ff, keyframes_only=True)]
    want2 = list(want) + [pk.span_s + t for t in want]
    check(close(got, want2), "iter_concat: exact per file, the second laid where the first ends",
          f"got {got}\n      want {want2}")

# ---------------------------------------------------------------- 3. booth footage
DUPKEY = os.environ.get("WT_DUPKEY_TS", r"C:\wt\labs-bench\dist\hiwatch-04eecd5eaed8.ts")
if not (ff and os.path.exists(DUPKEY)):
    print("SKIP  key pair on real footage -- the booth's sample file is not on this box")
else:
    pk = fs._read_packets(ff, DUPKEY)
    ts = [f.t_offset_s for f in fs.iter_frames(DUPKEY, ffmpeg=ff, keyframes_only=True)]
    pair = any(0 <= b - a < 0.001 for a, b in zip(ts, ts[1:]))
    check(len(ts) == pk.keys and pair and close(ts, pk.key_times_s, eps=1e-9),
          f"real camera: both keys of its one-tick pair are yielded, each at its own PTS ({len(ts)} keyframes)",
          f"frames {len(ts)} vs key packets {pk.keys}; times {ts}")

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
