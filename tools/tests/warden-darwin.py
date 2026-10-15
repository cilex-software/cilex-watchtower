#!/usr/bin/env python3
"""Darwin Warden tests. Only temporary processes/data, no real app or launchd jobs.

Native tests compile isolated fixtures, so this is a build-host test, NOT proof
that a clean runtime target needs developer tools. Sleep/clock tests inject
clocks; they do not alter power settings or the system clock.
"""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'warden'))
import warden_darwin as d


class ClockTests(unittest.TestCase):
    def setUp(self):
        self.mono, self.wall = 0, 1000
        self.clock = d.ActivityClock(lambda: self.mono, lambda: self.wall)

    def advance(self, seconds, wall=None):
        self.mono += seconds
        self.wall += seconds if wall is None else wall

    def test_age_tracks_observed_changes_not_epoch(self):
        self.assertEqual(self.clock.age((1, 50, 123)), 0)
        self.advance(10)
        self.assertEqual(self.clock.age((1, 50, 123)), 10)
        self.advance(10)
        self.assertEqual(self.clock.age((1, 51, 1)), 0)

    def test_missing_log_does_not_disable_watchdog(self):
        self.clock.age(None)
        for _ in range(13):
            self.advance(10)
            age = self.clock.age(None)
        self.assertEqual(age, 130)

    def test_clock_jump_grants_fresh_grace(self):
        for jump in (3600, -3600):
            self.advance(1, jump)
            self.assertEqual(self.clock.age(None), 0)
            self.advance(10)
            self.assertEqual(self.clock.age(None), 10)

    def test_wake_with_paused_monotonic_grants_grace(self):
        self.advance(1, 3600)
        self.assertEqual(self.clock.age(None), 0)
        self.advance(10)
        self.assertEqual(self.clock.age(None), 10)

    def test_scheduler_pause_grants_grace(self):
        self.advance(100)
        self.assertEqual(self.clock.age(None), 0)


