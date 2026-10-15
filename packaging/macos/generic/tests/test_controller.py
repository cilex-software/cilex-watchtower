import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import common
import deploy
import source


class ControllerTests(unittest.TestCase):
    def options(self, *args):
        return deploy.normalize(deploy.parser().parse_args(['--language', 'en', *args]))

    def test_readonly_dispatch_cannot_create_journal_or_build(self):
        for mode in deploy.MODES:
            options = self.options('--mode', mode, '--dry-run')
            with mock.patch.object(deploy, 'assessment', return_value={}) as assess, mock.patch.object(deploy, 'RunRecord', side_effect=AssertionError('mutation')), mock.patch.object(deploy.build, 'build', side_effect=AssertionError('build')):
                value, record = deploy.execute(options)
                self.assertIsNone(record)
                assess.assert_called_once()

    def test_verify_no_journal(self):
        with mock.patch.object(deploy.install, 'verify', return_value={}), mock.patch('runtime.verify', return_value={}), mock.patch.object(deploy, 'host_identity', return_value={}), mock.patch.object(deploy, 'RunRecord', side_effect=AssertionError('mutation')):
            value, record = deploy.execute(self.options('--mode', 'verify'))
            self.assertIsNone(record)
            self.assertEqual(value['states']['startup'], 'Unverified')

    def test_uninstall_receives_protected_run_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            options = self.options('--mode', 'uninstall', '--work-dir', str(Path(tmp) / 'runs'))
            with mock.patch.object(deploy, 'host_identity', return_value={'machine_id': 'fixture', 'uid': os.geteuid()}), mock.patch.object(deploy, 'helper_hash', return_value='fixture-helper'), mock.patch.object(deploy.install, 'uninstall', return_value={'installation': 'Uninstalled'}) as uninstall:
                value, record = deploy.execute(options)
                try:
                    uninstall.assert_called_once_with(options, {'run_id': record.data['run_id']})
                    self.assertEqual(value['exit_code'], 0)
                finally:
                    record.close()

    def test_completed_uninstall_resume_reconciles_its_journal(self):
        with tempfile.TemporaryDirectory() as tmp:
            arguments = ['--mode', 'uninstall', '--work-dir', str(Path(tmp) / 'runs')]
            with mock.patch.object(deploy, 'host_identity', return_value={'machine_id': 'fixture', 'uid': os.geteuid()}), mock.patch.object(deploy, 'helper_hash', return_value='fixture-helper'), mock.patch.object(deploy.install, 'uninstall', return_value={'installation': 'Uninstalled'}) as uninstall, mock.patch.object(deploy.install, 'verify', side_effect=AssertionError('uninstall requires its own journal reconciliation')):
                first, record = deploy.execute(self.options(*arguments))
                identity = record.data['run_id']
                record.close()
                resumed, record = deploy.execute(self.options(*arguments, '--resume', identity))
                try:
                    self.assertEqual(resumed['exit_code'], 0)
                    self.assertEqual(resumed['resume_action'], 'UninstallJournalAndCurrentAbsenceReconciled')
                    self.assertEqual(uninstall.call_count, 2)
                    self.assertEqual(uninstall.call_args.args[1], {'run_id': identity})
                finally:
                    record.close()

    def test_fatal_override_cannot_be_accepted(self):
        for finding in ('security.integrity', 'runtime.architecture', 'transaction.space', 'transaction.authorization', 'invented.finding'):
            with self.assertRaises(common.DeployError) as caught:
                self.options('--accept-findings', finding)
            self.assertEqual(caught.exception.finding, 'override.forbidden')

    def test_advisory_acceptance_is_explicit(self):
        options = self.options('--accept-findings', 'runtime.capacity-unmeasured,build.local-dependency-receipt')
        self.assertEqual(len(options['accept_findings']), 2)

    def test_non_arm64_blocked(self):
        for architecture in ('x86_64', 'universal2'):
            with self.assertRaises(common.DeployError):
                self.options('--arch', architecture)

    def test_no_success_for_registration(self):
        value = common.result()
        value['states'].update(installation='Installed', runtime_health='ProcessVerified', startup='StartupUnverified')
        self.assertEqual(deploy.exit_for(value, 'install'), common.EXITS['pending'])

    def test_observation_preserves_pending_and_blocked_startup(self):
        for status in ('PendingDisabledStartup', 'PendingGraphicalLogin', 'BlockedUnattendedRebootUnverified'):
            value = common.result()
            value['states']['startup'] = status
            deploy.merge_result(value, {'startup': 'StartupUnverified'})
            self.assertEqual(value['states']['startup'], status)

    def test_readonly_assessment_preserves_explicit_unattended_blockers(self):
        target = {'path': Path('/fixture/watchtower.app'), 'user': 'fixture', 'uid': 501, 'id': 'fixture-installation', 'domain': 'gui/501'}
        startup = {'filevault': 'On', 'automatic_login': 'NotConfigured', 'blockers': [{'id': 'startup.filevault_on'}]}
        installed = {'startup': 'BlockedUnattendedRebootUnverified', 'startup_evidence': startup}
        values = {'hw.optional.arm64': '1', 'sysctl.proc_translated': '0', 'hw.memsize': str(8 * 1024**3), 'hw.ncpu': '4'}
        with mock.patch.object(deploy.platform, 'system', return_value='Darwin'), mock.patch.object(deploy, 'sysctl', side_effect=values.get), mock.patch.object(deploy, 'command', return_value=types.SimpleNamespace(stdout='fixture-build')), mock.patch.object(deploy, 'host_identity', return_value={}), mock.patch.object(deploy.ctypes, 'CDLL'), mock.patch.object(deploy.install, 'resolve_target', return_value=target), mock.patch.object(deploy.install, 'verify', return_value=installed):
            value = deploy.assessment(self.options('--mode', 'verify', '--dry-run', '--startup', 'unattended-reboot'))
        self.assertEqual(value['states']['startup'], 'BlockedUnattendedRebootUnverified')
        self.assertEqual(value['startup_evidence'], startup)

    def test_failed_runtime_has_failure_exit(self):
        value = common.result()
        value['states']['gui_video'] = 'Failed'
        self.assertEqual(deploy.exit_for(value, 'install'), common.EXITS['verification'])

    def test_rollback_and_unknown_exit_codes(self):
        value = common.result()
        value['states'].update(installation='Unknown')
        self.assertEqual(deploy.exit_for(value, 'remote-install'), common.EXITS['unknown'])
        value['states']['rollback'] = 'Failed'
        self.assertEqual(deploy.exit_for(value, 'install'), common.EXITS['rollback'])

    def test_repository_and_backend_secret_urls_rejected(self):
        for argument in ('--repository', '--backend-url'):
            with self.assertRaises(common.DeployError):
                self.options(argument, 'https://name:secret@example.test/repo')

    def test_unicode_space_paths_preserved(self):
        options = self.options('--install-dir', '/Users/Оператор/Applications/Наблюдение зал.app')
        self.assertTrue(options['install_dir'].endswith('Наблюдение зал.app'))

    def test_invalid_missing_resume_creates_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / 'absent'
            with self.assertRaises(common.DeployError):
                common.RunRecord(base, {}, {}, 'abc', '20261013T120000Z-0000000000000000')
            self.assertFalse(base.exists())

    def test_resume_authentication_and_options_binding(self):
        with tempfile.TemporaryDirectory() as tmp:
            record = common.RunRecord(Path(tmp) / 'runs', {'scope': 'user'}, {'id': 'test'}, 'abc')
            run_id = record.data['run_id']
            with self.assertRaises(common.DeployError) as duplicate:
                common.RunRecord(Path(tmp) / 'runs', {'scope': 'user'}, {'id': 'test'}, 'abc', run_id)
            self.assertEqual(duplicate.exception.finding, 'run.concurrent')
            record.close()
            resumed = common.RunRecord(Path(tmp) / 'runs', {'scope': 'user'}, {'id': 'test'}, 'abc', run_id)
            self.assertEqual(resumed.data['run_id'], run_id)
            resumed.close()
            with self.assertRaises(common.DeployError):
                common.RunRecord(Path(tmp) / 'runs', {'scope': 'machine'}, {'id': 'test'}, 'abc', run_id)
            path = record.root / 'journal.json'
            value = json.loads(path.read_text())
            value['record']['phase'] = 'modified'
            path.write_text(json.dumps(value))
            with self.assertRaises(common.DeployError):
                common.RunRecord(Path(tmp) / 'runs', {'scope': 'user'}, {'id': 'test'}, 'abc', run_id)

    def test_secret_channel_unavailable_noninteractive(self):
        with self.assertRaises(common.DeployError):
            source.token_input({'gh_token_prompt': True, 'noninteractive': True})

    def test_selected_secret_fd_does_not_require_pipe_eof(self):
        read_fd, write_fd = os.pipe()
        try:
            os.write(write_fd, b'fixture-token\n')
            self.assertEqual(source.token_input({'gh_token_fd': read_fd}), 'fixture-token')
        finally:
            os.close(read_fd)
            os.close(write_fd)

    def test_offline_never_fetches(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(source, 'authenticated_git', side_effect=AssertionError('network')):
            with self.assertRaises(common.DeployError):
                source.obtain({'dependencies': 'offline'}, tmp)

    def test_bilingual_catalog_parity(self):
        en = common.read_json(deploy.ROOT / 'i18n/en.json')
        ru = common.read_json(deploy.ROOT / 'i18n/ru.json')
        self.assertEqual(set(en), set(ru))
        self.assertIn('Установить', ru['setup_install'])


if __name__ == '__main__':
    unittest.main()
