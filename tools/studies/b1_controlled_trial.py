#!/usr/bin/env python3
"""B1 — controlled trial: bytes-primary vs pixel-primary, same frames, operator labels.

THE POINT OF THIS DESIGN, which is the operator's: every previous comparison used a
PROXY for ground truth -- astronomy, or the encoder's own byte curve. Both are things
the classifiers are partly made of, so scoring against them is marking your own work.
The operator supplied real labels from having been there:

    A  2026-09-23 17:15 MSK   "the sun came out, it was a sunny moment"     SUNNY
    B  2026-09-24 00:30 MSK   now                                           DARK
    C  2026-09-23 06:00 MSK   operator expected overcast DAY
    D  2026-09-23 12:00 MSK   midday anchor, weather not labelled

SLOT C IS THE CONTROL NOBODY DESIGNED. On 09-23 at this site sunrise was 06:47 and
civil dawn ended 06:05, so 06:00 is astronomically NIGHT -- 47 minutes before the sun
is up. The operator's expectation and the ephemeris disagree, and the pixels get to
say which is true of the scene. Whatever the classifiers do here is the most
informative row in the table.

COLLECTION ONLY. This writes a dataset; b1_controlled_trial_score.py does the
comparison, so the analysis can be redone without decoding anything again.

Both classifiers must see EXACTLY the same material, so every feature -- luma,
chroma, and byte rate -- is taken from the same segments in the same window.

READ ONLY: no Labs endpoint, no scan unit, nothing written to the backend. Every
temporary file is removed in a finally.
"""
import argparse, json, os, subprocess, sys, tempfile, threading, queue, time
import numpy as np

FILER = "http://localhost:8888/buckets"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from b1_signal_separation import frame_metrics, cpu_now       # noqa: E402

SLOTS = [
    ("A_sunny",    "2026-09-23 17:15+03", "SUNNY   (operator: the sun came out)"),
    ("B_dark",     "2026-09-24 00:30+03", "DARK    (operator: now)"),
    ("C_0600",     "2026-09-23 06:00+03", "operator expected DAY; astronomy says NIGHT"),
    ("D_midday",   "2026-09-23 12:00+03", "DAY     (midday anchor, weather unlabelled)"),
]

SQL = """
set statement_timeout = '120s';
with cams as (select camera_id from cameras
              where decommissioned_at is null and facing='outside'
                and recording_state='recording')
select v.camera_id, v.storage_uri, v.width, v.height, v.bytes, v.duration_s
from video_segments v join cams c on c.camera_id = v.camera_id
where v.stream_type='main'
  and v.start_time >= timestamptz '{ts}'
  and v.start_time <  timestamptz '{ts}' + interval '{win} minutes'
order by v.camera_id, v.start_time;
"""


def fetch_and_measure(uri, w, h, want):
    """Returns (list of (luma, chroma) per keyframe, bytes_downloaded) or (None, 0)."""
    fd, tmp = tempfile.mkstemp(suffix=".ts"); os.close(fd)
    try:
        r = subprocess.run(["curl", "-sS", "--max-time", "90", "-o", tmp,
                            f"{FILER}/{uri.replace('s3://', '', 1)}"],
                           capture_output=True, timeout=120)
        if r.returncode != 0 or os.path.getsize(tmp) < 10000:
            return None, 0
        m = frame_metrics(tmp, w, h, want)
        return [(x[0], x[1]) for x in m], os.path.getsize(tmp)
    except Exception:
        return None, 0
    finally:
        try: os.unlink(tmp)
        except OSError: pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames", type=int, default=50, help="frames per camera per slot")
    ap.add_argument("--max-segs", type=int, default=8)
    ap.add_argument("--window", type=int, default=5, help="minutes after the slot time")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--out", default="b1_trial.json")
    a = ap.parse_args()

    dataset, t0, c0, bytes_read = [], time.time(), cpu_now(), 0
    for slot, ts, why in SLOTS:
        r = subprocess.run(["docker", "exec", "-i", "timescaledb", "psql", "-U", "cilex",
                            "-d", "vidanalytics", "-At", "-F", "|"],
                           input=SQL.format(ts=ts, win=a.window),
                           capture_output=True, text=True, timeout=240)
        if r.returncode != 0:
            sys.exit(f"psql failed for {slot}:\n" + r.stderr[:1200])
        per_cam = {}
        for line in r.stdout.splitlines():
            p = line.split("|")
            if len(p) != 6 or p[0] == "SET":
                continue
            try:
                per_cam.setdefault(p[0], []).append(
                    (p[1], int(p[2]), int(p[3]), int(p[4]), float(p[5])))
            except ValueError:
                continue
        print(f"\n=== {slot}  {ts}  {why}")
        print(f"    {len(per_cam)} street-facing continuous cameras")

        work, lock = queue.Queue(), threading.Lock()
        for cam, segs in per_cam.items():
            work.put((cam, segs[:a.max_segs]))
        results, done = {}, [0]

        def worker():
            nonlocal bytes_read
            while True:
                try: cam, segs = work.get_nowait()
                except queue.Empty: return
                fr, by, dur, nseg = [], 0, 0.0, 0
                per = max(1, -(-a.frames // max(1, len(segs))))      # ceil
                for uri, w, h, b, d in segs:
                    if len(fr) >= a.frames:
                        break
                    m, got = fetch_and_measure(uri, w, h, per)
                    with lock:
                        bytes_read += got
                    if not m:
                        continue
                    fr.extend(m); by += b; dur += d; nseg += 1
                if fr:
                    L = np.array([x[0] for x in fr]); C = np.array([x[1] for x in fr])
                    with lock:
                        results[cam] = {
                            "n_frames": len(fr), "n_segs": nseg,
                            "luma_mean": float(L.mean()), "luma_sd": float(L.std()),
                            "chroma_mean": float(C.mean()), "chroma_sd": float(C.std()),
                            "chroma_min": float(C.min()), "chroma_max": float(C.max()),
                            # The BYTES feature, from the SAME segments the pixels came
                            # from. Rate, not size: segment durations are not identical.
                            "byte_rate_mbps": (by * 8 / dur / 1e6) if dur > 0 else None,
                        }
                with lock:
                    done[0] += 1
                    if done[0] % 10 == 0:
                        print(f"      {done[0]}/{len(per_cam)} cameras "
                              f"({bytes_read/1e9:.2f} GB read)", flush=True)

        ts_ = [threading.Thread(target=worker, daemon=True) for _ in range(a.workers)]
        [t.start() for t in ts_]; [t.join() for t in ts_]
        for cam, m in results.items():
            dataset.append({"slot": slot, "camera_id": cam, **m})
        fr = [m["n_frames"] for m in results.values()]
        print(f"    collected {len(results)} cameras, "
              f"{sum(fr)} frames (median {int(np.median(fr))}/camera)")

    out = {"generated": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
           "slots": {s: {"ts": t, "why": w} for s, t, w in SLOTS},
           "frames_requested": a.frames, "rows": dataset}
    with open(a.out, "w") as f:
        json.dump(out, f, indent=1)
    print(f"\nwrote {a.out}: {len(dataset)} camera-slot rows")
    print(f"{cpu_now()-c0:.0f} CPU-s, {time.time()-t0:.0f} s wall, {bytes_read/1e9:.2f} GB read")

if __name__ == "__main__":
    main()
