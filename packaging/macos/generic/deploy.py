#!/usr/bin/env python3
"""Versioned macOS controller. Inspection paths never provision or repair."""
from __future__ import annotations

import argparse
import ctypes
import json
import os
from pathlib import Path
import platform
import plistlib
import pwd
import re
import shutil
import sys
import time
import urllib.parse

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import (DeployError, EXITS, VERSION, RunRecord, atomic_json, command,
                    digest, helper_hash, host_identity, private_dir, read_json,
                    redact, result, sha256, utc)
import source
import install
import remote
import build

ROOT = Path(__file__).resolve().parent
MODES = ('check', 'build', 'install', 'remote-install', 'build-installer', 'verify', 'uninstall')


def parser():
    p = argparse.ArgumentParser(add_help=False, description='Cilex Watchtower macOS deployment / Развёртывание для macOS')
    p.add_argument('--mode', choices=MODES, default='check')
    p.add_argument('--repository', default=source.DEFAULT_REPOSITORY)
    p.add_argument('--tag')
    auth = p.add_mutually_exclusive_group()
    auth.add_argument('--gh-token-fd', type=int)
    auth.add_argument('--gh-token-prompt', choices=('yes', 'no'), default='no')
    auth.add_argument('--gh-keychain-service')
    p.add_argument('--gh-keychain-account')
    p.add_argument('--package')
    p.add_argument('--package-sha256')
    p.add_argument('--package-manifest-sha256')
    p.add_argument('--scope', choices=('user', 'machine'), default='user')
    p.add_argument('--install-dir')
    p.add_argument('--desktop-user')
    p.add_argument('--target-host')
    p.add_argument('--ssh-user')
    p.add_argument('--expected-target-id')
    p.add_argument('--ssh-known-hosts')
    p.add_argument('--ssh-identity-file')
    p.add_argument('--ssh-use-agent', '--ssh-agent', dest='ssh_agent', choices=('yes', 'no'), default='no')
    p.add_argument('--ssh-port', type=int, default=22)
    p.add_argument('--remote-timeout', type=int, default=600)
    p.add_argument('--startup', choices=('after-sign-in', 'unattended-reboot'), default='after-sign-in')
    p.add_argument('--backend-url')
    p.add_argument('--dependencies', choices=('auto', 'manual', 'offline'), default='manual')
    p.add_argument('--cache-dir', default=str(Path.home() / 'Library/Caches/CilexWatchtower/Deploy'))
    p.add_argument('--work-dir', default=str(Path.home() / 'Library/Application Support/CilexWatchtower/DeploymentRuns'))
    p.add_argument('--output-dir', default=str(Path.home() / 'Downloads/CilexInstallers'))
    p.add_argument('--jobs', type=int)
    p.add_argument('--language', choices=('auto', 'en', 'ru'), default='auto')
    p.add_argument('--accept-findings', default='')
    p.add_argument('--accept-licenses', choices=('yes', 'no'), default='no')
    p.add_argument('--license-manifest', help='Reviewed component/notice/source mapping for this exact build context')
    p.add_argument('--noninteractive', choices=('yes', 'no'), default='no')
    p.add_argument('--dry-run', choices=('yes', 'no'), default='no')
    p.add_argument('--resume', metavar='RUN-ID')
    p.add_argument('--tools-json')
    p.add_argument('--python')
    p.add_argument('--source-archive')
    p.add_argument('--source-sha256')
    p.add_argument('--source-commit')
    p.add_argument('--source-dirty-tree', choices=('yes', 'no'), default='no')
    p.add_argument('--development', choices=('yes', 'no'), default='no')
    p.add_argument('--allow-development', choices=('yes', 'no'), default='no')
    p.add_argument('--signing-identity')
    p.add_argument('--notary-profile')
    p.add_argument('--deployment-target', default='14.4')
    p.add_argument('--observe-seconds', type=int, default=0)
    p.add_argument('--expected-cameras', type=int)
    p.add_argument('--remote-request', help=argparse.SUPPRESS)
    p.add_argument('--remote-run-id', help=argparse.SUPPRESS)
    p.add_argument('--result-file', help=argparse.SUPPRESS)
    p.add_argument('--ssh-control-path', help=argparse.SUPPRESS)
    return p


