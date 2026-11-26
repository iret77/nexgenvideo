import copy
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import notarization_proof as proof_module


UUID = '12345678-1234-1234-1234-123456789abc'
APP_HASH = 'a' * 40
PACK_HASH = 'b' * 40


def own_hash(index):
    return '%040x' % (index + 1)


def sample_proof(dmg_sha256='d' * 64, mode='dmg-only'):
    own = {name: {'cdhash': APP_HASH if index == 0 else own_hash(index),
                  'ticketPath': 'NexGenVideo.dmg/NexGenVideo.app/' + name}
           for index, name in enumerate(proof_module.OWN_BINARIES)}
    hashes = sorted({APP_HASH, PACK_HASH, *(value['cdhash'] for value in own.values())})
    return {'schema': proof_module.SCHEMA, 'mode': mode, 'dmgSHA256': dmg_sha256, 'uploadedDMGSHA256': 'e' * 64,
            'submissionID': UUID, 'logSHA256': 'f' * 64,
            'app': {'cdhash': APP_HASH, 'ticketPath': 'NexGenVideo.dmg/NexGenVideo.app'},
            'pack': {'cdhash': PACK_HASH, 'ticketPath': 'NexGenVideo.dmg/musicvideo.ngvpack'},
            'ownBinaries': own, 'ticketCDHashes': hashes}


class FakeTools:
    """Answer codesign, stapler, spctl and notarytool like macOS for one exact DMG submission."""

    def __init__(self, root, hashes, log=None):
        self.root, self.hashes, self.log, self.calls = root, hashes, log, []
        self.stapled, self.assessment = set(), 'accepted\nsource=Notarized Developer ID\n'

    def __call__(self, arguments, log=None, timeout=120):
        arguments = [str(item) for item in arguments]
        self.calls.append(arguments)
        if arguments[:2] == ['codesign', '-d']:
            path = arguments[-1]
            for suffix, value in self.hashes.items():
                if path.endswith(suffix):
                    return 0, 'Executable=x\nflags=0x10000(runtime)\nCDHash=' + value + '\nTeamIdentifier=VG5X6JCLGF\n'
            return 1, 'not signed'
        if arguments[:3] == ['xcrun', 'stapler', 'validate']:
            return (0, 'The validate action worked!') if arguments[3] in self.stapled else (65, 'no ticket')
        if arguments[0] == 'spctl':
            return 0, self.assessment
        if arguments[:3] == ['xcrun', 'notarytool', 'log']:
            Path(arguments[-1]).write_text(json.dumps(self.log))
            return 0, ''
        raise AssertionError(arguments)


