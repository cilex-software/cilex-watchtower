"""Inert launchd transitions: fake command replies, process identities and clock."""
from pathlib import Path
import sys
import types
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import install


def reply(code=0, stdout='', stderr=''):
    return types.SimpleNamespace(returncode=code, stdout=stdout, stderr=stderr)


class LaunchdLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.target = {'path': Path('/fixture/Applications/watchtower.app'), 'uid': 501,
                       'domain': 'gui/501', 'label': 'com.cilexvision.watchtower.fixture',
                       'agent': Path('/fixture/agent.plist')}
        self.manifest = {'app': 'watchtower.app', '_executable': 'watchtower',
                         'warden': 'watchtower.app/Contents/Resources/warden/cilex-warden'}
        self.loaded = {'loaded': True, 'pid': 77, 'disabled': False,
                       'disabled_explicit': False, 'gui_session': True}
        self.absent = dict(self.loaded, loaded=False, pid=None)
        self.row = {'pid': 77, 'uid': 501, 'ppid': 1,
                    'path': str(self.target['path'] / 'Contents/Resources/warden/cilex-warden')}
        self.now = 0
        def sleep(seconds): self.now += seconds
        self.patches = [mock.patch.object(install.time, 'monotonic', side_effect=lambda: self.now),
                        mock.patch.object(install.time, 'sleep', side_effect=sleep)]
        for patch in self.patches:
            patch.start(); self.addCleanup(patch.stop)

    def test_command_failure_contains_operation_exit_and_redacted_stderr(self):
        with mock.patch.object(install.subprocess, 'run', return_value=reply(5,
                stderr='Bootstrap failed: 5: Input/output error password=fixture-secret')):
            with self.assertRaises(install.InstallError) as failure:
                install.execute(['/bin/launchctl', 'bootstrap', 'gui/501', '/fixture/agent.plist'])
        error = failure.exception
        self.assertIn('bootstrap', str(error))
        self.assertIn('exit 5', str(error))
        self.assertNotIn('fixture-secret', str(error))
        record = install.failure_record(error, 'test')
        self.assertEqual(record['details']['exit'], 5)
        self.assertIn('Input/output error', record['details']['diagnostic'])

    def test_inaccessible_domain_is_never_reported_as_unloaded(self):
        with mock.patch.object(install, 'execute', side_effect=[reply(141), reply(141, stderr='Reentrancy avoided')]):
            with self.assertRaisesRegex(install.InstallError, 'Reentrancy avoided'):
                install.job_state(self.target)

    def test_absent_service_in_accessible_domain_is_distinguished_from_query_failure(self):
        with mock.patch.object(install, 'execute', side_effect=[
                reply(113, stderr='Could not find service "fixture" in domain for user gui: 501'),
                reply(), reply(stdout='disabled services = {}')]):
            state = install.job_state(self.target)
        self.assertFalse(state['loaded'])
        self.assertTrue(state['gui_session'])

    def test_disabled_policy_query_error_is_not_assumed_enabled(self):
        with mock.patch.object(install, 'execute', side_effect=[reply(), reply(),
                reply(1, stderr='Permission denied')]):
            with self.assertRaisesRegex(install.InstallError, 'Permission denied'):
                install.job_state(self.target)

    def test_waits_for_job_removal_after_process_has_exited(self):
        with mock.patch.object(install, 'job_state', side_effect=[self.loaded, self.loaded, self.absent]) as state:
            install.wait_job_unloaded(self.target)
        self.assertEqual(state.call_count, 3)
        self.assertGreater(self.now, 0)

    def test_stuck_unloading_is_bounded_and_signals_nothing(self):
        with mock.patch.object(install, 'job_state', return_value=self.loaded), \
             mock.patch.object(install, 'execute') as commands:
            with self.assertRaises(install.InstallError) as failure:
                install.wait_job_unloaded(self.target, timeout=1)
        self.assertEqual(failure.exception.finding, 'startup.unload_timeout')
        commands.assert_not_called()

    def test_stale_exited_pid_waits_for_absent_job(self):
        with mock.patch.object(install, 'job_state', side_effect=[self.loaded, self.absent]), \
             mock.patch.object(install, 'process_snapshot', return_value=[]), \
             mock.patch.object(install, 'execute') as commands:
            self.assertFalse(install.settled_job_state(self.target, self.manifest)['loaded'])
        commands.assert_not_called()

    def test_env_launcher_must_exec_into_owned_warden_before_returning(self):
        env = dict(self.row, path='/usr/bin/env')
        with mock.patch.object(install, 'job_state', return_value=self.loaded), \
             mock.patch.object(install, 'process_snapshot', side_effect=[[env], [self.row], [self.row]]):
            self.assertEqual(install.settled_job_state(self.target, self.manifest), self.loaded)
        self.assertGreater(self.now, 0)

    def test_foreign_pid_is_refused_without_signal_or_retry(self):
        with mock.patch.object(install, 'job_state', return_value=self.loaded), \
             mock.patch.object(install, 'process_snapshot', return_value=[dict(self.row, uid=502)]), \
             mock.patch.object(install, 'execute') as commands:
            with self.assertRaises(install.InstallError) as failure:
                install.settled_job_state(self.target, self.manifest)
        self.assertEqual(failure.exception.finding, 'runtime.job_identity')
        self.assertEqual(self.now, 0)
        commands.assert_not_called()

    def test_stale_pid_does_not_get_ignored_on_timeout(self):
        with mock.patch.object(install, 'job_state', return_value=self.loaded), \
             mock.patch.object(install, 'process_snapshot', return_value=[]):
            with self.assertRaises(install.InstallError) as failure:
                install.settled_job_state(self.target, self.manifest, timeout=1)
        self.assertEqual(failure.exception.finding, 'startup.identity_timeout')

    def test_transient_bootstrap_teardown_error_retries_only_after_job_absence(self):
        with mock.patch.object(install, 'execute', side_effect=[reply(5, stderr='Input/output error'), reply()]) as cmd, \
             mock.patch.object(install, 'settled_job_state', return_value=self.absent):
            install.bootstrap_job(self.target, self.manifest)
        self.assertEqual(cmd.call_count, 2)
        self.assertEqual(self.now, .5)

    def test_permanent_bootstrap_error_is_preserved_without_retry(self):
        with mock.patch.object(install, 'execute', return_value=reply(13, stderr='Permission denied')) as cmd:
            with self.assertRaises(install.InstallError) as failure:
                install.bootstrap_job(self.target, self.manifest)
        self.assertEqual(cmd.call_count, 1)
        self.assertEqual(failure.exception.details['attempts'][0]['exit'], 13)

    def test_bootstrap_error_with_registered_job_requires_verified_processes(self):
        with mock.patch.object(install, 'execute', return_value=reply(5, stderr='Already in progress')) as cmd, \
             mock.patch.object(install, 'settled_job_state', return_value=self.loaded), \
             mock.patch.object(install, 'process_snapshot', return_value=[self.row]), \
             mock.patch.object(install, 'wait_processes', side_effect=install.InstallError('runtime.timeout', 'not started')):
            with self.assertRaises(install.InstallError):
                install.bootstrap_job(self.target, self.manifest)
        self.assertEqual(cmd.call_count, 1)

    def test_repeated_transient_failure_is_bounded_and_retains_each_diagnostic(self):
        with mock.patch.object(install, 'execute', return_value=reply(5, stderr='Still unloading')) as cmd, \
             mock.patch.object(install, 'settled_job_state', return_value=self.absent):
            with self.assertRaises(install.InstallError) as failure:
                install.bootstrap_job(self.target, self.manifest, timeout=1)
        self.assertEqual(cmd.call_count, 3)
        self.assertEqual(len(failure.exception.details['attempts']), 3)
        self.assertLessEqual(self.now, 1)


if __name__ == '__main__': unittest.main()
