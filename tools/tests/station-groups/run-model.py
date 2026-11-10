#!/usr/bin/env python3
"""Exercise shipping CameraModel/group menus using disposable loopback sessions."""
import argparse
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
import time


COUNTS = (9, 21, 37, 17, 18, 31)
NAMES = ("4стр", "Entrances", "Внутри", "Крыша", "Лифты", "Улица")
STATION_KEY = "disposable-station-groups-key"
DISPLAY_KEY = "disposable-station-groups-display"


def token():
    claims = {"username": "station-groups-fixture", "role": "admin", "camera_scope": [],
              "exp": int(datetime.now(timezone.utc).timestamp()) + 3600}
    body = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
    return "e30." + body + ".fixture"


def roster(phase):
    rows = []
    for group, count in enumerate(COUNTS):
        for _ in range(count):
            gid = "group-%d" % group
            name = NAMES[group]
            if phase == "changed":
                if group == 0:
                    name = "Переименованная группа"
                if group == 5:
                    gid, name = "group-1", NAMES[1]
            rows.append({"camera_id": "fixture-camera-%03d" % len(rows), "name": "Fixture camera",
                         "status": "online", "recording": "unknown", "group_id": gid,
                         "group_name": name, "rtsp_url": "", "rtsp_sub_url": "", "snapshot_url": ""})
    if phase in ("scoped", "ungrouped", "missing-name"):
        rows = [dict(row) for row in rows if row["group_id"] == "group-2"][:3]
        if phase == "ungrouped":
            rows[0]["group_name"] = "<Крыша>"
            rows[1]["group_id"] = None
            rows[2]["group_id"] = ""
        if phase == "missing-name":
            for row in rows:
                row.pop("group_name")
    return rows


