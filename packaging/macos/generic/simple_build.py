"""Prepare ordinary Homebrew build inputs without a hand-written tools file."""
from __future__ import annotations

import json
import os
from pathlib import Path
import platform
import re
import secrets
import shutil
import subprocess

import build
import dependencies
import deploy
from common import atomic_json, clean_env, command, private_dir, read_json, sha256, utc

FORMULAS = ('cmake', 'ninja', 'pkgconf', 'qt', 'gstreamer', 'python@3.14')
REPOSITORY = Path(__file__).resolve().parents[3]


def brew_command(brew, *args):
    return command([str(brew), *args], timeout=120, env={
        'HOMEBREW_NO_AUTO_UPDATE': '1', 'HOMEBREW_NO_ANALYTICS': '1',
        'HOMEBREW_NO_INSTALL_CLEANUP': '1', 'HOMEBREW_NO_ENV_HINTS': '1'})


def homebrew():
    for path in (Path('/opt/homebrew/bin/brew'), Path('/usr/local/bin/brew')):
        if path.is_file():
            return path
    raise ValueError('Homebrew is missing. Install it from https://brew.sh, then run this build command again.')


def brew_tools(brew):
    prefix = Path(brew_command(brew, '--prefix').stdout.strip())
    tools = {
        'cmake': prefix / 'bin/cmake', 'ninja': prefix / 'bin/ninja',
        'pkg_config': prefix / 'bin/pkg-config', 'qt_root': prefix / 'opt/qt',
        'gstreamer_root': prefix / 'opt/gstreamer',
        'python': prefix / 'opt/python@3.14/bin/python3.14',
        'macdeployqt': prefix / 'opt/qt/bin/macdeployqt',
    }
    required = {'cmake': 'cmake', 'ninja': 'ninja', 'pkgconf': 'pkg_config',
                'qt': 'macdeployqt', 'gstreamer': 'gstreamer_root', 'python@3.14': 'python'}
    missing = [name for name, key in required.items() if not tools[key].exists()]
    # qt is split across formulas on recent Homebrew. Test the required modules,
    # rather than assuming that a qmake executable means all of Qt is installed.
    for module, formula in (('Qt6Quick', 'qtdeclarative'), ('Qt6Multimedia', 'qtmultimedia'),
                            ('Qt6ShaderTools', 'qtshadertools')):
        if not (tools['qt_root'] / 'lib/cmake' / module / (module + 'Config.cmake')).is_file():
            missing.append(formula)
    tools['pkg_config_dirs'] = [str(prefix / 'lib/pkgconfig')]
    apple_pc = prefix / 'Library/Homebrew/os/mac/pkgconfig'
    current_os = apple_pc / platform.mac_ver()[0].split('.')[0]
    if current_os.is_dir():
        tools['pkg_config_dirs'].append(str(current_os))
    tools['runtime_roots'] = [str(prefix / 'Cellar')]
    return {key: str(value) if isinstance(value, Path) else value for key, value in tools.items()}, sorted(set(missing))


def prepare_brew(brew, policy):
    tools, missing = brew_tools(brew)
    if missing:
        if policy == 'existing':
            raise ValueError('Missing build tools: ' + ', '.join(missing) + '. Use --tools install to prepare them.')
        print('Installing missing build tools with Homebrew: ' + ', '.join(missing), flush=True)
        # Install only missing formulas. Never upgrade or clean up unrelated tools.
        env = clean_env({'HOMEBREW_NO_AUTO_UPDATE': '1', 'HOMEBREW_NO_ANALYTICS': '1',
                         'HOMEBREW_NO_INSTALL_CLEANUP': '1', 'HOMEBREW_NO_ENV_HINTS': '1'})
        subprocess.run([str(brew), 'install', *missing], env=env, check=True, timeout=7200)
        tools, missing = brew_tools(brew)
        if missing:
            raise ValueError('Homebrew did not provide the required tools: ' + ', '.join(missing))
    return tools


def ffmpeg(cache, options, tools, jobs):
    root = cache / 'ffmpeg' / build.FFMPEG_VERSION
    receipt = root / 'ready.json'
    if receipt.is_file():
        data = read_json(receipt)
        binary = root / 'output/ffmpeg'
        if (data.get('source_sha256') == build.FFMPEG_SOURCE_SHA256
                and binary.is_file() and sha256(binary) == data.get('binary_sha256')
                and data.get('notices') == build.inventory(root / 'output/licenses')):
            return binary, root / 'output/licenses'
        raise ValueError('The cached FFmpeg build changed. Remove this folder before retrying: ' + str(root))
    # The cache key is locked for the whole build, so parallel commands cannot
    # partially replace a dependency another installer is about to package.
    if root.exists():
        raise ValueError('An unfinished FFmpeg build exists. Remove this folder before retrying: ' + str(root))
    package = next(p for p in dependencies.catalog()['packages'] if p['id'] == 'FFmpeg')
    archive = dependencies.fetch(package, options)
    private_dir(root)
    print('Building the video export tool. This is needed only on the first build.', flush=True)
    result = build.build_ffmpeg(archive, root / 'output', root, tools=tools, jobs=jobs)
    atomic_json(receipt, {'source_sha256': build.FFMPEG_SOURCE_SHA256, 'binary_sha256': result['sha256'],
                          'notices': build.inventory(root / 'output/licenses')})
    return Path(result['ffmpeg']), Path(result['licenses_dir'])


