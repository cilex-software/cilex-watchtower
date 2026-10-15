"""Read-only Darwin runtime evidence; never launch, repair, register or authenticate.

CGWindowListCopyWindowInfo supplies only numeric window metadata (no screenshot,
window titles or consent requests). Flight-recorder output is reduced to start
identity, numeric MEMTEL counters and non-secret VIDTEL source hashes/counters;
no log lines/configuration/credentials are returned. Stable source hashes do not
prove camera-name mapping or representative playback/export.
"""
import ctypes
from collections import deque
import datetime
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import re
import stat
import time

from common import DeployError, atomic_json, utc

SCHEMA = 1
MAX_LOG_BYTES = 16 * 1024 * 1024
MAX_TOTAL_LOG_BYTES = 64 * 1024 * 1024
MAX_LOG_AGE = 75
MAX_GUARD_RECORD_BYTES = 1024 * 1024
MAX_RECEIPT_BYTES = 32 * 1024 * 1024
MAX_SOURCE_ROWS = 1024
MAX_SOURCE_JSON_BYTES = 256 * 1024
MAX_LOG_LINE_BYTES = MAX_SOURCE_JSON_BYTES + 4096
MAX_TELEMETRY_ROWS = 2048
_SOURCE_ID = re.compile(r'^[a-f0-9]{64}$')
_START = re.compile(r'^(\S+)\s+[DIWCF]\s+.*=== watchtower start v(\S+) pid=(\d+) build=\S+')
_NUMBER_KEYS = ('up', 'active', 'livePipes', 'frames', 'framesIn', 'dec', 'lit', 'err')
_NUMBER = {key: re.compile(r'(?<![A-Za-z0-9_])' + key + r'=(\d+)' + ('s' if key == 'up' else '') + r'(?=[^A-Za-z0-9_]|$)') for key in _NUMBER_KEYS}


def _error(finding, en):
    return DeployError(finding, en, 'verification',
        ru='Проверка работы не подтверждена (' + finding + '); приложение не изменено. Изучите доступные свидетельства и повторите проверку.')


class BsdInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in (
        'flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid', 'rgid',
        'svuid', 'svgid', 'reserved')]
    _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in ('nfiles', 'pgid', 'pjobc', 'tdev', 'tpgid')]
    _fields_ += [('nice', ctypes.c_int32), ('start_sec', ctypes.c_uint64), ('start_usec', ctypes.c_uint64)]


