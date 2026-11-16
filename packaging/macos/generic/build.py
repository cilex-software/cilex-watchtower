"""Isolated source build, runtime closure, signing and offline artifact packaging.

No dependency or source download occurs here. Inputs have to be provisioned and
verified first; the outer controller supplies provenance and accepted decisions.
"""
from __future__ import annotations
import json
import os
import platform
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import selectors
import signal
import time
from pathlib import Path

from closure import (ClosureError, audit, contained, inventory, is_macho,
                     parse_macho, sha256, validate_bundle, version_tuple, is_system_load)
import license_coverage

HELPER_VERSION = '1.0.4'
GST_PLUGINS = ('coreelements','app','playback','typefindfunctions','rtsp','rtp',
               'rtpmanager','tcp','udp','videoparsersbad','videoconvertscale',
               'applemedia','isomp4','audioconvert','audioresample','volume')

class BuildError(RuntimeError):
    pass

def normalized_environment(tools, home, temp):
    # Never inherit tokens, shell startup, Python/DYLD/Qt/GStreamer path overrides.
    prefixes = [str(Path(tools[k]).resolve().parent) for k in ('cmake','ninja','pkg_config','python') if tools.get(k)]
    env = {'PATH': ':'.join(dict.fromkeys(prefixes + ['/usr/bin','/bin','/usr/sbin','/sbin'])),
           'HOME': str(home), 'TMPDIR': str(temp)+'/', 'LANG': 'en_US.UTF-8',
           'LC_ALL': 'en_US.UTF-8', 'PYTHONNOUSERSITE': '1', 'PYTHONDONTWRITEBYTECODE': '1',
           'PIP_NO_INDEX': '1', 'PIP_DISABLE_PIP_VERSION_CHECK': '1'}
    if tools.get('developer_dir'): env['DEVELOPER_DIR'] = str(tools['developer_dir'])
    if tools.get('gstreamer_root'):
        env['PKG_CONFIG_LIBDIR'] = ':'.join([str(Path(tools['gstreamer_root'])/'lib/pkgconfig')]+[str(Path(p)) for p in tools.get('pkg_config_dirs',[])])
    return env

