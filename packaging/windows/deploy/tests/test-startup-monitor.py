#!/usr/bin/env python3
"""Process-free startup-monitor checks using only disposable files and fake data."""
from __future__ import annotations
import ctypes
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import tempfile
import time
import unittest
from unittest import mock

MONITOR = Path(__file__).resolve().parents[1] / "isolated-startup.py"
SPEC = importlib.util.spec_from_file_location("startup_monitor_under_test", MONITOR)
MODULE = importlib.util.module_from_spec(SPEC)
# A regression introducing a native API during import fails safely.
with mock.patch.object(ctypes, "WinDLL", side_effect=AssertionError("Native calls are prohibited in these tests"), create=True):
    SPEC.loader.exec_module(MODULE)


class SafeMonitorTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="wt-startup-monitor-unit-")
        self.root = Path(self.directory.name)
        def cleanup():
            target = self.root.resolve()
            if target.parent != Path(tempfile.gettempdir()).resolve() or not target.name.startswith("wt-startup-monitor-unit-"):
                raise AssertionError("Disposable cleanup path is unsafe")
            self.directory.cleanup()
        self.addCleanup(cleanup)
        self.native_guard = mock.patch.object(ctypes, "WinDLL", side_effect=AssertionError("Native calls are prohibited"), create=True)
        self.native_guard.start()
        self.addCleanup(self.native_guard.stop)
        self.home = self.root / "home"
        self.user = self.home / "settings" / "user"
        self.system = self.home / "settings" / "system"
        self.user.mkdir(parents=True)
        self.system.mkdir()
        self.marker = self.home / "settings" / ".startup-settings.json"
        self.now = time.time()
        self.valid = {"pid": 123, "format": "ini", "userPath": str(self.user), "systemPath": str(self.system)}

    def mark(self, **changes):
        data = dict(self.valid)
        data.update(changes)
        self.marker.write_text(json.dumps(data), encoding="utf-8")
        os.utime(self.marker, (self.now, self.now))

    def image(self, leaf="fixture.exe", machine=0x8664, literals=("WT_SETTINGS_DIR", ".startup-settings.json"), encoding="ascii"):
        data = bytearray(256)
        data[:2] = b"MZ"
        struct.pack_into("<I", data, 0x3C, 128)
        data[128:132] = b"PE\0\0"
        struct.pack_into("<H", data, 132, machine)
        for literal in literals:
            data.extend(literal.encode(encoding) + b"\0\0")
        path = self.root / leaf
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def test_marker_valid(self):
        self.mark()
        self.assertTrue(MODULE.settings_marker(self.home, 123, self.now))

    def test_marker_wrong_pid(self):
        self.mark(pid=124)
        self.assertFalse(MODULE.settings_marker(self.home, 123, self.now))

    def test_marker_boolean_pid(self):
        self.mark(pid=True)
        self.assertFalse(MODULE.settings_marker(self.home, 123, self.now))

    def test_marker_wrong_format(self):
        self.mark(format="native")
        self.assertFalse(MODULE.settings_marker(self.home, 123, self.now))

    def test_marker_user_path_escape(self):
        self.mark(userPath=str(self.root))
        self.assertFalse(MODULE.settings_marker(self.home, 123, self.now))

    def test_marker_system_path_escape(self):
        self.mark(systemPath=str(self.root))
        self.assertFalse(MODULE.settings_marker(self.home, 123, self.now))

    def test_marker_stale(self):
        self.mark()
        os.utime(self.marker, (self.now - 100, self.now - 100))
        self.assertFalse(MODULE.settings_marker(self.home, 123, self.now))

    def test_marker_missing(self):
        self.assertFalse(MODULE.settings_marker(self.home, 123, self.now))

    def test_marker_invalid_json(self):
        self.marker.write_text("not JSON", encoding="utf-8")
        self.assertFalse(MODULE.settings_marker(self.home, 123, self.now))

    def test_marker_missing_private_directory(self):
        self.mark()
        self.system.rmdir()
        self.assertFalse(MODULE.settings_marker(self.home, 123, self.now))

    def test_marker_invalid_path_type(self):
        self.mark(userPath=None)
        self.assertFalse(MODULE.settings_marker(self.home, 123, self.now))

    def test_binary_missing_mz(self):
        path = self.root / "not-pe.exe"
        path.write_bytes(b"not executable")
        with self.assertRaisesRegex(MODULE.Refused, "TARGET_NOT_WINDOWS_EXECUTABLE"):
            MODULE.validate_binary(path)

    def test_binary_pe_offset_outside_file(self):
        path = self.image()
        data = bytearray(path.read_bytes())
        struct.pack_into("<I", data, 0x3C, 4096)
        path.write_bytes(data)
        with self.assertRaisesRegex(MODULE.Refused, "TARGET_PE_HEADER_INVALID"):
            MODULE.validate_binary(path)

    def test_binary_wrong_pe_signature(self):
        path = self.image()
        data = bytearray(path.read_bytes())
        data[128:132] = b"NOPE"
        path.write_bytes(data)
        with self.assertRaisesRegex(MODULE.Refused, "TARGET_PE_HEADER_INVALID"):
            MODULE.validate_binary(path)

    def test_binary_wrong_architecture(self):
        with self.assertRaisesRegex(MODULE.Refused, "TARGET_MUST_BE_X64"):
            MODULE.validate_binary(self.image(machine=0x14C))

    def test_binary_old_hook_absent(self):
        with self.assertRaisesRegex(MODULE.Refused, "TARGET_SETTINGS_HOOK_NOT_PRESENT"):
            MODULE.validate_binary(self.image(literals=()))

    def test_binary_only_environment_literal(self):
        with self.assertRaisesRegex(MODULE.Refused, "TARGET_SETTINGS_HOOK_NOT_PRESENT"):
            MODULE.validate_binary(self.image(literals=("WT_SETTINGS_DIR",)))

    def test_binary_only_marker_literal(self):
        with self.assertRaisesRegex(MODULE.Refused, "TARGET_SETTINGS_HOOK_NOT_PRESENT"):
            MODULE.validate_binary(self.image(literals=(".startup-settings.json",)))

    def test_binary_ascii_hook_literals(self):
        MODULE.validate_binary(self.image())

    def test_binary_utf16_hook_literals(self):
        MODULE.validate_binary(self.image(encoding="utf-16le"))

    def test_binary_installed_wall_path_refused(self):
        path = self.image("AppData/Local/Programs/Cilex Watchtower/watchtower.exe")
        with self.assertRaisesRegex(MODULE.Refused, "INSTALLED_CAMERA_WALL_REFUSED"):
            MODULE.validate_binary(path)

    def test_environment_sensitive_values_removed(self):
        fake = {"PATH": "fixture-path", "WT_STATION_TOKEN": "fake", "WT_CV_AUTOLOGIN": "fake", "SESSION_AUTH": "fake", "API_KEY": "fake", "PASSWORD": "fake", "HTTPS_PROXY": "fake", "QT_PLUGIN_PATH": "fake", "QML_IMPORT_PATH": "fake", "ORDINARY_VALUE": "keep"}
        with mock.patch.dict(os.environ, fake, clear=True):
            result = MODULE.isolated_environment(self.root / "private", self.root / "flightrec")
        for name in ("WT_STATION_TOKEN", "WT_CV_AUTOLOGIN", "SESSION_AUTH", "API_KEY", "PASSWORD", "HTTPS_PROXY", "QT_PLUGIN_PATH", "QML_IMPORT_PATH"):
            self.assertNotIn(name, result)
        self.assertEqual(result["ORDINARY_VALUE"], "keep")

    def test_environment_private_settings_and_profile(self):
        private = self.root / "private"
        flightrec = self.root / "flightrec"
        with mock.patch.dict(os.environ, {"PATH": "fixture"}, clear=True):
            result = MODULE.isolated_environment(private, flightrec)
        self.assertEqual(result["WT_SETTINGS_DIR"], str(private / "settings"))
        self.assertEqual(result["WT_NO_STATION_ENROL"], "1")
        self.assertEqual(result["WT_NO_SCHEME_REG"], "1")
        self.assertEqual(result["WT_CV_URL"], "http://127.0.0.1:1")
        for name in ("USERPROFILE", "HOME", "APPDATA", "LOCALAPPDATA", "TEMP", "TMP"):
            self.assertTrue(Path(result[name]).is_relative_to(private))

    def test_private_home_nonempty_refused_without_deletion(self):
        home = self.root / "nonempty"
        home.mkdir()
        sentinel = home / "sentinel"
        sentinel.write_text("fixture", encoding="ascii")
        with self.assertRaisesRegex(MODULE.Refused, "PRIVATE_DIRECTORY_MUST_BE_FRESH_AND_EMPTY"):
            MODULE.make_private_directory(home)
        self.assertEqual(sentinel.read_text(), "fixture")

    def test_private_home_file_refused(self):
        path = self.root / "not-directory"
        path.write_text("fixture", encoding="ascii")
        with self.assertRaisesRegex(MODULE.Refused, "PRIVATE_DIRECTORY_MUST_BE_FRESH_AND_EMPTY"):
            MODULE.make_private_directory(path)

    def test_private_home_relative_refused(self):
        with self.assertRaisesRegex(MODULE.Refused, "PRIVATE_DIRECTORY_MUST_BE_ABSOLUTE"):
            MODULE.make_private_directory(Path("relative-fixture"))

    def test_private_home_fresh_created(self):
        path = self.root / "fresh"
        MODULE.make_private_directory(path)
        self.assertTrue(path.is_dir())
        self.assertEqual(list(path.iterdir()), [])


if __name__ == "__main__":
    output = io.StringIO()
    result = unittest.TextTestRunner(stream=output, verbosity=0).run(unittest.defaultTestLoader.loadTestsFromTestCase(SafeMonitorTests))
    failed = len(result.failures) + len(result.errors)
    passed = result.testsRun - failed - len(result.skipped)
    if failed:
        for case, _ in result.failures + result.errors:
            print("FAIL: " + case.id().split(".")[-1])
    print(f"Startup monitor tests: {passed} passed, {failed} failed, {len(result.skipped)} skipped.")
    raise SystemExit(0 if result.wasSuccessful() else 1)
