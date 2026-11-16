"""DMG double-click updates. Never launch the wall from a mounted installer.

The existing transactional installer owns replacement, service shutdown and
rollback. This module supplies the GUI consent and binds it to one installed
copy and the exact disk image the user opened. It never elevates privileges.
"""
from __future__ import annotations

import contextlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import tempfile

import first_launch
import install
from common import command, sha256

APP_NAME = 'Cilex Watchtower.app'


def language():
    try:
        with (Path.home() / 'Library/Preferences/.GlobalPreferences.plist').open('rb') as stream:
            languages = plistlib.load(stream).get('AppleLanguages', [])
        return 'ru' if languages and languages[0].split('-')[0].lower() == 'ru' else 'en'
    except (OSError, ValueError):
        return 'en'


def text(en, ru):
    return ru if language() == 'ru' else en


def dialog(message, confirm=False):
    # Arguments are data, including paths and button labels; no script interpolation.
    button = text('Update', 'Обновить') if confirm else 'OK'
    script = '''function run(a) {
      var app=Application.currentApplication(); app.includeStandardAdditions=true;
      try { return app.displayDialog(a[0], {withTitle:'Cilex Watchtower',
        buttons:a[3]=='yes'?[a[1],a[2]]:[a[2]], defaultButton:a[2],
        cancelButton:1}).buttonReturned; } catch(e) { return ''; }
    }'''
    reply = command(['/usr/bin/osascript', '-l', 'JavaScript', '-e', script,
                     message, text('Cancel', 'Отмена'), button,
                     'yes' if confirm else 'no'], timeout=600, check=False)
    return reply.returncode == 0 and reply.stdout.strip() == button


def source_volume(app):
    """Resolve Apple's translocation mapping, then require an actual read-only DMG."""
    app = Path(app)
    if app != app.resolve() or app.name != APP_NAME:
        raise ValueError('Open Cilex Watchtower from the original DMG.')
    original = app
    if not (app.parent / '.deployment/artifact-manifest.json').is_file():
        reply = command(['/usr/bin/security', 'translocate-original-path', str(app)],
                        timeout=15, check=False)
        paths = [line[1:] for line in reply.stdout.splitlines() if line.startswith('\t/')]
        if reply.returncode != 0 or len(paths) != 1:
            raise ValueError('Drag Cilex Watchtower into Applications for a first installation. To update, open the new DMG and double-click its app.')
        original = Path(paths[0])
        if original != original.resolve() or original.name != APP_NAME:
            raise ValueError('macOS could not identify the original installer.')
        for relative in ('Contents/MacOS/watchtower',
                         'Contents/Helpers/Setup.app/Contents/MacOS/cilex-setup'):
            if sha256(original / relative) != sha256(app / relative):
                raise ValueError('The original installer differs from the launched application.')
    volume = original.parent
    fs = install.inspect_filesystem(volume)
    reply = command(['/usr/bin/hdiutil', 'info', '-plist'], timeout=30)
    images = plistlib.loads(reply.stdout.encode()).get('images', [])
    matches = [image for image in images if any(
        row.get('mount-point') == str(volume) for row in image.get('system-entities', []))]
    if (len(matches) != 1 or not fs['read_only']
            or Path(fs['mount_point']) != volume
            or (volume / '.deployment').is_symlink()
            or not (volume / '.deployment/artifact-manifest.json').is_file()):
        raise ValueError('Open the complete, read-only Cilex Watchtower DMG. No installed app was changed.')
    return volume


def application_dirs():
    return Path('/Applications'), Path.home() / 'Applications'


def installed_target():
    """No newest-file guessing or migration: update one identifiable installed copy."""
    parents = application_dirs()
    paths = {parent / name for parent in parents for name in (APP_NAME, 'watchtower.app')
             if (parent / name).exists() or (parent / name).is_symlink()}
    agents = Path.home() / 'Library/LaunchAgents'
    for entry in agents.glob('com.cilexvision.watchtower.*.plist'):
        if not re.fullmatch(r'com\.cilexvision\.watchtower\.[0-9a-f]{24}\.plist', entry.name):
            continue
        # Same protected account/path contract as normal first launch.
        probe = install.resolve_target({})
        install.configuration_file(entry, probe)
        data = plistlib.loads(entry.read_bytes())
        commands = [arg.split('=', 1)[1] for arg in data.get('ProgramArguments', [])
                    if isinstance(arg, str) and arg.startswith('WT_WARDEN_APP_CMD=')]
        if not commands:  # Exact legacy format is validated by validate_existing below.
            commands = [data.get('EnvironmentVariables', {}).get('WT_WARDEN_APP_CMD', '')]
        if len(commands) != 1 or not commands[0].endswith('/Contents/MacOS/watchtower'):
            raise ValueError('An existing Watchtower startup entry cannot be identified. No service was changed.')
        path = Path(commands[0]).parents[2]
        target = install.resolve_target({'install_dir': str(path)})
        if path.parent not in parents or entry != target['agent']:
            raise ValueError('An existing Watchtower copy needs inspection before updating. No service was changed.')
        paths.add(path)
    if not paths:
        return None
    if len(paths) != 1:
        raise ValueError('More than one Watchtower copy is installed. Keep one copy in Applications, then try again. No service was changed.')
    return first_launch.target_for(paths.pop())


