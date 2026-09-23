#!/usr/bin/env python3
"""B1 phase 1, part 3 — profile ONE camera across 24 hours and see which pixel
signal tracks the encoder's byte curve.

Part 2 sampled 12 cameras at 13:00 and 02:00 and found almost no separation in any
of the three candidate signals. That result was real but the SAMPLE WAS WRONG: the
cameras were taken in camera_id order, which is arbitrary, rather than drawn from
the population the byte census says has a day/night signature at all. A camera under
constant artificial light has no transition to find, and averaging it in hides the
ones that do.

So this takes a single camera with a razor-sharp byte step and walks the whole day.
The byte curve is the independent path; whichever pixel metric tracks it is the one
the classifier should key on, and any that does not is disqualified regardless of
how reasonable it sounds.

READ ONLY. No Labs endpoint, no scan unit. Temp files removed in a finally.
"""
import argparse, os, subprocess, sys, tempfile, resource, time
import numpy as np

FILER = "http://localhost:8888/buckets"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from b1_signal_separation import frame_metrics, cpu_now       # noqa: E402

SQL = """
set statement_timeout = '90s';
select distinct on (hr) hr, storage_uri, width, height, bytes from (
  select storage_uri, width, height, bytes,
         extract(hour from (start_time at time zone 'Europe/Moscow'))::int hr,
         start_time
  from video_segments
  where camera_id = '{cam}' and stream_type = 'main'
    and start_time >= now() - interval '{days} days' and bytes > 100000
) t order by hr, start_time desc;
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("camera")
    ap.add_argument("--days", type=int, default=2)
    ap.add_argument("--frames", type=int, default=3)
    a = ap.parse_args()

    r = subprocess.run(["docker", "exec", "-i", "timescaledb", "psql", "-U", "cilex",
                        "-d", "vidanalytics", "-At", "-F", "|"],
                       input=SQL.format(cam=a.camera, days=a.days),
                       capture_output=True, text=True, timeout=180)
    if r.returncode != 0:
        sys.exit("psql failed:\n" + r.stderr[:1500])
    rows = []
    for line in r.stdout.splitlines():
        p = line.split("|")
        if len(p) != 5 or p[0] == "SET":
            continue
        try:
            rows.append((int(p[0]), p[1], int(p[2]), int(p[3]), int(p[4])))
        except ValueError:
            continue
    if not rows:
        sys.exit("no segments for that camera in the window")

    print(f"camera  {a.camera}")
    print(f"sample  one main segment per hour-of-day, most recent in the last {a.days} days,"
          f" {a.frames} keyframes each")
    print()
    print(f"{'hr':>3s} {'MB':>6s} {'meanY':>7s} {'chroma':>7s} {'noise':>7s}   {'chroma bar':<24s}")
    print("-" * 74)
    prof, c0 = [], cpu_now()
    for hr, uri, w, h, byts in rows:
        fd, tmp = tempfile.mkstemp(suffix=".ts"); os.close(fd)
        try:
            rr = subprocess.run(["curl", "-sS", "--max-time", "60", "-o", tmp,
                                 f"{FILER}/{uri.replace('s3://', '', 1)}"],
                                capture_output=True, timeout=90)
            if rr.returncode != 0 or os.path.getsize(tmp) < 10000:
                print(f"{hr:3d} {byts/1e6:6.2f}  (fetch failed)"); continue
            m = frame_metrics(tmp, w, h, a.frames)
            if not m:
                print(f"{hr:3d} {byts/1e6:6.2f}  (no keyframe decoded)"); continue
            Y = float(np.mean([x[0] for x in m]))
            C = float(np.mean([x[1] for x in m]))
            N = float(np.mean([x[2] for x in m]))
            prof.append((hr, byts, Y, C, N))
            print(f"{hr:3d} {byts/1e6:6.2f} {Y:7.1f} {C:7.2f} {N:7.2f}   "
                  f"{'#' * int(min(C, 24)):<24s}")
        except Exception as e:
            print(f"{hr:3d}  {type(e).__name__}: {e}", file=sys.stderr)
        finally:
            try: os.unlink(tmp)
            except OSError: pass

    if len(prof) < 12:
        sys.exit("\ntoo few hours decoded to correlate")
    A = np.array(prof, dtype=float)
    b = A[:, 1]
    print()
    print("=== which pixel signal tracks the encoder's byte curve? ===")
    print("  (bytes are the independent path: large segments = gain-boosted night noise)")
    for idx, name in ((2, "mean luma"), (3, "chroma energy"), (4, "noise floor")):
        x = A[:, idx]
        if x.std() == 0:
            print(f"  {name:16s} constant -- no signal"); continue
        r_ = float(np.corrcoef(b, x)[0, 1])
        lo, hi = x.min(), x.max()
        print(f"  {name:16s} r = {r_:+.3f} vs bytes   range {lo:7.2f} .. {hi:7.2f}"
              f"   spread {hi/max(lo,1e-6):6.1f}x")
    print()
    print(f"  {cpu_now() - c0:.1f} CPU-s for {len(prof)} segments "
          f"({(cpu_now() - c0)/len(prof):.2f} CPU-s per segment)")

if __name__ == "__main__":
    main()