def collect_notices(brew, tools, ffmpeg_notices, destination):
    destination.mkdir()
    shutil.copytree(ffmpeg_notices, destination / 'FFmpeg')
    metadata = json.loads(brew_command(brew, 'info', '--json=v2', '--installed').stdout)
    formulae = {f['name']: f for f in metadata['formulae']}
    pending, selected = list(FORMULAS), set()
    while pending:
        name = pending.pop()
        if name in selected or name not in formulae:
            continue
        selected.add(name)
        pending.extend(formulae[name].get('dependencies', []))
    prefix = Path(brew_command(brew, '--prefix').stdout.strip())
    for name in sorted(selected):
        root = (prefix / 'opt' / name).resolve()
        if not root.is_dir():
            continue
        target = destination / 'Homebrew' / name
        for item in root.iterdir():
            if item.is_file() and re.match(r'(?i)^(licen[cs]e|copying|copyright|notice)', item.name):
                target.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(item, target / item.name)
        for directory in ('LICENSES', 'licenses', 'share/licenses'):
            source = root / directory
            if source.is_dir():
                shutil.copytree(source, target / directory, dirs_exist_ok=True)
    # Include the notices from the exact isolated Python packaging environment.
    code = "import importlib.metadata,json; print(json.dumps([str(d._path) for d in importlib.metadata.distributions()]))"
    for directory in json.loads(command([tools['python'], '-I', '-B', '-c', code], timeout=30).stdout):
        source = Path(directory)
        for entry in source.rglob('*'):
            if entry.is_file() and (re.match(r'(?i)^(licen[cs]e|copying|copyright|notice)', entry.name)
                                    or 'licenses' in entry.relative_to(source).parts):
                target = destination / 'Python-packages' / source.name / entry.relative_to(source)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(entry, target)
    python_root = (prefix / 'opt/python@3.14').resolve()
    if (python_root / 'LICENSE').is_file():
        shutil.copyfile(python_root / 'LICENSE', destination / 'Python-LICENSE.txt')
    atomic_json(destination / 'DEPENDENCY-NOTICES.json', {
        'status': 'internal-development-notices; redistribution review incomplete',
        'formulae': [{key: formulae[name].get(key) for key in ('name', 'license', 'urls', 'installed')}
                     for name in sorted(selected)],
        'note': 'Installed notices and source links are recorded. This is not a completed distribution license review.'})


def run(args, cache, output):
    if platform.machine() != 'arm64':
        raise ValueError('Build on an Apple silicon Mac, with Terminal running without Rosetta.')
    translated = command(['/usr/sbin/sysctl', '-in', 'sysctl.proc_translated'], check=False, timeout=10)
    if translated.stdout.strip() == '1':
        raise ValueError('Turn off Open using Rosetta for Terminal, reopen Terminal, then try again.')
    toolchain = dependencies.inspect_toolchain({})
    if toolchain['state'] != 'present':
        raise ValueError('Apple build tools are missing. Run xcode-select --install, finish the Apple installer, then try again.')
    cache = private_dir(cache)
    import fcntl
    lock = os.open(cache / 'build.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError('Another installer build is already running. Let it finish before starting another.')
        return locked_run(args, cache, output, toolchain)
    finally:
        os.close(lock)


def locked_run(args, cache, output, toolchain):
    run_name = utc().replace('-', '').replace(':', '') + '-' + secrets.token_hex(4)
    preparation = private_dir(cache / 'builds' / run_name)
    brew = homebrew()
    print('Preparing build tools. Downloaded tools stay in your build cache.', flush=True)
    tools = prepare_brew(brew, args.tools)
    tools['developer_dir'] = toolchain['developer_dir']
    options = deploy.normalize(deploy.parser().parse_args([]))
    options.update(mode='build-installer', development=True, accept_licenses=True,
                   dependencies='auto', accept_findings=[dependencies.LOCAL_FINDING],
                   accepted_findings=[dependencies.LOCAL_FINDING], jobs=args.jobs,
                   work_dir=str(cache / 'runs'),
                   output_dir=str(output.expanduser().absolute() / run_name), quiet=True, bootstrap=False)
    # Pin the local committed source; a checkout already has GitHub authorization.
    commit = command(['/usr/bin/git', 'rev-parse', '--verify', '--end-of-options', args.revision + '^{commit}'], cwd=REPOSITORY).stdout.strip()
    archive = preparation / 'source.tar.gz'
    command(['/usr/bin/git', '-c', 'tar.umask=0022', 'archive', '--format=tar.gz', '--output=' + str(archive), commit], cwd=REPOSITORY, timeout=120)
    print('Building committed source ' + commit[:12] + '. Uncommitted app edits are excluded.', flush=True)
    options.update(source_archive=str(archive), source_sha256=sha256(archive), source_commit=commit)
    python, _ = dependencies.provision_python(tools['python'], dependencies.catalog()['packages'], options, preparation)
    tools['python'] = python
    binary, notices = ffmpeg(cache, options, tools, args.jobs)
    tools['ffmpeg'] = str(binary)
    collect_notices(brew, tools, notices, preparation / 'notices')
    tools['licenses_dir'] = str(preparation / 'notices')
    tools_file = preparation / 'tools.json'
    atomic_json(tools_file, {'tools': tools, 'provenance': {'description': 'Discovered Homebrew inputs for an internal development build'}})
    options['tools_json'] = str(tools_file)
    value, record = deploy.execute(options)
    from easy import show_outcome
    code = show_outcome(value, record)
    installer = value.get('artifacts', {}).get('installer', {}).get('installer')
    if code == 0 and installer:
        print('\nDMG ready: ' + installer)
        manifest = read_json(Path(value['artifacts']['package_root']) / 'artifact-manifest.json')
        print('Requires an Apple silicon Mac with macOS ' + manifest['minimum_macos'] + ' or later.')
        print('Double-click that file, then open Setup.app to install it.')
        print('This is an unsigned internal build for Apple silicon. macOS may ask you to allow it.')
    return code
