"""Real temporary Git repos and inert files; never compile/install or call GitHub."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'packaging'))
import build_state as state


class BuildStateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='Cilex build тест ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / 'repo'; self.repo.mkdir()
        self.cache = self.root / 'cache'
        self.git('init', '--quiet', '-b', 'main')
        self.put('CMakeLists.txt', 'project(watchtower VERSION 1.2.3 LANGUAGES CXX)\n')
        self.put('src/main.cpp', 'committed application\n')
        self.put('warden/warden.py', 'WARDEN_VERSION = "1.5.0"\n')
        self.commit()
        self.console = contextlib.redirect_stdout(io.StringIO())
        self.console.__enter__(); self.addCleanup(self.console.__exit__, None, None, None)

    def git(self, *args, repo=None, check=True):
        return subprocess.run(['git', '-c', 'core.hooksPath=/dev/null', '-c', 'user.name=Fixture',
            '-c', 'user.email=fixture@example.invalid', '-C', str(repo or self.repo), *args],
            capture_output=True, text=True, check=check)

    def put(self, name, data):
        path = self.repo / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text(data)
        return path

    def commit(self):
        self.git('add', '.'); self.git('commit', '--quiet', '--no-gpg-sign', '-m', 'fixture')
        return self.git('rev-parse', 'HEAD').stdout.strip()

    def prepare(self, **kwargs):
        return state.prepare(self.repo, 'linux-app', update=False, root=self.cache, **kwargs)

    def successful(self, **kwargs):
        plan = self.prepare(**kwargs)
        binary = self.root / 'output' / 'watchtower'; binary.parent.mkdir(exist_ok=True)
        binary.write_bytes(b'fixture compiled executable\n')
        state.record_success(plan, [('binary', binary)], metadata={'fixture': True})
        return plan, binary

    def remote(self):
        bare = self.root / 'remote.git'
        self.git('init', '--bare', '--quiet', str(bare))
        self.git('remote', 'add', 'origin', str(bare))
        self.git('push', '--quiet', '-u', 'origin', 'main')
        writer = self.root / 'writer'
        self.git('clone', '--quiet', '--branch', 'main', str(bare), str(writer))
        return bare, writer

    def remote_commit(self, writer):
        (writer / 'src/main.cpp').write_text('new remote committed source\n')
        self.git('add', '.', repo=writer); self.git('commit', '--quiet', '--no-gpg-sign', '-m', 'remote', repo=writer)
        self.git('push', '--quiet', 'origin', 'main', repo=writer)
        return self.git('rev-parse', 'HEAD', repo=writer).stdout.strip()

    def test_first_build_is_needed_and_snapshot_contains_committed_code_only(self):
        self.put('src/main.cpp', 'local edit is not compiled\n')
        self.put('private-untracked/new.cpp', 'untracked and excluded\n')
        plan = self.prepare()
        self.assertTrue(plan['build'])
        self.assertEqual((Path(plan['source']) / 'src/main.cpp').read_text(), 'committed application\n')
        self.assertFalse((Path(plan['source']) / 'private-untracked').exists())
        self.assertEqual((self.repo / 'src/main.cpp').read_text(), 'local edit is not compiled\n')

    def test_existing_build_skips_noninteractive_and_prints_absolute_binary_location(self):
        _, binary = self.successful()
        with contextlib.redirect_stdout(io.StringIO()) as text, mock.patch.object(state.sys.stdin, 'isatty', return_value=False):
            plan = self.prepare()
        self.assertFalse(plan['build'])
        self.assertIn(str(binary), text.getvalue())
        self.assertIn('no new committed code', text.getvalue())

    def test_duplicate_decline_never_prepares_or_modifies_a_source_worktree(self):
        self.successful()
        with mock.patch.object(state.sys.stdin, 'isatty', return_value=True), mock.patch.object(state, 'snapshot') as snapshot:
            plan = self.prepare(ask=lambda _: 'no')
        self.assertFalse(plan['build']); snapshot.assert_not_called()

    def test_duplicate_requires_an_explicit_yes(self):
        self.successful()
        with mock.patch.object(state.sys.stdin, 'isatty', return_value=True):
            self.assertFalse(self.prepare(ask=lambda _: '')['build'])
            self.assertTrue(self.prepare(ask=lambda _: 'yes')['build'])
        self.assertTrue(self.prepare(rebuild='yes')['build'])

    def test_new_committed_code_builds_without_duplicate_prompt(self):
        self.successful()
        self.put('src/main.cpp', 'new committed code\n'); self.commit()
        with mock.patch.object(state.sys.stdin, 'isatty', return_value=True):
            self.assertTrue(self.prepare(ask=lambda _: self.fail('unexpected rebuild prompt'))['build'])

    def test_documentation_only_commit_reuses_same_binary(self):
        self.successful()
        self.put('docs/note.md', 'not a compilation input\n'); self.commit()
        self.assertFalse(self.prepare(rebuild='no')['build'])

    def test_changed_output_is_not_silently_reused_or_rebuilt(self):
        _, binary = self.successful(); binary.write_bytes(b'tampered')
        with self.assertRaisesRegex(ValueError, 'No rebuild was confirmed'):
            self.prepare(rebuild='no')
        self.assertTrue(self.prepare(rebuild='yes')['build'])

    def test_missing_output_requires_confirmation_to_rebuild_same_code(self):
        _, binary = self.successful(); binary.unlink()
        with self.assertRaises(ValueError): self.prepare(rebuild='no')
        self.assertTrue(self.prepare(rebuild='yes')['build'])

    def test_different_configuration_does_not_reuse_an_incompatible_build(self):
        self.successful(settings={'qt': 'one'})
        with self.assertRaises(ValueError): self.prepare(settings={'qt': 'two'}, rebuild='no')
        self.assertTrue(self.prepare(settings={'qt': 'two'}, rebuild='yes')['build'])

    def test_no_success_receipt_is_created_when_outputs_are_absent(self):
        plan = self.prepare()
        with self.assertRaises(ValueError): state.record_success(plan, [('binary', self.root/'missing')])
        self.assertFalse((self.cache / 'receipts').exists())

    def test_source_modified_during_build_cannot_get_a_success_receipt(self):
        plan = self.prepare()
        (Path(plan['source']) / 'src/main.cpp').write_text('uncommitted during build')
        binary = self.root / 'binary'; binary.write_bytes(b'executable')
        with self.assertRaisesRegex(ValueError, 'source changed'):
            state.record_success(plan, [('binary', binary)])

    def test_cached_snapshot_with_local_edits_is_not_reset(self):
        plan = self.prepare()
        source = Path(plan['source']) / 'src/main.cpp'; source.write_text('keep this edit')
        with self.assertRaisesRegex(ValueError, 'cache was modified'): self.prepare()
        self.assertEqual(source.read_text(), 'keep this edit')

    def test_untracked_source_in_cached_snapshot_is_not_compiled(self):
        plan = self.prepare()
        extra = Path(plan['source'])/'src/new-local.cpp'; extra.write_text('keep this local source')
        with self.assertRaisesRegex(ValueError, 'cache was modified'): self.prepare()
        self.assertTrue(extra.exists())

    def test_bundle_resource_change_invalidates_the_record(self):
        plan = self.prepare(); bundle = self.root/'bundle'; bundle.mkdir()
        (bundle/'executable').write_bytes(b'executable'); (bundle/'resource').write_bytes(b'one')
        state.record_success(plan, [('bundle', bundle)])
        (bundle/'resource').write_bytes(b'two')
        with self.assertRaises(ValueError): self.prepare(rebuild='no')

    def test_update_fetches_and_pulls_new_files_when_checkout_is_clean(self):
        _, writer = self.remote(); new = self.remote_commit(writer)
        plan = state.prepare(self.repo, 'linux-app', update=True, root=self.cache)
        self.assertEqual(plan['commit'], new)
        self.assertEqual(self.git('rev-parse', 'HEAD').stdout.strip(), new)
        self.assertIn('new remote', (Path(plan['source'])/'src/main.cpp').read_text())

    def test_update_with_local_edits_preserves_them_and_builds_fetched_commit(self):
        _, writer = self.remote(); old = self.git('rev-parse', 'HEAD').stdout.strip()
        self.put('src/main.cpp', 'keep local edit'); new = self.remote_commit(writer)
        plan = state.prepare(self.repo, 'linux-app', update=True, root=self.cache)
        self.assertEqual(plan['commit'], new)
        self.assertEqual(self.git('rev-parse', 'HEAD').stdout.strip(), old)
        self.assertEqual((self.repo/'src/main.cpp').read_text(), 'keep local edit')

    def test_failed_remote_check_cannot_claim_no_new_code_or_use_stale_ref(self):
        bare, _ = self.remote(); self.git('remote', 'set-url', 'origin', str(bare)+'-missing')
        with self.assertRaisesRegex(ValueError, 'Could not check remote updates'):
            state.prepare(self.repo, 'linux-app', update=True, root=self.cache)
        self.assertTrue(self.prepare()['build'])

    def test_diverged_history_is_not_rebased_or_reset(self):
        _, writer = self.remote(); self.remote_commit(writer)
        self.put('src/local.cpp', 'local committed code'); local = self.commit()
        with self.assertRaisesRegex(ValueError, 'diverged'):
            state.prepare(self.repo, 'linux-app', update=True, root=self.cache)
        self.assertEqual(self.git('rev-parse', 'HEAD').stdout.strip(), local)

    def test_local_commits_ahead_of_remote_are_retained(self):
        self.remote(); self.put('src/local.cpp', 'local committed'); local = self.commit()
        plan = state.prepare(self.repo, 'linux-app', update=True, root=self.cache)
        self.assertEqual(plan['commit'], local)

    def test_explicit_revision_does_not_change_checkout_or_build_other_code(self):
        self.remote(); old = self.git('rev-parse', 'HEAD').stdout.strip()
        self.put('src/main.cpp', 'later'); latest = self.commit()
        plan = state.prepare(self.repo, 'linux-app', revision=old, update=True, root=self.cache)
        self.assertEqual(plan['commit'], old)
        self.assertEqual(self.git('rev-parse', 'HEAD').stdout.strip(), latest)

    def test_unverified_older_binary_requires_explicit_build_consent(self):
        old = self.put('build/watchtower', 'unverified compiled binary')
        with self.assertRaises(ValueError): self.prepare(rebuild='no')
        self.assertTrue(self.prepare(rebuild='yes')['build'])
        self.assertTrue(old.exists())

    def test_directory_receipt_detects_contained_link_changes(self):
        bundle = self.root/'bundle'; bundle.mkdir(); (bundle/'real').write_text('code')
        (bundle/'link').symlink_to('real')
        before = state.output_digest(bundle)
        (bundle/'link').unlink(); (bundle/'link').symlink_to('other')
        self.assertNotEqual(before, state.output_digest(bundle))

    def test_output_permission_change_requires_confirmation(self):
        _, binary = self.successful(); binary.chmod(0o755)
        with self.assertRaises(ValueError): self.prepare(rebuild='no')

    def test_build_inputs_in_another_source_folder_are_not_ignored(self):
        self.successful(); self.put('another-component/source.cpp', 'new code'); self.commit()
        self.assertTrue(self.prepare(rebuild='no')['build'])

    def test_rename_of_a_filename_starting_with_UU_is_not_an_unmerged_conflict(self):
        self.put('UUold.cpp', 'committed code'); self.commit()
        self.git('mv', 'UUold.cpp', 'renamed.cpp')
        self.assertTrue(self.prepare()['build'])
        self.assertTrue((self.repo/'renamed.cpp').exists())

    def test_warden_build_is_not_repeated_for_unrelated_app_edits(self):
        plan = state.prepare(self.repo, 'windows-warden', update=False, root=self.cache)
        binary = self.root/'warden.exe'; binary.write_bytes(b'inert executable')
        state.record_success(plan, [('binary', binary)])
        self.put('src/main.cpp', 'different app code'); self.commit()
        plan = state.prepare(self.repo, 'windows-warden', update=False, rebuild='no', root=self.cache)
        self.assertFalse(plan['build'])

    def test_qt_sdk_build_is_not_repeated_for_unrelated_app_edits(self):
        self.put('tools/build-patched-qt/build.sh','TAG=v6.12.0-beta1\n')
        self.put('third_party/qt-patches/patch','committed patch'); self.commit()
        plan = state.prepare(self.repo, 'linux-qt', update=False, root=self.cache)
        binary = self.root/'libQtCore.so'; binary.write_bytes(b'inert SDK library')
        state.record_success(plan, [('binary', binary)])
        self.put('src/main.cpp', 'different app code'); self.commit()
        self.assertFalse(state.prepare(self.repo, 'linux-qt', update=False, rebuild='no', root=self.cache)['build'])

    def test_windows_wrapper_records_and_skips_without_compiling(self):
        pwsh = shutil.which('pwsh')
        if not pwsh: self.skipTest('PowerShell is unavailable')
        project = Path(__file__).resolve().parents[2]
        def quote(value): return "'"+str(value).replace("'", "''")+"'"
        script = self.root/'windows-check.ps1'
        binary = self.root/'compiled тест.exe'
        script.write_text(r'''$ErrorActionPreference='Stop'
$PSNativeCommandArgumentPassing='Legacy'
foreach($name in @('Microsoft.PowerShell.Utility','Microsoft.PowerShell.Management')){
  Import-Module ([IO.Path]::Combine($PSHOME,'Modules',$name,($name+'.psd1')))
}
Import-Module MODULE
$settings=@{QtRoot='C:\Qt Folder\6.12';Label='a "quoted" value'}
$plan=Start-CilexBuild -Repository REPO -BuildProfile windows-local -Update No -Rebuild No -Python PYTHON -Cache CACHE -Settings $settings
if(-not $plan.build){throw 'first build skipped'}
[IO.File]::WriteAllText(BINARY,'inert compiled fixture')
Complete-CilexBuild -Plan $plan -Outputs @{binary=BINARY}
$plan=Start-CilexBuild -Repository REPO -BuildProfile windows-local -Update No -Rebuild No -Python PYTHON -Cache CACHE -Settings $settings
if($plan.build){throw 'duplicate build started'}
if($plan.existing.outputs[0].path -ne BINARY){throw 'absolute binary path lost'}
if($plan.existing.settings.Label -ne 'a "quoted" value'){throw 'settings quoting was changed'}
[IO.File]::Delete($plan.PlanPath)
[Console]::WriteLine('wrapper passed')
'''.replace('MODULE', quote(project/'packaging/windows/BuildState.psm1'))
           .replace('REPO',quote(self.repo)).replace('PYTHON',quote(sys.executable))
           .replace('CACHE',quote(self.cache)).replace('BINARY',quote(binary)))
        result = subprocess.run([pwsh,'-NoProfile','-File',str(script)],capture_output=True,text=True,timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertIn(str(binary), result.stdout)
        self.assertIn('wrapper passed', result.stdout)

    def test_pinned_controller_reuses_only_same_settings_and_intact_output(self):
        plan = state.prepare_pinned('fixture-inputs', 'fixture-commit', '1.2.3',
                                    'macos-package-build', {'development': True}, root=self.cache)
        binary = self.root/'pinned-binary'; binary.write_bytes(b'inert compiled fixture')
        state.record_success(plan, [('binary', binary)], metadata={'built': {'version': '1.2.3'}})
        self.assertFalse(state.prepare_pinned('fixture-inputs', 'fixture-commit', '1.2.3',
            'macos-package-build', {'development': True}, rebuild='no', root=self.cache)['build'])
        with self.assertRaises(ValueError):
            state.prepare_pinned('fixture-inputs', 'fixture-commit', '1.2.3',
                'macos-package-build', {'development': False}, rebuild='no', root=self.cache)
        binary.unlink()
        with self.assertRaises(ValueError):
            state.prepare_pinned('fixture-inputs', 'fixture-commit', '1.2.3',
                'macos-package-build', {'development': True}, rebuild='no', root=self.cache)

    def historical_mac(self):
        helper = b'committed helper fixture\n'
        self.put('packaging/macos/generic/common.py', helper.decode()); commit = self.commit()
        package = self.root/'old-package'; binary = package/'watchtower.app/Contents/MacOS/watchtower'
        binary.parent.mkdir(parents=True); binary.write_bytes(b'inert compiled application')
        image = self.root/'old-installer.dmg'; image.write_bytes(b'inert disk image')
        manifest = {'version': '1.2.3', 'source': {'commit': commit}, 'arch': 'arm64',
            'distribution': 'development', 'helper_provenance': {'files': [
                {'path': 'common.py', 'sha256': state.hashlib.sha256(helper).hexdigest()}]},
            'files': [{'path': 'watchtower.app/Contents/MacOS/watchtower', 'sha256': state.file_digest(binary)}]}
        state.atomic_json(package/'artifact-manifest.json', manifest)
        result = self.root/'Library/Caches/CilexWatchtower/SimpleInstaller/runs/old-run/result.json'
        state.atomic_json(result, {'exit_code': 0, 'artifacts': {'package_root': str(package),
            'installer': {'installer': str(image), 'sha256': state.file_digest(image)}}})
        return commit, package, binary, image

    def test_historical_dmg_reuse_checks_committed_helpers_and_outputs(self):
        commit, package, binary, image = self.historical_mac()
        settings = state.build_settings({'arch': 'arm64', 'distribution': 'development'})
        root = state.prepare_cache(self.cache)
        with mock.patch.object(state.Path, 'home', return_value=self.root):
            record = state.discover_mac_builds(self.repo, commit, 'fixture-inputs', settings, root, rebuild='no')
        self.assertEqual(record['outputs'][0]['path'], str(binary))
        self.assertEqual(record['outputs'][1]['path'], str(image))
        self.assertIsNotNone(state.matching_build(root, 'fixture-inputs', 'macos-dmg', settings))

    def test_historical_same_source_dmg_needs_consent_if_unverified_or_different_settings(self):
        commit, package, binary, image = self.historical_mac()
        settings = state.build_settings({'arch': 'arm64', 'distribution': 'production'})
        root = state.prepare_cache(self.cache)
        with mock.patch.object(state.Path, 'home', return_value=self.root):
            with self.assertRaisesRegex(ValueError, 'No rebuild was confirmed'):
                state.discover_mac_builds(self.repo, commit, 'fixture-inputs', settings, root, rebuild='no')
            settings['distribution'] = 'development'; image.write_bytes(b'changed image')
            with self.assertRaisesRegex(ValueError, 'No rebuild was confirmed'):
                state.discover_mac_builds(self.repo, commit, 'fixture-inputs', settings, root, rebuild='no')

    def test_windows_warden_copies_cached_runtime_to_requested_build_without_compiling(self):
        pwsh = shutil.which('pwsh')
        if not pwsh: self.skipTest('PowerShell is unavailable')
        project = Path(__file__).resolve().parents[2]
        for name in ('packaging/build_state.py', 'packaging/windows/BuildState.psm1', 'packaging/windows/build-warden.ps1'):
            destination = self.repo/name; destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(project/name, destination)
        self.commit()
        runtime = self.root/'previous/warden'; runtime.mkdir(parents=True)
        binary = runtime/'warden.exe'; binary.write_bytes(b'inert executable')
        (runtime/'install-windows.ps1').write_text('inert install fixture')
        plan = state.prepare(self.repo, 'windows-warden', update=False, root=self.cache)
        state.record_success(plan, [('binary', binary), ('runtime', runtime)])
        def quote(value): return "'"+str(value).replace("'", "''")+"'"
        script = self.root/'reuse-warden.ps1'
        script.write_text('''$ErrorActionPreference='Stop'
foreach($name in @('Microsoft.PowerShell.Utility','Microsoft.PowerShell.Management')){
  Import-Module ([IO.Path]::Combine($PSHOME,'Modules',$name,($name+'.psd1')))
}
& ENTRY -Dist DIST -UpdateSource No -Rebuild No
'''.replace('ENTRY', quote(self.repo/'packaging/windows/build-warden.ps1')).replace('DIST', quote(self.root/'next-dist')))
        tools = self.root/'tools'; tools.mkdir(); (tools/'python').symlink_to(sys.executable)
        env = dict(os.environ, CILEX_BUILD_STATE_DIR=str(self.cache), PATH=str(tools)+os.pathsep+os.environ['PATH'])
        result = subprocess.run([pwsh, '-NoProfile', '-File', str(script)], env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertEqual((self.root/'next-dist/warden/warden.exe').read_bytes(), binary.read_bytes())
        self.assertIn('without recompiling', result.stdout)

    def test_linux_entry_builds_committed_source_then_skips_identical_output(self):
        project = Path(__file__).resolve().parents[2]
        for name in ('packaging/build_state.py','packaging/build-state.sh','packaging/linux/build-local.sh'):
            destination = self.repo/name; destination.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(project/name, destination)
            destination.chmod(0o755)
        self.put('.gitignore','/build/\n'); self.commit()
        self.put('src/main.cpp','local edit must be excluded')
        tools = self.root/'tools'; tools.mkdir()
        calls = self.root/'cmake-calls.jsonl'
        cmake = tools/'cmake'
        cmake.write_text('#!'+sys.executable+'\n'+'''import json,os,sys
from pathlib import Path
a=sys.argv[1:]
with Path(os.environ['FIXTURE_CMAKE_CALLS']).open('a') as f:f.write(json.dumps(a)+'\\n')
if '-S' in a:
 assert 'local edit' not in (Path(a[a.index('-S')+1])/'src/main.cpp').read_text()
if '--build' in a:
 p=Path(a[a.index('--build')+1])/'watchtower';p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(b'inert compiled fixture');p.chmod(0o755)
'''); cmake.chmod(0o755)
        (tools/'nproc').write_text('#!/bin/sh\necho 2\n');(tools/'nproc').chmod(0o755)
        (tools/'uname').write_text('#!/bin/sh\ncase "$1" in -m) echo x86_64;; *) echo Linux;; esac\n');(tools/'uname').chmod(0o755)
        env=dict(os.environ,PATH=str(tools)+os.pathsep+os.environ['PATH'],
                 CILEX_BUILD_STATE_DIR=str(self.cache),FIXTURE_CMAKE_CALLS=str(calls),
                 WT_BUILD_DIR=str(self.repo/'build'),WT_QT_PREFIX=str(self.root/'qt'))
        def build(): return subprocess.run(['bash',str(self.repo/'packaging/linux/build-local.sh'),'--update','no','--rebuild','no'],env=env,capture_output=True,text=True,timeout=30)
        first=build();self.assertEqual(first.returncode,0,first.stdout+first.stderr)
        binary=self.repo/'build/watchtower';self.assertIn(str(binary),first.stdout)
        self.assertEqual(len(calls.read_text().splitlines()),2)
        second=build();self.assertEqual(second.returncode,0,second.stdout+second.stderr)
        self.assertIn('Existing binary: '+str(binary),second.stdout)
        self.assertEqual(len(calls.read_text().splitlines()),2)
        self.put('src/main.cpp','new committed code');self.commit()
        third=build();self.assertEqual(third.returncode,0,third.stdout+third.stderr)
        self.assertEqual(len(calls.read_text().splitlines()),4)


if __name__ == '__main__': unittest.main()
