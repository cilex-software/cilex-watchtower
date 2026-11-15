"""Finder package discovery: no installation, launchd or security changes."""
import contextlib
import io
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import deploy
from common import DeployError


class SetupLocationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='setup location Тест ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.package = self.root / 'Original DMG'
        self.original = self.executable(self.package, b'same setup executable')
        (self.package / 'artifact-manifest.json').write_text('package fixture')
        (self.package / 'helpers').mkdir()
        self.isolated = self.executable(self.root / 'AppTranslocation/random/d', b'same setup executable')

    def executable(self, parent, content):
        path = parent / 'Setup.app/Contents/MacOS/cilex-setup'
        path.parent.mkdir(parents=True)
        path.write_bytes(content)
        return path

    def mapping(self, path=None, returncode=0):
        bundle = path or self.original.parents[2]
        return types.SimpleNamespace(returncode=returncode,
            stdout='Original Path: (note if this is what you passed in then that path is not translocated)\n\t' + str(bundle) + '\n')

    def test_adjacent_package_needs_no_system_lookup(self):
        with mock.patch.object(sys, 'executable', str(self.original)), mock.patch.object(deploy, 'command') as command:
            self.assertEqual(deploy.setup_package_root(), self.package)
        command.assert_not_called()

    def test_isolated_setup_recovers_exact_original_package(self):
        with mock.patch.object(sys, 'executable', str(self.isolated)), mock.patch.object(deploy, 'command', return_value=self.mapping()) as command:
            self.assertEqual(deploy.setup_package_root(), self.package)
        self.assertEqual(command.call_args.args[0], ['/usr/bin/security', 'translocate-original-path', str(self.isolated.parents[2])])

    def test_mismatched_original_setup_is_refused(self):
        self.original.write_bytes(b'different build')
        with mock.patch.object(sys, 'executable', str(self.isolated)), mock.patch.object(deploy, 'command', return_value=self.mapping()):
            with self.assertRaises(DeployError) as error: deploy.setup_package_root()
        self.assertEqual(error.exception.finding, 'package.location')

    def test_no_mapping_or_package_never_falls_back_to_check(self):
        (self.package / 'artifact-manifest.json').unlink()
        for reply in (self.mapping(), self.mapping(returncode=1), types.SimpleNamespace(returncode=0, stdout='malformed output')):
            with self.subTest(reply=reply), mock.patch.object(sys, 'executable', str(self.isolated)), mock.patch.object(deploy, 'command', return_value=reply), mock.patch.object(deploy.install, 'read_manifest') as read:
                with self.assertRaises(DeployError) as error: deploy.setup_dialog()
                self.assertEqual(error.exception.finding, 'package.location')
                read.assert_not_called()

    def test_standalone_bootstrap_still_finds_helpers_for_explicit_commands(self):
        (self.package / 'artifact-manifest.json').unlink()
        with mock.patch.object(sys, 'frozen', True, create=True), mock.patch.object(sys, 'executable', str(self.original)):
            self.assertEqual(deploy.helper_source_root(), self.package / 'helpers')

    def test_isolated_helper_provenance_uses_original_helpers(self):
        with mock.patch.object(sys, 'frozen', True, create=True), mock.patch.object(sys, 'executable', str(self.isolated)), mock.patch.object(deploy, 'command', return_value=self.mapping()):
            self.assertEqual(deploy.helper_source_root(), self.package / 'helpers')

    def test_finder_routes_to_install_not_diagnostic_check(self):
        def command(argv, **kwargs):
            if argv[0] == '/usr/bin/security': return self.mapping()
            self.assertEqual(argv[0], '/usr/bin/osascript')
            return types.SimpleNamespace(returncode=0, stdout='Install\n')
        with mock.patch.object(sys, 'executable', str(self.isolated)), mock.patch.object(deploy, 'preferred_language', return_value='en'), mock.patch.object(deploy, 'command', side_effect=command), mock.patch.object(deploy.install, 'read_manifest', return_value={'distribution': 'development'}) as read:
            argv = deploy.setup_dialog()
        read.assert_called_once_with(self.package)
        options = deploy.normalize(deploy.parser().parse_args(argv))
        self.assertEqual(options['mode'], 'install')
        self.assertEqual(options['package'], str(self.package))
        self.assertEqual(options['package_manifest_sha256'], deploy.sha256(self.package / 'artifact-manifest.json'))
        self.assertTrue(options['allow_development'])

    def test_missing_package_reports_actionable_gui_error_and_never_assesses(self):
        (self.package / 'artifact-manifest.json').unlink()
        with mock.patch.object(sys, 'frozen', True, create=True), mock.patch.object(sys, 'argv', ['cilex-setup']), mock.patch.object(sys, 'executable', str(self.isolated)), mock.patch.object(deploy, 'preferred_language', return_value='en'), mock.patch.object(deploy, 'command', return_value=self.mapping()) as command, mock.patch.object(deploy, 'assessment', side_effect=AssertionError('wrong diagnostic fallback')), mock.patch.object(deploy, 'RunRecord', side_effect=AssertionError('installation started')), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(deploy.main(), 10)
        message = command.call_args.args[0][-1]
        self.assertIn('Open the Watchtower DMG', message)
        self.assertNotIn('capacity', message)

    def test_cancel_before_install_creates_nothing(self):
        with mock.patch.object(sys, 'executable', str(self.original)), mock.patch.object(deploy, 'preferred_language', return_value='en'), mock.patch.object(deploy, 'command', return_value=types.SimpleNamespace(returncode=1, stdout='cancelled')), mock.patch.object(deploy.install, 'read_manifest', return_value={'distribution': 'development'}):
            self.assertIsNone(deploy.setup_dialog())


if __name__ == '__main__': unittest.main()