def preferred_language(options, standalone=False):
    if options.get('language') in ('ru', 'en'):
        return options['language']
    home = Path.home()
    if standalone or os.geteuid() == 0:
        try:
            home = install.resolve_target(options)['home']
        except DeployError:
            return 'en'
    path = home / 'Library/Preferences/.GlobalPreferences.plist'
    try:
        with path.open('rb') as stream:
            languages = plistlib.load(stream).get('AppleLanguages', [])
        return 'ru' if languages and languages[0].split('-')[0].lower() == 'ru' else 'en'
    except (OSError, ValueError, plistlib.InvalidFileException):
        return 'en'


def text_for(key, language):
    try:
        return read_json(ROOT / 'i18n' / (language + '.json'))[key]
    except (OSError, KeyError, ValueError):
        return key


def normalize(args):
    options = vars(args).copy()
    for key in ('gh_token_prompt', 'ssh_agent', 'accept_licenses', 'noninteractive', 'dry_run',
                'source_dirty_tree', 'development', 'allow_development'):
        options[key] = options[key] == 'yes'
    options['arch'] = 'arm64'
    options['language'] = preferred_language(options)
    options['accept_findings'] = sorted(set(x.strip() for x in options['accept_findings'].split(',') if x.strip()))
    options['accepted_findings'] = options['accept_findings']
    supported = {x['id'] for x in read_json(ROOT / 'manifests/requirements.json')['findings'] if x['overridable']}
    bad = set(options['accept_findings']) - supported
    if bad:
        raise DeployError('override.forbidden', 'Unknown or non-overridable finding IDs; remove them from --accept-findings.', 'security',
                          ru='Неизвестные или обязательные проверки нельзя обойти; удалите эти ID из --accept-findings.', details={'ids': sorted(bad)})
    if options['arch'] != 'arm64':
        raise DeployError('runtime.architecture', 'Only native arm64 is implemented; use an Apple silicon Mac.', 'requirements',
                          ru='Реализована только arm64; используйте Mac с Apple silicon.')
    if options['jobs'] is not None and not 1 <= options['jobs'] <= 64:
        raise DeployError('build.jobs', '--jobs must be between 1 and 64.', 'usage', ru='--jobs должен быть от 1 до 64.')
    if (options['observe_seconds'] != 0 and not 150 <= options['observe_seconds'] <= 3600) or (options['expected_cameras'] is not None and options['expected_cameras'] < 1):
        raise DeployError('verification.inputs', 'Use observation seconds 0–3600 and a positive expected camera count.', 'usage',
                          ru='Укажите 0–3600 секунд наблюдения и положительное число камер.')
    source.validate_repository(options['repository'])
    if options['mode'] == 'build' and options['package']:
        raise DeployError('mode.package', 'Use build-installer or install with an existing --package; build requires source inputs.', 'usage',
                          ru='Для готового --package используйте install или build-installer; режим build требует исходный код.')
    if options['backend_url']:
        url = urllib.parse.urlsplit(options['backend_url'])
        if url.scheme not in ('http', 'https') or not url.hostname or url.username or url.password or url.query or url.fragment:
            raise DeployError('backend.url', 'Use an HTTP(S) backend URL without embedded credentials or query parameters.', 'usage',
                              ru='Укажите HTTP(S) адрес сервера без пароля, токена и параметров запроса.')
    for key in ('package', 'cache_dir', 'work_dir', 'output_dir', 'tools_json', 'source_archive', 'python', 'ssh_identity_file', 'ssh_known_hosts', 'license_manifest'):
        if options.get(key):
            options[key] = str(Path(options[key]).expanduser().absolute())
    if options['install_dir'] and not Path(options['install_dir']).is_absolute():
        raise DeployError('target.path', '--install-dir must be an absolute target-local path.', 'usage', ru='--install-dir должен быть абсолютным путём на целевом Mac.')
    return options


def sysctl(name):
    return command(['/usr/sbin/sysctl', '-n', name], check=False).stdout.strip()


def nearest_existing(path):
    path = Path(path)
    while not path.exists() and path != path.parent:
        path = path.parent
    return path


def build_space(options):
    budget = read_json(ROOT / 'manifests/requirements.json')['build_host']['space_budget']
    groups = {}
    for key, parts in (('cache_dir', ('download_bytes',)), ('work_dir', ('extraction_bytes', 'compile_bytes')), ('output_dir', ('artifact_bytes',))):
        ancestor = nearest_existing(options[key])
        device = str(ancestor.stat().st_dev)
        item = groups.setdefault(device, {'required_bytes': budget['reserve_bytes'], 'free_bytes': shutil.disk_usage(ancestor).free, 'paths': [], 'status': budget['status']})
        item['required_bytes'] += sum(budget[p] for p in parts)
        item['paths'].append(options[key])
    return list(groups.values())


