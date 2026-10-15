"""Shared deployment primitives. No import-time I/O or implicit network access."""
from __future__ import annotations

import datetime
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path
import platform
import re
import secrets
import selectors
import signal
import stat
import subprocess
import time

VERSION = "1.0.1"
SCHEMA = 1
EXITS = {"ok": 0, "usage": 2, "requirements": 10, "dependency": 11,
         "authentication": 12, "source": 13, "integrity": 14, "build": 15,
         "authorization": 16, "installation": 17, "verification": 18,
         "unknown": 19, "rollback": 20, "pending": 21, "security": 22}
SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
_secrets = []


class DeployError(Exception):
    def __init__(self, finding, message, code="requirements", ru=None, details=None):
        super().__init__(message)
        self.finding, self.message, self.code = finding, message, EXITS.get(code, code)
        self.ru, self.details = ru or message, details or {}


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def canonical_json(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def digest(value):
    return hashlib.sha256(canonical_json(value)).hexdigest()


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def secret(value):
    if value:
        _secrets.append(value)
    return value


def redact(value):
    value = str(value)
    for token in _secrets:
        value = value.replace(token, "[REDACTED]")
    value = re.sub(r"(?i)(https?://)[^/@\s]+:[^/@\s]+@", r"\1[REDACTED]@", value)
    value = re.sub(r"(?i)((?:access_token|refresh_token|authorization|password|gh_token)[\s\"':=]+)[^\s,\"}]+", r"\1[REDACTED]", value)
    return value


def clean_env(extra=None):
    env = {"PATH": SYSTEM_PATH, "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
           "HOME": str(Path.home()), "TMPDIR": "/tmp", "PYTHONNOUSERSITE": "1",
           "PYTHONDONTWRITEBYTECODE": "1", "GIT_TERMINAL_PROMPT": "0"}
    if extra:
        env.update({str(k): str(v) for k, v in extra.items()})
    return env


COMMAND_OUTPUT_LIMIT = 8 * 1024 * 1024


def _command_log(path, argv, proc, finding=None):
    """Bound retained diagnostics after redaction; never follow a log symlink."""
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'r+b') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077 or info.st_nlink != 1:
            raise DeployError('log.permissions', 'The diagnostic log is not a private owned file; use a protected work directory.', 'security',
                              ru='Журнал доступен другим пользователям или имеет неподходящий тип; запись остановлена. Укажите защищённый рабочий каталог.')
        stream.seek(max(0, info.st_size - COMMAND_OUTPUT_LIMIT))
        previous = stream.read(COMMAND_OUTPUT_LIMIT)
        header = json.dumps({'at': utc(), 'program': str(argv[0]), 'exit': proc.returncode, 'finding': finding})
        addition = (header + '\n' + redact(proc.stdout + proc.stderr) + '\n').encode('utf-8')
        content = previous + addition
        if len(content) > COMMAND_OUTPUT_LIMIT:
            marker = b'[Earlier diagnostics truncated at 8 MiB limit]\n'
            content = marker + content[-(COMMAND_OUTPUT_LIMIT - len(marker)):]
        stream.seek(0)
        stream.write(content)
        stream.truncate()


