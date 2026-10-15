"""Darwin-only Warden primitives; no third-party runtime dependencies.

Uses public libproc identities (PID + birth time + UID + executable + session),
Mach CPU counters, and sysctl/vm_stat diagnostics. No process-name termination,
settings writes, privilege escalation, or launchd registration happens here.
"""
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import plistlib
import select
import signal
import stat
import subprocess
import sys
import time


class BsdInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in (
        'flags', 'status', 'xstatus', 'pid', 'ppid', 'uid', 'gid', 'ruid',
        'rgid', 'svuid', 'svgid', 'reserved')]
    _fields_ += [('comm', ctypes.c_char * 16), ('name', ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in (
        'nfiles', 'pgid', 'pjobc', 'tdev', 'tpgid')]
    _fields_ += [('nice', ctypes.c_int32), ('start_sec', ctypes.c_uint64),
                ('start_usec', ctypes.c_uint64)]


_LIB = None
GUARD_STARTUP_TIMEOUT = 30.0
IDENTITY_READ_GRACE = 0.5


def libproc():
    global _LIB
    if _LIB is None:
        if sys.platform != 'darwin':
            raise RuntimeError('Darwin native API required')
        _LIB = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
        _LIB.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                     ctypes.c_void_p, ctypes.c_int]
        _LIB.proc_pidinfo.restype = ctypes.c_int
        _LIB.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        _LIB.proc_pidpath.restype = ctypes.c_int
        _LIB.proc_listpids.argtypes = [ctypes.c_uint32, ctypes.c_uint32,
                                      ctypes.c_void_p, ctypes.c_int]
        _LIB.proc_listpids.restype = ctypes.c_int
    return _LIB


def process_identity(pid, allow_unreadable=False):
    """None for gone/zombie processes; do not substitute a guessed identity.

    Native reads can briefly fail while a process is exiting. A recorded live
    process gets a bounded retry, not an inferred identity or a claim of exit.
    Enumeration may skip unreadable processes; cleanup of known ones may not.
    """
    lib = libproc()
    deadline = time.monotonic() + IDENTITY_READ_GRACE
    while True:
        info = BsdInfo()
        if lib.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) == ctypes.sizeof(info):
            if info.status == 5:  # SZOMB cannot execute or receive a meaningful signal.
                return None
            path = ctypes.create_string_buffer(4096)
            if lib.proc_pidpath(pid, path, len(path)) > 0:
                try:
                    session = os.getsid(pid)
                except ProcessLookupError:
                    return None
                return {'pid': int(pid), 'ppid': int(info.ppid), 'uid': int(info.uid),
                        'birth': [int(info.start_sec), int(info.start_usec)],
                        'path': os.path.realpath(os.fsdecode(path.value)), 'session': session}
        if allow_unreadable:
            return None
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return None
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(0.01, remaining))
    # Darwin can return ESRCH for a zombie while kill(pid, 0) still succeeds.
    # Confirm that state explicitly. Persistent unreadability on a live process
    # remains an error, never evidence of successful cleanup or permission to
    # signal a process whose creation identity cannot be checked.
    status = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'stat='],
                            capture_output=True, text=True, timeout=2)
    if status.returncode == 0 and status.stdout.strip().startswith('Z'):
        return None
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return None
    raise PermissionError("Cannot verify live process creation identity for pid=%d" % pid)


def same_process(expected, actual):
    """PPID may legitimately change on orphaning; other identity must match."""
    return bool(actual) and all(expected.get(k) == actual.get(k)
                                for k in ('pid', 'uid', 'birth', 'session')) and \
        actual['path'] in expected.get('allowed_paths', [expected.get('path')])


