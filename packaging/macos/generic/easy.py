"""Small human-facing commands over the transactional macOS installer."""
from __future__ import annotations

import argparse
import contextlib
import gzip
import json
import os
from pathlib import Path
import plistlib
import platform
import re
import shlex
import subprocess
import sys
import tarfile
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import deploy
import install
import remote
from common import DeployError, clean_env, command, private_dir, read_json, sha256

OUTPUT = Path.home() / 'Downloads/CilexInstallers'
CACHE = Path.home() / 'Library/Caches/CilexWatchtower/SimpleInstaller'


def parser(action):
    p = argparse.ArgumentParser(prog=action + '.sh', add_help=False,
        description='Use "help" to read these instructions. Every option needs a value.')
    if action == 'build-installer':
        p.add_argument('--output-dir', type=Path, default=OUTPUT, help='Where to save installers; default: ~/Downloads/CilexInstallers')
        p.add_argument('--jobs', type=int, help='Parallel compile jobs, 1 through 64; default: choose for available memory')
        p.add_argument('--revision', default='HEAD', help='Local Git commit, branch or tag to build; default: HEAD (current commit)')
        p.add_argument('--tools', choices=('install', 'existing'), default='install', help='Install missing Homebrew tools or use existing ones only; default: install')
    elif action in ('install-local', 'install-remote'):
        p.add_argument('--installer', type=Path, help='DMG file; default: newest build in ~/Downloads/CilexInstallers')
        p.add_argument('--development', choices=('yes', 'no'), default='yes', help='Allow the unsigned internal build; default: yes')
        p.add_argument('--backend-url', help='Cilex Vision server address; default: keep existing setup')
    if action == 'install-remote':
        p.add_argument('--host', required=True, help='Remote Mac hostname or IP address')
        p.add_argument('--user', required=True, help='Remote Mac account short name')
        p.add_argument('--port', type=int, default=22, help='SSH port; default: 22')
        p.add_argument('--resume', help='Run ID printed by an interrupted installation')
    return p


def find_installer(selected):
    if selected:
        path = selected.expanduser().absolute()
        if path.suffix.lower() != '.dmg' or not path.is_file() or path.is_symlink():
            raise ValueError('--installer must name an existing DMG file.')
        return path
    candidates = [p for p in OUTPUT.rglob('CilexWatchtower-*.dmg') if p.is_file() and not p.is_symlink()]
    if not candidates:
        raise ValueError('No installer found. First run ./packaging/macos/build-installer.sh')
    return max(candidates, key=lambda p: p.stat().st_mtime_ns)


@contextlib.contextmanager
def mounted(image):
    with tempfile.TemporaryDirectory(prefix='cilex-dmg-', dir='/tmp') as temp:
        # hdiutil reports /private/tmp even when given the /tmp alias.
        mount = Path(temp).resolve() / 'volume'
        mount.mkdir()
        print('Opening installer: ' + str(image), flush=True)
        reply = subprocess.run(['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-plist',
                                '-mountpoint', str(mount), str(image)],
                               capture_output=True, timeout=180, check=True, env=clean_env())
        try:
            entities = plistlib.loads(reply.stdout).get('system-entities', [])
            if not any(row.get('mount-point') == str(mount) for row in entities):
                raise ValueError('macOS did not mount the installer at the requested location.')
            yield mount
        finally:
            subprocess.run(['/usr/bin/hdiutil', 'detach', str(mount)],
                           capture_output=True, timeout=60, check=True, env=clean_env())


def transport_package(image):
    """Check the DMG inventory, then cache a stable archive for safe resume."""
    root = private_dir(CACHE / 'packages' / sha256(image))
    archive = root / 'package.tar.gz'
    receipt = root / 'receipt.json'
    if archive.is_file() and receipt.is_file():
        data = read_json(receipt)
        if sha256(archive) == data.get('sha256'):
            return archive, data['manifest']
        raise ValueError('Cached installer changed. Remove this cache folder before retrying: ' + str(root))
    with mounted(image) as package:
        manifest = install.read_manifest(package)
        quarantine = install.read_quarantine(image)
        partial = root / 'package.partial'
        # Add only the frozen inventory, not Finder metadata from the mounted volume.
        with partial.open('wb') as out, gzip.GzipFile(fileobj=out, mode='wb', mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode='w', dereference=False) as tar:
                for name in sorted({'artifact-manifest.json'} | {row['path'] for row in manifest['files']}):
                    tar.add(package / name, arcname=name, recursive=False)
        partial.chmod(0o600)
        if quarantine:
            install.write_quarantine(partial, quarantine)
        partial.replace(archive)
        from common import atomic_json
        atomic_json(receipt, {'sha256': sha256(archive), 'manifest': manifest})
    return archive, manifest


