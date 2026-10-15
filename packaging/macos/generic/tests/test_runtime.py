"""Numeric fixtures + read-only native API checks; no app/setting mutations."""
import datetime
import json
import os
from pathlib import Path
import platform
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import runtime

BASE = 1791920000


def iso(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).isoformat()


def sample(offset, **changes):
    result = dict(epoch=BASE + offset, up=offset, active=0, livePipes=3,
                  frames=100 + 100 * offset, framesIn=120 + 120 * offset,
                  dec=3, lit=3, err=0)
    result.update(changes)
    return result


def line(offset, **changes):
    row = sample(offset, **changes)
    return iso(row['epoch']) + ' I default - [MEMTEL] ' + ' '.join(
        key + '=' + str(row[key]) + ('s' if key == 'up' else '') for key in runtime._NUMBER_KEYS)


def marker(pid=11, offset=0):
    return iso(BASE + offset) + ' I default - === watchtower start v1.1.781 pid=' + str(pid) + ' build=abcdef qt=6 ==='


def source_sample(offset, **changes):
    result = sample(offset, sources=[{'id': '%064x' % i, 'frames': 100 + offset * (i + 1),
        'age_ms': 30, 'decoder': True, 'error': False} for i in range(1, 4)], source_schema=1)
    result.update(changes)
    return result


def source_line(offset, **changes):
    value = {'schema': 1, 'up': offset, 'sources': source_sample(offset)['sources']}
    value.update(changes)
    return iso(BASE + offset) + ' I cilex.readiness - [VIDTEL] ' + json.dumps(value)


