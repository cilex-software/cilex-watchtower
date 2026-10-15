#!/usr/bin/env python3
"""Explicitly authorized native crash drill for one receipt-owned installation.

Never starts/stops jobs, repairs an app, clears holds, reads credentials, or
reboots. Only the exact revalidated application/Warden can receive SIGKILL.
Per-source telemetry does not certify camera-name mapping or export. Explicit
--process-only tests recovery while retaining failed/unverified video acceptance.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import secrets
import signal
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'packaging/macos/generic'))
import common
import install
import runtime
sys.path.insert(0, str(ROOT / 'warden'))
import warden_darwin as native


class DrillError(RuntimeError):
    pass


def identity_key(row):
    return row['pid'], tuple(row['birth']), row['uid'], row['session'], row['path']


def row_still_present(row, rows):
    # For *absence*, a changed path/session/UID does not mean the old process
    # died. Signalling remains stricter and binds every native identity field.
    return any(row['pid'] == current['pid'] and row['birth'] == current['birth'] for current in rows)


def complete_known_identities(rows, known):
    """Unreadable known PIDs must not become false cleanup-success evidence."""
    present = {row['pid'] for row in rows}
    for old in known:
        if old['pid'] not in present:
            current = native.process_identity(old['pid'])
            if current:
                rows.append(current)
                present.add(current['pid'])
    return rows


def observed_descendants(roots, rows, recorded):
    """Bind only live native descendants or identities already owned by guardian."""
    live = {identity_key(row): row for row in roots}
    by_pid = {row['pid']: row for row in rows}
    for old in recorded:
        current = by_pid.get(old.get('pid'))
        if not current or current['uid'] != roots[0]['uid']:
            continue
        if any(current.get(key) != old.get(key) for key in ('pid', 'birth', 'uid', 'session')):
            continue
        if current['path'] in old.get('allowed_paths', [old.get('path')]):
            live[identity_key(current)] = current
    changed = True
    while changed:
        changed = False
        parents = {row['pid'] for row in live.values()}
        for row in rows:
            if row['uid'] == roots[0]['uid'] and row['ppid'] in parents and identity_key(row) not in live:
                live[identity_key(row)] = row
                changed = True
    return list(live.values())


def graph(target, manifest):
    rows = runtime.process_snapshot()
    record_path = Path(target['home']) / 'Library/Application Support/CilexWatchtower/Warden' / target['id'] / 'process-guard/processes.json'
    record = runtime._private_json(record_path, target['uid'])
    return runtime.process_evidence(target, manifest, rows=rows, record=record), rows, record


def require_graph(evidence):
    if evidence.get('state') != 'ProcessVerified' or evidence.get('duplicates'):
        raise DrillError('PROCESS_GRAPH_NOT_VERIFIED_' + evidence.get('reason', 'UNKNOWN'))


def same_graph(left, right):
    return all(runtime.same_process(left.get(role), right.get(role)) for role in ('app', 'warden', 'guardian'))


def require_visible_observation(observation, expected_graph=None, require_video=False):
    """Process-only changes the video criterion, never graph or GUI authorization."""
    if observation.get('runtime_health') != 'ProcessVerified' or observation.get('gui_visibility') != 'Visible':
        raise DrillError('VISIBLE_NATIVE_PROCESS_BASELINE_NOT_VERIFIED')
    actual = observation.get('process_evidence', {})
    require_graph(actual)
    if expected_graph is not None and not same_graph(expected_graph, actual):
        raise DrillError('PROCESS_GRAPH_CHANGED_DURING_PREFLIGHT')
    if require_video and observation.get('gui_video') != 'VisibleWithRecentPerSourceVideo':
        raise DrillError('VISIBLE_HEALTHY_BASELINE_NOT_VERIFIED')


def initial_source_ids(observation, expected_count):
    """Pin available opaque source identities, without claiming their video health."""
    candidates = observation.get('video_evidence', {}).get('source_hashes')
    if candidates is None:
        rows = observation.get('samples', [])
        candidates = [row.get('id') for row in rows[-1].get('sources', [])] if rows else []
    if not isinstance(candidates, list) or len(candidates) != expected_count \
            or any(not isinstance(value, str) or not re.fullmatch('[a-f0-9]{64}', value) for value in candidates) \
            or len(set(candidates)) != expected_count:
        return None
    return sorted(candidates)


def verify_before_signal(options, target, manifest, receipt_path, receipt_hash, expected_graph,
                         on_observation=lambda observation: None):
    """Every signal requires current file, receipt, graph and window evidence."""
    install.verify_app_inventory(target['path'], manifest)
    if common.sha256(receipt_path) != receipt_hash:
        raise DrillError('INSTALL_RECEIPT_CHANGED_BEFORE_CRASH')
    observation = runtime.verify(dict(options, mode='verify', observe_seconds=0),
                                 {'target': target, 'manifest': manifest})
    on_observation(observation)
    require_visible_observation(observation, expected_graph, require_video=not options.get('process_only', False))
    return observation


def await_visible_observation(options, target, manifest, expected_graph, on_update, timeout=30):
    """Bounded GUI readiness after measured process recovery; no restart/repair."""
    started = time.monotonic()
    while True:
        observation = runtime.verify(dict(options, mode='verify', observe_seconds=0),
                                     {'target': target, 'manifest': manifest})
        elapsed = time.monotonic() - started
        on_update({'elapsed_seconds': round(elapsed, 3), 'observation': observation})
        if observation.get('runtime_health') != 'ProcessVerified' \
                or not same_graph(expected_graph, observation.get('process_evidence', {})):
            raise DrillError('RECOVERED_GRAPH_CHANGED_DURING_GUI_READINESS')
        if elapsed > timeout:
            raise DrillError('RECOVERED_GUI_READINESS_TIMEOUT')
        if observation.get('gui_visibility') == 'Visible':
            require_visible_observation(observation, expected_graph)
            return observation
        if elapsed >= timeout:
            raise DrillError('RECOVERED_GUI_READINESS_TIMEOUT')
        time.sleep(min(.5, max(0, timeout - elapsed)))


def stable_graph(target, manifest, seconds=2):
    first, rows, record = graph(target, manifest)
    require_graph(first)
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        time.sleep(.2)
        current, rows, record = graph(target, manifest)
        require_graph(current)
        if not same_graph(first, current):
            raise DrillError('PROCESS_GRAPH_CHANGED_BEFORE_CRASH')
    state = install.job_state(target)
    if not state['loaded'] or state['disabled'] or not state['gui_session'] or state['pid'] != first['warden']['pid']:
        raise DrillError('SELECTED_LAUNCHAGENT_NOT_ACTIVE_OR_IDENTITY_CHANGED')
    return first, rows, record


def scoped_crash(target, manifest, before, role):
    # No global process names and no cached PID-only decision. Darwin has no
    # pidfd_send_signal; this immediately revalidates native birth/path/session.
    current, rows, record = graph(target, manifest)
    require_graph(current)
    if not same_graph(before, current):
        raise DrillError('PROCESS_IDENTITY_CHANGED_BEFORE_SIGNAL')
    chosen = current[role]
    if chosen['uid'] != os.geteuid() or chosen['uid'] != target['uid'] or chosen['pid'] <= 1:
        raise DrillError('SIGNAL_ACCOUNT_OR_PROCESS_NOT_AUTHORIZED')
    final_rows = runtime.process_snapshot()
    final_graph = runtime.process_evidence(target, manifest, rows=final_rows, record=record)
    require_graph(final_graph)
    if not same_graph(before, final_graph):
        raise DrillError('SUPERVISOR_GRAPH_CHANGED_BEFORE_SIGNAL')
    exact = next((row for row in final_rows if runtime.same_process(chosen, row)), None)
    if not exact or exact['ppid'] != chosen['ppid']:
        raise DrillError('PROCESS_GENERATION_CHANGED_BEFORE_SIGNAL')
    started = time.monotonic()
    os.kill(exact['pid'], signal.SIGKILL)
    return exact, started


def await_recovery(target, manifest, before, old_owned, role, budget, on_update=lambda evidence: None, started_at=None):
    start = time.monotonic() if started_at is None else started_at
    trace, previous_key, polls = [], None, 0
    while True:
        rows = complete_known_identities(runtime.process_snapshot(), old_owned + [before['warden'], before['guardian']])
        evidence = runtime.process_evidence(target, manifest, rows=rows)
        polls += 1
        elapsed = time.monotonic() - start
        selected = evidence.get('processes', [])
        remaining = [row for row in old_owned if row_still_present(row, rows)]
        newer_app = any(row['path'] == before['app']['path'] and not runtime.same_process(row, before['app']) for row in selected)
        newer_warden = any(row['path'] == before['warden']['path'] and not any(runtime.same_process(row, before[part]) for part in ('warden', 'guardian')) for row in selected)
        trace_key = tuple(sorted(identity_key(row) for row in selected)), tuple(sorted(identity_key(row) for row in remaining)), evidence['state']
        if trace_key != previous_key:
            trace.append({'elapsed_seconds': round(elapsed, 3), 'processes': selected,
                          'remaining_owned_processes': remaining, 'state': evidence['state']})
            previous_key = trace_key
            on_update({'elapsed_seconds': round(elapsed, 3), 'polls': polls, 'trace': trace})
        # Persist the offending native snapshot before reporting failure.
        # A replacement Warden may wait for cleanup. A replacement application
        # must not coexist with any old owned app/descendant (or old guardian).
        if evidence.get('duplicates') or (newer_app and remaining):
            raise DrillError('OBSERVED_DUPLICATE_OR_OLD_PROCESS_OVERLAP')
        if role == 'app' and any(not row_still_present(before[part], rows) for part in ('warden', 'guardian')):
            raise DrillError('SUPERVISOR_CHANGED_DURING_APPLICATION_RECOVERY')
        if elapsed > budget:
            raise DrillError('RECOVERY_BUDGET_EXCEEDED')
        if evidence['state'] == 'ProcessVerified' and newer_app and not remaining:
            if role == 'warden' and not newer_warden:
                raise DrillError('WARDEN_GENERATION_DID_NOT_CHANGE')
            return {'status': 'Recovered', 'budget_seconds': budget, 'recovery_seconds': round(elapsed, 3),
                    'before': {key: before[key] for key in ('app', 'warden', 'guardian')},
                    'after': {key: evidence[key] for key in ('app', 'warden', 'guardian')},
                    'old_owned_processes_gone': True, 'no_overlap_observed': True,
                    'polls': polls, 'poll_interval_seconds': .05, 'trace': trace}
        if elapsed >= budget:
            raise DrillError('RECOVERY_BUDGET_EXCEEDED')
        time.sleep(min(.05, max(0, budget - elapsed)))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--install-dir', required=True)
    parser.add_argument('--desktop-user', required=True)
    parser.add_argument('--test-mac-id', required=True, help='exact common.host_identity machine_id of the explicitly designated test Mac')
    parser.add_argument('--expected-cameras', required=True, type=int)
    parser.add_argument('--evidence-dir', required=True, help='absolute private directory; each attempt gets a new subdirectory')
    parser.add_argument('--crash-app', action='store_true')
    parser.add_argument('--crash-warden', action='store_true')
    parser.add_argument('--process-only', action='store_true', help='measure only process recovery; retain failed/unverified video and never claim video acceptance')
    parser.add_argument('--scope', choices=('user', 'machine'), default='user')
    args = parser.parse_args(argv)
    options = vars(args)
    if platform.system() != 'Darwin' or args.expected_cameras < 1 or not (args.crash_app or args.crash_warden):
        parser.error('Use native macOS, a positive expected camera count, and an explicit crash action.')
    host = common.host_identity()
    if not host['machine_id'] or args.test_mac_id != host['machine_id']:
        parser.error('This is not the explicitly designated test Mac; no signal was sent.')
    target = install.resolve_target(options)
    if os.geteuid() != target['uid'] or os.geteuid() == 0 or Path('/dev/console').stat().st_uid != target['uid']:
        parser.error('Run as the intended signed-in desktop account, without sudo.')
    output = Path(args.evidence_dir)
    if not output.is_absolute() or any(path.is_symlink() for path in (output, *output.parents)) or output == target['path'] or target['path'] in output.parents:
        parser.error('Use an absolute canonical evidence directory outside the installed application.')
    base = common.private_dir(output)
    run_id = time.strftime('%Y%m%dT%H%M%SZ', time.gmtime()) + '-' + secrets.token_hex(8)
    evidence_dir = common.private_dir(base / run_id)
    path = evidence_dir / 'result.json'
    result = {'schema_version': 1, 'run_id': run_id, 'test': 'macos-installed-application-recovery',
              'status': 'Running', 'started_at': common.utc(), 'host': host, 'installation_id': target['id'],
              'install_dir': str(target['path']), 'desktop_uid': target['uid'], 'expected_cameras': args.expected_cameras,
              'harness_sha256': common.sha256(Path(__file__)), 'attempts': [], 'full_acceptance': False,
              'process_only': args.process_only,
              'video_acceptance': 'FailedOrUnverified' if args.process_only else 'Pending',
              'required_final_state': {'warden': 'stopped', 'watchtower': 'stopped'},
              'final_stop_verification': 'PendingInvokingController',
              'inspection_helper_hashes': {module.__name__: common.sha256(Path(module.__file__)) for module in (common, install, runtime, native)},
              'limitations': ['Per-source hashes confirm the initial source set; camera-name mapping and playback/export need separate verification.',
                              'No-overlap evidence covers sampled native process identities, including observed descendants.',
                              'No login, sleep, lock, user-switch, network-reconnection or reboot validation.',
                              'No backend holds, enrollment credentials or application configuration are modified.']}
    common.atomic_json(path, result)
    try:
        checked = install.verify(options)
        if checked.get('installation') != 'FilesVerified':
            raise DrillError('INSTALLED_PACKAGE_INVENTORY_NOT_VERIFIED')
        receipt_path = target['support'] / 'receipt.json'
        receipt = runtime._private_json(receipt_path, target['uid'], runtime.MAX_RECEIPT_BYTES)
        manifest = runtime._manifest(target, {})
        result.update(receipt_sha256=common.sha256(receipt_path), package_sha256=receipt.get('package_sha256'),
                      manifest_sha256=common.digest(manifest), versions=checked['versions'])
        baseline = runtime.verify(dict(options, mode='verify', observe_seconds=0), {'target': target, 'manifest': manifest})
        result['initial_runtime'] = baseline
        common.atomic_json(path, result)
        require_visible_observation(baseline, require_video=not args.process_only)
        baseline_sources = initial_source_ids(baseline, args.expected_cameras)
        result['expected_source_identity_basis'] = 'initial_visible_pre_crash_source_set' if baseline_sources else 'Unavailable'
        result['expected_source_ids'] = baseline_sources
        for role, selected, budget in (('app', args.crash_app, 45), ('warden', args.crash_warden, 60)):
            if not selected:
                continue
            install.verify_app_inventory(target['path'], manifest)
            if common.sha256(receipt_path) != result['receipt_sha256']:
                raise DrillError('INSTALL_RECEIPT_CHANGED_BEFORE_CRASH')
            before, rows, record = stable_graph(target, manifest)
            roots = [before['app']] if role == 'app' else [before[key] for key in ('app', 'warden', 'guardian')]
            owned = observed_descendants(roots, rows, record.get('processes', []))
            attempt = {'role': role, 'status': 'Prepared', 'prepared_at': common.utc(), 'old_owned_processes': owned}
            result['attempts'].append(attempt)
            common.atomic_json(path, result)
            def preflight_checkpoint(observation):
                attempt['before_runtime'] = observation
                common.atomic_json(path, result)

            verify_before_signal(dict(options, expected_source_ids=baseline_sources),
                target, manifest, receipt_path, result['receipt_sha256'], before, preflight_checkpoint)
            if common.sha256(receipt_path) != result['receipt_sha256']:
                raise DrillError('INSTALL_RECEIPT_CHANGED_BEFORE_CRASH')
            # Persist intent first, so interruption does not lose the failed attempt.
            attempt['status'] = 'SignalRequested'
            common.atomic_json(path, result)
            signalled, signalled_mono = scoped_crash(target, manifest, before, role)
            attempt['signal_identity'] = signalled
            attempt.update(status='AwaitingRecovery', signalled_at=common.utc())
            common.atomic_json(path, result)
            print(json.dumps({'run_id': run_id, 'role': role, 'state': 'AwaitingRecovery', 'budget_seconds': budget}), flush=True)

            def checkpoint(progress):
                attempt['recovery_progress'] = progress
                common.atomic_json(path, result)

            attempt['recovery'] = await_recovery(target, manifest, before, owned, role, budget, checkpoint, signalled_mono)
            if args.process_only:
                attempt['status'] = 'AwaitingVisibleGUIWithoutVideoAcceptance'
                attempt['gui_readiness'] = []
                common.atomic_json(path, result)
                print(json.dumps({'run_id': run_id, 'role': role, 'state': attempt['status'], 'timeout_seconds': 30}), flush=True)

                def gui_checkpoint(evidence):
                    attempt['gui_readiness'].append(evidence)
                    common.atomic_json(path, result)

                observed = await_visible_observation(dict(options, expected_source_ids=baseline_sources), target,
                    manifest, attempt['recovery']['after'], gui_checkpoint)
                attempt['video_acceptance'] = 'FailedOrUnverified'
            else:
                attempt['status'] = 'ObservingFreshVideo'
                common.atomic_json(path, result)
                print(json.dumps({'run_id': run_id, 'role': role, 'state': 'ObservingFreshVideo', 'seconds': 150}), flush=True)
                observed = runtime.verify(dict(options, mode='verify', observe_seconds=150, observation_timeout=240,
                                               expected_source_ids=baseline_sources),
                                          {'target': target, 'manifest': manifest, 'run_id': run_id})
            attempt['runtime'] = observed
            if not args.process_only and (observed['runtime_health'] != 'ProcessVerified' or observed['gui_video'] != 'VisibleAndPerSourceVideoObserved'):
                raise DrillError('FRESH_POST_RECOVERY_VIDEO_NOT_VERIFIED')
            final_graph, _, _ = stable_graph(target, manifest)
            if not same_graph(attempt['recovery']['after'], observed['process_evidence']) or not same_graph(attempt['recovery']['after'], final_graph):
                raise DrillError('RECOVERED_PROCESS_GENERATION_CHANGED_DURING_VIDEO_PROOF')
            install.verify_app_inventory(target['path'], manifest)
            if common.sha256(receipt_path) != result['receipt_sha256']:
                raise DrillError('INSTALL_RECEIPT_CHANGED_DURING_DRILL')
            attempt.update(status='PassedProcessRecovery_VideoAcceptanceFailed' if args.process_only else 'PassedMeasuredRecovery', completed_at=common.utc())
            common.atomic_json(path, result)
        result['status'] = 'PassedProcessRecovery_VideoAcceptanceFailed' if args.process_only else 'PassedMeasuredRecovery'
        result['video_acceptance'] = 'Failed' if args.process_only else 'Observed150SecondsAfterEachRecovery'
        return_code = common.EXITS['verification'] if args.process_only else 0
    except BaseException as exc:
        result['status'] = 'Failed'
        result['failure'] = {'type': type(exc).__name__, 'code': str(exc) if isinstance(exc, DrillError) else getattr(exc, 'finding', 'UNEXPECTED_OR_INTERRUPTED_TEST')}
        if result['attempts']:
            result['attempts'][-1]['status'] = 'Failed'
        return_code = 1
    result['completed_at'] = common.utc()
    common.atomic_json(path, result)
    print(json.dumps({'status': result['status'], 'evidence': str(path), 'full_acceptance': False}), flush=True)
    return return_code


if __name__ == '__main__':
    raise SystemExit(main())
