#!/usr/bin/env python3
"""B1 phase 1, part 4 — how many cameras are IR, how many are polarity-inverted?

Part 3 found that chroma energy separates dark from light on individual cameras, but
that its POLARITY differs between them: an IR camera collapses to exactly 0.00 in the
dark, while a camera under coloured artificial light goes UP. "Low chroma" therefore
means `ir` on one camera and `day` on another, and a single fleet-wide threshold
would be exactly backwards on whichever population did not tune it.

That is the A2 failure shape, so before any classifier is written this counts the
populations.

GROUND TRUTH IS ASTRONOMICAL, not clock hours. cilex-vision's site_solar_times
(migration 0090) gives real dark_start/dark_end per local date for this site, which
is at 60.1 N where "sunset + 30 min" is still civil twilight on 365 days of 365 --
short by up to 80 minutes at the summer solstice. Nothing here hard-codes an offset;
it joins the table.

READ ONLY. No Labs endpoint, no scan unit claimed. Temp files removed in a finally.
"""
import argparse, os, subprocess, sys, tempfile
import numpy as np

FILER = "http://localhost:8888/buckets"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from b1_signal_separation import frame_metrics, cpu_now       # noqa: E402

SQL = """
set statement_timeout = '120s';
with seg as (
  select v.camera_id, v.storage_uri, v.width, v.height, v.start_time,
         (v.start_time >= st.dark_start and v.start_time < st.dark_end) as is_dark
  from video_segments v
  join cameras c on c.camera_id = v.camera_id and c.decommissioned_at is null
  -- THE -12h SHIFT IS LOAD-BEARING. A dark window SPANS MIDNIGHT: local_date
  -- 2026-09-23 carries dark_start 09-23 19:39 and dark_end 09-24 06:07. Joining a
  -- segment to its OWN local date therefore tests a 02:00 segment against that
  -- date's EVENING window, and every pre-dawn hour is misclassified as light.
  -- Measured on this fleet: that dropped 213,670 of 406,369 genuinely dark
  -- segments -- 53% -- and understated the dark/light byte contrast as 15.4%
  -- instead of 23.7%. Shifting 12h back before taking the date attributes each
  -- segment to the night whose evening it belongs to, and is correct at both
  -- solstices (checked: dark_start ranges ~16:00 midwinter to ~23:30 midsummer).
  join site_solar_times st on st.site_id = c.site_id
       and st.local_date = ((v.start_time at time zone 'Europe/Moscow') - interval '12 hours')::date
  where v.start_time >= now() - interval '{days} days'
    and v.stream_type = 'main' and v.bytes > 150000
    and c.recording_state = 'recording'          -- armed cameras sample by motion
    -- SAMPLE THE MIDDLE OF EACH CONDITION, NOT ITS EDGE. Taking the most recent
    -- segment of each kind put the "light" sample minutes before dark_start --
    -- civil twilight, visually almost night -- so 57 of 60 cameras read dark and
    -- light as identical and the whole census said "no signal". The boundary is
    -- exactly where the two classes are least distinguishable, which is why it is
    -- the wrong place to characterise them from.
    and (
      (v.start_time >= st.dark_start + interval '1 hour'
       and v.start_time <  st.dark_end   - interval '1 hour')
      or
      (v.start_time >= st.sunrise + interval '2 hours'
       and v.start_time <  st.sunset  - interval '2 hours')
    )
)
select distinct on (camera_id, is_dark) camera_id, is_dark, storage_uri, width, height
from seg order by camera_id, is_dark, start_time desc;
"""