def assessment(options):
    value = result()
    value.update(mode=options['mode'], dry_run=options['dry_run'], target=host_identity(),
                 language=options['language'], accepted_findings=options['accept_findings'])
    if platform.system() != 'Darwin':
        raise DeployError('host.macos', 'Run this workflow on macOS; no changes were made.', 'requirements', ru='Запустите инструмент в macOS; изменений нет.')
    native, translated = sysctl('hw.optional.arm64') == '1', sysctl('sysctl.proc_translated') == '1'
    memory = int(sysctl('hw.memsize') or '0')
    host = {'macos': platform.mac_ver()[0], 'build': command(['/usr/bin/sw_vers', '-buildVersion']).stdout.strip(),
            'native_architecture': 'arm64' if native else 'x86_64', 'translated': translated,
            'cpus': int(sysctl('hw.ncpu') or '0'), 'physical_memory_bytes': memory,
            'storage_free_bytes': {key: shutil.disk_usage(nearest_existing(options[key])).free for key in ('cache_dir', 'work_dir', 'output_dir')},
            'graphics': 'WorkloadUnmeasured', 'required_apis': {}}
    # Loading a framework checks API presence without creating a decoder/session.
    for framework, symbol in (('VideoToolbox', 'VTDecompressionSessionCreate'), ('Metal', 'MTLCreateSystemDefaultDevice'), ('CoreServices', 'LSRegisterURL')):
        try:
            library = ctypes.CDLL('/System/Library/Frameworks/' + framework + '.framework/' + framework)
            getattr(library, symbol)
            host['required_apis'][symbol] = 'Present'
        except (OSError, AttributeError):
            host['required_apis'][symbol] = 'Missing'
    value['assessment'] = host
    def finding(identifier, en, ru, fatal=False):
        value['findings'].append({'id': identifier, 'severity': 'fatal' if fatal else 'advisory',
                                  'accepted': identifier in options['accept_findings'],
                                  'message': ru if options['language'] == 'ru' else en})
    if not native or translated:
        finding('runtime.architecture', 'Native arm64 is required; use a native Apple silicon session.', 'Нужна arm64 без Rosetta; запустите нативную сессию Apple silicon.', True)
    if 'Missing' in host['required_apis'].values():
        finding('runtime.required-api', 'A required system API is missing; use a compatible macOS version.', 'Нет обязательного системного API; используйте совместимую версию macOS.', True)
    if memory < 8 * 1024**3:
        finding('build.memory-advisory', 'Memory is below the provisional 8 GiB recommendation; reduce build jobs.', 'Память ниже предварительной рекомендации 8 ГиБ; уменьшите число задач сборки.')
    finding('runtime.capacity-unmeasured', 'Camera workload capacity is unmeasured; validate the intended feeds on this Mac.', 'Ёмкость видеостены не измерена; проверьте нужные потоки на этом Mac.')
    try:
        if options['mode'] == 'remote-install':
            # Only validate local SSH inputs; no probe/transfer in dry-run.
            remote.ssh_options(options)
            value['installation_target'] = {'host': options['target_host'], 'desktop_user': options['desktop_user'],
                                             'path': options.get('install_dir'), 'state': 'TargetNotContacted'}
        else:
            target = install.resolve_target(options)
            value['installation_target'] = {k: str(target[k]) if isinstance(target[k], Path) else target[k] for k in ('path', 'user', 'uid', 'id', 'domain')}
            value['existing_installation'] = install.verify(options)
            value['startup_evidence'] = value['existing_installation'].get('startup_evidence', {})
            value['states']['startup'] = value['existing_installation'].get('startup', 'StartupUnverified')
    except DeployError as exc:
        finding(exc.finding, exc.message, exc.ru, True)
    if options['mode'] in ('check', 'build', 'build-installer') or (options['mode'] == 'install' and not options['package']):
        import dependencies
        value['dependency_plan'] = dependencies.assess(options)
        value['build_space_plan'] = build_space(options)
        if any(row['free_bytes'] < row['required_bytes'] for row in value['build_space_plan']):
            finding('transaction.space', 'Insufficient storage for the complete build plan; free space before building.', 'Недостаточно места для полного плана сборки; освободите место до запуска.', True)
    value['states']['installation'] = 'AssessmentOnly'
    if value['states']['startup'] == 'Unverified':
        value['states']['startup'] = 'StartupUnverified'
    value['finished_at'] = utc()
    return value


