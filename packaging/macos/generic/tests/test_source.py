"""Authenticated loopback HTTPS Git fixture. No real credentials or repositories.

The fixture creates its own local Git history and TLS key; the deployment code
only fetches/checks it. CA trust applies only to the fixture Git wrapper. No
system trust, credential store, Git global config or external network is used.
"""
import base64
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest
import urllib.parse
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import source
from common import DeployError

FIXTURE_TOKEN = 'fixture-only-token-never-a-real-credential'


def native_fixture_tools_available():
    if sys.platform != 'darwin':
        return False
    try:
        developer = subprocess.run(['/usr/bin/xcode-select', '-p'], capture_output=True, text=True, timeout=5)
        return developer.returncode == 0 and Path(developer.stdout.strip()).is_dir()
    except (OSError, subprocess.TimeoutExpired):
        return False


class SourceTreeTests(unittest.TestCase):
    def test_source_link_target_is_bound_even_for_identical_content(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'a').write_text('same content')
            (root / 'b').write_text('same content')
            link = root / 'selected'
            link.symlink_to('a')
            before = source.source_tree_hash(root)
            link.unlink()
            link.symlink_to('b')
            self.assertNotEqual(source.source_tree_hash(root), before)

    def test_source_escaping_link_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root = base / 'source'
            root.mkdir()
            (base / 'outside').write_text('outside')
            (root / 'selected').symlink_to('../outside')
            with self.assertRaises(DeployError) as error:
                source.source_tree_hash(root)
            self.assertEqual(error.exception.finding, 'source.link')

    def test_offline_archive_with_git_directory_still_checks_tree(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            archive = base / 'source.tar'
            with tarfile.open(archive, 'w') as stream:
                for name, value in (('CMakeLists.txt', b'project(Fixture)\n'), ('.git/config', b'fixture only\n')):
                    info = tarfile.TarInfo(name)
                    info.mode = 0o644
                    info.size = len(value)
                    stream.addfile(info, io.BytesIO(value))
            run = base / 'run'
            run.mkdir()
            options = {'dependencies': 'offline', 'source_archive': str(archive),
                       'source_sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
                       'source_commit': '0' * 40}
            with mock.patch.object(source, 'command', side_effect=AssertionError('Offline archive must not run Git')):
                root, provenance = source.obtain(options, run)
                self.assertEqual(source.obtain(options, run)[1], provenance)
                (root / '.git/config').write_text('modified')
                with self.assertRaises(DeployError) as error:
                    source.obtain(options, run)
                self.assertEqual(error.exception.finding, 'source.modified')


@unittest.skipUnless(native_fixture_tools_available(), 'Native Git/TLS fixture requires installed Mac build tools; never invoke developer stubs')
class SourceHTTPSFixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='source HTTPS Тест ')
        cls.base = Path(cls.tmp.name).resolve()
        cls.origin = cls.base / 'origin.git'
        cls.work = cls.base / 'fixture-writer'
        cls.audit = cls.base / 'argv-env-audit.jsonl'
        cls.key = cls.base / 'fixture-key.pem'
        cls.cert = cls.base / 'fixture-ca.pem'
        subprocess.run(['/usr/bin/openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(cls.key), '-out', str(cls.cert), '-days', '1', '-subj', '/CN=localhost'], check=True, capture_output=True, timeout=20)
        cls.git('init', '--quiet', '--bare', str(cls.origin))
        cls.git('init', '--quiet', str(cls.work))
        cls.git('-C', str(cls.work), 'config', 'user.name', 'Fixture')
        cls.git('-C', str(cls.work), 'config', 'user.email', 'fixture@example.invalid')
        (cls.work / 'CMakeLists.txt').write_text('project(Fixture)\n')
        cls.git('-C', str(cls.work), 'add', 'CMakeLists.txt')
        cls.git('-C', str(cls.work), 'commit', '--quiet', '-m', 'fixture initial history')
        cls.git('-C', str(cls.work), 'branch', '-M', 'main')
        cls.initial = cls.git('-C', str(cls.work), 'rev-parse', 'HEAD').strip()
        cls.git('-C', str(cls.work), 'tag', '-a', 'existing-tag', '-m', 'fixture annotated tag')
        cls.git('-C', str(cls.work), 'remote', 'add', 'fixture', str(cls.origin))
        cls.git('-C', str(cls.work), 'push', '--quiet', 'fixture', 'main', 'refs/tags/existing-tag')
        cls.git('-C', str(cls.origin), 'symbolic-ref', 'HEAD', 'refs/heads/main')
        cls.backend = Path(cls.git('--exec-path').strip()) / 'git-http-backend'
        cls.requests = []
        expected = 'Basic ' + base64.b64encode(('x-access-token:' + FIXTURE_TOKEN).encode()).decode()

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                self.handle_git()

            def do_POST(self):
                self.handle_git()

            def handle_git(self):
                self.connection.settimeout(5)
                authorized = self.headers.get('Authorization') == expected
                cls.requests.append({'method': self.command, 'authorized': authorized})
                if not authorized:
                    self.send_response(401)
                    self.send_header('WWW-Authenticate', 'Basic realm="isolated-git-fixture"')
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
                parsed = urllib.parse.urlsplit(self.path)
                if not parsed.path.startswith('/origin.git/') or '..' in parsed.path:
                    self.send_error(404)
                    return
                size = int(self.headers.get('Content-Length', '0'))
                if size > 16 * 1024 * 1024:
                    self.send_error(413)
                    return
                body = self.rfile.read(size)
                env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'GIT_PROJECT_ROOT': str(cls.base),
                       'GIT_HTTP_EXPORT_ALL': '1', 'PATH_INFO': parsed.path,
                       'REQUEST_METHOD': self.command, 'QUERY_STRING': parsed.query,
                       'CONTENT_TYPE': self.headers.get('Content-Type', ''),
                       'CONTENT_LENGTH': str(size), 'REMOTE_USER': 'fixture'}
                proc = subprocess.run([str(cls.backend)], input=body, capture_output=True, env=env, timeout=10)
                header, payload = proc.stdout.split(b'\r\n\r\n', 1)
                rows = [row.decode().split(':', 1) for row in header.split(b'\r\n')]
                code = next((int(value.strip().split()[0]) for key, value in rows if key.lower() == 'status'), 200)
                self.send_response(code)
                for key, value in rows:
                    if key.lower() != 'status':
                        self.send_header(key, value.strip())
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(str(cls.cert), str(cls.key))
        cls.server.socket = context.wrap_socket(cls.server.socket, server_side=True)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = 'https://localhost:%d/origin.git' % cls.server.server_port
        # The wrapper records argv/env but deliberately never reads token FDs.
        # It adds only this fixture's CA, then execs the real Apple Git binary.
        cls.wrapper = cls.base / 'fixture-git'
        cls.wrapper.write_text('''#!/usr/bin/python3
import json,os,sys
with open(%r,'a') as stream:
 stream.write(json.dumps({'argv':sys.argv[1:],'env':dict(os.environ)})+'\\n')
os.execv('/usr/bin/git',['/usr/bin/git','-c',%r]+sys.argv[1:])
''' % (str(cls.audit), 'http.sslCAInfo=' + str(cls.cert)))
        cls.wrapper.chmod(0o700)

    @classmethod
    def git(cls, *args):
        return subprocess.run(['/usr/bin/git', *args], check=True, capture_output=True, text=True,
                              env={'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(cls.base), 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null'}, timeout=20).stdout

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)
        cls.tmp.cleanup()

    def run_dir(self):
        return Path(tempfile.mkdtemp(prefix='deployment ', dir=self.base))

    def obtain(self, run=None, **options):
        read_fd, write_fd = os.pipe()
        os.write(write_fd, (FIXTURE_TOKEN + '\n').encode())
        os.close(write_fd)
        try:
            configured = {'repository': self.url, 'noninteractive': True, 'dependencies': 'manual', 'gh_token_fd': read_fd}
            configured.update(options)
            directory = run or self.run_dir()
            return source.obtain(configured, directory, git=str(self.wrapper), log=directory / 'source.log')
        finally:
            os.close(read_fd)

    def test_exact_existing_annotated_tag_and_token_channel(self):
        root, provenance = self.obtain(tag='existing-tag')
        self.assertEqual(provenance['commit'], self.initial)
        self.assertEqual(provenance['tag'], 'existing-tag')
        self.assertEqual(provenance['requested_ref'], 'refs/tags/existing-tag')
        self.assertEqual(self.git('-C', str(root), 'rev-parse', 'HEAD').strip(), self.initial)
        audit = self.audit.read_text()
        self.assertNotIn(FIXTURE_TOKEN, audit)
        self.assertTrue(any('CILEX_GH_TOKEN_FD' in row['env'] for row in map(json.loads, audit.splitlines())))
        self.assertTrue(any(row['authorized'] for row in self.requests))
        for path in root.parent.rglob('*'):
            if path.is_file():
                self.assertNotIn(FIXTURE_TOKEN.encode(), path.read_bytes())

    def test_main_fetch_is_fresh_and_resumed_commit_stays_pinned(self):
        run = self.run_dir()
        root, first = self.obtain(run)
        (self.work / 'next.txt').write_text('new upstream revision\n')
        self.git('-C', str(self.work), 'add', 'next.txt')
        self.git('-C', str(self.work), 'commit', '--quiet', '-m', 'fixture newer main')
        latest = self.git('-C', str(self.work), 'rev-parse', 'HEAD').strip()
        self.git('-C', str(self.work), 'push', '--quiet', 'fixture', 'main')
        _, fresh = self.obtain()
        self.assertEqual(fresh['commit'], latest)
        self.assertNotEqual(first['commit'], latest)
        _, resumed = self.obtain(run)
        self.assertEqual(resumed['commit'], first['commit'])
        self.assertEqual(self.git('-C', str(root), 'rev-parse', 'HEAD').strip(), first['commit'])

    def test_absent_tag_never_falls_back(self):
        run = self.run_dir()
        with self.assertRaises(DeployError) as error:
            self.obtain(run, tag='definitely-absent-tag')
        self.assertEqual(error.exception.finding, 'source.fetch_source')
        self.assertFalse((run / 'source-provenance.json').exists())
        head = subprocess.run(['/usr/bin/git', '-C', str(run / 'source'), 'rev-parse', '--verify', 'HEAD'], capture_output=True, timeout=10)
        self.assertNotEqual(head.returncode, 0)

    def test_modified_checkout_is_refused_on_resume(self):
        run = self.run_dir()
        root, _ = self.obtain(run)
        (root / 'uncommitted.txt').write_text('preserve this change')
        with self.assertRaises(DeployError) as error:
            self.obtain(run)
        self.assertEqual(error.exception.finding, 'source.modified')
        self.assertTrue((root / 'uncommitted.txt').is_file())

    def test_offline_missing_archive_never_connects(self):
        before = len(self.requests)
        with self.assertRaises(DeployError) as error:
            source.obtain({'repository': self.url, 'dependencies': 'offline', 'noninteractive': True}, self.run_dir(), git=str(self.wrapper))
        self.assertEqual(error.exception.finding, 'source.offline_missing')
        self.assertEqual(len(self.requests), before)


if __name__ == '__main__':
    unittest.main(verbosity=2)
