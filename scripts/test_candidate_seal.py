import copy
import hashlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import candidate_seal as seal
from notarization_proof import summary
from test_notarization_proof import sample_proof


SOURCE = 'a' * 40
RUN = 500
DMG = 'd' * 64
SUITE = {'sourceSHA': SOURCE, 'completed': True, 'configuration': 'release', 'scope': 'all', 'filter': '',
         'phases': [{'name': 'app'}]}


def job(name, identifier, run_id=RUN, labels=('macrunner',), conclusion='success', steps=()):
    return {'id': identifier, 'name': name, 'labels': list(labels), 'status': 'completed', 'conclusion': conclusion,
            'run_id': run_id, 'head_sha': SOURCE, 'run_attempt': 1, 'started_at': '2026-11-26T10:00:00Z',
            'completed_at': '2026-11-26T11:00:00Z', 'steps': [{'name': step, 'conclusion': 'success'} for step in steps]}


class Producer:
    def __init__(self, *, tests_run=RUN, embedded=False):
        self.artifacts, self.payloads, self.runs = {}, {}, {}
        manifest = {'sourceSHA': SOURCE, 'runID': tests_run, 'appTreeSHA256': 'e' * 64,
                    'identity': {'version': '1.8.0', 'build': '141', 'sourceSHA': SOURCE, 'catalogURL': 'https://x'},
                    'nativeEvidence': ({'schema': 'fresh-release-tests/v1', 'suite': SUITE} if embedded else
                                       {'schema': seal.SEALED_TESTS, 'sourceSHA': SOURCE, 'runID': tests_run})}
        if not embedded:
            manifest['notaryMode'] = 'dmg-only'
        proof = sample_proof(DMG)
        producer = {'schema': 'nexgenvideo/release-workspace-producer/1', 'sourceSHA': SOURCE, 'runID': str(RUN),
                    'runAttempt': '1', 'dmgSHA256': DMG, 'notarization': summary(proof),
                    'app': {'NGVSourceCommit': SOURCE, 'CFBundleVersion': '141', 'CFBundleShortVersionString': '1.8.0'}}
        self.binding = {'manifest.json': manifest, 'release-workspace-producer.json': producer}
        if not embedded:
            self.binding.update({
                'notarization-proof.json': proof,
                'release-image-check.json': {'schema': 'nexgenvideo/release-image-check/1', 'passed': True,
                                             'dmgSHA256': DMG, 'expected': {'build': '141', 'version': '1.8.0',
                                                                            'sourceSHA': SOURCE, 'notaryMode': 'dmg-only'}}})
        self.jobs = {RUN: [job('release-gate', 1), job('release', 2), job('candidate-seal', 4, labels=('ubuntu-24.04',))]}
        tester = job('release-tests', 3, run_id=tests_run, steps=(seal.TEST_STEP,))
        self.jobs.setdefault(tests_run, []).append(tester)
        self.suite = dict(SUITE)
        self.add(RUN, 'release-candidate-binding', 10, 2)
        self.add(tests_run, 'release-tests-result', 11, 3)

    def add(self, run_id, name, identifier, job_id):
        self.artifacts[identifier] = {'run': run_id, 'name': name, 'job': job_id}

    def archive(self, identifier):
        item = self.artifacts[identifier]
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, 'w') as bundle:
            members = self.binding if item['name'] == 'release-candidate-binding' else {'suite.json': self.suite}
            for name, value in members.items():
                bundle.writestr(name, json.dumps(value))
        return stream.getvalue()

    def item(self, identifier):
        data = self.archive(identifier)
        run_id = self.artifacts[identifier]['run']
        return {'id': identifier, 'name': self.artifacts[identifier]['name'], 'size_in_bytes': len(data),
                'digest': 'sha256:' + hashlib.sha256(data).hexdigest(), 'expired': False,
                'workflow_run': {'id': run_id, 'head_sha': SOURCE}, 'created_at': '2026-11-26T10:30:00Z',
                'updated_at': '2026-11-26T10:30:01Z', 'expires_at': '2100-01-01T00:00:00Z'}

    def api(self, path):
        if path.startswith('actions/artifacts/'):
            return self.item(int(path.rsplit('/', 1)[1]))
        parts = path.split('/')
        run_id = int(parts[2].split('?')[0])
        if len(parts) == 3:
            return {'id': run_id, 'head_sha': SOURCE, 'run_attempt': 1, 'path': '.github/workflows/release.yml',
                    'event': 'workflow_dispatch', 'repository': {'full_name': seal.REPOSITORY}}
        if parts[3] == 'attempts':
            return {'total_count': len(self.jobs[run_id]), 'jobs': self.jobs[run_id]}
        name = path.split('name=', 1)[1].split('&', 1)[0]
        matches = [{'id': key} for key, value in self.artifacts.items() if value['run'] == run_id and value['name'] == name]
        return {'total_count': len(matches), 'artifacts': matches}

    def download(self, item, destination):
        destination.write_bytes(self.archive(item['id']))