def merge_result(target, detail):
    for key in target['states']:
        if key in detail:
            previous = target['states'][key]
            if previous.startswith(('Pending', 'Blocked')) and detail[key] in ('Unverified', 'StartupUnverified'):
                continue
            target['states'][key] = detail[key]
    for key, item in detail.items():
        if key not in target['states']:
            if key in ('schema_version', 'run_id', 'started_at', 'finished_at', 'target', 'accepted_findings'):
                continue
            if key == 'evidence':
                target['evidence'].extend(item)
            elif key == 'findings':
                target['findings'].extend(item)
            else:
                target[key] = item


def package_root(options, record):
    path = Path(options['package'])
    if path.is_dir():
        expected = options.get('package_manifest_sha256')
        if not re.fullmatch('[a-fA-F0-9]{64}', expected or '') or sha256(path / 'artifact-manifest.json') != expected.lower():
            raise DeployError('package.trust', 'An extracted package needs a separately trusted --package-manifest-sha256; use the tar package with --package-sha256 instead.', 'integrity',
                              ru='Для распакованного пакета нужен доверенный --package-manifest-sha256; либо укажите архив с --package-sha256.')
        install.verify_inventory(path, install.read_manifest(path))
        return path
    expected = options.get('package_sha256')
    if not re.fullmatch('[a-fA-F0-9]{64}', expected or ''):
        raise DeployError('package.trust', 'Supply --package-sha256 from a trusted channel before installation.', 'integrity',
                          ru='До установки укажите --package-sha256, полученный из доверенного источника.')
    destination = record.root / 'extracted-package'
    if destination.exists():
        if record.data.get('extracted_package_sha256') != expected or sha256(path) != expected.lower():
            raise DeployError('package.resume', 'The staged package lacks matching verified state; preserve it and start a new run.', 'integrity')
        install.verify_inventory(destination, install.read_manifest(destination))
    else:
        destination.mkdir(mode=0o700)
        install.safe_extract(path, destination, expected_sha256=expected)
        record.data['extracted_package_sha256'] = expected
        record.save()
    return destination


def exit_for(value, mode):
    states = value['states']
    if states['rollback'] == 'Failed': return EXITS['rollback']
    if states['installation'] == 'Failed': return EXITS['installation']
    if states['installation'] == 'Unknown': return EXITS['unknown']
    if any(str(states[k]).startswith('Failed') for k in ('runtime_health', 'gui_video', 'backend', 'security_admission', 'recovery', 'startup')):
        return EXITS['verification']
    if any(isinstance(x, dict) and x.get('severity') == 'fatal' for x in value.get('findings', [])): return EXITS['requirements']
    if mode in ('check',) or value.get('dry_run'):
        return EXITS['pending'] if value.get('dependency_plan', {}).get('missing') else 0
    if mode in ('build', 'build-installer'):
        return 0 if value.get('artifacts') else EXITS['build']
    if mode == 'uninstall': return 0 if states['installation'] == 'Uninstalled' else EXITS['verification']
    # Registration, a process, or copied files are never full runtime acceptance.
    return 0 if all(states[k] == 'Passed' for k in ('runtime_health', 'gui_video', 'backend', 'security_admission', 'recovery', 'startup')) else EXITS['pending']


def remote_handler(options):
    remote_options, context, request = remote.load_request(options['remote_request'], options['remote_run_id'], options['result_file'])
    try:
        detail = install.run(remote_options, context)
    except DeployError as exc:
        detail = {'installation': 'Failed', 'full_success': False, 'original_failure': {'finding': exc.finding, 'message': exc.ru if remote_options.get('language') == 'ru' else exc.message}}
    remote.save_result(options['result_file'], request, detail)
    value = result(request['run_id'])
    merge_result(value, detail)
    return value


