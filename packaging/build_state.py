"""Shared committed-source preflight and successful-build receipts.

No compiler, install, service or publication actions. A receipt is written only
after the caller's build checks succeed. Source snapshots are detached worktrees;
the operator's edits are never stashed, committed, reset or copied into a build.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import re
import stat
import struct
import subprocess
import sys
import tempfile


def cache_root():
    if os.environ.get('CILEX_BUILD_STATE_DIR'):
        return Path(os.environ['CILEX_BUILD_STATE_DIR'])
    if sys.platform == 'darwin':
        return Path.home() / 'Library/Caches/CilexWatchtower/BuildState'
    if os.name == 'nt':
        return Path(os.environ['LOCALAPPDATA']) / 'CilexWatchtower/BuildState'
    return Path(os.environ.get('XDG_CACHE_HOME', Path.home() / '.cache')) / 'CilexWatchtower/BuildState'


def prepare_cache(selected=None):
    root = Path(selected or cache_root()).absolute()
    if root.is_symlink(): raise ValueError('The build-state cache must not be a symbolic link.')
    root = root.resolve()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if os.name != 'nt' and (root.stat().st_uid != os.getuid() or root.stat().st_mode & 0o022):
        raise ValueError('The build-state cache must be owned by this account and not writable by others.')
    return root


def build_settings(settings):
    if settings is not None and not isinstance(settings, dict): raise ValueError('Build settings must be an object.')
    result = dict(settings or {})
    result['_build_host'] = {'platform': sys.platform, 'machine': platform.machine(), 'python_bits': struct.calcsize('P')*8}
    return result


def git(repo, *args, check=True):
    env = dict(os.environ, GIT_TERMINAL_PROMPT='0')
    result = subprocess.run([os.environ.get('CILEX_BUILD_GIT', 'git'), '-C', str(repo), *args], capture_output=True, env=env, timeout=120)
    if check and result.returncode:
        raise ValueError('Git could not complete ' + args[0] + '. ' + git_diagnostic(result.stderr))
    return result


def git_diagnostic(raw):
    message = raw.decode('utf-8', errors='replace').strip()
    message = re.sub(r'([a-zA-Z][a-zA-Z0-9+.-]*://)[^/\s@]+@', r'\1[redacted]@', message)
    return re.sub(r'(?i)((?:access_token|token|password|authorization)=)[^\s&]+', r'\1[redacted]', message)


def git_text(repo, *args):
    return git(repo, *args).stdout.decode('utf-8', errors='replace').strip()


def names(raw):
    return [p.decode('utf-8', errors='replace') for p in raw.split(b'\0') if p]


def show_files(title, files):
    print(title + (': none.' if not files else ': ' + str(len(files)) + ' path(s).'), flush=True)
    for name in files[:50]:
        print('  ' + json.dumps(name, ensure_ascii=False), flush=True)
    if len(files) > 50:
        print('  ... and ' + str(len(files)-50) + ' more paths.', flush=True)


def local_changes(repo):
    # --normal lists untracked directories, never scans their private contents.
    raw = git(repo, 'status', '--porcelain=v1', '-z', '--untracked-files=normal').stdout
    records = raw.split(b'\0'); changed = []; statuses = []; index = 0
    while index < len(records):
        row = records[index]; index += 1
        if not row:
            continue
        changed.append(row[3:].decode('utf-8', errors='replace'))
        statuses.append(row[:2])
        if row[:1] in (b'R', b'C') or row[1:2] in (b'R', b'C'):
            index += 1
    show_files('Local changes (excluded from this committed-code build)', changed)
    if any(status in (b'UU', b'AA', b'DD', b'AU', b'UA', b'DU', b'UD') for status in statuses):
        raise ValueError('Resolve the Git conflicts before building. No files were changed by this check.')
    tracked = bool(git(repo, 'diff', '--name-only', 'HEAD').stdout)
    return changed, tracked


def select_commit(repo, revision, update):
    _, dirty = local_changes(repo)
    before = git_text(repo, 'rev-parse', 'HEAD')
    if not update:
        print('Remote updates were not requested; using the selected local commit.', flush=True)
        return git_text(repo, 'rev-parse', '--verify', '--end-of-options', revision+'^{commit}')
    upstream = git(repo, 'rev-parse', '--abbrev-ref', '@{upstream}', check=False)
    remote_ref = upstream.stdout.decode().strip() if upstream.returncode == 0 else 'origin/main'
    selected_ref = git(repo, 'rev-parse', '--symbolic-full-name', revision, check=False)
    if selected_ref.returncode == 0 and selected_ref.stdout.startswith(b'refs/remotes/'):
        remote_ref = selected_ref.stdout.decode().strip()[len('refs/remotes/'):]
    if '/' not in remote_ref:
        raise ValueError('Set a Git upstream before checking for new code, or select local-only mode.')
    remote, branch = remote_ref.split('/', 1)
    if git(repo, 'remote', 'get-url', remote, check=False).returncode:
        print('No remote is configured; using local committed code.', flush=True)
        return git_text(repo, 'rev-parse', '--verify', '--end-of-options', revision+'^{commit}')
    print('Checking the remote for new committed files...', flush=True)
    result = git(repo, 'fetch', '--no-tags', remote,
                 'refs/heads/'+branch+':refs/remotes/'+remote_ref, check=False)
    if result.returncode:
        # Never mistake a stale tracking ref for a successful update check.
        raise ValueError('Could not check remote updates. No build started. Check network/Git access, '
                         'or explicitly select local-only mode.\n'+git_diagnostic(result.stderr))
    latest = git_text(repo, 'rev-parse', remote_ref)
    changes = names(git(repo, 'diff', '--name-only', '-z', before, latest).stdout)
    show_files('Remote file differences', changes)
    if revision != 'HEAD':
        print('An explicit revision was selected; the checkout will not be pulled.', flush=True)
        return git_text(repo, 'rev-parse', '--verify', '--end-of-options', revision+'^{commit}')
    if latest == before or git(repo, 'merge-base', '--is-ancestor', latest, before, check=False).returncode == 0:
        print('No newer remote code to pull. Local committed work is retained.', flush=True)
        return before
    if git(repo, 'merge-base', '--is-ancestor', before, latest, check=False).returncode:
        raise ValueError('Local and remote history have diverged. Integrate the commits before building; no automatic rebase or reset was attempted.')
    if dirty:
        print('New remote code found. Local edits are preserved; building the fetched commit in a separate source folder.', flush=True)
        return latest
    git(repo, 'pull', '--ff-only', '--no-rebase', '--no-tags', remote, branch)
    print('Pulled the new committed files.', flush=True)
    return git_text(repo, 'rev-parse', 'HEAD')


def source_identity(repo, commit, profile):
    if profile == 'windows-warden':
        paths = ['warden', 'packaging/windows/build-warden.ps1', 'packaging/windows/BuildState.psm1', 'packaging/build_state.py']
        tree = git(repo, 'ls-tree', '-r', '-z', commit, '--', *paths).stdout
    elif profile == 'linux-qt':
        paths = ['third_party/qt-patches', 'tools/build-patched-qt', 'packaging/build_state.py', 'packaging/build-state.sh']
        tree = git(repo, 'ls-tree', '-r', '-z', commit, '--', *paths).stdout
    else:
        raw = git(repo, 'ls-tree', '-r', '-z', commit).stdout
        rows = []
        for row in raw.split(b'\0'):
            if not row: continue
            name = row.split(b'\t', 1)[1].decode('utf-8', errors='surrogateescape')
            path = Path(name)
            if path.parts[0] in ('docs','.github','.idea','.vscode','.claude','.codex'): continue
            if len(path.parts) == 1 and (path.suffix == '.md' or name == '.gitignore'): continue
            rows.append(row)
        tree = b'\0'.join(rows)
    if not tree:
        raise ValueError('The selected commit has no build inputs.')
    return hashlib.sha256(tree).hexdigest()


def file_digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024*1024), b''):
            h.update(block)
    return h.hexdigest()


def output_digest(path):
    path = Path(path)
    if path.is_symlink():
        raise ValueError('An output path is a symlink: '+str(path))
    if path.is_file():
        if not path.stat().st_size:
            raise ValueError('An output file is empty: '+str(path))
        return hashlib.sha256((str(stat.S_IMODE(path.stat().st_mode))+':'+file_digest(path)).encode()).hexdigest()
    if not path.is_dir():
        raise ValueError('Build output is missing: '+str(path))
    rows = [['.', 'directory', stat.S_IMODE(path.stat().st_mode)]]
    for item in sorted(path.rglob('*')):
        rel = item.relative_to(path).as_posix()
        if item.name == '.DS_Store':
            continue
        if item.is_symlink():
            rows.append([rel, 'link', os.readlink(item)])
        elif item.is_file():
            rows.append([rel, 'file', file_digest(item), stat.S_IMODE(item.stat().st_mode)])
        elif item.is_dir():
            rows.append([rel, 'directory', stat.S_IMODE(item.stat().st_mode)])
        else:
            raise ValueError('Unsupported build output: '+str(item))
    if not any(row[1] in ('file','link') for row in rows):
        raise ValueError('Build output directory is empty.')
    return hashlib.sha256(json.dumps(rows, ensure_ascii=True).encode()).hexdigest()


def atomic_json(path, data):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix='.build-state-')
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as out:
            json.dump(data, out, ensure_ascii=True, indent=2)
            out.flush(); os.fsync(out.fileno())
        os.replace(temp, path)
    finally:
        if os.path.exists(temp): os.unlink(temp)


def load(path):
    if path.is_symlink() or path.stat().st_size > 8*1024*1024:
        raise ValueError('Invalid build record: '+str(path))
    data = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(data, dict): raise ValueError('Build record must contain an object.')
    return data


def matching_build(root, identity, profile, settings):
    matches = []
    for path in (root / 'receipts').glob('*.json'):
        try:
            record = load(path)
            if (record.get('schema') != 1 or record.get('identity') != identity
                    or record.get('profile') != profile or record.get('settings') != settings):
                continue
            if record.get('outputs') and all(output_digest(Path(row['path'])) == row['sha256'] for row in record['outputs']):
                matches.append((path.stat().st_mtime_ns, record))
            else:
                print('A previous build has missing or changed output; it will not be reused.', flush=True)
        except (OSError, ValueError, KeyError, TypeError):
            continue
    return max(matches, key=lambda pair: pair[0])[1] if matches else None


def snapshot(repo, commit, root, profile):
    root.mkdir(parents=True, exist_ok=True)
    # Keep sources for incremental CMake builds and the compiler's recorded paths.
    destination = root / (profile+'-'+commit[:16])
    if destination.exists():
        if git_text(destination, 'rev-parse', 'HEAD') != commit or git(destination, 'status', '--porcelain', '--untracked-files=normal').stdout:
            raise ValueError('The committed-source cache was modified. Preserve it and choose a fresh cache folder: '+str(destination))
    else:
        git(repo, 'worktree', 'add', '--detach', str(destination), commit)
    return destination.resolve()


def require_rebuild_consent(rebuild, message, ask=input):
    print(message, flush=True)
    if rebuild == 'yes': return
    if rebuild == 'ask' and sys.stdin.isatty():
        if ask('Build anyway? Type yes to confirm [no]: ').strip().lower() == 'yes': return
    raise ValueError('No rebuild was confirmed. Nothing was compiled; an unverified or incompatible output was not treated as the requested build.')


def historical_candidates(repo, profile, root, extra=()):
    choices = {
        'macos-thin': [repo / 'build-macos/watchtower.app/Contents/MacOS/watchtower'],
        'windows-local': [repo / 'build-windows/watchtower.exe', repo / 'build-windows/dist/watchtower.exe'],
        'windows-warden': [repo / 'build-windows/dist/warden/warden.exe'],
        'linux-app': [repo / 'build/watchtower', repo / 'build68/watchtower']}
    recorded = set()
    for record_path in (root / 'receipts').glob('*.json'):
        try:
            prior = load(record_path)
            if prior.get('profile') == profile:
                recorded.update(row['path'] for row in prior.get('outputs', []))
        except (OSError, ValueError, KeyError): pass
    paths = dict.fromkeys([*choices.get(profile, []), *(Path(p).absolute() for p in extra)])
    return [path for path in paths if path.is_file() and str(path) not in recorded]


def discover_mac_builds(repo, commit, identity, settings, root, *, rebuild='ask', ask=input):
    """Import successful pre-receipt DMGs only with matching committed helpers."""
    candidates = []
    runs = Path.home() / 'Library/Caches/CilexWatchtower/SimpleInstaller/runs'
    for path in runs.glob('*/result.json'):
        try:
            result = load(path)
            artifacts = result.get('artifacts', {})
            image = artifacts.get('installer', {})
            if result.get('exit_code') != 0 or not image.get('installer'):
                continue
            package = Path(artifacts['package_root'])
            manifest = load(package / 'artifact-manifest.json')
            binary = package / 'watchtower.app/Contents/MacOS/watchtower'
            if not binary.is_file() or not Path(image['installer']).is_file(): continue
            candidates.append((path.stat().st_mtime_ns, binary, Path(image['installer']), manifest, image, artifacts))
        except (OSError, ValueError, KeyError, TypeError): continue
    if not candidates: return None
    latest = max(candidates, key=lambda item: item[0])
    print('Previously compiled version: '+str(latest[3].get('version', 'unknown')), flush=True)
    print('Previous binary: '+str(latest[1]), flush=True)
    print('Previous installer: '+str(latest[2]), flush=True)
    for _, binary, image_path, manifest, image, artifacts in sorted(candidates, reverse=True, key=lambda item: item[0]):
        if manifest.get('source', {}).get('commit') != commit: continue
        try:
            if manifest.get('arch') != settings.get('arch') or manifest.get('distribution') != settings.get('distribution'):
                continue
            helpers = manifest['helper_provenance']['files']
            if not helpers: continue
            matched = True
            for item in helpers:
                name = item['path']
                if name.startswith('/') or '..' in Path(name).parts: matched = False; break
                source_path = ('packaging/build_state.py' if name == 'build_state.py' else
                               'packaging/macos/deploy-watchtower.sh' if name == 'deploy-watchtower.sh' else
                               'packaging/macos/generic/'+name)
                data = git(repo, 'show', commit+':'+source_path, check=False)
                if data.returncode or hashlib.sha256(data.stdout).hexdigest() != item['sha256']:
                    matched = False; break
            if not matched or file_digest(image_path) != image['sha256']: continue
            expected = next(row for row in manifest['files'] if row['path'] == 'watchtower.app/Contents/MacOS/watchtower')
            if file_digest(binary) != expected['sha256']: continue
            outputs = [('binary', binary), ('installer', image_path)]
            # The immutable DMG is reusable. Do not certify an old unpacked
            # package directory whose entire manifest has not been rechecked.
            plan = {'schema': 1, 'commit': commit, 'identity': identity, 'version': manifest['version'],
                    'profile': 'macos-dmg', 'settings': settings, 'cache': str(root), 'build': True}
            print('Found a previous successful DMG for the selected committed source.', flush=True)
            return record_success(plan, outputs)
        except (OSError, ValueError, KeyError, TypeError, StopIteration): continue
    if any(row[3].get('source', {}).get('commit') == commit for row in candidates):
        require_rebuild_consent(rebuild,
            'A previous DMG names this same committed code, but its contents/settings could not be verified. Rebuilding may add no new code.', ask)
    return None


def check_unusable_previous(root, identity, profile, rebuild, ask=input):
    for path in (root / 'receipts').glob('*.json'):
        try:
            prior = load(path)
            if prior.get('identity') == identity and prior.get('profile') == profile:
                print_outputs(prior.get('outputs', []), prefix='Recorded ')
                require_rebuild_consent(rebuild,
                    'No new committed code: a previous build exists, but its output changed/missing or its settings differ. Rebuilding adds no new code.', ask)
                return True
        except (OSError, json.JSONDecodeError): pass
    return False


def prepare(repo, profile, *, revision='HEAD', update=True, rebuild='ask', settings=None,
            root=None, make_snapshot=True, ask=input, candidates=()):
    repo = Path(repo).resolve(); root = prepare_cache(root)
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*', profile): raise ValueError('Invalid build profile.')
    settings = build_settings(settings)
    commit = select_commit(repo, revision, update)
    identity = source_identity(repo, commit, profile)
    text = git_text(repo, 'show', commit+(':warden/warden.py' if profile == 'windows-warden' else ':CMakeLists.txt'))
    pattern = r'WARDEN_VERSION\s*=\s*"([0-9.]+)"' if profile == 'windows-warden' else r'project\s*\(\s*watchtower\s+VERSION\s+([0-9.]+)'
    match = re.search(pattern, text)
    if not match: raise ValueError('The selected committed source has no supported product version.')
    version = match.group(1)
    if profile == 'linux-qt':
        sdk_script = git_text(repo, 'show', commit+':tools/build-patched-qt/build.sh')
        tag = re.search(r'^TAG=v([^\s]+)', sdk_script, re.M)
        if not tag: raise ValueError('The selected committed SDK builder has no pinned Qt tag.')
        version = 'Qt '+tag.group(1)
    print('Selected version: '+version+'. Building committed code only.', flush=True)
    record = matching_build(root, identity, profile, settings)
    if not record and profile == 'macos-dmg' and root == cache_root().resolve():
        record = discover_mac_builds(repo, commit, identity, settings, root, rebuild=rebuild, ask=ask)
    plan = {'schema': 1, 'repository': str(repo), 'commit': commit, 'identity': identity,
            'profile': profile, 'settings': settings, 'version': version, 'cache': str(root),
            'build': True, 'source': str(repo), 'source_snapshot': make_snapshot, 'existing': record,
            'git': os.environ.get('CILEX_BUILD_GIT', 'git')}
    if record:
        print('This committed code already has a successful build.', flush=True)
        print_outputs(record['outputs'], prefix='Existing ')
        print('Rebuilding will add no new committed code.', flush=True)
        consent = rebuild == 'yes'
        if rebuild == 'ask' and sys.stdin.isatty():
            consent = ask('Rebuild the same code anyway? Type yes to confirm [no]: ').strip().lower() == 'yes'
        if not consent:
            print('No build started. Use the existing files shown above.', flush=True)
            plan['build'] = False
            return plan
        print('Rebuild confirmed: no new committed code will be added.', flush=True)
    else:
        known = check_unusable_previous(root, identity, profile, rebuild, ask)
        previous_binaries = historical_candidates(repo, profile, root, candidates)
        if previous_binaries and not known:
            for path in previous_binaries: print('Existing binary (source not recorded): '+str(path), flush=True)
            require_rebuild_consent(rebuild, 'These older binaries have no matching build receipt. A rebuild might add no new code; source equivalence is unknown.', ask)
        print('No intact successful build of these committed inputs was found. A new build is needed.', flush=True)
        previous = []
        for path in (root / 'receipts').glob('*.json'):
            try:
                record = load(path)
                if record.get('profile') == profile: previous.append((path.stat().st_mtime_ns, record))
            except (OSError, ValueError): pass
        if previous:
            last = max(previous, key=lambda item: item[0])[1]
            changes = git(repo, 'diff', '--name-only', '-z', last['commit'], commit, check=False)
            if changes.returncode == 0: show_files('Files changed since the previous build', names(changes.stdout))
            print_outputs([row for row in last.get('outputs', []) if Path(row['path']).exists()], prefix='Previous ')
    if make_snapshot:
        plan['source'] = str(snapshot(repo, commit, root / 'sources', profile))
    return plan


def prepare_pinned(identity, commit, version, profile, settings, rebuild='ask', root=None):
    """Authenticated archive/remote controllers already acquired their source."""
    root = prepare_cache(root)
    settings = build_settings(settings)
    existing = matching_build(root, identity, profile, settings)
    plan = {'schema': 1, 'commit': commit, 'identity': identity, 'version': version,
            'profile': profile, 'settings': settings, 'cache': str(root), 'build': True,
            'existing': existing}
    print('Selected version: '+version+'. Building committed code only.', flush=True)
    if existing:
        print_outputs(existing['outputs'], prefix='Existing ')
        print('This committed code was already built. Rebuilding adds no new committed code.', flush=True)
        consent = rebuild == 'yes'
        if rebuild == 'ask' and sys.stdin.isatty():
            consent = input('Rebuild the same code anyway? Type yes to confirm [no]: ').strip().lower() == 'yes'
        plan['build'] = consent
        if not consent: print('No rebuild started; using the existing verified output.', flush=True)
    else:
        check_unusable_previous(root, identity, profile, rebuild)
        print('No intact successful build of these committed inputs was found.', flush=True)
    return plan


def print_outputs(outputs, prefix=''):
    for row in outputs:
        label = prefix + row['role'] if prefix else row['role'].capitalize()
        print(label+': '+row['path'], flush=True)


def record_success(plan, outputs, metadata=None):
    if not plan['build']:
        raise ValueError('Cannot record a build that was skipped.')
    if plan.get('source_snapshot'):
        source = Path(plan['source'])
        if git_text(source, 'rev-parse', 'HEAD') != plan['commit'] or git(source, 'status', '--porcelain', '--untracked-files=normal').stdout:
            raise ValueError('The committed source changed during the build; success was not recorded.')
    rows = []
    for role, path in outputs:
        path = Path(path).absolute()
        rows.append({'role': role, 'path': str(path), 'sha256': output_digest(path)})
    if not rows:
        raise ValueError('A successful build must have output files.')
    record = {key: plan[key] for key in ('schema','commit','identity','profile','settings','version')}
    record.update(outputs=rows, metadata=metadata or {})
    key = hashlib.sha256(json.dumps([plan['identity'],plan['profile'],plan['settings']], sort_keys=True).encode()).hexdigest()
    atomic_json(Path(plan['cache']) / 'receipts' / (key+'.json'), record)
    print_outputs(rows)
    return record


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    p = sub.add_parser('prepare')
    p.add_argument('--repository', type=Path, required=True); p.add_argument('--profile', required=True)
    p.add_argument('--plan', type=Path, required=True); p.add_argument('--revision', default='HEAD')
    p.add_argument('--update', choices=('yes','no'), default='yes')
    p.add_argument('--rebuild', choices=('ask','yes','no'), default='ask')
    setting_input = p.add_mutually_exclusive_group()
    setting_input.add_argument('--settings', default='{}')
    setting_input.add_argument('--settings-file', type=Path)
    p.add_argument('--cache', type=Path)
    p.add_argument('--snapshot', choices=('yes','no'), default='yes')
    p.add_argument('--candidate', action='append', type=Path, default=[])
    p.add_argument('--git', help='Selected Git executable; default: git on PATH')
    p = sub.add_parser('record'); p.add_argument('--plan', type=Path, required=True)
    p.add_argument('--output', action='append', nargs=2, metavar=('ROLE','PATH'), required=True)
    meta_input = p.add_mutually_exclusive_group()
    meta_input.add_argument('--metadata', default='{}')
    meta_input.add_argument('--metadata-file', type=Path)
    p = sub.add_parser('value'); p.add_argument('--plan', type=Path, required=True)
    p.add_argument('--field', choices=('source','commit','build','version','binary'), required=True)
    args = parser.parse_args(argv)
    try:
        if args.action == 'prepare':
            if args.git: os.environ['CILEX_BUILD_GIT'] = args.git
            plan = prepare(args.repository, args.profile, revision=args.revision, update=args.update=='yes',
                           rebuild=args.rebuild, settings=load(args.settings_file) if args.settings_file else json.loads(args.settings), root=args.cache,
                           make_snapshot=args.snapshot=='yes', candidates=args.candidate)
            atomic_json(args.plan, plan)
        elif args.action == 'record':
            plan = load(args.plan)
            if plan.get('git'): os.environ['CILEX_BUILD_GIT'] = plan['git']
            record = record_success(plan, args.output, metadata=load(args.metadata_file) if args.metadata_file else json.loads(args.metadata))
            plan['outputs'] = record['outputs']; atomic_json(args.plan, plan)
        else:
            plan = load(args.plan)
            if args.field == 'binary':
                rows = plan.get('outputs') or (plan.get('existing') or {}).get('outputs', [])
                value = next(row['path'] for row in rows if row['role'] == 'binary')
            else: value = plan[args.field]
            print(str(value).lower() if isinstance(value, bool) else value)
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print('Build check stopped: '+str(error), file=sys.stderr)
        return 1


if __name__ == '__main__': sys.exit(main())
