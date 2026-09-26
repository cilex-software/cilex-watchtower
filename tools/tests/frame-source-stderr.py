#!/usr/bin/env python3
"""frame_source must drain ffmpeg's stderr WHILE it reads frames, or it deadlocks.

THE DEFECT (booth, 2026-09-26). A verification run sat 42 minutes on one segment having
used 10 CPU-seconds, its ffmpeg child 0. That segment makes ffmpeg write 4,467 bytes of
error-level warnings (non-monotonic DTS). frame_source opened ffmpeg with stderr=PIPE
and read stderr only after the stream ENDED. Windows gives an anonymous pipe ~4 KB, so
ffmpeg filled it, blocked on its 33rd warning, stopped writing frames -- and the reader
waited on stdout forever. No error, no timeout, no log line.

It is the Labs worker's SHARED decode pass (run_worker imports frame_source), so on a
Windows station one noisy segment would have hung B1 and blob_geometry indefinitely.

WHY THIS TEST WRITES 200 KB. The real trigger was 4.5 KB, which a Linux pipe (64 KB)
swallows without blocking -- that is exactly why the bug was invisible from the Linux
box. 200 KB is past the buffer on every platform, so a regression now deadlocks HERE on
Linux too, instead of waiting for a Windows station to hang. Hermetic: a fake decoder
stands in for ffmpeg, so no footage, codec or ffmpeg build is needed.

A deadlock test that can itself deadlock proves nothing, so the decode runs on a thread
with a hard join timeout, and the fake decoder kills itself after 60 s regardless.

WT_NO_FS_STDERR_PIN=1 skips it.
"""
import os, sys, tempfile, textwrap, threading, pathlib

if os.environ.get("WT_NO_FS_STDERR_PIN") == "1":
    sys.exit(0)

ROOT = pathlib.Path(__file__).resolve().parents[2]
LABS = pathlib.Path(os.environ.get("WT_FRAME_SOURCE_DIR", ROOT / "tools" / "labs"))
sys.path.insert(0, str(LABS))
import frame_source as fs   # noqa: E402

W, H, N = 64, 48, 30
STDERR_BYTES = 200_000

fails = []
def check(ok, what, detail=""):
    print(("PASS  " if ok else "FAIL  ") + what + ("" if ok else f"\n      {detail}"))
    if not ok:
        fails.append(what)

fake = pathlib.Path(tempfile.mkdtemp()) / "fake_ffmpeg.py"
fake.write_text(textwrap.dedent(f"""
    import os, sys, threading
    threading.Timer(60, os._exit, (1,)).start()      # never outlive the test
    sys.stderr.buffer.write(b"x" * {STDERR_BYTES})    # all the noise FIRST, before any frame
    sys.stderr.buffer.flush()
    frame = bytes({W} * {H} * 3 // 2)                 # yuv420p: Y + quarter-size U and V
    for _ in range({N}):
        sys.stdout.buffer.write(frame)
    sys.stdout.buffer.flush()
    os._exit(0)
"""), encoding="ascii")

# Stand the fake in for ffmpeg: _stream builds its argv through _decode_args.
fs._decode_args = lambda *a, **k: [sys.executable, str(fake)]
pr = fs.Probe(width=W, height=H, codec="h264", fps=15.0, pix_fmt="yuv420p")

for planes in (False, True):
    got = {}
    def run():
        try:
            got["n"] = sum(1 for _ in fs._stream("unused", ["unused"], None, pr, False, 0.0,
                                                 None, True, planes))
        except Exception as e:                       # noqa: BLE001
            got["err"] = f"{type(e).__name__}: {e}"
    t = threading.Thread(target=run, daemon=True)
    t.start()
    t.join(timeout=30)
    tag = f"want_planes={planes}"
    check(not t.is_alive(),
          f"{STDERR_BYTES:,} B of stderr before the first frame does not deadlock ({tag})",
          "still blocked after 30 s: stderr is not being drained while stdout is read")
    if not t.is_alive():
        check("err" not in got and got.get("n") == N,
              f"all {N} frames delivered through the noise ({tag})",
              got.get("err", f"got {got.get('n')} frames"))

if fails:
    print("\nFAIL  " + "\n\nFAIL  ".join(fails), file=sys.stderr)
    sys.stdout.flush(); sys.stderr.flush()
    # os._exit, not sys.exit: a DEADLOCKED decode leaves a daemon thread blocked on a
    # pipe, and interpreter finalization then aborts on it -- measured, the process
    # exited -1 instead of 1. Still non-zero, but a failing test should fail by
    # reporting, not by crashing on the way out.
    os._exit(1)
print("all passed")
