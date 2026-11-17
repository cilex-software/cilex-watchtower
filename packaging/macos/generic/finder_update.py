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


def dialog(message, confirm=False, action=None):
    # Arguments are data, including paths and button labels; no script interpolation.
    button = (action or text('Update', 'Обновить')) if confirm else 'OK'
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
    """Prefer the verified running Warden, then one owned startup registration.

    Older inactive copies may remain after switching from Setup to Finder's
    Applications install. Their presence is not ambiguity about the active app.
    Never choose by modification time or version, or delete/migrate another copy.
    """
    parents = application_dirs()
    paths = {parent / name for parent in parents for name in (APP_NAME, 'watchtower.app')
             if (parent / name).exists() or (parent / name).is_symlink()}
    agents = Path.home() / 'Library/LaunchAgents'
    registered, running = set(), set()
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
        # Validate the entire owned configuration, not just its filename/path.
        install.validate_existing(target, first_launch.MANIFEST)
        state = install.job_state(target)
        if state['loaded'] and state.get('pid'):
            install.assert_job_process(target, first_launch.MANIFEST, state)
            running.add(path)
        registered.add(path)
        paths.add(path)
    if not paths:
        return None
    if len(running) == 1:
        selected = next(iter(running))
    elif not running and len(registered) == 1:
        selected = next(iter(registered))
    elif len(paths) == 1:
        selected = next(iter(paths))
    else:
        detail = '\n'.join(str(path) for path in sorted(running or registered or paths))
        raise ValueError('More than one Watchtower installation could be updated. '
                         'The updater cannot identify a single Warden-managed copy. '
                         'No service was changed.\n\n' + detail)
    return first_launch.target_for(selected)


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


def interrupted_update(target):
    """Read the owned journal; a new DMG must not bypass an unfinished update."""
    paths = sorted(target['support'].glob('*.json'))
    if len(paths) > 1000:
        raise ValueError('Too many installation records; inspect them before recovery.')
    unfinished = []
    for path in paths:
        if path.name in ('receipt.json', 'uninstall-result.json'):
            continue
        record = install.checked_private_file(path)
        if record.stat().st_size > 8 * 1024**2:
            raise ValueError('An installation record is too large to inspect safely.')
        state = json.loads(record.read_text())
        expected = {'schema_version': install.SCHEMA, 'installation_id': target['id'],
                    'target_uid': target['uid'], 'install_dir': str(target['path']), 'run_id': path.stem}
        if any(state.get(key) != value for key, value in expected.items()):
            raise ValueError('An installation record has a different identity; no recovery was attempted.')
        if state.get('phase') not in ('installed', 'rolled_back_runtime_unverified', 'uninstalled'):
            unfinished.append((record, state))
    if not unfinished:
        return None
    if len(unfinished) != 1:
        raise ValueError('Several interrupted operations need inspection; no recovery was attempted.')
    return unfinished[0]


def recover_interrupted(target):
    """Offer restoration through the original bound transaction, never a blind copy."""
    found = interrupted_update(target)
    if found is None:
        return False
    record, state = found
    manifest = state.get('previous_manifest', {})
    if not state.get('previous_application') or manifest.get('app') != 'watchtower.app':
        raise ValueError('The interrupted operation has no identified previous app to restore.')
    staging = Path(state.get('staging', ''))
    if (staging.parent != target['path'].parent or not staging.name.startswith('.cilex-deploy-')
            or staging.is_symlink() or not staging.is_dir()
            or staging.stat().st_uid != target['uid'] or staging.stat().st_mode & 0o077):
        raise ValueError('The recovery folder is not the protected folder recorded for this app.')
    previous = staging / 'previous.app'
    if previous.is_symlink() or not previous.is_dir() or install.app_fingerprint(previous) != state.get('previous_app_sha256'):
        raise ValueError('The previous app backup does not match its recorded fingerprint.')
    options = update_options(target, manifest)
    options['resume'] = state['run_id']
    if install.digest(install.requested_transaction(options)) != state.get('options_sha256'):
        raise ValueError('The interrupted update used different options; preserve its record for inspection.')
    with (previous / 'Contents/Info.plist').open('rb') as stream:
        version = plistlib.load(stream).get('CFBundleShortVersionString', '?')
    message = text(
        'The previous update did not finish. Restore Cilex Watchtower {version} and its previous startup state?\n\n{path}\n\nYour settings will be restored from this update’s protected backup. The failed replacement will be kept for inspection.',
        'Предыдущее обновление не завершено. Восстановить Cilex Watchtower {version} и прежнее состояние запуска?\n\n{path}\n\nНастройки будут восстановлены из защищённой копии этой операции. Неудачная новая версия останется для проверки.').format(version=version, path=target['path'])
    if not dialog(message, confirm=True, action=text('Restore Previous Version', 'Восстановить прежнюю версию')):
        return True
    # The engine binds recovery to the original replacement fingerprint/package,
    # even when this helper came from a newer DMG. Retain both versions on disk.
    candidates = [target['path'], staging / 'failed.app'] + sorted(staging.glob('interrupted-replacement-*.app'))
    if len(candidates) > 34:
        raise ValueError('Too many retained replacements; inspect the recovery folder before retrying.')
    replacement = next((path for path in candidates if not path.is_symlink() and path.is_dir()
                        and install.app_fingerprint(path) == state.get('replacement_app_sha256')), None)
    if replacement is None:
        raise ValueError('The recorded replacement cannot be identified for safe recovery.')
    with tempfile.TemporaryDirectory(prefix='cilex-recovery-') as temp:
        package = Path(temp).resolve()
        shutil.copytree(replacement, package / manifest['app'], symlinks=True)
        install.execute(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(previous)], timeout=120)
        admission = install.security_check(package, manifest, options)
        with install.installation_lock(target):
            install.assert_authorized(target, options)
            if install.digest(json.loads(install.checked_private_file(record).read_text())) != install.digest(state):
                raise ValueError('The recovery record changed while the dialog was open; retry recovery.')
            install.reject_other_incomplete_transactions(target, state['run_id'])
            result = install.reconcile_transaction(target, manifest, options, {
                'run_id': state['run_id'], 'package_sha256': state.get('package_sha256'),
                'package_root': str(package), 'security_admission': admission}, record)
    if not result or result.get('rollback') != 'FilesAndProcessStateRestored_RuntimeUnverified':
        failure = (result or {}).get('rollback_failure') or (result or {}).get('reason') or 'Recovery did not finish.'
        raise ValueError(str(failure) + '\nDetails: ' + str(record))
    if state['before']['loaded'] and state.get('previous_processes'):
        first_launch.activate(target)
    dialog(text('The previous Watchtower version and startup state were restored. Open the app inside the DMG again when you want to retry Update.',
                'Прежняя версия Watchtower и состояние запуска восстановлены. Для повторного обновления снова откройте приложение внутри DMG.'))
    return True


def update(volume):
    target = installed_target()
    if target is None:
        dialog(text('To install, drag Cilex Watchtower onto Applications in this window. Then eject the DMG and open Watchtower from Applications.',
                    'Для установки перетащите Cilex Watchtower в Applications в этом окне. Затем извлеките DMG и откройте Watchtower из Applications.'))
        return 0
    # Share the normal Finder-launch lock, including consent and final activation.
    with first_launch.launch_lock(target):
        if recover_interrupted(target):
            return 0
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
