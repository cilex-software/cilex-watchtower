#!/usr/bin/env python3
"""Designated-Mac rollback acceptance harness, never invoked by production code.

Default: bounded read-only preflight. --execute-authorized-test is a separate
explicit test action and requires an already loaded installation. Default tests
require healthy video; --process-only retains degraded video and cannot pass full
acceptance even when file/configuration/startup/process recovery is observed.
This program neither starts a stopped job nor reboots. The operator/main test
orchestrator remains responsible for the requested final stopped state.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import stat
import sys
import time
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import common
import install
import runtime

INJECTED_FINDING = "fixture.injected_post_replacement"


def required_sha(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise ValueError("An explicit lowercase SHA-256 binding is required.")
    return value


def options_for(request):
    return {"mode": "install", "scope": "user", "desktop_user": request["desktop_user"],
            "install_dir": request["install_dir"], "startup": "after-sign-in",
            "dependencies": "offline", "allow_development": bool(request.get("allow_development")),
            "observe_seconds": 0 if request.get("process_only") else 150, "observation_timeout": 240,
            "expected_cameras": request["expected_cameras"], "language": "en"}


def preflight(request, allow_created_evidence=False):
    """No writes, application lifecycle operations, package extraction or dialogs."""
    if platform.system() != "Darwin" or os.geteuid() == 0:
        raise ValueError("Run this designated-Mac test as its signed-in desktop user.")
    identity = common.host_identity()
    if identity.get("machine_id") != required_sha(request["expected_target_id"]) or identity.get("uid") != os.geteuid():
        raise ValueError("This is not the explicitly designated test machine/account.")
    if not re.fullmatch(r"[A-Za-z0-9_-]{8,80}", request["run_id"]):
        raise ValueError("Use a new explicit run ID containing 8–80 safe characters.")
    if not isinstance(request["expected_cameras"], int) or isinstance(request["expected_cameras"], bool) or request["expected_cameras"] < 1:
        raise ValueError("Specify the intended positive camera count before testing recovery.")
    options = options_for(request)
    target = install.resolve_target(options)
    install.assert_authorized(target, options)
    if str(target["path"]) != request["install_dir"] or target["user"] != request["desktop_user"]:
        raise ValueError("Resolved test target differs from the explicit path/account binding.")
    receipt_path = target["support"] / "receipt.json"
    receipt = install.read_owned_receipt(target)
    if install.sha256(receipt_path) != required_sha(request["expected_receipt_sha256"]):
        raise ValueError("The current installation receipt changed; inspect it before authorizing another test.")
    if (target["support"] / (request["run_id"] + ".json")).exists():
        raise ValueError("This test run already has transaction evidence; use its existing recovery procedure, not a repeated crash test.")
    install.reject_other_incomplete_transactions(target, request["run_id"])
    manifest = receipt["manifest"]
    install.verify_app_inventory(target["path"], manifest)
    install.validate_existing(target, manifest)
    job = install.job_state(target)
    if not job["gui_session"] or not job["loaded"] or job["disabled"] or not job.get("pid"):
        raise ValueError("The selected installation must already be running in its enabled graphical LaunchAgent. This harness will not start it.")
    install.assert_job_process(target, manifest, job)
    process = install.verify_processes(target, manifest)
    if process.get("state") != "ProcessVerified":
        raise ValueError("The current Warden/app/guardian graph is not verified; establish a healthy baseline before injecting failure.")
    package = Path(request["package"])
    if not package.is_absolute() or package.is_symlink() or not package.is_file():
        raise ValueError("Use an absolute regular trusted package archive path.")
    if install.sha256(package) != required_sha(request["package_sha256"]):
        raise ValueError("Test package hash does not match its explicit trusted digest.")
    evidence = Path(request["evidence_dir"])
    if not evidence.is_absolute() or ".." in evidence.parts or (evidence.exists() and not allow_created_evidence):
        raise ValueError("Use a new absolute private evidence directory; previous failed evidence is never reused.")
    if allow_created_evidence:
        prior_request = json.loads(common.checked_private_file(evidence / "request.json").read_text(encoding="utf-8"))
        if prior_request != request:
            raise ValueError("The protected native-test request changed during baseline.")
    for ancestor in (evidence, *evidence.parents):
        if ancestor.is_symlink():
            raise ValueError("Evidence destination must not have a symbolic-link ancestor.")
    return {"target": target, "options": options, "receipt": receipt, "target_identity": identity,
            "previous_app_sha256": install.app_fingerprint(target["path"]), "process_evidence": process}


def require_video(result, phase):
    if result.get("runtime_health") != "ProcessVerified" or result.get("gui_video") != "VisibleAndPerSourceVideoObserved":
        raise ValueError(phase + " did not prove the required 150-second visible per-source video interval; retain all failed evidence.")


def require_visible_process(result, phase):
    if (result.get("runtime_health") != "ProcessVerified" or result.get("gui_visibility") != "Visible"
            or result.get("window_evidence", {}).get("state") != "Visible"):
        raise ValueError(phase + " did not prove the selected native process graph and visible window metadata; failure injection or recovery acceptance is not permitted.")


def control_state(target):
    """Only hashes/ownership/policy: never persist configuration or credentials."""
    files = {}
    for path in [target["agent"], target["support"] / "receipt.json"] + install.configuration_paths(target):
        info = install.configuration_file(path, target)
        files[str(path)] = ({"exists": True, "sha256": install.sha256(path),
                             "mode": stat.S_IMODE(info.st_mode), "uid": info.st_uid, "gid": info.st_gid}
                            if info else {"exists": False})
    job = install.job_state(target)
    return {"files": files, "startup_policy": {key: job[key] for key in
            ("loaded", "disabled", "disabled_explicit", "gui_session")}}


def exit_code(result):
    if result["state"] == "FilesReceiptConfigurationStartupAndProcessesRestored_VideoUnverified":
        return common.EXITS["verification"]
    return 0 if result["state"] in ("PreflightPassed", "FilesReceiptProcessesAnd150SecondPerSourceVideoRecoveryObserved") else 40


def run(request):
    prepared = preflight(request)
    target, options = prepared["target"], prepared["options"]
    result = {"schema_version": 1, "test": "NativeRollbackInjectedPostReplacementFailure",
              "run_id": request["run_id"], "target": prepared["target_identity"],
              "installation_id": target["id"], "install_dir": str(target["path"]),
              "package_sha256": request["package_sha256"], "expected_receipt_sha256": request["expected_receipt_sha256"],
              "test_mode": "ProcessOnly" if request.get("process_only") else "FullVideo",
              "full_acceptance": False,
              "state": "PreflightPassed", "final_stopped_state": "OrchestratorMustEnforce",
              "limitations": ["This test does not establish crash, reboot, cold-start, backend or representative playback/export acceptance.",
                              "The required final stopped state must be applied and verified by the authorized test orchestrator."]}
    if not request.get("execute_authorized_test"):
        return result
    evidence = Path(request["evidence_dir"])
    common.private_dir(evidence)
    install.atomic_json(evidence / "request.json", dict(request))
    try:
        baseline_dir = evidence / "baseline"
        common.private_dir(baseline_dir)
        baseline = runtime.verify(options, {"target": target, "manifest": prepared["receipt"]["manifest"],
                                  "write_evidence": True, "evidence_dir": str(baseline_dir), "run_id": request["run_id"]})
        result["baseline"] = baseline
        install.atomic_json(evidence / "result.json", result)
        if request.get("process_only"):
            require_visible_process(baseline, "Process-only baseline")
            result["video_acceptance"] = "UnverifiedDegradedBaselinePreserved"
            result["limitations"].append("Process-only testing does not establish healthy camera feeds or the required150-second interval. Its best outcome is incomplete, exit18.")
            recovery_options = dict(options)
        else:
            require_video(baseline, "Baseline")
            source_ids = baseline.get("video_evidence", {}).get("source_hashes")
            if not isinstance(source_ids, list) or len(source_ids) != request["expected_cameras"] or len(set(source_ids)) != len(source_ids):
                raise ValueError("Baseline did not provide a unique source identity for every expected camera.")
            source_ids = [required_sha(value) for value in source_ids]
            recovery_options = dict(options, expected_source_ids=sorted(source_ids))
            result["expected_recovery_source_hashes"] = recovery_options["expected_source_ids"]
        # Rebind after observation: another install or a process restart must not
        # silently turn a validated baseline into a different test subject.
        rebound = preflight(request, allow_created_evidence=True)
        if rebound["previous_app_sha256"] != prepared["previous_app_sha256"] or any(
                not runtime.same_process(prepared["process_evidence"].get(role), rebound["process_evidence"].get(role))
                for role in ("app", "warden", "guardian")):
            raise ValueError("The bound process generation or application changed during baseline; failure injection was cancelled.")
        package_root = evidence / "verified-package"
        package_root.mkdir(mode=0o700)
        install.safe_extract(request["package"], package_root, request["package_sha256"])
        if request.get("process_only"):
            result["controls_before"] = control_state(target)
            install.atomic_json(evidence / "result.json", result)
        # Signature, full closure and target checks are real install.run work.
        injected = []
        def inject(actual_target, manifest, actual_options, context, staging, state, record_path, actual_result):
            if actual_target["id"] != target["id"] or context["run_id"] != request["run_id"] or state.get("phase") != "replaced" or injected:
                raise ValueError("Unexpected injection target, phase or repeated callback; stop this test.")
            injected.append({"at": time.time(), "replacement_version": manifest.get("version")})
            raise install.InstallError(INJECTED_FINDING, "Authorized test-only failure after replacement and process readiness; execute the real rollback path.")
        started = time.monotonic()
        with mock.patch.object(install, "requested_observation", side_effect=inject):
            transaction = install.run(options, {"run_id": request["run_id"], "package_root": str(package_root), "package_sha256": request["package_sha256"]})
        result.update(transaction=transaction, injection=injected,
                      transaction_and_rollback_seconds=round(time.monotonic() - started, 3))
        install.atomic_json(evidence / "result.json", result)
        if len(injected) != 1 or transaction.get("installation") != "Failed" or transaction.get("original_failure", {}).get("finding") != INJECTED_FINDING or transaction.get("rollback") != "FilesAndProcessStateRestored_RuntimeUnverified":
            raise ValueError("The expected injected-failure rollback was not observed; preserve the original and rollback failures separately.")
        if install.sha256(target["support"] / "receipt.json") != request["expected_receipt_sha256"] or install.app_fingerprint(target["path"]) != prepared["previous_app_sha256"]:
            raise ValueError("Recovered files or receipt differ from the pre-test installation.")
        recovery_dir = evidence / "recovery"
        common.private_dir(recovery_dir)
        recovery = runtime.verify(recovery_options, {"target": target, "manifest": prepared["receipt"]["manifest"],
                                  "write_evidence": True, "evidence_dir": str(recovery_dir), "run_id": request["run_id"]})
        result["independent_recovery_observation"] = recovery
        install.atomic_json(evidence / "result.json", result)
        if request.get("process_only"):
            require_visible_process(recovery, "Recovered process-only installation")
            result["controls_after"] = control_state(target)
            result["control_state_restored"] = result["controls_before"] == result["controls_after"]
            if not result["control_state_restored"]:
                raise ValueError("Configuration bytes/ownership or startup policy differ after rollback; retain the partial recovery evidence.")
            result["state"] = "FilesReceiptConfigurationStartupAndProcessesRestored_VideoUnverified"
        else:
            require_video(recovery, "Recovered installation")
            if sorted(recovery.get("video_evidence", {}).get("source_hashes", [])) != recovery_options["expected_source_ids"]:
                raise ValueError("Recovered video identities differ from the healthy baseline; recovery is not established.")
            result["state"] = "FilesReceiptProcessesAnd150SecondPerSourceVideoRecoveryObserved"
        result["registration_recovery"] = transaction.get("rollback_registration", {"state": "Unverified"})
        return result
    except BaseException as error:
        result.update(state="Failed", failure={"type": type(error).__name__, "finding": getattr(error, "finding", None), "message": str(error)})
        return result
    finally:
        install.atomic_json(evidence / "result.json", result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("expected-target-id", "expected-receipt-sha256", "desktop-user", "install-dir", "package", "package-sha256", "run-id", "evidence-dir"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--expected-cameras", type=int, required=True)
    parser.add_argument("--allow-development", action="store_true")
    parser.add_argument("--execute-authorized-test", action="store_true")
    parser.add_argument("--process-only", action="store_true", help="TEST ONLY: observe file/configuration/startup/process rollback with visible window metadata; video remains unverified and outcome returns18.")
    result = run(vars(parser.parse_args()))
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return exit_code(result)


if __name__ == "__main__":
    sys.exit(main())