def chroma_of(uri, w, h, frames):
    fd, tmp = tempfile.mkstemp(suffix=".ts"); os.close(fd)
    try:
        r = subprocess.run(["curl", "-sS", "--max-time", "60", "-o", tmp,
                            f"{FILER}/{uri.replace('s3://', '', 1)}"],
                           capture_output=True, timeout=90)
        if r.returncode != 0 or os.path.getsize(tmp) < 10000:
            return None
        m = frame_metrics(tmp, w, h, frames)
        return float(np.mean([x[1] for x in m])) if m else None
    except Exception:
        return None
    finally:
        try: os.unlink(tmp)
        except OSError: pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=3)
    ap.add_argument("--frames", type=int, default=2)
    ap.add_argument("--ir-cut", type=float, default=0.5,
                    help="chroma below this in the dark counts as IR (measured IR "
                         "cameras read EXACTLY 0.00, so this is a margin, not a tuned knob)")
    ap.add_argument("--min-ratio", type=float, default=1.3,
                    help="how far apart dark and light chroma must be to call a polarity")
    a = ap.parse_args()

    r = subprocess.run(["docker", "exec", "-i", "timescaledb", "psql", "-U", "cilex",
                        "-d", "vidanalytics", "-At", "-F", "|"],
                       input=SQL.format(days=a.days), capture_output=True,
                       text=True, timeout=240)
    if r.returncode != 0:
        sys.exit("psql failed:\n" + r.stderr[:1500])
    pairs = {}
    for line in r.stdout.splitlines():
        p = line.split("|")
        if len(p) != 5 or p[0] == "SET":
            continue
        pairs.setdefault(p[0], {})[p[1] == "t"] = (p[2], int(p[3]), int(p[4]))
    cams = sorted(c for c, d in pairs.items() if True in d and False in d)
    print(f"cameras   {len(cams)} continuous, with a main segment in BOTH an astronomically")
    print(f"          dark and a light window in the last {a.days} days (site_solar_times)")
    print(f"frames    {a.frames} keyframes per segment\n")

    buckets = {"ir": [], "normal": [], "inverted": [], "flat": [], "unreadable": []}
    c0 = cpu_now()
    for cam in cams:
        d = chroma_of(*pairs[cam][True], a.frames)
        l = chroma_of(*pairs[cam][False], a.frames)
        if d is None or l is None:
            buckets["unreadable"].append((cam, d, l)); continue
        if d <= a.ir_cut:
            buckets["ir"].append((cam, d, l))
        elif l > 0 and d / l >= a.min_ratio:
            buckets["inverted"].append((cam, d, l))       # brighter colour in the dark
        elif d > 0 and l / d >= a.min_ratio:
            buckets["normal"].append((cam, d, l))         # desaturates in the dark
        else:
            buckets["flat"].append((cam, d, l))
    cpu = cpu_now() - c0

    tot = sum(len(v) for v in buckets.values())
    print(f"{'class':<12s} {'n':>4s}   what it means for the classifier")
    print("-" * 78)
    for k, why in (
        ("ir",         "chroma ~0 in the dark: IR-cut closed. Detectable with NO tuned constant"),
        ("inverted",   "MORE colour in the dark: coloured artificial light. 'low chroma'=day"),
        ("normal",     "less colour in the dark, but never reaches 0: no IR, dim colour"),
        ("flat",       "no usable chroma separation: classifier must answer `unknown`"),
        ("unreadable", "fetch or decode failed on one side")):
        print(f"{k:<12s} {len(buckets[k]):4d}   {why}")
    print(f"{'TOTAL':<12s} {tot:4d}")

    for k in ("ir", "inverted", "normal", "flat"):
        if not buckets[k]:
            continue
        v = buckets[k]
        ds = np.array([x[1] for x in v]); ls = np.array([x[2] for x in v])
        print(f"\n  {k}: dark chroma {ds.min():.2f}-{ds.max():.2f} (median {np.median(ds):.2f}), "
              f"light {ls.min():.2f}-{ls.max():.2f} (median {np.median(ls):.2f})")
        for cam, dd, ll in sorted(v, key=lambda x: x[1])[:3]:
            print(f"      {cam:26s} dark {dd:6.2f}  light {ll:6.2f}")

    print(f"\n  {cpu:.1f} CPU-s for {2*len(cams)} segments "
          f"({cpu/max(1,2*len(cams)):.2f} CPU-s/segment, fetch included)")

if __name__ == "__main__":
    main()
