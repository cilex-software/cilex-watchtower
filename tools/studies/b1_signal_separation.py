#!/usr/bin/env python3
"""B1 phase 1, part 2 — WHICH pixel signal actually separates day from night?

cilex-vision proposed "mean luminance plus colour-saturation collapse". This tests
that proposal before anything is built on it, because the saturation half and the
luminance half are not equally trustworthy and the design brief says so:

  MEAN LUMA IS EXPECTED TO BE WEAK. Auto-exposure fights exactly the signal a
  classifier would be reading -- a camera in a darkening scene raises gain and
  lengthens exposure until mean Y returns toward its target. If that is right, mean
  Y is roughly invariant to ambient light and a threshold on it is the A2 mistake
  again: a constant that works on the footage it was tuned on.

  CHROMA COLLAPSE IS EXPECTED TO BE STRONG. The IR-cut filter is a mechanical
  swing; with it closed there is no chroma information to recover, so the signal is
  physical rather than statistical and does not depend on scene content.

  NOISE FLOOR IS THE THIRD CANDIDATE, and it is the one the encoder is already
  telling us about: night segments are LARGER, which is gain-boosted sensor noise.
  Measured here as the 5th percentile of per-block standard deviation -- in a flat
  patch (sky, wall, road) that is the sensor floor, not scene detail.

Reads segments directly from the SeaweedFS filer. READ ONLY: no Labs endpoint is
called, no scan unit is claimed, nothing is written to the backend.

EVERY TEMPORARY FILE IS REMOVED IN A finally. cilex-vision leaked ~1.5 GB twice
doing this exact thing -- once by cleaning up only on the success path, and once by
losing the close() in a later edit while the comment above it still promised
cleanup. Structural, not stated.
"""
import argparse, os, subprocess, sys, tempfile, resource, time
import numpy as np

FILER = "http://localhost:8888/buckets"

SQL = """
set statement_timeout = '90s';
with active as (select camera_id from cameras where decommissioned_at is null
                and recording_state = 'recording')
select distinct on (v.camera_id, hr) v.camera_id, hr, v.storage_uri, v.width, v.height
from (
  select camera_id, storage_uri, width, height, start_time,
         extract(hour from (start_time at time zone 'Europe/Moscow'))::int hr
  from video_segments
  where start_time >= now() - interval '{days} days'
    and stream_type = 'main' and bytes > 100000
) v join active a on a.camera_id = v.camera_id
where v.hr in ({hours})
order by v.camera_id, hr, v.start_time desc;
"""


def query(days, hours):
    sql = SQL.format(days=days, hours=",".join(str(h) for h in hours))
    r = subprocess.run(["docker", "exec", "-i", "timescaledb", "psql", "-U", "cilex",
                        "-d", "vidanalytics", "-At", "-F", "|"],
                       input=sql, capture_output=True, text=True, timeout=180)
    if r.returncode != 0:
        sys.exit("psql failed:\n" + r.stderr[:1500])
    out = []
    for line in r.stdout.splitlines():
        p = line.split("|")
        if len(p) != 5 or p[0] == "SET":
            continue
        try:
            out.append((p[0], int(p[1]), p[2], int(p[3]), int(p[4])))
        except ValueError:
            continue
    return out


