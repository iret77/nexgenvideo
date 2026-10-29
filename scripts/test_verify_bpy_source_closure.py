import copy
import hashlib
import json
import unittest

from verify_bpy_source_closure import validate_distribution_evidence


class Archive:
    def __init__(self, files):
        self.files = files

    def read(self, name):
        return self.files.get(name)

    @property
    def names(self):
        return set(self.files)


class DistributionEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.notice = 'Runtime/bpy/compliance/NOTICE.txt'
        coverage = {'schema': 'nexgenvideo/bpy-notice-coverage/1',
                    'components': {'wheel:bpy': [self.notice]}}
        self.files = {'evidence/correspondence.json': b'{"verified":true}',
                      'evidence/coverage.json': json.dumps(coverage).encode(),
                      'notices/distribution/NOTICE.txt': b'Exact license and copyright text'}
        def pin(repository, member):
            return {'path': repository, 'sha256': hashlib.sha256(self.files[member]).hexdigest()}
        self.lock = {'distributionClosure': {
            'wheelBinaryCorrespondence': pin('Runtime/bpy/compliance/correspondence.json', 'evidence/correspondence.json'),
            'noticeCoverage': pin('Runtime/bpy/compliance/coverage.json', 'evidence/coverage.json'),
            'noticeFiles': [pin(self.notice, 'notices/distribution/NOTICE.txt')]}}
        self.manifest = {'correspondenceEvidence': 'evidence/correspondence.json',
                         'noticeCoverageEvidence': 'evidence/coverage.json',
                         'sources': [{'component': 'wheel:bpy', 'noticePaths': ['notices/distribution/NOTICE.txt']}]}

    def test_exact_locked_evidence_is_accepted(self):
        validate_distribution_evidence(Archive(self.files), self.manifest, self.lock)

    def test_rewritten_notice_or_evidence_cannot_claim_completion(self):
        for member in self.files:
            with self.subTest(member=member):
                changed = dict(self.files, **{member: b'replaced bytes'})
                with self.assertRaisesRegex(ValueError, 'pin mismatch'):
                    validate_distribution_evidence(Archive(changed), self.manifest, self.lock)

    def test_source_cannot_reference_an_uncovered_notice(self):
        self.manifest['sources'][0]['noticePaths'] = ['notices/another.txt']
        with self.assertRaisesRegex(ValueError, 'mapping mismatch'):
            validate_distribution_evidence(Archive(self.files), self.manifest, self.lock)

    def test_candidate_member_or_flag_is_rejected(self):
        self.files['notices/bpy/NOTICE-CANDIDATE.json'] = b'{}'
        with self.assertRaisesRegex(ValueError, 'candidate-only'):
            validate_distribution_evidence(Archive(self.files), self.manifest, self.lock)
        del self.files['notices/bpy/NOTICE-CANDIDATE.json']
        self.manifest['sources'][0]['noticeCandidateOnly'] = False
        with self.assertRaisesRegex(ValueError, 'candidate-only'):
            validate_distribution_evidence(Archive(self.files), self.manifest, self.lock)

    def test_colliding_distribution_notice_names_are_rejected(self):
        other = copy.deepcopy(self.lock['distributionClosure']['noticeFiles'][0])
        other['path'] = 'Runtime/bpy/compliance/nested/NOTICE.txt'
        self.lock['distributionClosure']['noticeFiles'].append(other)
        with self.assertRaisesRegex(ValueError, 'collide'):
            validate_distribution_evidence(Archive(self.files), self.manifest, self.lock)


if __name__ == '__main__':
    unittest.main()
