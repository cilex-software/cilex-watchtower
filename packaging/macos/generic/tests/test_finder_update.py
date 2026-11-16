"""Inert updater acceptance: temporary bundles and mocked launchd/native UI only."""
import contextlib
import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import types
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import finder_update as update
import first_launch
import install


class FinderUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='Cilex update тест ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.volume = self.root / 'DMG'
        self.volume.mkdir()
        (self.volume / '.deployment').mkdir()
        self.manifest = {'version': '1.2.3', 'distribution': 'development'}
        (self.volume / '.deployment/artifact-manifest.json').write_text(json.dumps(self.manifest))
        self.target = {'path': self.root / 'Applications/Cilex Watchtower.app',
                       'home': self.root, 'user': 'fixture', 'uid': os.getuid(),
                       'agent': self.root / 'agent.plist'}
        (self.target['path'] / 'Contents').mkdir(parents=True)
        (self.target['path'] / 'Contents/Info.plist').write_bytes(
            plistlib.dumps({'CFBundleShortVersionString': '1.0.0'}))
        self.ui = mock.patch.object(update, 'dialog', return_value=True).start()
        self.find = mock.patch.object(update, 'installed_target', return_value=self.target).start()
        self.lock = mock.patch.object(first_launch, 'launch_lock', side_effect=lambda _: contextlib.nullcontext()).start()
        self.prepare = mock.patch.object(update, 'update_options', return_value={
            'allow_development': True, '_finder_update': True}).start()
        self.package = mock.patch.object(update, 'package_from_volume',
            side_effect=lambda _: contextlib.nullcontext(self.volume / '.deployment')).start()
        self.run = mock.patch.object(install, 'run', return_value={'installation': 'Installed'}).start()
        self.start = mock.patch.object(first_launch, 'start_service').start()
        self.activate = mock.patch.object(first_launch, 'activate').start()
        mock.patch.object(update, 'language', return_value='en').start()
        self.addCleanup(mock.patch.stopall)

    def test_cancel_does_not_copy_replace_or_signal(self):
        self.ui.return_value = False
        self.assertEqual(update.update(self.volume), 0)
        self.package.assert_not_called()
        self.run.assert_not_called()
        self.start.assert_not_called()
        self.activate.assert_not_called()
        message = self.ui.call_args.args[0]
        for part in ('1.0.0', '1.2.3', str(self.target['path']), 'stop Warden', 'unsigned internal'):
            self.assertIn(part, message)

    def test_confirm_runs_transaction_before_restart_and_activation(self):
        order = []
        self.run.side_effect = lambda *a: order.append('transaction') or {'installation': 'Installed'}
        self.start.side_effect = lambda *a: order.append('start')
        self.activate.side_effect = lambda *a: order.append('activate')
        self.assertEqual(update.update(self.volume), 0)
        self.assertEqual(order, ['transaction', 'start', 'activate'])
        options, context = self.run.call_args.args
        self.assertTrue(options['_finder_update'])
        self.assertEqual(context['package_root'], str(self.volume / '.deployment'))
        self.assertIn('updated and opened', self.ui.call_args.args[0])

    def test_failed_transaction_never_reports_success_or_starts_replacement(self):
        self.run.return_value = {'installation': 'Failed', 'rollback': 'FilesRestored',
                                 'original_failure': {'message': 'fixture startup failure'},
                                 'evidence': ['/fixture/record.json']}
        with self.assertRaisesRegex(ValueError, 'FilesRestored'):
            update.update(self.volume)
        self.start.assert_not_called()
        self.activate.assert_not_called()
        self.assertEqual(self.ui.call_count, 1)

    def test_start_failure_is_honest_about_already_updated_app(self):
        self.start.side_effect = ValueError('fixture disabled service')
        with self.assertRaisesRegex(ValueError, 'app was updated, but could not be opened'):
            update.update(self.volume)
        self.activate.assert_not_called()
        self.assertEqual(self.ui.call_count, 1)

    def test_fresh_install_explains_drag_without_starting_from_dmg(self):
        self.find.return_value = None
        self.assertEqual(update.update(self.volume), 0)
        self.assertIn('drag Cilex Watchtower', self.ui.call_args.args[0])
        self.lock.assert_not_called()
        self.package.assert_not_called()
        self.run.assert_not_called()
        self.start.assert_not_called()

    def test_corrupt_package_cannot_reach_restart(self):
        self.run.side_effect = install.InstallError('package.hash', 'fixture hash mismatch')
        with self.assertRaises(install.InstallError): update.update(self.volume)
        self.start.assert_not_called()
        self.activate.assert_not_called()

    def test_options_keep_existing_backend_and_bind_destination(self):
        # Bypass the patched function by reading it from a separately saved reference.
        self.target['agent'].write_bytes(plistlib.dumps({'ProgramArguments': [
            '/usr/bin/env', '-i', 'WT_WARDEN_BACKEND_URL=https://fixture.invalid', 'warden', 'run']}))
        with mock.patch.object(install, 'assert_authorized'), mock.patch.object(install, 'validate_existing'):
            options = REAL_OPTIONS(self.target, self.manifest)
        self.assertEqual(options['backend_url'], 'https://fixture.invalid')
        self.assertEqual(options['install_dir'], str(self.target['path']))
        self.assertEqual(options['desktop_user'], 'fixture')
        self.assertTrue(options['allow_development'])

    def test_legacy_backend_is_preserved(self):
        self.target['agent'].write_bytes(plistlib.dumps({'ProgramArguments': ['warden', 'run'],
            'EnvironmentVariables': {'WT_WARDEN_BACKEND_URL': 'https://legacy.invalid'}}))
        with mock.patch.object(install, 'assert_authorized'), mock.patch.object(install, 'validate_existing'):
            self.assertEqual(REAL_OPTIONS(self.target, self.manifest)['backend_url'], 'https://legacy.invalid')

    def test_native_dialog_uses_literal_arguments_and_localized_buttons(self):
        with mock.patch.object(update, 'command', return_value=types.SimpleNamespace(returncode=0, stdout='Обновить\n')) as cmd, \
             mock.patch.object(update, 'language', return_value='ru'):
            self.assertTrue(REAL_DIALOG('path with "quotes" and $(literal)', confirm=True))
        argv = cmd.call_args.args[0]
        self.assertEqual(argv[-4:], ['path with "quotes" and $(literal)', 'Отмена', 'Обновить', 'yes'])
        self.assertNotIn('$(literal)', argv[4])

    def test_native_dialog_cancel_is_false(self):
        with mock.patch.object(update, 'command', return_value=types.SimpleNamespace(returncode=0, stdout='')):
            self.assertFalse(REAL_DIALOG('fixture', confirm=True))

    def test_dmg_dispatch_never_enters_normal_first_launch(self):
        with mock.patch.object(update, 'main', return_value=0) as main, \
             mock.patch.object(first_launch, 'launch') as launch:
            self.assertEqual(first_launch.main([str(self.volume / update.APP_NAME)]), 0)
        main.assert_called_once()
        launch.assert_not_called()

    def test_frozen_helper_must_belong_to_launched_bundle(self):
        with mock.patch.object(sys, 'frozen', True, create=True), \
             mock.patch.object(update, 'main') as main, mock.patch.object(first_launch, 'dialog'):
            self.assertEqual(first_launch.main([str(self.volume / update.APP_NAME)]), 1)
        main.assert_not_called()

    def test_source_requires_actual_readonly_mounted_image(self):
        app = self.volume / update.APP_NAME
        app.mkdir()
        info = plistlib.dumps({'images': [{'system-entities': [{'mount-point': str(self.volume)}]}]}).decode()
        fs = {'read_only': True, 'mount_point': str(self.volume)}
        with mock.patch.object(update, 'command', return_value=types.SimpleNamespace(stdout=info)), \
             mock.patch.object(install, 'inspect_filesystem', return_value=fs):
            self.assertEqual(update.source_volume(app), self.volume)
            fs['read_only'] = False
            with self.assertRaisesRegex(ValueError, 'read-only'):
                update.source_volume(app)
            fs['read_only'] = True
            fs['mount_point'] = str(self.root)
            with self.assertRaises(ValueError): update.source_volume(app)

    def test_source_rejects_symlink_and_folder_imitating_dmg(self):
        app = self.volume / update.APP_NAME
        app.mkdir()
        link = self.root / update.APP_NAME
        link.symlink_to(app)
        with self.assertRaises(ValueError): update.source_volume(link)
        with mock.patch.object(update, 'command', return_value=types.SimpleNamespace(
                stdout=plistlib.dumps({'images': []}).decode())), \
             mock.patch.object(install, 'inspect_filesystem', return_value={'read_only': True, 'mount_point': str(self.volume)}):
            with self.assertRaises(ValueError): update.source_volume(app)

    def test_package_reconstruction_preserves_inventory_and_excludes_shortcut(self):
        (self.volume / update.APP_NAME).mkdir()
        (self.volume / update.APP_NAME / 'payload').write_bytes(b'fixture app')
        (self.volume / 'Applications').symlink_to('/Applications')
        with mock.patch.object(install, 'read_quarantine', return_value=None):
            with REAL_PACKAGE(self.volume) as package:
                self.assertEqual((package / 'watchtower.app/payload').read_bytes(), b'fixture app')
                self.assertEqual(json.loads((package / 'artifact-manifest.json').read_text()), self.manifest)
                self.assertFalse((package / 'Applications').exists())
                saved = package
        self.assertFalse(saved.exists())

    def test_translocation_mapping_must_match_both_executables(self):
        translocated = self.root / 'translocated' / update.APP_NAME
        original = self.volume / update.APP_NAME
        for app in (translocated, original):
            for relative in ('Contents/MacOS/watchtower', 'Contents/Helpers/Setup.app/Contents/MacOS/cilex-setup'):
                path = app / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'fixture signed executable')
        replies = [types.SimpleNamespace(returncode=0, stdout='Original path:\n\t' + str(original)),
                   types.SimpleNamespace(stdout=plistlib.dumps({'images': [
                       {'system-entities': [{'mount-point': str(self.volume)}]}]}).decode())]
        with mock.patch.object(update, 'command', side_effect=replies), \
             mock.patch.object(install, 'inspect_filesystem', return_value={'read_only': True, 'mount_point': str(self.volume)}):
            self.assertEqual(update.source_volume(translocated), self.volume)
        (original / 'Contents/Helpers/Setup.app/Contents/MacOS/cilex-setup').write_bytes(b'different helper')
        with mock.patch.object(update, 'command', return_value=replies[0]):
            with self.assertRaisesRegex(ValueError, 'differs'):
                update.source_volume(translocated)

    def test_multiple_or_missing_installed_copies_are_never_guessed(self):
        directories = (self.root / 'SharedApps', self.root / 'UserApps')
        with mock.patch.object(update, 'application_dirs', return_value=directories), \
             mock.patch.object(Path, 'home', return_value=self.root), \
             mock.patch.object(first_launch, 'target_for', return_value=self.target) as validate:
            self.assertIsNone(REAL_FIND())
            for parent in directories:
                (parent / update.APP_NAME).mkdir(parents=True)
            with self.assertRaisesRegex(ValueError, 'More than one'):
                REAL_FIND()
            validate.assert_not_called()
            (directories[1] / update.APP_NAME).rmdir()
            self.assertEqual(REAL_FIND(), self.target)
            validate.assert_called_once_with(directories[0] / update.APP_NAME)


