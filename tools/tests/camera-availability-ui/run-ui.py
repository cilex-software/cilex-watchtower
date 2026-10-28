#!/usr/bin/env python3
"""Exercise shipping QML using an isolated, non-networked fixture module."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--qt-bin', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--russian', action='store_true')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    module = output / 'imports' / 'Watchtower'
    module.mkdir(parents=True)
    for name in ('Theme.qml', 'AvailabilityHistory.qml'):
        shutil.copyfile(repo / 'qml' / name, module / name)
    (output / 'fonts').mkdir()
    for name in ('SpaceGrotesk-Variable.ttf', 'JetBrainsMono-Regular.ttf'):
        shutil.copyfile(repo / 'assets' / 'fonts' / name, output / 'fonts' / name)
    shutil.copyfile(Path(__file__).with_name('tst_ui.qml'), output / 'tst_ui.qml')
    (module / 'qmldir').write_text('module Watchtower\nsingleton Theme 1.0 Theme.qml\nAvailabilityHistory 1.0 AvailabilityHistory.qml\n', encoding='utf-8')
    suffix = '.exe' if os.name == 'nt' else ''
    command = [str(args.qt_bin / ('qmltestrunner' + suffix)), '-input', str(output / 'tst_ui.qml'),
               '-import', str(module.parent), '-o', str(output / 'results.xml') + ',junitxml']
    if args.russian:
        qm = output / 'watchtower_ru.qm'
        subprocess.run([str(args.qt_bin / ('lrelease' + suffix)), str(repo / 'i18n/watchtower_ru.ts'), '-qm', str(qm)],
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        command += ['-translation', str(qm)]
    env = {key: value for key, value in os.environ.items() if not key.startswith('WT_')}
    env.update(QT_QPA_PLATFORM='offscreen', QT_QUICK_BACKEND='software', QT_QUICK_CONTROLS_STYLE='Basic',
               QT_PLUGIN_PATH=str(args.qt_bin.parent / 'plugins'), QML2_IMPORT_PATH=str(args.qt_bin.parent / 'qml'))
    if os.name == 'nt':
        env['QT_QPA_FONTDIR'] = str(Path(os.environ['SystemRoot']) / 'Fonts')
    result = subprocess.run(command, cwd=output, env=env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, timeout=60)
    (output / 'ui.log').write_text(result.stdout, encoding='utf-8')
    report = ET.parse(output / 'results.xml').getroot()
    testcases = list(report.iter('testcase'))
    failures = list(report.iter('failure')) + list(report.iter('error'))
    passed = result.returncode == 0 and len(testcases) >= 8 and not failures and (output / 'availability-history-ui.png').is_file()
    summary = dict(exit_code=result.returncode, passed=passed, tests=len(testcases), failures=len(failures), russian=args.russian, production_connections=False,
                   output=str(output), screenshot=str(output / 'availability-history-ui.png'))
    (output / 'result.json').write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
    print(result.stdout)
    print(json.dumps(summary))
    return 0 if passed else (result.returncode or 1)


if __name__ == '__main__':
    raise SystemExit(main())
