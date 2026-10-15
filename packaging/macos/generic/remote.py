"""Strict SSH transfer and run-bound remote outcome reconciliation.

No remote access is enabled here. Once execution might have begun, resume is a
read-only reconciliation; an absent result never authorizes a second install.
"""
from __future__ import annotations
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import stat
import tempfile
import time

from common import DeployError, atomic_json, checked_private_file, clean_env, command, digest, host_identity, read_json, sha256
from install import safe_extract, read_manifest, read_quarantine, write_quarantine

REQUEST_KEYS = {"scope", "install_dir", "desktop_user", "startup", "backend_url", "language", "allow_development", "dependencies", "accept_findings"}
REMOTE_PHASES = {"remote-execution-requested", "remote-outcome-unknown", "remote-completed"}


def fail(finding, message, code="security"):
    raise DeployError(finding, message, code,
        ru="Удалённая операция не завершена (" + finding + "); результат не подтверждён. Проверьте доступ SSH, идентичность целевого Mac и защищённую запись запуска; не повторяйте установку вслепую.")


def safe_text(value, label):
    if not isinstance(value, str) or not value or any(c in value for c in ("\0", "\n", "\r")):
        fail("remote.input", "Missing or invalid " + label + "; provide the explicit requested value.", "usage")
    return value


def ssh_options(options):
    host = safe_text(options.get("target_host"), "--target-host")
    user = safe_text(options.get("ssh_user"), "--ssh-user")
    if host.startswith("-") or not re.fullmatch(r"[A-Za-z0-9.:%_\-\[\]]+", host):
        fail("remote.host", "Use a hostname or IP address without an SSH user, path or shell syntax.", "usage")
    desktop = safe_text(options.get("desktop_user"), "--desktop-user")
    target_id = options.get("expected_target_id")
    if not re.fullmatch(r"[0-9a-f]{64}", target_id or ""):
        fail("remote.target_identity", "Provide --expected-target-id from a trusted target-local check before deployment.", "usage")
    known = Path(options.get("ssh_known_hosts") or Path.home() / ".ssh/known_hosts").expanduser().absolute()
    safe_text(str(known), "known_hosts path")
    if not known.is_file() or known.is_symlink():
        fail("remote.host_keys", "An existing verified known_hosts file is required; verify the host key out of band first.", "authentication")
    info = known.stat()
    if info.st_uid != os.geteuid() or info.st_mode & 0o022:
        fail("remote.host_keys", "The selected known_hosts file is not protected from other accounts.", "authentication")
    port = options.get("ssh_port") or 22
    try:
        port = int(port)
    except ValueError:
        fail("remote.port", "SSH port must be a number from 1 through 65535.", "usage")
    if not 1 <= port <= 65535:
        fail("remote.port", "SSH port must be a number from 1 through 65535.", "usage")
    quoted_known = '"' + str(known).replace("\\", "\\\\").replace('"', '\\"') + '"'
    flags = ["-F", "/dev/null", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10",
             "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3", "-o", "NumberOfPasswordPrompts=0",
             "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no",
             "-o", "UserKnownHostsFile=" + quoted_known, "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes"]
    env = clean_env()
    key = options.get("ssh_identity_file")
    use_agent = options.get("ssh_agent") or options.get("ssh_use_agent")
    if key:
        key = checked_private_file(Path(key).expanduser().absolute())
        flags += ["-o", "IdentitiesOnly=yes", "-i", str(key)]
    elif not use_agent and not options.get('ssh_control_path'):
        fail("remote.authentication", "Select --ssh-identity-file or explicitly --ssh-agent; noninteractive deployment cannot prompt for SSH credentials.", "authentication")
    if use_agent:
        agent = os.environ.get("CILEX_INIT_SSH_AUTH_SOCK") or os.environ.get("SSH_AUTH_SOCK")
        if not agent or not Path(agent).exists() or not stat.S_ISSOCK(Path(agent).stat().st_mode):
            fail("remote.agent", "The explicitly selected SSH agent is unavailable; unlock an existing agent or select a private key.", "authentication")
        env["SSH_AUTH_SOCK"] = agent
    if key and not use_agent:
        flags += ["-o", "IdentityAgent=none"]
    if options.get('ssh_control_path'):
        # A password-authenticated OpenSSH master owns this private socket.
        # Never fall back to a fresh connection if that master disappears.
        control = Path(options['ssh_control_path']).absolute()
        parent = control.parent
        if (control.is_symlink() or parent.is_symlink() or not control.exists()
                or not stat.S_ISSOCK(control.stat().st_mode)
                or control.stat().st_uid != os.geteuid()
                or parent.stat().st_uid != os.geteuid() or parent.stat().st_mode & 0o077):
            fail('remote.control_socket', 'The authenticated SSH session is missing or unprotected.', 'authentication')
        flags += ['-o', 'ControlPath=' + str(control), '-o', 'ControlMaster=no',
                  '-o', 'ProxyCommand=/usr/bin/false']
    return {"host": host, "user": user, "desktop": desktop, "target_id": target_id,
            "flags": flags, "port": port, "env": env}


