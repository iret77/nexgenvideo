from copy import deepcopy
import hashlib
import unittest

from bpy_directory_scan_acceptance import validate


class DirectoryScanEvidenceTests(unittest.TestCase):
    def proof(self):
        sha = hashlib.sha256(bytes([0xa5]) * 8192).hexdigest()
        return {'schema': 'nexgenvideo/bpy-directory-deletion/1',
                'events': ['enumerated', 'unlinked', 'missing', 'completed'], 'processIdentifier': 123,
                'queuedDevice': 1, 'queuedInode': 2, 'retainedDevice': 1, 'retainedInode': 3,
                'queuedDirectoryBytes': 0, 'interruptedDirectoryBytes': 0,
                'baselineFiles': 3, 'interruptedFiles': 2, 'followupFiles': 1, 'payloadBytes': 8192,
                'retainedBytes': 16384, 'interruptedRetainedBytes': 16384, 'followupRetainedBytes': 16384,
                'payloadSHA256': sha, 'retainedSHA256': sha}

    def test_exact_native_receipt_accepts_allocated_bytes_above_payload(self):
        validate(self.proof(), 123)

    def test_nonzero_directory_allocation_must_still_be_preserved(self):
        proof = self.proof()
        proof['queuedDirectoryBytes'] = proof['interruptedDirectoryBytes'] = 4096
        validate(proof, 123)
        proof['interruptedDirectoryBytes'] = 0
        with self.assertRaises(ValueError):
            validate(proof, 123)

    def test_order_and_missing_branch_are_required(self):
        for events in [['enumerated', 'unlinked', 'completed'], ['unlinked', 'enumerated', 'missing', 'completed'],
                       ['enumerated', 'unlinked', 'missing', 'missing', 'completed']]:
            proof = self.proof()
            proof['events'] = events
            with self.subTest(events=events), self.assertRaises(ValueError):
                validate(proof, 123)

    def test_wrong_process_or_vnode_identity_is_rejected(self):
        for key, value in [('processIdentifier', 124), ('queuedDevice', 4), ('queuedInode', 3)]:
            proof = self.proof()
            proof[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate(proof, 123)

    def test_accounting_and_original_payload_are_required(self):
        for key, value in [('baselineFiles', 2), ('interruptedFiles', 1), ('followupFiles', 2),
                           ('payloadBytes', 4096), ('retainedBytes', 4096),
                           ('interruptedRetainedBytes', 8192), ('followupRetainedBytes', 8192),
                           ('payloadSHA256', '0' * 64), ('retainedSHA256', '0' * 64)]:
            proof = self.proof()
            proof[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate(proof, 123)

    def test_incomplete_or_boolean_receipts_are_rejected(self):
        original = self.proof()
        for key in original:
            proof = deepcopy(original)
            del proof[key]
            with self.subTest(missing=key), self.assertRaises(ValueError):
                validate(proof, 123)
        for key, value in original.items():
            if type(value) is int:
                proof = deepcopy(original)
                proof[key] = True
                with self.subTest(boolean=key), self.assertRaises(ValueError):
                    validate(proof, 123)
