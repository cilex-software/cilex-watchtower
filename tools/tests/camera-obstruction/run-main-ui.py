#!/usr/bin/env python3
"""Run shipping Watchtower against a loopback-only incident/roster fixture."""
import argparse
import base64
import datetime
import http.server
import json
import os
from pathlib import Path
import subprocess
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--binary', type=Path, default=Path('build/watchtower'))
parser.add_argument('--interactive', action='store_true',
                    help='Open an isolated, manual UI preview; no real camera or report service is used.')
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=False)
repo = Path(__file__).resolve().parents[3]
requests = []
incidents = [dict(incident_id='fixture-a', camera_id='fixture-camera-a', camera_name='Fixture Hall A',
                  state='active', disposition='pending', alert_pending=True, suppressed=False,
                  can_disable_7d=False, detected_at='2026-10-12T10:00:00Z')]
preview_sequence = 0


def preview_incident(eligible=False):
    global preview_sequence
    preview_sequence += 1
    now = datetime.datetime.now(datetime.timezone.utc)
    return dict(incident_id=f'preview-{preview_sequence}', camera_id='fixture-camera-a',
                camera_name='SIMULATION — Hall A', state='active',
                disposition='pending', alert_pending=True, suppressed=False,
                can_disable_7d=False, false_alarm_streak=2 if eligible else 0,
                detected_at=now.isoformat(), suppressed_until='',
                report_status='simulation_only', evidence_status='no_clip_created')


if args.interactive:
    incidents[:] = [preview_incident()]

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *unused):
        pass

    def handle_request(self):
        size = int(self.headers.get('Content-Length', '0'))
        body = json.loads(self.rfile.read(size) or b'{}') if size else {}
        requests.append(dict(method=self.command, path=self.path, action=body.get('action')))
        status = 200
        path = self.path.split('?')[0]
        if path == '/auth/login':
            claims = dict(username='fixture-operator', role='admin', exp=int(time.time())+7200, camera_scope=[])
            payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip('=')
            response = dict(access_token='e30.' + payload + '.fixture')
        elif path == '/streams':
            prefix = 'SIMULATION — Hall ' if args.interactive else 'Fixture Hall '
            response = dict(streams=[dict(camera_id='fixture-camera-'+letter, name=prefix+letter.upper(),
                ip='127.0.0.'+str(i+10), mac='fixture-'+letter, status='online', recording='recording',
                rtsp_url='', rtsp_sub_url='', group_id='fixture', group_name='Test cameras')
                for i, letter in enumerate('ab')])
        elif path == '/groups':
            response = dict(groups=[dict(group_id='fixture', name='Test cameras', camera_count=2)])
        elif path == '/camera-visibility/incidents':
            response = dict(incidents=incidents, can_manage=True, enabled=True, service_status='running')
        elif path.startswith('/camera-visibility/incidents/') and path.endswith('/actions'):
            incident_id = path.split('/')[-2]
            incident = next(x for x in incidents if x['incident_id'] == incident_id)
            incident['alert_pending'] = False
            if body.get('action') == 'false_alarm':
                incident.update(disposition='false_alarm', suppressed=True,
                    suppressed_until='2099-01-01T06:00:00Z', report_status='queued', evidence_status='pending')
            elif body.get('action') == 'confirm':
                incident.update(disposition='confirmed')
            elif args.interactive and body.get('action') == 'disable_7d' and incident.get('can_disable_7d'):
                incident.update(suppressed=True, can_disable_7d=False,
                    suppressed_until=(datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(days=7)).isoformat())
            else:
                status = 400
            if args.interactive:
                incident.update(report_status='simulation_only', evidence_status='no_clip_created')
                if body.get('action') == 'false_alarm':
                    incident['suppressed_until'] = (datetime.datetime.now(datetime.timezone.utc)
                                                    + datetime.timedelta(hours=6)).isoformat()
                    incident['false_alarm_streak'] = incident.get('false_alarm_streak', 0) + 1
                    incident['can_disable_7d'] = incident['false_alarm_streak'] >= 3
            response = dict(incident=incident)
        elif args.interactive and self.command == 'POST' and path.startswith('/fixture/preview/'):
            scenario = path.rsplit('/', 1)[-1]
            if scenario in ('alarm', 'eligible'):
                incidents[:] = [preview_incident(eligible=scenario == 'eligible')]
            elif scenario == 'recover':
                for incident in incidents:
                    incident.update(state='resolved', alert_pending=False, suppressed=False,
                                    suppressed_until='', can_disable_7d=False)
            elif scenario == 'reset':
                incidents.clear()
            else:
                status = 400
            response = dict(ok=status == 200)
        elif path == '/fixture/next':
            if not any(x['incident_id'] == 'fixture-b' for x in incidents):
                incidents.append(dict(incident_id='fixture-b', camera_id='fixture-camera-b', camera_name='Fixture Hall B',
                    state='active', disposition='pending', alert_pending=True, suppressed=False,
                    can_disable_7d=False, detected_at='2026-10-12T10:01:00Z'))
            response = dict(ok=True)
        elif path == '/events':
            response = dict(events=[], total=0)
        else:
            status, response = 404, dict(detail='loopback fixture does not implement this endpoint')
        raw = json.dumps(response).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
    do_GET = handle_request
    do_POST = handle_request

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
env = {k:v for k,v in os.environ.items() if not k.startswith('WT_')}
env.update(QT_QPA_PLATFORM='offscreen', QT_QUICK_BACKEND='software', QSG_RHI_BACKEND='software',
    QT_QUICK_CONTROLS_STYLE='Fusion', WT_NO_SCHEME_REG='1', WT_NO_STATION_ENROL='1', WT_RESTORE_OFF='1',
    WT_CV_AUTOLOGIN='1', WT_CV_USER='fixture', WT_CV_PASS='fixture', WT_NO_STALL_WATCH='1',
    WT_CV_URL=f'http://127.0.0.1:{server.server_port}',
    WT_TEST_QML=str(Path(__file__).with_name('main-ui.qml')),
    XDG_CONFIG_HOME=str(output/'isolated-config'), XDG_DATA_HOME=str(output/'isolated-data'),
    XDG_CACHE_HOME=str(output/'isolated-cache'))