def command(argv, *, timeout=60, cwd=None, env=None, input=None, log=None,
            offline=False, network=False, check=True, pass_fds=(), output_limit=COMMAND_OUTPUT_LIMIT):
    if offline and network:
        raise DeployError("offline.network_forbidden", "Offline mode forbids this network operation; supply the required local files.", "dependency",
                          ru='В автономном режиме сеть запрещена; операция остановлена. Предоставьте необходимые локальные файлы.')
    if output_limit < 1 or timeout <= 0:
        raise ValueError('Positive output and timeout bounds are required')
    arguments = [str(a) for a in argv]
    payload = None if input is None else input.encode('utf-8')
    try:
        child = subprocess.Popen(arguments, cwd=cwd, env=clean_env(env),
                                 stdin=subprocess.PIPE if payload is not None else subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 pass_fds=pass_fds, start_new_session=True, bufsize=0)
    except OSError as exc:
        raise DeployError("command.unavailable", "A required tool could not run; provide the exact dependency from the manifest.", "dependency",
                          ru='Не удалось запустить обязательный инструмент; операция остановлена. Подготовьте точную зависимость из манифеста.',
                          details={"program": str(argv[0]), "error": redact(exc)})
    selector = selectors.DefaultSelector()
    output = {'stdout': bytearray(), 'stderr': bytearray()}
    total, offset, failure, interrupted = 0, 0, None, None
    deadline = time.monotonic() + timeout
    for stream, name in ((child.stdout, 'stdout'), (child.stderr, 'stderr')):
        os.set_blocking(stream.fileno(), False)
        selector.register(stream, selectors.EVENT_READ, name)
    if child.stdin:
        os.set_blocking(child.stdin.fileno(), False)
        if payload:
            selector.register(child.stdin, selectors.EVENT_WRITE, 'stdin')
        else:
            child.stdin.close()
    try:
        while selector.get_map() or child.poll() is None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                failure = 'command.timeout'
                break
            for key, _ in selector.select(min(remaining, .2)):
                if key.data == 'stdin':
                    try:
                        offset += os.write(key.fd, payload[offset:offset + 65536])
                    except BrokenPipeError:
                        offset = len(payload)
                    if offset == len(payload):
                        selector.unregister(key.fileobj)
                        key.fileobj.close()
                    continue
                chunk = os.read(key.fd, 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                    continue
                output[key.data].extend(chunk)
                total += len(chunk)
                if total > output_limit:
                    failure = 'command.output_limit'
                    break
            if failure:
                break
    except BaseException as exc:
        interrupted = exc
        failure = 'command.interrupted'
    finally:
        # A dedicated child session contains authentication/SSH helper children.
        # Timeouts and interruption never leave those helpers waiting on input.
        if failure or child.poll() is None or selector.get_map():
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        child.wait(timeout=5)
        selector.close()
        for stream in (child.stdin, child.stdout, child.stderr):
            if stream and not stream.closed:
                stream.close()
    proc = subprocess.CompletedProcess(arguments, child.returncode,
        output['stdout'].decode('utf-8', 'replace'), output['stderr'].decode('utf-8', 'replace'))
    if log:
        _command_log(Path(log), argv, proc, failure)
    if interrupted is not None:
        raise interrupted
    if failure:
        message = ('The operation exceeded its time limit; inspect the retained log before retrying.' if failure == 'command.timeout'
                   else 'The operation exceeded its diagnostic output limit; inspect the retained log. Truncated output is not a successful result.')
        raise DeployError(failure, message, 'verification',
                          ru=('Истекло время ожидания операции; результат не подтверждён. Перед повтором изучите сохранённый журнал.' if failure == 'command.timeout'
                              else 'Вывод инструмента превысил допустимый объём; результат не подтверждён. Изучите сохранённый журнал; усечённый ответ не считается успешным.'),
                          details={'program': Path(arguments[0]).name, 'timeout_seconds': timeout, 'output_limit_bytes': output_limit})
    if check and proc.returncode:
        raise DeployError("command.failed", "A required operation failed; inspect its diagnostics before retrying.", "verification",
                          ru='Обязательная операция завершилась ошибкой; результат не подтверждён. Перед повтором изучите диагностику.',
                          details={"program": Path(str(argv[0])).name, "exit": proc.returncode,
                                   "diagnostic": redact(proc.stderr[-4000:])})
    return proc


def read_json(path):
    with open(path, encoding="utf-8") as stream:
        return json.load(stream)


def private_dir(path):
    path = Path(path).absolute()
    if path.is_symlink():
        raise DeployError("path.symlink", "The state directory is a symbolic link; choose a private directory.", "security")
    # Resolve ancestor aliases before retaining paths (e.g. macOS /var and /tmp).
    # Subsequent operations use the physical path, not a redirectable alias.
    path = path.resolve()
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise DeployError("path.not_private", "The state directory is not private to this account; choose a directory with mode 0700.", "security",
                          details={"path": str(path)})
    return path


def atomic_json(path, value):
    path = Path(path)
    tmp = path.with_name("." + path.name + "." + secrets.token_hex(8))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(canonical_json(value) + b"\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            tmp.unlink()


def checked_private_file(path):
    path = Path(path)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077 or info.st_nlink != 1:
        raise DeployError("resume.permissions", "The resume record is not a private regular file owned by this account; do not reuse it.", "security")
    return path


def helper_hash(root):
    root = Path(root)
    rows = []
    for item in sorted(root.rglob("*")):
        if item.is_file() and not item.is_symlink() and "__pycache__" not in item.parts and ".pyc" != item.suffix:
            rows.append([item.relative_to(root).as_posix(), sha256(item)])
    return digest(rows)


class RunRecord:
    """Private authenticated journal bound to requested options and helper bytes."""
    def __init__(self, base, options, target, helper_digest, resume=None):
        if resume and not (Path(base) / resume / 'journal.json').is_file():
            raise DeployError('resume.missing', 'The requested protected run record does not exist; use the original run ID and work directory.', 'integrity',
                              ru='Защищённая запись запуска не найдена; укажите исходные ID и рабочий каталог.')
        self.base = private_dir(base)
        key_path = self.base / ".resume-key"
        if not key_path.exists():
            fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "wb") as stream:
                stream.write(secrets.token_bytes(32))
        self.key = checked_private_file(key_path).read_bytes()
        if len(self.key) != 32:
            raise DeployError('resume.key_integrity', 'The protected resume key is incomplete; preserve the original records and investigate before continuing.', 'integrity',
                              ru='Повреждён защищённый ключ возобновления; продолжение заблокировано. Сохраните исходные записи и выясните причину повреждения.')
        fingerprint = digest(options)
        if resume:
            if not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}", resume):
                raise DeployError("resume.id", "Use the exact run ID from the previous result.", "usage")
            self.root = private_dir(self.base / resume)
            self.acquire()
            signed = read_json(checked_private_file(self.root / "journal.json"))
            self.data = signed["record"]
            signature = hmac.new(self.key, canonical_json(self.data), hashlib.sha256).hexdigest()
            if not hmac.compare_digest(signature, signed.get("hmac_sha256", "")):
                raise DeployError("resume.integrity", "Resume record authentication failed; inspect the original run without rerunning installation.", "integrity")
            if self.data.get("schema_version") != SCHEMA or self.data.get("options_sha256") != fingerprint or self.data.get("target") != target or self.data.get("helper_sha256") != helper_digest:
                raise DeployError("resume.binding", "Target, options or deployment helper changed; this run cannot be resumed.", "security")
        else:
            if sum(1 for p in self.base.iterdir() if p.is_dir() and re.fullmatch(r'[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}', p.name)) >= 200:
                raise DeployError('run.retention_limit', 'The work directory contains 200 retained runs; archive reviewed runs before starting another.', 'requirements')
            run_id = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + secrets.token_hex(8)
            self.root = private_dir(self.base / run_id)
            self.acquire()
            self.data = {"schema_version": SCHEMA, "run_id": run_id, "created_at": utc(),
                         "target": target, "options_sha256": fingerprint,
                         "helper_sha256": helper_digest, "phase": "created", "events": []}
            self.save()

    def acquire(self):
        self.lock_fd = os.open(self.root / '.run-lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        info = os.fstat(self.lock_fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
            self.close()
            raise DeployError('run.lock_permissions', 'The run lock is not protected; inspect its ownership before resuming.', 'security')
        try:
            fcntl.flock(self.lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.close()
            raise DeployError('run.concurrent', 'This run is already active; wait for it before resuming.', 'unknown')

    def close(self):
        fd = getattr(self, 'lock_fd', None)
        if fd is not None:
            os.close(fd)
            self.lock_fd = None

    def __del__(self):
        self.close()

    def save(self):
        signature = hmac.new(self.key, canonical_json(self.data), hashlib.sha256).hexdigest()
        atomic_json(self.root / "journal.json", {"record": self.data, "hmac_sha256": signature})

    def phase(self, name, **evidence):
        self.data["phase"] = name
        self.data["events"].append({"phase": name, "at": utc(), **evidence})
        if len(self.data['events']) > 10000:
            raise DeployError('resume.event_limit', 'This run reached its event limit; preserve evidence and start a new run after reconciliation.', 'unknown')
        self.save()


def result(run_id=None):
    return {"schema_version": SCHEMA, "helper_version": VERSION, "run_id": run_id,
            "started_at": utc(), "finished_at": None, "accepted_findings": [],
            "states": {key: "Unverified" for key in ("installation", "runtime_health", "gui_video",
                      "backend", "security_admission", "recovery", "startup", "rollback", "cleanup")},
            "findings": [], "evidence": []}


def host_identity():
    if platform.system() != "Darwin":
        return {"os": platform.system(), "machine_id": None, "uid": os.geteuid()}
    proc = command(["/usr/sbin/ioreg", "-rd1", "-c", "IOPlatformExpertDevice"], check=False)
    match = re.search(r'"IOPlatformUUID"\s*=\s*"([^"]+)"', proc.stdout)
    return {"os": "Darwin", "machine_id": hashlib.sha256(("cilex-deploy|" + match.group(1)).encode()).hexdigest() if match else None,
            "uid": os.geteuid()}
