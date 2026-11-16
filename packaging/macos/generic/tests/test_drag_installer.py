"""Inert installer fixtures: no real LaunchAgents or installed apps are changed."""
import contextlib
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import sys
import tempfile
import types
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build
import deploy
import dmg_layout
import easy
import first_launch as launch
import install


def read_layout(raw):
    """Independent traversal of allocator -> DSDB -> leaf, not string matching."""
    magic, tag, offset, size, duplicate = struct.unpack_from('>I4sIII', raw)
    assert (magic, tag, duplicate, size) == (1, b'Bud1', offset, 2048)
    root = offset + 4
    count = struct.unpack_from('>I', raw, root)[0]
    offsets = struct.unpack_from('>' + str(count) + 'I', raw, root+8)
    count, length = struct.unpack_from('>IB', raw, root+1032)
    assert count == 1 and raw[root+1037:root+1037+length] == b'DSDB'
    control = struct.unpack_from('>I', raw, root+1037+length)[0]
    leaf, levels, entries, nodes, page = struct.unpack_from('>5I', raw, (offsets[control]&~31)+4)
    assert levels == 0 and nodes == 1 and page == 4096
    pos = (offsets[leaf]&~31)+4
    next_node, records = struct.unpack_from('>II', raw, pos)
    assert next_node == 0 and records == entries
    pos += 8
    result = {}
    for _ in range(records):
        n = struct.unpack_from('>I', raw, pos)[0]; pos += 4
        name = raw[pos:pos+n*2].decode('utf-16be'); pos += n*2
        code, kind = struct.unpack_from('>4s4s', raw, pos); pos += 8
        if kind == b'blob':
            n = struct.unpack_from('>I', raw, pos)[0]; pos += 4
            value = raw[pos:pos+n]; pos += n
            if value.startswith(b'bplist'):
                value = plistlib.loads(value)
        else:
            value = raw[pos:pos+4]; pos += 4
        result[name, code] = value
    return result


class DragInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='Cilex drag тест ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def test_finder_layout_has_two_positions_background_and_no_build_host_path(self):
        raw = dmg_layout.store_bytes(b'fixture-alias-on-final-volume')
        layout = read_layout(raw)
        self.assertEqual(layout['.', b'icvl'], b'icnv')
        self.assertEqual(struct.unpack('>4I', layout[dmg_layout.APP_NAME, b'Iloc'])[:2], (190, 282))
        self.assertEqual(struct.unpack('>4I', layout['Applications', b'Iloc'])[:2], (570, 282))
        self.assertEqual(layout['.', b'icvp']['backgroundImageAlias'], b'fixture-alias-on-final-volume')
        self.assertEqual(layout['.', b'icvp']['iconSize'], 160)
        for flag in ('ShowToolbar', 'ShowStatusBar', 'ShowPathbar', 'ShowTabView', 'ShowSidebar'):
            self.assertFalse(layout['.', b'bwsp'][flag])
        self.assertEqual(layout['.', b'bwsp']['WindowBounds'], '{{200, 160}, {760, 568}}')
        self.assertEqual(layout['.', b'bwsp']['SidebarWidth'], 180)
        for channel, value in zip(('Red', 'Green', 'Blue'), (242, 240, 233)):
            self.assertEqual(layout['.', b'icvp']['backgroundColor' + channel], value / 255)
        # Include icon and label extents, not only icon centres: neither axis
        # may need scrolling in the saved window's content area.
        for name in (dmg_layout.APP_NAME, 'Applications'):
            x, y = struct.unpack('>4I', layout[name, b'Iloc'])[:2]
            self.assertGreater(x - 110, 0)
            self.assertLess(x + 110, 760)
            self.assertGreater(y - 80, 120)
            self.assertLess(y + 80 + 40, 480)
        self.assertNotIn(b'/Users/', raw)

    def test_oversized_background_alias_cannot_overrun_leaf(self):
        with self.assertRaises(ValueError): dmg_layout.store_bytes(b'x' * 4096)

    def package(self):
        package = self.root / 'package'; package.mkdir()
        (package / 'watchtower.app/Contents').mkdir(parents=True)
        (package / 'watchtower.app/Contents/app-data').write_text('immutable app')
        (package / 'helpers').mkdir()
        (package / 'helpers/fixture.py').write_text('# helper')
        (package / 'artifact-manifest.json').write_text('{}')
        return package

    def test_visible_image_is_only_app_and_applications(self):
        package = self.package()
        before = build.inventory(package)
        stage = self.root / 'image'
        build.stage_drag_installer(package, stage, Path(build.__file__).parent / 'assets')
        self.assertEqual({p.name for p in stage.iterdir() if not p.name.startswith('.')},
                         {dmg_layout.APP_NAME, 'Applications'})
        self.assertEqual(os.readlink(stage / 'Applications'), '/Applications')
        self.assertEqual(build.inventory(stage / dmg_layout.APP_NAME), build.inventory(package / 'watchtower.app'))
        self.assertTrue((stage / '.deployment/helpers/fixture.py').is_file())
        self.assertEqual((stage / '.background/install.tiff').read_bytes(),
                         (Path(build.__file__).parent / 'assets/install.tiff').read_bytes())
        self.assertEqual(build.inventory(package), before)

    def test_new_image_reconstructs_original_package_for_scripts_and_preserves_old_format(self):
        package = self.package()
        stage = self.root / 'image'
        build.stage_drag_installer(package, stage, Path(build.__file__).parent / 'assets')
        def hdiutil(argv, **kwargs):
            if 'attach' in argv:
                mount = Path(argv[argv.index('-mountpoint')+1])
                shutil.copytree(stage, mount, symlinks=True, dirs_exist_ok=True)
                return types.SimpleNamespace(stdout=plistlib.dumps({'system-entities': [{'mount-point': str(mount)}]}))
            return types.SimpleNamespace(returncode=0)
        with mock.patch.object(easy.subprocess, 'run', side_effect=hdiutil), \
             mock.patch.object(install, 'read_quarantine', return_value=None), \
             mock.patch.object(install, 'read_manifest') as verify:
            with easy.mounted(self.root / 'fixture.dmg') as restored:
                self.assertEqual(build.inventory(restored), build.inventory(package))
                self.assertFalse((restored / 'Applications').exists())
                verify.assert_called_once_with(restored)

    def test_dmg_layout_failure_always_ejects_and_never_publishes_image(self):
        package = self.package()
        manifest = {'version': '1.2.3', 'distribution': 'development',
                    'files': [r for r in build.inventory(package) if r['path'] != 'artifact-manifest.json']}
        (package / 'artifact-manifest.json').write_text(json.dumps(manifest))
        run_dir = self.root / 'run'; run_dir.mkdir()
        calls = []
        def run(argv, *args, **kwargs): calls.append([str(v) for v in argv]); return ''
        with mock.patch.object(build, 'run', side_effect=run), \
             mock.patch.object(dmg_layout, 'configure', side_effect=ValueError('fixture alias failure')):
            with self.assertRaisesRegex(ValueError, 'fixture alias'):
                build.build_installer(package, {'output_dir': str(self.root / 'out')}, run_dir)
        self.assertEqual(calls[-1][1], 'detach')
        self.assertFalse(any('convert' in call for call in calls))
        self.assertFalse(list((self.root / 'out').glob('*.dmg')))

    def test_launch_dispatch_does_not_select_setup_or_diagnostic_mode(self):
        with mock.patch.object(launch, 'main', return_value=0) as entry, mock.patch.object(deploy, 'execute') as install:
            self.assertEqual(deploy.main(['launch-app', '/Applications/Cilex Watchtower.app']), 0)
        entry.assert_called_once_with(['/Applications/Cilex Watchtower.app'])
        install.assert_not_called()


class FirstLaunchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='Cilex Finder тест ')
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve()
        self.target = self.make_target(self.home / 'Applications/Cilex Watchtower.app')
        self.agent_patch = mock.patch.object(install, 'resolve_target', side_effect=lambda opts: self.make_target(Path(opts['install_dir']))).start()
        self.jobs = mock.patch.object(install, 'job_state', return_value={
            'loaded': False, 'disabled': False, 'pid': None, 'gui_session': True}).start()
        self.identities = mock.patch.object(install, 'assert_job_process').start()
        self.start = mock.patch.object(launch, 'start_service').start()
        self.stop = mock.patch.object(launch, 'stop_service').start()
        self.activate = mock.patch.object(launch, 'activate').start()
        self.dialog = mock.patch.object(launch, 'dialog', return_value=True).start()
        self.addCleanup(mock.patch.stopall)

    def make_target(self, app):
        identity = hashlib.sha256((str(app)+'\0'+str(os.getuid())).encode()).hexdigest()[:24]
        label = 'com.cilexvision.watchtower.'+identity
        return {'path': app, 'home': self.home, 'uid': os.getuid(), 'gid': os.getgid(),
                'user': 'fixture', 'id': identity, 'label': label, 'domain': 'gui/'+str(os.getuid()),
                'agent': self.home / 'Library/LaunchAgents' / (label+'.plist')}

    def write_agent(self, target):
        target['agent'].parent.mkdir(parents=True, exist_ok=True)
        raw = plistlib.dumps(install.launchagent(target, launch.MANIFEST, {'backend_url': 'https://fixture.invalid'}))
        target['agent'].write_bytes(raw); target['agent'].chmod(0o600)
        return raw

    def test_cancel_does_not_register_or_stop_any_service(self):
        self.dialog.return_value = False
        self.assertEqual(launch.launch(self.target), 0)
        self.assertFalse(self.target['agent'].exists())
        self.start.assert_not_called(); self.stop.assert_not_called()

    def test_first_open_uses_user_service_and_bundled_runtime(self):
        self.assertEqual(launch.launch(self.target), 0)
        data = plistlib.loads(self.target['agent'].read_bytes())
        self.assertTrue(data['RunAtLoad'])
        self.assertEqual(data['LimitLoadToSessionType'], 'Aqua')
        self.assertIn('WT_WARDEN_APP_CMD='+str(self.target['path'] / 'Contents/MacOS/watchtower'), data['ProgramArguments'])
        self.assertEqual(data['ProgramArguments'][-2:], [str(self.target['path'] / 'Contents/Resources/warden/cilex-warden'), 'run'])
        self.start.assert_called_once_with(self.target)
        self.activate.assert_called_once_with(self.target)

    def test_existing_registration_is_not_rewritten_or_reprompted(self):
        before = self.write_agent(self.target)
        launch.launch(self.target)
        self.assertEqual(self.target['agent'].read_bytes(), before)
        self.dialog.assert_not_called(); self.stop.assert_not_called()
        self.start.assert_called_once_with(self.target)

    def test_old_copy_switch_requires_consent_and_preserves_server(self):
        old = self.make_target(self.home / 'Applications/watchtower.app')
        self.write_agent(old)
        launch.launch(self.target)
        self.assertIn(str(old['path']), self.dialog.call_args.args[0])
        self.stop.assert_called_once_with(old)
        self.assertFalse(old['agent'].exists())
        new = plistlib.loads(self.target['agent'].read_bytes())
        self.assertIn('WT_WARDEN_BACKEND_URL=https://fixture.invalid', new['ProgramArguments'])

    def test_failed_switch_restores_original_agent_and_running_state(self):
        old = self.make_target(self.home / 'Applications/watchtower.app')
        original = self.write_agent(old)
        self.jobs.return_value = {'loaded': True, 'disabled': False, 'pid': 123, 'gui_session': True}
        self.start.side_effect = ValueError('fixture startup failure')
        with mock.patch.object(install, 'execute') as commands:
            with self.assertRaisesRegex(ValueError, 'fixture startup'):
                launch.launch(self.target)
        self.assertEqual(old['agent'].read_bytes(), original)
        self.assertFalse(self.target['agent'].exists())
        commands.assert_called_once_with(['/bin/launchctl', 'bootstrap', old['domain'], str(old['agent'])])

    def test_cancel_switch_preserves_old_agent(self):
        old = self.make_target(self.home / 'Applications/watchtower.app')
        original = self.write_agent(old)
        self.dialog.return_value = False
        launch.launch(self.target)
        self.assertEqual(old['agent'].read_bytes(), original)
        self.assertFalse(self.target['agent'].exists())
        self.stop.assert_not_called()

    def test_other_product_diagnostic_job_is_untouched(self):
        folder = self.target['agent'].parent; folder.mkdir(parents=True)
        path = folder / 'com.cilexvision.watchtower.traceenv.plist'
        path.write_bytes(b'fixture diagnostic, not a managed installation')
        launch.launch(self.target)
        self.assertEqual(path.read_bytes(), b'fixture diagnostic, not a managed installation')

    def test_multiple_installations_are_not_automatically_stopped(self):
        for name in ('old.app', 'older.app'):
            self.write_agent(self.make_target(self.home / 'Applications' / name))
        with self.assertRaisesRegex(ValueError, 'More than one'):
            launch.launch(self.target)
        self.stop.assert_not_called(); self.start.assert_not_called()

    def test_modified_agent_binding_is_rejected(self):
        self.write_agent(self.target)
        data = plistlib.loads(self.target['agent'].read_bytes())
        data['ProgramArguments'][-2] = '/unrelated/program'
        self.target['agent'].write_bytes(plistlib.dumps(data))
        with self.assertRaisesRegex(ValueError, 'different configuration'):
            launch.launch(self.target)
        self.stop.assert_not_called(); self.start.assert_not_called()

    def test_open_from_dmg_is_rejected_before_service_or_signature_changes(self):
        with mock.patch.object(install, 'execute') as commands:
            with self.assertRaisesRegex(ValueError, 'Drag Cilex'):
                launch.target_for('/Volumes/Cilex Watchtower/Cilex Watchtower.app')
        commands.assert_not_called()

    def test_missing_gui_session_does_not_register_service(self):
        self.jobs.return_value = {'loaded': False, 'disabled': False, 'pid': None, 'gui_session': False}
        with self.assertRaisesRegex(ValueError, 'Sign in'):
            launch.launch(self.target)
        self.assertFalse(self.target['agent'].exists())
        self.start.assert_not_called()

    def test_duplicate_environment_binding_cannot_redirect_the_service(self):
        self.write_agent(self.target)
        data = plistlib.loads(self.target['agent'].read_bytes())
        data['ProgramArguments'].insert(2, 'WT_WARDEN_APP_CMD=/another/program')
        self.target['agent'].write_bytes(plistlib.dumps(data))
        with self.assertRaisesRegex(ValueError, 'different configuration'):
            launch.launch(self.target)
        self.start.assert_not_called()