def process_snapshot():
    """Native creation identities; unreadable processes never become positive evidence."""
    if platform.system() != 'Darwin':
        raise _error('runtime.darwin_required', 'Native macOS verification is required; run this check on the target Mac.')
    lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
    lib.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int]
    lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
    lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    capacity = max(4096, lib.proc_listpids(1, 0, None, 0) + 4096)
    pids = (ctypes.c_int * (capacity // ctypes.sizeof(ctypes.c_int)))()
    used = lib.proc_listpids(1, 0, pids, ctypes.sizeof(pids))
    if used <= 0 or used >= ctypes.sizeof(pids):
        raise _error('runtime.process_inventory', 'The native process inventory is unavailable or incomplete; repeat the check.')
    rows = []
    for pid in pids[:used // ctypes.sizeof(ctypes.c_int)]:
        if pid <= 0:
            continue
        info = BsdInfo()
        if lib.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info) or info.status == 5:
            continue
        buffer = ctypes.create_string_buffer(4096)
        if lib.proc_pidpath(pid, buffer, len(buffer)) <= 0:
            continue
        try:
            rows.append({'pid': pid, 'ppid': int(info.ppid), 'uid': int(info.uid),
                         'birth': [int(info.start_sec), int(info.start_usec)],
                         'session': os.getsid(pid), 'path': os.path.realpath(os.fsdecode(buffer.value))})
        except OSError:
            continue
    return rows


def same_process(left, right):
    return bool(left and right) and all(left.get(key) == right.get(key)
        for key in ('pid', 'uid', 'birth', 'path', 'session'))


def _private_json(path, uid, max_bytes=MAX_GUARD_RECORD_BYTES):
    path = Path(path)
    for component in (path, *path.parents):
        if component.is_symlink():
            raise _error('runtime.record_symlink', 'Runtime evidence contains a symbolic link; select protected local evidence.')
    fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != uid or info.st_mode & 0o077 or info.st_nlink != 1:
            raise _error('runtime.record_permissions', 'Runtime evidence is not a private owned regular file; inspect its ownership.')
        if info.st_size > max_bytes:
            raise _error('runtime.record_size', 'Runtime evidence exceeds its bounded record size; inspect the selected evidence type.')
        data = stream.read(max_bytes + 1)
        if len(data) > max_bytes:
            raise _error('runtime.record_size', 'Runtime evidence grew beyond its bounded record size; repeat the read-only check.')
        return json.loads(data)


def process_evidence(target, manifest=None, rows=None, record=None):
    """Validate direct app parentage and the intentionally separate guardian.

    Exposed for the installer: the guardian uses the same executable as Warden,
    so counting two matching executable paths as duplicate supervisors is wrong.
    """
    app = Path(target['path']).resolve()
    executable = (manifest or {}).get('_executable', 'watchtower')
    app_path = str(app / 'Contents/MacOS' / executable)
    warden_path = str(app / 'Contents/Resources/warden/cilex-warden')
    if manifest and manifest.get('warden') and manifest.get('app'):
        try:
            warden_path = str(app / Path(manifest['warden']).relative_to(manifest['app']))
        except ValueError:
            raise _error('runtime.manifest_path', 'Warden executable escapes the application; inspect the artifact manifest.')
    all_rows = process_snapshot() if rows is None else rows
    selected = [row for row in all_rows if row['path'] in (app_path, warden_path)]
    evidence = {'state': 'Unverified', 'supervision': 'Unverified', 'duplicates': False,
                'processes': selected, 'app': None, 'warden': None, 'guardian': None,
                'reason': 'PROCESS_OR_IDENTITY_UNVERIFIED'}
    if any(row['uid'] != target['uid'] for row in selected):
        evidence['reason'] = 'INSTALLATION_RUNNING_AS_DIFFERENT_ACCOUNT'
        return evidence
    apps = [row for row in selected if row['path'] == app_path]
    wardens = [row for row in selected if row['path'] == warden_path]
    if len(apps) != 1:
        evidence.update(reason='APP_MISSING' if not apps else 'DUPLICATE_APPLICATIONS', duplicates=len(apps) > 1)
        return evidence
    app_row = apps[0]
    evidence['app'] = app_row
    if record is None:
        state_path = Path(target['home']) / 'Library/Application Support/CilexWatchtower/Warden' / target['id'] / 'process-guard/processes.json'
        try:
            record = _private_json(state_path, target['uid'])
        except (OSError, ValueError, DeployError):
            evidence['reason'] = 'PROTECTED_WARDEN_RECORD_UNAVAILABLE'
            return evidence
    if record.get('schema') != 1 or record.get('installation_id') != target['id'] or record.get('uid') != target['uid']:
        evidence['reason'] = 'WARDEN_RECORD_INSTALLATION_MISMATCH'
        return evidence
    owner = next((row for row in wardens if same_process(record.get('owner'), row)), None)
    guardian = next((row for row in wardens if same_process(record.get('guard'), row)), None)
    if not owner or not guardian or owner['pid'] == guardian['pid']:
        evidence['reason'] = 'WARDEN_OR_GUARDIAN_IDENTITY_MISMATCH'
        return evidence
    if len(wardens) != 2:
        evidence.update(reason='UNEXPECTED_WARDEN_PROCESSES', duplicates=True)
        return evidence
    if app_row['ppid'] != owner['pid'] or owner['ppid'] != 1 or guardian['ppid'] != owner['pid'] or any(row['session'] != owner['session'] for row in (app_row, guardian)):
        evidence['reason'] = 'PARENTAGE_OR_SESSION_MISMATCH'
        return evidence
    tracked = any(row.get('pid') == app_row['pid'] and row.get('uid') == app_row['uid'] and
                  row.get('birth') == app_row['birth'] and row.get('session') == app_row['session'] and
                  app_path in row.get('allowed_paths', [row.get('path')]) for row in record.get('processes', []))
    if not tracked:
        evidence['reason'] = 'APPLICATION_NOT_IN_GUARDIAN_RECORD'
        return evidence
    evidence.update(state='ProcessVerified', supervision='launchd → Warden → Watchtower',
                    reason='NATIVE_CREATION_IDENTITIES_MATCH', warden=owner, guardian=guardian)
    return evidence


def window_visibility(pid):
    """On-screen ordinary-window metadata only; no recording or consent APIs."""
    if platform.system() != 'Darwin':
        return {'state': 'Unverified', 'reason': 'DARWIN_WINDOW_API_REQUIRED', 'windows': []}
    try:
        cg = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
        cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        cg.CGWindowListCopyWindowInfo.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
        cg.CGWindowListCopyWindowInfo.restype = ctypes.c_void_p
        cf.CFArrayGetCount.argtypes = [ctypes.c_void_p]
        cf.CFArrayGetCount.restype = ctypes.c_long
        cf.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]
        cf.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
        cf.CFDictionaryGetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        cf.CFDictionaryGetValue.restype = ctypes.c_void_p
        cf.CFNumberGetValue.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
        cf.CFNumberGetValue.restype = ctypes.c_bool
        cf.CFRelease.argtypes = [ctypes.c_void_p]
        keys = {name: ctypes.c_void_p.in_dll(cg, name).value for name in
                ('kCGWindowOwnerPID', 'kCGWindowLayer', 'kCGWindowNumber', 'kCGWindowAlpha', 'kCGWindowBounds')}

        class Rect(ctypes.Structure):
            _fields_ = [(name, ctypes.c_double) for name in ('x', 'y', 'width', 'height')]

        cg.CGRectMakeWithDictionaryRepresentation.argtypes = [ctypes.c_void_p, ctypes.POINTER(Rect)]
        cg.CGRectMakeWithDictionaryRepresentation.restype = ctypes.c_bool
        array = cg.CGWindowListCopyWindowInfo(1 | 16, 0)  # on-screen only, exclude desktop
        if not array:
            return {'state': 'Unverified', 'reason': 'WINDOW_METADATA_UNAVAILABLE', 'windows': []}
        windows = []
        try:
            count = cf.CFArrayGetCount(array)
            if not 0 <= count <= 10000:
                return {'state': 'Unverified', 'reason': 'WINDOW_INVENTORY_LIMIT', 'windows': []}
            for index in range(count):
                row = cf.CFArrayGetValueAtIndex(array, index)
                numbers = {}
                for name in ('kCGWindowOwnerPID', 'kCGWindowLayer', 'kCGWindowNumber'):
                    pointer = cf.CFDictionaryGetValue(row, keys[name])
                    number = ctypes.c_int64()
                    if pointer and cf.CFNumberGetValue(pointer, 4, ctypes.byref(number)):
                        numbers[name] = number.value
                if numbers.get('kCGWindowOwnerPID') != pid or numbers.get('kCGWindowLayer') != 0:
                    continue
                alpha = ctypes.c_double()
                pointer = cf.CFDictionaryGetValue(row, keys['kCGWindowAlpha'])
                bounds = Rect()
                bounds_pointer = cf.CFDictionaryGetValue(row, keys['kCGWindowBounds'])
                if not pointer or not cf.CFNumberGetValue(pointer, 6, ctypes.byref(alpha)) or alpha.value <= 0:
                    continue
                if not bounds_pointer or not cg.CGRectMakeWithDictionaryRepresentation(bounds_pointer, ctypes.byref(bounds)) or bounds.width < 2 or bounds.height < 2:
                    continue
                windows.append({'id': numbers.get('kCGWindowNumber'), 'width': bounds.width, 'height': bounds.height})
        finally:
            cf.CFRelease(array)
        return {'state': 'Visible' if windows else 'NotObserved',
                'reason': 'ONSCREEN_WINDOW_METADATA' if windows else 'NO_ONSCREEN_NORMAL_WINDOW', 'windows': windows,
                'limitation': 'Window metadata does not prove unobscured pixels, a correct scene, or video advancement.'}
    except (OSError, AttributeError, ValueError):
        return {'state': 'Unverified', 'reason': 'WINDOW_METADATA_API_UNAVAILABLE', 'windows': []}


def timestamp(value):
    try:
        parsed = datetime.datetime.fromisoformat(value[:-1] + '+00:00' if value.endswith('Z') else value)
        return parsed.timestamp()  # naive app timestamps use the target's local timezone
    except (ValueError, OverflowError):
        return None


def parse_source_telemetry(value):
    """Strict versioned JSON; return only allowed non-secret fields."""
    def unique_object(pairs):
        result = {}
        for key, item in pairs:
            if key in result:
                raise ValueError('duplicate source telemetry key')
            result[key] = item
        return result

    def integer(number, maximum=2**53 - 1):
        return type(number) is int and 0 <= number <= maximum

    if len(value.encode('utf-8')) > MAX_SOURCE_JSON_BYTES:
        raise ValueError('source telemetry exceeds size limit')
    data = json.loads(value, object_pairs_hook=unique_object)
    if not isinstance(data, dict) or set(data) != {'schema', 'up', 'sources'} \
            or type(data['schema']) is not int or data['schema'] != 1 or not integer(data['up']):
        raise ValueError('invalid source telemetry header')
    rows = data['sources']
    if not isinstance(rows, list) or len(rows) > MAX_SOURCE_ROWS:
        raise ValueError('invalid source telemetry count')
    identities = set()
    for row in rows:
        if not isinstance(row, dict) or set(row) != {'id', 'frames', 'age_ms', 'decoder', 'error'}:
            raise ValueError('invalid source telemetry fields')
        if not isinstance(row['id'], str) or not _SOURCE_ID.fullmatch(row['id']) or row['id'] in identities:
            raise ValueError('invalid or duplicate source identity')
        if not integer(row['frames']) or (row['age_ms'] is not None and not integer(row['age_ms'])) \
                or type(row['decoder']) is not bool or type(row['error']) is not bool:
            raise ValueError('invalid source telemetry values')
        identities.add(row['id'])
    return {'up': data['up'], 'sources': sorted(rows, key=lambda row: row['id'])}


def parse_telemetry(lines, pid, birth, now=None):
    now = time.time() if now is None else now
    marker = None
    invalid = False
    samples = []
    source_samples, invalid_source_epochs = {}, []
    for line in lines:
        if '=== watchtower start ' in line:
            marker, samples, invalid = None, [], True
            source_samples, invalid_source_epochs = {}, []
            match = _START.search(line)
            if match:
                epoch = timestamp(match.group(1))
                if epoch is not None:
                    marker = {'epoch': epoch, 'pid': int(match.group(3)), 'version': match.group(2)}
                    invalid = False
            continue
        if not marker or marker['pid'] != pid or ('[MEMTEL] up=' not in line and '[VIDTEL] ' not in line):
            continue
        prefix = re.match(r'^(\S+)\s+[DIWCF]\s+', line)
        epoch = timestamp(prefix.group(1)) if prefix else None
        if epoch is None or epoch < marker['epoch'] or epoch > now + 5:
            continue
        if '[VIDTEL] ' in line:
            try:
                source = parse_source_telemetry(line.split('[VIDTEL] ', 1)[1].strip())
                if source['up'] in source_samples:
                    # Two records for a tick are ambiguous, even if one is valid.
                    invalid_source_epochs.extend((epoch, source_samples[source['up']]['epoch']))
                source_samples[source['up']] = dict(source, epoch=epoch)
            except (ValueError, TypeError, RecursionError):
                invalid_source_epochs.append(epoch)
            continue
        values = {}
        for key, regex in _NUMBER.items():
            found = regex.findall(line)
            if len(found) != 1 or len(found[0]) > 19 or int(found[0]) > 2**63 - 1:
                break
            values[key] = int(found[0])
        if len(values) == len(_NUMBER_KEYS):
            samples.append(dict(values, epoch=epoch))
    reason = 'VIDEO_START_MARKER_INVALID' if invalid else 'VIDEO_START_MARKER_MISSING' if not marker else None
    if marker and marker['pid'] != pid:
        reason = 'VIDEO_LOG_BELONGS_TO_OTHER_PROCESS'
    if marker and (marker['epoch'] < birth - 2 or marker['epoch'] > birth + 30 or marker['epoch'] > now + 5):
        reason = 'VIDEO_START_TIME_MISMATCH'
    if reason:
        return {'known': False, 'reason': reason, 'samples': []}
    # Keep the session history for an observed150-second span; freshness is
    # independently required of the latest sample. Duplicate timestamps cannot
    # create fictitious progress.
    unique = {(s['epoch'], s['up']): s for s in samples}
    samples = sorted(unique.values(), key=lambda s: (s['epoch'], s['up']))
    for sample in samples:
        source = source_samples.get(sample['up'])
        if any(abs(sample['epoch'] - epoch) <= 2 for epoch in invalid_source_epochs):
            sample['source_error'] = 'VIDEO_SOURCE_TELEMETRY_INVALID'
        elif source and abs(source['epoch'] - sample['epoch']) <= 2:
            sample['sources'] = source['sources']
            sample['source_schema'] = 1
    if source_samples:
        # MEMTEL and VIDTEL are adjacent separate log writes. A concurrent read
        # may see the first but not the second; defer only that fresh incomplete
        # tick. A missing source record beyond this bounded join window fails.
        samples = [sample for sample in samples if 'sources' in sample or 'source_error' in sample
                   or sample['epoch'] <= now - 2]
    if not samples or samples[-1]['epoch'] < now - MAX_LOG_AGE:
        return {'known': False, 'reason': 'VIDEO_TELEMETRY_MISSING_OR_STALE', 'samples': []}
    return {'known': True, 'reason': 'VIDEO_TELEMETRY_CURRENT', 'pid': pid, 'start': marker,
            'samples': samples[-1000:], 'latest': samples[-1]}


def read_telemetry(log_path, app_row, now=None):
    """Bounded reads of current/rotated logs; return numeric evidence only."""
    log_path = Path(log_path)
    unknown = lambda reason: {'known': False, 'reason': reason, 'samples': []}
    if not log_path.is_absolute() or log_path.name != 'watchtower.log':
        return unknown('VIDEO_LOG_PATH_INVALID')
    for component in (log_path, *log_path.parents):
        if component.is_symlink():
            return unknown('VIDEO_LOG_SYMLINK_REFUSED')
    if not log_path.is_file():
        return unknown('VIDEO_LOG_MISSING')
    paths = []
    try:
        for path in log_path.parent.iterdir():
            match = re.fullmatch(r'watchtower\.log(?:\.([1-9]\d?))?', path.name)
            if match and (match.group(1) is None or int(match.group(1)) <= 50):
                paths.append((int(match.group(1) or 0), path))
        paths.sort(reverse=True)
        # Historical sessions must not exhaust the current observation budget.
        # Keep the latest boundary separately and only a bounded tail of that
        # session. At two rows per30-second tick this covers more than8 hours,
        # well beyond the maximum requested observation of one hour.
        selected, latest_start, total, bytes_read = deque(maxlen=MAX_TELEMETRY_ROWS), None, 0, 0
        for _, path in paths:
            fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, 'rb') as stream:
                info = os.fstat(stream.fileno())
                total += info.st_size
                if not stat.S_ISREG(info.st_mode) or info.st_uid != app_row['uid'] or info.st_nlink != 1:
                    return unknown('VIDEO_LOG_OWNER_OR_TYPE_INVALID')
                if info.st_size > MAX_LOG_BYTES or total > MAX_TOTAL_LOG_BYTES:
                    return unknown('VIDEO_LOG_READ_LIMIT_EXCEEDED')
                consumed = 0
                while True:
                    raw = stream.readline(MAX_LOG_LINE_BYTES + 1)
                    if not raw:
                        break
                    consumed += len(raw)
                    bytes_read += len(raw)
                    if consumed > MAX_LOG_BYTES or bytes_read > MAX_TOTAL_LOG_BYTES:
                        return unknown('VIDEO_LOG_READ_LIMIT_EXCEEDED')
                    if len(raw) > MAX_LOG_LINE_BYTES:
                        return unknown('VIDEO_LOG_LINE_LIMIT_EXCEEDED')
                    if b'=== watchtower start ' in raw:
                        # Also retain malformed boundaries: parsing must refuse
                        # them instead of reusing evidence from an older process.
                        latest_start = raw.decode('utf-8', 'replace')
                        selected.clear()
                    elif b'[MEMTEL] up=' in raw or b'[VIDTEL] ' in raw:
                        selected.append(raw.decode('utf-8', 'replace'))
    except (OSError, ValueError):
        return unknown('VIDEO_LOG_READ_FAILED')
    birth = app_row['birth'][0] + app_row['birth'][1] / 1000000
    return parse_telemetry(([latest_start] if latest_start is not None else []) + list(selected),
                           app_row['pid'], birth, now)


