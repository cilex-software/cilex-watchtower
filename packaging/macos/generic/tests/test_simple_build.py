"""Default builder regression checks, without system installs or live services."""
import contextlib
import io
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import easy
import simple_build
from common import atomic_json


class SimpleBuildTests(unittest.TestCase):
    def test_existing_tools_policy_never_invokes_brew_install(self):
        with mock.patch.object(simple_build, 'brew_tools', return_value=({}, ['ninja'])), mock.patch.object(subprocess, 'run') as run:
            with self.assertRaises(ValueError): simple_build.prepare_brew(Path('/fixture/brew'), 'existing')
        run.assert_not_called()

    def test_install_policy_installs_only_missing_formulas(self):
        with mock.patch.object(simple_build, 'brew_tools', side_effect=[({}, ['ninja']), ({'ninja': '/fixture/ninja'}, [])]), mock.patch.object(subprocess, 'run') as run, contextlib.redirect_stdout(io.StringIO()):
            tools = simple_build.prepare_brew(Path('/fixture/brew'), 'install')
        self.assertEqual(run.call_args.args[0], ['/fixture/brew', 'install', 'ninja'])
        self.assertEqual(tools['ninja'], '/fixture/ninja')
        self.assertEqual(run.call_args.kwargs['env']['HOMEBREW_NO_AUTO_UPDATE'], '1')

    def test_modified_ffmpeg_cache_is_never_reused(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            saved = root / 'ffmpeg' / simple_build.build.FFMPEG_VERSION
            saved.mkdir(parents=True)
            atomic_json(saved / 'ready.json', {'source_sha256': 'wrong'})
            with mock.patch.object(simple_build.dependencies, 'fetch') as fetch:
                with self.assertRaises(ValueError): simple_build.ffmpeg(root, {}, {}, None)
            fetch.assert_not_called()

    def test_default_source_archive_is_committed_and_has_safe_permissions(self):
        with tempfile.TemporaryDirectory(prefix='cilex-source-test-', dir='/tmp') as temp:
            root = Path(temp)
            repo = root / 'repo'; repo.mkdir()
            def git(*args):
                return subprocess.run(['/usr/bin/git', '-c', 'core.hooksPath=/dev/null', '-c', 'user.name=Fixture',
                    '-c', 'user.email=fixture@example.invalid', *args], cwd=repo, check=True, capture_output=True, text=True)
            git('init', '--quiet')
            (repo / 'CMakeLists.txt').write_text('committed source\n')
            (repo / 'CMakeLists.txt').chmod(0o664)
            git('add', 'CMakeLists.txt'); git('commit', '--quiet', '--no-gpg-sign', '-m', 'fixture')
            commit = git('rev-parse', 'HEAD').stdout.strip()
            (repo / 'CMakeLists.txt').write_text('uncommitted changes\n')
            cache = root / 'cache'; cache.mkdir()
            args = easy.parser('build-installer').parse_args([])
            failed = {'mode': 'build-installer', 'exit_code': 15, 'states': {'installation': 'Unverified'}}
            with mock.patch.object(simple_build, 'REPOSITORY', repo), mock.patch.object(simple_build, 'homebrew', return_value=Path('/fixture/brew')), mock.patch.object(simple_build, 'prepare_brew', return_value={'python': '/fixture/python'}), mock.patch.object(simple_build.dependencies, 'provision_python', return_value=('/fixture/venv/python', {})), mock.patch.object(simple_build, 'ffmpeg', return_value=(root / 'ffmpeg', root / 'notices')), mock.patch.object(simple_build, 'collect_notices'), mock.patch.object(simple_build.deploy, 'execute', return_value=(failed, None)) as execute, contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(simple_build.locked_run(args, cache, root / 'output', {'developer_dir': '/fixture/developer'}), 15)
            options = execute.call_args.args[0]
            self.assertTrue(options['development'])
            self.assertEqual(options['source_commit'], commit)
            self.assertEqual(options['arch'], 'arm64')
            self.assertNotIn(' ', options['work_dir'])
            self.assertFalse(options['bootstrap'])
            with tarfile.open(options['source_archive']) as archive:
                self.assertEqual(archive.extractfile('CMakeLists.txt').read(), b'committed source\n')
                self.assertTrue(all(not m.mode & 0o022 for m in archive if not m.issym()))


if __name__ == '__main__': unittest.main()