def process_list():
    lib = libproc()
    count = max(4096, lib.proc_listpids(1, 0, None, 0) + 1024)
    buf = (ctypes.c_int * (count // ctypes.sizeof(ctypes.c_int)))()
    used = lib.proc_listpids(1, 0, buf, ctypes.sizeof(buf))
    return [p for p in buf[:max(0, used) // ctypes.sizeof(ctypes.c_int)] if p > 0]


def descendants(records):
    """Remember observed descendants, including later session/group changes.

    This supplements launchd's inherited process-group cleanup. It is NOT a
    claim of containment for arbitrary double-forking hostile children: a child
    that detaches completely between observations can escape the snapshot.
    """
    live = {r['pid']: r for r in records if same_process(r, process_identity(r['pid']))}
    found = {}
    for pid in process_list():
        row = process_identity(pid, allow_unreadable=True)
        if row:
            found[pid] = row
    changed = True
    while changed:
        changed = False
        for pid, row in found.items():
            parent = live.get(row['ppid'])
            if pid not in live and parent and row['uid'] == parent['uid']:
                live[pid] = row
                changed = True
    by_birth = {(r['pid'], tuple(r['birth'])): r for r in records}
    by_birth.update({(r['pid'], tuple(r['birth'])): r for r in live.values()})
    return list(by_birth.values())


def stop_records(records, timeout=5.0):
    """Stop only identities still matching. Return identities that did not exit."""
    for sig, budget in ((signal.SIGTERM, timeout), (signal.SIGKILL, 2.0)):
        pending = [r for r in records if same_process(r, process_identity(r['pid']))]
        for row in reversed(pending):
            # Recheck directly before each signal; never signal a reused PID.
            if same_process(row, process_identity(row['pid'])):
                try:
                    os.kill(row['pid'], sig)
                except ProcessLookupError:
                    pass
        end = time.monotonic() + budget
        while pending and time.monotonic() < end:
            pending = [r for r in pending if same_process(r, process_identity(r['pid']))]
            if pending:
                time.sleep(0.05)
        if not pending:
            return []
    return pending


def private_directory(path):
    path = Path(path)
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    st = path.lstat()
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
        raise RuntimeError('Warden state directory must be owned by this account and mode 0700')


def atomic_private_json(path, value):
    path = Path(path)
    private_directory(path.parent)
    tmp = path.with_name(path.name + '.tmp-' + str(os.getpid()))
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as fh:
            json.dump(value, fh, ensure_ascii=False, sort_keys=True)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def read_private_json(path):
    fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'r', encoding='utf-8') as fh:
        st = os.fstat(fh.fileno())
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
            raise RuntimeError('Unsafe Warden process record ownership or permissions')
        if st.st_size > 1024 * 1024:
            raise RuntimeError('Warden process record exceeds size limit')
        return json.load(fh)


def guard_main(record_path, installation_id):
    """Pipe EOF is supervisor death, without wall-clock deadlines.

    An ACK is sent only after the process record is flushed. The native gate
    cannot exec Watchtower until Warden receives that ACK. On EOF or malformed
    commands, all known identities are reconciled and stopped before exit.
    """
    os.umask(0o077)
    records = []
    owner = None
    buffer = b''
    last_scan = time.monotonic()
    try:
        while True:
            readable, _, _ = select.select([sys.stdin.fileno()], [], [], 0.25)
            if readable:
                block = os.read(sys.stdin.fileno(), 65536)
                if not block:
                    break
                buffer += block
                if len(buffer) > 1024 * 1024:
                    raise ValueError('oversized guard request')
                while b'\n' in buffer:
                    line, buffer = buffer.split(b'\n', 1)
                    request = json.loads(line)
                    if request['installation_id'] != installation_id:
                        raise ValueError('guard installation mismatch')
                    if owner is None:
                        owner = request['owner']
                    if request['owner'] != owner or not same_process(owner, process_identity(os.getppid())):
                        raise ValueError('guard parent identity mismatch')
                    if request['operation'] == 'track':
                        root = request['process']
                        current = process_identity(root['pid'])
                        if root['uid'] != os.getuid() or not same_process(root, current) or current['ppid'] != owner['pid']:
                            raise ValueError('guard child identity mismatch')
                        records.append(root)
                    elif request['operation'] == 'cleanup':
                        remaining = stop_records(descendants(records))
                        if remaining:
                            raise RuntimeError('guard cleanup incomplete')
                        records = []
                    elif request['operation'] != 'hello':
                        raise ValueError('unsupported guard operation')
                    atomic_private_json(record_path, {
                        'schema': 1, 'installation_id': installation_id, 'uid': os.getuid(),
                        'owner': owner, 'guard': process_identity(os.getpid()), 'processes': records})
                    os.write(sys.stdout.fileno(), b'OK\n')
            if records and time.monotonic() - last_scan >= 0.5:
                records = descendants(records)
                atomic_private_json(record_path, {
                    'schema': 1, 'installation_id': installation_id, 'uid': os.getuid(),
                    'owner': owner, 'guard': process_identity(os.getpid()), 'processes': records})
                last_scan = time.monotonic()
    finally:
        remaining = stop_records(descendants(records))
        if remaining:
            return 5
    return 0


class ProcessGuard:
    def __init__(self, command, state_dir, installation_id):
        self.installation_id = installation_id
        self.path = Path(state_dir) / 'processes.json'
        self.owner = process_identity(os.getpid())
        self.records = []
        private_directory(state_dir)
        self.reconcile()
        self.proc = subprocess.Popen(command + ['darwin-guard', str(self.path), installation_id],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     close_fds=True)
        guard_identity = None
        try:
            guard_identity = process_identity(self.proc.pid)
            if not guard_identity or guard_identity['ppid'] != self.owner['pid']:
                raise RuntimeError('Cannot establish guardian process identity')
            # First execution of a frozen/signed Python runtime can be much
            # slower than a warm launch. No app is released until this ACK.
            self.request('hello', timeout=GUARD_STARTUP_TIMEOUT)
        except BaseException:
            # Constructor failures must not leave an unowned pipe guardian.
            # It has received no track command, so no application can exist.
            self.proc.stdin.close()
            try:
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                current = process_identity(self.proc.pid)
                # Apple's source Python launcher can exec its framework binary
                # before Python begins. An unreaped direct child with identical
                # birth/UID/session is still ours; bind its current exact path.
                same_child = current and guard_identity and current['ppid'] == self.owner['pid'] and all(
                    current.get(key) == guard_identity.get(key) for key in ('pid', 'uid', 'birth', 'session'))
                if current is not None and (not same_child or stop_records([current])):
                    raise RuntimeError('Guardian startup and cleanup both failed')
                self.proc.wait(timeout=2)
            finally:
                self.proc.stdout.close()
            raise

    def reconcile(self):
        try:
            old = read_private_json(self.path)
        except FileNotFoundError:
            return
        if old.get('schema') != 1 or old.get('installation_id') != self.installation_id or old.get('uid') != os.getuid():
            raise RuntimeError('Warden process record installation identity mismatch')
        if same_process(old['owner'], process_identity(old['owner']['pid'])):
            raise RuntimeError('Recorded Warden is still alive; refusing a second supervisor')
        # The old pipe guardian normally completes first. Wait, then reconcile
        # records if the guardian itself also died. Never start overlapping apps.
        guard = old.get('guard')
        end = time.monotonic() + 9
        while guard and same_process(guard, process_identity(guard['pid'])) and time.monotonic() < end:
            time.sleep(0.05)
        if guard and same_process(guard, process_identity(guard['pid'])):
            raise RuntimeError('Previous Warden cleanup still active')
        rows = old.get('processes', [])
        if any(r.get('uid') != os.getuid() for r in rows):
            raise RuntimeError('Process record account mismatch')
        if stop_records(rows):
            raise RuntimeError('Previous Watchtower did not exit; refusing overlap')

    def request(self, operation, process=None, timeout=10):
        body = {'installation_id': self.installation_id, 'owner': self.owner, 'operation': operation}
        if process:
            body['process'] = process
        self.proc.stdin.write((json.dumps(body) + '\n').encode('utf-8'))
        self.proc.stdin.flush()
        deadline = time.monotonic() + timeout
        reply = b''
        while b'\n' not in reply:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.proc.stdout], [], [], remaining)[0]:
                raise RuntimeError('Warden process guard did not acknowledge within %g seconds' % timeout)
            block = os.read(self.proc.stdout.fileno(), 16)
            if not block or len(reply) + len(block) > 16:
                raise RuntimeError('Invalid process guard acknowledgement')
            reply += block
        if reply != b'OK\n':
            raise RuntimeError('Invalid process guard acknowledgement')

    def spawn(self, executable, gate, env, stdout, cwd=None):
        gate = str(Path(gate).resolve(strict=True))
        executable = str(Path(executable).resolve(strict=True))
        read_fd, write_fd = os.pipe()
        proc = None
        try:
            proc = subprocess.Popen([gate, str(read_fd), executable], pass_fds=(read_fd,),
                                    env=env, stdout=stdout, stderr=subprocess.STDOUT,
                                    cwd=cwd, close_fds=True)
            os.close(read_fd)
            read_fd = -1
            row = process_identity(proc.pid)
            if not row or row['path'] != gate or row['ppid'] != os.getpid():
                raise RuntimeError('Cannot establish suspended child process identity')
            row['allowed_paths'] = [gate, executable]
            self.records.append(row)
            self.request('track', row)
            os.write(write_fd, b'G')
            return proc
        except BaseException:
            if proc:
                # Gate EOF prevents execution even if recording never succeeded.
                os.close(write_fd)
                write_fd = -1
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    stop_records(self.records)
            raise
        finally:
            if read_fd >= 0:
                os.close(read_fd)
            if write_fd >= 0:
                os.close(write_fd)

    def healthy(self):
        return self.proc.poll() is None

    def cleanup(self):
        if self.healthy():
            self.request('cleanup')
        elif stop_records(descendants(self.records)):
            raise RuntimeError('Guard failed and Watchtower cleanup did not complete')
        self.records = []

    def close(self):
        self.cleanup()
        self.proc.stdin.close()
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            raise RuntimeError('Warden guard shutdown did not complete')
        self.proc.stdout.close()
        if self.proc.returncode != 0:
            raise RuntimeError('Warden guard exited unsuccessfully')


def platform_uuid():
    result = subprocess.run(['/usr/sbin/ioreg', '-rd1', '-c', 'IOPlatformExpertDevice', '-a'],
                            capture_output=True, timeout=10, check=True)
    rows = plistlib.loads(result.stdout)
    value = rows[0].get('IOPlatformUUID', '') if rows else ''
    if not value or len(value) > 128:
        raise RuntimeError('IOPlatformUUID unavailable')
    return value


def native_machine_key(path, legacy_enrolled=False):
    """Retain legacy enrollment's empty key; new stations use a hashed UUID."""
    try:
        value = read_private_json(path)
        key = value['machine_key']
        if value.get('schema') != 1 or not key.startswith('sha256:') or len(key) != 71:
            raise RuntimeError('Invalid persisted Darwin station identity')
        return key
    except FileNotFoundError:
        if legacy_enrolled:
            return ''
    key = 'sha256:' + hashlib.sha256(('cilex-darwin-v1|' + platform_uuid()).encode()).hexdigest()
    atomic_private_json(path, {'schema': 1, 'machine_key': key})
    return key


class ActivityClock:
    """Track observed file changes using monotonic elapsed time.

    Darwin monotonic time excludes suspend. A long scheduler gap or a divergence
    between wall and monotonic clocks grants a new grace interval, so waking or
    changing the wall clock cannot immediately label a healthy app hung. Missing
    logs eventually time out too, rather than disabling the watchdog forever.
    """
    def __init__(self, monotonic=time.monotonic, wall=time.time, gap=30):
        self.monotonic, self.wall, self.gap = monotonic, wall, gap
        self.last_mono = self.changed_at = monotonic()
        self.last_wall = wall()
        self.signature = None

    def age(self, signature):
        now, wall = self.monotonic(), self.wall()
        elapsed = max(0, now - self.last_mono)
        discontinuity = elapsed > self.gap or abs((wall - self.last_wall) - elapsed) > self.gap
        if discontinuity or signature != self.signature:
            self.changed_at = now
        self.signature = signature
        self.last_mono, self.last_wall = now, wall
        return max(0, now - self.changed_at)


def host_load(previous):
    system = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
    system.mach_host_self.restype = ctypes.c_uint32
    host = system.mach_host_self()
    ticks = (ctypes.c_uint32 * 4)()
    count = ctypes.c_uint32(4)
    system.host_statistics.argtypes = [ctypes.c_uint32, ctypes.c_int,
                                      ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
    try:
        if system.host_statistics(host, 3, ticks, ctypes.byref(count)) != 0:
            raise RuntimeError('Mach CPU load unavailable')
    finally:
        task = ctypes.c_uint32.in_dll(system, 'mach_task_self_').value
        system.mach_port_deallocate(ctypes.c_uint32(task), ctypes.c_uint32(host))
    current = (int(ticks[2]), sum(ticks))  # CPU_STATE_IDLE=2
    cpu = None
    if previous and current[1] > previous[1]:
        cpu = round(max(0, min(100, 100 * (1 - (current[0] - previous[0]) / (current[1] - previous[1])))), 1)
    # Free/inactive pages are reclaimable. This is a documented estimate, not
    # Activity Monitor's pressure metric; retain null if any counter is absent.
    vm = subprocess.run(['/usr/bin/vm_stat'], capture_output=True, text=True, timeout=5, check=True)
    import re
    page = re.search(r'page size of (\d+) bytes', vm.stdout)
    counts = dict((key, int(value)) for key, value in re.findall(r'^([^:\n]+):\s+(\d+)\.', vm.stdout, re.M))
    total = subprocess.run(['/usr/sbin/sysctl', '-n', 'hw.memsize'], capture_output=True,
                           text=True, timeout=5, check=True)
    mem = None
    if page and 'Pages free' in counts and 'Pages inactive' in counts:
        available = (counts['Pages free'] + counts['Pages inactive']) * int(page.group(1))
        mem = round(max(0, min(100, 100 * (1 - available / int(total.stdout)))), 1)
    return cpu, mem, current


def bound_log(path, limit=5 * 1024 * 1024):
    """Trim only a verified private regular log; keep a bounded previous tail."""
    path = Path(path)
    try:
        fd = os.open(str(path), os.O_RDWR | os.O_NOFOLLOW)
    except FileNotFoundError:
        return
    with os.fdopen(fd, 'r+b') as fh:
        st = os.fstat(fh.fileno())
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_mode & 0o077:
            raise RuntimeError('Unsafe Warden diagnostic log ownership or permissions')
        if st.st_size <= limit:
            return
        fh.seek(max(0, st.st_size - limit))
        tail = fh.read(limit)
        backup = path.with_name(path.name + '.previous')
        out = os.open(str(backup), os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(out, 'wb') as saved:
            saved.write(tail)
        fh.truncate(0)
