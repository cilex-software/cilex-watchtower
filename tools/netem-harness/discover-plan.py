#!/usr/bin/env python3
"""Footage discovery for netem-soak.sh: hardcoded test days rot (backend prunes
aggressively — 2026-07-16: every day that served the 07-14 soak was already
gone). Builds the scenario plan from live /review/coverage instead.
Prints shell-safe assignments on stdout; exits 1 with a reason if no footage."""
import json, sys, urllib.request

base, user, pw = sys.argv[1], sys.argv[2], sys.argv[3]

def req(path, token=None, data=None):
    r = urllib.request.Request(base + path,
                               data=json.dumps(data).encode() if data else None,
                               headers={"Content-Type": "application/json",
                                        **({"Cookie": "access_token=" + token} if token else {})})
    with urllib.request.urlopen(r, timeout=10) as resp:
        return json.load(resp)

tok = req("/auth/login", data={"username": user, "password": pw})["access_token"]
cams = req("/streams", tok)
cams = cams if isinstance(cams, list) else cams.get("cameras", cams.get("items", cams.get("streams", [])))

have = []  # (ip, [days newest-first])
for c in cams:
    cid, ip = c.get("camera_id") or c.get("id"), c.get("ip")
    if not cid or not ip:
        continue
    try:
        cov = req(f"/review/coverage?camera_id={cid}", tok)
    except Exception:
        continue
    days = [d["date"] for d in cov.get("days", []) if d.get("has_footage")]
    if days:
        have.append((ip, sorted(days, reverse=True)))

if not have:
    print("no camera has ANY recorded footage (coverage empty fleet-wide)", file=sys.stderr)
    sys.exit(1)

have.sort(key=lambda t: len(t[1]), reverse=True)
plan = [{"ip": ip, "days": days[:2]} for ip, days in have[:2]]
churn_ip, churn_days = have[0]
churn_day = churn_days[0]
churn_alt = churn_days[1] if len(churn_days) > 1 else churn_days[0]
note = "; ".join(f"{ip}:{len(d)}d(latest {d[0]})" for ip, d in have[:4])
if churn_alt == churn_day:
    note += "; DEGRADED single-day churn (only one footage day fleet-wide)"

print(f"S1_PLAN='{json.dumps(plan, separators=(',', ':'))}'")
print(f"CHURN_IP={churn_ip}")
print(f"CHURN_DAY={churn_day}")
print(f"CHURN_ALT={churn_alt}")
print(f"DISC_NOTE={json.dumps(note)}")