def validate_target(host, user, port):
    if not re.fullmatch(r'[A-Za-z0-9.:%_\-\[\]]+', host) or host.startswith('-'):
        raise ValueError('--host must be a hostname or IP address, such as office-mac.local or 192.168.1.50.')
    if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9._-]*', user) or user == 'root':
        raise ValueError('--user must be the remote Mac account short name, not root or an email address.')
    if not 1 <= port <= 65535:
        raise ValueError('--port must be between 1 and 65535.')


@contextlib.contextmanager
def password_session(host, user, port):
    validate_target(host, user, port)
    if not sys.stdin.isatty():
        raise ValueError('Run remote installation in Terminal so SSH can ask for your password.')
    ssh_dir = Path.home() / '.ssh'
    if ssh_dir.is_symlink():
        raise ValueError('The .ssh folder must not be a symbolic link.')
    ssh_dir.mkdir(mode=0o700, exist_ok=True)
    if ssh_dir.stat().st_uid != os.geteuid() or ssh_dir.stat().st_mode & 0o022:
        raise ValueError('The .ssh folder is writable by another account; correct its permissions first.')
    known = ssh_dir / 'known_hosts'
    if not known.exists():
        fd = os.open(known, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(fd)
    if known.is_symlink() or known.stat().st_uid != os.geteuid() or known.stat().st_mode & 0o022:
        raise ValueError('The known_hosts file must be owned by you and protected from other accounts.')
    # Short private directory avoids the macOS Unix-domain socket path limit.
    with tempfile.TemporaryDirectory(prefix='cilex-ssh-', dir='/tmp') as temp:
        control = Path(temp) / 'session'
        base = ['/usr/bin/ssh', '-F', '/dev/null', '-S', str(control), '-p', str(port), '-l', user,
                '-o', 'StrictHostKeyChecking=ask', '-o', 'UserKnownHostsFile="' + str(known).replace('\\', '\\\\').replace('"', '\\"') + '"',
                '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=3',
                '-o', 'ForwardAgent=no', '-o', 'ClearAllForwardings=yes', '-o', 'IdentityAgent=none',
                '-o', 'PubkeyAuthentication=no', '-o', 'NumberOfPasswordPrompts=1', '-o', 'ControlPersist=60']
        print('Connecting to ' + user + '@' + host + '. Enter that Mac account’s password when asked.', flush=True)
        try:
            subprocess.run([*base, '-M', '-N', '-f', host], check=True, timeout=180, env=clean_env())
            options = {'target_host': host, 'ssh_user': user, 'desktop_user': user, 'ssh_port': port,
                       'ssh_known_hosts': str(known), 'ssh_control_path': str(control),
                       'expected_target_id': '0' * 64}
            connection = remote.ssh_options(options)
            response = remote.ssh(connection, remote.PROBE).stdout.rstrip('\n').split('\n')
            if len(response) != 4 or not re.fullmatch('[0-9a-f]{64}', response[0]):
                raise ValueError('The remote computer did not identify itself as a compatible Mac.')
            options['expected_target_id'] = response[0]
            # Recheck login identity and home through the same authenticated session.
            remote.probe(remote.ssh_options(options))
            yield options
        finally:
            if control.exists():
                try:
                    subprocess.run([*base, '-O', 'exit', host], capture_output=True,
                                   timeout=15, check=False, env=clean_env())
                except (OSError, subprocess.SubprocessError):
                    # Cleanup must never hide an installation result or run ID.
                    # ControlPersist also expires an idle master after one minute.
                    print('Temporary SSH session cleanup was incomplete; its idle timeout is one minute.', file=sys.stderr)


def show_outcome(value, record):
    state = value.get('states', {}).get('installation')
    if value.get('mode') in ('build', 'build-installer'):
        print('Installer created.' if value.get('exit_code') == 0 else 'Build stopped. No installer was completed.')
    elif state == 'Installed':
        print('Cilex Watchtower is installed. Its startup and camera checks may still need attention.')
    else:
        print('Installation is not confirmed: ' + str(state or 'unknown'))
    for finding in value.get('findings', []):
        print(finding.get('message', str(finding)))
    failure = value.get('original_failure')
    if isinstance(failure, dict) and failure.get('message'):
        print(failure['message'])
    if record:
        print('Run ID: ' + record.data['run_id'])
        print('Details saved on this Mac: ' + str(record.root / 'result.json'))
    return value.get('exit_code', 1)


def validate_backend(url):
    if url:
        deploy.normalize(deploy.parser().parse_args(['--backend-url', url]))


def check_development(manifest, allowed):
    development = manifest.get('distribution') == 'development'
    if development and allowed == 'no':
        raise ValueError('This is an unsigned internal installer. Use --development yes to allow it.')
    return development


def install_local(args):
    validate_backend(args.backend_url)
    image = find_installer(args.installer)
    with mounted(image) as package:
        manifest = install.read_manifest(package)
        development = check_development(manifest, args.development)
        from closure import version_tuple
        if platform.machine() != 'arm64' or version_tuple(platform.mac_ver()[0]) < version_tuple(manifest['minimum_macos']):
            raise ValueError('This installer needs an Apple silicon Mac running macOS ' + manifest['minimum_macos'] + ' or later.')
        argv = [str(package / 'Setup.app/Contents/MacOS/cilex-setup'), '--mode', 'install',
                '--package', str(package), '--package-manifest-sha256', sha256(package / 'artifact-manifest.json'),
                '--dependencies', 'offline', '--noninteractive', 'yes', '--allow-development', 'yes' if development else 'no']
        if args.backend_url:
            argv += ['--backend-url', args.backend_url]
        print('Installing Cilex Watchtower for your Mac account. Keep this Terminal window open.', flush=True)
        reply = command(argv, timeout=900, check=False)
        try:
            value = json.loads(reply.stdout)
        except ValueError:
            raise ValueError('The installer did not return a result. ' + reply.stderr[-2000:])
        show_outcome(value, None)
        for path in value.get('evidence', []):
            print('Details: ' + path)
        return value.get('exit_code', reply.returncode)


def install_remote(args):
    # Validate all target inputs before opening an image or making an SSH connection.
    validate_target(args.host, args.user, args.port)
    validate_backend(args.backend_url)
    image = find_installer(args.installer)
    package, manifest = transport_package(image)
    development = check_development(manifest, args.development)
    options = deploy.normalize(deploy.parser().parse_args([]))
    options.update(mode='remote-install', package=str(package), package_sha256=sha256(package),
                   allow_development=development, backend_url=args.backend_url,
                   dependencies='manual', resume=args.resume)
    with password_session(args.host, args.user, args.port) as session:
        options.update(session)
        print('Transferring and installing. Keep this Terminal window open.', flush=True)
        value, record = deploy.execute(options)
    code = show_outcome(value, record)
    if value.get('states', {}).get('installation') == 'Unknown' and record:
        print('Do not start a new installation. Check the same run with:')
        print('./packaging/macos/install-remote.sh --host ' + shlex.quote(args.host) +
              ' --user ' + shlex.quote(args.user) + ' --installer ' + shlex.quote(str(image)) +
              ' --development ' + ('yes' if development else 'no') + ' --port ' + str(args.port) +
              ((' --backend-url ' + shlex.quote(args.backend_url)) if args.backend_url else '') +
              ' --resume ' + shlex.quote(record.data['run_id']))
    return code


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    action = argv.pop(0)
    p = parser(action)
    if argv == ['help']:
        p.print_help()
        return 0
    args = p.parse_args(argv)
    try:
        if sys.platform != 'darwin':
            raise ValueError('Run this command on a Mac.')
        if action == 'build-installer':
            if args.jobs is not None and not 1 <= args.jobs <= 64:
                raise ValueError('--jobs must be between 1 and 64.')
            import simple_build
            return simple_build.run(args, CACHE, args.output_dir)
        if action == 'install-local':
            return install_local(args)
        if action == 'install-remote':
            return install_remote(args)
        raise ValueError('Unknown command: ' + action)
    except (DeployError, deploy.build.BuildError, ValueError, OSError, subprocess.SubprocessError) as error:
        print('Stopped: ' + str(error), file=sys.stderr)
        return getattr(error, 'code', 1)
    except KeyboardInterrupt:
        print('Interrupted. Check any printed run ID before starting another installation.', file=sys.stderr)
        return 130


if __name__ == '__main__':
    raise SystemExit(main())