def setup_package_root(require_manifest=True):
    """Locate this Setup's package, including Finder's isolated app launch.

    Apple exposes the original location through its stock security tool. Only
    that mapping is used; never guess another mounted volume or strip quarantine.
    """
    executable = Path(sys.executable).resolve()
    bundle = executable.parents[2]
    package = bundle.parent
    marker = 'artifact-manifest.json' if require_manifest else 'helpers'
    if (package / marker).exists():
        return package
    reply = command(['/usr/bin/security', 'translocate-original-path', str(bundle)],
                    check=False, timeout=15)
    # security prints one explanation followed by a tab-indented absolute path.
    paths = [line[1:] for line in reply.stdout.splitlines() if line.startswith('\t/')]
    if reply.returncode == 0 and len(paths) == 1:
        original = Path(paths[0])
        original_executable = original / 'Contents/MacOS' / executable.name
        if (original.name == bundle.name and original.suffix == '.app'
                and (original.parent / marker).exists()
                and original_executable.is_file() and sha256(original_executable) == sha256(executable)):
            return original.parent.resolve()
    raise DeployError('package.location',
        'Setup cannot find the complete installation package. Open the Watchtower DMG and run Setup.app from inside it. Do not copy Setup.app out on its own.',
        'requirements',
        ru='Установщик не нашёл полный комплект файлов. Откройте DMG Watchtower и запустите Setup.app внутри него. Не копируйте отдельно только Setup.app.')


def helper_source_root():
    if getattr(sys, 'frozen', False):
        candidate = setup_package_root(require_manifest=False) / 'helpers'
        if candidate.is_dir():
            return candidate
    return ROOT


def save_run_result(record, value):
    path = record.root / 'result.json'
    if path.exists():
        index = 1
        while (record.root / ('result-attempt-%04d.json' % index)).exists():
            index += 1
        if index > 100:
            raise DeployError('run.result_limit', 'This run reached its retained-result limit; archive its evidence before starting a new run.', 'unknown')
        previous = record.root / ('result-attempt-%04d.json' % index)
        os.rename(path, previous)
        if value.get('historical_result') == str(path): value['historical_result'] = str(previous)
    atomic_json(path, value)


def verify_prior_artifacts(value):
    artifacts = value.get('artifacts', {})
    for item in (artifacts, *artifacts.values()):
        if not isinstance(item, dict): continue
        path = item.get('package') or item.get('installer') or item.get('bootstrap')
        if path and (not Path(path).is_file() or sha256(path) != item.get('sha256')):
            raise DeployError('resume.artifact_changed', 'A recorded artifact is missing or changed; do not reuse the previous result.', 'integrity')