class NotarizationProofTests(unittest.TestCase):
    def fixture(self, root):
        app = root / 'NexGenVideo.app'
        for name in proof_module.OWN_BINARIES:
            (app / name).parent.mkdir(parents=True, exist_ok=True)
            (app / name).write_bytes(name.encode())
        pack = root / 'musicvideo.ngvpack'
        pack.mkdir()
        uploaded, dmg = root / 'uploaded.dmg', root / 'NexGenVideo.dmg'
        uploaded.write_bytes(b'unstapled dmg')
        dmg.write_bytes(b'stapled dmg')
        state = root / 'state'
        state.mkdir()
        digest = hashlib.sha256(b'unstapled dmg').hexdigest()
        (state / (digest + '.json')).write_text(json.dumps({'schema': 'release-notary/v1', 'sha256': digest,
                                                            'sourceSHA': 'c' * 40, 'submissionID': UUID}))
        hashes = {'NexGenVideo.app': APP_HASH, 'musicvideo.ngvpack': PACK_HASH,
                  **{name: (APP_HASH if index == 0 else own_hash(index))
                     for index, name in enumerate(proof_module.OWN_BINARIES)}}
        entries = [{'path': 'NexGenVideo.dmg', 'cdhash': '9' * 40, 'arch': '', 'digestAlgorithm': 'SHA-256'},
                   {'path': 'NexGenVideo.dmg/NexGenVideo.app', 'cdhash': APP_HASH.upper(), 'arch': 'arm64'},
                   {'path': 'NexGenVideo.dmg/musicvideo.ngvpack', 'cdhash': PACK_HASH, 'arch': 'arm64'}]
        entries += [{'path': 'NexGenVideo.dmg/NexGenVideo.app/' + name, 'cdhash': own_hash(index), 'arch': 'arm64'}
                    for index, name in enumerate(proof_module.OWN_BINARIES) if index]
        log = {'jobId': UUID, 'status': 'Accepted', 'sha256': digest, 'archiveFilename': 'NexGenVideo.dmg',
               'ticketContents': entries}
        environment = {'NOTARY_KEY_FILE': str(root / 'key.p8'), 'NOTARY_KEY_ID': 'KEY', 'NOTARY_ISSUER': 'ISSUER'}
        return app, pack, uploaded, dmg, state, FakeTools(root, hashes, log), environment

    def record(self, root, tools, environment, app, pack, uploaded, dmg, state, mode='dmg-only'):
        tools.stapled.add(str(dmg))
        with patch.object(proof_module, 'run', side_effect=tools):
            return proof_module.record(dmg, uploaded, app, pack, state, mode, root / 'proof.json',
                                       root / 'apple-log.json', environment)

    def test_record_binds_the_uploaded_submission_and_every_own_binary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, pack, uploaded, dmg, state, tools, environment = self.fixture(root)
            proof = self.record(root, tools, environment, app, pack, uploaded, dmg, state)
            self.assertEqual(proof['dmgSHA256'], hashlib.sha256(b'stapled dmg').hexdigest())
            self.assertEqual(proof['uploadedDMGSHA256'], hashlib.sha256(b'unstapled dmg').hexdigest())
            self.assertEqual(proof['app'], {'cdhash': APP_HASH, 'ticketPath': 'NexGenVideo.dmg/NexGenVideo.app'})
            self.assertEqual(json.loads((root / 'proof.json').read_text()), proof)
            self.assertIn(['xcrun', 'notarytool', 'log', UUID, '--key', str(root / 'key.p8'), '--key-id', 'KEY',
                           '--issuer', 'ISSUER', str(root / 'apple-log.json')], tools.calls)

    def test_record_rejects_foreign_rejected_or_incomplete_tickets(self):
        for variant in ('rejected', 'other-upload', 'other-job', 'missing-app', 'missing-helper', 'unstapled-dmg'):
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                app, pack, uploaded, dmg, state, tools, environment = self.fixture(root)
                if variant == 'rejected': tools.log['status'] = 'Invalid'
                if variant == 'other-upload': tools.log['sha256'] = '0' * 64
                if variant == 'other-job': tools.log['jobId'] = UUID.replace('1', '2')
                if variant == 'missing-app':
                    tools.log['ticketContents'] = [entry for entry in tools.log['ticketContents']
                                                   if entry['cdhash'].lower() != APP_HASH]
                if variant == 'missing-helper': tools.log['ticketContents'].pop()
                with self.assertRaises(ValueError):
                    if variant == 'unstapled-dmg':
                        with patch.object(proof_module, 'run', side_effect=tools):
                            proof_module.record(dmg, uploaded, app, pack, state, 'dmg-only', root / 'proof.json',
                                                root / 'apple-log.json', environment)
                    else:
                        self.record(root, tools, environment, app, pack, uploaded, dmg, state)
                self.assertFalse((root / 'proof.json').exists())

    def test_installed_dmg_only_copy_requires_ticket_coverage_and_notarized_assessment(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, pack, uploaded, dmg, state, tools, environment = self.fixture(root)
            proof = self.record(root, tools, environment, app, pack, uploaded, dmg, state)
            with patch.object(proof_module, 'run', side_effect=tools):
                result = proof_module.verify_installed(app, dmg, proof)
                self.assertEqual(result['cdhash'], APP_HASH)
                self.assertFalse(result['stapledApp'])
                tools.hashes['NexGenVideo.app'] = '7' * 40
                with self.assertRaisesRegex(ValueError, 'notarize_app_separately'):
                    proof_module.verify_installed(app, dmg, proof)
                tools.hashes['NexGenVideo.app'] = APP_HASH
                tools.assessment = 'accepted\nsource=Unnotarized Developer ID\n'
                with self.assertRaisesRegex(ValueError, 'notarized'):
                    proof_module.verify_installed(app, dmg, proof)
                tools.assessment = 'accepted\nsource=Notarized Developer ID\n'
                dmg.write_bytes(b'another dmg')
                with self.assertRaisesRegex(ValueError, 'another DMG'):
                    proof_module.verify_installed(app, dmg, proof)

    def test_bounded_summary_still_binds_the_dmg_and_app_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, pack, uploaded, dmg, state, tools, environment = self.fixture(root)
            proof = self.record(root, tools, environment, app, pack, uploaded, dmg, state)
            compact = proof_module.summary(proof)
            self.assertNotIn('ticketCDHashes', compact)
            self.assertEqual(compact['proofSHA256'], proof_module.canonical(proof))
            with patch.object(proof_module, 'run', side_effect=tools):
                self.assertEqual(proof_module.verify_installed(app, dmg, compact)['cdhash'], APP_HASH)
                tools.hashes['NexGenVideo.app'] = '7' * 40
                with self.assertRaises(ValueError):
                    proof_module.verify_installed(app, dmg, compact)
            for change in ({'extra': True}, {'mode': 'unknown'}, {'app': {'cdhash': 'x'}}):
                with self.subTest(change=sorted(change)), self.assertRaises(ValueError):
                    proof_module.validate_any(dict(compact, **change))
            with self.assertRaises(ValueError):
                proof_module.validate_any(compact, 'c' * 64)

    def test_two_submission_and_missing_proof_keep_the_per_app_staple(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, pack, uploaded, dmg, state, tools, environment = self.fixture(root)
            proof = self.record(root, tools, environment, app, pack, uploaded, dmg, state, mode='app-and-dmg')
            with patch.object(proof_module, 'run', side_effect=tools):
                for value in (None, proof):
                    with self.subTest(proof=value is not None), self.assertRaises(ValueError):
                        proof_module.verify_installed(app, dmg, value)
                tools.stapled.add(str(app))
                self.assertEqual(proof_module.verify_installed(app, dmg, None), {'mode': 'app-and-dmg', 'stapledApp': True})
                self.assertTrue(proof_module.verify_installed(app, dmg, proof)['stapledApp'])

    def test_validate_rejects_uncovered_or_inconsistent_records(self):
        proof_module.validate(sample_proof())
        for change in ({'mode': 'app-only'}, {'submissionID': 'x'}, {'ticketCDHashes': [APP_HASH]},
                       {'app': {'cdhash': '0' * 40}}, {'ticketCDHashes': sorted(sample_proof()['ticketCDHashes'])[::-1]}):
            broken = dict(sample_proof(), **change)
            with self.subTest(change=sorted(change)), self.assertRaises(ValueError):
                proof_module.validate(broken)
        broken = copy.deepcopy(sample_proof())
        broken['ownBinaries']['Contents/MacOS/NexGenVideo']['cdhash'] = own_hash(3)
        with self.assertRaises(ValueError):
            proof_module.validate(broken)
        with self.assertRaises(ValueError):
            proof_module.validate(sample_proof(), 'c' * 64)

    def test_diagnostic_copy_may_differ_from_the_installed_app_only_by_its_ticket(self):
        trees = {}
        def tree(path):
            return trees[Path(path).name if Path(path).name != 'NexGenVideo.app' else str(path)]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            installed, diagnostic = root / 'installed/NexGenVideo.app', root / 'diagnostic/NexGenVideo.app'
            trees[str(installed)], trees[str(diagnostic)] = 'mounted', 'mounted'
            self.assertEqual(proof_module.derived_diagnostic(installed, diagnostic, 'app-and-dmg', tree), 'mounted')
            trees[str(diagnostic)] = 'stapled'
            with self.assertRaises(ValueError):
                proof_module.derived_diagnostic(installed, diagnostic, 'app-and-dmg', tree)
            def tools(arguments, log=None, timeout=120):
                if arguments[0] == 'ditto':
                    trees[str(arguments[2])] = 'mounted'
                if arguments[:3] == ['xcrun', 'stapler', 'staple']:
                    trees[str(arguments[3])] = stapled
                return 0, ''
            for stapled, accepted in (('stapled', True), ('other', False)):
                with self.subTest(stapled=stapled), patch.object(proof_module, 'run', side_effect=tools):
                    if accepted:
                        self.assertEqual(proof_module.derived_diagnostic(installed, diagnostic, 'dmg-only', tree), 'stapled')
                    else:
                        with self.assertRaises(ValueError):
                            proof_module.derived_diagnostic(installed, diagnostic, 'dmg-only', tree)


if __name__ == '__main__':
    unittest.main()