class CandidateSealTests(unittest.TestCase):
    def seal(self, producer, root):
        environment = {'GITHUB_REPOSITORY': seal.REPOSITORY, 'GITHUB_JOB': 'candidate-seal', 'GITHUB_RUN_ATTEMPT': '1',
                       'GITHUB_RUN_ID': str(RUN), 'GITHUB_SHA': SOURCE}
        with patch.dict(os.environ, environment), patch.object(seal, 'api', side_effect=producer.api), \
                patch.object(seal, 'download', side_effect=producer.download):
            return seal.seal(root / 'seal')

    def test_parallel_candidate_seals_fresh_tests_and_product_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            record = self.seal(Producer(), Path(directory))
            self.assertEqual(record['tests']['schema'], 'fresh-release-tests/v1')
            self.assertEqual(record['tests']['origin']['runID'], RUN)
            self.assertEqual(record['product']['notaryMode'], 'dmg-only')
            self.assertEqual(record['dmgSHA256'], DMG)
            saved = json.loads((Path(directory) / 'seal/release-candidate-seal.json').read_text())
            self.assertEqual(seal.verify_record(saved, SOURCE, RUN), saved)

    def test_continuation_seals_the_original_runs_tests(self):
        with tempfile.TemporaryDirectory() as directory:
            record = self.seal(Producer(tests_run=400), Path(directory))
            self.assertEqual(record['tests']['origin']['runID'], 400)

    def test_embedded_legacy_tests_are_recorded_without_new_product_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            record = self.seal(Producer(embedded=True), Path(directory))
            self.assertEqual(record['tests'], {'schema': 'fresh-release-tests/v1', 'embedded': True})
            self.assertNotIn('product', record)

    def test_any_failed_or_foreign_part_voids_the_candidate(self):
        def failed_tests(producer): producer.jobs[RUN][-1]['steps'][0]['conclusion'] = 'failure'
        def cancelled_tests(producer): producer.jobs[RUN][-1]['conclusion'] = 'cancelled'
        def foreign_suite(producer): producer.suite['sourceSHA'] = 'b' * 40
        def filtered_suite(producer): producer.suite['filter'] = 'NexGenVideoTests.Only'
        def reused_suite(producer): producer.suite['phases'] = [{'reusedFrom': 1}]
        def missing_image(producer): producer.binding.pop('release-image-check.json')
        def image_failed(producer): producer.binding['release-image-check.json']['passed'] = False
        def stray_offline(producer): producer.binding['offline-gatekeeper.json'] = {'passed': True}
        def image_build(producer): producer.binding['release-image-check.json']['expected']['build'] = '140'
        def other_dmg(producer): producer.binding['release-workspace-producer.json']['dmgSHA256'] = 'c' * 64
        def mode_mismatch(producer): producer.binding['manifest.json']['notaryMode'] = 'app-and-dmg'
        def release_failed(producer): producer.jobs[RUN][1]['conclusion'] = 'failure'
        def foreign_label(producer): producer.jobs[RUN][-1]['labels'] = ['ubuntu-24.04']
        for change in (failed_tests, cancelled_tests, foreign_suite, filtered_suite, reused_suite, missing_image,
                       image_failed, stray_offline, image_build, other_dmg, mode_mismatch, release_failed, foreign_label):
            with self.subTest(change=change.__name__), tempfile.TemporaryDirectory() as directory:
                producer = Producer()
                change(producer)
                with self.assertRaises(ValueError):
                    self.seal(producer, Path(directory))
                self.assertFalse((Path(directory) / 'seal').exists())

    def test_record_verification_rejects_other_runs_and_unsealed_tests(self):
        with tempfile.TemporaryDirectory() as directory:
            record = self.seal(Producer(), Path(directory))
        for change in ({'runID': RUN + 1}, {'harnessSourceSHA': 'b' * 40}, {'notaryMode': 'none'}):
            with self.subTest(change=sorted(change)), self.assertRaises(ValueError):
                seal.verify_record(dict(record, **change), SOURCE, RUN)
        broken = copy.deepcopy(record)
        broken['tests']['suite']['completed'] = False
        with self.assertRaises(ValueError):
            seal.verify_record(broken, SOURCE, RUN)
        broken = copy.deepcopy(record)
        broken.pop('product')
        with self.assertRaises(ValueError):
            seal.verify_record(broken, SOURCE, RUN)


if __name__ == '__main__':
    unittest.main()
