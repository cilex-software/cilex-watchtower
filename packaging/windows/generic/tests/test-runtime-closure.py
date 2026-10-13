import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("closure", Path(__file__).parents[1] / "runtime-closure.py")
closure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(closure)


class RuntimeClosureTests(unittest.TestCase):
    def test_os_imports_do_not_need_developer_dlls(self):
        for name in ["KERNEL32.dll", "authz.dll", "icuuc.dll", "mscms.dll", "uiautomationcore.dll", "imagehlp.dll", "api-ms-win-core-file-l1-1-0.dll", "ext-ms-win-ntuser-window-l1-1-0.dll"]:
            self.assertTrue(closure.is_system(name))

    def test_crt_is_not_assumed_installed(self):
        for name in ["vcruntime140.dll", "msvcp140.dll", "concrt140.dll", "Qt6Core.dll", "libssl-3-x64.dll", "icu.dll", "libpq.dll", "oci.dll"]:
            self.assertFalse(closure.is_system(name))

    def test_closure_copies_transitive_dependency(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); payload = root / "payload"; sdk = root / "sdk"
            payload.mkdir(); sdk.mkdir()
            (payload / "app.exe").write_bytes(b"app")
            (sdk / "one.dll").write_bytes(b"one")
            (sdk / "two.dll").write_bytes(b"two")
            imports = {"app.exe": ["one.dll", "kernel32.dll"], "one.dll": ["two.dll"], "two.dll": []}
            result = closure.complete_closure(payload, [sdk], lambda p: imports[p.name])
            self.assertEqual(result["checkedFiles"], 3)
            self.assertEqual((payload / "two.dll").read_bytes(), b"two")

    def test_cycle_completes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); payload = root / "payload"; sdk = root / "sdk"
            payload.mkdir(); sdk.mkdir()
            (payload / "app.exe").write_bytes(b"app")
            (sdk / "one.dll").write_bytes(b"one")
            (sdk / "two.dll").write_bytes(b"two")
            imports = {"app.exe": ["one.dll"], "one.dll": ["two.dll"], "two.dll": ["one.dll"]}
            result = closure.complete_closure(payload, [sdk], lambda p: imports[p.name])
            self.assertEqual(result["checkedFiles"], 3)

    def test_missing_dependency_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            payload = Path(tmp)
            (payload / "app.exe").write_bytes(b"app")
            with self.assertRaisesRegex(ValueError, "missing runtime"):
                closure.complete_closure(payload, [], lambda p: ["missing.dll"])

    def test_conflicting_sdk_files_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); payload = root / "payload"; one = root / "one"; two = root / "two"
            for p in [payload, one, two]: p.mkdir()
            (payload / "app.exe").write_bytes(b"app")
            (one / "same.dll").write_bytes(b"one")
            (two / "same.dll").write_bytes(b"two")
            with self.assertRaisesRegex(ValueError, "ambiguous runtime"):
                closure.complete_closure(payload, [one, two], lambda p: ["same.dll"])

    def test_same_hash_in_multiple_roots_is_not_conflict(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); payload = root / "payload"; one = root / "one"; two = root / "two"
            for p in [payload, one, two]: p.mkdir()
            (payload / "app.exe").write_bytes(b"app")
            for p in [one, two]: (p / "same.dll").write_bytes(b"identical")
            result = closure.complete_closure(payload, [one, two], lambda p: ["same.dll"] if p.suffix == ".exe" else [])
            self.assertEqual(result["checkedFiles"], 2)

    def test_plugin_own_directory_resolution(self):
        with tempfile.TemporaryDirectory() as tmp:
            payload = Path(tmp); plugin = payload / "plugins"; plugin.mkdir()
            (plugin / "custom.dll").write_bytes(b"custom")
            (plugin / "local.dll").write_bytes(b"local")
            result = closure.complete_closure(payload, [], lambda p: ["local.dll"] if p.name == "custom.dll" else [])
            self.assertEqual(result["checkedFiles"], 2)


if __name__ == "__main__":
    unittest.main()