class ParserTests(unittest.TestCase):
    def parse(self, rows, now=BASE + 180):
        return runtime.parse_telemetry(rows, 11, BASE, now)

    def test_valid_session_and_current_numeric_only_evidence(self):
        result = self.parse([marker(), line(150), line(180)])
        self.assertTrue(result['known'])
        self.assertEqual(result['latest']['lit'], 3)
        self.assertNotIn('default', json.dumps(result))

    def test_wrong_pid_and_reused_pid_time_refused(self):
        self.assertEqual(self.parse([marker(12), line(180)])['reason'], 'VIDEO_LOG_BELONGS_TO_OTHER_PROCESS')
        self.assertEqual(self.parse([marker(offset=-30), line(180)])['reason'], 'VIDEO_START_TIME_MISMATCH')

    def test_malformed_new_boundary_discards_previous_success(self):
        result = self.parse([marker(), line(150), line(180), '=== watchtower start invalid'])
        self.assertFalse(result['known'])
        self.assertEqual(result['reason'], 'VIDEO_START_MARKER_INVALID')

    def test_stale_missing_future_and_duplicate_numbers_refused(self):
        for rows in ([marker(), line(30)], [line(180)], [marker(), line(250)],
                     [marker(), line(180) + ' lit=3'], [marker(), line(180, frames=-1)]):
            self.assertFalse(self.parse(rows)['known'])

    def test_timezone_and_invalid_timestamp(self):
        self.assertEqual(runtime.timestamp('2026-10-13T23:00:00+03:00'), runtime.timestamp('2026-10-13T20:00:00Z'))
        self.assertIsNone(runtime.timestamp('not-a-timestamp'))

    def test_full_observation_requires_150_seconds(self):
        rows = [sample(offset) for offset in range(30, 181, 30)]
        result = runtime.video_progress(rows, 150, 3)
        self.assertEqual(result['state'], 'AggregateVideoObserved')
        self.assertEqual(result['sample_span_seconds'], 150)
        self.assertEqual(result['individual_camera_identities'], 'Unverified')
        self.assertEqual(runtime.video_progress(rows[1:], 150, 3)['state'], 'Unverified')

    def test_every_sample_must_maintain_counts_and_no_errors(self):
        for changes in ({'lit': 2}, {'dec': 2}, {'err': 1}):
            rows = [sample(30), sample(60, **changes), sample(90)]
            self.assertEqual(runtime.video_progress(rows, 60, 3)['state'], 'Failed')

    def test_stall_reset_gap_and_clock_jumps_fail(self):
        for after in (sample(60, frames=sample(30)['frames']), sample(60, framesIn=0),
                      sample(120), sample(60, up=40)):
            self.assertEqual(runtime.video_progress([sample(30), after], 25, 3)['state'], 'Failed')

    def test_no_camera_video_is_not_a_pass(self):
        self.assertEqual(runtime.video_progress([sample(30, lit=0), sample(60, lit=0)], 25)['state'], 'Unverified')

    def test_vidtel_matches_tick_and_retains_only_hashes_and_numbers(self):
        result = self.parse([marker(), line(150), source_line(150), line(180), source_line(180)])
        self.assertEqual(len(result['latest']['sources']), 3)
        self.assertEqual(result['latest']['sources'][0]['id'], '%064x' % 1)
        self.assertNotIn('[VIDTEL]', json.dumps(result))

    def test_vidtel_cannot_cross_process_boundary_or_match_wrong_uptime(self):
        result = self.parse([marker(12), source_line(150), marker(), line(180), source_line(180, up=150)], now=BASE + 183)
        self.assertNotIn('sources', result['latest'])

    def test_fresh_incomplete_tick_waits_for_adjacent_write_then_fails_if_missing(self):
        rows = [marker(), line(150), source_line(150), line(180)]
        result = self.parse(rows)
        self.assertEqual(result['latest']['up'], 150)
        later = self.parse(rows, now=BASE + 183)
        self.assertEqual(runtime.video_progress(later['samples'], 25, 3)['reason'], 'VIDEO_SOURCE_EVIDENCE_MISSING')
        completed = self.parse(rows + [source_line(180)], now=BASE + 181)
        self.assertEqual(runtime.video_progress(completed['samples'], 25, 3)['state'], 'PerSourceVideoObserved')

    def test_strict_source_json_rejects_invalid_fields_duplicates_and_sizes(self):
        good = {'schema': 1, 'up': 180, 'sources': source_sample(180)['sources']}
        malformed = [dict(good, schema=True), dict(good, schema=2), dict(good, up=True),
                     dict(good, token='fixture-secret'), dict(good, sources=good['sources'] * 2)]
        for key, value in (('id', 'raw-camera-url'), ('frames', True), ('frames', -1),
                           ('frames', 2**53), ('age_ms', float('nan')), ('decoder', 1), ('error', 'false')):
            source = dict(good['sources'][0], **{key: value})
            malformed.append(dict(good, sources=[source]))
        for body in malformed:
            with self.subTest(body_keys=sorted(body)), self.assertRaises(ValueError):
                runtime.parse_source_telemetry(json.dumps(body))
        with self.assertRaises(ValueError):
            runtime.parse_source_telemetry('{"schema":1,"schema":1,"up":180,"sources":[]}')
        with mock.patch.object(runtime, 'MAX_SOURCE_JSON_BYTES', 8), self.assertRaises(ValueError):
            runtime.parse_source_telemetry(json.dumps(good))
        with mock.patch.object(runtime, 'MAX_SOURCE_ROWS', 2), self.assertRaises(ValueError):
            runtime.parse_source_telemetry(json.dumps(good))

    def test_invalid_or_duplicate_source_tick_is_failed_without_exposing_payload(self):
        for ending in ([source_line(180, credential='fixture-secret')], [source_line(180)] * 2):
            result = self.parse([marker(), line(150), source_line(150), line(180)] + ending)
            self.assertEqual(runtime.video_progress(result['samples'], 25, 3)['reason'], 'VIDEO_SOURCE_TELEMETRY_INVALID')
            self.assertNotIn('fixture-secret', json.dumps(result))
            self.assertNotIn('credential', json.dumps(result))

    def test_each_source_advances_for_150_seconds_and_identity_basis_is_explicit(self):
        rows = [source_sample(offset) for offset in range(30, 181, 30)]
        result = runtime.video_progress(rows, 150, 3)
        self.assertEqual(result['state'], 'PerSourceVideoObserved')
        self.assertEqual(result['individual_camera_identities'], 'StableInitialSourceHashes')
        self.assertEqual(result['expected_source_identities_from'], 'initial_observed_set')
        self.assertEqual(len(result['source_frame_deltas']), 3)
        matched = runtime.video_progress(rows, 150, 3, result['source_hashes'])
        self.assertEqual(matched['individual_camera_identities'], 'ExternallyMatchedSourceHashes')
        mismatch = runtime.video_progress(rows, 150, 3, ['f' * 64, *result['source_hashes'][1:]])
        self.assertEqual(mismatch['state'], 'Failed')
        missing = runtime.video_progress([sample(150), sample(180)], 25, 3, result['source_hashes'])
        self.assertEqual(missing['reason'], 'EXPECTED_SOURCE_IDENTITIES_NOT_OBSERVED')

    def test_individual_stall_cannot_hide_behind_aggregate_progress(self):
        rows = [source_sample(30), source_sample(60)]
        rows[1]['sources'][0]['frames'] = rows[0]['sources'][0]['frames']
        self.assertEqual(runtime.video_progress(rows, 25, 3)['reason'], 'VIDEO_INDIVIDUAL_SOURCE_STALLED_OR_RESET')
        rows[1]['sources'][0]['frames'] = 0
        self.assertEqual(runtime.video_progress(rows, 25, 3)['reason'], 'VIDEO_INDIVIDUAL_SOURCE_STALLED_OR_RESET')

    def test_changed_missing_duplicate_stale_or_errored_source_is_not_a_pass(self):
        for change in ({'id': 'f' * 64}, {'id': '%064x' % 2}, {'age_ms': 5001},
                       {'age_ms': None}, {'decoder': False}, {'error': True}):
            rows = [source_sample(30), source_sample(60)]
            rows[-1]['sources'][0].update(change)
            self.assertEqual(runtime.video_progress(rows, 25, 3)['state'], 'Failed')
        rows = [source_sample(30), source_sample(60)]
        rows[-1]['sources'].pop()
        self.assertEqual(runtime.video_progress(rows, 25, 3)['state'], 'Failed')


class ReadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='runtime Тест ')
        self.root = Path(self.tmp.name).resolve()
        self.row = {'pid': 11, 'uid': os.getuid(), 'birth': [BASE, 0]}

    def tearDown(self):
        self.tmp.cleanup()

    def test_rotated_start_marker_and_current_samples(self):
        (self.root / 'watchtower.log.1').write_text(marker() + '\n' + line(150) + '\n')
        path = self.root / 'watchtower.log'
        path.write_text(line(180) + '\nprivate-token=do-not-return-this\n')
        result = runtime.read_telemetry(path, self.row, BASE + 180)
        self.assertTrue(result['known'])
        self.assertNotIn('do-not-return', json.dumps(result))
        self.assertEqual(len(result['samples']), 2)

    def test_rotated_vidtel_read_is_bound_to_same_session(self):
        (self.root / 'watchtower.log.1').write_text(marker() + '\n' + line(150) + '\n' + source_line(150) + '\n')
        path = self.root / 'watchtower.log'
        path.write_text(line(180) + '\n' + source_line(180) + '\nprivate-token=do-not-return-this\n')
        result = runtime.read_telemetry(path, self.row, BASE + 180)
        self.assertEqual(runtime.video_progress(result['samples'], 25, 3)['state'], 'PerSourceVideoObserved')
        self.assertNotIn('do-not-return', json.dumps(result))

    def test_many_historical_sessions_cannot_exhaust_current_observation(self):
        history = self.root / 'watchtower.log.1'
        with history.open('w') as stream:
            for session in range(101):
                stream.write(marker(pid=900 + session, offset=-6000) + '\n')
                for _ in range(100):
                    stream.write(line(-5900) + '\n')
        path = self.root / 'watchtower.log'
        path.write_text('\n'.join([marker(), line(150), source_line(150), line(180), source_line(180)]) + '\n')
        result = runtime.read_telemetry(path, self.row, BASE + 180)
        self.assertTrue(result['known'])
        self.assertEqual(result['pid'], 11)
        self.assertEqual([row['up'] for row in result['samples']], [150, 180])
        self.assertEqual(runtime.video_progress(result['samples'], 25, 3)['state'], 'PerSourceVideoObserved')

    def test_current_session_tail_is_bounded_but_preserves_start_identity(self):
        path = self.root / 'watchtower.log'
        with path.open('w') as stream:
            stream.write(marker() + '\n')
            for offset in range(1, 5001):
                stream.write(line(offset) + '\n')
                stream.write(source_line(offset) + '\n')
        with mock.patch.object(runtime, 'MAX_TELEMETRY_ROWS', 12):
            result = runtime.read_telemetry(path, self.row, BASE + 5000)
        self.assertTrue(result['known'])
        self.assertEqual(result['start']['epoch'], BASE)
        self.assertEqual(len(result['samples']), 6)
        self.assertEqual(result['samples'][0]['up'], 4995)

    def test_oversized_current_line_is_rejected_with_bounded_readline(self):
        path = self.root / 'watchtower.log'
        path.write_text(marker() + '\n' + line(180) + '\n' + '[VIDTEL] ' + 'x' * runtime.MAX_LOG_LINE_BYTES)
        result = runtime.read_telemetry(path, self.row, BASE + 180)
        self.assertEqual(result['reason'], 'VIDEO_LOG_LINE_LIMIT_EXCEEDED')
        self.assertEqual(result['samples'], [])

    def test_malformed_latest_start_cannot_reuse_historical_success(self):
        path = self.root / 'watchtower.log'
        path.write_text('\n'.join([marker(), line(150), source_line(150), line(180), source_line(180),
                                   '=== watchtower start invalid', line(180), source_line(180)]))
        result = runtime.read_telemetry(path, self.row, BASE + 180)
        self.assertFalse(result['known'])
        self.assertEqual(result['reason'], 'VIDEO_START_MARKER_INVALID')

    def test_symlink_refusal_and_size_cap(self):
        actual = self.root / 'other'
        actual.write_text(marker() + '\n' + line(180))
        path = self.root / 'watchtower.log'
        path.symlink_to(actual)
        self.assertEqual(runtime.read_telemetry(path, self.row)['reason'], 'VIDEO_LOG_SYMLINK_REFUSED')
        path.unlink()
        path.write_text('oversize')
        with mock.patch.object(runtime, 'MAX_LOG_BYTES', 3):
            self.assertEqual(runtime.read_telemetry(path, self.row)['reason'], 'VIDEO_LOG_READ_LIMIT_EXCEEDED')

    def test_owner_mismatch_refused(self):
        path = self.root / 'watchtower.log'
        path.write_text(marker() + '\n' + line(180))
        result = runtime.read_telemetry(path, dict(self.row, uid=os.getuid() + 1), BASE + 180)
        self.assertEqual(result['reason'], 'VIDEO_LOG_OWNER_OR_TYPE_INVALID')


