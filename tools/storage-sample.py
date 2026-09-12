#!/usr/bin/env python3
"""One line per sample of the signals that matter AFTER 2026-09-12 b0a49eb.

Topology Free is deliberately NOT here: it reads 0 and that is correct now. The binding
constraint is real free disk on each volume server's /data, guarded by minFreeSpace=5GiB,
and the number that decides whether the disk comes back is garbage awaiting vacuum.
Fields requested by the cilex-vision agent, 2026-09-12 ~17:00.
"""
import json, subprocess, urllib.request, datetime, sys

NODES = {"07fa": "seaweed-volume-07fa7c7d-d56b-451a-b458-846deaef3103",
         "4fa8": "seaweed-volume-4fa8f6a7-2712-4cb3-bb2b-01e65be9a7bf"}

def sh(cmd, t=30):
    try: return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=t).stdout.strip()
    except Exception: return ""

def df_free_gb(container):
    out = sh(f"docker exec {container} sh -c 'df -BM /data 2>/dev/null | tail -1'")
    try: return int(out.split()[3].rstrip("M")) / 1024.0
    except Exception: return None

def vol_stats():
    """per node: (garbage GB, largest volume GB, count) from the master's /vol/status"""
    try:
        d = json.load(urllib.request.urlopen("http://127.0.0.1:9333/vol/status", timeout=20))
    except Exception:
        return {}, None
    out = {}
    dcs = ((d.get("Volumes") or {}).get("DataCenters") or {})
    for _dc, disks in dcs.items():
        for _disk, servers in (disks or {}).items():
            for server, vols in (servers or {}).items():
                key = server.split("-")[2][:4] if server.count("-") > 2 else server[:4]
                g = sum(v.get("DeletedByteCount", 0) for v in vols or [])
                big = max((v.get("Size", 0) for v in vols or []), default=0)
                cur = out.get(key, (0, 0, 0))
                out[key] = (cur[0] + g, max(cur[1], big), cur[2] + len(vols or []))
    return out, d.get("Version")

def count(container, pattern, since="3m"):
    o = sh(f"docker logs --since {since} {container} 2>&1 | grep -c '{pattern}'")
    try: return int(o)
    except Exception: return -1

spool = sh("docker exec recorder-service sh -c 'du -sm /tmp/recorder 2>/dev/null | cut -f1'")
vs, ver = vol_stats()
parts = [datetime.datetime.now().strftime("%H:%M:%S")]
for short, cont in NODES.items():
    free = df_free_gb(cont)
    g, big, n = vs.get(short, (0, 0, 0))
    parts.append(f"{short}: free={free:.0f}G garbage={g/1e9:.0f}G largest={big/1e9:.2f}G vols={n}"
                 if free is not None else f"{short}: free=? garbage={g/1e9:.0f}G largest={big/1e9:.2f}G vols={n}")
parts.append(f"spool={spool}M")
parts.append(f"failed_to_pick={count('seaweed-master','failed to pick')}")
parts.append(f"s3_assign_err={count('s3','assign volume')}")
parts.append(f"upload_fail={count('recorder-service','Failed to upload','1m')}")
if ver: parts.append(f"ver={ver.split()[0]}")
print("  ".join(parts))