def video_progress(samples, minimum_seconds, expected_feeds=None, expected_source_ids=None):
    """Aggregate and optional per-source proof; missing data cannot become proof."""
    result = {'state': 'Unverified', 'reason': 'VIDEO_NEEDS_FRESH_SAMPLES'}
    if len(samples) < 2:
        return result
    first, last = samples[0], samples[-1]
    expected = expected_feeds if expected_feeds is not None else first['lit']
    if expected < 1:
        return dict(result, reason='NO_EXPECTED_ACTIVE_CAMERA_VIDEO')
    if any(sample['err'] != 0 for sample in samples):
        return dict(result, state='Failed', reason='VIDEO_STREAM_ERRORS_OBSERVED')
    if any(sample['lit'] < expected or sample['dec'] < expected for sample in samples):
        return dict(result, state='Failed', reason='EXPECTED_CAMERA_COUNTS_NOT_MAINTAINED')
    for before, after in zip(samples, samples[1:]):
        elapsed, uptime = after['epoch'] - before['epoch'], after['up'] - before['up']
        if elapsed <= 0 or uptime <= 0 or elapsed > MAX_LOG_AGE:
            return dict(result, state='Failed', reason='VIDEO_SAMPLE_GAP_OR_CLOCK_CHANGE')
        if abs(elapsed - uptime) > 5:
            return dict(result, state='Failed', reason='VIDEO_CLOCK_OR_UPTIME_MISMATCH')
        if after['frames'] <= before['frames'] or after['framesIn'] <= before['framesIn']:
            return dict(result, state='Failed', reason='VIDEO_FRAMES_STALLED_OR_RESET')
    source_observed = any('sources' in row or 'source_error' in row for row in samples)
    source_ids = set(expected_source_ids) if expected_source_ids is not None else None
    if expected_source_ids is not None and not source_observed:
        return dict(result, reason='EXPECTED_SOURCE_IDENTITIES_NOT_OBSERVED')
    if source_observed:
        previous = None
        for sample in samples:
            if 'source_error' in sample:
                return dict(result, state='Failed', reason=sample['source_error'])
            if 'sources' not in sample:
                return dict(result, state='Failed', reason='VIDEO_SOURCE_EVIDENCE_MISSING')
            sources = {row['id']: row for row in sample['sources']}
            if len(sources) != len(sample['sources']) or len(sources) != expected:
                return dict(result, state='Failed', reason='VIDEO_SOURCE_COUNT_OR_DUPLICATE_MISMATCH')
            if source_ids is None:
                source_ids = set(sources)
            if set(sources) != source_ids:
                return dict(result, state='Failed', reason='VIDEO_SOURCE_IDENTITY_SET_CHANGED_OR_UNEXPECTED')
            for identity, row in sources.items():
                if row['error'] or not row['decoder'] or row['age_ms'] is None or not 0 <= row['age_ms'] <= 5000:
                    return dict(result, state='Failed', reason='VIDEO_SOURCE_NOT_FRESH_OR_DECODING')
                if previous is not None and row['frames'] <= previous[identity]['frames']:
                    return dict(result, state='Failed', reason='VIDEO_INDIVIDUAL_SOURCE_STALLED_OR_RESET')
            previous = sources
    span = last['epoch'] - first['epoch']
    if span < minimum_seconds or last['up'] - first['up'] < minimum_seconds:
        return dict(result, reason='VIDEO_OBSERVATION_INTERVAL_TOO_SHORT', sample_span_seconds=span)
    proof = {'state': 'AggregateVideoObserved', 'reason': 'COUNTS_MAINTAINED_AND_FRAMES_ADVANCING',
            'sample_span_seconds': span, 'frame_delta': last['frames'] - first['frames'],
            'input_frame_delta': last['framesIn'] - first['framesIn'], 'expected_feeds': expected,
            'expected_feeds_source': 'explicit' if expected_feeds is not None else 'initial_observed_lit_count',
            'sample_count': len(samples), 'individual_camera_identities': 'Unverified'}
    if source_observed:
        first_sources = {row['id']: row for row in first['sources']}
        proof.update(state='PerSourceVideoObserved', reason='STABLE_SOURCES_EACH_ADVANCING_AND_FRESH',
            individual_camera_identities='ExternallyMatchedSourceHashes' if expected_source_ids is not None else 'StableInitialSourceHashes',
            expected_source_identities_from='external_expected_hashes' if expected_source_ids is not None else 'initial_observed_set',
            source_hashes=sorted(source_ids), camera_name_mapping='Unverified',
            source_frame_deltas={row['id']: row['frames'] - first_sources[row['id']]['frames'] for row in last['sources']})
    return proof


