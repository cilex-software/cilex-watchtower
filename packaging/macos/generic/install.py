"""Fail-closed macOS transaction primitives. No operation runs at import time.

This module deliberately cannot certify GUI/video, backend, reboot or clean-Mac
acceptance from process existence. The caller must preserve its separate states.
"""
import contextlib
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import plistlib
import pwd
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import time
import unicodedata
import uuid
from common import DeployError, digest, checked_private_file

SCHEMA = 1
BUNDLE_ID = "com.cilexvision.watchtower"
PACKAGE_ID = BUNDLE_ID + ".macos"
SAFE_ENV = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"}
LOGINWINDOW_PLIST = Path("/Library/Preferences/com.apple.loginwindow.plist")


_RU = {
    "package.trust": "Не указан доверенный SHA-256 пакета; установка остановлена. Передайте --package-sha256 из доверенного источника.",
    "package.hash": "Хеш пакета или файла не совпадает; установка остановлена. Повторно получите проверенный пакет.",
    "space.extraction": "Недостаточно места для безопасной распаковки; установка остановлена. Освободите место и повторите попытку.",
    "space.transaction": "Недостаточно места для замены и отката; установка остановлена. Освободите место и повторите попытку.",
    "host.macos": "Требуется macOS; установка остановлена. Запустите установщик на целевом Mac.",
    "host.architecture": "Требуется нативный arm64; установка остановлена. Запустите установщик без Rosetta на Apple silicon.",
    "host.system_api": "Версия macOS ниже минимальной для компонентов пакета; установка остановлена. Обновите систему.",
    "security.offline_admission": "Автономная проверка Gatekeeper ещё не реализована; производственная установка заблокирована. Используйте проверенный поддерживаемый способ допуска пакета.",
    "security.development": "Это пакет для разработки; производственное доверие не подтверждено. Для явной попытки передайте --allow-development.",
    "target.desktop_user": "Не определена существующая учётная запись рабочего стола; установка остановлена. Укажите --desktop-user.",
    "target.root_gui": "Запуск интерфейса от root запрещён; установка остановлена. Укажите обычного пользователя рабочего стола.",
    "target.path": "Недопустимый путь установки; изменения не выполнены. Укажите абсолютный путь к пакету .app.",
    "target.symlink": "Путь установки содержит символическую ссылку; изменения не выполнены. Укажите канонический локальный путь.",
    "authorization.helper": "Защищённый помощник для установки от другого администратора ещё не реализован; изменения не выполнены. Выполните пользовательскую установку от учётной записи рабочего стола.",
    "authorization.destination": "Нет права записи в каталог назначения; изменения не выполнены. Используйте пользовательскую установку в доступный каталог.",
    "installation.locked": "Другая установка удерживает блокировку; изменения не выполнены. Дождитесь её завершения и возобновите запуск.",
    "startup.loaded_stopped": "LaunchAgent зарегистрирован, но процесс Warden отсутствует; установка остановлена, чтобы сохранить намеренную остановку. Проверьте состояние launchd и режим обслуживания; состояние задания автоматически не изменяется.",
    "runtime.unmanaged": "Выбранное приложение запущено вне его LaunchAgent; установка остановлена. Намеренно закройте этот экземпляр и повторите попытку.",
    "runtime.timeout": "Процессы выбранной установки не достигли ожидаемого состояния вовремя; результат не подтверждён. Изучите сохранённые свидетельства запуска.",
    "run.resume": "Для этого запуска уже есть запись транзакции; повторная установка заблокирована. Сначала проверьте фактический результат предыдущей попытки.",
    "package.staging": "Нет проверенного распакованного пакета; установка остановлена. Подготовьте пакет через основной инструмент развёртывания.",
}


class InstallError(DeployError):
    def __init__(self, finding, message):
        category = finding.split(".", 1)[0]
        code = {"package": "integrity", "archive": "integrity", "bundle": "integrity",
                "security": "security", "authorization": "authorization", "runtime": "verification",
                "run": "unknown", "receipt": "integrity"}.get(category, "installation")
        ru = _RU.get(finding)
        if ru is None:
            if category in ("package", "archive", "bundle", "security"):
                ru = "Проверка целостности или безопасности не пройдена (" + finding + "); установка остановлена. Получите корректный пакет и повторите проверку."
            else:
                ru = "Операция не выполнена (" + finding + "); успешный результат не подтверждён. Проверьте права, состояние установки и сохранённые свидетельства."
        super().__init__(finding, message, code=code, ru=ru)


def fail(finding, message):
    raise InstallError(finding, message)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_name(value):
    if not isinstance(value, str) or not value or "\\" in value or "\x00" in value:
        fail("archive.path", "Invalid archive path; obtain an intact package.")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in ("", ".", "..") for part in value.split("/")):
        fail("archive.path", "Archive traversal is forbidden; obtain an intact package.")
    return path


def collision_key(value):
    # Default APFS/HFS volumes are case insensitive and normalize Unicode.
    return unicodedata.normalize("NFD", str(value)).casefold()


def validate_link(name, target):
    if not isinstance(target, str) or not target or "\\" in target or "\x00" in target:
        fail("archive.link", "Invalid symbolic link; obtain an intact package.")
    if target.startswith("/"):
        fail("archive.link", "Absolute symbolic link rejected; obtain an intact package.")
    parts = list(PurePosixPath(name).parent.parts)
    for part in target.split("/"):
        if part == "..":
            if not parts:
                fail("archive.link", "Symbolic link escapes the package; obtain an intact package.")
            parts.pop()
        elif part not in ("", "."):
            parts.append(part)
    return "/".join(parts)


def read_quarantine(path):
    if platform.system() != "Darwin":
        return None
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    libc.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    libc.getxattr.restype = ctypes.c_ssize_t
    name, encoded = b"com.apple.quarantine", os.fsencode(path)
    size = libc.getxattr(encoded, name, None, 0, 0, 0)
    if size < 0:
        if ctypes.get_errno() in (93, 45):  # ENOATTR, ENOTSUP
            return None
        fail("security.quarantine", "Cannot inspect source quarantine metadata; inspect the package permissions.")
    if size > 65536:
        fail("security.quarantine", "Quarantine metadata exceeds the accepted size.")
    buffer = ctypes.create_string_buffer(size)
    if libc.getxattr(encoded, name, buffer, size, 0, 0) != size:
        fail("security.quarantine", "Quarantine metadata changed during inspection; retry the package validation.")
    return buffer.raw


def write_quarantine(path, value):
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    libc.setxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
    libc.setxattr.restype = ctypes.c_int
    if libc.setxattr(os.fsencode(path), b"com.apple.quarantine", value, len(value), 0, 0) != 0:
        fail("security.quarantine", "Cannot preserve package quarantine; inspect destination filesystem support.")


def safe_extract(package, destination, expected_sha256=None, max_bytes=32 * 1024**3):
    """Extract only regular files, directories and contained framework symlinks.

    The destination must be an existing empty owned directory. No tar extraction
    API is used: symlinks are created last and no file is written through a link.
    """
    package, destination = Path(package), Path(destination)
    if not re.fullmatch(r"[0-9a-fA-F]{64}", expected_sha256 or ""):
        fail("package.trust", "A trusted package SHA-256 is required; supply --package-sha256.")
    if package.is_symlink() or not package.is_file() or sha256(package) != expected_sha256.lower():
        fail("package.hash", "Package hash mismatch; obtain the expected package again.")
    if destination.is_symlink() or not destination.is_dir() or any(destination.iterdir()):
        fail("archive.destination", "Extraction requires an empty protected staging directory.")
    with tarfile.open(package, "r:*") as archive:
        members = archive.getmembers()
        names, entries, prefixes, total = {}, {}, {}, 0
        if len(members) > 200000:
            fail("archive.count", "Package has too many entries; inspect the package.")
        for member in members:
            name = str(safe_name(member.name.rstrip("/") if member.isdir() else member.name))
            key = collision_key(name)
            if key in names:
                fail("archive.collision", "Archive filename collision; rebuild the package.")
            names[key], entries[name] = name, member
            for prefix in (PurePosixPath(name), *PurePosixPath(name).parents):
                prefix_key = collision_key(prefix)
                if prefix_key in prefixes and prefixes[prefix_key] != str(prefix):
                    fail("archive.collision", "Archive parent filename collision; rebuild the package.")
                prefixes[prefix_key] = str(prefix)
            if not (member.isfile() or member.isdir() or member.issym()):
                fail("archive.type", "Archive contains an unsupported device or hard link.")
            if not member.issym() and member.mode & 0o7022:
                fail("archive.permissions", "Unsafe package permissions; rebuild the package.")
            if member.issym():
                validate_link(name, member.linkname)
            if member.size < 0:
                fail("archive.size", "Invalid archive size.")
            total += member.size
            if total > max_bytes:
                fail("archive.space", "Package extraction exceeds the safe space limit.")
        for name in entries:
            for parent in PurePosixPath(name).parents:
                if str(parent) in entries and not entries[str(parent)].isdir():
                    fail("archive.link_parent", "An archive entry would write through a non-directory.")
        required = total + 128 * 1024**2
        if shutil.disk_usage(destination).free < required:
            fail("space.extraction", "Insufficient space to extract safely; free storage and retry.")
        for name, member in entries.items():
            if member.issym():
                continue
            output = destination / name
            output.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
            if member.isdir():
                output.mkdir(exist_ok=True)
            else:
                with archive.extractfile(member) as source, open(output, "xb") as target:
                    shutil.copyfileobj(source, target)
            output.chmod(member.mode & 0o755)
        for name, member in entries.items():
            if member.issym():
                output = destination / name
                output.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
                output.symlink_to(member.linkname)
        root = destination.resolve()
        for name, member in entries.items():
            if member.issym():
                try:
                    (destination / name).resolve(strict=True).relative_to(root)
                except (OSError, RuntimeError, ValueError):
                    fail("archive.link", "Broken, cyclic or escaping symbolic link; rebuild the package.")
    # Retain quarantine inherited from the download; never strip it. The archive
    # itself and every extracted top-level bundle keep Apple's original value.
    quarantine = read_quarantine(package)
    if quarantine:
        for path in destination.iterdir():
            if not path.is_symlink():
                write_quarantine(path, quarantine)
    return total


