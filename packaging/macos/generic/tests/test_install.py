"""Isolated fixtures only: no launchctl, application starts or station changes."""
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import pwd
import sys
import tarfile
import tempfile
import types
import unittest
import uuid
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import install
import runtime


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="Cilex тест ")
        self.root = Path(self.temporary.name).resolve()
        self.preference_cache = mock.patch.object(install, "preferences_cache", return_value={}).start()
        self.registration = mock.patch.object(install, "registration_snapshot", return_value={"state": "Absent", "bundle_identifier": None, "application_path": None}).start()
        # Transaction fixtures model settled launchd operations. Teardown/start
        # transitions themselves are exercised by test_launchd_lifecycle.py.
        mock.patch.object(install, 'wait_job_unloaded').start()
        mock.patch.object(install, 'settled_job_state', side_effect=lambda t, m: install.job_state(t)).start()
        mock.patch.object(install, 'bootstrap_job', side_effect=lambda t, m:
                          install.execute(['/bin/launchctl', 'bootstrap', t['domain'], str(t['agent'])])).start()
        self.addCleanup(mock.patch.stopall)

    def tearDown(self):
        self.temporary.cleanup()

    def archive(self, entries):
        archive = self.root / "package.tar.gz"
        with tarfile.open(archive, "w:gz") as target:
            for name, kind, value, mode in entries:
                info = tarfile.TarInfo(name)
                info.mode = mode
                if kind == "file":
                    data = value.encode()
                    info.size = len(data)
                    target.addfile(info, io.BytesIO(data))
                else:
                    info.type = tarfile.SYMTYPE if kind == "symlink" else tarfile.LNKTYPE if kind == "hardlink" else tarfile.FIFOTYPE
                    info.linkname = value
                    target.addfile(info)
        destination = self.root / "staging"
        destination.mkdir(exist_ok=True)
        return archive, destination

    def extract(self, entries):
        archive, destination = self.archive(entries)
        install.safe_extract(archive, destination, install.sha256(archive))
        return destination

    def assertArchiveRejected(self, entries, finding):
        with self.assertRaises(install.InstallError) as error:
            self.extract(entries)
        self.assertEqual(error.exception.finding, finding)

    def test_regular_unicode_spaces_and_contained_framework_symlinks(self):
        root = self.extract([("watchtower.app/Frameworks/QtCore/Versions/A/QtCore", "file", "binary", 0o755),
                             ("watchtower.app/Frameworks/QtCore/Versions/Current", "symlink", "A", 0o777),
                             ("watchtower.app/Frameworks/QtCore/QtCore", "symlink", "Versions/Current/QtCore", 0o777),
                             ("Установка с пробелом/readme.txt", "file", "Привет", 0o644)])
        self.assertEqual((root / "watchtower.app/Frameworks/QtCore/QtCore").read_text(), "binary")
        self.assertEqual((root / "Установка с пробелом/readme.txt").read_text(), "Привет")

    def test_traversal_rejected(self):
        self.assertArchiveRejected([("../escaped", "file", "bad", 0o644)], "archive.path")
        self.assertFalse((self.root / "escaped").exists())

    def test_absolute_rejected(self):
        self.assertArchiveRejected([("/tmp/escaped", "file", "bad", 0o644)], "archive.path")

    def test_hardlink_rejected(self):
        self.assertArchiveRejected([("hard", "hardlink", "target", 0o644)], "archive.type")

    def test_fifo_rejected(self):
        self.assertArchiveRejected([("fifo", "fifo", "", 0o644)], "archive.type")

    def test_link_escape_rejected(self):
        self.assertArchiveRejected([("link", "symlink", "../outside", 0o777)], "archive.link")

    def test_absolute_link_rejected(self):
        self.assertArchiveRejected([("link", "symlink", "/etc/passwd", 0o777)], "archive.link")

    def test_file_through_symlink_rejected(self):
        self.assertArchiveRejected([("inside/file", "file", "original", 0o644),
                                    ("link", "symlink", "inside", 0o777),
                                    ("link/payload", "file", "evil", 0o644)], "archive.link_parent")

    def test_cyclic_symlink_rejected(self):
        self.assertArchiveRejected([("a", "symlink", "b", 0o777), ("b", "symlink", "a", 0o777)], "archive.link")

    def test_case_collision_rejected(self):
        self.assertArchiveRejected([("App", "file", "a", 0o644), ("app", "file", "b", 0o644)], "archive.collision")

    def test_implicit_parent_case_collision_rejected(self):
        self.assertArchiveRejected([("App/a", "file", "a", 0o644), ("app/b", "file", "b", 0o644)], "archive.collision")

    def test_normalization_collision_rejected(self):
        self.assertArchiveRejected([("é", "file", "a", 0o644), ("e\u0301", "file", "b", 0o644)], "archive.collision")

    def test_world_write_rejected(self):
        self.assertArchiveRejected([("app", "file", "bad", 0o666)], "archive.permissions")

    def test_setuid_rejected(self):
        self.assertArchiveRejected([("app", "file", "bad", 0o4755)], "archive.permissions")

    def test_hash_mismatch_rejected_before_writes(self):
        archive, destination = self.archive([("app", "file", "value", 0o644)])
        with self.assertRaises(install.InstallError) as error:
            install.safe_extract(archive, destination, "0" * 64)
        self.assertEqual(error.exception.finding, "package.hash")
        self.assertEqual(list(destination.iterdir()), [])

    def test_missing_trust_rejected(self):
        archive, destination = self.archive([("app", "file", "value", 0o644)])
        with self.assertRaises(install.InstallError) as error:
            install.safe_extract(archive, destination)
        self.assertEqual(error.exception.finding, "package.trust")

    def test_archive_space_not_overridable(self):
        archive, destination = self.archive([("app", "file", "value", 0o644)])
        with mock.patch.object(install.shutil, "disk_usage", return_value=types.SimpleNamespace(free=0)):
            with self.assertRaises(install.InstallError) as error:
                install.safe_extract(archive, destination, install.sha256(archive))
        self.assertEqual(error.exception.finding, "space.extraction")
        self.assertEqual(list(destination.iterdir()), [])

    def test_quarantine_propagates_without_removal(self):
        archive, destination = self.archive([("app/file", "file", "value", 0o644)])
        with mock.patch.object(install, "read_quarantine", return_value=b"0083;source"), mock.patch.object(install, "write_quarantine") as setter:
            install.safe_extract(archive, destination, install.sha256(archive))
        setter.assert_called_once_with(destination / "app", b"0083;source")

    @unittest.skipUnless(sys.platform == "darwin", "Darwin extended attributes")
    def test_native_quarantine_round_trip_on_owned_fixture(self):
        archive, destination = self.archive([("app/file", "file", "value", 0o644)])
        quarantine = b"0083;00000000;CilexDeploymentFixture;"
        install.write_quarantine(archive, quarantine)
        self.assertEqual(install.read_quarantine(archive), quarantine)
        install.safe_extract(archive, destination, install.sha256(archive))
        self.assertEqual(install.read_quarantine(archive), quarantine)
        self.assertEqual(install.read_quarantine(destination / "app"), quarantine)

    def test_inventory_corruption_and_addition_rejected(self):
        root = self.extract([("file", "file", "value", 0o644)])
        manifest = {"files": [{"path": "file", "type": "file", "mode": 0o644, "sha256": install.sha256(root / "file"), "size": 5}]}
        install.verify_inventory(root, manifest)
        (root / "file").write_text("other")
        with self.assertRaises(install.InstallError) as error:
            install.verify_inventory(root, manifest)
        self.assertEqual(error.exception.finding, "package.hash")
        (root / "extra").write_text("extra")
        with self.assertRaises(install.InstallError) as error:
            install.verify_inventory(root, manifest)
        self.assertEqual(error.exception.finding, "package.inventory")

    def target(self):
        home = self.root / "Desktop Пользователь"
        home.mkdir(exist_ok=True)
        app = home / "Applications/watchtower.app"
        target = {"uid": os.geteuid(), "gid": os.getegid(), "user": pwd.getpwuid(os.geteuid()).pw_name,
                  "home": home, "path": app, "id": "0123456789abcdef01234567",
                  "label": "com.cilexvision.watchtower.0123456789abcdef01234567", "domain": "gui/501"}
        target["agent"] = home / "Library/LaunchAgents" / (target["label"] + ".plist")
        target["support"] = home / "Library/Application Support/CilexWatchtower/Deploy" / target["id"]
        return target

    def manifest(self):
        return {"app": "watchtower.app", "warden": "watchtower.app/Contents/Resources/warden/cilex-warden", "_executable": "watchtower"}

    def test_launchagent_direct_parentage_contract_unicode_absolute_paths(self):
        target = self.target()
        job = install.launchagent(target, self.manifest(), {})
        self.assertEqual(job["ProgramArguments"][:2], ["/usr/bin/env", "-i"])
        self.assertEqual(job["ProgramArguments"][-2:], [str(target["path"] / "Contents/Resources/warden/cilex-warden"), "run"])
        environment = dict(value.split("=", 1) for value in job["ProgramArguments"][2:-2])
        self.assertEqual(environment["WT_WARDEN_APP_CMD"], str(target["path"] / "Contents/MacOS/watchtower"))
        self.assertNotIn("STATION_TOKEN", environment)
        self.assertNotIn("EnvironmentVariables", job)
        self.assertFalse(job["AbandonProcessGroup"])
        self.assertEqual(job["KeepAlive"], {"SuccessfulExit": False})
        plistlib.loads(plistlib.dumps(job))

    def test_owned_environment_launcher_and_exact_legacy_upgrade_are_recognized(self):
        target, manifest, package = self.transaction_fixture()
        job = install.launchagent(target, manifest, {"backend_url": "https://example.invalid"})
        target["agent"].write_bytes(plistlib.dumps(job))
        install.validate_existing(target, manifest)
        legacy = dict(job, ProgramArguments=job["ProgramArguments"][-2:], EnvironmentVariables=dict(value.split("=", 1) for value in job["ProgramArguments"][2:-2]))
        target["agent"].write_bytes(plistlib.dumps(legacy))
        install.validate_existing(target, manifest)

    def test_unowned_environment_launcher_variants_are_refused(self):
        target, manifest, package = self.transaction_fixture()
        original = install.launchagent(target, manifest, {})
        variants = [dict(original, Program="/bin/sh"),
                    dict(original, EnvironmentVariables={"DYLD_LIBRARY_PATH": "/unrelated"}),
                    dict(original, ProgramArguments=["/usr/bin/env"] + original["ProgramArguments"][2:]),
                    dict(original, ProgramArguments=original["ProgramArguments"] + ["unexpected"]),
                    dict(original, ProgramArguments=original["ProgramArguments"][:2] + ["DYLD_LIBRARY_PATH=/unrelated"] + original["ProgramArguments"][2:]),
                    dict(original, ProgramArguments=original["ProgramArguments"][:2] + [original["ProgramArguments"][2]] + original["ProgramArguments"][2:])]
        legacy = dict(original, ProgramArguments=original["ProgramArguments"][-2:], EnvironmentVariables=dict(value.split("=", 1) for value in original["ProgramArguments"][2:-2]))
        legacy["EnvironmentVariables"]["DYLD_LIBRARY_PATH"] = "/unrelated"
        variants.append(legacy)
        for value in variants:
            with self.subTest(arguments=value["ProgramArguments"]):
                target["agent"].write_bytes(plistlib.dumps(value))
                with self.assertRaises(install.InstallError) as error:
                    install.validate_existing(target, manifest)
                self.assertEqual(error.exception.finding, "startup.ownership")

    def test_root_gui_rejected(self):
        with mock.patch.object(install.pwd, "getpwnam", return_value=types.SimpleNamespace(pw_uid=0)):
            with self.assertRaises(install.InstallError) as error:
                install.resolve_target({"desktop_user": "root"})
        self.assertEqual(error.exception.finding, "target.root_gui")

    def test_arbitrary_destination_rejected(self):
        with self.assertRaises(install.InstallError) as error:
            install.resolve_target({"desktop_user": pwd.getpwuid(os.geteuid()).pw_name, "install_dir": str(self.root)})
        self.assertEqual(error.exception.finding, "target.path")

    def test_absolute_custom_bundle_name_with_unicode_and_spaces(self):
        path = self.root / "Камеры наблюдения.app"
        target = install.resolve_target({"desktop_user": pwd.getpwuid(os.geteuid()).pw_name, "install_dir": str(path)})
        self.assertEqual(target["path"], path)

    def test_symlink_destination_rejected(self):
        link = self.root / "link"
        link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(install.InstallError) as error:
            install.resolve_target({"desktop_user": pwd.getpwuid(os.geteuid()).pw_name, "install_dir": str(link / "watchtower.app")})
        self.assertEqual(error.exception.finding, "target.symlink")

    def test_alternate_admin_fails_before_mutation(self):
        target = self.target()
        with mock.patch.object(install.os, "geteuid", return_value=target["uid"] + 1):
            with self.assertRaises(install.InstallError) as error:
                install.assert_authorized(target, {})
        self.assertEqual(error.exception.finding, "authorization.helper")
        self.assertFalse(target["path"].parent.exists())

    def test_machine_scope_fails_closed_without_protected_helper(self):
        target = self.target()
        with self.assertRaises(install.InstallError) as error:
            install.assert_authorized(target, {"scope": "machine"})
        self.assertEqual(error.exception.finding, "authorization.helper")
        self.assertFalse(target["path"].parent.exists())

    def test_lock_refuses_parallel_transaction(self):
        target = self.target()
        target["path"].parent.mkdir()
        with install.installation_lock(target):
            with self.assertRaises(install.InstallError) as error:
                with install.installation_lock(target):
                    self.fail("second lock accepted")
        self.assertEqual(error.exception.finding, "installation.locked")

    def test_lock_rejects_symlink(self):
        target = self.target()
        target["path"].parent.mkdir()
        (target["path"].parent / ".watchtower.app.cilex-deploy.lock").symlink_to(self.root / "victim")
        with self.assertRaises(OSError):
            with install.installation_lock(target):
                self.fail("symlink lock accepted")
        self.assertFalse((self.root / "victim").exists())

    def test_process_parentage_and_duplicates(self):
        target, manifest = self.target(), self.manifest()
        warden = {"pid": 10, "ppid": 1, "session": 99, "uid": target["uid"], "path": str(target["path"] / "Contents/Resources/warden/cilex-warden"), "birth": [100, 1]}
        app = {"pid": 11, "ppid": 10, "session": 99, "uid": target["uid"], "path": str(target["path"] / "Contents/MacOS/watchtower"), "birth": [101, 1]}
        guardian = dict(warden, pid=12, ppid=10, birth=[100, 2])
        record = {"schema": 1, "installation_id": target["id"], "uid": target["uid"], "owner": warden, "guard": guardian, "processes": [app]}
        with mock.patch.object(runtime, "_private_json", return_value=record):
            with mock.patch.object(runtime, "process_snapshot", return_value=[warden, app, guardian]):
                evidence = install.verify_processes(target, manifest)
                self.assertEqual(evidence["state"], "ProcessVerified")
                self.assertFalse(evidence["duplicates"])
            with mock.patch.object(runtime, "process_snapshot", return_value=[warden, app, guardian, dict(app, pid=13)]):
                self.assertTrue(install.verify_processes(target, manifest)["duplicates"])
            with mock.patch.object(runtime, "process_snapshot", return_value=[warden, guardian, dict(app, ppid=1)]):
                self.assertEqual(install.verify_processes(target, manifest)["state"], "Unverified")
            with mock.patch.object(runtime, "process_snapshot", return_value=[warden, app]):
                self.assertEqual(install.verify_processes(target, manifest)["state"], "Unverified")
            with mock.patch.object(runtime, "process_snapshot", return_value=[warden, app, guardian, dict(warden, pid=14)]):
                self.assertTrue(install.verify_processes(target, manifest)["duplicates"])
            with mock.patch.object(runtime, "process_snapshot", return_value=[dict(warden, birth=[100, 3]), app, guardian]):
                self.assertEqual(install.verify_processes(target, manifest)["state"], "Unverified")

    def test_other_uid_and_path_not_selected(self):
        target = self.target()
        row = {"pid": 10, "uid": target["uid"] + 1, "path": str(target["path"] / "Contents/MacOS/watchtower")}
        with mock.patch.object(install, "process_snapshot", return_value=[row, dict(row, uid=target["uid"], path="/another/watchtower")]):
            self.assertEqual(install.selected_processes(target, self.manifest()), [])

    def test_readonly_verify_without_receipt_creates_nothing(self):
        target = self.target()
        before = sorted(str(p) for p in self.root.rglob("*"))
        with mock.patch.object(install, "resolve_target", return_value=target), mock.patch.object(install, "execute") as execute:
            result = install.verify({})
        self.assertEqual(result["installation"], "UnverifiedNoOwnedReceipt")
        execute.assert_called_once_with(["/usr/bin/fdesetup", "status"], timeout=15, check=False)
        self.assertEqual(before, sorted(str(p) for p in self.root.rglob("*")))

    def test_dry_run_no_creation_or_mutating_commands(self):
        target = self.target()
        before = sorted(str(p) for p in self.root.rglob("*"))
        with mock.patch.object(install, "resolve_target", return_value=target), mock.patch.object(install, "execute") as execute:
            result = install.run({"dry_run": True})
        execute.assert_called_once_with(["/usr/bin/fdesetup", "status"], timeout=15, check=False)
        self.assertFalse(result["full_success"])
        self.assertEqual(before, sorted(str(p) for p in self.root.rglob("*")))

    def test_startup_never_assumed_verified(self):
        result = install.base_result(self.target())
        self.assertEqual(result["startup"], "StartupUnverified")
        self.assertFalse(result["full_success"])
        self.assertEqual(result["gui_video"], "Unverified")

    def test_macos_version_padding(self):
        self.assertEqual(install.version_tuple("14.4"), install.version_tuple("14.4.0"))
        with self.assertRaises(install.InstallError):
            install.version_tuple("invalid")

    def transaction_fixture(self, existing=True):
        from closure import inventory
        target, manifest = self.target(), self.manifest()
        target["path"].parent.mkdir()
        package = self.root / "package"
        incoming = package / "watchtower.app"
        (incoming / "Contents").mkdir(parents=True)
        with (incoming / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": install.BUNDLE_ID}, stream)
        (incoming / "Contents/payload").write_text("new-version")
        manifest["files"] = inventory(package)
        if existing:
            (target["path"] / "Contents").mkdir(parents=True)
            with (target["path"] / "Contents/Info.plist").open("wb") as stream:
                plistlib.dump({"CFBundleIdentifier": install.BUNDLE_ID}, stream)
            (target["path"] / "Contents/payload").write_text("old-version")
            target["agent"].parent.mkdir(parents=True)
            with target["agent"].open("wb") as stream:
                plistlib.dump(install.launchagent(target, manifest, {}), stream)
        return target, manifest, package

    def test_transaction_preserves_disabled_startup_and_user_configuration(self):
        target, manifest, package = self.transaction_fixture()
        prefs = target["home"] / "Library/Preferences/com.cilex-vision.Watchtower.plist"
        prefs.parent.mkdir()
        original = plistlib.dumps({"auth/token": "fixture enrollment", "view": "fixture view"})
        prefs.write_bytes(original)
        state = {"loaded": False, "disabled": True, "disabled_explicit": True, "gui_session": True}
        with mock.patch.object(install, "job_state", return_value=state), mock.patch.object(install, "selected_processes", return_value=[]), mock.patch.object(install, "execute") as execute, mock.patch.object(install, "register_bundle"):
            result = install.transaction(package, manifest, target, {}, {"security_admission": "DevelopmentOnly", "run_id": "fixture-disabled", "package_sha256": "a" * 64})
        execute.assert_not_called()
        self.assertEqual(result["startup"], "PendingDisabledStartup")
        self.assertEqual(result["runtime_health"], "PendingDisabledStartup")
        self.assertEqual(prefs.read_bytes(), original)
        self.assertEqual((target["path"] / "Contents/payload").read_text(), "new-version")
        self.assertFalse(result["full_success"])

    def test_transaction_without_gui_remains_pending(self):
        target, manifest, package = self.transaction_fixture(False)
        state = {"loaded": False, "disabled": False, "disabled_explicit": False, "gui_session": False}
        with mock.patch.object(install, "job_state", return_value=state), mock.patch.object(install, "selected_processes", return_value=[]), mock.patch.object(install, "execute") as execute, mock.patch.object(install, "register_bundle"):
            result = install.transaction(package, manifest, target, {}, {"security_admission": "DevelopmentOnly", "run_id": "fixture-nogui", "package_sha256": "a" * 64})
        execute.assert_not_called()
        self.assertEqual(result["runtime_health"], "PendingGraphicalLogin")
        self.assertEqual(result["startup"], "PendingGraphicalLogin")
        self.assertTrue(target["agent"].exists())

    def test_existing_unloaded_startup_stays_stopped_during_upgrade(self):
        target, manifest, package = self.transaction_fixture()
        before = {"loaded": False, "disabled": False, "disabled_explicit": False, "gui_session": True}
        with mock.patch.object(install, "job_state", return_value=before), mock.patch.object(install, "selected_processes", return_value=[]), mock.patch.object(install, "register_bundle"), mock.patch.object(install, "execute") as execute:
            result = install.transaction(package, manifest, target, {}, {"security_admission": "DevelopmentOnly", "run_id": "fixture-keep-stopped", "package_sha256": "a" * 64})
        execute.assert_not_called()
        self.assertEqual(result["startup"], "PendingStoppedStartup")
        self.assertEqual(result["runtime_health"], "PendingStoppedStartup")
        self.assertEqual((target["path"] / "Contents/payload").read_text(), "new-version")

    def test_loaded_job_without_warden_pid_cannot_be_restarted_by_upgrade(self):
        target, manifest, package = self.transaction_fixture()
        before = {"loaded": True, "pid": None, "disabled": False, "disabled_explicit": False, "gui_session": True}
        with mock.patch.object(install, "job_state", return_value=before), mock.patch.object(install, "execute") as execute, mock.patch.object(install, "register_bundle") as register:
            with self.assertRaises(install.InstallError) as error:
                install.transaction(package, manifest, target, {}, {"security_admission": "DevelopmentOnly", "run_id": "fixture-loaded-stopped"})
        self.assertEqual(error.exception.finding, "startup.loaded_stopped")
        self.assertIn("LaunchAgent", error.exception.ru)
        self.assertEqual((target["path"] / "Contents/payload").read_text(), "old-version")
        self.assertEqual(list(target["path"].parent.glob(".cilex-deploy-*")), [])
        execute.assert_not_called()
        register.assert_not_called()

    def test_observation_does_not_authorize_starting_an_unloaded_job(self):
        target, manifest, package = self.transaction_fixture()
        before = {"loaded": False, "disabled": False, "disabled_explicit": False, "gui_session": True}
        with mock.patch.object(install, "job_state", return_value=before), mock.patch.object(install, "execute") as execute:
            with self.assertRaises(install.InstallError) as error:
                install.transaction(package, manifest, target, {"observe_seconds": 150}, {"security_admission": "DevelopmentOnly", "run_id": "fixture-stopped-observe", "package_sha256": "a" * 64})
        execute.assert_not_called()
        self.assertEqual(error.exception.finding, "startup.stopped")
        self.assertEqual((target["path"] / "Contents/payload").read_text(), "old-version")

    def test_failed_install_restores_files_and_keeps_failure_evidence(self):
        target, manifest, package = self.transaction_fixture()
        target["agent"].unlink()  # First registration for an existing copied app.
        state = {"loaded": False, "disabled": False, "disabled_explicit": False, "gui_session": True}
        with mock.patch.object(install, "job_state", return_value=state), mock.patch.object(install, "selected_processes", return_value=[]), mock.patch.object(install, "register_bundle"), mock.patch.object(install, "execute", side_effect=install.InstallError("fixture.denied", "authorization rejected")):
            result = install.transaction(package, manifest, target, {}, {"security_admission": "DevelopmentOnly", "run_id": "fixture-rollback", "package_sha256": "a" * 64})
        self.assertEqual(result["installation"], "Failed")
        self.assertEqual(result["original_failure"]["finding"], "fixture.denied")
        self.assertEqual(result["rollback"], "FilesAndProcessStateRestored_RuntimeUnverified")
        self.assertEqual((target["path"] / "Contents/payload").read_text(), "old-version")
        self.assertFalse(target["agent"].exists())
        self.assertEqual(result["cleanup"], "FailureEvidenceRetained")
        self.assertTrue(Path(result["evidence"][0]).exists())

    def test_finder_update_stops_job_before_swap_and_keeps_backend_and_settings(self):
        target, manifest, package = self.transaction_fixture()
        url = 'https://fixture-backend.invalid'
        target['agent'].write_bytes(plistlib.dumps(install.launchagent(target, manifest, {'backend_url': url})))
        preferences = target['home'] / 'Library/Preferences/com.cilex-vision.Watchtower.plist'
        preferences.parent.mkdir()
        raw = plistlib.dumps({'auth/token': 'inert fixture credential', 'view': 'fixture'})
        preferences.write_bytes(raw)
        before = {'loaded': True, 'disabled': False, 'disabled_explicit': False,
                  'gui_session': True, 'pid': 101}
        order = []
        def execute(argv, **kw):
            order.append(argv[1])
        def wait(t, m, running):
            order.append('running' if running else 'stopped')
            self.assertEqual((target['path'] / 'Contents/payload').read_text(),
                             'new-version' if running else 'old-version')
            return {'state': 'ProcessVerified', 'processes': []}
        with mock.patch.object(install, 'job_state', return_value=before), \
             mock.patch.object(install, 'assert_job_process'), \
             mock.patch.object(install, 'process_snapshot', return_value=[]), \
             mock.patch.object(install, 'execute', side_effect=execute), \
             mock.patch.object(install, 'wait_processes', side_effect=wait), \
             mock.patch.object(install, 'register_bundle'):
            result = install.transaction(package, manifest, target,
                {'_finder_update': True, 'backend_url': url},
                {'security_admission': 'DevelopmentOnly', 'run_id': 'fixture-finder-update'})
        self.assertEqual(result['installation'], 'Installed')
        self.assertEqual(order, ['bootout', 'stopped', 'bootstrap', 'running'])
        self.assertEqual(preferences.read_bytes(), raw)
        self.assertIn('WT_WARDEN_BACKEND_URL=' + url,
                      plistlib.loads(target['agent'].read_bytes())['ProgramArguments'])

    def test_finder_update_start_failure_restores_running_old_copy(self):
        target, manifest, package = self.transaction_fixture()
        raw_agent = target['agent'].read_bytes()
        before = {'loaded': True, 'disabled': False, 'disabled_explicit': False,
                  'gui_session': True, 'pid': 101}
        starts = []
        def wait(t, m, running):
            if running:
                starts.append((target['path'] / 'Contents/payload').read_text())
                if starts == ['new-version']:
                    raise install.InstallError('fixture.startup', 'replacement did not start')
            return {'state': 'ProcessVerified', 'processes': []}
        with mock.patch.object(install, 'job_state', return_value=before), \
             mock.patch.object(install, 'assert_job_process'), \
             mock.patch.object(install, 'process_snapshot', return_value=[]), \
             mock.patch.object(install, 'selected_processes', return_value=[{'pid': 100}]), \
             mock.patch.object(install, 'execute') as execute, \
             mock.patch.object(install, 'wait_processes', side_effect=wait), \
             mock.patch.object(install, 'register_bundle'):
            result = install.transaction(package, manifest, target, {'_finder_update': True},
                {'security_admission': 'DevelopmentOnly', 'run_id': 'fixture-finder-rollback'})
        self.assertEqual(result['installation'], 'Failed')
        self.assertEqual(result['original_failure']['finding'], 'fixture.startup')
        self.assertEqual(result['rollback'], 'FilesAndProcessStateRestored_RuntimeUnverified')
        self.assertEqual(starts, ['new-version', 'old-version'])
        self.assertEqual(target['agent'].read_bytes(), raw_agent)
        self.assertEqual([call.args[0][1] for call in execute.call_args_list],
                         ['bootout', 'bootstrap', 'bootout', 'bootstrap'])

    def test_finder_update_recheck_failure_never_stops_unchanged_service(self):
        target, manifest, package = self.transaction_fixture()
        before = {'loaded': True, 'disabled': False, 'disabled_explicit': False,
                  'gui_session': True, 'pid': 101}
        with mock.patch.object(install, 'assert_authorized', side_effect=[None,
                install.InstallError('update.other_user', 'another account started')]), \
             mock.patch.object(install, 'job_state', return_value=before), \
             mock.patch.object(install, 'assert_job_process'), \
             mock.patch.object(install, 'selected_processes', return_value=[]), \
             mock.patch.object(install, 'execute') as execute:
            with self.assertRaises(install.InstallError):
                install.transaction(package, manifest, target, {'_finder_update': True},
                    {'security_admission': 'DevelopmentOnly', 'run_id': 'fixture-finder-recheck'})
        execute.assert_not_called()
        self.assertEqual((target['path'] / 'Contents/payload').read_text(), 'old-version')

    def test_rollback_failure_does_not_hide_original_error(self):
        target, manifest, package = self.transaction_fixture()
        target["agent"].unlink()  # First registration, not an intentionally unloaded job.
        before = {"loaded": False, "disabled": False, "disabled_explicit": False, "gui_session": True}
        after = dict(before, loaded=True)
        with mock.patch.object(install, "job_state", side_effect=[before, after]), mock.patch.object(install, "selected_processes", return_value=[]), mock.patch.object(install, "register_bundle"), mock.patch.object(install, "execute", side_effect=[install.InstallError("fixture.start", "start failed"), install.InstallError("fixture.rollback", "stop failed")]):
            result = install.transaction(package, manifest, target, {}, {"security_admission": "DevelopmentOnly", "run_id": "fixture-dualfail", "package_sha256": "a" * 64})
        self.assertEqual(result["original_failure"]["finding"], "fixture.start")
        self.assertEqual(result["rollback_failure"]["finding"], "fixture.rollback")
        self.assertEqual(result["rollback"], "Failed")

    def test_transaction_refuses_unmanaged_app_without_stopping_anything(self):
        target, manifest, package = self.transaction_fixture()
        state = {"loaded": False, "disabled": False, "disabled_explicit": False, "gui_session": True}
        with mock.patch.object(install, "job_state", return_value=state), mock.patch.object(install, "selected_processes", return_value=[{"pid": 99}]), mock.patch.object(install, "execute") as execute:
            with self.assertRaises(install.InstallError) as error:
                install.transaction(package, manifest, target, {}, {"security_admission": "DevelopmentOnly"})
        execute.assert_not_called()
        self.assertEqual(error.exception.finding, "runtime.unmanaged")
        self.assertEqual((target["path"] / "Contents/payload").read_text(), "old-version")

    def test_staged_corruption_rejected_before_stop(self):
        target, manifest, package = self.transaction_fixture()
        (package / "watchtower.app/Contents/payload").write_text("bad-version")
        state = {"loaded": True, "pid": 123, "disabled": False, "disabled_explicit": False, "gui_session": True}
        with mock.patch.object(install, "job_state", return_value=state), mock.patch.object(install, "assert_job_process"), mock.patch.object(install, "selected_processes", return_value=[]), mock.patch.object(install, "execute") as execute:
            with self.assertRaises(install.InstallError) as error:
                install.transaction(package, manifest, target, {}, {"security_admission": "DevelopmentOnly"})
        execute.assert_not_called()
        self.assertEqual(error.exception.finding, "package.hash")
        self.assertEqual((target["path"] / "Contents/payload").read_text(), "old-version")

    @unittest.skipUnless(sys.platform == "darwin", "Native Darwin statfs64")
    def test_native_local_filesystem_capability_assessment(self):
        value = install.require_filesystem(self.root)
        self.assertIn(value["type"], ("apfs", "hfs"))
        self.assertTrue(value["local"])
        self.assertFalse(value["ownership_ignored"])
        self.assertGreater(value["available_bytes"], 0)

    def test_unsupported_and_unsafe_filesystems_not_overridable(self):
        safe = {"type": "apfs", "local": True, "read_only": False, "no_exec": False, "ownership_ignored": False, "journaled": True}
        for change in ({"type": "smbfs"}, {"local": False}, {"read_only": True}, {"no_exec": True}, {"ownership_ignored": True}, {"type": "hfs", "journaled": False}):
            with self.subTest(change=change), mock.patch.object(install, "inspect_filesystem", return_value=dict(safe, **change)), self.assertRaises(install.InstallError):
                install.require_filesystem(self.root)
        with mock.patch.object(install, "inspect_filesystem", return_value=dict(safe, type="hfs")):
            self.assertEqual(install.require_filesystem(self.root)["type"], "hfs")

    def resume_fixture(self, disabled=False):
        target, manifest, package = self.transaction_fixture()
        job = {"loaded": False, "disabled": disabled, "disabled_explicit": disabled, "gui_session": False}
        context = {"security_admission": "DevelopmentOnly", "run_id": "fixture-resuming", "package_sha256": "a" * 64}
        with mock.patch.object(install, "job_state", return_value=job), mock.patch.object(install, "selected_processes", return_value=[]), mock.patch.object(install, "register_bundle"):
            first = install.transaction(package, manifest, target, {}, context)
        self.assertEqual(first["installation"], "Installed")
        record = target["support"] / (context["run_id"] + ".json")
        state = json.loads(record.read_text())
        state["phase"] = "replaced"
        state["before"]["gui_session"] = True
        install.atomic_json(record, state)
        (target["support"] / "receipt.json").unlink()
        job["gui_session"] = True
        return target, manifest, package, context, record, state, job

    def test_resume_finishes_proven_disabled_replacement_without_starting(self):
        target, manifest, package, context, record, state, job = self.resume_fixture(True)
        with mock.patch.object(install, "job_state", return_value=job), mock.patch.object(install, "verify_processes", return_value={"state": "Unverified", "processes": []}), mock.patch.object(install, "execute") as execute:
            result = install.transaction(package, manifest, target, {"resume": "fixture-resuming"}, context)
        execute.assert_not_called()
        self.assertEqual(result["resumed"], "FinishedObservedReplacement")
        self.assertEqual(result["startup"], "PendingDisabledStartup")
        self.assertTrue((target["support"] / "receipt.json").exists())
        self.assertFalse(result["full_success"])

    def test_resume_failed_startup_restores_verified_backup_and_original_job(self):
        target, manifest, package, context, record, state, job = self.resume_fixture()
        state["original_failure"] = {"finding": "installation.interrupted", "message": "Fixture failed before completion"}
        install.atomic_json(record, state)
        with mock.patch.object(install, "job_state", return_value=job), mock.patch.object(install, "verify_processes", return_value={"state": "Unverified", "processes": []}), mock.patch.object(install, "selected_processes", return_value=[]), mock.patch.object(install, "register_bundle"), mock.patch.object(install, "execute") as execute:
            result = install.transaction(package, manifest, target, {"resume": "fixture-resuming"}, context)
        execute.assert_not_called()
        self.assertEqual(result["installation"], "Failed")
        self.assertEqual(result["original_failure"]["finding"], "installation.interrupted")
        self.assertEqual(result["rollback"], "FilesAndProcessStateRestored_RuntimeUnverified")
        self.assertEqual((target["path"] / "Contents/payload").read_text(), "old-version")
        self.assertEqual(install.sha256(target["agent"]), state["rollback_files"]["previous-agent.plist"])
        self.assertFalse((target["support"] / "receipt.json").exists())

    def test_resume_preserves_original_loaded_job_without_warden_pid(self):
        target, manifest, package, context, record, state, job = self.resume_fixture()
        state["before"].update(loaded=True, pid=None)
        install.atomic_json(record, state)
        with mock.patch.object(install, "execute") as execute, mock.patch.object(install, "job_state") as inspect:
            result = install.transaction(package, manifest, target, {"resume": context["run_id"]}, context)
        self.assertEqual(result["installation"], "Unknown")
        self.assertEqual((target["path"] / "Contents/payload").read_text(), "new-version")
        execute.assert_not_called()
        inspect.assert_not_called()

    def test_resume_changed_options_rejected_without_stopping(self):
        target, manifest, package, context, record, state, job = self.resume_fixture()
        with mock.patch.object(install, "execute") as execute:
            with self.assertRaises(install.InstallError) as error:
                install.transaction(package, manifest, target, {"resume": "fixture-resuming", "backend_url": "https://different.example"}, context)
        execute.assert_not_called()
        self.assertEqual(error.exception.finding, "resume.binding")

    def test_resume_corrupt_backup_rejected_before_process_operations(self):
        target, manifest, package, context, record, state, job = self.resume_fixture()
        (Path(state["staging"]) / "previous.app/Contents/payload").write_text("corrupt-old")
        with mock.patch.object(install, "job_state", return_value=job), mock.patch.object(install, "execute") as execute:
            with self.assertRaises(install.InstallError) as error:
                install.transaction(package, manifest, target, {"resume": "fixture-resuming"}, context)
        execute.assert_not_called()
        self.assertEqual(error.exception.finding, "resume.backup_hash")

    def test_resume_missing_backup_reports_unknown_without_mutation(self):
        target, manifest, package, context, record, state, job = self.resume_fixture()
        state["original_failure"] = {"finding": "installation.interrupted", "message": "Fixture failed before completion"}
        install.atomic_json(record, state)
        backup = Path(state["staging"]) / "previous.app"
        backup.rename(Path(state["staging"]) / "moved-by-operator.app")
        with mock.patch.object(install, "job_state", return_value=job), mock.patch.object(install, "verify_processes", return_value={"state": "Unverified", "processes": []}), mock.patch.object(install, "execute") as execute:
            result = install.transaction(package, manifest, target, {"resume": "fixture-resuming"}, context)
        execute.assert_not_called()
        self.assertEqual(result["installation"], "Unknown")
        self.assertEqual((target["path"] / "Contents/payload").read_text(), "new-version")

    def test_resume_preserves_later_operator_disable(self):
        target, manifest, package, context, record, state, job = self.resume_fixture()
        job.update(disabled=True, disabled_explicit=True)
        with mock.patch.object(install, "job_state", return_value=job), mock.patch.object(install, "execute") as execute:
            result = install.transaction(package, manifest, target, {"resume": "fixture-resuming"}, context)
        execute.assert_not_called()
        self.assertEqual(result["installation"], "Unknown")
        self.assertIn("operator", result["reason"])

    def test_resume_does_not_overwrite_a_newer_transaction_receipt(self):
        target, manifest, package, context, record, state, job = self.resume_fixture(True)
        receipt = install.installation_receipt(target, manifest, {}, context)
        receipt["run_id"] = "another-completed-run"
        install.atomic_json(target["support"] / "receipt.json", receipt)
        with mock.patch.object(install, "job_state", return_value=job), mock.patch.object(install, "execute") as execute:
            result = install.transaction(package, manifest, target, {"resume": "fixture-resuming"}, context)
        execute.assert_not_called()
        self.assertEqual(result["installation"], "Unknown")
        self.assertEqual(json.loads((target["support"] / "receipt.json").read_text())["run_id"], "another-completed-run")

    def test_resume_before_stop_can_continue_with_retained_prior_record(self):
        target, manifest, package, context, record, state, job = self.resume_fixture(True)
        staging = Path(state["staging"])
        target["path"].rename(staging / "replacement.app")
        (staging / "previous.app").rename(target["path"])
        target["agent"].write_bytes((staging / "previous-agent.plist").read_bytes())
        state["phase"] = "staged"
        install.atomic_json(record, state)
        with mock.patch.object(install, "job_state", return_value=job), mock.patch.object(install, "selected_processes", return_value=[]), mock.patch.object(install, "register_bundle"), mock.patch.object(install, "execute") as execute:
            result = install.transaction(package, manifest, target, {"resume": "fixture-resuming"}, context)
        execute.assert_not_called()
        self.assertEqual(result["installation"], "Installed")
        self.assertTrue((staging / "interrupted-before-stop.json").is_file())
        self.assertEqual(len(json.loads(record.read_text())["resumed_evidence"]), 1)

    def test_completed_resume_only_observes_and_does_not_restart(self):
        target, manifest, package, context, record, state, job = self.resume_fixture(True)
        receipt = install.installation_receipt(target, manifest, {}, context)
        install.atomic_json(target["support"] / "receipt.json", receipt)
        state["phase"] = "installed"
        install.atomic_json(record, state)
        with mock.patch.object(install, "job_state", return_value=job), mock.patch.object(install, "verify_processes", return_value={"state": "Unverified", "processes": []}), mock.patch.object(install, "execute") as execute:
            result = install.transaction(package, manifest, target, {"resume": "fixture-resuming"}, context)
        execute.assert_not_called()
        self.assertEqual(result["resumed"], "ObservedCompletedInstallation")
        self.assertFalse(result["full_success"])

    def test_resume_rollback_failure_keeps_original_interruption(self):
        target, manifest, package, context, record, state, job = self.resume_fixture()
        state["before"]["loaded"] = True
        state["before"]["pid"] = 123
        state["previous_processes"] = [{"pid": 123}]
        install.atomic_json(record, state)
        with mock.patch.object(install, "job_state", return_value=job), mock.patch.object(install, "verify_processes", return_value={"state": "Unverified", "processes": []}), mock.patch.object(install, "selected_processes", return_value=[]), mock.patch.object(install, "register_bundle"), mock.patch.object(install, "execute", side_effect=install.InstallError("fixture.rollback_denied", "bootstrap denied")):
            result = install.transaction(package, manifest, target, {"resume": "fixture-resuming"}, context)
        self.assertEqual(result["original_failure"]["finding"], "installation.interrupted")
        self.assertEqual(result["rollback_failure"]["finding"], "fixture.rollback_denied")
        self.assertEqual(result["rollback"], "Failed")

    def test_loaded_job_pid_reuse_or_foreign_path_prevents_stop(self):
        target, manifest = self.target(), self.manifest()
        row = {"pid": 123, "uid": target["uid"], "path": "/another/application", "ppid": 1}
        with mock.patch.object(install, "process_snapshot", return_value=[row]), mock.patch.object(install, "execute") as execute:
            with self.assertRaises(install.InstallError) as error:
                install.assert_job_process(target, manifest, {"pid": 123})
        execute.assert_not_called()
        self.assertEqual(error.exception.finding, "runtime.job_identity")

    def configuration_fixture(self):
        target = self.target()
        staging = self.root / "configuration backup"
        staging.mkdir(mode=0o700)
        prefs, other, warden, data = install.configuration_paths(target)
        prefs.parent.mkdir(parents=True)
        prefs.write_bytes(plistlib.dumps({"auth/token": "fixture-only", "theme": "existing"}))
        prefs.chmod(0o644)
        warden.parent.mkdir(parents=True)
        warden.write_text("STATION_TOKEN=fixture-only\n")
        warden.chmod(0o600)
        return target, staging, prefs, warden

    def test_configuration_snapshot_restores_bytes_permissions_and_native_cache(self):
        target, staging, prefs, warden = self.configuration_fixture()
        prior_prefs, prior_warden = prefs.read_bytes(), warden.read_bytes()
        snapshots = install.snapshot_configuration(target, staging)
        prefs.write_bytes(plistlib.dumps({"theme": "new", "new_key": 1}))
        prefs.chmod(0o600)
        warden.write_text("STATION_TOKEN=replaced-fixture\n")
        install.restore_configuration(target, staging, snapshots)
        self.assertEqual(prefs.read_bytes(), prior_prefs)
        self.assertEqual(warden.read_bytes(), prior_warden)
        self.assertEqual(prefs.stat().st_mode & 0o777, 0o644)
        self.assertEqual(warden.stat().st_mode & 0o777, 0o600)
        self.preference_cache.assert_any_call(prefs.stem, plistlib.loads(prior_prefs))
        for item in snapshots:
            if item["existed"]:
                self.assertEqual((staging / item["backup"]).stat().st_mode & 0o777, 0o600)
        self.assertNotIn("fixture-only", json.dumps(snapshots))

    def test_configuration_new_file_removed_but_guard_hold_untouched(self):
        target, staging, prefs, warden = self.configuration_fixture()
        snapshots = install.snapshot_configuration(target, staging)
        new_config = install.configuration_paths(target)[-1]
        new_config.parent.mkdir(parents=True)
        new_config.write_text("STATION_TOKEN=new-fixture\n")
        hold = new_config.parent / "operator-hold.json"
        hold.write_text('{"paused":true}')
        install.restore_configuration(target, staging, snapshots)
        self.assertFalse(new_config.exists())
        self.assertEqual(hold.read_text(), '{"paused":true}')

    def test_configuration_corrupt_backup_changes_no_destination(self):
        target, staging, prefs, warden = self.configuration_fixture()
        snapshots = install.snapshot_configuration(target, staging)
        prefs.write_bytes(plistlib.dumps({"theme": "new"}))
        before = prefs.read_bytes()
        (staging / snapshots[2]["backup"]).write_bytes(b"corrupt")
        with self.assertRaises(install.InstallError) as error:
            install.restore_configuration(target, staging, snapshots)
        self.assertEqual(error.exception.finding, "configuration.hash")
        self.assertEqual(prefs.read_bytes(), before)

    def test_configuration_symlink_cannot_redirect_restore(self):
        target, staging, prefs, warden = self.configuration_fixture()
        snapshots = install.snapshot_configuration(target, staging)
        victim = self.root / "unrelated"
        victim.write_text("unrelated")
        warden.unlink()
        warden.symlink_to(victim)
        with self.assertRaises(install.InstallError) as error:
            install.restore_configuration(target, staging, snapshots)
        self.assertEqual(error.exception.finding, "configuration.symlink")
        self.assertEqual(victim.read_text(), "unrelated")

    def test_failed_application_restores_configuration_before_prior_startup(self):
        target, manifest, package = self.transaction_fixture()
        target["agent"].unlink()  # First registration, not an intentionally unloaded job.
        prefs = install.configuration_paths(target)[0]
        prefs.parent.mkdir(parents=True)
        old = plistlib.dumps({"auth/token": "fixture-old"})
        prefs.write_bytes(old)
        state = {"loaded": False, "disabled": False, "disabled_explicit": False, "gui_session": True}

        def failed_start(*args, **kwargs):
            prefs.write_bytes(plistlib.dumps({"auth/token": "fixture-new", "new": True}))
            raise install.InstallError("fixture.start", "fixture application changed settings then failed")

        with mock.patch.object(install, "job_state", return_value=state), mock.patch.object(install, "selected_processes", return_value=[]), mock.patch.object(install, "register_bundle"), mock.patch.object(install, "execute", side_effect=failed_start):
            result = install.transaction(package, manifest, target, {}, {"security_admission": "DevelopmentOnly", "run_id": "fixture-config-rollback", "package_sha256": "a" * 64})
        self.assertEqual(result["rollback"], "FilesAndProcessStateRestored_RuntimeUnverified")
        self.assertEqual(prefs.read_bytes(), old)
        self.assertNotIn("fixture-old", json.dumps(result))
        self.assertNotIn("fixture-new", json.dumps(result))

    def test_atomic_configuration_write_keeps_previous_file_on_rename_failure(self):
        path = self.root / "settings"
        path.write_bytes(b"previous")
        with mock.patch.object(install.os, "replace", side_effect=OSError("fixture rename failure")), self.assertRaises(OSError):
            install.atomic_bytes(path, b"replacement")
        self.assertEqual(path.read_bytes(), b"previous")
        self.assertFalse(list(self.root.glob(".write-*")))

    def test_recovery_space_includes_exact_configuration_restore_bytes(self):
        target, staging, prefs, warden = self.configuration_fixture()
        snapshots = install.snapshot_configuration(target, staging)
        total = prefs.stat().st_size + warden.stat().st_size
        state = {"configuration": snapshots, "rollback_files": {}}
        with mock.patch.object(install.shutil, "disk_usage", return_value=types.SimpleNamespace(free=64 * 1024**2 + total - 1)):
            with self.assertRaises(install.InstallError) as error:
                install.require_recovery_space(target, staging, state)
        self.assertEqual(error.exception.finding, "space.recovery")
        with mock.patch.object(install.shutil, "disk_usage", return_value=types.SimpleNamespace(free=64 * 1024**2 + total)):
            budget = install.require_recovery_space(target, staging, state)
        self.assertEqual(sum(item["required_bytes"] for item in budget), 64 * 1024**2 + total)

    def test_explicit_video_observation_precedes_install_commit(self):
        target, manifest, package = self.transaction_fixture()
        target["agent"].unlink()  # First registration, not an intentionally unloaded job.
        state = {"loaded": False, "disabled": False, "disabled_explicit": False, "gui_session": True}
        observed = {"runtime_health": "ProcessVerified", "gui_video": "VisibleAndPerSourceVideoObserved", "evidence": [], "observed_seconds": 150}

        def observe(options, context):
            self.assertEqual(options["observe_seconds"], 150)
            self.assertEqual(context["manifest"], manifest)
            self.assertEqual(context["target"], target)
            self.assertTrue(context["write_evidence"])
            self.assertFalse((target["support"] / "receipt.json").exists())
            self.assertEqual((target["path"] / "Contents/payload").read_text(), "new-version")
            self.assertEqual(json.loads((target["support"] / "fixture-observe-ok.json").read_text())["phase"], "observing")
            return observed

        with mock.patch.object(install, "job_state", return_value=state), mock.patch.object(install, "selected_processes", return_value=[]), mock.patch.object(install, "register_bundle"), mock.patch.object(install, "execute"), mock.patch.object(install, "wait_processes", return_value={"state": "ProcessVerified"}), mock.patch.object(runtime, "verify", side_effect=observe) as verifier:
            result = install.transaction(package, manifest, target, {"observe_seconds": 150}, {"security_admission": "DevelopmentOnly", "run_id": "fixture-observe-ok", "package_sha256": "a" * 64})
        verifier.assert_called_once()
        self.assertEqual(result["installation"], "Installed")
        self.assertEqual(result["runtime_observation"], observed)
        self.assertEqual(result["gui_video"], "VisibleAndPerSourceVideoObserved")
        self.assertFalse(result["full_success"])
        self.assertTrue((target["support"] / "receipt.json").exists())

    def test_explicit_failed_or_incomplete_video_rolls_back(self):
        for video in ("Failed", "Unverified", "UnverifiedVisibility", "VisibleAndAggregateVideoObserved"):
            with self.subTest(video=video):
                separate = self.root / video
                separate.mkdir()
                original_root = self.root
                self.root = separate
                try:
                    target, manifest, package = self.transaction_fixture()
                    target["agent"].unlink()  # First registration permits startup.
                    state = {"loaded": False, "disabled": False, "disabled_explicit": False, "gui_session": True}
                    observed = {"runtime_health": "ProcessVerified", "gui_video": video, "evidence": [], "observed_seconds": 150, "findings": [{"id": "FIXTURE_VIDEO_FAILURE"}]}
                    with mock.patch.object(install, "job_state", return_value=state), mock.patch.object(install, "selected_processes", return_value=[]), mock.patch.object(install, "register_bundle"), mock.patch.object(install, "execute"), mock.patch.object(install, "wait_processes", return_value={"state": "ProcessVerified"}), mock.patch.object(runtime, "verify", return_value=observed):
                        result = install.transaction(package, manifest, target, {"observe_seconds": 150}, {"security_admission": "DevelopmentOnly", "run_id": "fixture-observe-failure", "package_sha256": "a" * 64})
                    self.assertEqual(result["installation"], "Failed")
                    self.assertEqual(result["rollback"], "FilesAndProcessStateRestored_RuntimeUnverified")
                    self.assertEqual(result["original_failure"]["finding"], "runtime.observation")
                    self.assertEqual(result["runtime_observation"], observed)
                    self.assertEqual((target["path"] / "Contents/payload").read_text(), "old-version")
                    self.assertFalse((target["support"] / "receipt.json").exists())
                finally:
                    self.root = original_root

    def test_resume_cannot_skip_bound_requested_video_observation(self):
        target, manifest, package, context, record, state, job = self.resume_fixture(True)
        options = {"resume": "fixture-resuming", "observe_seconds": 150}
        state["options_sha256"] = install.digest(install.requested_transaction(options))
        state["phase"] = "observing"
        install.atomic_json(record, state)
        observed = {"runtime_health": "Unverified", "gui_video": "Unverified", "evidence": [], "observed_seconds": 0}
        with mock.patch.object(install, "job_state", return_value=job), mock.patch.object(install, "verify_processes", return_value={"state": "Unverified", "processes": []}), mock.patch.object(install, "selected_processes", return_value=[]), mock.patch.object(install, "register_bundle"), mock.patch.object(install, "execute") as execute, mock.patch.object(runtime, "verify", return_value=observed) as verifier:
            result = install.transaction(package, manifest, target, options, context)
        execute.assert_not_called()
        verifier.assert_called_once()
        self.assertEqual(result["installation"], "Failed")
        self.assertEqual(result["original_failure"]["finding"], "runtime.observation")
        self.assertEqual(result["runtime_observation"], observed)
        self.assertEqual((target["path"] / "Contents/payload").read_text(), "old-version")

    def test_new_run_cannot_bypass_an_incomplete_prior_transaction(self):
        target, manifest, package, context, record, state, job = self.resume_fixture()
        for phase in ("staged", "stopping", "replaced", "observing", "rollback_requested", "resume_rollback_requested", "rollback_failed", "unknown-phase"):
            with self.subTest(phase=phase):
                state["phase"] = phase
                state["original_failure"] = {"finding": "fixture.original", "message": "prior failure evidence"}
                install.atomic_json(record, state)
                before = record.read_bytes()
                new_context = dict(context, run_id="fixture-new-attempt")
                with mock.patch.object(install, "execute") as execute, mock.patch.object(install, "job_state") as jobs:
                    with self.assertRaises(install.InstallError) as error:
                        install.transaction(package, manifest, target, {}, new_context)
                self.assertEqual(error.exception.finding, "run.previous_incomplete")
                self.assertIn(context["run_id"], error.exception.message)
                execute.assert_not_called()
                jobs.assert_not_called()
                self.assertEqual(record.read_bytes(), before)
                self.assertFalse((target["support"] / "fixture-new-attempt.json").exists())

    def test_completed_prior_transactions_allow_normal_upgrade(self):
        target, manifest, package, context, record, state, job = self.resume_fixture(True)
        state["phase"] = "installed"
        install.atomic_json(record, state)
        receipt = install.installation_receipt(target, manifest, {}, context)
        install.atomic_json(target["support"] / "receipt.json", receipt)
        older = dict(state, run_id="fixture-older-rollback", phase="rolled_back_runtime_unverified")
        install.atomic_json(target["support"] / "fixture-older-rollback.json", older)
        with mock.patch.object(install, "job_state", return_value=job), mock.patch.object(install, "selected_processes", return_value=[]), mock.patch.object(install, "register_bundle"), mock.patch.object(install, "execute") as execute:
            result = install.transaction(package, manifest, target, {}, dict(context, run_id="fixture-normal-upgrade"))
        execute.assert_not_called()
        self.assertEqual(result["installation"], "Installed")
        self.assertEqual(json.loads(record.read_text())["run_id"], "fixture-resuming")

    def test_incomplete_other_installation_directory_is_not_a_global_block(self):
        target, manifest, package, context, record, state, job = self.resume_fixture(True)
        state["phase"] = "installed"
        install.atomic_json(record, state)
        unrelated = target["support"].parent / "different-installation"
        unrelated.mkdir(mode=0o700)
        install.atomic_json(unrelated / "incomplete.json", {"phase": "rollback_failed"})
        install.reject_other_incomplete_transactions(target, "fixture-future-run")

    def test_corrupt_prior_record_prevents_new_transaction(self):
        target, manifest, package, context, record, state, job = self.resume_fixture()
        record.write_text("not-json")
        with self.assertRaises(install.InstallError) as error:
            install.reject_other_incomplete_transactions(target, "fixture-new-run")
        self.assertEqual(error.exception.finding, "run.history_integrity")

    def test_uninstall_refuses_incomplete_history_without_stopping_or_removing(self):
        target, manifest, package, context, record, state, job = self.resume_fixture(True)
        install.atomic_json(target["support"] / "receipt.json", install.installation_receipt(target, manifest, {}, context))
        before = record.read_bytes()
        with mock.patch.object(install, "resolve_target", return_value=target), mock.patch.object(install, "verify", return_value={"installation": "FilesVerified"}), mock.patch.object(install, "job_state") as jobs, mock.patch.object(install, "execute") as execute:
            with self.assertRaises(install.InstallError) as error:
                install.uninstall({})
        self.assertEqual(error.exception.finding, "run.previous_incomplete")
        execute.assert_not_called()
        jobs.assert_not_called()
        self.assertEqual(record.read_bytes(), before)
        self.assertEqual((target["path"] / "Contents/payload").read_text(), "new-version")
        self.assertTrue(target["agent"].exists())
        self.assertFalse((target["support"] / "uninstall-result.json").exists())

    def test_uninstall_completed_history_removes_only_owned_components(self):
        target, manifest, package, context, record, state, job = self.resume_fixture(True)
        state["phase"] = "installed"
        install.atomic_json(record, state)
        install.atomic_json(target["support"] / "receipt.json", install.installation_receipt(target, manifest, {}, context))
        data = target["home"] / "Library/Application Support/Cilex Vision/Watchtower"
        data.mkdir(parents=True)
        hold = data / "operator-hold.json"
        hold.write_text('{"paused":true}')
        with mock.patch.object(install, "resolve_target", return_value=target), mock.patch.object(install, "verify", return_value={"installation": "FilesVerified"}), mock.patch.object(install, "job_state", return_value=job), mock.patch.object(install, "selected_processes", return_value=[]), mock.patch.object(install, "execute") as execute:
            result = install.uninstall({})
        execute.assert_not_called()
        self.assertEqual(result["installation"], "Uninstalled")
        self.assertFalse(target["path"].exists())
        self.assertFalse(target["agent"].exists())
        self.assertEqual(hold.read_text(), '{"paused":true}')
        self.assertTrue(record.exists())

    def uninstall_fixture(self):
        target, manifest, package, context, record, state, job = self.resume_fixture(True)
        state["phase"] = "installed"
        install.atomic_json(record, state)
        install.atomic_json(target["support"] / "receipt.json", install.installation_receipt(target, manifest, {}, context))
        for name, value in (("resolve_target", target), ("job_state", job), ("selected_processes", [])):
            mock.patch.object(install, name, return_value=value).start()
        execute = mock.patch.object(install, "execute").start()
        return target, manifest, {"run_id": "fixture-uninstall"}, execute

    def test_uninstall_interrupt_after_rename_resumes_from_protected_backup(self):
        target, manifest, context, execute = self.uninstall_fixture()
        hold = target["home"] / "unrelated-pause.json"
        hold.write_text('{"paused":true}')
        with mock.patch.object(install, "sync_directory", side_effect=OSError("fixture interrupted fsync")):
            first = install.uninstall({}, context)
        self.assertEqual(first["installation"], "Unknown")
        self.assertFalse(target["path"].exists())
        self.assertTrue(target["agent"].exists())
        result = install.uninstall({"resume": context["run_id"]}, context)
        self.assertEqual(result["installation"], "Uninstalled")
        self.assertEqual(result["resumed"], "FinishedObservedUninstall")
        self.assertEqual(len(result["previous_failures"]), 1)
        self.assertEqual(Path(result["backup_path"]).joinpath("Contents/payload").read_text(), "new-version")
        self.assertEqual(hold.read_text(), '{"paused":true}')
        self.assertFalse((target["support"] / "receipt.json").exists())
        self.assertFalse(target["agent"].exists())
        execute.assert_not_called()

    def test_interrupted_uninstall_blocks_new_install_or_uninstall_run(self):
        target, manifest, context, execute = self.uninstall_fixture()
        with mock.patch.object(install, "sync_directory", side_effect=OSError("fixture interrupted")):
            self.assertEqual(install.uninstall({}, context)["installation"], "Unknown")
        with self.assertRaises(install.InstallError) as error:
            install.uninstall({}, {"run_id": "fixture-another-run"})
        self.assertEqual(error.exception.finding, "run.previous_incomplete")
        execute.assert_not_called()

    def test_uninstall_final_record_failure_remains_in_completed_resume_evidence(self):
        target, manifest, context, execute = self.uninstall_fixture()
        original = install.atomic_json
        interrupted = []
        def write(path, value):
            if value.get("phase") == "uninstalled" and not interrupted:
                interrupted.append(True)
                raise OSError("fixture final journal interruption")
            return original(path, value)
        with mock.patch.object(install, "atomic_json", side_effect=write):
            first = install.uninstall({}, context)
        self.assertEqual(first["installation"], "Unknown")
        result = install.uninstall({"resume": context["run_id"]}, context)
        self.assertEqual(result["resumed"], "ObservedCompletedUninstall")
        self.assertEqual(len(result["previous_failures"]), 1)
        self.assertIn("final journal interruption", result["previous_failures"][0]["message"])
        execute.assert_not_called()

    def test_uninstall_resume_corrupt_backup_keeps_all_remaining_files(self):
        target, manifest, context, execute = self.uninstall_fixture()
        with mock.patch.object(install, "sync_directory", side_effect=OSError("fixture interrupted")):
            install.uninstall({}, context)
        record = target["support"] / (context["run_id"] + ".json")
        state = json.loads(record.read_text())
        Path(state["staging"]).joinpath("application.backup/Contents/payload").write_text("tampered")
        result = install.uninstall({"resume": context["run_id"]}, context)
        self.assertEqual(result["installation"], "Unknown")
        self.assertTrue(target["agent"].exists())
        self.assertTrue((target["support"] / "receipt.json").exists())
        execute.assert_not_called()

    def test_uninstall_completed_resume_only_observes_and_preserves_later_reinstall(self):
        import shutil
        target, manifest, context, execute = self.uninstall_fixture()
        result = install.uninstall({}, context)
        with mock.patch.object(install, "atomic_json") as write, mock.patch.object(install, "sync_directory") as sync:
            observed = install.uninstall({"resume": context["run_id"]}, context)
            self.assertEqual(observed["resumed"], "ObservedCompletedUninstall")
            write.assert_not_called()
            sync.assert_not_called()
        shutil.copytree(result["backup_path"], target["path"])
        observed = install.uninstall({"resume": context["run_id"]}, context)
        self.assertEqual(observed["installation"], "Unknown")
        self.assertTrue(target["path"].exists())
        execute.assert_not_called()

    def test_uninstall_resume_rejects_changed_target_options_and_policy(self):
        target, manifest, context, execute = self.uninstall_fixture()
        with mock.patch.object(install, "sync_directory", side_effect=OSError("fixture interrupted")):
            install.uninstall({}, context)
        record = target["support"] / (context["run_id"] + ".json")
        state = json.loads(record.read_text())
        state["options_sha256"] = "wrong"
        install.atomic_json(record, state)
        with self.assertRaises(install.InstallError) as error:
            install.uninstall({"resume": context["run_id"]}, context)
        self.assertEqual(error.exception.finding, "resume.binding")
        state["options_sha256"] = install.digest(install.uninstall_options({}))
        install.atomic_json(record, state)
        policy = dict(state["before"], disabled=False, disabled_explicit=False)
        with mock.patch.object(install, "job_state", return_value=policy):
            result = install.uninstall({"resume": context["run_id"]}, context)
        self.assertEqual(result["installation"], "Unknown")
        self.assertTrue(target["agent"].exists())
        execute.assert_not_called()

    def test_uninstall_dry_run_creates_no_journal_or_backup(self):
        target, manifest, context, execute = self.uninstall_fixture()
        before = sorted(str(p) for p in self.root.rglob("*"))
        with mock.patch.object(install, "verify", return_value={"installation": "FilesVerified"}):
            result = install.uninstall({"dry_run": True}, context)
        self.assertEqual(result["installation"], "UninstallPlanned")
        self.assertEqual(before, sorted(str(p) for p in self.root.rglob("*")))
        execute.assert_not_called()

    def test_uninstall_loaded_job_stops_only_owned_label_before_detach(self):
        target, manifest, context, execute = self.uninstall_fixture()
        live = {"loaded": True, "disabled": False, "disabled_explicit": False, "gui_session": True, "pid": 456}
        execute.side_effect = lambda command: live.update(loaded=False, pid=None)
        with mock.patch.object(install, "job_state", side_effect=lambda target: dict(live)), mock.patch.object(install, "assert_job_process") as identity, mock.patch.object(install, "wait_processes") as wait:
            result = install.uninstall({}, context)
        self.assertEqual(result["installation"], "Uninstalled")
        execute.assert_called_once_with(["/bin/launchctl", "bootout", target["domain"] + "/" + target["label"]])
        self.assertEqual(identity.call_count, 2)
        wait.assert_called_once_with(target, manifest, False)

    def test_uninstall_owned_receipt_hardlink_is_rejected_before_changes(self):
        target, manifest, context, execute = self.uninstall_fixture()
        os.link(target["support"] / "receipt.json", self.root / "receipt-copy")
        with self.assertRaises(install.DeployError) as error:
            install.uninstall({}, context)
        self.assertEqual(error.exception.finding, "resume.permissions")
        self.assertTrue(target["path"].exists())
        self.assertTrue(target["agent"].exists())
        execute.assert_not_called()

    def test_uninstall_mutated_owned_job_is_rejected_before_changes(self):
        target, manifest, context, execute = self.uninstall_fixture()
        target["agent"].chmod(0o666)
        with self.assertRaises(install.InstallError) as error:
            install.uninstall({}, context)
        self.assertEqual(error.exception.finding, "startup.ownership")
        self.assertTrue(target["path"].exists())
        execute.assert_not_called()

    def test_registration_unchanged_uses_no_native_mutation(self):
        previous = {"state": "Absent", "bundle_identifier": None, "application_path": None}
        with mock.patch.object(install, "set_default_handler") as setter, mock.patch.object(install, "register_bundle") as register:
            result = install.restore_registration(previous)
        self.assertEqual(result["state"], "DefaultHandlerPreserved")
        self.assertEqual(result["catalog_restoration"], "UnverifiedNoPublicUnregister")
        setter.assert_not_called()
        register.assert_not_called()

    def test_registration_previous_absence_does_not_invent_unregister(self):
        previous = {"state": "Absent", "bundle_identifier": None, "application_path": None}
        self.registration.return_value = {"state": "Observed", "bundle_identifier": install.BUNDLE_ID, "application_path": "/fixture/watchtower.app"}
        with mock.patch.object(install, "set_default_handler") as setter, mock.patch.object(install, "register_bundle") as register:
            result = install.restore_registration(previous)
        self.assertEqual(result["state"], "Unverified")
        setter.assert_not_called()
        register.assert_not_called()

    def test_registration_restore_requires_exact_identifier_and_path(self):
        target, manifest, package = self.transaction_fixture()
        previous = {"state": "Observed", "bundle_identifier": install.BUNDLE_ID, "application_path": str(target["path"])}
        changed = dict(previous, application_path="/fixture/another/watchtower.app")
        for status, after, expected in ((0, previous, "DefaultHandlerRestored"), (-54, changed, "Unverified"), (0, changed, "Unverified")):
            with self.subTest(status=status, path=after["application_path"]), mock.patch.object(install, "registration_snapshot", side_effect=[changed, after]), mock.patch.object(install, "set_default_handler", return_value=status) as setter, mock.patch.object(install, "register_bundle") as register:
                result = install.restore_registration(previous)
            self.assertEqual(result["state"], expected)
            setter.assert_called_once_with(install.BUNDLE_ID)
            register.assert_called_once_with(target["path"])

    def test_registration_unknown_blocks_replacement_before_staging(self):
        target, manifest, package = self.transaction_fixture()
        before = {"loaded": False, "disabled": False, "disabled_explicit": False, "gui_session": True}
        self.registration.return_value = {"state": "Unverified"}
        with mock.patch.object(install, "job_state", return_value=before), mock.patch.object(install, "selected_processes", return_value=[]), mock.patch.object(install, "execute") as execute:
            with self.assertRaises(install.InstallError) as error:
                install.transaction(package, manifest, target, {}, {"security_admission": "DevelopmentOnly", "run_id": "fixture-unknown-handler"})
        self.assertEqual(error.exception.finding, "bundle.registration_snapshot")
        self.assertEqual((target["path"] / "Contents/payload").read_text(), "old-version")
        self.assertEqual(list(target["path"].parent.glob(".cilex-deploy-*")), [])
        execute.assert_not_called()

    def test_rollback_records_unrestorable_default_separately(self):
        target, manifest, package = self.transaction_fixture()
        before = {"loaded": False, "disabled": False, "disabled_explicit": False, "gui_session": True}
        absent = {"state": "Absent", "bundle_identifier": None, "application_path": None}
        changed = {"state": "Observed", "bundle_identifier": install.BUNDLE_ID, "application_path": str(target["path"])}
        self.registration.side_effect = [absent, changed]
        with mock.patch.object(install, "job_state", return_value=before), mock.patch.object(install, "selected_processes", return_value=[]), mock.patch.object(install, "register_bundle", side_effect=[install.InstallError("fixture.registration", "injected partial registration"), None]), mock.patch.object(install, "set_default_handler") as setter:
            result = install.transaction(package, manifest, target, {}, {"security_admission": "DevelopmentOnly", "run_id": "fixture-handler-rollback"})
        self.assertEqual(result["installation"], "Failed")
        self.assertEqual(result["original_failure"]["finding"], "fixture.registration")
        self.assertEqual(result["rollback_registration"]["state"], "Unverified")
        self.assertEqual((target["path"] / "Contents/payload").read_text(), "old-version")
        self.assertTrue(any("handler recovery is unverified" in item for item in result["limitations"]))
        setter.assert_not_called()


@unittest.skipUnless(sys.platform == "darwin", "Native CoreFoundation preferences")
class NativePreferencesTests(unittest.TestCase):
    def test_owned_unique_domain_cache_restoration_removes_new_keys(self):
        domain = "com.cilexvision.deploy.fixture." + uuid.uuid4().hex
        path = Path.home() / "Library/Preferences" / (domain + ".plist")
        try:
            self.assertEqual(install.preferences_cache(domain), {})
            install.preferences_cache(domain, {"fixture": "first", "added": True})
            install.preferences_cache(domain, {"fixture": "restored"})
            self.assertEqual(install.preferences_cache(domain), {"fixture": "restored"})
        finally:
            install.preferences_cache(domain, {})
            if path.is_file() and not path.is_symlink() and path.stat().st_uid == os.geteuid():
                path.unlink()


class StartupAssessmentTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="Cilex startup assessment ")
        self.root = Path(self.temporary.name)
        self.path = self.root / "loginwindow.plist"
        self.addCleanup(self.temporary.cleanup)
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(install, "LOGINWINDOW_PLIST", self.path).start()
        mock.patch.object(install.platform, "system", return_value="Darwin").start()

    def assess(self, filevault="FileVault is On.\n", config=None, **options):
        if config is not None:
            self.path.write_bytes(plistlib.dumps(config))
        with mock.patch.object(install, "execute", return_value=types.SimpleNamespace(returncode=0, stdout=filevault)) as operation:
            value = install.startup_assessment({"user": "designated-fixture-user"}, dict({"startup": "unattended-reboot"}, **options))
        operation.assert_called_once_with(["/usr/bin/fdesetup", "status"], timeout=15, check=False)
        return value

    def test_filevault_and_missing_automatic_login_are_explicit_blockers(self):
        value = self.assess(config={})
        self.assertEqual(value["startup"], "BlockedUnattendedRebootUnverified")
        self.assertEqual(value["startup_evidence"]["filevault"], "On")
        self.assertEqual(value["startup_evidence"]["automatic_login"], "NotConfigured")
        self.assertEqual({row["id"] for row in value["startup_evidence"]["blockers"]}, {"startup.filevault_on", "startup.automatic_login_missing", "startup.boot_unverified"})

    def test_matching_automatic_login_never_proves_boot(self):
        value = self.assess("FileVault is Off.\n", {"autoLoginUser": "designated-fixture-user", "unrelated": "fixture-private-value"})
        self.assertTrue(value["startup_evidence"]["desktop_account_matches"])
        self.assertEqual(value["startup"], "BlockedUnattendedRebootUnverified")
        self.assertEqual([row["id"] for row in value["startup_evidence"]["blockers"]], ["startup.boot_unverified"])
        self.assertNotIn("designated-fixture-user", json.dumps(value))
        self.assertNotIn("fixture-private-value", json.dumps(value))

    def test_other_account_is_redacted_and_blocked(self):
        value = self.assess("FileVault is Off.\n", {"autoLoginUser": "other-private-fixture-user"}, language="ru")
        self.assertFalse(value["startup_evidence"]["desktop_account_matches"])
        self.assertIn("startup.automatic_login_other_account", [row["id"] for row in value["startup_evidence"]["blockers"]])
        self.assertNotIn("other-private-fixture-user", json.dumps(value))
        self.assertIn("учётной", value["startup_evidence"]["blockers"][0]["message"])

    def test_inaccessible_status_and_invalid_preferences_stay_unverified(self):
        self.path.write_bytes(b"invalid plist")
        before = self.path.read_bytes()
        with mock.patch.object(install, "execute", side_effect=install.InstallError("command.failed", "fixture status unavailable")):
            value = install.startup_assessment({"user": "fixture"}, {"startup": "unattended-reboot"})
        self.assertEqual(value["startup_evidence"]["filevault"], "Unverified")
        self.assertEqual(value["startup_evidence"]["automatic_login"], "Unverified")
        self.assertEqual(self.path.read_bytes(), before)

    def test_after_sign_in_is_unverified_without_unrelated_automatic_login_block(self):
        value = self.assess(startup="after-sign-in")
        self.assertEqual(value["startup"], "StartupUnverified")
        self.assertEqual(value["startup_evidence"]["blockers"], [])

    def test_symlink_preference_source_is_not_followed(self):
        other = self.root / "unrelated.plist"
        other.write_bytes(plistlib.dumps({"autoLoginUser": "designated-fixture-user"}))
        self.path.symlink_to(other)
        value = self.assess()
        self.assertEqual(value["startup_evidence"]["automatic_login"], "Unverified")


if __name__ == "__main__":
    unittest.main()