def bounded_jobs(memory_bytes, cpus, override=None):
    maximum = max(1,min(int(cpus), max(1,int(memory_bytes)//(2*1024**3))))
    if override is not None and (int(override)<1 or int(override)>256):
        raise BuildError('jobs must be between 1 and 256')
    return int(override) if override is not None else maximum

def available_memory(env, physical):
    result=subprocess.run(['/usr/bin/vm_stat'],env=env,capture_output=True,text=True,timeout=10,stdin=subprocess.DEVNULL)
    page=re.search(r'page size of (\d+) bytes',result.stdout)
    counts=[re.search(r'^'+name+r':\s+(\d+)\.',result.stdout,re.M) for name in ('Pages free','Pages inactive','Pages speculative')]
    if result.returncode or not page or not all(counts):
        # Probe uncertainty reduces concurrency instead of assuming all RAM free.
        return min(int(physical),2*1024**3)
    return max(1,min(int(physical),int(page.group(1))*sum(int(m.group(1)) for m in counts)))

COMMAND_LOG_LIMIT=4*1024*1024

def run(command, cwd, env, logs, name, timeout=1200, log_limit=COMMAND_LOG_LIMIT):
    logs.mkdir(parents=True,exist_ok=True)
    log = logs/(name+'.log')
    # Commands are token-free by contract. Keep useful beginning/end diagnostics
    # without unbounded disk or communicate() memory use from a noisy child.
    head_limit=log_limit//2;tail_limit=log_limit-head_limit
    head_size=0;tail=bytearray();total=0;timed_out=False
    with log.open('wb') as out:
        os.chmod(log,0o600)
        proc=subprocess.Popen([str(x) for x in command],cwd=str(cwd),env=env,
            stdout=subprocess.PIPE,stderr=subprocess.STDOUT,stdin=subprocess.DEVNULL,
            bufsize=0,start_new_session=True)
        selector=selectors.DefaultSelector();selector.register(proc.stdout,selectors.EVENT_READ)
        deadline=time.monotonic()+timeout;eof=False
        try:
            while not (eof and proc.poll() is not None):
                remaining=deadline-time.monotonic()
                if remaining<=0:
                    timed_out=True;break
                for key,_ in selector.select(min(remaining,0.2)):
                    chunk=os.read(key.fd,65536)
                    if not chunk:
                        selector.unregister(key.fileobj);eof=True;continue
                    total+=len(chunk)
                    keep=min(len(chunk),head_limit-head_size)
                    if keep:
                        out.write(chunk[:keep]);out.flush();head_size+=keep
                    tail.extend(chunk[keep:])
                    if len(tail)>tail_limit:del tail[:-tail_limit]
        finally:
            # Every command gets a new session. Stop only that child session on
            # timeout/interruption, never a global executable-name match.
            if timed_out or proc.poll() is None:
                try:os.killpg(proc.pid,signal.SIGTERM)
                except ProcessLookupError:pass
                try:proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    try:os.killpg(proc.pid,signal.SIGKILL)
                    except ProcessLookupError:pass
                    proc.wait(timeout=2)
            selector.close();proc.stdout.close()
            if total>log_limit:
                out.write(('\n[deployment log truncated: %d middle bytes omitted]\n'%(total-head_size-len(tail))).encode())
            out.write(tail)
    if timed_out:raise BuildError('%s timed out; diagnostics: %s' % (name,log))
    if proc.returncode: raise BuildError('%s failed (%s); diagnostics: %s' % (name,proc.returncode,log))
    return log.read_text(errors='replace')

def copy_tree(source,dest):
    if dest.exists(): raise BuildError('Staging destination already exists: '+str(dest))
    shutil.copytree(source,dest,symlinks=True)
    protect_staging_tree(dest)

def protect_staging_tree(dest):
    # Distribution files must not retain write permission for other accounts.
    for path in [dest]+list(dest.rglob('*')):
        if not path.is_symlink(): path.chmod((path.stat().st_mode & ~0o7022) | (0o700 if path.is_dir() else 0o200))

def tool_version(command, env):
    import hashlib
    name='tool-version-'+hashlib.sha256(json.dumps([str(p) for p in command]).encode()).hexdigest()[:12]
    home=Path(env['HOME'])
    return run(command,home,env,home.parent/'logs',name,30).strip()

def validate_tools(tools):
    required=('cmake','ninja','pkg_config','qt_root','gstreamer_root','python','ffmpeg','licenses_dir')
    missing=[k for k in required if not tools.get(k) or not Path(tools[k]).is_absolute() or not Path(tools[k]).exists()]
    if missing: raise BuildError('Missing explicit verified tool inputs: '+', '.join(missing))
    for key in ('cmake','ninja','pkg_config','python','ffmpeg'):
        if not Path(tools[key]).is_file() or not os.access(tools[key],os.X_OK): raise BuildError('Tool is not executable: '+key)
    for value in tools.values():
        # Runtime inputs may never be borrowed from an installed Watchtower.
        if isinstance(value,str) and any(p.name.lower()=='watchtower.app' for p in Path(value).parents):
            raise BuildError('Installed Watchtower runtime is not an allowed build input')
    qt=Path(tools['qt_root'])
    deploy=Path(tools.get('macdeployqt',qt/'bin/macdeployqt'))
    if not deploy.is_file(): raise BuildError('Missing Qt macdeployqt: '+str(deploy))
    return deploy

def _resolve_load(value,binary,main,slices,search_roots):
    if is_system_load(value): return None
    if value.startswith('@loader_path/'): candidates=[binary.parent/value[13:]]
    elif value.startswith('@executable_path/'): candidates=[main.parent/value[17:]]
    elif value.startswith('/'):
        candidates=[Path(value)]
    elif value.startswith('@rpath/'):
        paths=[]
        for item in slices:
            for r in item['rpaths']:
                r=r.replace('@loader_path',str(binary.parent)).replace('@executable_path',str(main.parent))
                if not r.startswith('@'): paths.append(Path(r))
        if main.is_file() and main != binary and is_macho(main):
            for item in parse_macho(main):
                for r in item['rpaths']:
                    r=r.replace('@loader_path',str(main.parent)).replace('@executable_path',str(main.parent))
                    if not r.startswith('@'): paths.append(Path(r))
        candidates=[p/value[7:] for p in paths]
        # Prefer the actual dyld rpath chain; developer search roots are fallback
        # only. A deployed framework and its original must not look ambiguous.
        if not any(p.is_file() for p in candidates):
            staged=search_roots[0]/value[7:]
            candidates=[staged] if staged.is_file() else [p/value[7:] for p in search_roots[1:]]
    else: raise BuildError('Unsupported relative Mach-O load: '+value)
    found={p.resolve() for p in candidates if p.is_file()}
    if len(found)!=1: raise BuildError('Unresolved or ambiguous Mach-O dependency: '+value+' from '+str(binary))
    return next(iter(found))

def bundle_external_libraries(app, tools, env, logs):
    """Copy exact linked external code, relocate links, then reject any residue.

    Do not use DYLD_LIBRARY_PATH. Every copied non-system load is made relative to
    its loader, so scanners and independently launched Python helpers also work.
    """
    app=Path(app).resolve(); framework=app/'Contents/Frameworks'; framework.mkdir(exist_ok=True)
    main=app/'Contents/MacOS'/validate_bundle(app)['CFBundleExecutable']
    search=[framework,Path(tools['qt_root'])/'lib',Path(tools['gstreamer_root'])/'lib']
    allowed=[Path(p).resolve() for p in tools.get('runtime_roots',[])]+[Path(tools['qt_root']).resolve(),Path(tools['gstreamer_root']).resolve(),Path(tools['ffmpeg']).resolve().parent]
    done=set(); index=0; original_inputs={}
    while True:
        binaries=[p for p in app.rglob('*') if p.is_file() and not p.is_symlink() and is_macho(p) and p not in done]
        if not binaries: break
        for binary in binaries:
            done.add(binary); slices=parse_macho(binary)
            binary.chmod((binary.stat().st_mode & ~0o7022) | 0o200)
            loads=list(dict.fromkeys(x for s in slices for x in s['dylibs']))
            changes=[]
            for value in loads:
                target=_resolve_load(value,binary,main,slices,search)
                if target is None: continue
                if not contained(target,app):
                    if not any(contained(target,r) for r in allowed): raise BuildError('Unapproved runtime dependency root: '+str(target))
                    fw=next((p for p in [target]+list(target.parents) if p.suffix=='.framework'),None)
                    if fw:
                        newroot=framework/fw.name
                        if not newroot.exists(): copy_tree(fw,newroot)
                        relocated=newroot/target.relative_to(fw)
                        if not relocated.is_file(): raise BuildError('Framework layout collision: '+fw.name)
                    else:
                        relocated=framework/target.name
                    source_hash=sha256(target)
                    previous=original_inputs.get(str(relocated))
                    if previous and previous['sha256']!=source_hash:
                        raise BuildError('Distinct source library basename collision: '+target.name)
                    if not previous:
                        if relocated.exists() and sha256(relocated)!=source_hash:
                            # macdeployqt has already rewritten/stripped this copy.
                            # Match compiler UUIDs before replacing it from the
                            # approved input; never equate arbitrary basenames.
                            before={(s['arch'],s['uuid']) for s in parse_macho(target)}
                            after={(s['arch'],s['uuid']) for s in parse_macho(relocated)}
                            if before!=after or any(not uid for arch,uid in before):
                                raise BuildError('Library identity collision: '+target.name)
                        if relocated.exists(): relocated.chmod(relocated.stat().st_mode | 0o200)
                        shutil.copy2(target,relocated);relocated.chmod(0o755)
                        original_inputs[str(relocated)]={'source':str(target),'sha256':source_hash}
                        done.discard(relocated)
                    target=relocated
                new='@loader_path/'+os.path.relpath(target,binary.parent)
                if new!=value: changes += ['-change',value,new]
            # Absolute build rpaths must not survive signing. Relocated links no longer need them.
            for value in dict.fromkeys(x for s in slices for x in s['rpaths']):
                changes += ['-delete_rpath',value]
            if any(s['install_name'] for s in slices): changes += ['-id','@loader_path/'+binary.name]
            if changes:
                index+=1
                run(['/usr/bin/install_name_tool']+changes+[binary],app,env,logs,'relocate-%04d'%index,60)
    (logs/'runtime-inputs.json').write_text(json.dumps(original_inputs,indent=2)+'\n')
    return len(done)

def freeze_helpers(helper_root,dest):
    helper_root=Path(helper_root).resolve(); dest.mkdir()
    files=[]
    for p in sorted(helper_root.rglob('*')):
        rel=p.relative_to(helper_root)
        if any(x in ('tests','__pycache__') for x in rel.parts) or not p.is_file() or p.suffix not in ('.py','.json','.sh','.md','.js','.plist','.png','.tiff'):
            continue
        if p.is_symlink(): raise BuildError('Deployment helper symlink refused')
        target=dest/rel; target.parent.mkdir(parents=True,exist_ok=True); shutil.copyfile(p,target); target.chmod(0o755 if p.stat().st_mode & 0o111 else 0o644)
        files.append({'path':rel.as_posix(),'sha256':sha256(target)})
    entry=helper_root.parent/'deploy-watchtower.sh'
    if entry.is_file():
        shutil.copyfile(entry,dest/'deploy-watchtower.sh');(dest/'deploy-watchtower.sh').chmod(0o755)
        files=[item for item in files if item['path']!='deploy-watchtower.sh']
        files.append({'path':'deploy-watchtower.sh','sha256':sha256(dest/'deploy-watchtower.sh')})
    state=helper_root.parents[1]/'build_state.py'
    if state.is_file():
        shutil.copyfile(state,dest/'build_state.py')
        files=[item for item in files if item['path']!='build_state.py']
        files.append({'path':'build_state.py','sha256':sha256(dest/'build_state.py')})
    files.sort(key=lambda item:item['path'])
    if not (dest/'deploy.py').is_file(): raise BuildError('Frozen deployment controller is missing')
    import hashlib
    digest=hashlib.sha256(json.dumps(files,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    return {'version':HELPER_VERSION,'tree_sha256':digest,'files':files}

def sign_bundle(app,identity,env,logs,name,entitlements=None):
    # Explicit nested order, never codesign --deep for signing.
    binaries=[p for p in app.rglob('*') if p.is_file() and not p.is_symlink() and is_macho(p)]
    for i,p in enumerate(sorted(binaries,key=lambda p:len(p.parts),reverse=True)):
        args=['/usr/bin/codesign','--force','--sign',identity]
        if identity!='-': args+=['--timestamp','--options','runtime']
        run(args+[p],app,env,logs,name+'-code-%04d'%i,120)
    for i,p in enumerate(sorted([p for p in app.rglob('*') if p.is_dir() and p.suffix in ('.framework','.app','.xpc')],key=lambda p:len(p.parts),reverse=True)):
        args=['/usr/bin/codesign','--force','--sign',identity]
        if identity!='-': args+=['--timestamp','--options','runtime']
        run(args+[p],app,env,logs,name+'-bundle-%04d'%i,120)
    args=['/usr/bin/codesign','--force','--sign',identity]
    if identity!='-': args+=['--timestamp','--options','runtime']
    if entitlements: args+=['--entitlements',str(entitlements)]
    run(args+[app],app.parent,env,logs,name+'-outer',120)
    run(['/usr/bin/codesign','--verify','--deep','--strict',app],app.parent,env,logs,name+'-verify',120)

def freeze_setup(package, work, pyi, tools, env, logs, target):
    # Use PyInstaller's BUNDLE layout transform even with its console bootloader.
    # A hand-moved onedir executable detects .app and expects Contents/Frameworks;
    # BUNDLE also safely relocates dotted Python directories for code signing.
    helpers=package/'helpers';spec=pyi/'cilex-setup.spec'
    metadata=dict(CFBundleName='Cilex Watchtower Setup',CFBundleVersion=HELPER_VERSION,
                  CFBundleShortVersionString=HELPER_VERSION,LSMinimumSystemVersion=target,
                  LSBackgroundOnly=False)
    datas=[(str(helpers/name),name) for name in ('manifests','i18n')]+[(str(helpers/'git-askpass.sh'),'.')]
    spec.write_text('a = Analysis('+repr([str(helpers/'deploy.py')])+', pathex='+repr([str(helpers)])+
        ', datas='+repr(datas)+", hiddenimports=['dependencies', 'runtime'])\n"+
        'pyz = PYZ(a.pure)\n'+
        "exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name='cilex-setup', console=True, target_arch='arm64', strip=False, upx=False)\n"+
        "coll = COLLECT(exe, a.binaries, a.datas, name='cilex-setup', strip=False, upx=False)\n"+
        "app = BUNDLE(coll, name='Setup.app', bundle_identifier='com.cilexvision.watchtower.setup', version="+repr(HELPER_VERSION)+', info_plist='+repr(metadata)+')\n')
    run([tools['python'],'-I','-m','PyInstaller','--noconfirm','--clean',
         '--distpath',pyi/'setup-dist','--workpath',pyi/'setup-work',spec],work,env,logs,'setup-freeze',1800)
    setup=package/'Setup.app';copy_tree(pyi/'setup-dist/Setup.app',setup)
    return setup

def verify_ffmpeg(ffmpeg,work,env,logs):
    """Exercise the approved PNG-overlay/scale/VideoToolbox MP4 path locally."""
    import struct, zlib
    def chunk(kind,data):
        return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
    width,height=320,180
    raw=b''.join(b'\0'+bytes([y%256,64,192])*width for y in range(height))
    png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b'')
    fixture=work/'export-fixture.png';fixture.write_bytes(png)
    output=work/'export-fixture.mp4'
    run([ffmpeg,'-hide_banner','-nostdin','-y','-loop','1','-i',fixture,'-t','1',
         '-vf','scale=160:90,format=yuv420p','-c:v','h264_videotoolbox','-b:v','800k','-an',output],work,env,logs,'export-fixture',90)
    if not output.is_file() or output.stat().st_size<512: raise BuildError('FFmpeg export fixture did not produce an MP4')
    decoded=work/'decode-fixture.mp4'
    run([ffmpeg,'-hide_banner','-nostdin','-y','-i',output,'-t','1','-vf','scale=160:90',
         '-c:v','h264_videotoolbox','-b:v','800k','-an',decoded],work,env,logs,'decode-fixture',90)
    return {'export':'passed','decode':'passed','selected_encoder':'h264_videotoolbox','hardware_usage':'unverified','source_png_sha256':sha256(fixture),'export_sha256':sha256(output)}

def build(source_root, options, run_dir):
    if platform.system()!='Darwin' or platform.machine()!='arm64': raise BuildError('Native arm64 macOS build host is required; translated builds are not validation')
    if options.get('arch','arm64')!='arm64': raise BuildError('Only arm64 is implemented')
    if options.get('dependencies')=='offline' and options.get('signing_identity'):
        raise BuildError('Offline production build cannot timestamp/notarize; provide an already admitted artifact or explicitly build development output')
    tools=options.get('tools',{}); macdeployqt=validate_tools(tools)
    selected=subprocess.run(['/usr/bin/xcode-select','-p'],capture_output=True,text=True,timeout=10,stdin=subprocess.DEVNULL)
    developer=tools.get('developer_dir') or selected.stdout.strip()
    if not developer or not Path(developer).is_dir():
        raise BuildError('Apple toolchain is unavailable; install an authorized Xcode/CLT and select its SDK before building')
    source=Path(source_root).resolve(); run_dir=Path(run_dir).resolve()
    import hashlib
    requested={'tools':tools,'source':options.get('source',{}),'source_root':str(source),
               'arch':options.get('arch','arm64'),'deployment_target':options.get('deployment_target','14.4'),
               'signing_identity':options.get('signing_identity'),'development':options.get('development',False)}
    fingerprint=hashlib.sha256(json.dumps(requested,sort_keys=True,default=str).encode()).hexdigest()
    state=run_dir/'build-request.json'; work=run_dir/'build'
    if work.exists():
        if not options.get('resume') or not state.is_file() or json.loads(state.read_text()).get('fingerprint')!=fingerprint:
            raise BuildError('Interrupted build exists; resume requires unchanged pinned source, tools and requested options')
        # Preserve failed-run evidence and rebuild in a fresh owned directory.
        # Never delete a user-selected directory or use partial signed output.
        number=1
        while (run_dir/('build-attempt-%03d'%number)).exists(): number+=1
        previous=run_dir/('build-attempt-%03d'%number)
        cache_record=run_dir/'compile-complete.json'
        if cache_record.is_file():
            cache=json.loads(cache_record.read_text())
            cached=Path(cache.get('build_dir',''))
            if contained(cached,work):
                cache['build_dir']=str(previous/cached.relative_to(work))
                cache_record.write_text(json.dumps(cache,sort_keys=True)+'\n');cache_record.chmod(0o600)
        work.rename(previous)
    elif state.exists() and json.loads(state.read_text()).get('fingerprint')!=fingerprint:
        raise BuildError('Build request differs from the protected run record')
    state.write_text(json.dumps({'schema_version':1,'fingerprint':fingerprint,'request':requested},sort_keys=True,default=str)+'\n');state.chmod(0o600)
    work.mkdir(parents=True,exist_ok=False)
    (work/'home').mkdir(); (work/'tmp').mkdir(); logs=work/'logs'
    env=normalized_environment(tools,work/'home',work/'tmp')
    translated=subprocess.run(['/usr/sbin/sysctl','-in','sysctl.proc_translated'],capture_output=True,text=True,env=env,timeout=10)
    if translated.stdout.strip()=='1': raise BuildError('Rosetta is not a native build host')
    memory=int(tool_version(['/usr/sbin/sysctl','-n','hw.memsize'],env)); cpus=int(tool_version(['/usr/sbin/sysctl','-n','hw.ncpu'],env))
    available=available_memory(env,memory)
    jobs=bounded_jobs(available,cpus,options.get('jobs'))
    target=options.get('deployment_target','14.4'); version_tuple(target)
    env['MACOSX_DEPLOYMENT_TARGET']=target
    version=re.search(r'project\s*\(\s*watchtower\s+VERSION\s+(\d+\.\d+\.\d+)',(source/'CMakeLists.txt').read_text()).group(1)
    warden_source=source/'warden/warden.py'
    warden_version=re.search(r'^WARDEN_VERSION\s*=\s*"([0-9.]+)"',warden_source.read_text(),re.M).group(1)
    versions={
        'cmake':tool_version([tools['cmake'],'--version'],env).splitlines()[0],
        'ninja':tool_version([tools['ninja'],'--version'],env),
        'pkg_config':tool_version([tools['pkg_config'],'--version'],env),
        'python':tool_version([tools['python'],'-I','--version'],env),
        'pyinstaller':tool_version([tools['python'],'-I','-m','PyInstaller','--version'],env),
        'qt':tool_version([str(Path(tools['qt_root'])/'bin/qtpaths'),'--query','QT_VERSION'],env),
        'gstreamer':tool_version([tools['pkg_config'],'--modversion','gstreamer-1.0'],env),
        'sdk':tool_version(['/usr/bin/xcrun','--show-sdk-version'],env),
        'compiler':tool_version(['/usr/bin/xcrun','clang','--version'],env).splitlines()[0]}
    expected=options.get('dependency_versions',{})
    for key,value in expected.items():
        if key not in versions or str(value) not in versions[key]: raise BuildError('Pinned dependency version mismatch: '+key)
    build_dir=work/'watchtower'
    compile_record=run_dir/'compile-complete.json'
    tool_hashes={k:sha256(tools[k]) for k in ('cmake','ninja','pkg_config','python','ffmpeg')}
    reused=False
    if options.get('resume') and compile_record.is_file():
        compiled=json.loads(compile_record.read_text())
        candidate=Path(compiled.get('build_dir',''))
        if (compiled.get('request_fingerprint')!=fingerprint or compiled.get('tool_hashes')!=tool_hashes
                or compiled.get('versions')!=versions or not contained(candidate,run_dir)
                or not (candidate/'watchtower.app').is_dir()
                or inventory(candidate/'watchtower.app')!=compiled.get('app_inventory')):
            raise BuildError('Compiled resume checkpoint changed; preserve evidence and start a new run')
        build_dir=candidate;reused=True
    if not reused:
        run([tools['cmake'],'-S',source,'-B',build_dir,'-G','Ninja','-DCMAKE_BUILD_TYPE=Release',
             '-DCMAKE_MAKE_PROGRAM='+str(tools['ninja']),'-DCMAKE_PREFIX_PATH='+str(tools['qt_root']),
             '-DCMAKE_OSX_ARCHITECTURES=arm64','-DCMAKE_OSX_DEPLOYMENT_TARGET='+target,
             '-DCMAKE_C_COMPILER=/usr/bin/clang','-DCMAKE_CXX_COMPILER=/usr/bin/clang++'],source,env,logs,'cmake-configure')
        run([tools['cmake'],'--build',build_dir,'--parallel',str(jobs)],source,env,logs,'cmake-build',7200)
        # CMake can preserve group-write bits from an archive's plist template.
        # Normalize only this freshly compiled owned output before checkpointing.
        protect_staging_tree(build_dir/'watchtower.app')
        compile_record.write_text(json.dumps({'schema_version':1,'request_fingerprint':fingerprint,
            'build_dir':str(build_dir),'tool_hashes':tool_hashes,'versions':versions,
            'app_inventory':inventory(build_dir/'watchtower.app')},sort_keys=True)+'\n');compile_record.chmod(0o600)
    package=work/'package'; package.mkdir(); app=package/'watchtower.app'
    copy_tree(build_dir/'watchtower.app',app); validate_bundle(app)
    run([macdeployqt,app,'-qmldir='+str(source/'qml'),'-no-codesign','-verbose=2'],work,env,logs,'macdeployqt',1200)
    shutil.copy2(tools['ffmpeg'],app/'Contents/MacOS/ffmpeg')
    ff=run([app/'Contents/MacOS/ffmpeg','-hide_banner','-version'],work,env,logs,'ffmpeg-version',30)
    if '--enable-gpl' in ff or '--enable-nonfree' in ff or '--disable-autodetect' not in ff:
        raise BuildError('FFmpeg does not match the approved LGPL/no-autodetect feature profile')
    fflicense=run([app/'Contents/MacOS/ffmpeg','-L'],work,env,logs,'ffmpeg-license',30)
    if 'GNU Lesser General Public License' not in ' '.join(fflicense.split()): raise BuildError('FFmpeg LGPL license check failed')
    gst=Path(tools['gstreamer_root']); plugins=app/'Contents/PlugIns/gstreamer'; plugins.mkdir(parents=True,exist_ok=True)
    # Apple code signing rejects plain dotted directories in nested-code slots.
    # A contained compatibility link preserves the Warden/scanner runtime path.
    (plugins.parent/'gstreamer-1.0').symlink_to('gstreamer')
    for name in GST_PLUGINS:
        item=gst/'lib/gstreamer-1.0'/('libgst'+name+'.dylib')
        if not item.is_file(): raise BuildError('Required dynamic GStreamer plugin missing: '+str(item))
        shutil.copy2(item,plugins/item.name)
    scanner=gst/'libexec/gstreamer-1.0/gst-plugin-scanner'
    if not scanner.is_file(): raise BuildError('Missing GStreamer plugin scanner: '+str(scanner))
    helper=app/'Contents/Helpers'; helper.mkdir(exist_ok=True); shutil.copy2(scanner,helper/'gst-plugin-scanner')
    pyi=work/'pyinstaller'; pyi.mkdir()
    run([tools['python'],'-I','-m','PyInstaller','--noconfirm','--clean','--onedir','--target-arch','arm64',
         '--name','cilex-warden','--hidden-import','warden_darwin','--distpath',pyi/'dist','--workpath',pyi/'work','--specpath',pyi,warden_source],work,env,logs,'warden-freeze',1800)
    warden_dest=app/'Contents/Resources/warden'; copy_tree(pyi/'dist/cilex-warden',warden_dest)
    gate=source/'warden/darwin_spawn_gate.c'
    if not gate.is_file(): raise BuildError('Selected source lacks Darwin supervision gate; choose a compatible source revision')
    run(['/usr/bin/xcrun','clang','-O2','-Wall','-Wextra','-Werror','-arch','arm64','-mmacosx-version-min='+target,gate,'-o',warden_dest/'cilex-spawn-gate'],work,env,logs,'spawn-gate-build',120)
    bundle_external_libraries(app,tools,env,logs)
    ffmpeg_evidence=verify_ffmpeg(app/'Contents/MacOS/ffmpeg',work,env,logs)
    helper_provenance=freeze_helpers(options.get('helper_root',Path(__file__).parent),package/'helpers')
    shutil.copy2(package/'helpers/deploy-watchtower.sh',package/'deploy-watchtower.sh')
    (package/'deploy-watchtower.sh').chmod(0o755)
    setup=freeze_setup(package,work,pyi,tools,env,logs,target)
    # Finder's drag-to-Applications copy must carry its own service registrar.
    # The separate root Setup remains available to the advanced deployment tools.
    copy_tree(setup,app/'Contents/Helpers/Setup.app')
    # Python helpers should already be self-contained after PyInstaller. Audit rejects external references.
    licenses=package/'licenses'; copy_tree(Path(tools['licenses_dir']),licenses)
    copy_tree(licenses,app/'Contents/Resources/Licenses')
    uninstall=package/'Uninstall.command'
    uninstall.write_text('#!/bin/bash\nset -eu\nHERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)\nexec "$HERE/Setup.app/Contents/MacOS/cilex-setup" --mode uninstall "$@"\n')
    uninstall.chmod(0o755)
    closure=audit(package,source_minimum=target)
    minimum=closure['minimum_macos']
    for bundle in (app,setup,app/'Contents/Helpers/Setup.app'):
        meta=bundle/'Contents/Info.plist'
        with meta.open('rb') as f: d=plistlib.load(f)
        d['LSMinimumSystemVersion']=audit(bundle,source_minimum=target)['minimum_macos']
        with meta.open('wb') as f: plistlib.dump(d,f)
    identity=options.get('signing_identity')
    if not identity and not options.get('development'): raise BuildError('Developer ID identity missing; production package blocked. Explicit development mode is required for ad-hoc artifacts')
    if identity and not identity.startswith('Developer ID Application:'): raise BuildError('A Developer ID Application identity is required')
    runtime_inputs=json.loads((logs/'runtime-inputs.json').read_text())
    license_inputs=dict(tool_hashes)
    license_inputs['runtime_libraries']={str(Path(path).relative_to(app)):item['sha256'] for path,item in runtime_inputs.items()}
    license_context=license_coverage.review_context(options.get('source',{}),helper_provenance,versions,
        license_inputs,version,warden_version)
    try:
        license_review=license_coverage.record(package,license_context,options.get('license_manifest'),
            accepted=options.get('accept_licenses',False),production=bool(identity))
    except license_coverage.LicenseCoverageError as exc:
        raise BuildError(str(exc)) from exc
    entitlements=work/'watchtower-entitlements.plist'
    with entitlements.open('wb') as f: plistlib.dump({'com.apple.security.cs.allow-jit':True},f)
    sign_bundle(app,identity or '-',env,logs,'watchtower-sign',entitlements if identity else None)
    sign_bundle(setup,identity or '-',env,logs,'setup-sign')
    security={'signed':bool(identity),'notarized':False,'team_identifier':None,'ad_hoc':not bool(identity)}
    if identity:
        signed=run(['/usr/bin/codesign','-dv','--verbose=4',app],work,env,logs,'signature-details',30)
        match=re.search(r'^TeamIdentifier=(\S+)',signed,re.M)
        if not match or match.group(1)=='not set': raise BuildError('Signed bundle has no team identifier')
        security['team_identifier']=match.group(1)
        profile=options.get('notary_profile')
        if not profile: raise BuildError('Production package requires an explicit notarytool Keychain profile before final inventory')
        for name,bundle in (('watchtower',app),('setup',setup)):
            submission=work/(name+'-notary.zip')
            run(['/usr/bin/ditto','-c','-k','--keepParent',bundle,submission],work,env,logs,name+'-notary-zip',600)
            text=run(['/usr/bin/xcrun','notarytool','submit',submission,'--keychain-profile',profile,'--wait','--timeout','20m','--output-format','json'],work,env,logs,name+'-notarize',1250)
            if json.loads(text).get('status')!='Accepted': raise BuildError(name+' notarization did not return Accepted')
            run(['/usr/bin/xcrun','stapler','staple',bundle],work,env,logs,name+'-staple',120)
            run(['/usr/bin/xcrun','stapler','validate',bundle],work,env,logs,name+'-staple-verify',120)
            run(['/usr/bin/codesign','--verify','--deep','--strict',bundle],work,env,logs,name+'-post-staple-signature',120)
        security['notarized']=True
        security['admission']='unverified-on-target'
    manifest={'schema_version':1,'package_id':'com.cilexvision.watchtower.macos','app':'watchtower.app',
        'warden':'watchtower.app/Contents/Resources/warden/cilex-warden','arch':'arm64',
        'bundle_identifier':'com.cilexvision.watchtower','version':version,'warden_version':warden_version,
        'minimum_macos':minimum,'source':options.get('source',{}),'helper_provenance':helper_provenance,
        'dependencies':versions,'dependency_input_hashes':{k:sha256(tools[k]) for k in ('cmake','ninja','pkg_config','python','ffmpeg')},
        'dependency_receipts':options.get('dependency_receipts',{}),'accepted_findings':options.get('accepted_findings',[]),
        'runtime_input_roots':tools.get('runtime_roots',[]),'toolchain':{'deployment_target':target,'jobs':jobs,'available_memory_estimate_bytes':available,'physical_memory_bytes':memory},
        'distribution':'production' if identity else 'development','security':security,
        'license_review':license_review['status'],'license_coverage':license_review,
        'runtime_closure':audit(package,source_minimum=target),'startup_verification':'StartupUnverified',
        'ffmpeg_fixture':ffmpeg_evidence,
        'verification':{'clean_machine':'unverified','oldest_os':'unverified','camera_video':'unverified','recovery':'unverified'}}
    manifest['files']=inventory(package)
    (package/'artifact-manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    output=Path(options.get('output_dir',run_dir/'output')).resolve(); output.mkdir(parents=True,exist_ok=True)
    archive=output/('CilexWatchtower-%s-arm64-%s.tar.gz'%(version,manifest['distribution']))
    if archive.exists(): raise BuildError('Artifact already exists: '+str(archive))
    with tarfile.open(archive,'w:gz',dereference=False) as tar:
        for p in sorted(package.iterdir()): tar.add(p,arcname=p.name,recursive=True)
    result={'package':str(archive),'package_root':str(package),'sha256':sha256(archive),'manifest':manifest,'evidence':str(logs)}
    (output/(archive.name+'.sha256')).write_text(result['sha256']+'  '+archive.name+'\n')
    return result

def stage_drag_installer(package, destination, assets):
    """Keep the transactional payload intact but out of the ordinary Finder UI."""
    import dmg_layout
    destination.mkdir()
    support=destination/'.deployment'; support.mkdir()
    for item in package.iterdir():
        target=destination/dmg_layout.APP_NAME if item.name=='watchtower.app' else support/item.name
        if item.is_dir(): copy_tree(item,target)
        elif item.is_file() and not item.is_symlink(): shutil.copy2(item,target)
        else: raise BuildError('Unexpected deployment payload entry: '+item.name)
    (destination/'Applications').symlink_to('/Applications',target_is_directory=True)
    (destination/'.background').mkdir()
    shutil.copyfile(assets/'install.tiff',destination/'.background/install.tiff')


def build_installer(package_root,options,run_dir):
    package=Path(package_root).resolve(); run_dir=Path(run_dir).resolve()
    manifest=json.loads((package/'artifact-manifest.json').read_text())
    # Never treat directory contents as immutable without checking the frozen inventory.
    actual=inventory(package); actual=[x for x in actual if x['path']!='artifact-manifest.json']
    if actual!=manifest['files']: raise BuildError('Package changed after inventory/signing')
    output=Path(options['output_dir']).resolve(); output.mkdir(parents=True,exist_ok=True)
    image=output/('CilexWatchtower-%s-arm64-%s.dmg'%(manifest['version'],manifest['distribution']))
    if image.exists(): raise BuildError('Installer already exists')
    env=normalized_environment(options.get('tools',{}),run_dir,run_dir); logs=run_dir/'installer-logs'
    import dmg_layout
    stage=run_dir/'dmg-stage'
    assets=Path(options.get('helper_root',Path(__file__).parent))/'assets'
    stage_drag_installer(package,stage,assets)
    writable=run_dir/'installer-writable.dmg'
    mount=run_dir/'installer-volume'; mount.mkdir()
    run(['/usr/bin/hdiutil','create','-fs','HFS+','-format','UDRW','-volname','Cilex Watchtower','-srcfolder',stage,writable],run_dir,env,logs,'dmg-create',1200)
    run(['/usr/bin/hdiutil','attach','-readwrite','-nobrowse','-mountpoint',mount,writable],run_dir,env,logs,'dmg-attach',180)
    try:
        dmg_layout.configure(mount)
        # Changing Finder metadata must never change signed application contents.
        if inventory(mount/dmg_layout.APP_NAME)!=inventory(package/'watchtower.app'):
            raise BuildError('Application changed while creating the drag installer')
        run(['/usr/bin/codesign','--verify','--deep','--strict',mount/dmg_layout.APP_NAME],run_dir,env,logs,'dmg-app-signature',120)
    finally:
        run(['/usr/bin/hdiutil','detach',mount],run_dir,env,logs,'dmg-detach',180)
    run(['/usr/bin/hdiutil','convert',writable,'-format','UDZO','-o',image],run_dir,env,logs,'dmg-compress',1200)
    identity=options.get('signing_identity'); profile=options.get('notary_profile')
    if manifest['distribution']=='production':
        if options.get('dependencies')=='offline': raise BuildError('Offline mode cannot sign/notarize a new production DMG; no request was made')
        if not identity or not profile: raise BuildError('Production installer requires Developer ID and a selected notarytool Keychain profile')
        run(['/usr/bin/codesign','--sign',identity,'--timestamp',image],run_dir,env,logs,'dmg-sign',120)
        run(['/usr/bin/xcrun','notarytool','submit',image,'--keychain-profile',profile,'--wait','--timeout','20m','--output-format','json'],run_dir,env,logs,'notarize',1250)
        status=json.loads((logs/'notarize.log').read_text())
        if status.get('status')!='Accepted': raise BuildError('Notarization did not return Accepted; production acceptance blocked')
        run(['/usr/bin/xcrun','stapler','staple',image],run_dir,env,logs,'staple',120)
        run(['/usr/bin/xcrun','stapler','validate',image],run_dir,env,logs,'staple-verify',120)
        run(['/usr/sbin/spctl','--assess','--type','open','--context','context:primary-signature',image],run_dir,env,logs,'dmg-admission',120)
    run(['/usr/bin/hdiutil','verify',image],run_dir,env,logs,'dmg-verify',300)
    digest=sha256(image); (output/(image.name+'.sha256')).write_text(digest+'  '+image.name+'\n')
    return {'installer':str(image),'sha256':digest,'distribution':manifest['distribution'],
            'notarized':bool(identity and profile),'offline_clean_machine':'unverified','evidence':str(logs)}

FFMPEG_VERSION='9.0.2'
FFMPEG_SOURCE_SHA256='8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e'
FFMPEG_CONFIGURE=(
    '--disable-everything','--disable-autodetect','--disable-doc','--disable-network','--disable-debug',
    '--disable-shared','--enable-static','--enable-small','--enable-zlib','--enable-videotoolbox',
    '--enable-encoder=h264_videotoolbox','--enable-decoder=h264','--enable-decoder=hevc',
    '--enable-decoder=png','--enable-decoder=rawvideo','--enable-demuxer=mov','--enable-demuxer=image2',
    '--enable-demuxer=png_pipe','--enable-muxer=mp4','--enable-parser=h264','--enable-parser=hevc',
    '--enable-parser=png','--enable-filter=scale,overlay,format,null,copy,setpts,fps','--enable-protocol=file',
    '--enable-bsf=h264_mp4toannexb','--enable-bsf=hevc_mp4toannexb','--enable-ffmpeg','--disable-ffplay','--disable-ffprobe')

def build_ffmpeg(source_archive,output_root,run_dir,tools=None,jobs=None,deployment_target='14.4'):
    """Build the existing approved export profile from a previously pinned download.

    This API never downloads, replaces an installed app, or modifies a shared
    prefix. Output root and work directory must be fresh installation-owned paths.
    """
    from install import safe_extract
    archive=Path(source_archive); output=Path(output_root); work=Path(run_dir)/'ffmpeg-build'
    if output.exists() or work.exists(): raise BuildError('FFmpeg build/output directory already exists; preserve evidence and choose a new run')
    if sha256(archive)!=FFMPEG_SOURCE_SHA256: raise BuildError('FFmpeg source hash differs from approved profile')
    work.mkdir(parents=True); (work/'source').mkdir(); (work/'home').mkdir();(work/'tmp').mkdir()
    safe_extract(archive,work/'source',expected_sha256=FFMPEG_SOURCE_SHA256)
    source=work/'source'/('ffmpeg-'+FFMPEG_VERSION)
    if not (source/'configure').is_file(): raise BuildError('FFmpeg source layout mismatch')
    env=normalized_environment(tools or {},work/'home',work/'tmp')
    version_tuple(deployment_target); env['MACOSX_DEPLOYMENT_TARGET']=deployment_target
    log=work/'logs'
    memory=int(tool_version(['/usr/sbin/sysctl','-n','hw.memsize'],env));cpus=int(tool_version(['/usr/sbin/sysctl','-n','hw.ncpu'],env))
    configure=['/bin/sh',source/'configure',*FFMPEG_CONFIGURE,'--arch=arm64','--cc=/usr/bin/clang',
        '--extra-cflags=-mmacosx-version-min='+deployment_target,'--extra-ldflags=-mmacosx-version-min='+deployment_target]
    text=run(configure,source,env,log,'configure',600)
    if not re.search(r'^License:\s+LGPL version 2\.1 or later\s*$',text,re.M):
        raise BuildError('FFmpeg configure did not report approved LGPL2.1 profile')
    run(['/usr/bin/make','-j'+str(bounded_jobs(available_memory(env,memory),cpus,jobs))],source,env,log,'make',3600)
    output.mkdir(parents=True);shutil.copy2(source/'ffmpeg',output/'ffmpeg');(output/'ffmpeg').chmod(0o755)
    closure=audit(output,source_minimum=deployment_target)
    if len(closure['components'])!=1: raise BuildError('Expected standalone FFmpeg with system dependencies only')
    for s in closure['components'][0]['slices']:
        if any(not is_system_load(p) for p in s['dylibs']):
            raise BuildError('FFmpeg acquired an unapproved runtime dependency')
    notices=output/'licenses';notices.mkdir()
    for name in ('COPYING.LGPLv2.1','LICENSE.md'):
        shutil.copy2(source/name,notices/('FFmpeg-'+name))
    shutil.copy2(archive,notices/archive.name)
    (notices/'FFmpeg-build-provenance.json').write_text(json.dumps({'version':FFMPEG_VERSION,
        'source_sha256':FFMPEG_SOURCE_SHA256,'configure':[str(p) for p in configure[2:]],
        'deployment_target':deployment_target,'binary_sha256':sha256(output/'ffmpeg'),
        'runtime_closure':closure},indent=2)+'\n')
    fixture=verify_ffmpeg(output/'ffmpeg',work,env,log)
    return {'ffmpeg':str(output/'ffmpeg'),'licenses_dir':str(notices),'sha256':sha256(output/'ffmpeg'),
            'minimum_macos':closure['minimum_macos'],'fixture':fixture,'evidence':str(log)}

def build_bootstrap(package_root,options,run_dir):
    """Versioned standalone bootstrap with its own Python runtime and modules."""
    package=Path(package_root).resolve();run_dir=Path(run_dir).resolve()
    manifest=json.loads((package/'artifact-manifest.json').read_text())
    actual=[item for item in inventory(package) if item['path']!='artifact-manifest.json']
    if actual!=manifest['files']: raise BuildError('Cannot freeze bootstrap from a changed package')
    stage=run_dir/'bootstrap-stage'
    if stage.exists(): raise BuildError('Bootstrap staging already exists; use the completed artifact or a new run')
    stage.mkdir()
    for name in ('Setup.app','helpers','licenses'):
        copy_tree(package/name,stage/name)
    shutil.copy2(package/'deploy-watchtower.sh',stage/'deploy-watchtower.sh')
    (stage/'README.txt').write_text('Cilex Watchtower deployment bootstrap '+HELPER_VERSION+'\n\n'
        'Contains the deployment controller and its Python runtime. No application payload is included.\n'
        'Run ./deploy-watchtower.sh --mode check for read-only assessment.\n'
        'Private repository access must be authorized separately through a protected credential channel.\n'
        'Verify the archive SHA-256 from the trusted delivery channel before extraction.\n'
        'Distribution: '+manifest['distribution']+'. Startup and clean-machine compatibility remain unverified.\n\n'
        'Содержит инструмент развёртывания и его Python runtime. Приложение не включено.\n'
        'Проверка без изменений: ./deploy-watchtower.sh --mode check\n'
        'Для закрытого репозитория нужен отдельно разрешённый защищённый доступ.\n'
        'До распаковки проверьте SHA-256 по доверенному каналу.\n')
    bootstrap_floor=audit(stage,source_minimum=options.get('deployment_target','14.4'))['minimum_macos']
    bootstrap={'schema_version':1,'bootstrap_version':HELPER_VERSION,'distribution':manifest['distribution'],
        'minimum_macos':bootstrap_floor,'arch':'arm64','helper_provenance':manifest['helper_provenance'],
        'runtime_closure':audit(stage,source_minimum=bootstrap_floor),'files':inventory(stage),
        'validation':{'clean_machine':'unverified','oldest_os':'unverified'}}
    (stage/'bootstrap-manifest.json').write_text(json.dumps(bootstrap,ensure_ascii=False,indent=2)+'\n')
    output=Path(options['output_dir']);output.mkdir(parents=True,exist_ok=True)
    archive=output/('CilexWatchtower-Bootstrap-%s-arm64-%s.tar.gz'%(HELPER_VERSION,manifest['distribution']))
    if archive.exists():raise BuildError('Bootstrap artifact already exists')
    with tarfile.open(archive,'w:gz',dereference=False) as tar:
        for p in sorted(stage.iterdir()):tar.add(p,arcname=p.name,recursive=True)
    digest=sha256(archive);(output/(archive.name+'.sha256')).write_text(digest+'  '+archive.name+'\n')
    return {'bootstrap':str(archive),'sha256':digest,'version':HELPER_VERSION,'directory':str(stage),'clean_machine':'unverified'}
