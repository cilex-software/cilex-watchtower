"""Fixture-only native acceptance harness tests; no app/launchd operations."""
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import native_rollback as harness


class NativeRollbackHarnessTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="Rollback fixture ")
        self.addCleanup(self.temporary.cleanup)
        self.addCleanup(mock.patch.stopall)
        self.root = Path(self.temporary.name).resolve()
        self.target = {"id": "fixture-installation", "uid": os.geteuid(), "user": "fixture operator", "home": self.root,
                       "path": self.root / "Applications/watchtower.app", "support": self.root / "records", "agent": self.root / "agent.plist"}
        self.target["support"].mkdir()
        receipt = self.target["support"] / "receipt.json"
        receipt.write_text('{"fixture":true}')
        receipt.chmod(0o600)
        self.target["agent"].write_bytes(b"fixture startup policy")
        self.target["agent"].chmod(0o600)
        package = self.root / "package.tar.gz"
        package.write_bytes(b"fixture archive")
        self.request = {"expected_target_id": "a" * 64, "expected_receipt_sha256": harness.install.sha256(receipt),
                        "desktop_user": self.target["user"], "install_dir": str(self.target["path"]),
                        "package": str(package), "package_sha256": harness.install.sha256(package),
                        "run_id": "fixture-native-rollback", "evidence_dir": str(self.root / "evidence"), "expected_cameras": 31}
        self.process = {"state": "ProcessVerified"}
        for number, role in enumerate(("app", "warden", "guardian"), 10):
            self.process[role] = {"pid": number, "uid": os.geteuid(), "birth": [100, number], "path": "/fixture/" + role, "session": 1}
        mock.patch.object(harness.platform, "system", return_value="Darwin").start()
        mock.patch.object(harness.common, "host_identity", return_value={"os": "Darwin", "machine_id": "a" * 64, "uid": os.geteuid()}).start()
        mock.patch.object(harness.install, "resolve_target", return_value=self.target).start()
        mock.patch.object(harness.install, "assert_authorized").start()
        mock.patch.object(harness.install, "read_owned_receipt", return_value={"manifest": {"version": "fixture"}}).start()
        mock.patch.object(harness.install, "reject_other_incomplete_transactions").start()
        mock.patch.object(harness.install, "verify_app_inventory").start()
        mock.patch.object(harness.install, "validate_existing").start()
        mock.patch.object(harness.install, "assert_job_process").start()
        mock.patch.object(harness.install, "app_fingerprint", return_value="b" * 64).start()
        self.job = mock.patch.object(harness.install, "job_state", return_value={"gui_session": True, "loaded": True, "disabled": False, "disabled_explicit": False, "pid": 11}).start()
        self.graph = mock.patch.object(harness.install, "verify_processes", return_value=self.process).start()
        self.extract = mock.patch.object(harness.install, "safe_extract").start()
        self.transaction = mock.patch.object(harness.install, "run").start()
        self.video_result = {"runtime_health": "ProcessVerified", "gui_visibility": "Visible", "window_evidence": {"state": "Visible"}, "gui_video": "VisibleAndPerSourceVideoObserved", "video_evidence": {"source_hashes": [hashlib.sha256(str(number).encode()).hexdigest() for number in range(31)]}}
        self.video = mock.patch.object(harness.runtime, "verify", return_value=self.video_result).start()

    def test_default_preflight_has_no_writes_extraction_or_lifecycle_actions(self):
        before = sorted(str(p) for p in self.root.rglob("*"))
        self.assertEqual(harness.run(self.request)["state"], "PreflightPassed")
        self.assertEqual(before, sorted(str(p) for p in self.root.rglob("*")))
        self.extract.assert_not_called()
        self.transaction.assert_not_called()
        self.video.assert_not_called()

    def test_different_machine_receipt_package_and_account_are_rejected(self):
        for field, value in (("expected_target_id", "f" * 64), ("expected_receipt_sha256", "f" * 64),
                             ("package_sha256", "f" * 64), ("desktop_user", "different account"),
                             ("install_dir", str(self.root / "different.app"))):
            with self.subTest(field=field), self.assertRaises(ValueError):
                harness.run(dict(self.request, **{field: value}))
        self.extract.assert_not_called()
        self.transaction.assert_not_called()

    def test_stopped_job_is_never_started_even_with_execution_flag(self):
        self.job.return_value["loaded"] = False
        with self.assertRaises(ValueError):
            harness.run(dict(self.request, execute_authorized_test=True))
        self.transaction.assert_not_called()
        self.video.assert_not_called()
        self.assertFalse(Path(self.request["evidence_dir"]).exists())

    def test_old_evidence_and_unsafe_path_refused_before_actions(self):
        evidence = Path(self.request["evidence_dir"])
        evidence.mkdir()
        with self.assertRaises(ValueError):
            harness.run(self.request)
        evidence.rmdir()
        evidence.symlink_to(self.root)
        with self.assertRaises(ValueError):
            harness.run(self.request)
        self.transaction.assert_not_called()

    def test_execution_injects_once_then_independently_observes_recovery(self):
        def transaction(options, context):
            with self.assertRaises(harness.install.InstallError) as failure:
                harness.install.requested_observation(self.target, {"version": "replacement"}, options, context,
                    self.root, {"phase": "replaced"}, self.root / "record.json", {})
            self.assertEqual(failure.exception.finding, harness.INJECTED_FINDING)
            return {"installation": "Failed", "original_failure": {"finding": failure.exception.finding},
                    "rollback": "FilesAndProcessStateRestored_RuntimeUnverified", "rollback_registration": {"state": "DefaultHandlerPreserved"}}
        self.transaction.side_effect = transaction
        result = harness.run(dict(self.request, execute_authorized_test=True))
        self.assertEqual(result["state"], "FilesReceiptProcessesAnd150SecondPerSourceVideoRecoveryObserved")
        self.assertEqual(len(result["injection"]), 1)
        self.assertEqual(self.video.call_count, 2)
        self.assertNotIn("expected_source_ids", self.video.call_args_list[0].args[0])
        self.assertEqual(self.video.call_args_list[1].args[0]["expected_source_ids"], sorted(self.video_result["video_evidence"]["source_hashes"]))
        self.assertEqual([call.args[0]["observe_seconds"] for call in self.video.call_args_list], [150, 150])
        self.assertEqual([Path(call.args[1]["evidence_dir"]).name for call in self.video.call_args_list], ["baseline", "recovery"])
        stored = json.loads(Path(self.request["evidence_dir"]).joinpath("result.json").read_text())
        self.assertEqual(stored["transaction"]["original_failure"]["finding"], harness.INJECTED_FINDING)
        self.assertEqual(stored["final_stopped_state"], "OrchestratorMustEnforce")

    def test_aggregate_only_baseline_cannot_authorize_failure_injection(self):
        self.video.return_value["gui_video"] = "VisibleAndAggregateVideoObserved"
        result = harness.run(dict(self.request, execute_authorized_test=True))
        self.assertEqual(result["state"], "Failed")
        self.transaction.assert_not_called()
        self.extract.assert_not_called()
        self.assertTrue(Path(self.request["evidence_dir"]).joinpath("result.json").is_file())

    def test_missing_baseline_source_identity_cancels_failure_injection(self):
        self.video_result["video_evidence"]["source_hashes"].pop()
        result = harness.run(dict(self.request, execute_authorized_test=True))
        self.assertEqual(result["state"], "Failed")
        self.transaction.assert_not_called()
        self.extract.assert_not_called()

    def test_reused_pid_generation_between_baseline_and_injection_is_rejected(self):
        changed = dict(self.process, warden=dict(self.process["warden"], birth=[200, 1]))
        self.graph.side_effect = [self.process, changed]
        result = harness.run(dict(self.request, execute_authorized_test=True))
        self.assertEqual(result["state"], "Failed")
        self.transaction.assert_not_called()
        self.extract.assert_not_called()

    def test_changed_protected_request_after_baseline_cancels_injection(self):
        def baseline(*args):
            Path(self.request["evidence_dir"]).joinpath("request.json").write_text('{}')
            return self.video_result
        self.video.side_effect = baseline
        result = harness.run(dict(self.request, execute_authorized_test=True))
        self.assertEqual(result["state"], "Failed")
        self.transaction.assert_not_called()
        self.extract.assert_not_called()

    def process_only_transaction(self, mutate=None):
        def transaction(options, context):
            with self.assertRaises(harness.install.InstallError) as failure:
                harness.install.requested_observation(self.target, {"version": "replacement"}, options, context,
                    self.root, {"phase": "replaced"}, self.root / "record.json", {})
            if mutate:
                mutate()
            return {"installation": "Failed", "original_failure": {"finding": failure.exception.finding},
                    "rollback": "FilesAndProcessStateRestored_RuntimeUnverified"}
        self.transaction.side_effect = transaction

    def test_process_only_default_still_performs_no_mutations(self):
        result = harness.run(dict(self.request, process_only=True))
        self.assertEqual(result["test_mode"], "ProcessOnly")
        self.assertEqual(result["state"], "PreflightPassed")
        self.assertFalse(Path(self.request["evidence_dir"]).exists())
        self.transaction.assert_not_called()
        self.video.assert_not_called()

    def test_process_only_retains_degraded_video_and_returns_incomplete18(self):
        self.process_only_transaction()
        self.video_result.update(gui_video="Failed", video_evidence={"state": "Failed", "reason": "EXPECTED_CAMERA_COUNTS_NOT_MAINTAINED"})
        result = harness.run(dict(self.request, process_only=True, execute_authorized_test=True))
        self.assertEqual(result["state"], "FilesReceiptConfigurationStartupAndProcessesRestored_VideoUnverified")
        self.assertEqual(harness.exit_code(result), 18)
        self.assertFalse(result["full_acceptance"])
        self.assertTrue(result["control_state_restored"])
        self.assertEqual(result["baseline"]["gui_video"], "Failed")
        self.assertEqual(result["independent_recovery_observation"]["gui_video"], "Failed")
        self.assertEqual([call.args[0]["observe_seconds"] for call in self.video.call_args_list], [0, 0])
        self.assertNotIn("expected_recovery_source_hashes", result)
        self.assertEqual(len(result["injection"]), 1)

    def test_process_only_refuses_missing_native_visibility_before_mutation(self):
        self.video_result["window_evidence"]["state"] = "NotObserved"
        result = harness.run(dict(self.request, process_only=True, execute_authorized_test=True))
        self.assertEqual(result["state"], "Failed")
        self.transaction.assert_not_called()
        self.extract.assert_not_called()

    def test_process_only_refuses_unverified_baseline_graph(self):
        self.video_result["runtime_health"] = "UnverifiedVersionMismatch"
        result = harness.run(dict(self.request, process_only=True, execute_authorized_test=True))
        self.assertEqual(result["state"], "Failed")
        self.transaction.assert_not_called()

    def test_process_only_independent_recovery_graph_must_pass(self):
        self.process_only_transaction()
        self.video.side_effect = [self.video_result, dict(self.video_result, runtime_health="Unverified")]
        result = harness.run(dict(self.request, process_only=True, execute_authorized_test=True))
        self.assertEqual(result["state"], "Failed")
        self.assertEqual(harness.exit_code(result), 40)
        self.assertEqual(len(result["injection"]), 1)
        self.assertIn("independent_recovery_observation", result)

    def test_process_only_detects_changed_configuration_after_file_recovery(self):
        configuration = self.root / ".config/watchtower-warden/warden.conf"
        configuration.parent.mkdir(parents=True)
        configuration.write_bytes(b"fixture value")
        configuration.chmod(0o600)
        self.process_only_transaction(lambda: configuration.write_bytes(b"changed value"))
        result = harness.run(dict(self.request, process_only=True, execute_authorized_test=True))
        self.assertEqual(result["state"], "Failed")
        self.assertFalse(result["control_state_restored"])
        self.assertNotIn("fixture value", json.dumps(result))
        self.assertNotIn("changed value", json.dumps(result))

    def test_process_only_detects_changed_startup_policy(self):
        self.process_only_transaction(lambda: self.job.return_value.update(disabled=True))
        result = harness.run(dict(self.request, process_only=True, execute_authorized_test=True))
        self.assertEqual(result["state"], "Failed")
        self.assertFalse(result["control_state_restored"])

    def test_process_only_cannot_bypass_package_binding(self):
        with self.assertRaises(ValueError):
            harness.run(dict(self.request, process_only=True, execute_authorized_test=True, package_sha256="f" * 64))
        self.transaction.assert_not_called()


if __name__ == "__main__":
    unittest.main()