def execute(options):
    if options.get('remote_request'):
        return remote_handler(options), None
    if options['mode'] == 'check' or options['dry_run']:
        return assessment(options), None
    if options['mode'] == 'verify':
        value = result()
        value.update(mode='verify', target=host_identity())
        merge_result(value, install.verify(options))
        import runtime
        merge_result(value, runtime.verify(options, {}))
        return value, None
    if platform.system() != 'Darwin':
        raise DeployError('host.macos', 'Build and installation require macOS.', 'requirements')
    # Secret-bearing channels are never serialized or copied to the target.
    public_options = {k: v for k, v in options.items() if k not in ('resume', 'gh_token_fd', 'gh_token_prompt', 'gh_keychain_service', 'gh_keychain_account', 'remote_request', 'remote_run_id', 'result_file', 'ssh_control_path')}
    identity = host_identity()
    if not identity.get('machine_id'):
        raise DeployError('target.identity', 'Stable target identity is unavailable; deployment and resume cannot be safely bound to this Mac.', 'requirements',
                          ru='Не удалось определить стабильный ID Mac; безопасная привязка установки и возобновления невозможна.')
    record = RunRecord(options['work_dir'], public_options, identity, helper_hash(helper_source_root()), options.get('resume'))
    value = result(record.data['run_id'])
    value.update(mode=options['mode'], target=host_identity(), accepted_findings=options['accept_findings'])
    value['evidence'].append(str(record.root / 'journal.json'))
    try:
        if record.data.get('phase') == 'complete' and (record.root / 'result.json').is_file() and options['mode'] != 'remote-install':
            stored = read_json(record.root / 'result.json')
            if digest(stored) != record.data.get('result_sha256'):
                raise DeployError('resume.result', 'Previous result changed; do not reuse it.', 'integrity')
            verify_prior_artifacts(stored)
            if options['mode'] == 'uninstall':
                merge_result(value, install.uninstall(options, {'run_id': record.data['run_id']}))
                value['historical_result'] = str(record.root / 'result.json')
                value['resume_action'] = 'UninstallJournalAndCurrentAbsenceReconciled'
            elif options['mode'] == 'install':
                merge_result(value, install.verify(options))
                import runtime
                merge_result(value, runtime.verify(options, {}))
                value['historical_result'] = str(record.root / 'result.json')
                value['resume_action'] = 'CurrentInstallationInspectedWithoutRepair'
            else:
                value = stored
                value['resume_action'] = 'RecordedArtifactHashesReverified'
            value['resumed_at'] = utc()
        elif options['mode'] == 'remote-install':
            merge_result(value, remote.run(options, record))
        elif options['mode'] == 'uninstall':
            merge_result(value, install.uninstall(options, {'run_id': record.data['run_id']}))
        else:
            if options['package']:
                package = package_root(options, record)
            else:
                import dependencies
                space = build_space(options)
                if any(row['free_bytes'] < row['required_bytes'] for row in space):
                    raise DeployError('transaction.space', 'Insufficient storage for downloads, extraction, build, artifacts and reserve; free space before retrying.', 'requirements',
                                      ru='Недостаточно места для загрузки, распаковки, сборки и резерва; освободите место перед повтором.', details={'space_plan': space})
                plan = dependencies.assess(options)
                if not options.get('quiet'):
                    print(json.dumps({'dependency_plan': plan, 'language': options['language']}, ensure_ascii=False), file=sys.stderr)
                else:
                    print('Checking build tools and libraries.', flush=True)
                record.phase('dependencies')
                resolved = dependencies.resolve(options, record.root)
                options['tools'], options['dependency_receipts'] = resolved['tools'], resolved['receipts']
                record.phase('source')
                provenance_path = record.root / 'source-provenance.json'
                if provenance_path.exists() and sha256(provenance_path) != record.data.get('source_provenance_sha256'):
                    raise DeployError('source.resume_binding', 'Pinned source provenance is not authenticated by this run; preserve it and start a new run.', 'integrity')
                tree, provenance = source.obtain(options, record.root, git=options['tools'].get('git', '/usr/bin/git'), log=record.root / 'source.log')
                record.data['source_provenance_sha256'] = sha256(provenance_path)
                record.save()
                options['source'], options['helper_root'] = provenance, str(helper_source_root())
                record.phase('build')
                if options.get('quiet'):
                    print('Compiling Watchtower and packaging its libraries. This can take several minutes.', flush=True)
                built = build.build(tree, options, record.root)
                package = Path(built['package_root'])
                options['package_sha256'] = built['sha256']
                value['artifacts'] = {k: v for k, v in built.items() if k != 'manifest'}
                value['source'] = provenance
                value['versions'] = {'watchtower': built['manifest']['version'], 'warden': built['manifest']['warden_version']}
                value['states']['installation'] = 'ArtifactBuilt'
                record.phase('built', package=str(package), package_sha256=built['sha256'])
            if options['mode'] == 'build-installer':
                if options.get('quiet'):
                    print('Creating and checking the DMG.', flush=True)
                value.setdefault('artifacts', {})['installer'] = build.build_installer(package, options, record.root)
                if options.get('bootstrap', True):
                    value['artifacts']['bootstrap'] = build.build_bootstrap(package, options, record.root)
            elif options['mode'] == 'install':
                record.phase('install')
                merge_result(value, install.run(options, {'package_root': str(package), 'package_sha256': options.get('package_sha256'), 'run_id': record.data['run_id']}))
                if value['states']['installation'] == 'Installed' and not value.get('runtime_observation'):
                    import runtime
                    evidence = private_dir(record.root / 'runtime')
                    merge_result(value, runtime.verify(options, {'write_evidence': True, 'evidence_dir': str(evidence), 'run_id': record.data['run_id']}))
        value['finished_at'] = utc()
        value['exit_code'] = exit_for(value, options['mode'])
        value['full_success'] = value['exit_code'] == 0 and options['mode'] in ('install', 'remote-install', 'verify')
        save_run_result(record, value)
        phase = 'needs-reconciliation' if value['states']['rollback'] == 'Failed' or value['states']['installation'] in ('Failed', 'Unknown') else 'complete'
        record.phase(phase, exit_code=value['exit_code'])
        record.data['result_sha256'] = digest(value)
        record.save()
        return value, record
    except BaseException as exc:
        if isinstance(exc, (KeyboardInterrupt, SystemExit)):
            code, finding, message = EXITS['unknown'], 'run.interrupted', text_for('interrupted', options['language'])
        else:
            code, finding = getattr(exc, 'code', EXITS['build']), getattr(exc, 'finding', 'operation.failed')
            message = getattr(exc, 'ru', str(exc)) if options['language'] == 'ru' else str(exc)
        value['findings'].append({'id': finding, 'severity': 'fatal', 'message': redact(message)})
        value.update(finished_at=utc(), exit_code=code, full_success=False)
        save_run_result(record, value)
        record.phase('failed', finding=finding, exit_code=code)
        return value, record


