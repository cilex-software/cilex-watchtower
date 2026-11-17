"""Finder entry point for a copied app or the updater in a mounted DMG.

All writes are in the signed-in user's Library. The existing deployment engine
owns app replacement; the installed-app path only registers its LaunchAgent.
"""
from __future__ import annotations

import contextlib
import fcntl
import os
from pathlib import Path
import plistlib
import re
import sys
import time

import install
from common import command, private_dir

MANIFEST = {'app': 'watchtower.app',
            'warden': 'watchtower.app/Contents/Resources/warden/cilex-warden',
            '_executable': 'watchtower'}


def dialog(message, confirm=False):
    # Literal arguments, never executable interpolation. No System Events or
    # Accessibility permission is needed for this ordinary application dialog.
    script = '''function run(a) {
      var app=Application.currentApplication(); app.includeStandardAdditions=true;
      try { return app.displayDialog(a[0], {withTitle:'Cilex Watchtower',
        buttons:a[1]=='yes'?['Cancel','Open Watchtower']:['OK'],
        defaultButton:a[1]=='yes'?'Open Watchtower':'OK', cancelButton:1}).buttonReturned; }
      catch(e) { return 'Cancel'; }
    }'''
    result = command(['/usr/bin/osascript', '-l', 'JavaScript', '-e', script,
                      message, 'yes' if confirm else 'no'], timeout=600, check=False)
    return result.returncode == 0 and result.stdout.strip() == 'Open Watchtower'


def target_for(app):
    path = Path(app)
    if path != path.resolve() or path.parent not in (Path('/Applications'), Path.home() / 'Applications'):
        raise ValueError('Drag Cilex Watchtower into Applications, eject the DMG, then open the app from Applications.')
    target = install.resolve_target({'install_dir': str(path), 'scope': 'user'})
    if target['uid'] != os.getuid() or target['uid'] == 0:
        raise ValueError('Open Watchtower from the Mac account that will use it, without sudo.')
    with (path / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('CFBundleIdentifier') != install.BUNDLE_ID or info.get('CFBundleExecutable') != 'watchtower':
        raise ValueError('This is not a Cilex Watchtower application bundle.')
    for relative in ('Contents/MacOS/watchtower', 'Contents/Resources/warden/cilex-warden',
                     'Contents/Resources/warden/cilex-spawn-gate'):
        executable = path / relative
        if not executable.is_file() or not executable.resolve().is_relative_to(path) or executable.is_symlink():
            raise ValueError('The application is incomplete. Copy it again from the DMG.')
    install.execute(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(path)])
    return target


def agent_bytes(target):
    path = target['agent']
    if not path.exists() and not path.is_symlink():
        return None
    install.configuration_file(path, target)
    if path.parent.stat().st_uid != target['uid'] or path.parent.stat().st_mode & 0o022:
        raise ValueError('The Watchtower startup folder has unsafe ownership or permissions.')
    raw = path.read_bytes()
    data = plistlib.loads(raw)
    argv = data.get('ProgramArguments', [])
    expected = str(target['path'] / 'Contents/Resources/warden/cilex-warden')
    bindings = {'WT_WARDEN_INSTALLATION_ID': target['id'],
                'WT_WARDEN_APP_CMD': str(target['path'] / 'Contents/MacOS/watchtower')}
    if (data.get('Label') != target['label'] or argv[:2] != ['/usr/bin/env', '-i']
            or argv[-2:] != [expected, 'run']
            or any([item for item in argv if isinstance(item, str) and item.startswith(key+'=')]
                   != [key+'='+value] for key, value in bindings.items())):
        raise ValueError('The existing Watchtower startup entry has a different configuration. It was left unchanged.')
    return raw


def other_installations(target):
    found = []
    for path in sorted(target['agent'].parent.glob('com.cilexvision.watchtower.*.plist')):
        if path == target['agent']:
            continue
        # Diagnostic jobs and unrelated launchd services are not installations.
        if not re.fullmatch(r'com\.cilexvision\.watchtower\.[0-9a-f]{24}\.plist', path.name):
            continue
        install.configuration_file(path, target)
        data = plistlib.loads(path.read_bytes())
        commands = [value.split('=', 1)[1] for value in data.get('ProgramArguments', [])
                    if isinstance(value, str) and value.startswith('WT_WARDEN_APP_CMD=')]
        if len(commands) != 1 or not commands[0].endswith('/Contents/MacOS/watchtower'):
            raise ValueError('An existing Watchtower startup entry cannot be identified safely. It was left unchanged.')
        old = install.resolve_target({'install_dir': str(Path(commands[0]).parents[2])})
        if old['agent'] != path:
            raise ValueError('An existing Watchtower startup entry has an unexpected identity. It was left unchanged.')
        found.append((old, agent_bytes(old)))
    if len(found) > 1:
        raise ValueError('More than one Watchtower installation has startup enabled. Choose which installation to keep before opening this copy.')
    return found


def wait_user_processes(target, running, timeout=60):
    import runtime
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        # /Applications is shared across accounts; each account has its own job,
        # guardian and records. Another signed-in user's wall must be untouched.
        rows = [row for row in install.process_snapshot() if row['uid'] == target['uid']]
        evidence = runtime.process_evidence(target, MANIFEST, rows=rows)
        if (running and evidence['state'] == 'ProcessVerified') or (not running and not evidence['processes']):
            return
        time.sleep(.2)
    raise ValueError('Watchtower did not reach the expected startup state within 60 seconds.')


