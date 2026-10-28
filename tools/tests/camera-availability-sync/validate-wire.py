#!/usr/bin/env python3
"""Validate the copied shared fixtures and generated client batches offline."""
import argparse
import hashlib
import json
from importlib.metadata import version
from pathlib import Path
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--batch', type=Path, action='append', default=[])
    parser.add_argument('--dependency-dir', type=Path)
    parser.add_argument('--result', type=Path)
    args = parser.parse_args()
    if args.dependency_dir:
        sys.path.insert(0, str(args.dependency_dir.resolve()))
    import jsonschema
    from referencing import Registry, Resource
    from referencing.jsonschema import DRAFT202012

    root = Path(__file__).resolve().parents[3] / 'docs/reference/camera-availability-v1'
    manifest = json.loads((root / 'manifest.json').read_text(encoding='utf-8'))
    checks = []
    for name, expected in manifest['files'].items():
        actual = hashlib.sha256((root / name).read_bytes()).hexdigest()
        checks.append(dict(check='shared fixture SHA-256', file=name, passed=actual == expected))
    resources = []
    for path in root.glob('*.schema.json'):
        schema = json.loads(path.read_text(encoding='utf-8'))
        resources.append((path.as_uri(), Resource.from_contents(schema, default_specification=DRAFT202012)))
    registry = Registry().with_resources(resources)
    pairs = [('valid-batch.json', 'batch.schema.json'), ('valid-reported-batch.json', 'batch.schema.json'),
             ('valid-monitoring-batch.json', 'batch.schema.json'), ('accepted-response.json', 'ack.schema.json'),
             ('duplicate-response.json', 'ack.schema.json'), ('capabilities-response.json', 'capabilities.schema.json'),
             ('changes-empty-response.json', 'changes.schema.json'), ('valid-scope.json', 'scope.schema.json')]
    pairs = [(root / value, schema) for value, schema in pairs]
    pairs += [(batch.resolve(), 'batch.schema.json') for batch in args.batch]
    for path, name in pairs:
        validator = jsonschema.Draft202012Validator({'$ref': (root / name).as_uri()}, registry=registry,
                                                   format_checker=jsonschema.FormatChecker())
        value = json.loads(path.read_text(encoding='utf-8'))
        errors = [dict(path=list(error.path), message=error.message) for error in validator.iter_errors(value)]
        checks.append(dict(check='JSON schema plus format', file=str(path), schema=name,
                           passed=not errors, errors=errors))
    result = dict(passed=all(check['passed'] for check in checks), checks=checks,
                  validator=version('jsonschema'), production_connections=False,
                  limitation='Structural/format validation; semantic authorization and idempotency require integration tests.')
    if args.result:
        args.result.write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(result))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