def ssh(remote, script, timeout=45, check=True):
    return command(["/usr/bin/ssh", *remote["flags"], "-p", str(remote["port"]), "-l", remote["user"], remote["host"], "/bin/sh -s"],
                   input=script, timeout=timeout, env=remote["env"], network=True, check=check)


PROBE = r'''set -eu
[ "$(/usr/bin/uname -s)" = Darwin ] || exit 61
uid=$(/usr/bin/id -u)
login=$(/usr/bin/id -un)
platform_uuid=$(/usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice | /usr/bin/awk -F '"' '/"IOPlatformUUID"/{print $4; exit}')
[ -n "$platform_uuid" ] || exit 62
identity=$(/usr/bin/printf 'cilex-deploy|%s' "$platform_uuid" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
/usr/bin/printf '%s\n%s\n%s\n%s\n' "$identity" "$uid" "$login" "$HOME"
'''


def probe(remote):
    reply = ssh(remote, PROBE)
    fields = reply.stdout.rstrip("\n").split("\n")
    if len(fields) != 4 or fields[0] != remote["target_id"]:
        fail("remote.identity_changed", "SSH target identity differs from the expected Mac; do not deploy to this host.")
    if not fields[1].isdigit() or int(fields[1]) == 0 or fields[2] != remote["user"]:
        fail("remote.login_identity", "Remote login account does not match the requested non-root account.")
    home = safe_text(fields[3], "remote home directory")
    if not home.startswith("/") or ".." in Path(home).parts:
        fail("remote.home", "Remote login home is not an absolute local path.")
    return {"target_id": fields[0], "uid": int(fields[1]), "user": fields[2], "home": home}


def check_compatibility(remote, manifest):
    """Check the target before transferring or executing its frozen runtime."""
    from closure import version_tuple
    reply = ssh(remote, '/usr/bin/uname -m\n/usr/bin/sw_vers -productVersion\n')
    fields = reply.stdout.strip().splitlines()
    try:
        compatible = (len(fields) == 2 and fields[0] == 'arm64'
                      and version_tuple(fields[1]) >= version_tuple(manifest['minimum_macos']))
    except (ValueError, KeyError):
        compatible = False
    if not compatible:
        fail('remote.compatibility', 'The target must be an Apple silicon Mac running macOS '
             + str(manifest.get('minimum_macos', 'unknown')) + ' or later.', 'requirements')


def sftp_quote(value):
    value = safe_text(str(value), "transfer path")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def transfer(remote, local, destination):
    script = "put " + sftp_quote(local) + " " + sftp_quote(destination) + "\n"
    return command(["/usr/bin/sftp", *remote["flags"], "-P", str(remote["port"]), "-o", "User=" + remote["user"], "-b", "-", remote["host"]],
                   input=script, timeout=900, env=remote["env"], network=True)


def request_options(options):
    result = {key: options[key] for key in REQUEST_KEYS if key in options and options[key] is not None}
    result.update(mode="install", noninteractive=True)
    return result