class GraphTests(unittest.TestCase):
    def setUp(self):
        self.target = {'uid': os.getuid(), 'id': 'fixture', 'path': Path('/Applications/watchtower.app'), 'home': Path.home()}
        path = str(self.target['path'])
        self.owner = dict(pid=10, ppid=1, uid=os.getuid(), birth=[BASE, 1], path=path + '/Contents/Resources/warden/cilex-warden', session=1)
        self.guard = dict(self.owner, pid=12, ppid=10, birth=[BASE, 2])
        self.app = dict(self.owner, pid=11, ppid=10, birth=[BASE, 3], path=path + '/Contents/MacOS/watchtower')
        self.rows = [self.owner, self.guard, self.app]
        self.record = {'schema': 1, 'installation_id': 'fixture', 'uid': os.getuid(), 'owner': self.owner, 'guard': self.guard, 'processes': [self.app]}

    def evidence(self, rows=None, record=None):
        return runtime.process_evidence(self.target, rows=rows or self.rows, record=record or self.record)

    def test_expected_guardian_is_not_duplicate(self):
        result = self.evidence()
        self.assertEqual(result['state'], 'ProcessVerified')
        self.assertFalse(result['duplicates'])

    def test_real_duplicate_and_wrong_uid_fail(self):
        self.assertTrue(self.evidence(self.rows + [dict(self.app, pid=99)])['duplicates'])
        self.assertTrue(self.evidence(self.rows + [dict(self.owner, pid=99)])['duplicates'])
        self.assertEqual(self.evidence([self.owner, self.guard, dict(self.app, uid=os.getuid() + 1)])['state'], 'Unverified')

    def test_parent_birth_session_and_registry_mismatch_fail(self):
        for changes in ({'ppid': 1}, {'birth': [BASE + 1, 3]}, {'session': 99}):
            self.assertEqual(self.evidence([self.owner, self.guard, dict(self.app, **changes)])['state'], 'Unverified')
        self.assertEqual(self.evidence(record=dict(self.record, installation_id='other'))['state'], 'Unverified')


class VerifyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='runtime observe ')
        self.root = Path(self.tmp.name).resolve()
        self.target = {'uid': os.getuid(), 'id': 'fixture', 'path': self.root / 'watchtower.app', 'home': self.root, 'support': self.root}
        self.app = dict(pid=11, ppid=10, uid=os.getuid(), path='/app', birth=[BASE, 0], session=1)
        self.process = dict(state='ProcessVerified', app=self.app, reason='OK')
        self.context = {'target': self.target, 'manifest': {'version': '1.1.781'}, 'write_evidence': True, 'evidence_dir': self.root, 'run_id': 'fixture'}

    def tearDown(self):
        self.tmp.cleanup()

    def test_plain_verify_and_dry_run_never_write_evidence(self):
        snapshot = {'known': True, 'samples': [sample(150), sample(180)], 'latest': sample(180)}
        for options in ({'mode': 'verify'}, {'mode': 'install', 'dry_run': True}):
            with mock.patch.object(runtime, 'process_evidence', return_value=self.process), mock.patch.object(runtime, 'window_visibility', return_value={'state': 'Visible'}), mock.patch.object(runtime, 'read_telemetry', return_value=snapshot):
                result = runtime.verify(options, self.context)
            self.assertEqual(list(self.root.iterdir()), [])
            self.assertEqual(result['gui_video'], 'VisibleWithRecentAggregateVideo')
            self.assertEqual(result['backend'], 'Unverified')
            self.assertFalse(result['full_success'])

    def test_missing_receipt_returns_unverified_without_writes(self):
        context = dict(self.context)
        context.pop('manifest')
        result = runtime.verify({'mode': 'verify'}, context)
        self.assertEqual(result['runtime_health'], 'Unverified')
        self.assertEqual(result['findings'][0]['id'], 'PROTECTED_INSTALL_RECEIPT_UNAVAILABLE_OR_INVALID')
        self.assertFalse(result['full_success'])
        self.assertEqual(list(self.root.iterdir()), [])

    def test_large_owned_receipt_verifies_without_relaxing_guardian_limit(self):
        receipt = self.root / 'receipt.json'
        manifest = {'version': '1.1.781', 'files': [{'path': 'fixture-' + str(i), 'sha256': 'a' * 64} for i in range(16000)]}
        receipt.write_text(json.dumps({'installation_id': 'fixture', 'uid': os.getuid(),
            'install_dir': str(self.target['path']), 'manifest': manifest}))
        receipt.chmod(0o600)
        self.assertGreater(receipt.stat().st_size, runtime.MAX_GUARD_RECORD_BYTES)
        self.assertLess(receipt.stat().st_size, runtime.MAX_RECEIPT_BYTES)
        before = receipt.read_bytes()
        context = {'target': self.target, 'write_evidence': True, 'evidence_dir': self.root}
        with mock.patch.object(runtime, 'process_evidence', return_value={'state': 'Unverified', 'reason': 'APP_MISSING'}) as processes:
            result = runtime.verify({'mode': 'verify'}, context)
        processes.assert_called_once_with(self.target, manifest)
        self.assertEqual([finding['id'] for finding in result['findings']], ['APP_MISSING'])
        self.assertEqual(receipt.read_bytes(), before)
        self.assertEqual(list(self.root.iterdir()), [receipt])
        with self.assertRaises(runtime.DeployError) as error:
            runtime._private_json(receipt, os.getuid())
        self.assertEqual(error.exception.finding, 'runtime.record_size')

    def test_receipt_larger_than_32_mib_remains_rejected(self):
        receipt = self.root / 'receipt.json'
        with receipt.open('wb') as stream:
            stream.truncate(runtime.MAX_RECEIPT_BYTES + 1)
        receipt.chmod(0o600)
        with self.assertRaises(runtime.DeployError) as error:
            runtime._manifest(self.target, {})
        self.assertEqual(error.exception.finding, 'runtime.record_size')

    def test_runtime_version_mismatch_cannot_pass(self):
        snapshot = {'known': True, 'start': {'version': '1.1.1'}, 'samples': [sample(150), sample(180)], 'latest': sample(180)}
        with mock.patch.object(runtime, 'process_evidence', return_value=self.process), mock.patch.object(runtime, 'window_visibility', return_value={'state': 'Visible'}), mock.patch.object(runtime, 'read_telemetry', return_value=snapshot):
            result = runtime.verify({'mode': 'verify'}, self.context)
        self.assertEqual(result['runtime_health'], 'UnverifiedVersionMismatch')
        self.assertEqual(result['gui_video'], 'Unverified')

    def test_postinstall_writes_only_numeric_evidence_in_run_directory(self):
        with mock.patch.object(runtime, 'process_evidence', return_value={'state': 'Unverified', 'reason': 'APP_MISSING'}):
            result = runtime.verify({'mode': 'install'}, self.context)
        path = Path(result['evidence'][0])
        self.assertEqual(path.parent, self.root)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertFalse(json.loads(path.read_text())['full_success'])

    def test_duration_and_timeout_cannot_be_unbounded(self):
        for options in ({'observe_seconds': 149}, {'observe_seconds': 99999}, {'observe_seconds': 150, 'observation_timeout': float('nan')}, {'expected_cameras': '3'}):
            with self.assertRaises(runtime.DeployError):
                runtime.verify(options, self.context)

    def test_external_source_expectations_are_validated(self):
        identity = '%064x' % 1
        for options in ({'expected_source_ids': []}, {'expected_source_ids': [identity, identity]},
                        {'expected_source_ids': ['private-url']}, {'expected_source_ids': [identity], 'expected_cameras': 3}):
            with self.assertRaises(runtime.DeployError):
                runtime.verify(options, self.context)

    def test_explicit_150_seconds_proves_each_stable_source_without_writes(self):
        clock = [float(BASE)]
        def snap(*_):
            offset = int(clock[0] - BASE)
            rows = [source_sample(t) for t in range(0, offset + 1, 30)]
            return {'known': True, 'samples': rows, 'latest': rows[-1]}
        with mock.patch.object(runtime, 'process_evidence', return_value=self.process), mock.patch.object(runtime, 'window_visibility', return_value={'state': 'Visible'}), mock.patch.object(runtime, 'read_telemetry', side_effect=snap), mock.patch.object(runtime.time, 'time', side_effect=lambda: clock[0]), mock.patch.object(runtime.time, 'monotonic', side_effect=lambda: clock[0]), mock.patch.object(runtime.time, 'sleep', side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)):
            result = runtime.verify({'mode': 'verify', 'observe_seconds': 150, 'expected_cameras': 3}, self.context)
        self.assertEqual(result['observed_seconds'], 150)
        self.assertEqual(result['gui_video'], 'VisibleAndPerSourceVideoObserved')
        self.assertEqual(result['video_evidence']['expected_source_identities_from'], 'initial_observed_set')
        self.assertFalse(result['full_success'])
        self.assertEqual(list(self.root.iterdir()), [])

    def test_instantaneous_external_source_match_does_not_infer_complete_acceptance(self):
        rows = [source_sample(150), source_sample(180)]
        snapshot = {'known': True, 'samples': rows, 'latest': rows[-1]}
        with mock.patch.object(runtime, 'process_evidence', return_value=self.process), mock.patch.object(runtime, 'window_visibility', return_value={'state': 'Visible'}), mock.patch.object(runtime, 'read_telemetry', return_value=snapshot):
            result = runtime.verify({'mode': 'verify', 'expected_source_ids': [row['id'] for row in rows[0]['sources']]}, self.context)
        self.assertEqual(result['gui_video'], 'VisibleWithRecentPerSourceVideo')
        self.assertEqual(result['video_evidence']['individual_camera_identities'], 'ExternallyMatchedSourceHashes')
        self.assertEqual(result['playback_export'], 'Unverified')
        self.assertFalse(result['full_success'])
        self.assertEqual(list(self.root.iterdir()), [])

    def test_explicit_observation_uses_fresh_150_second_span(self):
        clock = [float(BASE)]
        def snap(*_):
            offset = int(clock[0] - BASE)
            rows = [sample(t) for t in range(0, offset + 1, 30)]
            return {'known': True, 'samples': rows, 'latest': rows[-1]}
        with mock.patch.object(runtime, 'process_evidence', return_value=self.process), mock.patch.object(runtime, 'window_visibility', return_value={'state': 'Visible'}), mock.patch.object(runtime, 'read_telemetry', side_effect=snap), mock.patch.object(runtime.time, 'time', side_effect=lambda: clock[0]), mock.patch.object(runtime.time, 'monotonic', side_effect=lambda: clock[0]), mock.patch.object(runtime.time, 'sleep', side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)):
            result = runtime.verify({'mode': 'verify', 'observe_seconds': 150, 'expected_cameras': 3}, self.context)
        self.assertEqual(result['observed_seconds'], 150)
        self.assertEqual(result['gui_video'], 'VisibleAndAggregateVideoObserved')
        self.assertFalse(result['full_success'])
        self.assertEqual(list(self.root.iterdir()), [])

    def test_process_restart_and_hidden_window_cannot_pass(self):
        with mock.patch.object(runtime, 'process_evidence', return_value=self.process), mock.patch.object(runtime, 'window_visibility', return_value={'state': 'NotObserved'}), mock.patch.object(runtime, 'read_telemetry', return_value={'known': False, 'reason': 'STALE'}):
            result = runtime.verify({'mode': 'verify', 'observe_seconds': 150}, self.context)
        self.assertEqual(result['gui_video'], 'UnverifiedVisibility')
        self.assertIn('GUI_NOT_CONTINUOUSLY_OBSERVED', [row['id'] for row in result['findings']])


@unittest.skipUnless(platform.system() == 'Darwin', 'Native Mac API inspection only')
class NativeReadonlyTests(unittest.TestCase):
    def test_current_process_native_identity(self):
        row = next(p for p in runtime.process_snapshot() if p['pid'] == os.getpid())
        self.assertEqual(row['uid'], os.getuid())
        self.assertEqual(row['session'], os.getsid(0))
        self.assertGreater(row['birth'][0], 0)

    def test_window_metadata_has_no_titles_or_capture(self):
        result = runtime.window_visibility(os.getpid())
        self.assertIn(result['state'], ('Visible', 'NotObserved', 'Unverified'))
        self.assertTrue(all(set(window).issubset({'id', 'width', 'height'}) for window in result['windows']))


if __name__ == '__main__':
    unittest.main(verbosity=2)
