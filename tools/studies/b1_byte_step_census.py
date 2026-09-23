#!/usr/bin/env python3
"""B1 phase 1, part 1 — which cameras have a day/night signature in their bytes?

cilex-vision offered their encoder byte-signature as a free ground truth for the
illumination classifier: mean segment size per hour shows two sharp steps, dawn and
dusk, because a dark scene is full of gain-boosted sensor noise that the encoder
cannot predict. Their figures are a FLEET MEAN over "56 continuous outside cameras".

Their own caveat is why this script exists: individual cameras switch at different
lux, and an indoor camera under constant artificial light shows no step at all. A
fleet mean cannot tell you WHICH cameras can adjudicate a classifier and which
cannot -- and validating against a mean would quietly accept a classifier that is
wrong on every camera that lacks a step.

So this counts them, per camera, and reports the population of each answer.

NOT a classifier and not a label. It is one signal path (encoder bitrate) that will
later be compared against a completely different one (pixel chroma). Agreement is
the acceptance criterion for B1; this establishes where agreement can be tested.

Cheap: video_segments is a hypertable with an index on start_time DESC, so the
window is chunk-excluded. No footage is decoded here.
"""
import subprocess, sys, json, statistics, argparse

SQL = """
set statement_timeout = '120s';
with active as (
  select camera_id, recording_state, facing
  from cameras where decommissioned_at is null
),
seg as (
  select v.camera_id,
         extract(hour from (v.start_time at time zone 'Europe/Moscow'))::int as hr,
         v.bytes
  from video_segments v
  where v.start_time >= now() - interval '%d days'
    and v.stream_type = 'main'
)
select a.camera_id, a.recording_state, a.facing, s.hr,
       count(*)::bigint, round(avg(s.bytes))::bigint
from active a join seg s on s.camera_id = a.camera_id
group by 1,2,3,4
order by 1,4;
"""

def run(days):
    out = subprocess.run(
        ["docker", "exec", "-i", "timescaledb", "psql", "-U", "cilex",
         "-d", "vidanalytics", "-At", "-F", "|"],
        input=(SQL % days), capture_output=True, text=True, timeout=300)
    if out.returncode != 0:
        sys.exit("psql failed:\n" + out.stderr[:2000])
    rows = []
    for line in out.stdout.splitlines():
        p = line.split("|")
        if len(p) != 6 or p[0] in ("SET",):
            continue
        try:
            rows.append((p[0], p[1], p[2], int(p[3]), int(p[4]), int(p[5])))
        except ValueError:
            continue
    return rows

