#!/usr/bin/env python3
"""Mirror of EvHeroPlayer._ambiguousAt — pins the one-frame floor against REAL measured rows.

Why this exists: the detector cannot be exercised by a normal soak run, because the defect
only appears in a session that straddles a codec switch, and none was reproducible while the
pilot backend was in an incident. So the QML wiring is verified by running (it executes on
every hero seek without error) and the LOGIC is verified here, against the manifest rows CV
measured for session 2c351168 on 2026-09-12 and against the rounding case that must stay silent.

Run: python3 tools/tests/hero-ambiguous-span.py   (exit 0 = pass)
"""
import sys

FLOOR_MS = 67          # one frame at the fleet's 15 fps; keep in step with _ambiguityFloorMs


def ambiguous_at(frags, ms):
    hit = [i for i, f in enumerate(frags) if ms >= f["ws"] and ms <= f["we"]]
    if len(hit) < 2:
        return []
    for a in range(len(hit)):
        for b in range(a + 1, len(hit)):
            f, g = frags[hit[a]], frags[hit[b]]
            if min(f["we"], g["we"]) - max(f["ws"], g["ws"]) >= FLOOR_MS:
                return hit
    return []


def t(h, m, s, ms=0):
    return ((h * 60 + m) * 60 + s) * 1000 + ms


# CV's manifest rows, session 2c351168-fb55-425c-bfea-457e2d68f10f, window 2026-09-11T23:48:50.809Z.
# frag 3 carries boundary="codec": an hevc_capable session serves the hot window as HEVC main and
# the rest as H.264 sub, and the two renditions declare the SAME 4.809 s of wall time.
CODEC_SESSION = [
    {"ws": t(23, 48, 50, 809), "we": t(23, 48, 52, 9),   "boundary": "start"},
    {"ws": t(23, 48, 52, 9),   "we": t(23, 48, 56, 924), "boundary": ""},
    {"ws": t(23, 48, 57, 0),   "we": t(23, 49, 15, 809), "boundary": ""},
    {"ws": t(23, 49, 11, 0),   "we": t(23, 49, 15, 809), "boundary": "codec"},
]

CASES = [
    ("target inside the codec overlap fires",   ambiguous_at(CODEC_SESSION, t(23, 49, 13, 0)), [2, 3]),
    ("target before the overlap is silent",     ambiguous_at(CODEC_SESSION, t(23, 49, 5, 0)),  []),
    ("target in fragment 1 is silent",          ambiguous_at(CODEC_SESSION, t(23, 48, 54, 0)), []),
    # CV measured 10 of 35 manifest pairs overlapping by 0.007 s — sub-frame rounding at segment
    # boundaries, which no seek can resolve. Reporting it would train readers to skip the log.
    ("7 ms rounding overlap stays silent",
     ambiguous_at([{"ws": 0, "we": 10000}, {"ws": 9993, "we": 20000}], 9996), []),
    ("66 ms, just under one frame, stays silent",
     ambiguous_at([{"ws": 0, "we": 10000}, {"ws": 9934, "we": 20000}], 9950), []),
    ("67 ms, exactly one frame, fires",
     ambiguous_at([{"ws": 0, "we": 10000}, {"ws": 9933, "we": 20000}], 9950), [0, 1]),
    ("touching fragments are not overlapping",
     ambiguous_at([{"ws": 0, "we": 10000}, {"ws": 10000, "we": 20000}], 10000), []),
]

overlap = min(CODEC_SESSION[2]["we"], CODEC_SESSION[3]["we"]) - max(CODEC_SESSION[2]["ws"], CODEC_SESSION[3]["ws"])
CASES.append(("the measured overlap is 4809 ms", overlap, 4809))

failed = 0
for name, got, want in CASES:
    ok = got == want
    failed += 0 if ok else 1
    print("%-46s %s   got=%s want=%s" % (name, "PASS" if ok else "FAIL", got, want))
print("\n%d/%d passed" % (len(CASES) - failed, len(CASES)))
sys.exit(1 if failed else 0)