def checked_result(value, request):
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        fail("remote.result_schema", "Remote result schema is missing or unsupported; preserve this uncertain run.")
    for key in ("run_id", "target_id", "package_sha256", "options_sha256"):
        if value.get(key) != request.get(key):
            fail("remote.result_binding", "Remote result does not match this target, package, options and run; do not reuse it.")
    if not isinstance(value.get("result"), dict):
        fail("remote.result_missing", "Remote result has no installation outcome; preserve this uncertain run.")
    return value["result"]


def fetch_result(remote, directory):
    path = shlex.quote(directory + "/result.json")
    script = "set -eu\np=" + path + "\n" + r'''if [ ! -e "$p" ]; then exit 44; fi
[ ! -L "$p" ] && [ -f "$p" ] || exit 45
[ "$(/usr/bin/stat -f %u "$p")" = "$(/usr/bin/id -u)" ] || exit 45
[ "$(/usr/bin/stat -f %Lp "$p")" = 600 ] || exit 45
[ "$(/usr/bin/stat -f %z "$p")" -le 10485760 ] || exit 45
/bin/cat "$p"
'''
    result = ssh(remote, script, check=False)
    if result.returncode == 44:
        return None
    if result.returncode:
        fail("remote.result_unreadable", "Protected remote result is unavailable; reconnect and reconcile this run before any retry.", "unknown")
    try:
        return json.loads(result.stdout)
    except ValueError:
        fail("remote.result_corrupt", "Remote result is not valid JSON; retain the run as an unknown outcome.", "unknown")


def unknown(record, reason):
    record.phase("remote-outcome-unknown", reason=reason)
    return {"installation": "Unknown", "runtime_health": "Unverified", "gui_video": "Unverified", "backend": "Unverified",
            "security_admission": "Unverified", "recovery": "Unverified", "startup": "StartupUnverified",
            "rollback": "Unknown", "cleanup": "RemoteEvidenceRetained", "full_success": False,
            "run_id": record.data["run_id"], "finding": "remote.outcome_unknown", "reason": reason,
            "evidence": [str(record.root / "journal.json")], "remote_staging": record.data.get("remote_staging")}


