import copy
import datetime
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import license_coverage as coverage
import deploy
from closure import sha256


class LicenseCoverageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='Cilex лицензии ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for path, data in (('watchtower.app/Contents/MacOS/watchtower', b'fixture-code'),
                           ('helpers/модуль.py', b'fixture-helper'),
                           ('licenses/Fixture.txt', b'Fixture notice and recorded distribution basis'),
                           ('licenses/source.tar.gz', b'fixture-source-archive')):
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            target.chmod(0o644)
        self.context = coverage.review_context({'commit': 'a' * 40}, {'version': '1', 'tree_sha256': 'b' * 64},
                                              {'python': 'fixture-version'}, {'python': 'c' * 64}, '1.2.3', '1.0')
        self.notice = {'path': 'licenses/Fixture.txt', 'sha256': sha256(self.root / 'licenses/Fixture.txt')}
        self.component = {'id': 'fixture', 'version': '1.0', 'license_expression': 'LicenseRef-Fixture',
                          'paths': coverage.payload_files(self.root), 'notices': [self.notice],
                          'source': {'kind': 'git', 'url': 'https://example.test/source.git', 'commit': 'a' * 40},
                          'redistribution': {'basis': 'Fixture reviewer records the basis in the notice.',
                                             'source_obligation': 'none-recorded', 'evidence': [self.notice]}}
        self.document = {'schema_version': 1, 'context': self.context,
                         'review': {'status': 'complete', 'reviewer': 'Fixture reviewer',
                                    'reviewed_at': '2026-01-01T00:00:00Z', 'scope': 'all-distributed-content',
                                    'attestation': coverage.ATTESTATION}, 'components': [self.component]}

    def check(self, document=None, **kwargs):
        return coverage.validate(document or self.document, self.root, self.context, **kwargs)

    def rejected(self, document=None, **kwargs):
        with self.assertRaises(coverage.LicenseCoverageError):
            self.check(document, **kwargs)

    def test_complete_review_is_structural_and_accepted_explicitly(self):
        value = self.check(accepted=True, production=True)
        self.assertEqual(value['status'], 'complete')
        self.assertEqual(value['legal_approval'], 'not-inferred')
        self.assertEqual(value['covered_file_count'], 2)
        self.rejected(production=True)

    def test_no_manifest_development_records_exact_uncovered_payload(self):
        report = coverage.record(self.root, self.context)
        self.assertEqual(report['status'], 'unverified')
        self.assertEqual(report['unassigned_paths'], sorted(self.component['paths']))
        self.assertIsNone(report['input_sha256'])
        self.assertTrue((self.root / 'licenses/COMPONENT-LICENSES.json').is_file())

    def test_missing_production_review_retains_draft_then_blocks(self):
        with self.assertRaises(coverage.LicenseCoverageError):
            coverage.record(self.root, self.context, accepted=True, production=True)
        self.assertTrue((self.root / 'licenses/LICENSE-COVERAGE.json').is_file())

    def test_input_manifest_digest_preserved(self):
        incoming = self.root / 'review-input.json'
        incoming.write_text(json.dumps(self.document))
        # The input is outside the payload so it cannot create a circular map.
        moved = self.root / 'licenses/input-review.json'
        incoming.rename(moved)
        value = coverage.record(self.root, self.context, moved, accepted=True, production=True)
        self.assertEqual(value['input_sha256'], sha256(moved))

    def test_changed_context_rejected_even_in_development(self):
        for key in ('source', 'helpers', 'dependencies', 'dependency_input_hashes', 'versions'):
            document = copy.deepcopy(self.document)
            document['context'][key]['changed'] = 'new identity'
            self.rejected(document)

    def test_every_payload_file_requires_coverage(self):
        self.component['paths'].pop()
        self.rejected()
        self.document['review']['status'] = 'draft'
        self.assertEqual(len(self.check()['unassigned_paths']), 1)

    def test_new_payload_after_review_blocks(self):
        (self.root / 'extra.dylib').write_bytes(b'new dependency')
        self.rejected()

    def test_unknown_and_repeated_paths_rejected(self):
        for value in ('unknown', self.component['paths'][0], '.', '../outside', '/absolute', 'helpers//module.py', 'helpers\\module.py'):
            document = copy.deepcopy(self.document)
            document['components'][0]['paths'].append(value)
            self.rejected(document)

    def test_several_components_can_share_embedded_archive(self):
        embedded = copy.deepcopy(self.component)
        embedded['id'] = 'embedded-code'
        embedded['paths'] = [self.component['paths'][0]]
        self.document['components'].append(embedded)
        self.assertEqual(self.check()['component_count'], 2)

    def test_duplicate_components_rejected(self):
        self.document['components'].append(copy.deepcopy(self.component))
        self.rejected()

    def test_bad_or_missing_notice_hash_rejected(self):
        self.notice['sha256'] = '0' * 64
        self.rejected()
        self.notice['path'] = 'licenses/missing.txt'
        self.rejected()

    def test_notice_cannot_escape_licenses_or_use_payload(self):
        self.notice['path'] = self.component['paths'][0]
        self.rejected()
        (self.root / 'licenses/escape').symlink_to('/etc/hosts')
        self.notice['path'] = 'licenses/escape'
        self.rejected()

    def test_source_reference_is_immutable_and_credential_free(self):
        for url in ('http://example.test/source', 'https://secret@example.test/source',
                    'https://example.test/source?token=secret', 'https://example.test/source#main'):
            document = copy.deepcopy(self.document)
            document['components'][0]['source']['url'] = url
            self.rejected(document)
        self.component['source']['commit'] = 'main'
        self.rejected()

    def test_archive_and_included_source_verified(self):
        self.component['source'] = {'kind': 'archive', 'url': 'https://example.test/source.tar.gz', 'sha256': 'd' * 64}
        self.assertEqual(self.check()['status'], 'complete')
        self.component['redistribution']['source_obligation'] = 'source-included'
        self.rejected()
        self.component['source'] = {'kind': 'bundled-source', 'path': 'licenses/source.tar.gz',
                                    'sha256': sha256(self.root / 'licenses/source.tar.gz')}
        self.assertEqual(self.check()['status'], 'complete')

    def test_decision_evidence_and_embedded_attestation_required(self):
        self.component['redistribution']['evidence'] = []
        self.rejected()
        self.component['redistribution']['evidence'] = [self.notice]
        self.document['review']['attestation'] = ''
        self.rejected()

    def test_review_timestamp_and_reviewer_required(self):
        for key, value in (('reviewer', ''), ('reviewed_at', 'tomorrow'),
                           ('reviewed_at', '2999-01-01T00:00:00Z'), ('scope', 'main-executable-only')):
            document = copy.deepcopy(self.document)
            document['review'][key] = value
            self.rejected(document)

    def test_schema_and_duplicate_json_keys(self):
        for version in (True, 0, 2, '1'):
            document = copy.deepcopy(self.document)
            document['schema_version'] = version
            self.rejected(document)
        path = self.root / 'duplicate.json'
        path.write_text('{"schema_version":1,"schema_version":2}')
        with self.assertRaises(coverage.LicenseCoverageError):
            coverage.read_manifest(path)

    def test_bounded_input(self):
        path = self.root / 'large.json'
        with path.open('wb') as stream:
            stream.truncate(coverage.MAX_MANIFEST_BYTES + 1)
        with self.assertRaises(coverage.LicenseCoverageError):
            coverage.read_manifest(path)

    def test_old_outputs_never_overwritten(self):
        path = self.root / 'licenses/LICENSE-COVERAGE.json'
        path.write_text('preserve')
        with self.assertRaises(coverage.LicenseCoverageError):
            coverage.record(self.root, self.context)
        self.assertEqual(path.read_text(), 'preserve')

    def test_cli_preserves_unicode_manifest_path(self):
        path = self.root / 'Рецензия с пробелами.json'
        options = deploy.normalize(deploy.parser().parse_args(['--language', 'en', '--license-manifest', str(path)]))
        self.assertEqual(options['license_manifest'], str(path))


if __name__ == '__main__':
    unittest.main()
