#!/usr/bin/env python3
"""Real CameraModel + worker journal against 133 loopback-only fake cameras."""
import argparse
import base64
from datetime import datetime, timezone
import http.server
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import threading


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--qt-prefix", type=Path, required=True)
    parser.add_argument("--runtime-bin", type=Path, action="append", default=[])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    profile = output / "profile"
    profile.mkdir()
    # Refuse an older binary that could touch the operator's settings or token.
    root = Path(__file__).resolve().parents[3]
    service = (root / "src/models/CameraAvailabilityService.cpp").read_text(encoding="utf-8")
    entry = (root / "src/main.cpp").read_text(encoding="utf-8")
    if 'isolated + "/availability-station.conf"' not in service or "QStandardPaths::setTestModeEnabled(true)" not in entry:
        raise RuntimeError("required settings, data and credential isolation is missing")
    binary = args.binary.read_bytes()
    if b"setTestModeEnabled" not in binary or not any(
            "availability-station.conf".encode(encoding) in binary for encoding in ("utf-8", "utf-16-le")):
        raise RuntimeError("the supplied binary does not contain the required isolation support")
    started = datetime.now(timezone.utc).isoformat()
    fixture = {"phase": "healthy", "since": started, "camera_status": "online"}
    requests = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *unused):
            pass

        def dispatch(self):
            self.rfile.read(int(self.headers.get("Content-Length", "0")))
            path = self.path.split("?")[0]
            requests.append({"method": self.command, "path": path, "phase": fixture["phase"]})
            status = 200
            if path == "/auth/login":
                claims = {"username": "availability-fixture", "role": "admin", "camera_scope": [],
                          "exp": int(datetime.now(timezone.utc).timestamp()) + 3600}
                payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
                response = {"access_token": "e30." + payload + ".fixture"}
            elif path.startswith("/fixture/"):
                fixture["phase"] = path.rsplit("/", 1)[-1]
                wanted = "offline" if fixture["phase"] == "offline" else "online"
                if fixture["phase"] != "unavailable" and wanted != fixture["camera_status"]:
                    fixture["since"] = datetime.now(timezone.utc).isoformat()
                    fixture["camera_status"] = wanted
                response = {"ok": True}
            elif path == "/groups":
                response = {"groups": []}
            elif path == "/streams":
                status = 503 if fixture["phase"] == "unavailable" else 200
                response = {"detail": "loopback fixture unavailable"} if status != 200 else {
                    "streams": [{"camera_id": "fixture-camera-%03d" % i,
                                 "name": "Fixture %d" % i, "status": "offline" if i == 0 and fixture["phase"] == "offline" else "online",
                                 "status_since": fixture["since"] if i == 0 else started, "recording": "unknown",
                                 "rtsp_url": "", "rtsp_sub_url": "", "snapshot_url": ""}
                                for i in range(133)]}
            else:
                status, response = 404, {"detail": "isolated fixture"}
            raw = json.dumps(response).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
        do_GET = dispatch
        do_POST = dispatch

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = {k: v for k, v in os.environ.items() if not k.startswith("WT_")}
    empty_plugins = output / "empty-gstreamer-plugins"
    empty_plugins.mkdir()
    env.update({"WT_SETTINGS_DIR": str(profile), "WT_TEST_QML": str(Path(__file__).with_name("model.qml")),
                "WT_FLIGHTREC_DIR": str(output / "flightrec"),
                "WT_CV_URL": "http://127.0.0.1:%d" % server.server_port,
                "WT_CV_AUTOLOGIN": "1", "WT_CV_USER": "availability-fixture", "WT_CV_PASS": "fixture",
                "WT_NO_POLL": "1", "WT_NO_SCHEME_REG": "1", "WT_NO_STATION_ENROL": "1",
                "WT_RESTORE_OFF": "1", "WT_NO_STALL_WATCH": "1", "WT_LANG": "en",
                "QT_QPA_PLATFORM": "offscreen", "QT_QUICK_BACKEND": "software", "QSG_RHI_BACKEND": "software",
                "QT_PLUGIN_PATH": str(args.qt_prefix / "plugins"), "QT_QML_IMPORT_PATH": str(args.qt_prefix / "qml"),
                "QML2_IMPORT_PATH": str(args.qt_prefix / "qml"), "GST_PLUGIN_SYSTEM_PATH_1_0": str(empty_plugins),
                "GST_PLUGIN_PATH_1_0": "", "GST_PLUGIN_PATH": "", "GST_REGISTRY_1_0": str(output / "gst-registry.bin")})
    env["PATH"] = os.pathsep.join([str(args.qt_prefix / "bin")] + [str(p) for p in args.runtime_bin] + [env.get("PATH", "")])
    try:
        completed = subprocess.run([str(args.binary.resolve())], env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, timeout=45)
        log, code = completed.stdout.decode(errors="replace"), completed.returncode
    except subprocess.TimeoutExpired as error:
        log, code = (error.stdout or b"").decode(errors="replace"), 124
    finally:
        server.shutdown()
        server.server_close()
    flight_log = output / "flightrec/watchtower.log"
    if flight_log.is_file():
        log += flight_log.read_text(encoding="utf-8", errors="replace")
    (output / "model.log").write_text(log, encoding="utf-8")
    (output / "requests.json").write_text(json.dumps(requests, indent=2), encoding="utf-8")
    checks = []

    def check(description, passed):
        checks.append({"check": description, "passed": bool(passed)})
    check("application fixture exited successfully", code == 0)
    qml_checks = [json.loads(line.split("[AVAILABILITY-MODEL-CHECK] ", 1)[1])
                  for line in log.splitlines() if "[AVAILABILITY-MODEL-CHECK] " in line]
    check("actual QML assertions ran and passed", len(qml_checks) >= 10 and all(c["ok"] for c in qml_checks))
    check("settings isolation marker exists", (profile / ".startup-settings.json").is_file())
    database = profile / "availability.sqlite3"
    check("availability database is inside the isolated profile", database.is_file())
    events = []
    if database.is_file():
        with sqlite3.connect("file:" + database.as_posix() + "?mode=ro", uri=True) as db:
            events = [json.loads(row[0]) for row in db.execute("SELECT payload FROM events ORDER BY local_seq")]
    outages = [e for e in events if e.get("domain") == "backend_reachability" and e.get("state") == "unavailable"]
    check("three API failures did not create 133 camera outages", len(outages) == 1 and outages[0]["camera_id"] == "fixture-camera-000")
    check("the actual reported camera failure was recorded once", len(outages) == 1 and outages[0]["transition"] == "failure")
    recoveries = [e for e in events if e.get("domain") == "backend_reachability" and e.get("transition") == "recovery"]
    check("real camera recovery refers to the same camera failure", len(recoveries) == 1 and len(outages) == 1
          and recoveries[0].get("related_event_id") == outages[0]["event_id"])
    api_failures = [e for e in events if e.get("domain") == "backend_connectivity" and e.get("state") == "degraded"]
    check("API failure is one station condition", len(api_failures) == 1 and api_failures[0].get("camera_id") is None)
    check("reported evidence retains its provenance", all(e.get("provenance") == "backend_reported_by_client" for e in outages + recoveries))
    check("no live delivery is invented from status polls", not any(e.get("domain") == "live_delivery" for e in events))
    check("unprovisioned observations remain pending locally", bool(events) and not any(r["path"].startswith("/client/stations/") for r in requests))
    (output / "events.json").write_text(json.dumps(events, indent=2), encoding="utf-8")
    result = {"passed": sum(c["passed"] for c in checks), "failed": sum(not c["passed"] for c in checks),
              "exit_code": code, "checks": checks, "event_count": len(events), "real_cameras_used": False,
              "binary_sha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
              "sources": {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in (root / "src/models/CameraModel.cpp", Path(__file__), Path(__file__).with_name("model.qml"))}}
    (output / "result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result))
    return 0 if not result["failed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
