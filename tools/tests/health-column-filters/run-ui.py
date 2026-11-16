#!/usr/bin/env python3
"""Shipping HealthScreen QML; disposable camera/settings fixtures, no network."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--qt-bin', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--language', choices=('en', 'ru'), default='en')
    parser.add_argument('--width', type=int, choices=(1200, 1440), default=1440)
    parser.add_argument('--panel', choices=('open', 'closed'), default='closed')
    parser.add_argument('--case', help='Run one Qt test function instead of the whole suite')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    module = output/'imports/Watchtower'; module.mkdir(parents=True)
    names = ('HealthScreen', 'Icon', 'IconButton', 'StatusBadge', 'LiveStatusBadge',
             'RecordingStatusBadge', 'EmptyState', 'PlaceholderVid', 'AvailabilityHistory',
             'TitleBar', 'NavRail', 'TopBar', 'GroupSwitcher', 'StatusSummaryChip', 'WatchChip', 'AlertsDropdown')
    for name in (*names, 'Theme', 'EventStyle'):
        shutil.copyfile(repo/'qml'/(name+'.qml'), module/(name+'.qml'))
    # Only redirect the shell logo's resource URL for the standalone Qt test engine.
    nav = module/'NavRail.qml'
    nav.write_text(nav.read_text().replace('qrc:/images/cilex-logo.png', (repo/'assets/images/cilex-logo.png').as_uri()))
    for name in ('HealthFilters.js', 'GroupsStatus.js', 'WatchNames.js'):
        shutil.copyfile(repo/'qml'/name, module/name)
    shutil.copyfile(repo/'tools/tests/live-arrangement/fixtures/CameraStatus.qml', module/'CameraStatus.qml')
    (module/'Settings.qml').write_text('pragma Singleton\nimport QtQml\nQtObject { property bool badgeTimers: false; function clock(now, seconds) { return Qt.formatTime(new Date(now), "HH:mm") } }\n')
    (module/'AuthController.qml').write_text('pragma Singleton\nimport QtQml\nQtObject { property string username: "UI fixture"; property string role: "admin"; property string baseUrl: ""; property bool authenticated: true }\n')
    (module/'Watch.qml').write_text('pragma Singleton\nimport QtQml\nQtObject { property bool available: false; property string stationId: ""; property var watchstate: ({}); property bool onWatch: false; property string startedAt: ""; property string guardName: ""; property var roster: [] }\n')
    (module/'qmldir').write_text('module Watchtower\nsingleton Theme 1.0 Theme.qml\nsingleton EventStyle 1.0 EventStyle.qml\nsingleton Settings 1.0 Settings.qml\nsingleton AuthController 1.0 AuthController.qml\nsingleton Watch 1.0 Watch.qml\nCameraStatus 1.0 CameraStatus.qml\n'+
        ''.join(name+' 1.0 '+name+'.qml\n' for name in names))
    fonts = output/'fonts'; fonts.mkdir()
    for name in ('SpaceGrotesk-Variable.ttf', 'JetBrainsMono-Regular.ttf', 'JetBrainsMono-Medium.ttf', 'JetBrainsMono-SemiBold.ttf'):
        shutil.copyfile(repo/'assets/fonts'/name, fonts/name)
    source = Path(__file__).with_name('tst_ui.qml').read_text()
    (output/'tst_ui.qml').write_text(source.replace('@OUTPUT@', output.as_posix()).replace('@LANGUAGE@', args.language)
        .replace('@WIDTH@', str(args.width)).replace('@PANEL@', 'true' if args.panel == 'open' else 'false'))
    suffix = '.exe' if os.name == 'nt' else ''
    command = [str(args.qt_bin/('qmltestrunner'+suffix)), '-input', str(output/'tst_ui.qml'),
               '-import', str(module.parent), '-o', str(output/'results.xml')+',junitxml']
    if args.case:
        command.append('HealthColumnFilters::'+args.case)
    if args.language == 'ru':
        qm = output/'watchtower_ru.qm'
        subprocess.run([str(args.qt_bin/('lrelease'+suffix)), str(repo/'i18n/watchtower_ru.ts'), '-qm', str(qm)],
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        command += ['-translation', str(qm)]
    env = {key: value for key, value in os.environ.items() if not key.startswith(('WT_', 'QML_', 'QT_'))}
    env.update(QT_QPA_PLATFORM='offscreen', QT_QUICK_BACKEND='software', QT_QUICK_CONTROLS_STYLE='Basic',
               QT_PLUGIN_PATH=str(args.qt_bin.parent/'plugins'), QML2_IMPORT_PATH=str(args.qt_bin.parent/'qml'))
    result = subprocess.run(command, cwd=output, env=env, capture_output=True, text=True, timeout=160)
    (output/'ui.log').write_text(result.stdout+result.stderr)
    print(result.stdout[-6000:]+result.stderr[-6000:])
    if (output/'results.xml').is_file():
        report = ET.parse(output/'results.xml').getroot()
        print('Test cases:', len(list(report.iter('testcase'))), 'Failures:', len(list(report.iter('failure')))+len(list(report.iter('error'))))
    print('Evidence:', output)
    return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())
