#!/usr/bin/env python3
"""Run actual production QML against isolated silent-stall RTSP fixtures."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import select
import shutil
import socket
import subprocess
import time


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def stop_fixture(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    return process.returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', required=True, type=Path)
    parser.add_argument('--evidence-dir', required=True, type=Path)
    parser.add_argument('--source-root', type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument('--before-revision', default='199a8998c4a4b20d8ebffdec87b5bc053adb473b',
                        help='full local commit ID of the preserved component without the reconnect forwarder')
    args = parser.parse_args()
    root = args.source_root.resolve()
    if not re.fullmatch('[0-9a-f]{40}|[0-9a-f]{64}', args.before_revision):
        parser.error('--before-revision must be a full existing local commit hash')
    subprocess.run(['/usr/bin/git','cat-file','-e',args.before_revision+'^{commit}'],cwd=root,check=True)
    build = args.build_dir.resolve()
    evidence = args.evidence_dir.resolve()
    evidence.mkdir(mode=0o700, parents=True, exist_ok=False)
    dependency_env = {'PATH':'/opt/homebrew/bin:/usr/bin:/bin','HOME':str(evidence),'LANG':'en_US.UTF-8'}
    def pkg_value(argument):
        return subprocess.check_output(['/opt/homebrew/bin/pkg-config',argument,'gstreamer-1.0'],
                                       env=dependency_env,text=True).strip()
    scanner = Path(pkg_value('--variable=pluginscannerdir'))/'gst-plugin-scanner'
    plugin_dir = Path(pkg_value('--variable=pluginsdir'))
    plugins = ('coreelements','videotestsrc','videoconvertscale','applemedia','rtsp','rtp',
               'rtpmanager','tcp','udp','app','typefindfunctions','playback','videoparsersbad','x264','opengl')
    isolated_plugins = evidence/'plugins'
    isolated_plugins.mkdir(mode=0o700)
    for name in plugins:
        source = plugin_dir/('libgst'+name+'.dylib')
        if not source.is_file():
            raise RuntimeError('required fixture plugin missing: '+str(source))
        (isolated_plugins/source.name).symlink_to(source)
    if not scanner.is_file():
        raise RuntimeError('fixture plugin scanner missing: '+str(scanner))
    source_hashes = {}
    for name in ('VideoSurface.qml', 'ReconnectCoordinator.qml'):
        source_hashes[name] = sha(root/'qml'/name)
    summary = {'schema_version':1, 'test':'production-qml-silent-rtsp-reconnect',
               'source_commit':subprocess.check_output(['/usr/bin/git','rev-parse','HEAD'], cwd=root, text=True).strip(),
               'before_revision':args.before_revision,
               'source_hashes':source_hashes, 'runs':[], 'passed':False,
               'watchdog_disabled':True, 'installed_application_started':False,
               'limitations':['Loopback synthetic H264 source, not production camera/network acceptance.',
                              'Uses host Qt/GStreamer dependencies and offscreen QML; not packaged-runtime acceptance.']}
    summary['gstreamer_version'] = pkg_value('--modversion')
    summary['fixture_hashes'] = {name:sha(Path(__file__).parent/name)
                                 for name in ('main.cpp','rtsp_fixture.c','run.py','CMakeLists.txt')}
    summary['plugin_hashes'] = {path.name:sha(path) for path in isolated_plugins.iterdir()}
    summary['scanner_sha256'] = sha(scanner)
    for name in ('RtspVideoSource.cpp','RtspVideoSource.h'):
        summary['source_hashes'][name] = sha(root/'src/models'/name)
    summary['binary_hashes'] = {name:sha(build/name) for name in ('qml-stream-reconnect','stalled-rtsp-fixture')}
    for phase in ('before','after'):
        run = evidence/phase
        run.mkdir(mode=0o700)
        qml = run/'qml'
        qml.mkdir(mode=0o700)
        for name in ('VideoSurface.qml','ReconnectCoordinator.qml'):
            if phase == 'before':
                (qml/name).write_bytes(subprocess.check_output(['/usr/bin/git','show',args.before_revision+':qml/'+name], cwd=root))
            else:
                shutil.copyfile(root/'qml'/name, qml/name)
        home = run/'home'
        home.mkdir(mode=0o700)
        env = {'HOME':str(home), 'TMPDIR':str(run), 'PATH':'/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin',
               'LANG':'en_US.UTF-8', 'QT_QPA_PLATFORM':'offscreen', 'QT_QUICK_BACKEND':'software',
               'QML_DISABLE_DISK_CACHE':'1', 'QT_MEDIA_BACKEND':'ffmpeg',
               'GST_REGISTRY':str(run/'gstreamer-registry.bin'),
               'GST_PLUGIN_SYSTEM_PATH_1_0':str(isolated_plugins),
               'GST_PLUGIN_SCANNER_1_0':str(scanner),
               'WT_STREAM_WATCHDOG_OFF':'1', 'WT_RTSP_TCP':'1',
               'OMP_NUM_THREADS':'2', 'OPENBLAS_NUM_THREADS':'2', 'MKL_NUM_THREADS':'2'}
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0))
            port = sock.getsockname()[1]
        server = None
        try:
            with (run/'server.log').open('w') as server_log:
                server = subprocess.Popen([str(build/'stalled-rtsp-fixture'),str(port)], env=env,
                                          stdout=subprocess.PIPE, stderr=server_log, text=True)
                ready, _, _ = select.select([server.stdout], [], [], 10)
                if not ready:
                    raise RuntimeError('fixture readiness timeout')
                ready_line = server.stdout.readline()
                if not json.loads(ready_line).get('ready'):
                    raise RuntimeError('fixture did not signal readiness')
                with (run/'client.log').open('w') as client_log:
                    started = time.monotonic()
                    client = subprocess.run([str(build/'qml-stream-reconnect'),str(qml),
                                             'rtsp://127.0.0.1:%s/silent-stall'%port,'20000'],
                                            env=env, stdout=subprocess.PIPE, stderr=client_log,
                                            text=True, timeout=30)
                    elapsed = time.monotonic()-started
                stop_fixture(server)
                events_text = ready_line + server.stdout.read()
                (run/'server-events.jsonl').write_text(events_text)
                events = [json.loads(line) for line in events_text.splitlines()]
                # stdout contains the bounded structured pixel/transition result only.
                (run/'result.json').write_text(client.stdout)
                measured = json.loads(client.stdout)
                connections = sum(event.get('event') == 'connection' for event in events)
                stalled = any(event.get('event') == 'silent_stall' for event in events)
                if phase == 'before':
                    expected = client.returncode == 1 and not measured['passed'] \
                        and measured['initial_red_frames'] >= 10 and measured['qml_stall_detected_ms'] > 0 \
                        and measured['reconnected_blue_frames'] == 0 and measured['reconnect_runs'] == 0 \
                        and measured['watchdog_rebuilds'] == 0 and connections == 1 and stalled
                else:
                    expected = client.returncode == 0 and measured['passed'] and connections == 2 and stalled
                summary['runs'].append({'phase':phase,'expected_outcome_observed':expected,
                    'client_exit':client.returncode,'server_exit':server.returncode,'elapsed_seconds':round(elapsed,3),
                    'qml_hashes':{name:sha(qml/name) for name in ('VideoSurface.qml','ReconnectCoordinator.qml')},
                    'connections':connections,'silent_stall_observed':stalled,'measurement':measured})
        except Exception as exc:
            summary['runs'].append({'phase':phase,'expected_outcome_observed':False,'error':type(exc).__name__+': '+str(exc)})
            raise
        finally:
            if server is not None:
                stop_fixture(server)
            summary['fixture_processes_stopped'] = server is None or server.poll() is not None
            (evidence/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    summary['passed'] = all(row['expected_outcome_observed'] for row in summary['runs'])
    (evidence/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(json.dumps({'passed':summary['passed'],'evidence':str(evidence/'summary.json'),
                      'runs':[{key:row[key] for key in ('phase','client_exit','connections','elapsed_seconds')} for row in summary['runs']]}))
    return 0 if summary['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