def update_options(target, manifest):
    options = {'mode': 'install', 'scope': 'user', 'startup': 'after-sign-in',
               'install_dir': str(target['path']), 'desktop_user': target['user'],
               'allow_development': manifest.get('distribution') == 'development',
               '_finder_update': True}
    install.assert_authorized(target, options)
    install.validate_existing(target, first_launch.MANIFEST)
    if target['agent'].is_file():
        job = plistlib.loads(target['agent'].read_bytes())
        env = job.get('EnvironmentVariables', {})
        assignments = job.get('ProgramArguments', [])
        urls = [arg.split('=', 1)[1] for arg in assignments
                if arg.startswith('WT_WARDEN_BACKEND_URL=')]
        if urls:
            options['backend_url'] = urls[0]
        elif env.get('WT_WARDEN_BACKEND_URL'):
            options['backend_url'] = env['WT_WARDEN_BACKEND_URL']
    return options


@contextlib.contextmanager
def package_from_volume(volume):
    # A private reconstruction avoids executing the image's loose Python files.
    # The frozen executable owns this code. The complete manifest/closure and
    # native signature are checked again before any service is stopped.
    with tempfile.TemporaryDirectory(prefix='cilex-update-') as temp:
        package = Path(temp).resolve() / 'package'
        shutil.copytree(volume / '.deployment', package, symlinks=True)
        shutil.copytree(volume / APP_NAME, package / 'watchtower.app', symlinks=True)
        quarantine = install.read_quarantine(volume / APP_NAME)
        if quarantine:
            install.write_quarantine(package / 'watchtower.app', quarantine)
        yield package


def update(volume):
    target = installed_target()
    if target is None:
        dialog(text('To install, drag Cilex Watchtower onto Applications in this window. Then eject the DMG and open Watchtower from Applications.',
                    'Для установки перетащите Cilex Watchtower в Applications в этом окне. Затем извлеките DMG и откройте Watchtower из Applications.'))
        return 0
    # Share the normal Finder-launch lock, including consent and final activation.
    with first_launch.launch_lock(target):
        manifest = json.loads((volume / '.deployment/artifact-manifest.json').read_text())
        options = update_options(target, manifest)
        with (target['path'] / 'Contents/Info.plist').open('rb') as stream:
            old_version = plistlib.load(stream).get('CFBundleShortVersionString', '?')
        message = text(
            'Update Cilex Watchtower from {old} to {new}?\n\n{path}\n\nThis will stop Warden and Watchtower, replace the app, then start them again. Your settings and sign-in will be kept. Please wait until the update finishes.',
            'Обновить Cilex Watchtower с {old} до {new}?\n\n{path}\n\nWarden и Watchtower будут остановлены. После замены приложения они запустятся снова. Настройки и вход в систему сохранятся. Дождитесь завершения обновления.').format(
                old=old_version, new=manifest['version'], path=target['path'])
        if options['allow_development']:
            message += text('\n\nThis is an unsigned internal build.', '\n\nЭто внутренняя сборка без подписи Apple.')
        if not dialog(message, confirm=True):
            return 0
        with package_from_volume(volume) as package:
            result = install.run(options, {'package_root': str(package),
                                          'package_sha256': sha256(package / 'artifact-manifest.json')})
        if result.get('installation') != 'Installed':
            raise ValueError('Update failed. Recovery: ' + str(result.get('rollback', 'not completed'))
                             + '\n' + str(result.get('original_failure', {}).get('message', ''))
                             + '\nDetails: ' + ', '.join(result.get('evidence', [])))
        # Consent above explicitly includes restart, even if this user's job was
        # disabled/unloaded. Scripted installs retain their preserve-state policy.
        try:
            first_launch.start_service(target)
            first_launch.activate(target)
        except Exception as error:
            raise ValueError('The app was updated, but could not be opened. Open it from Applications to retry.\n' + str(error)) from error
        dialog(text('Cilex Watchtower was updated and opened. You can eject the DMG.',
                    'Cilex Watchtower обновлён и открыт. Можно извлечь DMG.'))
        return 0


def main(app):
    try:
        return update(source_volume(app))
    except Exception as error:
        dialog(text('Watchtower could not finish the update.\n\n',
                    'Не удалось завершить обновление Watchtower.\n\n') + str(error))
        return 1