def _manifest(target, context):
    if context.get('manifest'):
        return context['manifest']
    # The receipt includes the complete packaged dependency inventory, which
    # legitimately exceeds the much smaller guardian process-record bound.
    receipt = _private_json(Path(target['support']) / 'receipt.json', target['uid'], MAX_RECEIPT_BYTES)
    if receipt.get('installation_id') != target['id'] or receipt.get('uid') != target['uid'] or receipt.get('install_dir') != str(target['path']):
        raise _error('runtime.receipt_identity', 'Receipt belongs to another installation; inspect the selected application.')
    return receipt['manifest']


def verify(options, context=None):
    """Inspect now, or explicitly observe150+ seconds without touching the app.

    Optional context.target/context.manifest avoid rereading a validated receipt.
    Evidence writes require context.write_evidence=True, an existing private
    context.evidence_dir, and a mutation mode. Plain verify/check/dry-run never
    write evidence, even if a caller mistakenly supplies that flag.
    """
    context = dict(context or {})
    from install import resolve_target
    target = context.get('target') or resolve_target(options)
    requested = float(options.get('observe_seconds', 0) or 0)
    if requested != 0 and not 150 <= requested <= 3600:
        raise _error('runtime.observation_duration', 'Use zero for an instantaneous check or 150–3600 seconds for video observation.')
    timeout = float(options.get('observation_timeout', requested + 90))
    if not math.isfinite(timeout) or timeout < requested or timeout > requested + 300:
        raise _error('runtime.observation_timeout', 'Use a bounded observation timeout between the requested duration and 300 extra seconds.')
    expected = options.get('expected_cameras', options.get('expected_camera_count'))
    if expected is not None and (not isinstance(expected, int) or isinstance(expected, bool) or expected < 1):
        raise _error('runtime.expected_cameras', 'Expected camera count must be a positive integer; provide the intended view count.')
    expected_ids = options.get('expected_source_ids')
    if expected_ids is not None:
        if not isinstance(expected_ids, list) or not 1 <= len(expected_ids) <= MAX_SOURCE_ROWS \
                or any(not isinstance(value, str) or not _SOURCE_ID.fullmatch(value) for value in expected_ids) \
                or len(set(expected_ids)) != len(expected_ids) or (expected is not None and len(expected_ids) != expected):
            raise _error('runtime.expected_source_ids', 'Provide unique lowercase SHA-256 source identities matching the expected camera count.')
        if expected is None:
            expected = len(expected_ids)
    started, started_mono = time.time(), time.monotonic()
    result = {'schema_version': SCHEMA, 'installation_id': target['id'], 'target_uid': target['uid'],
        'runtime_health': 'Unverified', 'gui_visibility': 'Unverified', 'gui_video': 'Unverified',
        'backend': 'Unverified', 'playback_export': 'Unverified', 'recovery': 'Unverified',
        'startup': 'StartupUnverified', 'full_success': False, 'requested_observation_seconds': requested,
        'started_at': utc(), 'evidence': [], 'findings': [], 'samples': [],
        'limitations': ['Aggregate MEMTEL alone cannot certify individual sources; VIDTEL hashes do not establish camera-name mapping or playback/export.',
                       'Backend enrollment/connectivity requires separate authenticated application evidence.',
                       'Window metadata does not prove an unobscured or correct scene.',
                       'This observation does not certify recovery, login or reboot startup.']}
    if context.get('run_id') is not None:
        result['run_id'] = context['run_id']
    try:
        manifest = _manifest(target, context)
    except (OSError, ValueError, KeyError, DeployError):
        manifest = None
        result['findings'].append('PROTECTED_INSTALL_RECEIPT_UNAVAILABLE_OR_INVALID')
    baseline = None
    numeric = {}
    visibility_continuous = True
    while manifest is not None:
        process = process_evidence(target, manifest)
        result['process_evidence'] = process
        result['runtime_health'] = process['state']
        if process['state'] != 'ProcessVerified':
            result['findings'].append(process['reason'])
            break
        app = process['app']
        if baseline is None:
            baseline = {role: process.get(role) for role in ('app', 'warden', 'guardian')}
        elif any(before and not same_process(before, process.get(role)) for role, before in baseline.items()):
            result['runtime_health'] = 'UnverifiedProcessChanged'
            result['findings'].append('PROCESS_CHANGED_DURING_OBSERVATION')
            break
        visibility = window_visibility(app['pid'])
        result['window_evidence'] = visibility
        result['gui_visibility'] = visibility['state']
        visibility_continuous = visibility_continuous and visibility['state'] == 'Visible'
        log_path = Path(target['home']) / 'Library/Application Support/Cilex Vision/Watchtower/flightrec/watchtower.log'
        snapshot = read_telemetry(log_path, app)
        result['telemetry'] = {key: value for key, value in snapshot.items() if key != 'samples'}
        if snapshot['known'] and snapshot.get('start') and manifest.get('version') and snapshot['start']['version'] != manifest['version']:
            result['runtime_health'] = 'UnverifiedVersionMismatch'
            result['findings'].append('RUNNING_APPLICATION_VERSION_MISMATCH')
            break
        if snapshot['known']:
            chosen = snapshot['samples'] if requested else snapshot['samples'][-2:]
            for sample in chosen:
                if not requested or sample['epoch'] >= started:
                    numeric[(sample['epoch'], sample['up'])] = sample
            result['samples'] = sorted(numeric.values(), key=lambda s: (s['epoch'], s['up']))
            video = video_progress(result['samples'], requested or 25, expected, expected_ids)
        else:
            video = {'state': 'Unverified', 'reason': snapshot['reason']}
        result['video_evidence'] = video
        elapsed = time.monotonic() - started_mono
        if not requested:
            if visibility['state'] == 'Visible' and video['state'] in ('PerSourceVideoObserved', 'AggregateVideoObserved'):
                result['gui_video'] = 'VisibleWithRecentPerSourceVideo' if video['state'] == 'PerSourceVideoObserved' else 'VisibleWithRecentAggregateVideo'
            break
        if video['state'] == 'Failed':
            result['gui_video'] = 'Failed'
            result['findings'].append(video['reason'])
            break
        if not visibility_continuous:
            result['gui_video'] = 'UnverifiedVisibility'
            result['findings'].append('GUI_NOT_CONTINUOUSLY_OBSERVED')
            break
        if elapsed >= requested and video['state'] in ('PerSourceVideoObserved', 'AggregateVideoObserved'):
            result['gui_video'] = 'VisibleAndPerSourceVideoObserved' if video['state'] == 'PerSourceVideoObserved' else 'VisibleAndAggregateVideoObserved'
            break
        if elapsed >= timeout:
            result['findings'].append('OBSERVATION_TIMEOUT_' + video['reason'])
            break
        time.sleep(min(2.0, max(0, timeout - elapsed)))
    result['observed_seconds'] = round(time.monotonic() - started_mono, 3)
    result['completed_at'] = utc()
    language = options.get('language', 'en')
    result['findings'] = [{'id': code, 'severity': 'error' if result['gui_video'] == 'Failed' else 'warning',
        'overridable': False, 'message': (('Проверка работы не подтверждена (' + code + '); успешный результат не установлен. Проверьте процессы, окно и потоки камер по сохранённым свидетельствам и повторите проверку.') if language == 'ru' else ('Runtime verification is incomplete (' + code + '); a successful outcome is not established. Inspect the process, window and camera evidence, then repeat verification.'))} for code in result['findings']]
    if context.get('write_evidence') and options.get('mode') in ('install', 'remote-install') and not options.get('dry_run'):
        directory = Path(context['evidence_dir'])
        if not directory.is_absolute() or any(p.is_symlink() for p in (directory, *directory.parents)):
            raise _error('runtime.evidence_path', 'Evidence directory must be an absolute canonical protected path.')
        info = directory.lstat()
        if directory.is_symlink() or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            raise _error('runtime.evidence_permissions', 'Evidence directory must already be private and owned; use the protected deployment run directory.')
        run_id = str(context.get('run_id', 'observation'))
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,100}', run_id):
            raise _error('runtime.evidence_run_id', 'Evidence run ID is invalid; use the caller’s protected run identifier.')
        path = directory / ('runtime-' + run_id + '-' + str(time.time_ns()) + '.json')
        result['evidence'].append(str(path))
        atomic_json(path, result)
    return result