def read_manifest(root):
    root = Path(root)
    try:
        manifest = json.loads((root / "artifact-manifest.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        fail("package.manifest", "Package manifest is missing or invalid: " + type(error).__name__)
    if manifest.get("schema_version") != SCHEMA or manifest.get("package_id") != PACKAGE_ID:
        fail("package.identity", "Unsupported package identity or manifest version.")
    if manifest.get("bundle_identifier") != BUNDLE_ID or not manifest.get("version") or not manifest.get("warden_version"):
        fail("package.metadata", "Package identifiers or versions are empty or incorrect.")
    if manifest.get("app") != "watchtower.app" or manifest.get("arch") != "arm64":
        fail("package.architecture", "Only the complete arm64 package layout is implemented.")
    for key in ("app", "warden"):
        safe_name(manifest.get(key))
    verify_inventory(root, manifest)
    app = root / manifest["app"]
    try:
        with (app / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, ValueError, plistlib.InvalidFileException):
        fail("bundle.plist", "Application metadata cannot be parsed; rebuild the package.")
    if info.get("CFBundleIdentifier") != BUNDLE_ID or info.get("CFBundleShortVersionString") != manifest["version"] or not info.get("CFBundleVersion"):
        fail("bundle.identity", "Application metadata does not match the package manifest.")
    executable = info.get("CFBundleExecutable", "")
    if not executable or "/" in executable or executable in (".", ".."):
        fail("bundle.executable", "Application executable metadata is invalid.")
    if not any("cilex" in entry.get("CFBundleURLSchemes", []) for entry in info.get("CFBundleURLTypes", [])):
        fail("bundle.url_scheme", "The cilex URL scheme is missing; rebuild the package.")
    for path in (app / "Contents/MacOS" / executable, root / manifest["warden"]):
        if path.is_symlink() or not path.is_file() or not os.access(path, os.X_OK):
            fail("bundle.executable", "Required executable is absent or not executable.")
    manifest["_executable"] = executable
    try:
        from closure import audit, ClosureError
        audited = audit(root, arch="arm64", source_minimum=manifest.get("minimum_macos", "0"))
        if version_tuple(audited["minimum_macos"]) != version_tuple(manifest.get("minimum_macos")):
            fail("bundle.minimum", "Runtime requirements exceed the declared macOS version.")
    except ClosureError as error:
        fail("bundle.closure", "Runtime closure validation failed: " + str(error))
    return manifest


def verify_inventory(root, manifest):
    root, expected, aliases = Path(root), {}, set()
    files = manifest.get("files")
    if not isinstance(files, list) or not files:
        fail("package.inventory", "Package inventory is empty; rebuild the package.")
    for entry in files:
        name = str(safe_name(entry.get("path")))
        key = collision_key(name)
        if key in aliases or name == "artifact-manifest.json":
            fail("package.collision", "Manifest contains duplicate or reserved paths.")
        aliases.add(key)
        expected[name] = entry
    actual = {str(path.relative_to(root)) for path in root.rglob("*") if not path.is_dir() or path.is_symlink()}
    actual.discard("artifact-manifest.json")
    non_dirs = {name for name, item in expected.items() if item.get("type") != "directory"}
    if actual != non_dirs:
        fail("package.inventory", "Package inventory differs from disk; obtain an intact package.")
    for name, entry in expected.items():
        path = root / name
        try:
            st = path.lstat()
        except OSError:
            fail("package.missing", "A manifest entry is missing; obtain an intact package.")
        if entry.get("type") == "symlink":
            if not path.is_symlink() or os.readlink(path) != entry.get("target"):
                fail("package.link", "Package symlink mismatch; obtain an intact package.")
            validate_link(name, entry["target"])
            try:
                path.resolve(strict=True).relative_to(root.resolve())
            except (ValueError, OSError, RuntimeError):
                fail("package.link", "Package symlink escapes or is broken.")
        elif entry.get("type") == "directory":
            if not stat.S_ISDIR(st.st_mode):
                fail("package.type", "Package directory type mismatch.")
        elif entry.get("type") == "file":
            if entry.get("size") is not None and st.st_size != entry["size"]:
                fail("package.size", "Package file size mismatch.")
            if not stat.S_ISREG(st.st_mode) or sha256(path) != entry.get("sha256"):
                fail("package.hash", "Package file hash mismatch; obtain an intact package.")
        else:
            fail("package.type", "Unknown package file type.")
        if not stat.S_ISLNK(st.st_mode):
            mode = entry.get("mode")
            if isinstance(mode, str):
                mode = int(mode, 8)
            if mode is None or stat.S_IMODE(st.st_mode) != mode or mode & 0o7022:
                fail("package.permissions", "Package permissions do not match safe manifest permissions.")


def execute(argv, timeout=30, check=True):
    try:
        result = subprocess.run(argv, env=SAFE_ENV, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        fail("command.failed", "Required local operation failed: " + Path(argv[0]).name + " (" + type(error).__name__ + ")")
    if check and result.returncode:
        fail("command.failed", "Required local operation failed: " + Path(argv[0]).name + "; inspect protected diagnostics.")
    return result


def version_tuple(value):
    try:
        parts = str(value).split(".")
        if not 1 <= len(parts) <= 3:
            raise ValueError()
        return tuple(int(part) for part in parts) + (0,) * (3 - len(parts))
    except ValueError:
        fail("package.minimum", "Package macOS requirement is invalid.")


def security_check(root, manifest, options):
    if platform.system() != "Darwin":
        fail("host.macos", "Installation requires macOS; run the package on the target Mac.")
    native_arm = execute(["/usr/sbin/sysctl", "-n", "hw.optional.arm64"], check=False).stdout.strip() == "1"
    translated = execute(["/usr/sbin/sysctl", "-n", "sysctl.proc_translated"], check=False).stdout.strip() == "1"
    if not native_arm or translated:
        fail("host.architecture", "Native arm64 execution is required; use a native Apple silicon session.")
    if not manifest.get("minimum_macos") or version_tuple(platform.mac_ver()[0]) < version_tuple(manifest["minimum_macos"]):
        fail("host.system_api", "Target macOS is below the audited runtime minimum; upgrade the OS.")
    app = Path(root) / manifest["app"]
    execute(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], timeout=120)
    if manifest.get("distribution") == "production":
        if not manifest.get("security", {}).get("team_identifier") or not manifest.get("security", {}).get("notarized"):
            fail("security.production", "Production signing/notarization evidence is incomplete; rebuild with approved signing credentials.")
        identity = execute(["/usr/bin/codesign", "-dv", "--verbose=4", str(app)], check=False)
        if "TeamIdentifier=" + manifest["security"]["team_identifier"] not in identity.stderr.splitlines():
            fail("security.team", "Signing team differs from the manifest; obtain the approved package.")
        if options.get("dependencies") == "offline":
            fail("security.offline_admission", "Offline Gatekeeper assessment is not implemented; production offline installation remains blocked.")
        execute(["/usr/sbin/spctl", "--assess", "--type", "execute", str(app)], timeout=120)
        return "Passed"
    if manifest.get("distribution") != "development" or not options.get("allow_development"):
        fail("security.development", "Development artifact requires --allow-development; production trust remains unverified.")
    return "DevelopmentOnly"


def resolve_target(options):
    username = options.get("desktop_user")
    if not username:
        # The console owner identifies the desktop user, never the elevated account.
        try:
            uid = Path("/dev/console").stat().st_uid
            if uid == 0:
                fail("target.desktop_user", "No desktop user is signed in; specify --desktop-user.")
            account = pwd.getpwuid(uid)
        except (OSError, KeyError):
            fail("target.desktop_user", "Desktop account is unknown; specify --desktop-user.")
    else:
        try:
            account = pwd.getpwnam(username)
        except KeyError:
            fail("target.desktop_user", "Desktop account does not exist; specify an existing account.")
    if account.pw_uid == 0:
        fail("target.root_gui", "The desktop account cannot be root; specify the intended GUI user.")
    home = Path(account.pw_dir)
    scope = options.get("scope", "user")
    if scope not in ("user", "machine"):
        fail("target.scope", "Unknown installation scope; use user or machine.")
    path = Path(options.get("install_dir") or (home / "Applications/watchtower.app" if scope == "user" else "/Applications/watchtower.app"))
    if not path.is_absolute() or path.suffix != ".app" or not path.stem or ".." in path.parts:
        fail("target.path", "Use an absolute destination ending in .app without parent traversal.")
    # Existing symlink ancestors could redirect the selected installation.
    for ancestor in (path, *path.parents):
        if ancestor.is_symlink():
            fail("target.symlink", "Destination has a symlink ancestor; select its canonical local path.")
    install_id = hashlib.sha256((str(path) + "\0" + str(account.pw_uid)).encode()).hexdigest()[:24]
    support = home / "Library/Application Support/CilexWatchtower/Deploy" / install_id
    return {"uid": account.pw_uid, "gid": account.pw_gid, "user": account.pw_name,
            "home": home, "path": path, "id": install_id, "support": support,
            "label": "com.cilexvision.watchtower." + install_id,
            "domain": "gui/" + str(account.pw_uid),
            "agent": home / "Library/LaunchAgents" / ("com.cilexvision.watchtower." + install_id + ".plist")}


def launchagent(target, manifest, options):
    home, app = target["home"], target["path"]
    state = home / "Library/Application Support/CilexWatchtower/Warden" / target["id"]
    warden = app / Path(manifest["warden"]).relative_to(manifest["app"])
    env = {"PATH": SAFE_ENV["PATH"], "HOME": str(home), "USER": target["user"],
           "LOGNAME": target["user"], "WT_WARDEN_INSTALLATION_ID": target["id"],
           "WT_WARDEN_APP_CMD": str(app / "Contents/MacOS" / manifest["_executable"]),
           "WT_WARDEN_APP_WORKING_DIR": str(home), "WT_WARDEN_WARDEN_DIR": str(state),
           "WT_WARDEN_DATA_DIR": str(home / "Library/Application Support/Cilex Vision/Watchtower"),
           "WT_WARDEN_SPAWN_GATE": str(warden.with_name("cilex-spawn-gate"))}
    env.update({"GST_PLUGIN_PATH": str(app / "Contents/PlugIns/gstreamer-1.0"),
                "GST_PLUGIN_SYSTEM_PATH": "", "GST_PLUGIN_SYSTEM_PATH_1_0": "",
                "GST_PLUGIN_PATH_1_0": str(app / "Contents/PlugIns/gstreamer-1.0"),
                "GST_PLUGIN_SCANNER": str(app / "Contents/Helpers/gst-plugin-scanner"),
                "GST_PLUGIN_SCANNER_1_0": str(app / "Contents/Helpers/gst-plugin-scanner"),
                "GST_REGISTRY": str(home / "Library/Caches/CilexWatchtower" / target["id"] / "gstreamer-registry.bin"),
                "WT_FFMPEG": str(app / "Contents/MacOS/ffmpeg")})
    if options.get("backend_url"):
        env["WT_WARDEN_BACKEND_URL"] = options["backend_url"]
    logs = home / "Library/Logs/CilexWatchtower" / target["id"]
    env["WT_WARDEN_LOG_DIR"] = str(logs)
    # launchd EnvironmentVariables are additive. System env is protected Apple
    # code, and execs Warden after clearing inherited DYLD/Qt/GStreamer/Python
    # settings. exec preserves the required launchd -> Warden parentage.
    argv = ["/usr/bin/env", "-i"] + [key + "=" + value for key, value in sorted(env.items())] + [str(warden), "run"]
    return {"Label": target["label"], "ProgramArguments": argv,
            "WorkingDirectory": str(home),
            "StandardOutPath": str(logs / "warden-launchd.log"),
            "StandardErrorPath": str(logs / "warden-launchd-error.log"),
            "RunAtLoad": True, "KeepAlive": {"SuccessfulExit": False},
            "ThrottleInterval": 10, "ExitTimeOut": 30, "AbandonProcessGroup": False,
            "LimitLoadToSessionType": "Aqua", "ProcessType": "Interactive", "Umask": 0o077}


def register_bundle(path):
    """Register bundle metadata/URL schemes without launching through `open`."""
    cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    core = ctypes.CDLL("/System/Library/Frameworks/CoreServices.framework/CoreServices")
    cf.CFURLCreateFromFileSystemRepresentation.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_bool]
    cf.CFURLCreateFromFileSystemRepresentation.restype = ctypes.c_void_p
    cf.CFRelease.argtypes = [ctypes.c_void_p]
    core.LSRegisterURL.argtypes = [ctypes.c_void_p, ctypes.c_bool]
    core.LSRegisterURL.restype = ctypes.c_int32
    encoded = os.fsencode(path)
    url = cf.CFURLCreateFromFileSystemRepresentation(None, encoded, len(encoded), True)
    if not url:
        fail("bundle.registration", "Application path could not be registered with Launch Services.")
    try:
        if core.LSRegisterURL(url, True) != 0:
            fail("bundle.registration", "Launch Services rejected application registration; inspect the bundle.")
    finally:
        cf.CFRelease(url)


def registration_api():
    """Public Launch Services APIs available on the declared macOS baseline."""
    cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    core = ctypes.CDLL("/System/Library/Frameworks/CoreServices.framework/CoreServices")
    signatures = {
        "CFStringCreateWithCString": ([ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32], ctypes.c_void_p),
        "CFStringGetCString": ([ctypes.c_void_p, ctypes.c_void_p, ctypes.c_long, ctypes.c_uint32], ctypes.c_bool),
        "CFURLCreateWithString": ([ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p], ctypes.c_void_p),
        "CFURLCopyFileSystemPath": ([ctypes.c_void_p, ctypes.c_long], ctypes.c_void_p),
        "CFErrorGetCode": ([ctypes.c_void_p], ctypes.c_long),
        "CFRelease": ([ctypes.c_void_p], None)}
    for name, (arguments, result) in signatures.items():
        method = getattr(cf, name)
        method.argtypes, method.restype = arguments, result
    core.LSCopyDefaultHandlerForURLScheme.argtypes = [ctypes.c_void_p]
    core.LSCopyDefaultHandlerForURLScheme.restype = ctypes.c_void_p
    core.LSCopyDefaultApplicationURLForURL.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_void_p)]
    core.LSCopyDefaultApplicationURLForURL.restype = ctypes.c_void_p
    core.LSSetDefaultHandlerForURLScheme.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    core.LSSetDefaultHandlerForURLScheme.restype = ctypes.c_int32
    return cf, core