def stop_service(target):
    before = install.job_state(target)
    install.assert_job_process(target, MANIFEST, before)
    if before['loaded']:
        install.execute(['/bin/launchctl', 'bootout', target['domain'] + '/' + target['label']])
    wait_user_processes(target, running=False)
    install.wait_job_unloaded(target)


def start_service(target):
    service = target['domain'] + '/' + target['label']
    state = install.job_state(target)
    install.assert_job_process(target, MANIFEST, state)
    if state['disabled']:
        # Opening the app is an explicit start, unlike background installer checks.
        install.execute(['/bin/launchctl', 'enable', service])
    if not state['loaded']:
        install.bootstrap_job(target, MANIFEST)
    elif not state['pid']:
        install.execute(['/bin/launchctl', 'kickstart', service])
    wait_user_processes(target, running=True)


def activate(target):
    rows = [row for row in install.process_snapshot()
            if row['uid'] == target['uid'] and row['path'] == str(target['path'] / 'Contents/MacOS/watchtower')]
    if len(rows) != 1:
        raise ValueError('Watchtower did not start as expected. Its startup entry has been retained for inspection.')
    # Activate the verified existing PID. Opening the bundle URL would invoke
    # this first-launch entry point recursively instead of focusing the window.
    script = '''ObjC.import('AppKit'); function run(a) {
      var app=$.NSRunningApplication.runningApplicationWithProcessIdentifier(Number(a[0]));
      if (!app || app.isTerminated) throw Error('Watchtower is no longer running');
      app.activateWithOptions(2);
    }'''
    command(['/usr/bin/osascript', '-l', 'JavaScript', '-e', script, str(rows[0]['pid'])], timeout=15)


@contextlib.contextmanager
def launch_lock(target):
    # One Finder launch/migration at a time, including two different app copies.
    state_dir = private_dir(target['home'] / 'Library/Application Support/CilexWatchtower/FinderLaunch')
    lock = state_dir / 'launch.lock'
    fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        if (os.fstat(fd).st_uid != target['uid'] or os.fstat(fd).st_nlink != 1
                or os.fstat(fd).st_mode & 0o077):
            raise ValueError('The Watchtower startup lock has unexpected ownership.')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


def launch(target):
    with launch_lock(target):
        existing = agent_bytes(target)
        others = other_installations(target)
        if existing and others:
            raise ValueError('Another Watchtower copy also has startup enabled. No service was changed.')
        if not install.job_state(target)['gui_session']:
            raise ValueError('Sign in to this Mac normally before opening Watchtower.')
        if not existing:
            message = ('Warden keeps Watchtower running and starts it when you sign in. '
                       'Enable Warden and open Watchtower? Your existing settings will be kept.')
            if others:
                message += '\n\nThis will stop the older copy at ' + str(others[0][0]['path']) + ' and use this copy instead.'
            if not dialog(message, confirm=True):
                return 0
            for folder in (target['agent'].parent,
                           target['home'] / 'Library/Logs/CilexWatchtower' / target['id'],
                           target['home'] / 'Library/Caches/CilexWatchtower' / target['id']):
                # Library/LaunchAgents may legitimately be 0755; reject redirects
                # and foreign ownership, rather than changing its permissions.
                for parent in (folder, *folder.parents):
                    if parent.is_symlink():
                        raise ValueError('A Watchtower startup folder is a symbolic link. No service was changed.')
                    if parent == target['home']:
                        break
                folder.mkdir(parents=True, exist_ok=True, mode=0o700)
                if folder.stat().st_uid != target['uid'] or folder.stat().st_mode & 0o022:
                    raise ValueError('A Watchtower startup folder is writable by another account.')
            prior = [(old, raw, install.job_state(old)) for old, raw in others]
            for old, _, before in prior:
                install.assert_job_process(old, MANIFEST, before)
            stopped = []
            try:
                for old, raw, before in prior:
                    stopped.append((old, raw, before))
                    stop_service(old)
                options = {}
                if prior:
                    # Preserve a previously selected server; all credentials and
                    # application preferences remain in their original locations.
                    argv = plistlib.loads(prior[0][1])['ProgramArguments']
                    urls = [s.split('=', 1)[1] for s in argv if s.startswith('WT_WARDEN_BACKEND_URL=')]
                    if urls:
                        options['backend_url'] = urls[0]
                install.atomic_bytes(target['agent'], plistlib.dumps(install.launchagent(target, MANIFEST, options)))
                start_service(target)
                for old, _, _ in prior:
                    old['agent'].unlink()
            except Exception:
                # Never leave two supervisors running after an unsuccessful move.
                stop_service(target)
                target['agent'].unlink(missing_ok=True)
                for old, raw, before in stopped:
                    install.atomic_bytes(old['agent'], raw)
                    if before['loaded']:
                        install.execute(['/bin/launchctl', 'bootstrap', old['domain'], str(old['agent'])])
                raise
        else:
            start_service(target)
        activate(target)
        return 0


def main(argv):
    try:
        if len(argv) != 1:
            raise ValueError('Open Cilex Watchtower from Applications.')
        app = Path(argv[0])
        if getattr(sys, 'frozen', False):
            expected = app / 'Contents/Helpers/Setup.app/Contents/MacOS/cilex-setup'
            if Path(sys.executable).resolve() != expected.resolve():
                raise ValueError('Open the copied Watchtower app from Applications.')
        if app.parent not in (Path('/Applications'), Path.home() / 'Applications'):
            import finder_update
            return finder_update.main(app)
        return launch(target_for(app))
    except Exception as error:
        dialog('Watchtower could not be opened.\n\n' + str(error))
        return 1
