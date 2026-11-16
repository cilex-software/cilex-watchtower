"""Human-facing installer checks; never connect or install on a real Mac."""
import contextlib
import io
from pathlib import Path
import socket
import sys
import tempfile
import types
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import deploy
import easy
import remote
from common import DeployError


class EasyTests(unittest.TestCase):
    def test_reused_build_does_not_claim_a_new_installer_was_created(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            easy.show_outcome({'mode': 'build-installer', 'exit_code': 0, 'build_reused': True}, None)
        self.assertIn('Nothing was recompiled', output.getvalue())
        self.assertNotIn('Installer created', output.getvalue())

    def test_remote_needs_only_host_and_username(self):
        args = easy.parser('install-remote').parse_args(['--host', 'office.local', '--user', 'operator'])
        self.assertEqual(args.port, 22)
        self.assertIsNone(args.installer)
        self.assertEqual(args.development, 'yes')

    def test_no_password_argument(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            easy.parser('install-remote').parse_args(['--host', 'office.local', '--user', 'operator', '--password', 'fixture'])

    def test_all_exposed_controller_options_require_values(self):
        for action in deploy.parser()._actions:
            self.assertNotEqual(action.nargs, 0, action.dest)
            if action.choices:
                self.assertGreaterEqual(len(action.choices), 2, action.dest)
        self.assertNotIn('arch', {a.dest for a in deploy.parser()._actions})
        for key in ('development', 'dry_run', 'noninteractive', 'accept_licenses'):
            option = '--' + key.replace('_', '-')
            self.assertTrue(deploy.normalize(deploy.parser().parse_args([option, 'yes']))[key])
            self.assertFalse(deploy.normalize(deploy.parser().parse_args([option, 'no']))[key])

    def test_latest_installer_and_explicit_selection(self):
        with tempfile.TemporaryDirectory() as temp, mock.patch.object(easy, 'OUTPUT', Path(temp)):
            old = Path(temp) / 'CilexWatchtower-old.dmg'
            new = Path(temp) / 'sub/CilexWatchtower-new.dmg'
            new.parent.mkdir()
            old.touch(); new.touch()
            import os
            os.utime(old, (1, 1)); os.utime(new, (2, 2))
            self.assertEqual(easy.find_installer(None), new)
            self.assertEqual(easy.find_installer(old), old)
            new.unlink()
            with self.assertRaises(ValueError): easy.find_installer(new)

    def test_help_does_not_open_image_or_connect(self):
        with mock.patch.object(easy, 'install_remote') as install, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(easy.main(['install-remote', 'help']), 0)
        install.assert_not_called()

    def test_all_public_scripts_have_only_valued_options(self):
        for name in ('build-installer', 'install-local', 'install-remote'):
            for action in easy.parser(name)._actions:
                self.assertNotEqual(action.nargs, 0, (name, action.dest))
                if action.choices:
                    self.assertGreaterEqual(len(action.choices), 2, (name, action.dest))

    def test_no_argument_build_dispatches_to_internal_defaults(self):
        import simple_build
        with mock.patch.object(easy.sys, 'platform', 'darwin'), mock.patch.object(simple_build, 'run', return_value=0) as build:
            self.assertEqual(easy.main(['build-installer']), 0)
        args, cache, output = build.call_args.args
        self.assertEqual(args.tools, 'install')
        self.assertEqual(args.revision, 'HEAD')
        self.assertIsNone(args.jobs)
        self.assertEqual(output, easy.OUTPUT)

    def test_build_failure_does_not_claim_installer_created(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            easy.show_outcome({'mode': 'build-installer', 'exit_code': 15,
                               'states': {'installation': 'ArtifactBuilt'}}, None)
        self.assertIn('Build stopped', output.getvalue())
        self.assertNotIn('Installer created', output.getvalue())

    def test_finder_result_is_plain_language_and_retains_failures(self):
        message = deploy.setup_result_message({'states': {'installation': 'Installed'}, 'exit_code': 21}, 'en')
        self.assertIn('installed for your Mac account', message)
        self.assertIn('could not confirm', message)
        self.assertNotIn('JSON', message)
        failed = deploy.setup_result_message({'states': {'installation': 'Failed'}, 'exit_code': 15,
            'findings': [{'message': 'Not enough free space.'}]}, 'en')
        self.assertIn('not confirmed', failed)
        self.assertIn('Not enough free space.', failed)

    def test_transport_contains_only_inventory_and_reuses_stable_bytes(self):
        import tarfile
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            image = root / 'internal.dmg'; image.write_bytes(b'image-fixture')
            package = root / 'package'; package.mkdir()
            (package / 'artifact-manifest.json').write_text('{}')
            (package / 'payload').mkdir()
            (package / 'payload/file').write_text('application fixture')
            (package / '.DS_Store').write_text('Finder metadata is not payload')
            manifest = {'files': [{'path': 'payload'}, {'path': 'payload/file'}], 'distribution': 'development'}
            @contextlib.contextmanager
            def mounted(image): yield package
            with mock.patch.object(easy, 'CACHE', root / 'cache'), mock.patch.object(easy, 'mounted', side_effect=mounted), mock.patch.object(easy.install, 'read_manifest', return_value=manifest), mock.patch.object(easy.install, 'read_quarantine', return_value=None):
                archive, _ = easy.transport_package(image)
                before = archive.read_bytes()
                again, actual = easy.transport_package(image)
            self.assertEqual(archive, again)
            self.assertEqual(before, again.read_bytes())
            self.assertEqual(actual, manifest)
            with tarfile.open(archive) as tar:
                self.assertEqual(tar.getnames(), ['artifact-manifest.json', 'payload', 'payload/file'])

    def test_mount_uses_canonical_path_and_always_detaches(self):
        import plistlib
        calls = []
        def run(argv, **kwargs):
            calls.append(argv)
            if 'attach' in argv:
                mount = argv[argv.index('-mountpoint') + 1]
                self.assertEqual(str(Path(mount).resolve()), mount)
                return types.SimpleNamespace(stdout=plistlib.dumps({'system-entities': [{'mount-point': mount}]}))
            return types.SimpleNamespace(returncode=0)
        with mock.patch.object(easy.subprocess, 'run', side_effect=run), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(RuntimeError):
                with easy.mounted(Path('/fixture/image.dmg')):
                    raise RuntimeError('fixture failure after mount')
        self.assertEqual(calls[-1][:2], ['/usr/bin/hdiutil', 'detach'])

    def test_invalid_remote_input_stops_before_opening_installer(self):
        args = easy.parser('install-remote').parse_args(['--host', 'bad;host', '--user', 'operator'])
        with mock.patch.object(easy, 'transport_package') as package:
            with self.assertRaises(ValueError): easy.install_remote(args)
        package.assert_not_called()

    def test_local_installer_passes_valued_options_and_preserves_pending_result(self):
        import json
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'artifact-manifest.json').write_text('{}')
            @contextlib.contextmanager
            def mounted(image): yield root
            args = easy.parser('install-local').parse_args([])
            result = {'states': {'installation': 'Installed'}, 'exit_code': 21}
            with mock.patch.object(easy, 'find_installer', return_value=root / 'fixture.dmg'), mock.patch.object(easy, 'mounted', side_effect=mounted), mock.patch.object(easy.install, 'read_manifest', return_value={'minimum_macos': '14.4', 'distribution': 'development'}), mock.patch.object(easy.platform, 'machine', return_value='arm64'), mock.patch.object(easy.platform, 'mac_ver', return_value=('26.0', (), '')), mock.patch.object(easy, 'command', return_value=types.SimpleNamespace(stdout=json.dumps(result), returncode=21)) as command, contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(easy.install_local(args), 21)
            argv = command.call_args.args[0]
            self.assertEqual(argv[argv.index('--allow-development') + 1], 'yes')
            self.assertEqual(argv[argv.index('--noninteractive') + 1], 'yes')
            self.assertIn('installed', output.getvalue())
            self.assertIn('still need attention', output.getvalue())

    def test_backend_password_is_refused_before_opening_any_image(self):
        args = easy.parser('install-local').parse_args(['--backend-url', 'https://user:secret@example.invalid'])
        with mock.patch.object(easy, 'mounted') as mount:
            with self.assertRaises(DeployError): easy.install_local(args)
        mount.assert_not_called()

    def test_bad_hosts_users_ports_never_start_ssh(self):
        for host, user, port in [('x;id', 'operator', 22), ('x', 'root', 22), ('x', 'a@b', 22), ('x', 'operator', 0)]:
            with self.subTest(host=host, user=user, port=port), mock.patch.object(easy.subprocess, 'run') as run:
                with self.assertRaises(ValueError), easy.password_session(host, user, port):
                    self.fail('must not connect')
                run.assert_not_called()

    def test_password_session_uses_terminal_and_closes_master(self):
        with tempfile.TemporaryDirectory(prefix='ssh-test-', dir='/tmp') as temp:
            home = Path(temp)
            calls = []
            def fake_run(argv, **kwargs):
                calls.append((argv, kwargs))
                if '-M' in argv:
                    # A real protected Unix socket, just as OpenSSH creates.
                    server = socket.socket(socket.AF_UNIX)
                    server.bind(argv[argv.index('-S') + 1])
                    self.addCleanup(server.close)
                return types.SimpleNamespace(returncode=0)
            probe = types.SimpleNamespace(stdout='a'*64 + '\n501\noperator\n/Users/operator\n')
            with mock.patch.object(Path, 'home', return_value=home), mock.patch.object(easy.sys.stdin, 'isatty', return_value=True), mock.patch.object(easy.subprocess, 'run', side_effect=fake_run), mock.patch.object(remote, 'ssh', return_value=probe), contextlib.redirect_stdout(io.StringIO()):
                with easy.password_session('office.local', 'operator', 22) as options:
                    info = remote.ssh_options(options)
                    self.assertIn('ProxyCommand=/usr/bin/false', info['flags'])
                    self.assertEqual(options['expected_target_id'], 'a'*64)
            self.assertIn('-M', calls[0][0])
            self.assertNotIn('capture_output', calls[0][1])
            self.assertEqual(calls[-1][0][-3:], ['-O', 'exit', 'office.local'])
            self.assertNotIn('password', repr(options).lower())

    def test_missing_master_fails_before_network(self):
        with tempfile.TemporaryDirectory(dir='/tmp') as temp:
            known = Path(temp) / 'known'; known.touch(); known.chmod(0o600)
            with self.assertRaises(DeployError) as error:
                remote.ssh_options({'target_host': 'office.local', 'ssh_user': 'operator', 'desktop_user': 'operator',
                    'ssh_known_hosts': str(known), 'expected_target_id': 'a'*64,
                    'ssh_control_path': str(Path(temp) / 'absent')})
            self.assertEqual(error.exception.finding, 'remote.control_socket')


if __name__ == '__main__':
    unittest.main()