def registration_snapshot():
    """Read the default cilex handler and resolved path without opening a URL."""
    objects = []
    try:
        cf, core = registration_api()
        def string(value):
            obj = cf.CFStringCreateWithCString(None, value.encode("utf-8"), 0x08000100)
            if not obj:
                raise ValueError("CFString allocation failed")
            objects.append(obj)
            return obj
        def decoded(obj):
            buffer = ctypes.create_string_buffer(32768)
            if not cf.CFStringGetCString(obj, buffer, len(buffer), 0x08000100):
                raise ValueError("CFString is too large or not UTF-8")
            return buffer.value.decode("utf-8")
        handler = core.LSCopyDefaultHandlerForURLScheme(string("cilex"))
        if handler:
            objects.append(handler)
        url = cf.CFURLCreateWithString(None, string("cilex://"), None)
        if not url:
            raise ValueError("CFURL allocation failed")
        objects.append(url)
        error = ctypes.c_void_p()
        app_url = core.LSCopyDefaultApplicationURLForURL(url, 0xFFFFFFFF, ctypes.byref(error))
        if error.value:
            objects.append(error.value)
        if app_url:
            objects.append(app_url)
            path = cf.CFURLCopyFileSystemPath(app_url, 0)
            if not path:
                raise ValueError("Handler application path unavailable")
            objects.append(path)
            if not handler:
                raise ValueError("Handler identifier and application disagree")
            return {"state": "Observed", "bundle_identifier": decoded(handler), "application_path": decoded(path)}
        if not handler and (not error.value or cf.CFErrorGetCode(error) == -10814):
            return {"state": "Absent", "bundle_identifier": None, "application_path": None}
        return {"state": "Unverified", "reason": "Default handler could not be resolved consistently."}
    except (OSError, AttributeError, ValueError):
        return {"state": "Unverified", "reason": "Public Launch Services inspection was unavailable."}
    finally:
        if objects:
            for obj in reversed(objects):
                cf.CFRelease(obj)


def set_default_handler(bundle_identifier):
    """Restore only a known prior handler through the public API; honor rejection."""
    cf, core = registration_api()
    objects = []
    try:
        for value in ("cilex", bundle_identifier):
            obj = cf.CFStringCreateWithCString(None, value.encode("utf-8"), 0x08000100)
            if not obj:
                fail("bundle.registration", "Cannot prepare the previous URL handler for restoration.")
            objects.append(obj)
        return core.LSSetDefaultHandlerForURLScheme(*objects)
    finally:
        for obj in reversed(objects):
            cf.CFRelease(obj)


def restore_registration(previous):
    """Restore and inspect default-handler identity; never invent an unregister."""
    current = registration_snapshot()
    evidence = {"state": "Unverified", "before": previous, "after": current,
                "catalog_restoration": "UnverifiedNoPublicUnregister"}
    if not isinstance(previous, dict) or previous.get("state") not in ("Observed", "Absent") or current.get("state") == "Unverified":
        evidence["reason"] = "Prior or current default handler evidence is unavailable."
        return evidence
    if current == previous:
        evidence["state"] = "DefaultHandlerPreserved"
        return evidence
    if previous["state"] == "Absent":
        evidence["reason"] = "No supported public API to clear a newly registered URL handler was used."
        return evidence
    identifier, path = previous.get("bundle_identifier"), Path(previous.get("application_path") or "")
    try:
        if not isinstance(identifier, str) or not identifier or not path.is_absolute() or path.suffix != ".app":
            raise ValueError("invalid prior handler")
        with (path / "Contents/Info.plist").open("rb") as stream:
            if plistlib.load(stream).get("CFBundleIdentifier") != identifier:
                raise ValueError("prior handler changed")
        # Registering the prior path is necessary when two bundles have the same
        # identifier. Exact readback remains required; registration is no proof.
        if current.get("application_path") != str(path):
            register_bundle(path)
        status = set_default_handler(identifier)
        evidence["status"] = status
        evidence["after"] = registration_snapshot()
        if status == 0 and evidence["after"] == previous:
            evidence["state"] = "DefaultHandlerRestored"
        else:
            evidence["reason"] = "Native handler restoration was denied or exact path readback differed."
    except (OSError, ValueError, InstallError, plistlib.InvalidFileException):
        evidence["reason"] = "The prior handler application is unavailable or restoration was rejected."
    return evidence


def preserve_registered_default(state, result):
    previous = state.get("registration_before")
    if previous and previous.get("state") == "Observed":
        evidence = restore_registration(previous)
        result["registration"] = evidence
        if evidence["state"] not in ("DefaultHandlerPreserved", "DefaultHandlerRestored"):
            fail("bundle.registration_preservation", "The previous cilex URL handler could not be preserved; restore the prior installation and inspect registration evidence.")


def record_rollback_registration(state, result):
    evidence = restore_registration(state.get("registration_before"))
    result["rollback_registration"] = evidence
    if evidence["state"] not in ("DefaultHandlerPreserved", "DefaultHandlerRestored"):
        result.setdefault("limitations", []).append("Default cilex URL handler recovery is unverified; inspect native settings before relying on deep links.")


def process_snapshot():
    """Native executable/UID/session/birth identity shared with runtime checks."""
    from runtime import process_snapshot as native_snapshot
    return native_snapshot()


def selected_processes(target, manifest):
    app = target["path"]
    paths = {str(app / "Contents/MacOS" / manifest["_executable"]),
             str(app / Path(manifest["warden"]).relative_to(manifest["app"]))}
    return [process for process in process_snapshot() if process["uid"] == target["uid"] and process["path"] in paths]


def job_state(target):
    service = target["domain"] + "/" + target["label"]
    live = execute(["/bin/launchctl", "print", service], check=False)
    disabled = execute(["/bin/launchctl", "print-disabled", target["domain"]], check=False)
    match = re.search(r'"' + re.escape(target["label"]) + r'"\s*=>\s*(true|false)', disabled.stdout)
    pid = re.search(r"^\s*pid = (\d+)\s*$", live.stdout, re.MULTILINE)
    return {"loaded": live.returncode == 0, "disabled": match.group(1) == "true" if match else False,
            "disabled_explicit": bool(match), "pid": int(pid.group(1)) if pid else None,
            "gui_session": execute(["/bin/launchctl", "print", target["domain"]], check=False).returncode == 0}


def assert_job_process(target, manifest, state):
    if not state.get("pid"):
        return
    path = str(target["path"] / Path(manifest["warden"]).relative_to(manifest["app"]))
    rows = [row for row in process_snapshot() if row["pid"] == state["pid"]]
    if len(rows) != 1 or rows[0]["uid"] != target["uid"] or rows[0]["path"] != path or rows[0]["ppid"] != 1:
        fail("runtime.job_identity", "The loaded startup process does not match the selected installation and account; no process was stopped.")


def verify_processes(target, manifest, state=None):
    # The packaged guardian deliberately runs from the Warden executable too.
    # Native creation records distinguish it from an unexpected second Warden.
    from runtime import process_evidence
    return process_evidence(target, manifest)


