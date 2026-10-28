#!/usr/bin/env python3
"""Shipping model/UI regression; loopback-only synthetic recording telemetry."""
import argparse
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import http.server
import json
import os
from pathlib import Path
import subprocess
import threading


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--qt-prefix', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--russian', action='store_true')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    fixture = {'phase': 'legacy', 'expiry': None}
    requests = []

    def health(capture='progressing', archive='current', ttl=60):
        now = datetime.now(timezone.utc)
        stamp = now.isoformat()
        until = (now + timedelta(seconds=ttl)).isoformat()
        lane = dict(expected=True, capture_state=capture, archive_state=archive,
                    archive_delay_s=240 if archive == 'delayed' else 10,
                    observed_at=stamp, valid_until=until,
                    last_available_end=(now-timedelta(seconds=10)).isoformat())
        return dict(version=1, observed_at=stamp, valid_until=until,
                    capture_state=capture, archive_state=archive,
                    archive_delay_s=lane['archive_delay_s'],
                    last_available_end=lane['last_available_end'],
                    incident_started_at=None,
                    streams=dict(main=dict(lane), sub=dict(lane)))

    def row(name, h=None, legacy='recording', status='online'):
        data = dict(camera_id=name, name=name.title(), ip='127.0.0.10', mac=name,
                    status=status, recording=legacy, group_id='fixture', group_name='Health fixture',
                    rtsp_url='', rtsp_sub_url='', last_segment_at='2026-10-27T12:54:00Z')
        if h is not None:
            data['recording_health'] = h
        return data

    def rows():
        if fixture['phase'] == 'legacy':
            return [row('legacy', legacy='stalled')]
        if fixture['phase'] == 'expiry':
            return [row('expiry', fixture['expiry'])]
        stale = health()
        stale['streams']['main']['valid_until'] = '2000-01-01T00:00:00Z'
        masked = health()
        masked['streams']['main']['capture_state'] = 'stopped'
        motion = health('idle', 'idle')
        disabled = health('disabled', 'disabled')
        for h in (motion, disabled):
            for lane in h['streams'].values():
                lane['expected'] = False
        return [row('legacy', legacy='stalled'), row('archiveunknown', health(archive='unknown')),
                row('delayed', health(archive='delayed'), legacy='stalled'),
                row('stopped', health('stopped')), row('unknown', health('unknown', 'unknown')),
                row('stale', stale), row('offline', health('unknown', 'unknown'), status='offline'),
                row('motion', motion, legacy='armed'), row('disabled', disabled, legacy='disabled'),
                row('masked', masked)]

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *unused):
            pass

        def handle_request(self):
            size = int(self.headers.get('Content-Length', '0'))
            self.rfile.read(size)
            path = self.path.split('?')[0]
            requests.append(dict(method=self.command, path=path))
            status = 200
            if path == '/auth/login':
                claims = dict(username='fixture', role='admin', exp=int(datetime.now().timestamp())+7200,
                              camera_scope=[])
                payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip('=')
                response = dict(access_token='e30.'+payload+'.fixture')
            elif path.startswith('/fixture/'):
                fixture['phase'] = path.rsplit('/', 1)[-1]
                if fixture['phase'] == 'expiry':
                    fixture['expiry'] = health(ttl=2)
                response = dict(ok=True)
            elif path == '/streams':
                status = 503 if fixture['phase'] == 'unavailable' else 200
                response = dict(streams=rows()) if status == 200 else dict(detail='fixture timeout')
            elif path == '/groups':
                response = dict(groups=[dict(group_id='fixture', name='Health fixture', camera_count=10)])
            elif path == '/events':
                response = dict(events=[], total=0)
            elif path == '/camera-visibility/incidents':
                response = dict(incidents=[], can_manage=True, enabled=False, service_status='disabled')
            else:
                status, response = 404, dict(detail='loopback-only fixture')
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
    env = {key: value for key, value in os.environ.items() if not key.startswith('WT_')}
    env.update(QT_QPA_PLATFORM='offscreen', QT_QUICK_BACKEND='software', QSG_RHI_BACKEND='software',
               QT_QUICK_CONTROLS_STYLE='Fusion', WT_NO_SCHEME_REG='1', WT_NO_STATION_ENROL='1',
               WT_RESTORE_OFF='1', WT_CV_AUTOLOGIN='1', WT_CV_USER='fixture', WT_CV_PASS='fixture',
               WT_NO_STALL_WATCH='1', WT_CV_URL=f'http://127.0.0.1:{server.server_port}',
               WT_TEST_QML=str(Path(__file__).with_name('ui.qml')),
               XDG_CONFIG_HOME=str(output/'config'), XDG_DATA_HOME=str(output/'data'),
               XDG_CACHE_HOME=str(output/'cache'),
               LD_LIBRARY_PATH=str(args.qt_prefix/'lib'),
               QT_PLUGIN_PATH=str(args.qt_prefix/'plugins'),
               QML2_IMPORT_PATH=str(args.qt_prefix/'qml'),
               QT_QML_IMPORT_PATH=str(args.qt_prefix/'qml'))
    if args.russian:
        env['WT_LANG'] = 'ru'
    argv = [str(args.binary.resolve()), '--health-output='+str(output)]
    started = datetime.now(timezone.utc).isoformat()
    try:
        completed = subprocess.run(argv, env=env, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, text=True, timeout=45)
        log, code = completed.stdout, completed.returncode
    except subprocess.TimeoutExpired as error:
        raw = error.stdout or b''
        log, code = raw.decode(errors='replace') if isinstance(raw, bytes) else raw, 124
    finally:
        server.shutdown()
    (output/'ui.log').write_text(log)
    (output/'requests.json').write_text(json.dumps(requests, indent=2)+'\n')
    summary = dict(started_at_utc=started, argv=argv, exit_code=code,
                   binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),
                   qt_prefix=str(args.qt_prefix), russian_requested=args.russian,
                   loopback_only=True, real_video_verified=False,
                   guardstation_deployed=False)
    (output/'run.json').write_text(json.dumps(summary, indent=2)+'\n')
    for line in log.splitlines():
        if 'RECORDING-HEALTH-' in line or 'Error:' in line or 'Binding loop' in line:
            print(line)
    print(json.dumps(summary))
    return code


if __name__ == '__main__':
    raise SystemExit(main())