class ServiceHandoffTests(unittest.TestCase):
    def setUp(self):
        self.target = {'path': Path('/Applications/Cilex Watchtower.app'), 'uid': 501,
                       'domain': 'gui/501', 'label': 'fixture', 'agent': Path('/fixture/agent.plist')}
        self.state = {'loaded': True, 'pid': 42, 'disabled': False}
        self.jobs = mock.patch.object(install, 'job_state', return_value=self.state).start()
        self.identity = mock.patch.object(install, 'assert_job_process').start()
        self.commands = mock.patch.object(install, 'execute').start()
        self.wait_patch = mock.patch.object(launch, 'wait_user_processes')
        self.wait = self.wait_patch.start()
        self.addCleanup(mock.patch.stopall)

    def test_running_service_is_reused_without_restart(self):
        launch.start_service(self.target)
        self.identity.assert_called_once_with(self.target, launch.MANIFEST, self.state)
        self.commands.assert_not_called()
        self.wait.assert_called_once_with(self.target, running=True)

    def test_explicit_open_reenables_and_starts_a_stopped_job_without_killing(self):
        self.state.update(pid=None, disabled=True)
        launch.start_service(self.target)
        self.assertEqual(self.commands.call_args_list, [
            mock.call(['/bin/launchctl', 'enable', 'gui/501/fixture']),
            mock.call(['/bin/launchctl', 'kickstart', 'gui/501/fixture'])])

    def test_unloaded_service_is_bootstrapped(self):
        self.state.update(loaded=False, pid=None)
        launch.start_service(self.target)
        self.commands.assert_called_once_with(['/bin/launchctl', 'bootstrap', 'gui/501', '/fixture/agent.plist'])

    def test_foreign_loaded_job_is_not_enabled_started_or_stopped(self):
        self.identity.side_effect = ValueError('fixture identity mismatch')
        for function in (launch.start_service, launch.stop_service):
            with self.assertRaisesRegex(ValueError, 'identity mismatch'):
                function(self.target)
        self.commands.assert_not_called(); self.wait.assert_not_called()

    def test_stop_is_launchd_bootout_and_waits_for_only_that_account(self):
        launch.stop_service(self.target)
        self.commands.assert_called_once_with(['/bin/launchctl', 'bootout', 'gui/501/fixture'])
        self.wait.assert_called_once_with(self.target, running=False)

    def test_shared_app_in_other_account_is_excluded_from_own_guard_check(self):
        import runtime
        self.wait_patch.stop()
        own = {'uid': 501, 'pid': 1}; other = {'uid': 502, 'pid': 2}
        with mock.patch.object(install, 'process_snapshot', return_value=[own, other]), \
             mock.patch.object(runtime, 'process_evidence', return_value={'state': 'ProcessVerified'}) as verify:
            launch.wait_user_processes(self.target, running=True)
        verify.assert_called_once_with(self.target, launch.MANIFEST, rows=[own])


if __name__ == '__main__': unittest.main()
