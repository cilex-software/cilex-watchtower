#!/usr/bin/env python3
"""Explicitly authorized isolated launchd recovery test; never the real GUI app.

Run only on a designated macOS test host. A unique temporary gui/<uid> job is
booted out in finally; existing LaunchAgents and application state are untouched.
The C fixture deliberately puts one child in another session to exercise exact
process-record reconciliation beyond launchd's ordinary group cleanup.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'warden'))
import warden_darwin as d


def wait_for(check, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(.05)
    raise RuntimeError('bounded readiness deadline expired')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--allow-launchd', action='store_true', help='explicit designated-test-Mac authorization')
    parser.add_argument('--evidence-dir', required=True)
    parser.add_argument('--warden-executable')
    parser.add_argument('--spawn-gate')
    parser.add_argument('--clean-environment', action='store_true', help='exercise system env -i exec and reject job-only environment contamination')
    args = parser.parse_args()
    if sys.platform != 'darwin' or not args.allow_launchd or os.getuid() == 0:
        parser.error('requires Darwin, non-root graphical user and explicit --allow-launchd')
    evidence = Path(args.evidence_dir).resolve()
    evidence.mkdir(parents=True, exist_ok=True, mode=0o700)
    result = {'schema': 1, 'test': 'isolated-darwin-launchd', 'status': 'failed',
              'configuration': {'os': os.uname().release, 'architecture': os.uname().machine,
                                'python': sys.version.split()[0]},
              'production_watchtower_exercised': False, 'startup_after_login': 'unverified',
              'reboot': 'unverified', 'clean_environment_launcher': args.clean_environment}
    label = 'com.cilexvision.test.warden.' + uuid.uuid4().hex
    domain = 'gui/' + str(os.getuid())
    job = domain + '/' + label
    own_rows = []
    loaded = False
    try:
        with tempfile.TemporaryDirectory(prefix='cilex launchd Тест ') as temp:
            base = Path(temp).resolve()
            gate = Path(args.spawn_gate).resolve() if args.spawn_gate else base / 'cilex-spawn-gate'
            executable = base / 'fixture-child'
            source = base / 'fixture.c'
            source.write_text('''#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
int main(void) {
 if(getenv("CILEX_FIXTURE_POLLUTION"))return 78;
 const char *base=getenv("FIXTURE_STATE"); if(!base)return 64;
 pid_t descendant=fork(); if(descendant<0)return 70;
 if(descendant==0) { if(setsid()<0)return 71; for(;;)pause(); }
 char path[4096]; snprintf(path,sizeof(path),"%s/child-ready",base);
 FILE *f=fopen(path,"w"); if(!f)return 73;
 fprintf(f,"%d %d %d",getpid(),getppid(),descendant); fclose(f);
 for(;;)pause();
}
''')
            if not args.spawn_gate:
                subprocess.run(['/usr/bin/cc', '-Wall', '-Wextra', '-Werror', str(ROOT / 'warden/darwin_spawn_gate.c'), '-o', str(gate)], check=True)
            subprocess.run(['/usr/bin/cc', '-Wall', '-Wextra', '-Werror', str(source), '-o', str(executable)], check=True)
            (base / 'home').mkdir(mode=0o700)
            (base / 'logs').mkdir(mode=0o700)
            environment = {'HOME': str(base / 'home'), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
                'WT_WARDEN_APP_CMD': str(executable), 'WT_WARDEN_SPAWN_GATE': str(gate),
                'WT_WARDEN_WARDEN_DIR': str(base / 'spool'), 'WT_WARDEN_DATA_DIR': str(base / 'data'),
                'WT_WARDEN_LOG_DIR': str(base / 'logs'), 'WT_WARDEN_INSTALLATION_ID': label,
                'WT_WARDEN_HANG_S': '0', 'WT_WARDEN_BACKEND_URL': '',
                'WT_WARDEN_STATION_TOKEN': '', 'FIXTURE_STATE': str(base)}
            command = [str(Path(args.warden_executable).resolve())] if args.warden_executable else ['/usr/bin/python3', str(ROOT / 'warden/warden.py')]
            arguments = command + ['run']
            inherited = environment
            if args.clean_environment:
                arguments = ['/usr/bin/env', '-i'] + [key + '=' + value for key, value in sorted(environment.items())] + arguments
                inherited = {'CILEX_FIXTURE_POLLUTION': 'fixture-only', 'PYTHONHOME': '/nonexistent/cilex-fixture',
                             'PYTHONPATH': '/nonexistent/cilex-fixture', 'DYLD_LIBRARY_PATH': '/nonexistent/cilex-fixture'}
            agent = {'Label': label, 'ProgramArguments': arguments,
                'WorkingDirectory': str(base), 'EnvironmentVariables': inherited,
                'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 10,
                'LimitLoadToSessionType': 'Aqua', 'AbandonProcessGroup': False,
                'ProcessType': 'Interactive', 'Umask': 0o077,
                'StandardOutPath': str(base / 'logs/warden-launchd.log'),
                'StandardErrorPath': str(base / 'logs/warden-launchd-error.log')}
            plist = base / (label + '.plist')
            plist.write_bytes(plistlib.dumps(agent))
            plist.chmod(0o600)
            subprocess.run(['/bin/launchctl', 'print', domain], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True, timeout=10)
            subprocess.run(['/bin/launchctl', 'bootstrap', domain, str(plist)], capture_output=True, check=True, timeout=10)
            loaded = True
            ready = base / 'child-ready'
            record = base / 'spool/process-guard/processes.json'

            def readiness(previous=None):
                if not ready.is_file() or not record.is_file():
                    return None
                try:
                    pids = [int(x) for x in ready.read_text().split()]
                    state = d.read_private_json(record)
                except (ValueError, json.JSONDecodeError):
                    return None
                if len(pids) != 3 or previous == pids[0]:
                    return None
                rows = [d.process_identity(pid) for pid in pids]
                if not all(rows):
                    return None
                child, warden, descendant = rows
                if child['ppid'] != warden['pid'] or warden['ppid'] != 1:
                    raise RuntimeError('direct launchd -> Warden -> fixture parentage failed')
                if not any(p['pid'] == descendant['pid'] for p in state['processes']):
                    return None
                if not d.same_process(state['owner'], warden):
                    return None
                own_rows.extend(rows + [state['guard']])
                return {'child': child, 'warden': warden, 'descendant': descendant, 'guard': state['guard']}

            try:
                before = wait_for(readiness, 60)
                if before['descendant']['session'] == before['child']['session']:
                    raise RuntimeError('fixture did not create detached-session descendant')
                start = time.monotonic()
                os.kill(before['warden']['pid'], signal.SIGKILL)
                after = wait_for(lambda: readiness(before['child']['pid']), 35)
                elapsed = time.monotonic() - start
                for role in ('child', 'warden', 'descendant', 'guard'):
                    if d.same_process(before[role], d.process_identity(before[role]['pid'])):
                        raise RuntimeError('old ' + role + ' overlaps replacement')
                result.update(status='passed', direct_parentage=True, observed_detached_descendant_cleanup=True,
                    warden_sigkill_recovery_seconds=round(elapsed, 3), no_overlap=True,
                    before=before, after=after)
            finally:
                stop = subprocess.run(['/bin/launchctl', 'bootout', job], capture_output=True, text=True, timeout=20)
                loaded = False
                if stop.returncode:
                    raise RuntimeError('test LaunchAgent bootout failed: ' + stop.stderr[:300])
                remaining = d.stop_records(own_rows)
                if remaining:
                    raise RuntimeError('temporary test process cleanup incomplete')
                check = subprocess.run(['/bin/launchctl', 'print', job], capture_output=True, timeout=10)
                result['cleanup_verified'] = check.returncode != 0
                for source_log in (base / 'logs').glob('*.log'):
                    (evidence / source_log.name).write_bytes(source_log.read_bytes())
                if record.is_file():
                    (evidence / 'final-process-record.json').write_bytes(record.read_bytes())
    except Exception as exc:
        result.update(status='failed', error=type(exc).__name__ + ': ' + str(exc))
    finally:
        if loaded:
            cleanup = subprocess.run(['/bin/launchctl', 'bootout', job], capture_output=True, timeout=20)
            result['last_resort_bootout_exit'] = cleanup.returncode
        (evidence / 'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
        print(json.dumps(result, indent=2))
    return 0 if result['status'] == 'passed' and result.get('cleanup_verified') else 1


if __name__ == '__main__':
    sys.exit(main())