def step_profile(by_hour, min_hours, min_segs):
    """Largest adjacent-hour ratio, forward and backward round the 24h clock.

    A real IR transition is a STEP between neighbouring hours, not a slow drift, so
    the discriminant is the biggest adjacent ratio -- not the day/night spread,
    which a camera with a gentle diurnal curve would also show.
    """
    hrs = {h: v for h, (n, v) in by_hour.items() if n >= min_segs}
    if len(hrs) < min_hours:
        return None
    present = sorted(hrs)
    ups, downs = [], []
    for i, h in enumerate(present):
        nxt = present[(i + 1) % len(present)]
        a, b = hrs[h], hrs[nxt]
        if a <= 0 or b <= 0:
            continue
        (ups if b > a else downs).append((max(a, b) / min(a, b), h, nxt))
    up = max(ups, default=None)
    dn = max(downs, default=None)
    return {"hours_covered": len(present),
            "rise": up, "fall": dn,
            "min": min(hrs.values()), "max": max(hrs.values())}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--min-hours", type=int, default=20,
                    help="hours-of-day a camera must cover to be judged at all")
    ap.add_argument("--min-segs", type=int, default=5,
                    help="segments in an hour-of-day bucket for it to count")
    ap.add_argument("--step", type=float, default=1.25,
                    help="adjacent-hour ratio that counts as a step")
    ap.add_argument("--json", help="write the per-camera table here")
    a = ap.parse_args()

    rows = run(a.days)
    if not rows:
        sys.exit("no rows -- check the window and stream_type")

    cams = {}
    for cam, rec, face, hr, n, mean in rows:
        c = cams.setdefault(cam, {"rec": rec, "facing": face, "h": {}})
        c["h"][hr] = (n, mean)

    # SCORED PER DIRECTION, not as a single pass/fail. The first version of this
    # required BOTH a rise and a fall above the cut, and that threw away half the
    # continuous-outside fleet: the rejected group's median biggest adjacent jump is
    # 1.38x, above the 1.25x cut, so they were failing on ONE direction while having a
    # perfectly clean other one. A camera with a sharp dusk and a gradual dawn can
    # still adjudicate the dusk transition, and excluding it loses real evidence.
    judged, nostep, thin = [], [], []
    for cam, c in cams.items():
        p = step_profile(c["h"], a.min_hours, a.min_segs)
        if p is None:
            thin.append((cam, c)); continue
        p["can_rise"] = bool(p["rise"]) and p["rise"][0] >= a.step
        p["can_fall"] = bool(p["fall"]) and p["fall"][0] >= a.step
        (judged if (p["can_rise"] or p["can_fall"]) else nostep).append((cam, c, p))

    tot = len(cams)
    print(f"window        last {a.days} days, stream_type=main, hour-of-day in Europe/Moscow")
    print(f"cameras seen  {tot} of 133 active")
    print(f"step rule     a rise OR a fall of >= {a.step}x between adjacent hours (scored per direction)")
    print()
    both = [x for x in judged if x[2]["can_rise"] and x[2]["can_fall"]]
    one  = [x for x in judged if not (x[2]["can_rise"] and x[2]["can_fall"])]
    print(f"  HAS a day/night signature   {len(judged):3d}   <- can adjudicate at least one transition")
    print(f"      both transitions        {len(both):3d}")
    print(f"      one transition only     {len(one):3d}")
    print(f"  has NO step                 {len(nostep):3d}   <- cannot; validated only against themselves")
    print(f"  too thin to judge           {len(thin):3d}   <- < {a.min_hours} hours-of-day covered")
    print()

    def breakdown(name, items):
        if not items: return
        combos = {}
        for it in items:
            c = it[1]
            combos[(c["rec"], c["facing"])] = combos.get((c["rec"], c["facing"]), 0) + 1
        print(f"  {name}:")
        for (r, f), n in sorted(combos.items(), key=lambda kv: -kv[1]):
            print(f"      {n:3d}  {r or 'null':10s} {f or 'null'}")
    breakdown("HAS a signature", judged)
    breakdown("NO step", nostep)
    breakdown("too thin", thin)

    # MOTION-ARMED CAMERAS CANNOT ADJUDICATE ANYTHING, and their apparent signature is
    # the loudest trap in this data. Measured: their segments-per-hour max/min ratio has
    # a median of 63x and a worst of 223x, because they record only when motion fires --
    # so an "hourly mean" compares a 2-segment bucket against a 400-segment one. The
    # continuous cameras' ratio is 1.4x. 27 armed-inside cameras pass the step test on
    # that artefact alone, and their transition hours are scattered (19h x10, 07h x3,
    # 01h x3) where the continuous ones are razor sharp (19h x25 of 27, 07h x25 of 27).
    # Including them would "validate" the classifier against sampling noise.
    usable = [x for x in judged if x[1]["rec"] == "recording"]
    print()
    print(f"  USABLE FOR VALIDATION       {len(usable):3d}   <- continuous only; armed cameras excluded,")
    print(f"                                    their hour buckets are not comparable samples")

    if judged:
        rises = [p["rise"][2] for _, _, p in judged if p["rise"]]
        falls = [p["fall"][2] for _, _, p in judged if p["fall"]]
        def mode_hours(xs):
            cnt = {}
            for h in xs: cnt[h] = cnt.get(h, 0) + 1
            return sorted(cnt.items(), key=lambda kv: -kv[1])[:4]
        print()
        print("  transition hours across the cameras that have one (hour the step lands ON):")
        print(f"      dawn-ish (bytes fall): {mode_hours(falls)}")
        print(f"      dusk-ish (bytes rise): {mode_hours(rises)}")
        print("  NOTE: a spread here is the finding cilex-vision's fleet mean could not show.")

    if a.json:
        with open(a.json, "w") as f:
            json.dump({"days": a.days, "step": a.step,
                       "usable": [c for c, _, _ in usable],
                       "judged": [c for c, _, _ in judged],
                       "nostep": [c for c, _, _ in nostep],
                       "thin": [c for c, _ in thin],
                       "per_camera": {c: {"rec": d["rec"], "facing": d["facing"],
                                          "hours": {str(k): v for k, v in d["h"].items()}}
                                      for c, d in cams.items()}}, f, indent=1)
        print(f"\nwrote {a.json}")

if __name__ == "__main__":
    main()
