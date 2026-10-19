import copy
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
import zipfile
from unittest.mock import patch

import consume_bpy_distributable_source as source


class QualifiedSourceConsumerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)
        self.sha = 'a' * 40
        self.public = {
            'filename': 'NexGenVideo-bpy-5.2.2-corresponding-source.tar',
            'manifestFilename': 'NexGenVideo-bpy-5.2.2-corresponding-source.manifest.json',
            'sha256': hashlib.sha256(b'original').hexdigest(), 'size': 8,
            'manifestSHA256': hashlib.sha256(b'{}').hexdigest(), 'releaseTag': 'v0.9.1',
            'producer': {'repository': source.REPOSITORY, 'workflowPath': '.github/workflows/ci-batch.yml',
                         'runID': 42, 'sourceSHA': 'b' * 40, 'jobID': 9, 'jobAttempt': 2,
                         'artifactID': 7, 'artifactName': 'managed-bpy-source-' + 'b' * 40,
                         'artifactDigest': 'sha256:' + 'c' * 64, 'artifactSize': 1000}}
        self.lock = {'distributionStatus': 'ready', 'distributionClosure': {'publicSourceAsset': self.public}}

    def test_pins_require_fixed_release_and_complete_original_provenance(self):
        self.assertEqual(source.public_asset(self.lock), self.public)
        for field, value in [('releaseTag', 'latest'), ('sha256', ''), ('size', True), ('producer', {})]:
            lock = copy.deepcopy(self.lock)
            lock['distributionClosure']['publicSourceAsset'][field] = value
            with self.subTest(field=field), self.assertRaises((KeyError, ValueError)):
                source.public_asset(lock)
        for field, value in [('repository', 'other/repo'), ('workflowPath', '.github/workflows/ci.yml'),
                             ('sourceSHA', 'tag'), ('artifactName', 'other'), ('jobID', True)]:
            lock = copy.deepcopy(self.lock)
            lock['distributionClosure']['publicSourceAsset']['producer'][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                source.public_asset(lock)

    def receipt(self):
        return {'schema': source.SCHEMA, 'sourceSHA': self.sha, 'publicSourceAsset': copy.deepcopy(self.public),
                'origin': {'kind': 'actions', 'producer': copy.deepcopy(self.public['producer'])},
                'validation': {'archiveSHA256': self.public['sha256'],
                               'manifestSHA256': self.public['manifestSHA256']}}

    def test_handoff_cannot_replace_current_producer_pins_or_consumer_commit(self):
        original = self.receipt()
        source.require_receipt(original, self.public, self.sha)
        for change in ('sourceSHA', 'producer', 'manifest', 'extra'):
            receipt = copy.deepcopy(original)
            if change == 'sourceSHA': receipt['sourceSHA'] = 'e' * 40
            if change == 'producer': receipt['publicSourceAsset']['producer']['artifactID'] += 1
            if change == 'manifest': receipt['publicSourceAsset']['manifestSHA256'] = 'f' * 64
            if change == 'extra': receipt['extra'] = True
            with self.subTest(change=change), self.assertRaisesRegex(ValueError, 'receipt'):
                source.require_receipt(receipt, self.public, self.sha)

    def producer_metadata(self):
        producer = self.public['producer']
        run = {'id': 42, 'head_sha': producer['sourceSHA'], 'repository': {'full_name': source.REPOSITORY},
               'head_repository': {'full_name': source.REPOSITORY}, 'path': producer['workflowPath'],
               'event': 'workflow_dispatch', 'status': 'completed'}
        job = {'id': 9, 'run_id': 42, 'run_attempt': 2, 'head_sha': producer['sourceSHA'],
               'name': 'bpy-qualification / source', 'status': 'completed', 'conclusion': 'success',
               'labels': ['ubuntu-24.04'], 'started_at': '2026-10-19T10:00:00Z',
               'completed_at': '2026-10-19T10:10:00Z'}
        artifact = {'id': 7, 'name': producer['artifactName'], 'expired': False,
                    'workflow_run': {'id': 42, 'head_sha': producer['sourceSHA']},
                    'digest': producer['artifactDigest'], 'size_in_bytes': producer['artifactSize'],
                    'created_at': '2026-10-19T10:09:00Z', 'updated_at': '2026-10-19T10:09:30Z'}
        return run, artifact, job

    def test_original_source_must_be_successful_exact_job_artifact_and_attempt(self):
        run, artifact, job = self.producer_metadata()
        self.assertEqual(source.require_original_producer(self.public, run, [artifact], [job]), artifact)
        for change in ({'conclusion': 'failure'}, {'id': 10}, {'run_attempt': 3}, {'name': 'other / source'}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                source.require_original_producer(self.public, run, [artifact], [{**job, **change}])
        for change in ({'digest': 'sha256:' + 'd' * 64}, {'id': 8}, {'expired': True}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                source.require_original_producer(self.public, run, [{**artifact, **change}], [job])
        with self.assertRaises(ValueError):
            source.require_original_producer(self.public, {**run, 'path': '.github/workflows/ci.yml'}, [artifact], [job])

    def test_source_transfer_rejects_extra_duplicate_link_missing_or_oversized_members(self):
        wanted = [self.public['filename'], self.public['manifestFilename']]
        variants = [wanted + ['unexpected.json'], wanted + [wanted[0]], wanted[:-1], wanted]
        for index, names in enumerate(variants):
            payload = io.BytesIO()
            with zipfile.ZipFile(payload, 'w') as bundle:
                for name in names:
                    member = zipfile.ZipInfo(name)
                    if index == 3: member.external_attr = 0o120777 << 16
                    bundle.writestr(member, b'{}')
            target = self.root / str(index); target.mkdir()
            with self.subTest(index=index), self.assertRaises(ValueError):
                source.extract_original(payload, target, self.public)
        payload = io.BytesIO()
        with zipfile.ZipFile(payload, 'w') as bundle:
            bundle.writestr(wanted[0], b'oversized')
            bundle.writestr(wanted[1], b'{}')
        with self.assertRaises(ValueError): source.extract_original(payload, self.root, self.public)

    def test_both_public_hashes_are_required_before_distribution_validation(self):
        for name in (self.public['filename'], self.public['manifestFilename']):
            (self.root / self.public['filename']).write_bytes(b'original')
            (self.root / self.public['manifestFilename']).write_bytes(b'{}')
            source.require_pair(self.root, self.public)
            (self.root / name).write_bytes(b'corrupt')
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, 'public pins'):
                source.require_pair(self.root, self.public)

    def test_original_transfer_preserves_public_pair_without_reassembly(self):
        payload = io.BytesIO()
        with zipfile.ZipFile(payload, 'w') as bundle:
            bundle.writestr(self.public['filename'], b'original')
            bundle.writestr(self.public['manifestFilename'], b'{}')
            bundle.writestr('evidence.json', b'{}')
        source.extract_original(payload, self.root, self.public)
        archive, manifest = source.require_pair(self.root, self.public)
        self.assertEqual(archive.read_bytes(), b'original')
        self.assertEqual(manifest.read_bytes(), b'{}')
        self.assertEqual({p.name for p in self.root.iterdir()},
                         {self.public['filename'], self.public['manifestFilename']})

    def test_bad_published_bytes_never_fall_back_to_actions_or_produce_receipt(self):
        lock = self.root / 'lock.json'; lock.write_text(json.dumps(self.lock))
        destination = self.root / 'output'
        def corrupt_release(release, public, target):
            (target / public['filename']).write_bytes(b'corrupt!')
            (target / public['manifestFilename']).write_bytes(b'{}')
            return {'kind': 'release'}
        with patch.object(source, 'LOCK_PATH', lock), patch.object(source, 'released', return_value={'id': 1}), \
             patch.object(source, 'copy_release', side_effect=corrupt_release), \
             patch.object(source, 'copy_actions') as actions, patch.object(source, 'validate') as validator:
            with self.assertRaisesRegex(ValueError, 'public pins'):
                source.consume(destination, self.sha)
            actions.assert_not_called(); validator.assert_not_called()
        self.assertFalse((destination / source.RECEIPT).exists())

    def test_expired_unpublished_artifact_requires_explicit_requalification(self):
        run, artifact, job = self.producer_metadata()
        with patch.object(source, 'api', return_value=run), \
             patch.object(source, 'pages', return_value=[{**artifact, 'expired': True}]), \
             patch.object(source, 'download') as fetch:
            with self.assertRaisesRegex(ValueError, 'explicit source qualification rebuild'):
                source.copy_actions(self.public, self.root)
            fetch.assert_not_called()


if __name__ == '__main__':
    unittest.main()
