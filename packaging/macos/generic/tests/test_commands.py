"""Bounded tool execution must not deadlock, leak secrets or fake protocol output."""
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import common


class CommandTests(unittest.TestCase):
    def python(self, code, **options):
        return common.command([sys.executable, '-I', '-B', '-c', code], **options)

    def test_input_output_are_drained_concurrently_with_unicode(self):
        payload = 'данные ' * 40000
        proc = self.python("import sys;sys.stdout.write('x'*200000);sys.stdout.flush();data=sys.stdin.read();sys.stderr.write(str(len(data)))", input=payload)
        self.assertEqual(proc.stdout, 'x' * 200000)
        self.assertEqual(proc.stderr, str(len(payload)))

    def test_absent_input_is_eof_not_an_inherited_prompt(self):
        proc = self.python("import sys;print('EOF' if not sys.stdin.read() else 'unexpected')", timeout=5)
        self.assertEqual(proc.stdout.strip(), 'EOF')

    def test_excess_output_fails_even_when_exit_check_is_disabled(self):
        with self.assertRaises(common.DeployError) as caught:
            self.python("import sys;sys.stdout.write('x'*1000000)", output_limit=16384, check=False)
        self.assertEqual(caught.exception.finding, 'command.output_limit')

    def test_timeout_preserves_redacted_diagnostics_and_stops_session(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            marker, log = root / 'child.pid', root / 'output.log'
            token = common.secret('fixture-confidential-token-09ad4')
            code = "import subprocess,sys,time;from pathlib import Path;p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(60)']);Path(sys.argv[1]).write_text(str(p.pid));print(sys.argv[2],flush=True);time.sleep(60)"
            started = time.monotonic()
            with self.assertRaises(common.DeployError) as caught:
                common.command([sys.executable, '-I', '-B', '-c', code, str(marker), token], timeout=1, log=log)
            self.assertEqual(caught.exception.finding, 'command.timeout')
            self.assertLess(time.monotonic() - started, 5)
            text = log.read_text()
            self.assertNotIn(token, text)
            self.assertIn('[REDACTED]', text)
            self.assertIn('command.timeout', text)
            self.assertEqual(log.stat().st_mode & 0o777, 0o600)
            pid = int(marker.read_text())
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                import subprocess
                state = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True).stdout.strip()
                if not state or state.startswith('Z'):
                    break
                time.sleep(.05)
            self.assertTrue(not state or state.startswith('Z'), 'Timed-out helper child remains active')

    def test_log_retention_is_bounded_after_append(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / 'output.log'
            log.write_bytes(b'x' * (common.COMMAND_OUTPUT_LIMIT + 100))
            log.chmod(0o600)
            self.python("print('fresh diagnostics')", log=log)
            self.assertLessEqual(log.stat().st_size, common.COMMAND_OUTPUT_LIMIT)
            data = log.read_bytes()
            self.assertTrue(data.startswith(b'[Earlier diagnostics truncated'))
            self.assertIn(b'fresh diagnostics', data)

    def test_interruption_retains_diagnostics_before_propagating(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / 'interrupted.log'
            selector = common.selectors.DefaultSelector()
            original_select = selector.select
            calls = []
            def interrupt_after_read(timeout):
                if calls:
                    raise KeyboardInterrupt()
                ready = original_select(5)
                calls.append(True)
                return ready
            with mock.patch.object(common.selectors, 'DefaultSelector', return_value=selector), \
                 mock.patch.object(selector, 'select', side_effect=interrupt_after_read):
                with self.assertRaises(KeyboardInterrupt):
                    self.python("import time;print('retained before interruption',flush=True);time.sleep(60)", log=log)
            self.assertIn('retained before interruption', log.read_text())
            self.assertIn('command.interrupted', log.read_text())

    def test_changed_key_and_hardlinked_protected_file_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / 'runs'
            run = common.RunRecord(base, {}, {}, 'helper')
            identity = run.data['run_id']
            run.close()
            (base / '.resume-key').write_bytes(b'')
            with self.assertRaises(common.DeployError) as caught:
                common.RunRecord(base, {}, {}, 'helper', identity)
            self.assertEqual(caught.exception.finding, 'resume.key_integrity')
            (base / '.resume-key').write_bytes(b'1' * 32)
            os.link(base / '.resume-key', base / 'linked-key')
            with self.assertRaises(common.DeployError):
                common.checked_private_file(base / '.resume-key')


if __name__ == '__main__':
    unittest.main()