def run(options, record):
    remote = ssh_options(options)
    if options.get("dependencies") == "offline":
        fail("remote.offline", "Offline mode prohibits network requests, including SSH; use local installation or explicitly choose manual dependencies.", "usage")
    if options.get("dry_run"):
        return {"installation": "Planned", "full_success": False,
                "plan": ["Verify existing SSH host key and target identity; transfer one verified package.",
                         "Run the protected target-local helper once; retrieve the bound result."]}
    if options.get("scope") == "machine" or remote["user"] != remote["desktop"]:
        fail("remote.authorization", "Machine scope or different SSH and desktop accounts require the protected native authorization helper, which is not implemented; use the desktop account for per-user deployment.", "authorization")
    identity = probe(remote)
    if record.data.get("remote_execution_requested") or record.data.get("phase") in REMOTE_PHASES:
        request = read_json(checked_private_file(record.root / "remote-request.json"))
        expected = request_options(options)
        if digest(expected) != request.get("options_sha256") or request.get("package_sha256") != options.get("package_sha256") or request.get("target_id") != identity["target_id"]:
            fail("remote.resume_binding", "Remote resume options, package or target changed; do not rerun this uncertain installation.")
        try:
            result = fetch_result(remote, record.data["remote_staging"])
        except DeployError as error:
            return unknown(record, error.finding)
        if result is None:
            return unknown(record, "The target has no final protected result yet; inspect or resume this same run later.")
        outcome = checked_result(result, request)
        atomic_json(record.root / "remote-result.json", result)
        record.phase("remote-completed", result_sha256=sha256(record.root / "remote-result.json"))
        return outcome
    package = Path(safe_text(options.get("package"), "--package")).expanduser().absolute()
    expected_hash = options.get("package_sha256")
    if not re.fullmatch(r"[0-9a-f]{64}", expected_hash or "") or not package.is_file() or package.is_symlink() or sha256(package) != expected_hash:
        fail("remote.package_hash", "Package integrity is untrusted or invalid; provide the verified package and --package-sha256.", "integrity")
    # Audit the exact bytes before a trusted system tar ever extracts them remotely.
    with tempfile.TemporaryDirectory(prefix="remote-package-", dir=record.root) as staging:
        safe_extract(package, staging, expected_hash)
        manifest = read_manifest(staging)
    if manifest.get("distribution") == "development" and not options.get("allow_development"):
        fail("remote.development", "Development artifact requires explicit --allow-development; production acceptance remains blocked.")
    check_compatibility(remote, manifest)
    run_id = record.data["run_id"]
    if not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}", run_id):
        fail("remote.run_id", "Run identifier is invalid.")
    directory = identity["home"] + "/Library/Caches/CilexWatchtower/Deploy/" + run_id
    root = shlex.quote(directory)
    # Canonical parent checks and exclusive mkdir prevent replacement/cross-run reuse.
    create = "set -eu\numask 077\nbase=" + shlex.quote(identity["home"] + "/Library/Caches/CilexWatchtower/Deploy") + "\n"
    create += r'''cursor="$HOME"
for component in Library Caches CilexWatchtower Deploy; do
    cursor="$cursor/$component"
    [ ! -L "$cursor" ] || exit 45
    if [ ! -d "$cursor" ]; then /bin/mkdir "$cursor"; fi
    [ "$(/usr/bin/stat -f %u "$cursor")" = "$(/usr/bin/id -u)" ] || exit 45
done
'''
    required_kib = (package.stat().st_size + 2 * sum(entry.get("size", 0) for entry in manifest["files"]) + 512 * 1024**2 + 1023) // 1024
    create += r'''available=$(/bin/df -Pk "$base" | /usr/bin/awk 'NR==2 {print $4}')
case "$available" in ''|*[!0-9]*) exit 47 ;; esac
'''
    create += '[ "$available" -ge ' + str(required_kib) + ' ] || exit 47\n'
    if record.data.get("remote_staging"):
        if record.data["remote_staging"] != directory:
            fail("remote.resume_path", "Resumed staging differs from the run's expected target-local path.")
        create += "[ -d " + root + " ] && [ ! -L " + root + " ] || exit 45\n"
        create += "[ \"$(/usr/bin/stat -f %u " + root + ")\" = \"$(/usr/bin/id -u)\" ] || exit 45\n"
        create += "[ \"$(/usr/bin/stat -f %Lp " + root + ")\" = 700 ] || exit 45\n"
    else:
        create += "/bin/mkdir " + root + "\n/bin/chmod 700 " + root + "\n"
    ssh(remote, create)
    record.data["remote_staging"] = directory
    record.phase("remote-staging-created", target=identity)
    selected = request_options(options)
    request = {"schema_version": 1, "run_id": run_id, "target_id": identity["target_id"],
               "target_uid": identity["uid"], "package_sha256": expected_hash,
               "options_sha256": digest(selected), "options": selected,
               "package_root": directory + "/package", "staging": directory}
    atomic_json(record.root / "remote-request.json", request)
    transfer(remote, package, directory + "/package.tar.gz")
    transfer(remote, record.root / "remote-request.json", directory + "/request.json")
    quarantine = read_quarantine(package)
    verify = "set -eu\numask 077\ncd " + root + "\n"
    verify += "[ \"$(/usr/bin/shasum -a 256 package.tar.gz | /usr/bin/awk '{print $1}')\" = " + shlex.quote(expected_hash) + " ] || exit 46\n"
    verify += "[ \"$(/usr/bin/shasum -a 256 request.json | /usr/bin/awk '{print $1}')\" = " + shlex.quote(sha256(record.root / "remote-request.json")) + " ] || exit 46\n"
    stage_name = "package-stage-" + secrets.token_hex(8)
    verify += "/bin/chmod 600 package.tar.gz request.json\n/bin/mkdir " + stage_name + "\n/usr/bin/tar -xpf package.tar.gz -C " + stage_name + "\n"
    verify += "if [ -e package ]; then [ ! -L package ] || exit 45; /bin/mv package " + stage_name + "-previous; fi\n/bin/mv " + stage_name + " package\n"
    if quarantine:
        verify += "/usr/bin/xattr -wx com.apple.quarantine " + shlex.quote(quarantine.hex()) + " package.tar.gz package/Setup.app package/watchtower.app\n"
    verify += "/usr/bin/codesign --verify --deep --strict package/Setup.app\n"
    if manifest.get("distribution") == "production":
        verify += "/usr/sbin/spctl --assess --type execute package/Setup.app\n"
    ssh(remote, verify, timeout=300)
    record.phase("remote-package-verified", package_sha256=expected_hash)
    setup = directory + "/package/Setup.app/Contents/MacOS/cilex-setup"
    argv = ["/usr/bin/nohup", "/usr/bin/env", "-i", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=" + identity["home"],
            "USER=" + identity["user"], "LOGNAME=" + identity["user"], setup,
            "--remote-request", directory + "/request.json", "--remote-run-id", run_id,
            "--result-file", directory + "/result.json"]
    launch = "set -eu\numask 077\n" + shlex.join(argv) + " >" + shlex.quote(directory + "/setup.log") + " 2>&1 </dev/null &\n"
    # Persist uncertainty BEFORE the only command which can start installation.
    record.data["remote_execution_requested"] = True
    record.phase("remote-execution-requested", request_sha256=sha256(record.root / "remote-request.json"))
    try:
        ssh(remote, launch, timeout=30)
        deadline = time.monotonic() + int(options.get("remote_timeout", 600))
        while time.monotonic() < deadline:
            received = fetch_result(remote, directory)
            if received is not None:
                result = checked_result(received, request)
                atomic_json(record.root / "remote-result.json", received)
                record.phase("remote-completed", result_sha256=sha256(record.root / "remote-result.json"))
                return result
            time.sleep(2)
        return unknown(record, "The bounded remote deadline expired; the detached installation may still be running.")
    except (DeployError, KeyboardInterrupt) as error:
        return unknown(record, getattr(error, "finding", "interrupted"))


