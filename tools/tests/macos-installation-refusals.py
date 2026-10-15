#!/usr/bin/env python3
"""Isolated native refusal evidence; never target the selected installation."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import pwd
import shutil
import stat
import subprocess
import sys
import time


def sha256(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def file_state(path):
    path = Path(path)
    if not path.exists():
        return {'exists': False}
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode):
        raise RuntimeError('Expected a regular protected evidence input: ' + str(path))
    return {'exists': True, 'sha256': sha256(path), 'mode': stat.S_IMODE(info.st_mode),
            'uid': info.st_uid, 'gid': info.st_gid, 'size': info.st_size}


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n')
    path.chmod(0o600)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--helper-source', required=True)
    parser.add_argument('--setup', required=True)
    parser.add_argument('--setup-sha256', required=True)
    parser.add_argument('--package', required=True)
    parser.add_argument('--package-sha256', required=True)
    parser.add_argument('--package-root', required=True)
    parser.add_argument('--manifest-sha256', required=True)
    parser.add_argument('--selected-install-dir', required=True)
    parser.add_argument('--evidence-dir', required=True)
    args = parser.parse_args()
    sys.path.insert(0, args.helper_source)
    import install
    import runtime
    if sys.platform != 'darwin' or os.geteuid() == 0:
        raise RuntimeError('Run as the intended desktop account on macOS.')
    account = pwd.getpwuid(os.geteuid())
    setup, package, package_root = map(Path, (args.setup, args.package, args.package_root))
    for path, expected in ((setup, args.setup_sha256), (package, args.package_sha256),
                           (package_root / 'artifact-manifest.json', args.manifest_sha256)):
        if sha256(path) != expected:
            raise RuntimeError('Candidate input hash mismatch: ' + str(path))
    evidence = Path(args.evidence_dir)
    if not evidence.is_absolute() or evidence.exists():
        raise RuntimeError('Use a new absolute evidence directory.')
    evidence.mkdir(mode=0o700)
    if evidence.resolve() != evidence:
        raise RuntimeError('Use a canonical evidence directory without symlink ancestors.')
    selected = install.resolve_target({'scope': 'user', 'desktop_user': account.pw_name,
                                       'install_dir': args.selected_install_dir})
    selected_executable = selected['path'] / 'Contents/MacOS/watchtower'
    tracked_files = [selected['agent'], selected['support'] / 'receipt.json', selected_executable]
    tracked_files.extend(install.configuration_paths(selected))

    def snapshot():
        process_paths = {str(selected_executable), str(selected['path'] / 'Contents/Resources/warden/cilex-warden')}
        return {'files': {str(p): file_state(p) for p in tracked_files},
                'job': install.job_state(selected),
                'processes': sorted([p for p in runtime.process_snapshot() if p['path'] in process_paths], key=lambda p: p['pid']),
                'cilex_handler': install.registration_snapshot()}

    env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': account.pw_dir,
           'USER': account.pw_name, 'LOGNAME': account.pw_name, 'LANG': 'en_US.UTF-8'}
    common = [str(setup), '--mode', 'install', '--desktop-user', account.pw_name,
              '--scope', 'user', '--startup', 'after-sign-in', '--dependencies', 'offline',
              '--allow-development', 'yes', '--noninteractive', 'yes']
    rows = []

    def attempt(name, package_args, parent_mode, language, expected_id):
        row_dir = evidence / name
        row_dir.mkdir(mode=0o700)
        parent = row_dir / 'Каталог приложения с пробелами'
        parent.mkdir(mode=parent_mode)
        parent.chmod(parent_mode)
        destination = parent / 'watchtower.app'
        fixture_target = install.resolve_target({'scope': 'user', 'desktop_user': account.pw_name,
                                                'install_dir': str(destination)})
        if fixture_target['id'] == selected['id'] or fixture_target['support'].exists() or fixture_target['agent'].exists():
            raise RuntimeError('Fixture isolation cannot be proven.')
        before = snapshot()
        write(row_dir / 'before.json', before)
        argv = common + package_args + ['--install-dir', str(destination), '--language', language,
                '--work-dir', str(row_dir / 'work'), '--cache-dir', str(row_dir / 'cache'),
                '--output-dir', str(row_dir / 'output')]
        started = time.monotonic()
        try:
            proc = subprocess.run(argv, env=env, stdin=subprocess.DEVNULL,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120, check=False)
        finally:
            parent.chmod(0o700)
        elapsed = round(time.monotonic() - started, 3)
        (row_dir / 'stdout.json').write_bytes(proc.stdout)
        (row_dir / 'stderr.txt').write_bytes(proc.stderr)
        for path in (row_dir / 'stdout.json', row_dir / 'stderr.txt'):
            path.chmod(0o600)
        value = json.loads(proc.stdout)
        after = snapshot()
        write(row_dir / 'after.json', after)
        finding_ids = [item['id'] for item in value.get('findings', [])]
        unchanged = before == after
        no_fixture_mutation = not destination.exists() and not fixture_target['support'].exists() and not fixture_target['agent'].exists()
        passed = proc.returncode != 0 and not value.get('full_success') and expected_id in finding_ids and unchanged and no_fixture_mutation
        row = {'test': name, 'status': 'passed' if passed else 'failed', 'exit_code': proc.returncode,
               'finding_ids': finding_ids, 'expected_finding': expected_id, 'elapsed_seconds': elapsed,
               'language': language, 'offline_requested': True,
               'selected_lifecycle_and_configuration_unchanged': unchanged,
               'selected_process_count': len(after['processes']),
               'no_fixture_application_agent_or_installation_record_created': no_fixture_mutation,
               'destination': str(destination), 'command': argv,
               'evidence': [str(row_dir / name) for name in ('before.json', 'after.json', 'stdout.json', 'stderr.txt')]}
        write(row_dir / 'result.json', row)
        rows.append(row)

    corrupted = evidence / 'corrupted-package.tar.gz'
    shutil.copyfile(package, corrupted)
    corrupted.chmod(0o600)
    with corrupted.open('r+b') as stream:
        stream.seek(128)
        original = stream.read(1)
        stream.seek(128)
        stream.write(bytes([original[0] ^ 1]))
    if sha256(corrupted) == args.package_sha256:
        raise RuntimeError('Corruption fixture did not change package identity.')
    attempt('corrupt-package', ['--package', str(corrupted), '--package-sha256', args.package_sha256],
            0o700, 'en', 'package.hash')
    attempt('unwritable-destination', ['--package', str(package_root), '--package-manifest-sha256', args.manifest_sha256],
            0o500, 'ru', 'authorization.destination')
    result = {'schema_version': 1, 'created_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'status': 'passed' if all(row['status'] == 'passed' for row in rows) else 'failed',
              'candidate': {'setup_sha256': args.setup_sha256, 'package_sha256': args.package_sha256,
                            'manifest_sha256': args.manifest_sha256},
              'scope': 'Native frozen Setup refusals in newly owned isolated destinations; selected installation read only.',
              'network': 'Offline requested; no dependency operation, backend authentication or production security admission used. Packet-level no-network verification was not performed.',
              'destructive_or_lifecycle_actions_against_selected_installation': False,
              'tests': rows}
    write(evidence / 'result.json', result)
    print(json.dumps({'status': result['status'], 'tests': [{k: row[k] for k in ('test', 'status', 'finding_ids', 'elapsed_seconds', 'selected_lifecycle_and_configuration_unchanged')} for row in rows], 'evidence': str(evidence / 'result.json')}, indent=2))
    return 0 if result['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