class IdentityTests(unittest.TestCase):
    def native_identity_fixture(self, failures=1, path_failures=0):
        native = mock.Mock()
        attempts = {'info': 0, 'path': 0}

        def info(pid, flavor, argument, pointer, length):
            attempts['info'] += 1
            if attempts['info'] <= failures:
                return 0
            value = pointer._obj
            value.pid, value.ppid, value.uid, value.status = pid, 1, 501, 2
            value.start_sec, value.start_usec = 123, 456
            return length

        def path(pid, buffer, length):
            attempts['path'] += 1
            if attempts['path'] <= path_failures:
                return 0
            buffer.value = b'/tmp/identity-fixture'
            return len(buffer.value)

        native.proc_pidinfo.side_effect = info
        native.proc_pidpath.side_effect = path
        return native

    def test_transient_native_identity_read_recovers_without_guess_or_signal(self):
        for info_failures, path_failures in ((2, 0), (0, 2)):
            native = self.native_identity_fixture(info_failures, path_failures)
            with self.subTest(info_failures=info_failures, path_failures=path_failures), \
                    mock.patch.object(d, 'libproc', return_value=native), \
                    mock.patch.object(d.os, 'kill') as kill, \
                    mock.patch.object(d.os, 'getsid', return_value=9), \
                    mock.patch.object(d.time, 'sleep'), \
                    mock.patch.object(d.subprocess, 'run') as ps:
                row = d.process_identity(999999)
                self.assertEqual(row['birth'], [123, 456])
                self.assertEqual(row['path'], os.path.realpath('/tmp/identity-fixture'))
                self.assertEqual(row['uid'], 501)
                self.assertEqual(row['session'], 9)
                self.assertTrue(all(call.args == (999999, 0) for call in kill.call_args_list))
                ps.assert_not_called()

    def test_persistent_live_unreadability_still_fails_closed(self):
        native = self.native_identity_fixture(100)
        live = subprocess.CompletedProcess([], 0, stdout='S\n')
        with mock.patch.object(d, 'libproc', return_value=native), \
                mock.patch.object(d.os, 'kill') as kill, \
                mock.patch.object(d.time, 'monotonic', side_effect=[0, .25, .5]), \
                mock.patch.object(d.time, 'sleep'), \
                mock.patch.object(d.subprocess, 'run', return_value=live):
            with self.assertRaisesRegex(PermissionError, 'pid=999999'):
                d.stop_records([{'pid': 999999}])
            self.assertTrue(all(call.args == (999999, 0) for call in kill.call_args_list))

    def test_unreadable_identity_disappearance_is_confirmed(self):
        with mock.patch.object(d, 'libproc', return_value=self.native_identity_fixture(100)), \
                mock.patch.object(d.os, 'kill', side_effect=[None, ProcessLookupError()]), \
                mock.patch.object(d.time, 'sleep'), \
                mock.patch.object(d.subprocess, 'run') as ps:
            self.assertIsNone(d.process_identity(999999))
            ps.assert_not_called()

    def test_unreadable_enumeration_has_no_wait_or_exit_claim_for_cleanup(self):
        with mock.patch.object(d, 'libproc', return_value=self.native_identity_fixture(100)), \
                mock.patch.object(d.time, 'sleep') as sleep, \
                mock.patch.object(d.os, 'kill') as kill:
            self.assertIsNone(d.process_identity(999999, allow_unreadable=True))
            sleep.assert_not_called()
            kill.assert_not_called()

    def test_pid_reuse_and_path_uid_session_mismatch(self):
        original = {'pid': 900, 'birth': [123, 456], 'uid': 501, 'path': '/tmp/app', 'session': 99}
        self.assertTrue(d.same_process(original, dict(original, ppid=1)))
        for key, value in [('pid', 901), ('birth', [124, 456]), ('uid', 502), ('path', '/tmp/other'), ('session', 100)]:
            self.assertFalse(d.same_process(original, dict(original, **{key: value})))

    def test_persisted_machine_identity_and_legacy_preservation(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'id' / 'identity.json'
            with mock.patch.object(d, 'platform_uuid', return_value='TEST-PLATFORM-UUID') as value:
                self.assertEqual(d.native_machine_key(path, legacy_enrolled=True), '')
                self.assertFalse(path.exists())
                first = d.native_machine_key(path)
                second = d.native_machine_key(path, legacy_enrolled=True)
                self.assertEqual(first, second)
                self.assertEqual(len(first), 71)
                self.assertEqual(value.call_count, 1)
                self.assertNotIn('TEST-PLATFORM', path.read_text())

    def test_bounded_log_retains_tail_and_rejects_links(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'runtime.log'
            path.write_bytes(b'0123456789')
            path.chmod(0o600)
            d.bound_log(path, limit=4)
            self.assertEqual(path.read_bytes(), b'')
            self.assertEqual(path.with_name('runtime.log.previous').read_bytes(), b'6789')
            link = Path(tmp) / 'link'
            link.symlink_to(path)
            with self.assertRaises(OSError):
                d.bound_log(link, limit=4)

    def test_private_records_reject_symlink_and_world_readable(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'record.json'
            d.atomic_private_json(path, {'schema': 1})
            link = Path(tmp) / 'link.json'
            link.symlink_to(path)
            with self.assertRaises(OSError):
                d.read_private_json(link)
            path.chmod(0o644)
            with self.assertRaises(RuntimeError):
                d.read_private_json(path)


@unittest.skipUnless(sys.platform == 'darwin', 'Darwin config defaults')
class ConfigurationTests(unittest.TestCase):
    def setUp(self):
        import warden
        self.w = warden

    def test_completed_child_wait_respects_explicit_shutdown_intent(self):
        for stopping, maintenance, expected in ((True, False, 'stopped'),
                                               (False, True, 'maintenance'),
                                               (False, False, 'died')):
            supervisor = self.w.Supervisor()
            supervisor.stopping = stopping
            child = mock.Mock()
            child.wait.return_value = -15
            with self.subTest(stopping=stopping, maintenance=maintenance), \
                    mock.patch.object(supervisor, 'maintenance_requested', return_value=maintenance):
                self.assertEqual(supervisor.watch(child), expected)

    def test_native_qt_dotted_backend_key_and_slash_compatibility(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, {'HOME': tmp}, clear=True):
            path = Path(tmp) / 'Library/Preferences/com.cilex-vision.Watchtower.plist'
            path.parent.mkdir(parents=True)
            for values, expected in (
                ({'auth.baseUrl': ' https://native.example.invalid/ ', 'auth.token': 'fixture-never-exposed'}, 'https://native.example.invalid/'),
                ({'auth/baseUrl': 'https://legacy.example.invalid/'}, 'https://legacy.example.invalid/'),
                ({'auth.baseUrl': 'https://native.example.invalid/', 'auth/baseUrl': 'https://stale.example.invalid/'}, 'https://native.example.invalid/'),
                ({'auth.baseUrl': '', 'auth/baseUrl': 'https://stale.example.invalid/'}, None),
                ({'auth.baseUrl': 42}, None),
                ({'unrelated.setting': 'fixture'}, None),
            ):
                path.write_bytes(plistlib.dumps(values))
                with self.subTest(keys=sorted(values)):
                    self.assertEqual(self.w.app_saved_backend(), expected)

    def test_native_paths_and_legacy_spool_preservation(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, {'HOME': tmp}, clear=True):
            with mock.patch.object(self.w, 'config_paths', return_value=[]), mock.patch.object(self.w, 'app_saved_backend', return_value=None):
                cfg = self.w.load_config()
                self.assertEqual(cfg['DATA_DIR'], str(Path(tmp) / 'Library/Application Support/Cilex Vision/Watchtower'))
                self.assertEqual(cfg['WARDEN_DIR'], str(Path(tmp) / 'Library/Application Support/CilexWatchtower/Warden'))
                legacy = Path(tmp) / '.local/share/watchtower-warden'
                legacy.mkdir(parents=True)
                self.assertEqual(self.w.load_config()['WARDEN_DIR'], str(legacy))

    def test_enrollment_token_refresh_preserves_configuration(self):
        with tempfile.TemporaryDirectory() as tmp:
            legacy = Path(tmp) / 'legacy.conf'
            deployed = Path(tmp) / 'deployment.conf'
            legacy.write_text('STATION_TOKEN=fixture-old\nAPP_CMD=/legacy\n')
            deployed.write_text('APP_CMD=/Applications/Watch tower.app/Contents/MacOS/watchtower\nINSTALLATION_ID=test\n')
            with mock.patch.object(self.w, 'config_paths', return_value=[str(legacy), str(deployed)]), mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(self.w, 'app_saved_backend', return_value=None):
                cfg = self.w.load_config()
                self.assertEqual(cfg['STATION_TOKEN'], 'fixture-old')
                self.assertEqual(cfg['APP_CMD'], '/Applications/Watch tower.app/Contents/MacOS/watchtower')
                legacy.write_text('STATION_TOKEN=fixture-refreshed\nAPP_CMD=/unrelated\n')
                with mock.patch.object(self.w, 'CFG', cfg):
                    self.w.refresh_station_token()
                self.assertEqual(cfg['STATION_TOKEN'], 'fixture-refreshed')
                self.assertEqual(cfg['APP_CMD'], '/Applications/Watch tower.app/Contents/MacOS/watchtower')

    def test_child_environment_uses_packaged_plugins_and_private_cache(self):
        with tempfile.TemporaryDirectory() as tmp:
            contents = Path(tmp) / 'Watch tower.app/Contents'
            (contents / 'PlugIns/gstreamer-1.0').mkdir(parents=True)
            (contents / 'Helpers').mkdir()
            (contents / 'Helpers/gst-plugin-scanner').touch()
            (contents / 'Helpers/ffmpeg').touch()
            cfg = dict(self.w.DEFAULTS, APP_CMD=str(contents / 'MacOS/watchtower'), INSTALLATION_ID='fixture')
            polluted = {'HOME': tmp, 'PATH': '/unrelated', 'DYLD_LIBRARY_PATH': '/bad', 'GST_PLUGIN_PATH': '/bad', 'PYTHONPATH': '/bad', 'QT_PLUGIN_PATH': '/bad'}
            with mock.patch.object(self.w, 'CFG', cfg), mock.patch.object(self.w, 'machine_id_hash', return_value=''), mock.patch.dict(os.environ, polluted, clear=True):
                env = self.w.Supervisor().app_env()
                for name in ('DYLD_LIBRARY_PATH', 'GST_PLUGIN_PATH', 'PYTHONPATH', 'QT_PLUGIN_PATH'):
                    self.assertNotIn(name, env)
                self.assertEqual(env['GST_PLUGIN_SYSTEM_PATH_1_0'], str(contents / 'PlugIns/gstreamer-1.0'))
                self.assertTrue(env['GST_REGISTRY_1_0'].startswith(str(Path(tmp) / 'Library/Caches/')))
                self.assertEqual(env['PATH'], str(contents / 'Helpers') + ':/usr/bin:/bin:/usr/sbin:/sbin')


@unittest.skipUnless(sys.platform == 'darwin', 'Requires real Darwin libproc/Mach APIs')
class NativeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='warden Тест with spaces ')
        cls.base = Path(cls.tmp.name)
        cls.gate = Path(os.environ['CILEX_TEST_SPAWN_GATE']).resolve() if os.environ.get('CILEX_TEST_SPAWN_GATE') else cls.base / 'cilex-spawn-gate'
        cls.child = cls.base / 'test-child'
        source = cls.base / 'child.c'
        source.write_text('#include <unistd.h>\n#include <stdlib.h>\n#include <stdio.h>\nint main(void) { const char *d=getenv("CHILD_DESCENDANT"); if(d && fork()==0) { setsid(); FILE *f=fopen(d,"w"); if(!f)return 2; fprintf(f,"%d",getpid()); fclose(f); for(;;) pause(); } const char *p=getenv("CHILD_READY"); if(p) { FILE *f=fopen(p,"w"); if(!f)return 2; fprintf(f,"%d %d",getpid(),getppid()); fclose(f); } for(;;) pause(); }\n')
        if not os.environ.get('CILEX_TEST_SPAWN_GATE'):
            subprocess.run(['/usr/bin/cc', '-Wall', '-Wextra', '-Werror', str(ROOT / 'warden/darwin_spawn_gate.c'), '-o', str(cls.gate)], check=True)
        subprocess.run(['/usr/bin/cc', '-Wall', '-Wextra', '-Werror', str(source), '-o', str(cls.child)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def setUp(self):
        self.test_dir = Path(tempfile.mkdtemp(dir=self.base))
        self.guard = None
        self.children = []
        self.command = [os.environ['CILEX_TEST_WARDEN_EXECUTABLE']] if os.environ.get('CILEX_TEST_WARDEN_EXECUTABLE') else [sys.executable, str(ROOT / 'warden/warden.py')]

    def tearDown(self):
        if self.guard:
            try:
                self.guard.close()
            except (RuntimeError, BrokenPipeError):
                self.guard.proc.stdin.close()
                self.guard.proc.wait(timeout=10)
                self.guard.proc.stdout.close()
        for child in self.children:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=5)

    def create_guard(self):
        self.guard = d.ProcessGuard(self.command, self.test_dir / 'state', 'isolated-test')
        return self.guard

    def spawn(self, guard=None):
        guard = guard or self.create_guard()
        env = dict(os.environ, CHILD_READY=str(self.test_dir / 'ready'))
        with open(os.devnull, 'wb') as output:
            child = guard.spawn(str(self.child), str(self.gate), env, output)
        self.children.append(child)
        self.wait_until(lambda: (self.test_dir / 'ready').exists())
        return child

    def wait_until(self, condition, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if condition():
                return
            time.sleep(.025)
        self.fail('Bounded readiness wait expired')

    def test_native_identity_and_metrics(self):
        row = d.process_identity(os.getpid())
        self.assertEqual(row['pid'], os.getpid())
        self.assertEqual(row['uid'], os.getuid())
        self.assertEqual(row['session'], os.getsid(0))
        self.assertTrue(row['birth'][0] > 0)
        self.assertTrue(Path(row['path']).is_file())
        cpu, mem, previous = d.host_load(None)
        self.assertIsNone(cpu)
        self.assertIsInstance(mem, float)
        time.sleep(.1)
        cpu, _, _ = d.host_load(previous)
        self.assertTrue(0 <= cpu <= 100)
        self.assertTrue(0 <= mem <= 100)
        self.assertTrue(d.platform_uuid())

    def test_runtime_status_uses_native_dotted_backend(self):
        home = self.test_dir / 'status-home'
        prefs = home / 'Library/Preferences/com.cilex-vision.Watchtower.plist'
        prefs.parent.mkdir(parents=True)
        prefs.write_bytes(plistlib.dumps({'auth.baseUrl': 'https://native.fixture.invalid', 'auth.token': 'fixture-only-not-station-token'}))
        before = prefs.read_bytes()
        environment = {'HOME': str(home), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
                       'WT_WARDEN_BACKEND_URL': '', 'WT_WARDEN_STATION_TOKEN': '',
                       'WT_WARDEN_WARDEN_DIR': str(self.test_dir / 'status-spool'),
                       'WT_WARDEN_DATA_DIR': str(self.test_dir / 'status-data')}
        result = subprocess.run(self.command + ['status'], env=environment, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0)
        self.assertIn("backend=https://native.fixture.invalid [the app's saved server]", result.stdout)
        self.assertIn('token=MISSING', result.stdout)
        self.assertNotIn('fixture-only-not-station-token', result.stdout + result.stderr)
        self.assertEqual(prefs.read_bytes(), before)

    def test_gate_eof_never_executes(self):
        read_fd, write_fd = os.pipe()
        env = dict(os.environ, CHILD_READY=str(self.test_dir / 'ready'))
        child = subprocess.Popen([str(self.gate), str(read_fd), str(self.child)], pass_fds=(read_fd,), env=env)
        self.children.append(child)
        os.close(read_fd)
        os.close(write_fd)
        self.assertEqual(child.wait(timeout=5), 75)
        self.assertFalse((self.test_dir / 'ready').exists())

    def test_guard_startup_timeout_closes_and_reaps_child(self):
        spawned = []
        original_popen = subprocess.Popen

        def record_popen(*args, **kwargs):
            proc = original_popen(*args, **kwargs)
            if args[0][0] == sys.executable:
                spawned.append(proc)
            return proc

        with mock.patch.object(d, 'GUARD_STARTUP_TIMEOUT', .1), mock.patch.object(d.subprocess, 'Popen', side_effect=record_popen):
            with self.assertRaisesRegex(RuntimeError, 'did not acknowledge'):
                d.ProcessGuard([sys.executable, '-c', 'import time; time.sleep(60)'],
                               self.test_dir / 'stall-state', 'stalled-start')
        self.assertEqual(len(spawned), 1)
        self.assertIsNotNone(spawned[0].poll())
        self.assertIsNone(d.process_identity(spawned[0].pid))
        self.assertTrue(spawned[0].stdin.closed)
        self.assertTrue(spawned[0].stdout.closed)

    def test_direct_parent_and_cleanup(self):
        child = self.spawn()
        row = d.process_identity(child.pid)
        self.assertEqual(row['path'], str(self.child.resolve()))
        self.assertEqual(row['ppid'], os.getpid())
        self.assertEqual(row['session'], os.getsid(0))
        self.guard.cleanup()
        self.assertIsNotNone(child.wait(timeout=5))
        self.assertIsNone(d.process_identity(child.pid))

    def test_repeated_child_exit_during_guard_cleanup(self):
        guard = self.create_guard()
        for iteration in range(12):
            with self.subTest(iteration=iteration):
                (self.test_dir / 'ready').unlink(missing_ok=True)
                child = self.spawn(guard)
                identity = d.process_identity(child.pid)
                self.assertEqual(identity['ppid'], os.getpid())
                # The fixture has finished exec and reported readiness. Race its
                # exit against guardian cleanup without affecting any real app.
                child.send_signal(signal.SIGTERM if iteration % 2 else signal.SIGKILL)
                guard.cleanup()
                self.assertIsNotNone(child.wait(timeout=5))
                self.assertIsNone(d.process_identity(child.pid))
                self.assertTrue(guard.healthy())

    def test_guard_failure_cleanup_uses_retained_identity(self):
        child = self.spawn()
        os.kill(self.guard.proc.pid, signal.SIGKILL)
        self.guard.proc.wait(timeout=5)
        self.assertFalse(self.guard.healthy())
        self.guard.cleanup()
        child.wait(timeout=5)
        self.assertIsNone(d.process_identity(child.pid))

    def test_guard_refuses_cross_installation_reuse(self):
        state = self.test_dir / 'state'
        state.mkdir(mode=0o700)
        d.atomic_private_json(state / 'processes.json', {'schema': 1, 'installation_id': 'other', 'uid': os.getuid()})
        with self.assertRaisesRegex(RuntimeError, 'installation identity'):
            d.ProcessGuard(self.command, state, 'isolated-test')

    def test_wrong_process_generation_is_never_signalled(self):
        child = self.spawn()
        row = d.process_identity(child.pid)
        row['birth'][1] += 1
        self.assertEqual(d.stop_records([row], timeout=.1), [])
        self.assertIsNone(child.poll())

    def test_parent_sigkill_reaps_child_without_launchd(self):
        driver = self.test_dir / 'driver.py'
        driver.write_text('''import sys,os,json,time
from pathlib import Path
sys.path.insert(0,sys.argv[1])
import warden_darwin as d
base=Path(sys.argv[2]);g=d.ProcessGuard(json.loads(sys.argv[3]),base/'state','isolated-test')
with open(os.devnull,'wb') as out:
 p=g.spawn(sys.argv[4],sys.argv[5],dict(os.environ,CHILD_DESCENDANT=str(base/'descendant-ready')),out)
(base/'driver-ready').write_text(json.dumps({'child':d.process_identity(p.pid),'guard':d.process_identity(g.proc.pid)}))
while True: time.sleep(1)
''')
        driver_proc = subprocess.Popen([sys.executable, str(driver), str(ROOT / 'warden'), str(self.test_dir), json.dumps(self.command), str(self.child), str(self.gate)])
        self.children.append(driver_proc)
        self.wait_until(lambda: (self.test_dir / 'driver-ready').exists())
        identities = json.loads((self.test_dir / 'driver-ready').read_text())
        self.wait_until(lambda: (self.test_dir / 'descendant-ready').exists())
        descendant_pid = int((self.test_dir / 'descendant-ready').read_text())
        descendant = d.process_identity(descendant_pid)
        self.assertNotEqual(descendant['session'], d.process_identity(driver_proc.pid)['session'])
        record = self.test_dir / 'state/processes.json'
        self.wait_until(lambda: any(row['pid'] == descendant_pid for row in json.loads(record.read_text())['processes']))
        os.kill(driver_proc.pid, signal.SIGKILL)
        driver_proc.wait(timeout=5)
        start = time.monotonic()
        self.wait_until(lambda: d.process_identity(identities['child']['pid']) is None)
        self.wait_until(lambda: d.process_identity(identities['guard']['pid']) is None)
        self.wait_until(lambda: d.process_identity(descendant_pid) is None)
        print('evidence: parent SIGKILL cleanup (including observed detached descendant) %.3fs' % (time.monotonic() - start))

    def start_warden(self):
        home = self.test_dir / 'home'
        home.mkdir(exist_ok=True)
        spool = self.test_dir / 'spool'
        data = self.test_dir / 'data'
        environment = {key: os.environ[key] for key in ('PATH', 'TMPDIR') if key in os.environ}
        environment.update(HOME=str(home), WT_WARDEN_APP_CMD=str(self.child),
            WT_WARDEN_SPAWN_GATE=str(self.gate), WT_WARDEN_WARDEN_DIR=str(spool),
            WT_WARDEN_DATA_DIR=str(data), WT_WARDEN_INSTALLATION_ID='isolated-test',
            WT_WARDEN_HANG_S='0', WT_WARDEN_BACKEND_URL='', WT_WARDEN_STATION_TOKEN='',
            WT_WARDEN_MAINTENANCE_FILE=str(self.test_dir / 'maintenance'),
            CHILD_READY=str(self.test_dir / 'ready'))
        output = open(self.test_dir / ('warden-%d.log' % len(self.children)), 'wb')
        proc = subprocess.Popen(self.command + ['run'], env=environment, stdout=output, stderr=subprocess.STDOUT)
        output.close()
        self.children.append(proc)
        return proc, environment

    def read_child(self):
        return int((self.test_dir / 'ready').read_text().split()[0])

    def test_warden_restart_duplicate_refusal_and_maintenance(self):
        warden, environment = self.start_warden()
        self.wait_until(lambda: (self.test_dir / 'ready').exists())
        child = self.read_child()
        self.assertEqual(d.process_identity(child)['ppid'], warden.pid)
        duplicate = subprocess.run(self.command + ['run'], env=environment,
                                   capture_output=True, timeout=5)
        self.assertEqual(duplicate.returncode, 3)
        start = time.monotonic()
        os.kill(child, signal.SIGKILL)
        self.wait_until(lambda: self.read_child() != child, timeout=12)
        recovered = self.read_child()
        self.assertEqual(d.process_identity(recovered)['ppid'], warden.pid)
        print('evidence: isolated Watchtower failure recovery %.3fs' % (time.monotonic() - start))
        marker = self.test_dir / 'maintenance'
        marker.write_text('maintenance')
        marker.chmod(0o600)
        self.wait_until(lambda: d.process_identity(recovered) is None)
        time.sleep(1.2)
        self.assertEqual(self.read_child(), recovered)
        marker.unlink()
        self.wait_until(lambda: self.read_child() != recovered)
        final_child = self.read_child()
        warden.terminate()
        self.assertEqual(warden.wait(timeout=12), 0)
        self.assertIsNone(d.process_identity(final_child))

    def test_warden_detects_guard_failure_and_exits_after_cleanup(self):
        warden, _ = self.start_warden()
        self.wait_until(lambda: (self.test_dir / 'ready').exists())
        child = self.read_child()
        record = self.test_dir / 'spool/process-guard/processes.json'
        rows = json.loads(record.read_text())
        start = time.monotonic()
        os.kill(rows['guard']['pid'], signal.SIGKILL)
        self.assertNotEqual(warden.wait(timeout=12), 0)
        self.assertIsNone(d.process_identity(child))
        print('evidence: Warden detects guard failure and cleans child %.3fs' % (time.monotonic() - start))

    def test_live_owner_prevents_second_guard(self):
        self.create_guard()
        with self.assertRaisesRegex(RuntimeError, 'still alive'):
            d.ProcessGuard(self.command, self.test_dir / 'state', 'isolated-test')


if __name__ == '__main__':
    unittest.main(verbosity=2)