def frame_metrics(path, w, h, frames):
    """Decode up to `frames` keyframes; return per-frame (meanY, chroma, noise)."""
    n = w * h
    cmd = ["ffmpeg", "-nostdin", "-loglevel", "error", "-skip_frame", "nokey",
           "-i", path, "-frames:v", str(frames), "-f", "rawvideo",
           "-pix_fmt", "yuv420p", "-"]
    raw = subprocess.run(cmd, capture_output=True, timeout=120).stdout
    fsz = n * 3 // 2
    out = []
    for i in range(len(raw) // fsz):
        b = raw[i * fsz:(i + 1) * fsz]
        Y = np.frombuffer(b[:n], np.uint8).reshape(h, w).astype(np.float32)
        U = np.frombuffer(b[n:n + n // 4], np.uint8).astype(np.float32)
        V = np.frombuffer(b[n + n // 4:], np.uint8).astype(np.float32)
        # Chroma ENERGY, not "saturation": distance of U/V from neutral 128.
        # An IR frame is genuinely greyscale, so both planes collapse onto 128.
        chroma = float(np.abs(U - 128).mean() + np.abs(V - 128).mean())
        # Noise floor: 5th percentile of 8x8 block std. Flat blocks carry sensor
        # noise and nothing else, so the low tail is the floor rather than detail.
        bh, bw = h // 8, w // 8
        blocks = Y[:bh * 8, :bw * 8].reshape(bh, 8, bw, 8).transpose(0, 2, 1, 3)
        stds = blocks.reshape(bh * bw, 64).std(axis=1)
        out.append((float(Y.mean()), chroma, float(np.percentile(stds, 5))))
    return out


def cpu_now():
    a = resource.getrusage(resource.RUSAGE_SELF)
    b = resource.getrusage(resource.RUSAGE_CHILDREN)
    return a.ru_utime + a.ru_stime + b.ru_utime + b.ru_stime


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--day-hour", type=int, default=13)
    ap.add_argument("--night-hour", type=int, default=2)
    ap.add_argument("--cameras", type=int, default=12)
    ap.add_argument("--frames", type=int, default=2)
    ap.add_argument("--days", type=int, default=2)
    a = ap.parse_args()

    rows = query(a.days, [a.day_hour, a.night_hour])
    by_cam = {}
    for cam, hr, uri, w, h in rows:
        by_cam.setdefault(cam, {})[hr] = (uri, w, h)
    both = [c for c, d in by_cam.items() if a.day_hour in d and a.night_hour in d]
    both.sort()
    both = both[:a.cameras]
    if not both:
        sys.exit("no camera has a segment at both hours in the window")

    print(f"cameras   {len(both)} continuous, with a main segment at both "
          f"{a.day_hour:02d}:00 and {a.night_hour:02d}:00 MSK")
    print(f"frames    up to {a.frames} keyframes per segment, software decode, no -hwaccel")
    print()
    print(f"{'camera':26s} {'meanY d/n':>16s} {'chroma d/n':>16s} {'noise d/n':>16s}")
    print("-" * 78)

    res = {"Y": [], "C": [], "N": []}
    t0, c0, nseg = time.time(), cpu_now(), 0
    for cam in both:
        vals = {}
        for hr in (a.day_hour, a.night_hour):
            uri, w, h = by_cam[cam][hr]
            key = uri.replace("s3://", "", 1)
            fd, tmp = tempfile.mkstemp(suffix=".ts")
            os.close(fd)
            try:
                r = subprocess.run(["curl", "-sS", "--max-time", "60", "-o", tmp,
                                    f"{FILER}/{key}"], capture_output=True, timeout=90)
                if r.returncode != 0 or os.path.getsize(tmp) < 10000:
                    vals[hr] = None; continue
                m = frame_metrics(tmp, w, h, a.frames)
                nseg += 1
                vals[hr] = (float(np.mean([x[0] for x in m])),
                            float(np.mean([x[1] for x in m])),
                            float(np.mean([x[2] for x in m]))) if m else None
            except Exception as e:
                vals[hr] = None
                print(f"  {cam}: {type(e).__name__}", file=sys.stderr)
            finally:
                # Structural. Runs on success, on failure, and on exception.
                try: os.unlink(tmp)
                except OSError: pass
        d, n = vals.get(a.day_hour), vals.get(a.night_hour)
        if not d or not n:
            print(f"{cam:26s} {'(no readable pair)':>50s}")
            continue
        res["Y"].append((d[0], n[0])); res["C"].append((d[1], n[1])); res["N"].append((d[2], n[2]))
        print(f"{cam:26s} {d[0]:7.1f}/{n[0]:<7.1f} {d[1]:7.2f}/{n[1]:<7.2f} {d[2]:7.2f}/{n[2]:<7.2f}")

    if not res["Y"]:
        sys.exit("\nno readable pairs")
    cpu, wall = cpu_now() - c0, time.time() - t0
    print()
    print("=== separation, day vs night, across the sampled cameras ===")
    for key, name, unit in (("Y", "mean luma", ""), ("C", "chroma energy", ""),
                            ("N", "noise floor (p5 block std)", "")):
        d = np.array([x[0] for x in res[key]]); n = np.array([x[1] for x in res[key]])
        ratio = np.where(n > 0, d / np.maximum(n, 1e-6), np.nan)
        agree = int(np.sum(d > n)), int(np.sum(n > d))
        # Effect size that does not assume which direction the signal goes.
        pooled = np.sqrt((d.std(ddof=1) ** 2 + n.std(ddof=1) ** 2) / 2) if len(d) > 1 else 0.0
        cohen = abs(d.mean() - n.mean()) / pooled if pooled > 0 else float("nan")
        print(f"  {name:28s} day {d.mean():8.2f}  night {n.mean():8.2f}   "
              f"|d| {cohen:5.2f}   day>night on {agree[0]}/{len(d)}")
    print()
    print(f"  decoded {nseg} segments, {cpu:.1f} CPU-s, {wall:.1f} s wall")
    print("  (NOT a camera-hour cost figure -- that is a separate measurement)")

if __name__ == "__main__":
    main()