def setup_dialog():
    """Explicit local setup action when launched from Finder; no elevation."""
    options = vars(parser().parse_args([]))
    language = preferred_language(options, standalone=True)
    package = setup_package_root()
    manifest = install.read_manifest(package)
    message = text_for('setup_install', language)
    if manifest.get('distribution') == 'development':
        message += '\n\n' + text_for('development', language)
    # User-readable text is an argv value, never interpolated executable code.
    script = 'function run(a) { var app=Application.currentApplication(); app.includeStandardAdditions=true; try { return app.displayDialog(a[0], {buttons:[a[1],a[2]], defaultButton:a[2], cancelButton:a[1]}).buttonReturned; } catch(e) { return "cancelled"; } }'
    proc = command(['/usr/bin/osascript', '-l', 'JavaScript', '-e', script, message, text_for('cancel', language), text_for('install', language)], timeout=300, check=False)
    if proc.returncode or proc.stdout.strip() != text_for('install', language):
        return None
    argv = ['--mode', 'install', '--package', str(package), '--package-manifest-sha256', sha256(package / 'artifact-manifest.json'),
            '--language', language, '--dependencies', 'offline', '--noninteractive', 'yes']
    if manifest.get('distribution') == 'development': argv += ['--allow-development', 'yes']
    return argv


def setup_result_message(value, language):
    """Finder users get an installation result without controller field names."""
    installed = value.get('states', {}).get('installation') == 'Installed'
    message = text_for('setup_installed' if installed else 'setup_not_confirmed', language)
    if installed and value.get('exit_code'):
        message += '\n\n' + text_for('setup_checks_pending', language)
    messages = [row.get('message', '') for row in value.get('findings', [])]
    if value.get('original_failure', {}).get('message'):
        messages.append(value['original_failure']['message'])
    if any(messages):
        message += '\n\n' + '\n'.join(messages)
    if value.get('evidence'):
        message += '\n\n' + text_for('setup_details', language) + '\n' + value['evidence'][0]
    return message


def main(argv=None):
    gui = argv is None and len(sys.argv) == 1 and getattr(sys, 'frozen', False)
    language = 'en'
    raw = list(sys.argv[1:] if argv is None else argv)
    if raw == ['help']:
        parser().print_help()
        return 0
    if raw == ['version']:
        print(VERSION)
        return 0
    try:
        if gui:
            argv = setup_dialog()
            if argv is None: return EXITS['pending']
        args = parser().parse_args(argv)
        language = preferred_language(vars(args))
        options = normalize(args)
        language = options['language']
        value, record = execute(options)
        if not value.get('finished_at'): value['finished_at'] = utc()
        value.setdefault('exit_code', exit_for(value, options['mode']))
        value.setdefault('full_success', False)
        code = value['exit_code']
    except DeployError as exc:
        value = result()
        value.update(finished_at=utc(), exit_code=exc.code, full_success=False)
        value['findings'] = [{'id': exc.finding, 'severity': 'fatal', 'message': redact(exc.ru if language == 'ru' else exc.message), 'details': exc.details}]
        code = exc.code
    except (OSError, ValueError) as exc:
        value = result()
        value.update(finished_at=utc(), exit_code=EXITS['requirements'], full_success=False)
        value['findings'] = [{'id': 'input.invalid', 'severity': 'fatal', 'message': redact(exc)}]
        code = EXITS['requirements']
    print(json.dumps(value, ensure_ascii=False, indent=2, default=str))
    print(text_for('completed' if code == 0 else 'incomplete', language) + ' (' + str(code) + ')', file=sys.stderr)
    if gui:
        script = 'function run(a) { var app=Application.currentApplication(); app.includeStandardAdditions=true; app.displayDialog(a[0], {buttons:["OK"],defaultButton:"OK"}); }'
        command(['/usr/bin/osascript', '-l', 'JavaScript', '-e', script,
                 setup_result_message(value, language)], timeout=300, check=False)
    return code


if __name__ == '__main__':
    raise SystemExit(main())