if args.interactive:
    # Keep the normal desktop platform; the automated harness remains offscreen.
    env.pop('QT_QPA_PLATFORM', None)
    if os.environ.get('QT_QPA_PLATFORM'):
        env['QT_QPA_PLATFORM'] = os.environ['QT_QPA_PLATFORM']
    for key in ('WT_QT_PREFIX', 'WT_BUILD_DIR'):
        if key in os.environ:
            env[key] = os.environ[key]
    env['WT_TEST_QML'] = str(Path(__file__).with_name('preview-ui.qml'))
    env['WT_WATCHDOG_OFF'] = '1'
argv = [str(args.binary.resolve()), '--obstruction-output='+str(output)]
started = datetime.datetime.now(datetime.timezone.utc).isoformat()
(output/'fixture.json').write_text(json.dumps(dict(url=env['WT_CV_URL'], interactive=args.interactive,
                                                  real_incidents=False, real_reports=False), indent=2)+'\n')
if args.interactive:
    print(f'Camera-obstruction UI SIMULATION. No live camera, alarm or report changes.\nEvidence: {output}', flush=True)
try:
    if args.interactive:
        # Stream to disk rather than accumulating an unbounded interactive log.
        with (output/'main-ui.log').open('w') as logfile:
            completed = subprocess.run(argv, cwd=repo, env=env, stdout=logfile, stderr=subprocess.STDOUT)
        log, exit_code = (output/'main-ui.log').read_text(), completed.returncode
    else:
        completed = subprocess.run(argv, cwd=repo, env=env, text=True, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, timeout=40)
        log, exit_code = completed.stdout, completed.returncode
except subprocess.TimeoutExpired as exc:
    log, exit_code = str(exc.stdout or ''), 124
finally:
    server.shutdown()
(output/'main-ui.log').write_text(log)
(output/'requests.json').write_text(json.dumps(requests, indent=2)+'\n')
summary = dict(started_at_utc=started, argv=argv, exit_code=exit_code,
               loopback_only=True, real_video_pixels_verified=False, live_actions=False,
               interactive=args.interactive)
(output/'run.json').write_text(json.dumps(summary, indent=2)+'\n')
for line in log.splitlines():
    if 'OBSTRUCTION-UI-' in line or 'Error:' in line or 'Binding loop' in line:
        print(line)
print(json.dumps(summary))
raise SystemExit(exit_code)