def execute(args, case, root, output, executable):
    folder = output / case
    folder.mkdir()
    profile = folder / "profile"
    profile.mkdir()
    template = Path(__file__).with_name("model.qml")
    qml = folder / "model.qml"
    qml.write_text(template.read_text(encoding="utf-8").replace("__CASE__", case), encoding="utf-8")
    state = {"phase": "initial"}
    requests = []
    lock = threading.Lock()

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *unused):
            pass

        def dispatch(self):
            self.rfile.read(int(self.headers.get("Content-Length", "0")))
            path = self.path.split("?", 1)[0]
            admin = "access_token=" in self.headers.get("Cookie", "")
            display = self.headers.get("X-Cilex-Display-Session") == DISPLAY_KEY
            with lock:
                phase = state["phase"]
                requests.append({"method": self.command, "path": path, "phase": phase,
                                 "operator_cookie": admin, "station_display": display})
            status, response = 200, {}
            if path == "/client/stations/display-session":
                if self.headers.get("X-Cilex-Station-Token") != STATION_KEY:
                    status, response = 401, {"code": "station_credential_rejected"}
                else:
                    response = {"token": DISPLAY_KEY, "scope": "station:live", "station_id": "fixture-station",
                                "camera_scope": [], "expires_at": (datetime.now(timezone.utc) + timedelta(minutes=15)).isoformat()}
            elif path in ("/auth/login", "/auth/refresh"):
                response = {"access_token": token()}
            elif path == "/auth/me":
                status, response = (200, {"ok": True}) if admin else (401, {"code": "fixture_sign_in_required"})
            elif path.startswith("/fixture/phase/"):
                with lock:
                    state["phase"] = path.rsplit("/", 1)[-1]
                response = {"ok": True}
            elif path == "/groups":
                if not admin:
                    status, response = 403, {"code": "display_session_out_of_scope"}
                else:
                    response = {"groups": [{"group_id": "group-%d" % i,
                                            "name": "Canonical entrance" if i == 0 else NAMES[i],
                                            "camera_count": 9999} for i in range(6)]
                                + [{"group_id": "empty-group", "name": "Empty operator group", "camera_count": 9999}]}
            elif path == "/streams":
                if not (admin or display):
                    status, response = 401, {"code": "fixture_sign_in_required"}
                else:
                    # Make the canonical definitions precede the first operator
                    # roster; this fixture targets station projection, not the
                    # independent canonical-groups notification ordering issue.
                    if case == "operator" and phase == "initial":
                        time.sleep(0.12)
                    response = {"streams": roster(phase)}
            else:
                status, response = 404, {"detail": "loopback fixture only"}
            raw = json.dumps(response, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            try:
                self.wfile.write(raw)
            except (BrokenPipeError, ConnectionResetError):
                pass

        do_GET = dispatch
        do_POST = dispatch

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = {key: value for key, value in os.environ.items() if not key.startswith("WT_")}
    empty_plugins = folder / "empty-gstreamer-plugins"
    empty_plugins.mkdir()
    env.update({"WT_SETTINGS_DIR": str(profile), "WT_TEST_QML": str(qml),
                "WT_FLIGHTREC_DIR": str(folder / "flightrec"),
                "WT_CV_URL": "http://127.0.0.1:%d" % server.server_port,
                "WT_NO_SCHEME_REG": "1", "WT_NO_STATION_ENROL": "1", "WT_RESTORE_OFF": "1",
                "WT_NO_STALL_WATCH": "1", "WT_WATCHDOG_OFF": "1", "WT_LANG": "en",
                "QT_QPA_PLATFORM": "offscreen", "QT_QUICK_BACKEND": "software", "QSG_RHI_BACKEND": "software",
                "QT_QUICK_CONTROLS_STYLE": "Basic", "QT_PLUGIN_PATH": str(args.qt_prefix / "plugins"),
                "QT_QML_IMPORT_PATH": str(args.qt_prefix / "qml"), "QML2_IMPORT_PATH": str(args.qt_prefix / "qml"),
                "GST_PLUGIN_SYSTEM_PATH_1_0": str(empty_plugins), "GST_PLUGIN_PATH_1_0": "", "GST_PLUGIN_PATH": "",
                "GST_REGISTRY_1_0": str(folder / "gst-registry.bin")})
    if case == "station":
        env["WT_STATION_TOKEN"] = STATION_KEY
    else:
        env.update(WT_CV_AUTOLOGIN="1", WT_CV_USER="station-groups-fixture", WT_CV_PASS="disposable")
    env["PATH"] = os.pathsep.join([str(args.qt_prefix / "bin"), str(args.binary.resolve().parent)]
                                  + [str(path) for path in args.runtime_bin] + [env.get("PATH", "")])
    try:
        completed = subprocess.run([str(executable)], cwd=folder, env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, timeout=60)
        log, code = completed.stdout.decode("utf-8", errors="replace"), completed.returncode
    except subprocess.TimeoutExpired as error:
        log, code = (error.stdout or b"").decode("utf-8", errors="replace"), 124
    finally:
        server.shutdown()
        server.server_close()
    flight = folder / "flightrec/watchtower.log"
    if flight.is_file():
        log += flight.read_text(encoding="utf-8", errors="replace")
    (folder / "model.log").write_text(log, encoding="utf-8")
    (folder / "requests.json").write_text(json.dumps(requests, indent=2), encoding="utf-8")
    checks, qml_checks = [], []
    for line in log.splitlines():
        if "[STATION-GROUP-CHECK] " in line:
            value = json.loads(line.split("[STATION-GROUP-CHECK] ", 1)[1])
            if value not in qml_checks:
                qml_checks.append(value)

    def check(name, passed):
        checks.append({"check": name, "passed": bool(passed)})

    check("isolated application exited successfully", code == 0)
    summaries = [line for line in log.splitlines() if "[STATION-GROUP-SUMMARY] " in line]
    check("shipping model and UI assertions completed", bool(summaries) and len(qml_checks) >= (32 if case == "station" else 13))
    check("all shipping model and UI assertions passed", bool(qml_checks) and all(value["ok"] for value in qml_checks))
    check("settings isolation marker exists", (profile / ".startup-settings.json").is_file())
    check("fixture executable has a watchdog-distinct name", executable.name.lower() != "watchtower.exe")
    check("stream metadata was read from loopback only", any(row["path"] == "/streams" for row in requests))
    if case == "station":
        check("the denied canonical groups API is never called without an operator session",
              not any(row["path"] == "/groups" and not row["operator_cookie"] for row in requests))
        check("station roster requests use display authorization; operator requests use their own cookie",
              all(row["station_display"] != row["operator_cookie"] for row in requests if row["path"] == "/streams"))
        check("same-process operator sign-in obtained canonical groups",
              any(row["path"] == "/groups" and row["operator_cookie"] for row in requests))
        check("rename/removal was received by normal status polling", any(row["path"] == "/streams" and row["phase"] == "changed" for row in requests))
    else:
        check("operator retains canonical group API access", any(row["path"] == "/groups" and row["operator_cookie"] for row in requests))
    check("no group mutation was attempted", not any(row["path"].startswith("/groups") and row["method"] != "GET" for row in requests))
    result = {"case": case, "exit_code": code, "passed": sum(row["passed"] for row in checks),
              "failed": sum(not row["passed"] for row in checks), "checks": checks, "qml_checks": qml_checks,
              "real_cameras_used": False, "production_settings_used": False, "executable": str(executable),
              "binary_sha256": hashlib.sha256(executable.read_bytes()).hexdigest()}
    (folder / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--qt-prefix", type=Path, required=True)
    parser.add_argument("--runtime-bin", type=Path, action="append", default=[])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--case", choices=("station", "operator", "all"), default="all")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    entry = (root / "src/main.cpp").read_text(encoding="utf-8")
    service = (root / "src/models/CameraAvailabilityService.cpp").read_text(encoding="utf-8")
    binary = args.binary.read_bytes()
    if "QStandardPaths::setTestModeEnabled(true)" not in entry or 'isolated + "/availability-station.conf"' not in service:
        raise RuntimeError("required source settings/data/credential isolation is absent")
    if b"setTestModeEnabled" not in binary or not any("availability-station.conf".encode(encoding) in binary for encoding in ("utf-8", "utf-16-le")):
        raise RuntimeError("supplied executable lacks required production isolation support")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    suffix = ".exe" if os.name == "nt" else ""
    executable = output / ("camera-groups-fixture" + suffix)
    shutil.copy2(args.binary, executable)
    if os.name != "nt":
        executable.chmod(executable.stat().st_mode | 0o100)
    cases = ("station", "operator") if args.case == "all" else (args.case,)
    results = [execute(args, case, root, output, executable) for case in cases]
    result = {"passed": sum(value["passed"] for value in results), "failed": sum(value["failed"] for value in results),
              "qml_assertions": sum(len(value["qml_checks"]) for value in results), "cases": results,
              "source_hashes": {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                                for path in (Path(__file__), Path(__file__).with_name("model.qml"), root / "src/models/CameraModel.cpp")}}
    (output / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({key: value for key, value in result.items() if key != "cases"}))
    return 1 if result["failed"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