def wait_processes(target, manifest, running, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        evidence = verify_processes(target, manifest)
        if (running and evidence["state"] == "ProcessVerified") or (not running and not evidence["processes"]):
            return evidence
        time.sleep(0.2)
    fail("runtime.timeout", "Selected installation did not reach the expected process state within the recovery budget.")


def atomic_bytes(path, value, mode=0o600, uid=None, gid=None):
    path = Path(path)
    fd, temp = tempfile.mkstemp(prefix=".write-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(value)
            os.fchmod(stream.fileno(), mode)
            if uid is not None or gid is not None:
                os.fchown(stream.fileno(), -1 if uid is None else uid, -1 if gid is None else gid)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
        parent = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(parent)
        finally:
            os.close(parent)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def atomic_json(path, value):
    atomic_bytes(path, (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8"))


def configuration_paths(target):
    """Only application configuration; never server holds, workers or guard state."""
    home = target["home"]
    return [home / "Library/Preferences/com.cilex-vision.Watchtower.plist",
            home / "Library/Preferences/com.cilexvision.watchtower.plist",
            home / ".config/watchtower-warden/warden.conf",
            home / "Library/Application Support/Cilex Vision/Watchtower/warden.conf"]


def preferences_cache(domain, values=None):
    """Synchronize the current user's native preference domain; no daemon killing.

    When values is supplied it replaces the domain, including removal of newly
    added keys. The caller is restricted to the intended desktop user's UID.
    """
    cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    ptr, integer = ctypes.c_void_p, ctypes.c_long
    cf.CFStringCreateWithCString.argtypes = [ptr, ctypes.c_char_p, ctypes.c_uint32]
    cf.CFStringCreateWithCString.restype = ptr
    cf.CFRelease.argtypes = [ptr]
    cf.CFPreferencesAppSynchronize.argtypes = [ptr]
    cf.CFPreferencesAppSynchronize.restype = ctypes.c_bool
    cf.CFPreferencesCopyMultiple.argtypes = [ptr, ptr, ptr, ptr]
    cf.CFPreferencesCopyMultiple.restype = ptr
    cf.CFPreferencesSetMultiple.argtypes = [ptr, ptr, ptr, ptr, ptr]
    cf.CFDataCreate.argtypes = [ptr, ctypes.c_void_p, integer]
    cf.CFDataCreate.restype = ptr
    cf.CFPropertyListCreateWithData.argtypes = [ptr, ptr, ctypes.c_ulong, ptr, ptr]
    cf.CFPropertyListCreateWithData.restype = ptr
    cf.CFPropertyListCreateData.argtypes = [ptr, ptr, integer, ctypes.c_ulong, ptr]
    cf.CFPropertyListCreateData.restype = ptr
    cf.CFDataGetLength.argtypes = [ptr]
    cf.CFDataGetLength.restype = integer
    cf.CFDataGetBytePtr.argtypes = [ptr]
    cf.CFDataGetBytePtr.restype = ptr
    user = ptr.in_dll(cf, "kCFPreferencesCurrentUser")
    host = ptr.in_dll(cf, "kCFPreferencesAnyHost")
    owned = []

    def native(value):
        raw = plistlib.dumps(value)
        data = cf.CFDataCreate(None, raw, len(raw))
        if not data:
            fail("configuration.preferences", "Cannot serialize native preferences for recovery.")
        owned.append(data)
        result = cf.CFPropertyListCreateWithData(None, data, 0, None, None)
        if not result:
            fail("configuration.preferences", "Native preferences rejected the rollback data.")
        owned.append(result)
        return result

    def python(value):
        data = cf.CFPropertyListCreateData(None, value, 100, 0, None)  # XML v1
        if not data:
            fail("configuration.preferences", "Cannot inspect the native preference cache.")
        owned.append(data)
        return plistlib.loads(ctypes.string_at(cf.CFDataGetBytePtr(data), cf.CFDataGetLength(data)))

    try:
        application = cf.CFStringCreateWithCString(None, domain.encode("utf-8"), 0x08000100)
        if not application:
            fail("configuration.preferences", "Preference domain could not be represented.")
        owned.append(application)
        if not cf.CFPreferencesAppSynchronize(application):
            fail("configuration.preferences", "Native preferences could not be synchronized; inspect user permissions.")
        current = cf.CFPreferencesCopyMultiple(None, application, user, host)
        if not current:
            fail("configuration.preferences", "Native preferences could not be read for verification.")
        owned.append(current)
        existing = python(current)
        if values is None:
            return existing
        if not isinstance(values, dict):
            fail("configuration.preferences", "The prior preference domain is not a dictionary.")
        removed = [key for key in existing if key not in values]
        cf.CFPreferencesSetMultiple(native(values), native(removed), application, user, host)
        if not cf.CFPreferencesAppSynchronize(application):
            fail("configuration.preferences", "Native preference restoration was not persisted; recovery is incomplete.")
        restored = cf.CFPreferencesCopyMultiple(None, application, user, host)
        if not restored:
            fail("configuration.preferences", "Restored native preferences could not be verified.")
        owned.append(restored)
        if python(restored) != values:
            fail("configuration.preferences", "Restored native preferences differ from the snapshot; recovery is incomplete.")
        return values
    finally:
        for value in reversed(owned):
            cf.CFRelease(value)


def configuration_file(path, target):
    for ancestor in (path, *path.parents):
        if ancestor.is_symlink():
            fail("configuration.symlink", "An application configuration path is a symbolic link; inspect it before installation.")
        if ancestor == target["home"]:
            break
    if not path.exists():
        return None
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != target["uid"] or info.st_mode & 0o022:
        fail("configuration.ownership", "Application configuration is not an owned regular file; inspect its ownership and permissions.")
    if info.st_size > 32 * 1024**2:
        fail("configuration.size", "Application configuration exceeds the snapshot limit; inspect it before installation.")
    return info


def snapshot_configuration(target, staging):
    snapshots = []
    for index, path in enumerate(configuration_paths(target)):
        info = configuration_file(path, target)
        item = {"path": str(path), "existed": info is not None}
        if info is not None:
            if path.suffix == ".plist":
                # Synchronize only in an installation transaction; check/verify
                # never enter this function or write preference caches.
                preferences_cache(path.stem)
                info = configuration_file(path, target)
                if info is None:
                    fail("configuration.changed", "Configuration changed while being snapshotted; retry before replacing the application.")
            raw = path.read_bytes()
            backup = staging / ("configuration-" + str(index) + ".backup")
            atomic_bytes(backup, raw)
            item.update(backup=backup.name, sha256=sha256(backup), mode=stat.S_IMODE(info.st_mode), uid=info.st_uid, gid=info.st_gid)
        snapshots.append(item)
    return snapshots


def configuration_backups(target, staging, snapshots):
    allowed = configuration_paths(target)
    if not isinstance(snapshots, list) or len(snapshots) != len(allowed):
        fail("configuration.record", "Configuration recovery record is incomplete; preserve the transaction for inspection.")
    verified = []
    for index, (item, path) in enumerate(zip(snapshots, allowed)):
        if item.get("path") != str(path) or not isinstance(item.get("existed"), bool):
            fail("configuration.binding", "Configuration snapshot belongs to a different path or account.")
        raw = None
        if item["existed"]:
            if item.get("backup") != "configuration-" + str(index) + ".backup" or item.get("uid") != target["uid"]:
                fail("configuration.binding", "Configuration snapshot ownership or backup path is invalid.")
            if not isinstance(item.get("mode"), int) or item["mode"] & 0o7022 or not isinstance(item.get("gid"), int):
                fail("configuration.permissions", "Recorded configuration permissions are unsafe or incomplete.")
            backup = checked_private_file(staging / item["backup"])
            if sha256(backup) != item.get("sha256"):
                fail("configuration.hash", "Private configuration snapshot failed its hash; preserve the original failure evidence.")
            raw = backup.read_bytes()
            if path.suffix == ".plist" and not isinstance(plistlib.loads(raw), dict):
                fail("configuration.preferences", "Prior preferences are not a valid dictionary.")
        verified.append((path, item, raw))
    return verified


def restore_configuration(target, staging, snapshots):
    verified = configuration_backups(target, staging, snapshots)
    # Validate every destination and every backup before changing any file.
    for path, item, raw in verified:
        configuration_file(path, target)
    for path, item, raw in verified:
        if path.suffix == ".plist" and (raw is not None or path.exists()):
            preferences_cache(path.stem, plistlib.loads(raw) if raw is not None else {})
        if raw is None:
            path.unlink(missing_ok=True)
        else:
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            atomic_bytes(path, raw, item["mode"], item["uid"], item["gid"])
        info = configuration_file(path, target)
        if raw is None:
            if info is not None:
                fail("configuration.restore", "New configuration could not be removed during rollback.")
        elif info is None or sha256(path) != item["sha256"] or (stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid) != (item["mode"], item["uid"], item["gid"]):
            fail("configuration.restore", "Configuration bytes or ownership differ after rollback; recovery is incomplete.")


def protected_directory(path):
    path = Path(path)
    for ancestor in (path, *path.parents):
        if ancestor.is_symlink():
            fail("state.symlink", "State path contains a symlink; choose a protected local path.")
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    st = path.stat()
    if st.st_uid != os.geteuid() or st.st_mode & 0o022:
        fail("state.permissions", "State directory is not owned and protected; correct its ownership and permissions.")
    path.chmod(0o700)


@contextlib.contextmanager
def installation_lock(target):
    path = target["path"].parent / ("." + target["path"].name + ".cilex-deploy.lock")
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        st = os.fstat(fd)
        if st.st_uid != os.geteuid() or not stat.S_ISREG(st.st_mode) or st.st_mode & 0o077 or st.st_nlink != 1:
            fail("lock.permissions", "Installation lock is not protected; inspect it before retrying.")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            fail("installation.locked", "Another deployment owns this installation; resume after it completes.")
        yield
    finally:
        os.close(fd)


def base_result(target):
    return {"schema_version": SCHEMA, "installation_id": target["id"], "target_user": target["user"],
            "target_uid": target["uid"], "install_dir": str(target["path"]),
            "installation": "Unverified", "runtime_health": "Unverified", "gui_video": "Unverified",
            "backend": "Unverified", "security_admission": "Unverified", "recovery": "Unverified",
            "startup": "StartupUnverified", "rollback": "NotRequired", "cleanup": "NotRequired",
            "full_success": False, "evidence": []}


def startup_assessment(target, options):
    """Bounded, read-only startup assessment. Never read auto-login secrets."""
    requested = options.get("startup", "after-sign-in")
    evidence = {"requested_mode": requested, "filevault": "Unverified",
                "automatic_login": "Unverified", "desktop_account_matches": None,
                "restart": "Unverified", "cold_start": "Unverified", "blockers": [],
                "sources": ["/usr/bin/fdesetup status", str(LOGINWINDOW_PLIST),
                            "https://support.apple.com/en-au/102316"],
                "limitations": ["An automatic-login preference does not prove that login is permitted or functioning.",
                                "Management policy and Apple Account password restrictions were not assessed.",
                                "Registration or an existing session does not prove post-reboot or power-loss recovery."]}
    if platform.system() == "Darwin":
        try:
            status = execute(["/usr/bin/fdesetup", "status"], timeout=15, check=False)
            if status.returncode == 0 and isinstance(status.stdout, str):
                if re.search(r"^FileVault is On\.", status.stdout, re.MULTILINE):
                    evidence["filevault"] = "On"
                elif re.search(r"^FileVault is Off\.", status.stdout, re.MULTILINE):
                    evidence["filevault"] = "Off"
        except (DeployError, OSError):
            pass
        try:
            fd = os.open(LOGINWINDOW_PLIST, os.O_RDONLY | os.O_NOFOLLOW)
            try:
                info = os.fstat(fd)
                if not stat.S_ISREG(info.st_mode) or info.st_size > 1024 * 1024:
                    raise ValueError("invalid preference file")
                with os.fdopen(fd, "rb", closefd=False) as stream:
                    raw = stream.read(1024 * 1024 + 1)
                if len(raw) > 1024 * 1024:
                    raise ValueError("preference file grew")
                settings = plistlib.loads(raw)
                if not isinstance(settings, dict):
                    raise ValueError("invalid preference dictionary")
                account = settings.get("autoLoginUser")
                if account is None or account == "":
                    evidence.update(automatic_login="NotConfigured", desktop_account_matches=False)
                elif isinstance(account, str):
                    evidence.update(automatic_login="Configured", desktop_account_matches=account == target["user"])
                # Only the boolean match leaves this function, never the name or
                # unrelated preference values. /etc/kcpassword is never read.
            finally:
                os.close(fd)
        except FileNotFoundError:
            evidence.update(automatic_login="NotConfigured", desktop_account_matches=False)
        except (OSError, ValueError, plistlib.InvalidFileException):
            pass
    if requested == "unattended-reboot":
        messages = {
            "startup.filevault_on": ("FileVault requires sign-in after startup; unattended recovery is blocked. Use AfterSignIn on this Mac.", "FileVault требует входа после запуска; автономное восстановление заблокировано. Используйте AfterSignIn на этом Mac."),
            "startup.filevault_unverified": ("FileVault status could not be verified; unattended startup is unverified. Review access to the read-only status command.", "Не удалось проверить FileVault; автономный запуск не подтверждён. Проверьте доступ к команде чтения статуса."),
            "startup.automatic_login_missing": ("Automatic login is not configured; unattended startup is blocked. Ask the authorized administrator to review the login arrangement.", "Автоматический вход не настроен; автономный запуск заблокирован. Обратитесь к уполномоченному администратору для проверки способа входа."),
            "startup.automatic_login_other_account": ("Automatic login selects a different account; the intended desktop session is unavailable at boot. Review the authorized login arrangement.", "Автоматический вход настроен для другой учётной записи; нужная сессия не откроется при загрузке. Проверьте разрешённый способ входа."),
            "startup.automatic_login_unverified": ("Automatic-login configuration could not be read; unattended startup is unverified. Review the setting through authorized system controls.", "Не удалось прочитать настройку автоматического входа; автономный запуск не подтверждён. Проверьте настройку через разрешённые системные средства."),
            "startup.boot_unverified": ("No matching post-reboot or cold-start evidence is recorded; unattended recovery remains unverified. Perform a separately authorized startup acceptance test.", "Нет соответствующих свидетельств после перезагрузки или холодного запуска; автономное восстановление не подтверждено. Выполните отдельно разрешённую проверку запуска.")}
        ids = []
        if evidence["filevault"] == "On": ids.append("startup.filevault_on")
        elif evidence["filevault"] == "Unverified": ids.append("startup.filevault_unverified")
        if evidence["automatic_login"] == "NotConfigured": ids.append("startup.automatic_login_missing")
        elif evidence["automatic_login"] == "Unverified": ids.append("startup.automatic_login_unverified")
        elif not evidence["desktop_account_matches"]: ids.append("startup.automatic_login_other_account")
        ids.append("startup.boot_unverified")
        evidence["blockers"] = [{"id": identifier, "message": messages[identifier][1 if options.get("language") == "ru" else 0]} for identifier in ids]
    return {"startup": "BlockedUnattendedRebootUnverified" if requested == "unattended-reboot" else "StartupUnverified",
            "startup_evidence": evidence}


def finder_update_destination(target):
    """A Finder-owned app may be updated in macOS's standard admin folder.

    This does not grant machine installation or elevation. Require the stock
    root:admin directory, an existing protected app owned by this user, and
    actual write access. Never permit a fresh install through this exception.
    """
    path = target['path']
    if path.parent != Path('/Applications') or path != path.resolve() or not path.is_dir():
        return False
    parent, app = path.parent.stat(), path.stat()
    return (parent.st_uid == 0 and parent.st_gid == 80
            and stat.S_IMODE(parent.st_mode) in (0o755, 0o775)
            and app.st_uid == target['uid'] and not app.st_mode & 0o022
            and os.access(path.parent, os.W_OK) and os.access(path, os.W_OK))


def assert_no_other_users(target):
    paths = {str(target['path'] / relative) for relative in (
        'Contents/MacOS/watchtower', 'Contents/Resources/warden/cilex-warden')}
    if any(row['uid'] != target['uid'] and row['path'] in paths for row in process_snapshot()):
        fail('update.other_user', 'Another Mac account is using this Watchtower copy. Ask them to quit Watchtower and stop their Warden before updating; their service was not changed.')


def assert_authorized(target, options):
    # Until a signed, immutable Authorization Services helper exists, elevation is
    # deliberately unavailable. Never execute this Python module through sudo.
    if options.get("scope") == "machine" or os.geteuid() == 0 or os.geteuid() != target["uid"]:
        fail("authorization.helper", "Alternate-administrator installation needs a protected native authorization helper, which is not implemented; run per-user installation as the desktop account.")
    if options.get('_finder_update'):
        app = target['path'].stat()
        if app.st_uid != target['uid'] or app.st_mode & 0o022:
            fail('authorization.update_owner', 'This app must be owned by your Mac account to use Update. Ask its administrator to replace it; no service was changed.')
    parent = target["path"].parent
    while not parent.exists() and parent != parent.parent:
        parent = parent.parent
    finder_update = options.get('_finder_update') and finder_update_destination(target)
    if not finder_update and (parent.stat().st_uid != target["uid"] or parent.stat().st_mode & 0o022):
        fail("authorization.destination", "Destination must be owned by the desktop account and protected from other accounts; shared or machine installation requires the protected authorization helper.")
    if not os.access(parent, os.W_OK):
        fail("authorization.destination", "Destination is not writable; use per-user scope or an authorized protected installer.")
    if options.get('_finder_update'):
        assert_no_other_users(target)
    if options.get("startup", "after-sign-in") not in ("after-sign-in", "unattended-reboot"):
        fail("startup.mode", "Unknown startup mode.")


class _DarwinStatFS(ctypes.Structure):
    # Darwin sys/mount.h __DARWIN_STRUCT_STATFS64, including reserved tail.
    _fields_ = [("block_size", ctypes.c_uint32), ("io_size", ctypes.c_int32),
                ("blocks", ctypes.c_uint64), ("blocks_free", ctypes.c_uint64),
                ("blocks_available", ctypes.c_uint64), ("files", ctypes.c_uint64),
                ("files_free", ctypes.c_uint64), ("filesystem_id", ctypes.c_int32 * 2),
                ("owner", ctypes.c_uint32), ("type", ctypes.c_uint32),
                ("flags", ctypes.c_uint32), ("subtype", ctypes.c_uint32),
                ("name", ctypes.c_char * 16), ("mount_point", ctypes.c_char * 1024),
                ("source", ctypes.c_char * 1024), ("extended_flags", ctypes.c_uint32),
                ("reserved", ctypes.c_uint32 * 7)]


def inspect_filesystem(path):
    """Read-only native filesystem capabilities; never infer from pathname."""
    if platform.system() != "Darwin":
        fail("filesystem.platform", "Native macOS filesystem assessment is required.")
    path = Path(path)
    while not path.exists() and path != path.parent:
        path = path.parent
    libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    function = getattr(libc, "statfs64")
    function.argtypes = [ctypes.c_char_p, ctypes.POINTER(_DarwinStatFS)]
    function.restype = ctypes.c_int
    value = _DarwinStatFS()
    if function(os.fsencode(path), ctypes.byref(value)) != 0:
        fail("filesystem.inspect", "Filesystem capabilities could not be inspected; select a local supported volume.")
    return {"type": value.name.decode("ascii"), "local": bool(value.flags & 0x1000),
            "read_only": bool(value.flags & 1), "no_exec": bool(value.flags & 4),
            "ownership_ignored": bool(value.flags & 0x200000), "journaled": bool(value.flags & 0x800000),
            "available_bytes": value.block_size * value.blocks_available,
            "mount_point": os.fsdecode(value.mount_point)}


def require_filesystem(path):
    evidence = inspect_filesystem(path)
    if evidence["type"] not in ("apfs", "hfs") or not evidence["local"]:
        fail("filesystem.unsupported", "Installation requires a local APFS or journaled HFS+ volume; select a supported destination.")
    if evidence["read_only"] or evidence["no_exec"] or evidence["ownership_ignored"] or (evidence["type"] == "hfs" and not evidence["journaled"]):
        fail("filesystem.permissions", "Volume execution, write, ownership or journaling requirements are unavailable; select a correctly configured local volume.")
    return evidence


def validate_existing(target, manifest):
    path = target["path"]
    if path.exists():
        try:
            with (path / "Contents/Info.plist").open("rb") as stream:
                info = plistlib.load(stream)
            if info.get("CFBundleIdentifier") != BUNDLE_ID:
                raise ValueError()
        except (OSError, ValueError, plistlib.InvalidFileException):
            fail("installation.ownership", "Destination is not an identified Watchtower bundle; choose another path.")
    agent = target["agent"]
    if agent.is_symlink():
        fail("startup.ownership", "LaunchAgent path is a symbolic link; inspect it before deployment.")
    if agent.exists():
        agent_info = agent.stat()
        if agent_info.st_uid != target["uid"] or agent_info.st_mode & 0o022 or agent_info.st_nlink != 1 or agent_info.st_size > 1024 * 1024:
            fail("startup.ownership", "Existing LaunchAgent is not a bounded, protected file owned by the desktop account; inspect it before deployment.")
        with agent.open("rb") as stream:
            old = plistlib.load(stream)
        args = old.get("ProgramArguments")
        if not isinstance(args, list) or not all(isinstance(value, str) and "\x00" not in value for value in args):
            fail("startup.ownership", "Existing LaunchAgent arguments are invalid; inspect the selected job before deployment.")
        warden = str(path / Path(manifest["warden"]).relative_to(manifest["app"]))
        if args[:2] == ["/usr/bin/env", "-i"]:
            environment = {}
            for assignment in args[2:-2]:
                key, equals, value = assignment.partition("=")
                if not equals or not re.fullmatch(r"[A-Z][A-Z0-9_]*", key) or key in environment:
                    fail("startup.ownership", "Existing environment launcher is not the exact owned form; inspect the selected job.")
                environment[key] = value
            expected = launchagent(target, manifest, {"backend_url": environment.get("WT_WARDEN_BACKEND_URL")})
            valid = args == expected["ProgramArguments"] and set(old) == set(expected)
        elif args == [warden, "run"]:
            # Upgrade only the exact previous direct-execution format. Do not
            # mistake an arbitrary script, extra Warden option or injected env
            # value for an installation-owned job.
            environment = old.get("EnvironmentVariables")
            if not isinstance(environment, dict):
                fail("startup.ownership", "Legacy LaunchAgent environment is invalid; inspect the selected job.")
            if not all(isinstance(key, str) and isinstance(value, str) for key, value in environment.items()):
                fail("startup.ownership", "Legacy LaunchAgent environment values are invalid; inspect the selected job.")
            expected = launchagent(target, manifest, {"backend_url": environment.get("WT_WARDEN_BACKEND_URL")})
            expected_environment = dict(value.split("=", 1) for value in expected["ProgramArguments"][2:-2])
            valid = environment == expected_environment and set(old) == set(expected) | {"EnvironmentVariables"}
        else:
            fail("startup.ownership", "Existing LaunchAgent does not invoke this installation's Warden through an owned launcher.")
        required_fields = ("Label", "WorkingDirectory", "StandardOutPath", "StandardErrorPath", "RunAtLoad", "KeepAlive", "ThrottleInterval", "ExitTimeOut", "AbandonProcessGroup", "LimitLoadToSessionType", "ProcessType", "Umask")
        if not valid or "Program" in old or any(old.get(key) != expected[key] for key in required_fields):
            fail("startup.ownership", "Existing LaunchAgent is not owned by this installation; inspect it before deployment.")


def verify_app_inventory(app, manifest):
    entries = []
    for entry in manifest["files"]:
        if entry["path"].startswith(manifest["app"] + "/"):
            copied = dict(entry)
            copied["path"] = entry["path"][len(manifest["app"]) + 1:]
            entries.append(copied)
    verify_inventory(app, {"files": entries})


def app_fingerprint(path):
    if not Path(path).exists():
        return None
    from closure import inventory, ClosureError
    try:
        return digest(inventory(path))
    except (OSError, ValueError, ClosureError):
        fail("resume.bundle_integrity", "Application snapshot contains invalid or unreadable files; preserve it for inspection.")


def requested_transaction(options):
    value = {"scope": options.get("scope", "user"), "startup": options.get("startup", "after-sign-in"),
            "backend_url": options.get("backend_url"), "allow_development": bool(options.get("allow_development")),
            "observe_seconds": options.get("observe_seconds", 0), "expected_cameras": options.get("expected_cameras")}
    if options.get('_finder_update'):
        value['finder_update'] = True
    return value


def pending_startup(before, had_agent):
    if before["disabled"]:
        return "PendingDisabledStartup"
    if not before["gui_session"]:
        return "PendingGraphicalLogin"
    if had_agent and not before["loaded"]:
        return "PendingStoppedStartup"
    return None


def require_recovery_space(target, staging, state):
    """Reserve all atomic restore writes, including separate destination volumes."""
    groups = {}

    def reserve(path, size=0):
        path = Path(path)
        while not path.exists() and path != path.parent:
            path = path.parent
        device = path.stat().st_dev
        item = groups.setdefault(device, {"path": str(path), "required_bytes": 64 * 1024**2})
        item["required_bytes"] += size

    reserve(target["path"].parent)
    reserve(target["support"])
    for path, item, raw in configuration_backups(target, staging, state["configuration"]):
        reserve(path.parent, len(raw) if raw is not None else 0)
    for name, path in (("previous-agent.plist", target["agent"]), ("previous-receipt.json", target["support"] / "receipt.json")):
        reserve(path.parent, (staging / name).stat().st_size if name in state.get("rollback_files", {}) else 0)
    for item in groups.values():
        item["available_bytes"] = shutil.disk_usage(item["path"]).free
        if item["available_bytes"] < item["required_bytes"]:
            fail("space.recovery", "Insufficient space for configuration restoration and the recovery reserve; free storage and resume the same run.")
    return list(groups.values())


def requested_observation(target, manifest, options, context, staging, state, record_path, result):
    if not options.get("observe_seconds"):
        return
    import runtime
    state["phase"] = "observing"
    atomic_json(record_path, state)
    evidence = staging / "runtime"
    protected_directory(evidence)
    observation = runtime.verify(dict(options, mode="install"), {"target": target, "manifest": manifest,
        "write_evidence": True, "evidence_dir": str(evidence), "run_id": context["run_id"]})
    state["runtime_observation"] = observation
    result["runtime_observation"] = observation
    for key in ("runtime_health", "gui_video", "gui_visibility", "playback_export"):
        if key in observation:
            result[key] = observation[key]
    result["evidence"].extend(observation.get("evidence", []))
    # Persist failure evidence before any rollback. A successful retry cannot
    # erase an unexplained failed observation from the interrupted attempt.
    atomic_json(record_path, state)
    if observation.get("runtime_health") != "ProcessVerified" or observation.get("gui_video") != "VisibleAndPerSourceVideoObserved":
        fail("runtime.observation", "The explicitly requested video interval was not verified; restore the prior installation and inspect retained runtime evidence.")


def installation_receipt(target, manifest, options, context):
    return {"schema_version": SCHEMA, "installation_id": target["id"], "uid": target["uid"],
            "install_dir": str(target["path"]), "run_id": context["run_id"], "manifest": manifest,
            "package_sha256": context.get("package_sha256"), "startup": options.get("startup", "after-sign-in")}


def resume_unknown(target, record_path, reason, state):
    result = base_result(target)
    result.update(installation="Unknown", rollback="Unknown", cleanup="FailureEvidenceRetained",
                  finding="resume.outcome_unknown", reason=reason, interrupted_phase=state.get("phase"))
    result["evidence"].append(str(record_path))
    # Keep the original phase and failure intact; do not turn unknown evidence
    # into a resumable "staged" record or overwrite the original result.
    return result


def reject_other_incomplete_transactions(target, run_id):
    """A new run ID is not permission to bypass this installation's unknown state."""
    paths = sorted(target["support"].glob("*.json"))
    if len(paths) > 1000:
        fail("run.history_limit", "This installation has too many retained transaction records; archive reviewed completed evidence before starting another run.")
    for path in paths:
        if path.name in ("receipt.json", "uninstall-result.json") or path.stem == run_id:
            continue
        record = checked_private_file(path)
        try:
            state = json.loads(record.read_text(encoding="utf-8"))
        except (ValueError, OSError):
            fail("run.history_integrity", "A retained transaction record is unreadable; inspect it before changing this installation.")
        if not isinstance(state, dict) or state.get("schema_version") != SCHEMA or state.get("run_id") != path.stem:
            fail("run.history_integrity", "A retained transaction record has an invalid identity; inspect it before changing this installation.")
        if state.get("installation_id") != target["id"] or state.get("target_uid") != target["uid"] or state.get("install_dir") != str(target["path"]):
            fail("run.history_binding", "A transaction record in this installation's state directory belongs to another target; inspect it without replacing the current application.")
        if state.get("phase") not in ("installed", "rolled_back_runtime_unverified", "uninstalled"):
            fail("run.previous_incomplete", "An earlier transaction for this installation is incomplete or unknown (" + path.stem + "); resume that original run and reconcile it before starting another installation.")


def reconcile_transaction(target, manifest, options, context, record_path):
    """Under installation_lock: observe, finish proven state, or restore backup.

    Returning None permits replay only when the durable phase proves that no stop
    or replacement was attempted. All other paths return an observed outcome.
    """
    record_path = checked_private_file(record_path)
    state = json.loads(record_path.read_text(encoding="utf-8"))
    required = {"schema_version": SCHEMA, "run_id": context["run_id"], "installation_id": target["id"],
                "target_uid": target["uid"], "install_dir": str(target["path"]),
                "package_sha256": context.get("package_sha256"), "options_sha256": digest(requested_transaction(options))}
    if any(state.get(key) != value for key, value in required.items()):
        fail("resume.binding", "Transaction belongs to another run, package, target or requested configuration; do not resume it.")
    if state.get("phase") not in ("staged", "stopping", "replaced", "observing", "installed", "rollback_requested", "resume_rollback_requested", "rolled_back_runtime_unverified", "rollback_failed"):
        fail("resume.phase", "Transaction phase is unsupported; preserve the original record for inspection.")
    expected_new = app_fingerprint(Path(context["package_root"]) / manifest["app"])
    if state.get("replacement_app_sha256") != expected_new:
        fail("resume.package", "Replacement package differs from this transaction's frozen inventory.")
    current_hash = app_fingerprint(target["path"])
    previous_hash = state.get("previous_app_sha256")
    if current_hash not in (None, previous_hash, expected_new):
        return resume_unknown(target, record_path, "Installed files changed outside this transaction; no process or file was changed.", state)
    before = state.get("before", {})
    if not all(isinstance(before.get(key), bool) for key in ("loaded", "disabled", "disabled_explicit", "gui_session")):
        fail("resume.startup_record", "Recorded prior startup state is incomplete; do not guess at recovery.")
    if before["loaded"] and not before.get("pid"):
        return resume_unknown(target, record_path, "The original startup job was loaded without a Warden process; automatic recovery cannot safely distinguish intentional maintenance from startup failure.", state)
    current_job = job_state(target)
    if (current_job["disabled"], current_job["disabled_explicit"]) != (before["disabled"], before["disabled_explicit"]):
        return resume_unknown(target, record_path, "Startup enabled/disabled state changed since interruption; preserve the operator's current choice.", state)
    expected_agent_hash = hashlib.sha256(plistlib.dumps(launchagent(target, manifest, options))).hexdigest()
    agent_hash = sha256(target["agent"]) if target["agent"].is_file() and not target["agent"].is_symlink() else None
    previous_agent_hash = state.get("rollback_files", {}).get("previous-agent.plist")
    if agent_hash not in (None, previous_agent_hash, expected_agent_hash):
        return resume_unknown(target, record_path, "LaunchAgent configuration changed outside this transaction; no job was stopped.", state)
    if target["agent"].is_symlink() or (current_job["loaded"] and agent_hash is None):
        fail("resume.startup_ownership", "Loaded startup ownership cannot be established; do not modify this job.")
    if current_job["loaded"]:
        assert_job_process(target, manifest, current_job)
    receipt_path = target["support"] / "receipt.json"
    if receipt_path.exists() or receipt_path.is_symlink():
        checked_private_file(receipt_path)
        previous_receipt_hash = state.get("rollback_files", {}).get("previous-receipt.json")
        if sha256(receipt_path) != previous_receipt_hash:
            observed_receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            expected_receipt = installation_receipt(target, manifest, options, context)
            if observed_receipt != expected_receipt:
                return resume_unknown(target, record_path, "Another transaction changed the installation receipt; no stale resume action was applied.", state)
    # A completed install is verified again, never restarted just for --resume.
    if state.get("phase") == "installed":
        receipt_path = target["support"] / "receipt.json"
        if current_hash != expected_new or not receipt_path.is_file():
            return resume_unknown(target, record_path, "Completed installation no longer matches its recorded package or receipt.", state)
        receipt = json.loads(checked_private_file(receipt_path).read_text(encoding="utf-8"))
        if any(receipt.get(key) != value for key, value in installation_receipt(target, manifest, options, context).items() if key != "manifest"):
            fail("resume.receipt", "Installed receipt belongs to another transaction.")
        evidence = verify_processes(target, manifest)
        result = dict(state["result"])
        result.update(runtime_health=evidence["state"], process_evidence=evidence, resumed="ObservedCompletedInstallation", full_success=False)
        return result
    staging = Path(state.get("staging", ""))
    if not staging.is_absolute() or staging.parent != target["path"].parent or not staging.name.startswith(".cilex-deploy-") or staging.is_symlink() or not staging.is_dir():
        fail("resume.staging", "Recorded rollback staging is not an owned adjacent directory.")
    info = staging.stat()
    if info.st_uid != target["uid"] or info.st_mode & 0o077:
        fail("resume.staging_permissions", "Rollback staging is not protected for the intended account.")
    configuration_backups(target, staging, state.get("configuration"))
    rollback_bytes = {}
    for name, expected in state.get("rollback_files", {}).items():
        if name not in ("previous-agent.plist", "previous-receipt.json"):
            fail("resume.backup_name", "Unexpected rollback file name in the transaction record.")
        backup = checked_private_file(staging / name)
        if sha256(backup) != expected:
            fail("resume.backup_hash", "Rollback file failed its recorded hash; preserve the interrupted transaction.")
        rollback_bytes[name] = backup.read_bytes()
    backup_app, staged_app = staging / "previous.app", staging / "replacement.app"
    if backup_app.exists() and app_fingerprint(backup_app) != previous_hash:
        fail("resume.backup_hash", "Previous application backup failed its recorded inventory hash.")
    if staged_app.exists() and app_fingerprint(staged_app) != expected_new:
        fail("resume.staged_hash", "Staged application changed since verification; preserve the interrupted transaction.")
    prior_manifest = state.get("previous_manifest", manifest)
    if state.get("phase") in ("rolled_back_runtime_unverified", "rollback_failed") and current_hash == previous_hash and agent_hash == previous_agent_hash:
        if state.get("phase") == "rolled_back_runtime_unverified":
            result = dict(state["result"])
            result["resumed"] = "ObservedPreviousRollback"
            result["rollback_process_evidence"] = verify_processes(target, prior_manifest) if state.get("previous_application") else {"state": "NotPreviouslyInstalled", "processes": []}
            return result
    if state.get("phase") == "staged":
        if current_hash != previous_hash or agent_hash != previous_agent_hash or current_job["loaded"] != before["loaded"]:
            return resume_unknown(target, record_path, "Pre-replacement state changed; a staged transaction cannot safely be replayed.", state)
        require_recovery_space(target, staging, state)
        archive = staging / "interrupted-before-stop.json"
        if archive.exists():
            fail("resume.record_collision", "An earlier reconciliation record already exists; inspect this run before continuing.")
        os.rename(record_path, archive)
        context.setdefault("resumed_evidence", []).append(str(archive))
        return None
    # If replacement and its exact startup job were fully created and are still
    # healthy (or intentionally pending login/disabled), finish the missing receipt.
    process_evidence = verify_processes(target, manifest) if current_hash == expected_new else None
    intended_pending = pending_startup(before, state.get("previous_agent", bool(previous_agent_hash)))
    pending = not current_job["gui_session"] or current_job["disabled"] or intended_pending == "PendingStoppedStartup"
    can_finish = current_hash == expected_new and agent_hash == expected_agent_hash and not state.get("original_failure") and (
        (current_job["loaded"] and process_evidence["state"] == "ProcessVerified") or (pending and not current_job["loaded"]))
    if can_finish:
        require_recovery_space(target, staging, state)
        result = base_result(target)
        result.update(installation="Installed", security_admission=context["security_admission"],
                      runtime_health=intended_pending or ("PendingGraphicalLogin" if not current_job["gui_session"] else "ProcessVerified"),
                      startup=intended_pending or "StartupUnverified",
                      cleanup="RollbackBackupRetained", resumed="FinishedObservedReplacement",
                      interrupted_phase=state.get("phase"), process_evidence=process_evidence)
        if options.get("startup") == "unattended-reboot":
            result["startup"] = "BlockedUnattendedRebootUnverified"
        try:
            preserve_registered_default(state, result)
            requested_observation(target, manifest, options, context, staging, state, record_path, result)
        except BaseException as error:
            state.update(original_failure={"finding": getattr(error, "finding", "runtime.observation_interrupted"), "message": str(error)}, phase="rollback_requested")
            atomic_json(record_path, state)
        else:
            atomic_json(target["support"] / "receipt.json", installation_receipt(target, manifest, options, context))
            result["evidence"].append(str(record_path))
            state.update(phase="installed", result=result, resumed_at=time.time())
            atomic_json(record_path, state)
            return result
    if state.get("previous_application") and current_hash != previous_hash and not backup_app.exists():
        return resume_unknown(target, record_path, "Previous application backup is missing; recovery cannot be proven.", state)
    if not state.get("previous_application") and previous_hash is not None:
        fail("resume.previous_state", "Previous application existence and inventory disagree.")
    if current_hash is None and current_job["loaded"]:
        return resume_unknown(target, record_path, "A startup job is loaded while the application path is absent; inspect process ownership before recovery.", state)
    if state.get("previous_application") and not isinstance(prior_manifest.get("_executable"), str):
        fail("resume.previous_manifest", "Previous executable identity is missing; do not guess at process recovery.")
    result = base_result(target)
    if "runtime_observation" in state:
        result["runtime_observation"] = state["runtime_observation"]
        result["evidence"].extend(state["runtime_observation"].get("evidence", []))
    original = state.get("original_failure") or {"finding": "installation.interrupted", "message": "Transaction interrupted in phase " + str(state.get("phase"))}
    result.update(installation="Failed", original_failure=original, cleanup="FailureEvidenceRetained", resumed="RestorePreviousState")
    require_recovery_space(target, staging, state)
    state.update(original_failure=original, phase="resume_rollback_requested")
    atomic_json(record_path, state)
    try:
        if current_job["loaded"]:
            validate_existing(target, manifest)
            assert_job_process(target, manifest, current_job)
            execute(["/bin/launchctl", "bootout", target["domain"] + "/" + target["label"]])
            wait_processes(target, manifest, False)
            if prior_manifest.get("_executable") != manifest.get("_executable"):
                wait_processes(target, prior_manifest, False)
        elif selected_processes(target, manifest) or selected_processes(target, prior_manifest):
            return resume_unknown(target, record_path, "Unmanaged selected processes exist; automatic recovery will not signal them.", state)
        if current_hash == expected_new and current_hash != previous_hash:
            os.rename(target["path"], staging / ("interrupted-replacement-" + uuid.uuid4().hex + ".app"))
        if state.get("previous_application") and not target["path"].exists():
            os.rename(backup_app, target["path"])
            register_bundle(target["path"])
        for name, destination in (("previous-agent.plist", target["agent"]), ("previous-receipt.json", target["support"] / "receipt.json")):
            if name in rollback_bytes:
                destination.parent.mkdir(parents=True, exist_ok=True)
                atomic_bytes(destination, rollback_bytes[name], (state.get("agent_mode") or 0o600) if name == "previous-agent.plist" else 0o600)
            else:
                destination.unlink(missing_ok=True)
        restore_configuration(target, staging, state["configuration"])
        if before["loaded"]:
            execute(["/bin/launchctl", "bootstrap", target["domain"], str(target["agent"])])
            if state.get("previous_processes"):
                result["rollback_process_evidence"] = wait_processes(target, prior_manifest, True)
        after = job_state(target)
        if app_fingerprint(target["path"]) != previous_hash or (after["loaded"], after["disabled"], after["disabled_explicit"]) != (before["loaded"], before["disabled"], before["disabled_explicit"]):
            fail("resume.recovery_verification", "Restored files or actual startup state do not match the recorded prior installation.")
        actual_agent_hash = sha256(target["agent"]) if target["agent"].is_file() else None
        if actual_agent_hash != previous_agent_hash:
            fail("resume.recovery_verification", "Restored LaunchAgent bytes do not match the prior startup configuration.")
        record_rollback_registration(state, result)
        result["rollback"] = "FilesAndProcessStateRestored_RuntimeUnverified"
        state["phase"] = "rolled_back_runtime_unverified"
    except BaseException as error:
        result["rollback"] = "Failed"
        result["rollback_failure"] = {"finding": getattr(error, "finding", "rollback.error"), "message": str(error)}
        state["phase"] = "rollback_failed"
    result["evidence"].append(str(record_path))
    state["result"] = result
    atomic_json(record_path, state)
    return result


def transaction(package_root, manifest, target, options, context):
    result = base_result(target)
    result["security_admission"] = context["security_admission"]
    assert_authorized(target, options)
    result["filesystem"] = require_filesystem(target["path"].parent)
    target["path"].parent.mkdir(parents=True, exist_ok=True)
    with installation_lock(target):
        protected_directory(target["support"])
        run_id = context.get("run_id") or str(uuid.uuid4())
        context.update(run_id=run_id, package_root=str(package_root))
        if not re.fullmatch(r"[A-Za-z0-9_-]{8,80}", run_id):
            fail("run.identity", "Run ID is invalid.")
        record_path = target["support"] / (run_id + ".json")
        reject_other_incomplete_transactions(target, run_id)
        if record_path.exists():
            if not options.get("resume"):
                fail("run.resume", "This run already has a transaction record; use the same authenticated --resume run before starting another transaction.")
            reconciled = reconcile_transaction(target, manifest, options, context, record_path)
            if reconciled is not None:
                return reconciled
        validate_existing(target, manifest)
        before = job_state(target)
        had_agent = target["agent"].exists()
        if had_agent and before["loaded"] and not before.get("pid"):
            fail("startup.loaded_stopped", "The existing LaunchAgent is loaded without a Warden process; replacement could restart an intentional stop. Inspect launchd and maintenance state before retrying; this job was not changed.")
        pending = pending_startup(before, had_agent)
        if pending == "PendingStoppedStartup" and options.get("observe_seconds"):
            fail("startup.stopped", "The selected startup job is intentionally unloaded; video observation cannot authorize starting it. Preserve the stopped state and request a separate explicit start action.")
        if before["loaded"]:
            assert_job_process(target, manifest, before)
        prior_manifest = dict(manifest)
        if target["path"].exists():
            with (target["path"] / "Contents/Info.plist").open("rb") as stream:
                prior_info = plistlib.load(stream)
            prior_executable = prior_info.get("CFBundleExecutable", manifest["_executable"])
            if not isinstance(prior_executable, str) or not prior_executable or "/" in prior_executable or prior_executable in (".", ".."):
                fail("installation.previous_executable", "Previous executable identity is invalid; inspect it before replacing the application.")
            prior_manifest["_executable"] = prior_executable
        old_processes = selected_processes(target, prior_manifest)
        if old_processes and not before["loaded"]:
            fail("runtime.unmanaged", "Watchtower is running outside this installation's LaunchAgent; close that instance intentionally before installing.")
        if before["loaded"] and not target["agent"].exists():
            fail("startup.ownership", "Loaded startup job has no owned plist; inspect it before deployment.")
        incoming_size = sum(path.stat().st_size for path in Path(package_root).rglob("*") if path.is_file() and not path.is_symlink())
        if shutil.disk_usage(target["path"].parent).free < incoming_size * 2 + 512 * 1024**2:
            fail("space.transaction", "Insufficient space for staging and rollback; free storage and retry.")
        registration_before = registration_snapshot()
        if registration_before["state"] == "Unverified":
            fail("bundle.registration_snapshot", "Existing cilex URL handler could not be inspected; no application replacement was attempted.")
        staging = Path(tempfile.mkdtemp(prefix=".cilex-deploy-", dir=target["path"].parent))
        backup_app, staged_app = staging / "previous.app", staging / "replacement.app"
        shutil.copytree(Path(package_root) / manifest["app"], staged_app, symlinks=True)
        verify_app_inventory(staged_app, manifest)
        quarantine = read_quarantine(Path(package_root) / manifest["app"])
        if quarantine:
            write_quarantine(staged_app, quarantine)
        agent_bytes = target["agent"].read_bytes() if target["agent"].exists() else None
        receipt_path = target["support"] / "receipt.json"
        if receipt_path.exists() or receipt_path.is_symlink():
            read_owned_receipt(target, receipt_path)
            old_receipt = receipt_path.read_bytes()
        else:
            old_receipt = None
        # Durable rollback inputs must survive SIGKILL, disconnect and power loss;
        # keeping only bytes in this process would not make a resumable transaction.
        backup_records = {}
        for name, content in (("previous-agent.plist", agent_bytes), ("previous-receipt.json", old_receipt)):
            if content is not None:
                backup = staging / name
                atomic_bytes(backup, content)
                backup_records[name] = sha256(backup)
        configuration = snapshot_configuration(target, staging)
        configuration_backups(target, staging, configuration)
        state = {"schema_version": SCHEMA, "run_id": run_id, "installation_id": target["id"],
                 "target_uid": target["uid"], "install_dir": str(target["path"]), "package_sha256": context.get("package_sha256"),
                 "phase": "staged", "before": before, "staging": str(staging), "created_at": time.time(),
                 "previous_processes": old_processes, "rollback_files": backup_records,
                 "configuration": configuration,
                 "previous_application": target["path"].exists(),
                 "previous_agent": had_agent,
                 "registration_before": registration_before,
                 "previous_app_sha256": app_fingerprint(target["path"]),
                 "replacement_app_sha256": app_fingerprint(staged_app),
                 "previous_manifest": prior_manifest,
                 "options_sha256": digest(requested_transaction(options)),
                 "filesystem": result["filesystem"],
                 "resumed_evidence": context.get("resumed_evidence", []),
                 "agent_mode": stat.S_IMODE(target["agent"].stat().st_mode) if target["agent"].exists() else None}
        state["recovery_space"] = require_recovery_space(target, staging, state)
        if options.get('_finder_update'):
            # Failure here must not enter rollback and stop an unchanged job.
            assert_authorized(target, options)
        atomic_json(record_path, state)
        replaced = False
        try:
            state["phase"] = "stopping"
            atomic_json(record_path, state)
            if before["loaded"]:
                execute(["/bin/launchctl", "bootout", target["domain"] + "/" + target["label"]])
                wait_processes(target, prior_manifest, False)
            if target["path"].exists():
                os.rename(target["path"], backup_app)
            os.rename(staged_app, target["path"])
            replaced = True
            state["phase"] = "replaced"
            atomic_json(record_path, state)
            target["agent"].parent.mkdir(parents=True, exist_ok=True)
            for directory in (target["home"] / "Library/Logs/CilexWatchtower" / target["id"],
                              target["home"] / "Library/Application Support/CilexWatchtower/Warden" / target["id"],
                              target["home"] / "Library/Caches/CilexWatchtower" / target["id"]):
                protected_directory(directory)
            atomic_bytes(target["agent"], plistlib.dumps(launchagent(target, manifest, options)))
            register_bundle(target["path"])
            preserve_registered_default(state, result)
            if pending is None:
                execute(["/bin/launchctl", "bootstrap", target["domain"], str(target["agent"])])
                evidence = wait_processes(target, manifest, True)
                result["runtime_health"] = evidence["state"]
                result["process_evidence"] = evidence
            else:
                result["runtime_health"] = pending
            requested_observation(target, manifest, options, context, staging, state, record_path, result)
            receipt = installation_receipt(target, manifest, options, context)
            atomic_json(target["support"] / "receipt.json", receipt)
            state["phase"] = "installed"
            result["installation"] = "Installed"
            result["startup"] = pending or "StartupUnverified"
            if options.get("startup") == "unattended-reboot":
                result["startup"] = "BlockedUnattendedRebootUnverified"
            result["cleanup"] = "RollbackBackupRetained" if backup_app.exists() else "EvidenceRetained"
            result["evidence"].append(str(record_path))
            result["limitations"] = ["Physical scene identity, representative playback/export, backend and recovery were not certified.",
                                     "Login, sleep/wake, switching, lock and reboot startup remain unverified."]
            state["result"] = result
            atomic_json(record_path, state)
            return result
        except BaseException as original:
            state["original_failure"] = {"finding": getattr(original, "finding", "interrupted"), "message": str(original)}
            state["phase"] = "rollback_requested"
            atomic_json(record_path, state)
            result["installation"] = "Failed"
            result["original_failure"] = state["original_failure"]
            try:
                require_recovery_space(target, staging, state)
                current = job_state(target)
                if current["loaded"]:
                    assert_job_process(target, manifest, current)
                    execute(["/bin/launchctl", "bootout", target["domain"] + "/" + target["label"]])
                    wait_processes(target, manifest, False)
                if replaced and target["path"].exists():
                    os.rename(target["path"], staging / "failed.app")
                if backup_app.exists():
                    os.rename(backup_app, target["path"])
                    register_bundle(target["path"])
                if agent_bytes is None:
                    target["agent"].unlink(missing_ok=True)
                else:
                    atomic_bytes(target["agent"], agent_bytes, state["agent_mode"])
                receipt_path = target["support"] / "receipt.json"
                if old_receipt is None:
                    receipt_path.unlink(missing_ok=True)
                else:
                    atomic_bytes(receipt_path, old_receipt)
                restore_configuration(target, staging, state["configuration"])
                if before["loaded"]:
                    execute(["/bin/launchctl", "bootstrap", target["domain"], str(target["agent"])])
                    if old_processes:
                        recovered = wait_processes(target, prior_manifest, True)
                        result["rollback_process_evidence"] = recovered
                after = job_state(target)
                if app_fingerprint(target["path"]) != state["previous_app_sha256"] or (after["loaded"], after["disabled"], after["disabled_explicit"]) != (before["loaded"], before["disabled"], before["disabled_explicit"]):
                    fail("rollback.verification", "Actual application or startup state differs after restoration; recovery is incomplete.")
                if (sha256(target["agent"]) if target["agent"].is_file() else None) != backup_records.get("previous-agent.plist"):
                    fail("rollback.verification", "Restored startup configuration differs from its snapshot; recovery is incomplete.")
                record_rollback_registration(state, result)
                result["rollback"] = "FilesAndProcessStateRestored_RuntimeUnverified"
                state["phase"] = "rolled_back_runtime_unverified"
            except BaseException as rollback_error:
                result["rollback"] = "Failed"
                result["rollback_failure"] = {"finding": getattr(rollback_error, "finding", "rollback.error"), "message": str(rollback_error)}
                state["phase"] = "rollback_failed"
            result["cleanup"] = "FailureEvidenceRetained"
            result["evidence"].append(str(record_path))
            state["result"] = result
            atomic_json(record_path, state)
            return result


def verify(options, context=None):
    """Read only: no directory creation, job changes, repair, security cache writes."""
    target = resolve_target(options)
    result = base_result(target)
    result.update(startup_assessment(target, options))
    path = target["support"] / "receipt.json"
    if not path.is_file() or path.is_symlink():
        result["installation"] = "UnverifiedNoOwnedReceipt"
        return result
    receipt = read_owned_receipt(target, path)
    manifest = receipt["manifest"]
    verify_app_inventory(target["path"], manifest)
    result["installation"] = "FilesVerified"
    evidence = verify_processes(target, manifest)
    result["runtime_health"], result["process_evidence"] = evidence["state"], evidence
    result["evidence"].append(str(path))
    result["versions"] = {"watchtower": manifest["version"], "warden": manifest["warden_version"]}
    result["startup_registration"] = job_state(target)
    return result


def read_owned_receipt(target, path=None):
    """Bound receipt parsing consistently with the runtime verifier."""
    from runtime import MAX_RECEIPT_BYTES
    path = checked_private_file(path or target["support"] / "receipt.json")
    if path.stat().st_size > MAX_RECEIPT_BYTES:
        fail("receipt.size", "Installation receipt exceeds the supported size; preserve it for inspection.")
    receipt = json.loads(path.read_text(encoding="utf-8"))
    if receipt.get("schema_version") != SCHEMA or receipt.get("installation_id") != target["id"] or receipt.get("uid") != target["uid"] or receipt.get("install_dir") != str(target["path"]):
        fail("receipt.identity", "Receipt belongs to another installation; inspect the selected destination.")
    return receipt


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def uninstall_options(options):
    return {"operation": "uninstall", "scope": options.get("scope", "user"), "preserve_user_data": True}


def continue_uninstall(target, options, context, record_path, state, resumed):
    """Reconcile observed files before continuing a bound detach transaction.

    The complete application backup is retained. This avoids an unrecoverable
    partially deleted bundle if deletion is interrupted, and never recursively
    deletes the user's selected directory. No settings or data files are removed.
    """
    expected = {"schema_version": SCHEMA, "operation": "uninstall", "run_id": context["run_id"],
                "installation_id": target["id"], "target_uid": target["uid"], "install_dir": str(target["path"]),
                "options_sha256": digest(uninstall_options(options))}
    if any(state.get(key) != value for key, value in expected.items()):
        fail("resume.binding", "Uninstall record belongs to another run, target or operation; do not reuse it.")
    if state.get("phase") not in ("uninstall_staged", "uninstall_stopping", "uninstall_detached", "uninstalled"):
        fail("resume.phase", "Uninstall phase is unsupported; preserve its record for inspection.")
    staging = Path(state.get("staging", ""))
    if not staging.is_absolute() or staging.parent != target["path"].parent or not staging.name.startswith(".cilex-uninstall-") or staging.is_symlink() or not staging.is_dir():
        fail("resume.staging", "Uninstall backup is not the recorded adjacent private directory.")
    info = staging.stat()
    if info.st_uid != target["uid"] or info.st_mode & 0o077:
        fail("resume.staging_permissions", "Uninstall backup directory is not protected for the desktop account.")
    previous_receipt = checked_private_file(staging / "previous-receipt.json")
    if sha256(previous_receipt) != state.get("receipt_sha256"):
        fail("resume.backup_hash", "Uninstall receipt backup changed; preserve the evidence before continuing.")
    receipt = read_owned_receipt(target, previous_receipt)
    manifest = receipt["manifest"]
    if receipt.get("package_sha256") != state.get("package_sha256"):
        fail("resume.binding", "Uninstall package identity differs from its protected receipt.")
    agent_backup = staging / "previous-agent.plist"
    if state.get("agent_sha256"):
        checked_private_file(agent_backup)
        if sha256(agent_backup) != state["agent_sha256"]:
            fail("resume.backup_hash", "Uninstall startup backup changed; preserve it for inspection.")
    backup = staging / "application.backup"
    if backup.is_symlink():
        fail("resume.backup_hash", "Uninstall application backup is a symbolic link; do not follow it.")
    current_hash, backup_hash = app_fingerprint(target["path"]), app_fingerprint(backup)
    expected_hash = state.get("application_sha256")
    if not expected_hash or current_hash not in (None, expected_hash) or backup_hash not in (None, expected_hash) or (current_hash is None) == (backup_hash is None):
        return resume_unknown(target, record_path, "Uninstall application or backup no longer matches the unique recorded copy; no files or processes were changed.", state)
    if backup_hash:
        verify_app_inventory(backup, manifest)
    else:
        verify_app_inventory(target["path"], manifest)
    agent_hash = None
    if target["agent"].exists() or target["agent"].is_symlink():
        if target["agent"].is_symlink():
            fail("startup.ownership", "Uninstall startup path became a symbolic link; do not modify it.")
        validate_existing(target, manifest)
        agent_hash = sha256(target["agent"])
    receipt_path = target["support"] / "receipt.json"
    receipt_hash = sha256(checked_private_file(receipt_path)) if receipt_path.exists() or receipt_path.is_symlink() else None
    if agent_hash not in (None, state.get("agent_sha256")) or receipt_hash not in (None, state["receipt_sha256"]):
        return resume_unknown(target, record_path, "Startup configuration or ownership receipt changed after uninstall began; preserve the newer state.", state)
    before = state.get("before", {})
    if not all(isinstance(before.get(key), bool) for key in ("loaded", "disabled", "disabled_explicit", "gui_session")):
        fail("resume.startup_record", "Uninstall prior startup state is incomplete; do not guess at recovery.")
    current_job = job_state(target)
    if (current_job["disabled"], current_job["disabled_explicit"]) != (before["disabled"], before["disabled_explicit"]):
        return resume_unknown(target, record_path, "Startup policy changed after uninstall began; preserve the operator's current choice.", state)
    processes = selected_processes(target, manifest)
    if processes and not current_job["loaded"]:
        return resume_unknown(target, record_path, "Unmanaged selected processes exist; uninstall will not signal them.", state)
    if current_job["loaded"] and (current_hash is None or agent_hash is None or not before["loaded"]):
        return resume_unknown(target, record_path, "Loaded startup state cannot be attributed to this uninstall; no job was stopped.", state)
    if state["phase"] == "uninstalled":
        if current_hash is not None or agent_hash is not None or receipt_hash is not None or current_job["loaded"] or processes:
            return resume_unknown(target, record_path, "Completed uninstall no longer matches observed absence; a later installation will not be removed.", state)
        result = dict(state["result"])
        if state.get("failures"):
            result["previous_failures"] = state["failures"]
        result["resumed"] = "ObservedCompletedUninstall"
        return result
    if current_hash is not None and (receipt_hash is None or (state.get("agent_sha256") and agent_hash is None)):
        return resume_unknown(target, record_path, "Application remains but its owned receipt or startup snapshot is missing; uninstall will not guess at ownership.", state)
    try:
        if current_job["loaded"]:
            assert_job_process(target, manifest, current_job)
            state["phase"] = "uninstall_stopping"
            atomic_json(record_path, state)
            execute(["/bin/launchctl", "bootout", target["domain"] + "/" + target["label"]])
            wait_processes(target, manifest, False)
        if selected_processes(target, manifest):
            fail("uninstall.processes", "Selected processes remain; uninstall did not detach their application.")
        if current_hash is not None:
            # The record predates the rename; either side is reconciled after a crash.
            state["phase"] = "uninstall_stopping"
            atomic_json(record_path, state)
            os.rename(target["path"], backup)
            sync_directory(target["path"].parent)
            sync_directory(staging)
        state["phase"] = "uninstall_detached"
        atomic_json(record_path, state)
        target["agent"].unlink(missing_ok=True)
        if target["agent"].parent.exists():
            sync_directory(target["agent"].parent)
        receipt_path.unlink(missing_ok=True)
        sync_directory(target["support"])
        after = job_state(target)
        if target["path"].exists() or target["agent"].exists() or receipt_path.exists() or after["loaded"] or selected_processes(target, manifest):
            fail("uninstall.verification", "Application, receipt or startup remains; uninstall is incomplete. Resume this run after inspecting its evidence.")
        result = base_result(target)
        result.update(installation="Uninstalled", runtime_health="NotRunning", startup="NotRegistered",
                      cleanup="OwnedComponentsDetached_BackupRetained_UserDataPreserved",
                      backup_path=str(backup), registration="RemovalUnverified",
                      limitations=["The complete owned application backup is retained for recovery; no user data was removed.",
                                   "Launch Services registration removal is unverified; no private unregister API or global settings mutation is used."])
        result["evidence"].append(str(record_path))
        if resumed:
            result["resumed"] = "FinishedObservedUninstall"
        if state.get("failures"):
            result["previous_failures"] = state["failures"]
        state.update(phase="uninstalled", completed_at=time.time(), result=result)
        atomic_json(record_path, state)
        return result
    except BaseException as error:
        failure = {"finding": getattr(error, "finding", "uninstall.interrupted"), "message": str(error), "at": time.time()}
        state.setdefault("failures", []).append(failure)
        # Retain the last durable phase; do not convert uncertainty to completion.
        atomic_json(record_path, state)
        result = resume_unknown(target, record_path, "Uninstall was interrupted; resume this same run to reconcile its protected backup and observed startup state.", state)
        result["original_failure"] = state["failures"][0]
        result["latest_failure"] = failure
        return result


def uninstall(options, context=None):
    """Durably detach only receipt-owned components; preserve data and backups."""
    context = dict(context or {})
    target = resolve_target(options)
    assert_authorized(target, options)
    if options.get("dry_run"):
        checked = verify(options)
        if checked["installation"] != "FilesVerified":
            fail("uninstall.ownership", "Uninstall needs an intact owned installation; inspect the receipt and files.")
        checked["installation"] = "UninstallPlanned"
        return checked
    context["run_id"] = context.get("run_id") or options.get("resume") or str(uuid.uuid4())
    if not re.fullmatch(r"[A-Za-z0-9_-]{8,80}", context["run_id"]):
        fail("run.identity", "Run ID is invalid.")
    with installation_lock(target):
        reject_other_incomplete_transactions(target, context["run_id"])
        record_path = target["support"] / (context["run_id"] + ".json")
        if record_path.exists() or record_path.is_symlink():
            if not options.get("resume"):
                fail("run.resume", "This uninstall already has a journal; resume the same run before another attempt.")
            state = json.loads(checked_private_file(record_path).read_text(encoding="utf-8"))
            return continue_uninstall(target, options, context, record_path, state, True)
        if options.get("resume"):
            fail("resume.missing", "The bound uninstall journal is missing; do not start a new transaction under an old run ID.")
        receipt_path = target["support"] / "receipt.json"
        receipt = read_owned_receipt(target)
        manifest = receipt["manifest"]
        verify_app_inventory(target["path"], manifest)
        validate_existing(target, manifest)
        filesystem = require_filesystem(target["path"].parent)
        before = job_state(target)
        if selected_processes(target, manifest) and not before["loaded"]:
            fail("uninstall.unmanaged", "Selected application is outside its LaunchAgent; close it intentionally before uninstalling.")
        if before["loaded"]:
            if not target["agent"].exists():
                fail("startup.ownership", "Loaded startup job has no owned plist; inspect it before uninstalling.")
            assert_job_process(target, manifest, before)
        for reserve_path in (target["path"].parent, target["support"]):
            if shutil.disk_usage(reserve_path).free < receipt_path.stat().st_size + 64 * 1024**2:
                fail("space.transaction", "Insufficient space for the uninstall journal and recovery reserve; free storage and retry.")
        staging = Path(tempfile.mkdtemp(prefix=".cilex-uninstall-", dir=target["path"].parent))
        atomic_bytes(staging / "previous-receipt.json", receipt_path.read_bytes())
        agent_hash = None
        if target["agent"].exists():
            atomic_bytes(staging / "previous-agent.plist", target["agent"].read_bytes())
            agent_hash = sha256(staging / "previous-agent.plist")
        state = {"schema_version": SCHEMA, "operation": "uninstall", "run_id": context["run_id"],
                 "installation_id": target["id"], "target_uid": target["uid"], "install_dir": str(target["path"]),
                 "options_sha256": digest(uninstall_options(options)), "package_sha256": receipt.get("package_sha256"),
                 "phase": "uninstall_staged", "before": before, "staging": str(staging), "created_at": time.time(),
                 "application_sha256": app_fingerprint(target["path"]), "agent_sha256": agent_hash,
                 "receipt_sha256": sha256(staging / "previous-receipt.json"), "filesystem": filesystem}
        atomic_json(record_path, state)
        return continue_uninstall(target, options, context, record_path, state, False)


def run(options, context=None):
    context = dict(context or {})
    if options.get("mode") == "verify":
        return verify(options, context)
    if options.get("mode") == "uninstall":
        return uninstall(options, context)
    target = resolve_target(options)
    if options.get("dry_run"):
        result = base_result(target)
        result.update(startup_assessment(target, options))
        result["installation"] = "Planned"
        result["plan"] = ["Validate trusted package, runtime closure, signature and free space.",
                          "Stage replacement, preserve selected startup state, install and observe scoped processes."]
        return result
    root = context.get("package_root")
    if not root:
        fail("package.staging", "Install requires a verified extracted package in context.package_root.")
    manifest = read_manifest(root)
    context["security_admission"] = security_check(root, manifest, options)
    startup = startup_assessment(target, options)
    result = transaction(root, manifest, target, options, context)
    result["startup_evidence"] = startup["startup_evidence"]
    if options.get("startup") == "unattended-reboot":
        result["startup"] = startup["startup"]
    return result
