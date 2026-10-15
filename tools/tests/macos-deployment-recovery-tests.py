#!/usr/bin/env python3
"""Pure mocked crash-drill tests: never sends a signal or changes launchd."""
import importlib.util
import os
from pathlib import Path
import json
import tempfile
import types
import unittest
from unittest import mock

path = Path(__file__).with_name('macos-deployment-recovery.py')
spec = importlib.util.spec_from_file_location('recovery_drill', path)
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)


def row(pid, path, ppid=1, birth=None, uid=None, session=1):
    return {'pid': pid, 'path': path, 'ppid': ppid, 'birth': birth or [100, pid],
            'uid': os.geteuid() if uid is None else uid, 'session': session}


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.app = row(10, '/owned.app/app', 20)
        self.warden = row(20, '/owned.app/warden')
        self.guardian = row(21, '/owned.app/warden', 20)
        self.before = {'state': 'ProcessVerified', 'duplicates': False, 'app': self.app,
                       'warden': self.warden, 'guardian': self.guardian,
                       'processes': [self.app, self.warden, self.guardian]}
        self.target = {'uid': os.geteuid()}
        self.after_app = row(11, self.app['path'], 20)
        self.clock = 0

    def sleep(self, seconds):
        self.clock += seconds

    def observation(self, visibility='Visible', video='Failed', graph=None):
        return {'runtime_health': 'ProcessVerified', 'gui_visibility': visibility,
                'gui_video': video, 'process_evidence': graph or self.before,
                'samples': [{'sources': [{'id': '%064x' % i, 'frames': 4, 'age_ms': 60000}
                                        for i in range(1, 4)]}]}

    def test_process_only_never_relaxes_visible_native_graph_gate(self):
        failed_video = self.observation()
        d.require_visible_observation(failed_video, self.before, require_video=False)
        self.assertEqual(failed_video['gui_video'], 'Failed')
        with self.assertRaisesRegex(d.DrillError, 'HEALTHY_BASELINE'):
            d.require_visible_observation(failed_video, self.before, require_video=True)
        for changes in ({'gui_visibility': 'NotObserved'}, {'runtime_health': 'Unverified'},
                        {'process_evidence': dict(self.before, duplicates=True)},
                        {'process_evidence': dict(self.before, app=self.after_app)}):
            with self.subTest(fields=list(changes)), self.assertRaises(d.DrillError):
                d.require_visible_observation(dict(failed_video, **changes), self.before)

    def test_degraded_video_source_hashes_are_pinned_without_health_claim(self):
        observed = self.observation()
        self.assertEqual(d.initial_source_ids(observed, 3), ['%064x' % i for i in range(1, 4)])
        self.assertEqual(observed['gui_video'], 'Failed')
        observed['samples'][-1]['sources'][1]['id'] = '%064x' % 1
        self.assertIsNone(d.initial_source_ids(observed, 3))
        self.assertIsNone(d.initial_source_ids({'samples': []}, 3))

    def test_every_presignal_check_requires_inventory_receipt_graph_and_gui(self):
        target = dict(self.target, path=Path('/owned.app'))
        with mock.patch.object(d.install, 'verify_app_inventory') as inventory, \
                mock.patch.object(d.common, 'sha256', return_value='expected') as receipt, \
                mock.patch.object(d.runtime, 'verify', return_value=self.observation()) as observe:
            result = d.verify_before_signal({'process_only': True}, target, {}, Path('/receipt'), 'expected', self.before)
            self.assertEqual(result['gui_video'], 'Failed')
            inventory.assert_called_once_with(target['path'], {})
            receipt.assert_called_once_with(Path('/receipt'))
            self.assertEqual(observe.call_args.args[0]['observe_seconds'], 0)
            receipt.return_value = 'changed'
            observe.reset_mock()
            with self.assertRaisesRegex(d.DrillError, 'RECEIPT_CHANGED'):
                d.verify_before_signal({'process_only': True}, target, {}, Path('/receipt'), 'expected', self.before)
            observe.assert_not_called()
            receipt.return_value = 'expected'
            inventory.side_effect = RuntimeError('corrupt inventory')
            with self.assertRaisesRegex(RuntimeError, 'corrupt inventory'):
                d.verify_before_signal({'process_only': True}, target, {}, Path('/receipt'), 'expected', self.before)
            observe.assert_not_called()

    def test_gui_readiness_is_bounded_retains_failure_and_does_not_require_video(self):
        observations = [self.observation('NotObserved', 'Unverified'), self.observation('Visible', 'Failed')]
        retained = []
        with mock.patch.object(d.runtime, 'verify', side_effect=observations), \
                mock.patch.object(d.time, 'monotonic', side_effect=lambda: self.clock), \
                mock.patch.object(d.time, 'sleep', side_effect=self.sleep):
            result = d.await_visible_observation({}, {}, {}, self.before, retained.append, timeout=1)
        self.assertEqual(result['gui_video'], 'Failed')
        self.assertEqual([row['observation']['gui_video'] for row in retained], ['Unverified', 'Failed'])
        self.assertEqual(self.clock, .5)

    def test_failed_presignal_observation_is_retained_before_refusal(self):
        retained = []
        with mock.patch.object(d.install, 'verify_app_inventory'), \
                mock.patch.object(d.common, 'sha256', return_value='expected'), \
                mock.patch.object(d.runtime, 'verify', return_value=self.observation('NotObserved')), \
                mock.patch.object(d.os, 'kill') as kill, \
                self.assertRaisesRegex(d.DrillError, 'VISIBLE_NATIVE_PROCESS'):
            d.verify_before_signal({'process_only': True}, dict(self.target, path=Path('/owned.app')), {},
                                   Path('/receipt'), 'expected', self.before, retained.append)
        self.assertEqual(len(retained), 1)
        self.assertEqual(retained[0]['gui_visibility'], 'NotObserved')
        kill.assert_not_called()

    def test_gui_readiness_timeout_or_changed_graph_fails(self):
        for observation, error in ((self.observation('NotObserved'), 'GUI_READINESS_TIMEOUT'),
                                   (self.observation(graph=dict(self.before, app=self.after_app)), 'GRAPH_CHANGED')):
            self.clock = 0
            retained = []
            with mock.patch.object(d.runtime, 'verify', return_value=observation), \
                    mock.patch.object(d.time, 'monotonic', side_effect=lambda: self.clock), \
                    mock.patch.object(d.time, 'sleep', side_effect=self.sleep), \
                    self.assertRaisesRegex(d.DrillError, error):
                d.await_visible_observation({}, {}, {}, self.before, retained.append, timeout=1)
            self.assertTrue(retained)

    def test_process_only_main_retains_degraded_evidence_and_incomplete_exit(self):
        with tempfile.TemporaryDirectory(prefix='mocked process recovery ') as temp:
            root = Path(temp).resolve()
            receipt = root / 'receipt.json'
            receipt.write_text('{}')
            target = dict(self.target, uid=501, path=root/'owned.app', support=root, home=root, id='fixture')
            graph = {**self.before}
            for role in ('app', 'warden', 'guardian'):
                graph[role] = dict(graph[role], uid=501)
            observed = self.observation(graph=graph)
            actual_stat = Path.stat
            def console_stat(path, *args, **kwargs):
                return types.SimpleNamespace(st_uid=501) if str(path) == '/dev/console' else actual_stat(path, *args, **kwargs)
            with mock.patch.object(d.platform, 'system', return_value='Darwin'), \
                    mock.patch.object(d.os, 'geteuid', return_value=501), \
                    mock.patch.object(d.os, 'kill') as real_kill, \
                    mock.patch.object(Path, 'stat', console_stat), \
                    mock.patch.object(d.common, 'host_identity', return_value={'machine_id': 'fixture-host'}), \
                    mock.patch.object(d.install, 'resolve_target', return_value=target), \
                    mock.patch.object(d.install, 'verify', return_value={'installation':'FilesVerified','versions':{}}), \
                    mock.patch.object(d.install, 'verify_app_inventory') as inventory, \
                    mock.patch.object(d.runtime, '_private_json', return_value={}), \
                    mock.patch.object(d.runtime, '_manifest', return_value={}), \
                    mock.patch.object(d.runtime, 'verify', return_value=observed) as verify, \
                    mock.patch.object(d, 'stable_graph', return_value=(graph, [], {'processes':[]})), \
                    mock.patch.object(d, 'scoped_crash', return_value=(graph['app'], 0)) as crash, \
                    mock.patch.object(d, 'await_recovery', return_value={'after':graph,'recovery_seconds':1}), \
                    mock.patch('builtins.print'):
                code = d.main(['--install-dir',str(target['path']),'--desktop-user','fixture',
                    '--test-mac-id','fixture-host','--expected-cameras','3','--evidence-dir',str(root/'evidence'),
                    '--process-only','--crash-app','--crash-warden'])
            real_kill.assert_not_called()
            self.assertEqual(crash.call_count, 2)
            self.assertGreaterEqual(inventory.call_count, 4)
            self.assertTrue(all(call.args[0]['observe_seconds'] == 0 for call in verify.call_args_list))
            self.assertEqual(code, d.common.EXITS['verification'])
            result = json.loads(next((root/'evidence').glob('*/result.json')).read_text())
            self.assertEqual(result['status'], 'PassedProcessRecovery_VideoAcceptanceFailed')
            self.assertEqual(result['video_acceptance'], 'Failed')
            self.assertFalse(result['full_acceptance'])
            self.assertEqual(result['initial_runtime']['gui_video'], 'Failed')
            self.assertEqual(len(result['expected_source_ids']), 3)
            self.assertTrue(all(a['before_runtime']['gui_video'] == a['runtime']['gui_video'] == 'Failed' for a in result['attempts']))

    def evidence(self, target, manifest, rows, **kwargs):
        apps = [entry for entry in rows if entry['path'] == self.app['path']]
        owners = [entry for entry in rows if entry['path'] == self.warden['path'] and entry['ppid'] == 1]
        guardians = [entry for entry in rows if entry['path'] == self.warden['path'] and entry['ppid'] != 1]
        verified = len(apps) == 1 and len(owners) == 1 and len(guardians) == 1
        return {'state': 'ProcessVerified' if verified else 'Unverified',
                'duplicates': len(apps) > 1 or len(owners) > 1, 'processes': rows,
                'app': apps[0] if apps else None, 'warden': owners[0] if owners else None,
                'guardian': guardians[0] if guardians else None}

    def recovery(self, snapshots, owned=None, role='app', budget=45, start=None):
        with mock.patch.object(d.runtime, 'process_snapshot', side_effect=snapshots), \
             mock.patch.object(d.native, 'process_identity', return_value=None), \
             mock.patch.object(d.runtime, 'process_evidence', side_effect=self.evidence), \
             mock.patch.object(d.time, 'monotonic', side_effect=lambda: self.clock), \
             mock.patch.object(d.time, 'sleep', side_effect=self.sleep):
            return d.await_recovery(self.target, {}, self.before, owned or [self.app], role, budget, started_at=start)

    def test_app_recovery_preserves_owner_and_guardian(self):
        result = self.recovery([[self.warden, self.guardian], [self.after_app, self.warden, self.guardian]])
        self.assertEqual(result['status'], 'Recovered')
        self.assertEqual(result['recovery_seconds'], .05)
        self.assertTrue(result['old_owned_processes_gone'])

    def test_replacement_app_must_not_overlap_old_detached_descendant(self):
        descendant = row(99, '/helper', 1, session=99)
        with self.assertRaisesRegex(d.DrillError, 'OVERLAP'):
            self.recovery([[self.after_app, self.warden, self.guardian, descendant]], [self.app, descendant])

    def test_application_recovery_must_not_change_guardian(self):
        replacement = row(22, '/owned.app/warden', 20)
        with self.assertRaisesRegex(d.DrillError, 'SUPERVISOR_CHANGED'):
            self.recovery([[self.after_app, self.warden, replacement]])

    def test_warden_recovery_requires_old_graph_gone(self):
        owner, guard = row(30, '/owned.app/warden'), row(31, '/owned.app/warden', 30)
        app = row(12, '/owned.app/app', 30)
        result = self.recovery([[], [app, owner, guard]], self.before['processes'], role='warden', budget=60)
        self.assertEqual(result['after']['warden']['pid'], 30)
        with self.assertRaisesRegex(d.DrillError, 'OVERLAP'):
            self.recovery([[app, owner, guard, self.guardian]], self.before['processes'], role='warden', budget=60)

    def test_budget_includes_time_since_signal_not_since_wait(self):
        self.clock = 46
        with self.assertRaisesRegex(d.DrillError, 'BUDGET_EXCEEDED'):
            self.recovery([[self.after_app, self.warden, self.guardian]], start=0)

    def test_pid_reuse_does_not_keep_old_process_alive(self):
        reused = dict(self.app, birth=[200, 9])
        self.assertFalse(d.row_still_present(self.app, [reused]))

    def test_exec_or_session_change_does_not_prove_old_process_gone(self):
        changed = dict(self.app, path='/another-executable', session=987)
        self.assertTrue(d.row_still_present(self.app, [changed]))

    def test_unreadable_known_process_cannot_be_cleanup_success(self):
        with mock.patch.object(d.native, 'process_identity', side_effect=PermissionError('fixture')):
            with self.assertRaises(PermissionError):
                d.complete_known_identities([], [self.app])

    def test_observed_descendants_include_recorded_detached_and_reject_foreign(self):
        detached = row(99, '/helper', 1, session=99)
        child = row(90, '/child-helper', self.app['pid'])
        foreign = row(91, '/other-user', self.app['pid'], uid=os.geteuid() + 1)
        reused = row(92, '/reused', 1, birth=[202, 1])
        old = dict(reused, birth=[201, 1])
        rows = [self.app, detached, child, foreign, reused]
        owned = d.observed_descendants([self.app], rows, [detached, foreign, old])
        self.assertEqual({entry['pid'] for entry in owned}, {10, 90, 99})

    def test_signal_rejects_changed_process_and_never_calls_kill(self):
        changed = dict(self.before, app=dict(self.app, birth=[500, 1]))
        with mock.patch.object(d, 'graph', return_value=(changed, [], {})), mock.patch.object(d.os, 'kill') as kill:
            with self.assertRaisesRegex(d.DrillError, 'IDENTITY_CHANGED'):
                d.scoped_crash(self.target, {}, self.before, 'app')
            kill.assert_not_called()

    def test_signal_rechecks_final_graph_and_sends_one_exact_signal(self):
        with mock.patch.object(d, 'graph', return_value=(self.before, self.before['processes'], {})), \
             mock.patch.object(d.runtime, 'process_snapshot', return_value=self.before['processes']), \
             mock.patch.object(d.runtime, 'process_evidence', return_value=self.before), \
             mock.patch.object(d.os, 'kill') as kill:
            chosen, started = d.scoped_crash(self.target, {}, self.before, 'app')
            self.assertEqual(chosen, self.app)
            self.assertIsInstance(started, float)
            kill.assert_called_once_with(self.app['pid'], d.signal.SIGKILL)

    def test_final_guardian_change_refuses_signal(self):
        changed = dict(self.before, guardian=row(33, '/owned.app/warden', 20))
        with mock.patch.object(d, 'graph', return_value=(self.before, self.before['processes'], {})), \
             mock.patch.object(d.runtime, 'process_snapshot', return_value=self.before['processes']), \
             mock.patch.object(d.runtime, 'process_evidence', return_value=changed), \
             mock.patch.object(d.os, 'kill') as kill:
            with self.assertRaisesRegex(d.DrillError, 'SUPERVISOR_GRAPH_CHANGED'):
                d.scoped_crash(self.target, {}, self.before, 'app')
            kill.assert_not_called()


if __name__ == '__main__':
    unittest.main(verbosity=2)
