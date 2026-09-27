#!/usr/bin/env python3
"""The WORKER's side of the Windows replace race, flat out, for a Windows box to run
against the app's side (tools/tests/labs-station.cpp --stress). Linux never shows it.

    labs-station-stress.py write-status <dir> <seconds>   with   labsst --stress read-status <dir> <s>
    labs-station-stress.py read-control <dir> <seconds>   with   labsst --stress write-control <dir> <s>

Use a SCRATCH directory: control.json in the station's real one decides whether this
box scans. Prints "<role>: <failed> failed of <attempts>"; exit 1 if any failed.
"""
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "labs"))
import station as S  # noqa: E402

role, d, secs = sys.argv[1], sys.argv[2], float(sys.argv[3])
if os.path.abspath(d) == os.path.abspath(S.state_dir()):
    sys.exit("refusing: that is this station's REAL state directory")
os.makedirs(d, exist_ok=True)
n = bad = 0
end = time.monotonic() + secs
while time.monotonic() < end:
    if role == "write-status":
        n += 1
        try:
            S.write_status({"state": "running", "n": n}, directory=d)
        except OSError:
            bad += 1
    elif role == "read-control":
        c = S.read_control(d)
        if c["why"] == "never started on this station":
            continue                     # the app's side has not written yet
        n += 1
        if c["why"].startswith("control file unreadable"):
            bad += 1
    else:
        sys.exit("roles: write-status | read-control")
print(f"{role}: {bad} failed of {n}")
sys.exit(1 if bad else 0)