def load_request(path, run_id, result_file):
    """Target-local packaged helper validation; no network or writes."""
    path = checked_private_file(Path(path))
    for parent in (path, *path.parents):
        if parent.is_symlink():
            fail("remote.request_symlink", "Remote request path is not canonical; refuse execution.")
    request = read_json(path)
    if request.get("schema_version") != 1 or request.get("run_id") != run_id:
        fail("remote.request_id", "Remote request is not bound to this run.")
    if not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}", run_id or ""):
        fail("remote.request_id", "Remote request run identifier is invalid.")
    home = Path.home()
    staging = home / "Library/Caches/CilexWatchtower/Deploy" / run_id
    if path != staging / "request.json" or Path(result_file) != staging / "result.json" or request.get("staging") != str(staging):
        fail("remote.request_path", "Remote request or result is outside the run's protected staging directory.")
    info = staging.stat()
    if info.st_uid != os.geteuid() or info.st_mode & 0o077:
        fail("remote.request_permissions", "Remote staging is not protected for the intended login account.")
    if request.get("target_id") != host_identity().get("machine_id") or request.get("target_uid") != os.geteuid():
        fail("remote.request_target", "Remote request belongs to another machine or account.")
    options = request.get("options")
    if not isinstance(options, dict) or set(options) - (REQUEST_KEYS | {"mode", "noninteractive"}) or digest(options) != request.get("options_sha256"):
        fail("remote.request_options", "Remote options failed integrity validation.")
    if options.get("mode") != "install" or options.get("noninteractive") is not True:
        fail("remote.request_options", "Remote request must use noninteractive install mode.")
    expected = request.get("package_sha256")
    package = staging / "package.tar.gz"
    if not re.fullmatch(r"[0-9a-f]{64}", expected or "") or package.is_symlink() or sha256(package) != expected:
        fail("remote.request_package", "Remote package hash differs from the approved package.", "integrity")
    if request.get("package_root") != str(staging / "package"):
        fail("remote.request_package", "Remote package path differs from protected staging.")
    read_manifest(staging / "package")
    return options, {"package_root": str(staging / "package"), "package_sha256": expected, "run_id": run_id}, request


def save_result(path, request, result):
    envelope = {key: request[key] for key in ("run_id", "target_id", "package_sha256", "options_sha256")}
    envelope.update(schema_version=1, result=result)
    atomic_json(path, envelope)
    return envelope