REAL_OPTIONS = update.update_options
REAL_DIALOG = update.dialog
REAL_PACKAGE = update.package_from_volume
REAL_FIND = update.installed_target


class DestinationTests(unittest.TestCase):
    def test_standard_applications_exception_needs_exact_owner_parent_and_permissions(self):
        path = mock.MagicMock()
        path.parent = Path('/Applications')
        path.resolve.return_value = path
        path.is_dir.return_value = True
        target = {'path': path, 'uid': 501}
        parent = types.SimpleNamespace(st_uid=0, st_gid=80, st_mode=0o40775)
        app = types.SimpleNamespace(st_uid=501, st_mode=0o40755)
        path.stat.return_value = app
        with mock.patch.object(Path, 'stat', return_value=parent), mock.patch.object(os, 'access', return_value=True):
            self.assertTrue(install.finder_update_destination(target))
            for attr, value in (('st_uid', 502), ('st_mode', 0o40777)):
                old = getattr(app, attr)
                setattr(app, attr, value)
                self.assertFalse(install.finder_update_destination(target))
                setattr(app, attr, old)
            parent.st_mode = 0o40777
            self.assertFalse(install.finder_update_destination(target))
            parent.st_mode = 0o40775
            parent.st_gid = 20
            self.assertFalse(install.finder_update_destination(target))
        path.is_dir.return_value = False
        self.assertFalse(install.finder_update_destination(target))

    def test_other_user_is_rejected_by_exact_bundle_path(self):
        target = {'path': Path('/Applications/Cilex Watchtower.app'), 'uid': 501}
        for executable in ('Contents/MacOS/watchtower', 'Contents/Resources/warden/cilex-warden'):
            with mock.patch.object(install, 'process_snapshot', return_value=[
                    {'path': str(target['path'] / executable), 'uid': 502}]):
                with self.assertRaises(install.InstallError) as error:
                    install.assert_no_other_users(target)
                self.assertEqual(error.exception.finding, 'update.other_user')
        with mock.patch.object(install, 'process_snapshot', return_value=[
                {'path': '/Other/watchtower.app/Contents/MacOS/watchtower', 'uid': 502}]):
            install.assert_no_other_users(target)

    def test_shared_applications_remains_blocked_for_scripted_install(self):
        path = mock.MagicMock()
        path.parent = Path('/Applications')
        path.resolve.return_value = path
        path.is_dir.return_value = True
        path.stat.return_value = types.SimpleNamespace(st_uid=501, st_mode=0o40755)
        target = {'path': path, 'uid': 501}
        parent = types.SimpleNamespace(st_uid=0, st_gid=80, st_mode=0o40775)
        with mock.patch.object(Path, 'stat', return_value=parent), \
             mock.patch.object(os, 'geteuid', return_value=501), \
             mock.patch.object(os, 'access', return_value=True), \
             mock.patch.object(install, 'process_snapshot', return_value=[]):
            with self.assertRaises(install.InstallError) as error:
                install.assert_authorized(target, {})
            self.assertEqual(error.exception.finding, 'authorization.destination')
            install.assert_authorized(target, {'_finder_update': True})
            with self.assertRaises(install.InstallError):
                install.assert_authorized(target, {'_finder_update': True, 'scope': 'machine'})


if __name__ == '__main__': unittest.main()
