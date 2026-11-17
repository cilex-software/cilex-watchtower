"""GUI recovery over temporary bundles; no real launchd or installed app changes."""
import json
import contextlib
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_install
import finder_update as update
import install
import recovery
import build


class UpdateRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_install.InstallerTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.addCleanup(self.fixture.tearDown)
        self.target, self.manifest, self.package, self.context, self.record, self.state, self.job = self.fixture.resume_fixture()
        self.state.update(phase='rollback_failed', original_failure={'finding': 'command.failed', 'message': 'fixture bootstrap failure'})
        self.options = {'_finder_update': True}
        self.state['options_sha256'] = install.digest(install.requested_transaction(self.options))
        install.atomic_json(self.record, self.state)
        self.commands = mock.patch.object(install, 'execute').start()
        self.ui = mock.patch.object(update, 'dialog', return_value=True).start()
        mock.patch.object(update, 'language', return_value='en').start()
        self.prepare = mock.patch.object(update, 'update_options', side_effect=lambda *a: dict(self.options)).start()
        mock.patch.object(install, 'security_check', return_value='DevelopmentOnly').start()
        mock.patch.object(install, 'job_state', return_value=self.job).start()
        mock.patch.object(install, 'register_bundle').start()
        mock.patch.object(install, 'selected_processes', return_value=[]).start()
        mock.patch.object(install, 'verify_processes', return_value={'state': 'Unverified', 'processes': []}).start()
        self.addCleanup(mock.patch.stopall)

    def test_restore_uses_original_journal_and_actually_restores_old_bundle(self):
        self.assertEqual((self.target['path'] / 'Contents/payload').read_text(), 'new-version')
        self.assertTrue(update.recover_interrupted(self.target))
        self.assertEqual((self.target['path'] / 'Contents/payload').read_text(), 'old-version')
        result = json.loads(self.record.read_text())
        self.assertEqual(result['phase'], 'rolled_back_runtime_unverified')
        self.assertEqual(result['result']['original_failure'], self.state['original_failure'])
        preserved = list(Path(self.state['staging']).glob('interrupted-replacement-*.app'))
        self.assertEqual(len(preserved), 1)
        self.assertEqual((preserved[0] / 'Contents/payload').read_text(), 'new-version')
        # Its original job was stopped, so recovery must not bootstrap it.
        self.assertFalse(any(call.args[0][0] == '/bin/launchctl' for call in self.commands.call_args_list))

    def test_cancel_preserves_record_app_and_backup_without_native_commands(self):
        self.ui.return_value = False
        before = self.record.read_bytes()
        self.assertTrue(update.recover_interrupted(self.target))
        self.assertEqual(self.record.read_bytes(), before)
        self.assertEqual((self.target['path'] / 'Contents/payload').read_text(), 'new-version')
        self.assertTrue((Path(self.state['staging']) / 'previous.app').is_dir())
        self.commands.assert_not_called()

    def test_changed_backup_is_rejected_before_consent_or_native_command(self):
        (Path(self.state['staging']) / 'previous.app/Contents/payload').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'fingerprint'):
            update.recover_interrupted(self.target)
        self.ui.assert_not_called()
        self.commands.assert_not_called()

    def test_foreign_target_record_is_rejected_before_any_action(self):
        self.state['target_uid'] += 1
        install.atomic_json(self.record, self.state)
        with self.assertRaisesRegex(ValueError, 'different identity'):
            update.recover_interrupted(self.target)
        self.commands.assert_not_called()

    def test_different_original_options_cannot_be_reconstructed_by_guessing(self):
        self.options['backend_url'] = 'https://different.invalid'
        with self.assertRaisesRegex(ValueError, 'different options'):
            update.recover_interrupted(self.target)
        self.ui.assert_not_called()
        self.commands.assert_not_called()

    def test_record_changed_during_consent_cannot_trigger_recovery(self):
        def consent(*args, **kwargs):
            value = dict(self.state, phase='installed')
            install.atomic_json(self.record, value)
            return True
        self.ui.side_effect = consent
        with self.assertRaisesRegex(ValueError, 'record changed'):
            update.recover_interrupted(self.target)
        self.assertEqual((self.target['path'] / 'Contents/payload').read_text(), 'new-version')

    def test_completed_record_does_not_offer_recovery(self):
        self.state['phase'] = 'installed'
        install.atomic_json(self.record, self.state)
        self.assertFalse(update.recover_interrupted(self.target))
        self.ui.assert_not_called()
        self.commands.assert_not_called()


class RecoveryEntryTests(unittest.TestCase):
    def test_no_installed_copy_reports_error_without_entering_recovery(self):
        with mock.patch.object(update, 'installed_target', return_value=None), \
             mock.patch.object(update, 'dialog') as dialog, mock.patch.object(update, 'recover_interrupted') as restore:
            self.assertEqual(recovery.main(), 1)
        restore.assert_not_called()
        self.assertIn('No installed Watchtower', dialog.call_args.args[0])

    def test_standalone_entry_holds_shared_lock_and_delegates_consent(self):
        target = {'path': Path('/fixture/watchtower.app')}
        with mock.patch.object(update, 'installed_target', return_value=target), \
             mock.patch.object(recovery.first_launch, 'launch_lock', return_value=contextlib.nullcontext()) as lock, \
             mock.patch.object(update, 'recover_interrupted', return_value=True) as restore, \
             mock.patch.object(update, 'dialog') as dialog:
            self.assertEqual(recovery.main(), 0)
        lock.assert_called_once_with(target)
        restore.assert_called_once_with(target)
        dialog.assert_not_called()

    def test_completed_update_reports_no_recovery_needed(self):
        with mock.patch.object(update, 'installed_target', return_value={}), \
             mock.patch.object(recovery.first_launch, 'launch_lock', return_value=contextlib.nullcontext()), \
             mock.patch.object(update, 'recover_interrupted', return_value=False), \
             mock.patch.object(update, 'dialog') as dialog:
            self.assertEqual(recovery.main(), 0)
        self.assertIn('No interrupted update', dialog.call_args.args[0])

    def test_build_accepts_only_the_two_owned_entry_points(self):
        with self.assertRaisesRegex(build.BuildError, 'Unknown frozen helper'):
            build.freeze_setup(None, None, None, {}, {}, None, '26.0', entry='../foreign.py')


if __name__ == '__main__': unittest.main()
