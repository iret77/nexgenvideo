import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import compiled_app_release as release


class CompiledAppReleaseTests(unittest.TestCase):
    def source_reuse_fixture(self):
        public = json.loads(Path('Runtime/bpy/runtime-lock.json').read_text())['distributionClosure']['publicSourceAsset']
        original = {'schema': 'nexgenvideo/bpy-source-receipt/1', 'sourceSHA': release.RETAINED_SOURCE,
            'publicSourceAsset': public, 'origin': {'kind': 'actions', 'producer': public['producer']},
            'validation': {'archiveSHA256': public['sha256'], 'manifestSHA256': public['manifestSHA256'], 'sourceFiles': 123}}
        raw = json.dumps(original, indent=2) + '\n'
        origin = dict(release.SIGNED_RESUME, sourceReceiptSHA256=hashlib.sha256(raw.encode()).hexdigest())
        receipt = dict(original, sourceSHA=origin['sourceSHA'])
        derived = json.dumps(receipt, indent=2) + '\n'
        producer = public['producer']
        run = {'id': producer['runID'], 'head_sha': producer['sourceSHA'], 'repository': {'full_name': release.REPOSITORY},
            'head_repository': {'full_name': release.REPOSITORY}, 'run_attempt': 1, 'status': 'completed',
            'event': 'workflow_dispatch', 'path': producer['workflowPath']}
        job = {'id': producer['jobID'], 'run_id': producer['runID'], 'head_sha': producer['sourceSHA'],
            'run_attempt': 1, 'status': 'completed', 'conclusion': 'success', 'labels': ['ubuntu-24.04'],
            'name': 'bpy-qualification / source', 'started_at': '2026-11-01T00:00:00Z', 'completed_at': '2026-11-01T01:00:00Z'}
        artifact = {'id': producer['artifactID'], 'name': producer['artifactName'], 'digest': producer['artifactDigest'],
            'size_in_bytes': producer['artifactSize'], 'expired': False,
            'workflow_run': {'id': producer['runID'], 'head_sha': producer['sourceSHA']},
            'created_at': '2026-11-01T00:30:00Z', 'updated_at': '2026-11-01T00:30:01Z', 'expires_at': '2099-01-01T00:00:00Z'}
        reuse = {'schema': 'compiled-bpy-source-receipt-reuse/v1', 'state': 'REUSED', 'signedProduct': origin,
            'originalReceiptSHA256': origin['sourceReceiptSHA256'], 'originalConsumerSourceSHA': release.RETAINED_SOURCE,
            'productSourceSHA': origin['sourceSHA'], 'harnessSourceSHA': 'c' * 40, 'runID': 777, 'attempt': 1, 'job': 'release',
            'publicSourceAsset': public, 'originalValidation': original['validation'], 'semanticSourceValidationPerformed': False,
            'derivedReceiptSHA256': hashlib.sha256(derived.encode()).hexdigest(), 'archiveSHA256': public['sha256'],
            'manifestSHA256': public['manifestSHA256'], 'originEvidence': {'run': run, 'job': job, 'artifact': artifact},
            'acquiredAt': '2026-11-02T00:00:00Z'}
        value = {'bpy-source-original-receipt.json': raw, 'bpy-source-receipt.json': derived,
            'bpy-source-reuse.json': json.dumps(reuse)}
        return origin, value, receipt, reuse

    def test_source_receipt_derivation_preserves_original_bytes_and_semantics_without_revalidation(self):
        import consume_bpy_distributable_source as source
        origin, value, receipt, reuse = self.source_reuse_fixture()
        with patch.object(release, 'SIGNED_RESUME', origin), patch.object(source, 'validate') as semantic:
            actual, proof = release.verify_source_reuse(value, origin['sourceSHA'], 'c' * 40, 777)
            self.assertEqual(actual, receipt)
            self.assertEqual(proof['originalValidation'], json.loads(value['bpy-source-original-receipt.json'])['validation'])
            source.require_receipt(actual, actual['publicSourceAsset'], origin['sourceSHA'])
            with self.assertRaises(ValueError):
                source.require_receipt(json.loads(value['bpy-source-original-receipt.json']), actual['publicSourceAsset'], origin['sourceSHA'])
            semantic.assert_not_called()

    def test_source_reuse_rejects_changed_original_receipt_derived_consumer_and_fresh_claim(self):
        origin, value, receipt, reuse = self.source_reuse_fixture()
        mutations = [('bpy-source-original-receipt.json', 'sourceSHA', 'a' * 40),
            ('bpy-source-receipt.json', 'sourceSHA', release.RETAINED_SOURCE),
            ('bpy-source-receipt.json', 'validation', {}), ('bpy-source-reuse.json', 'harnessSourceSHA', 'a' * 40),
            ('bpy-source-reuse.json', 'runID', 778), ('bpy-source-reuse.json', 'semanticSourceValidationPerformed', True),
            ('bpy-source-reuse.json', 'originalValidation', {}), ('bpy-source-reuse.json', 'signedProduct', {})]
        with patch.object(release, 'SIGNED_RESUME', origin):
            for name, key, changed in mutations:
                broken = dict(value); record = json.loads(broken[name]); record[key] = changed; broken[name] = json.dumps(record)
                with self.subTest(name=name, key=key), self.assertRaises(ValueError):
                    release.verify_source_reuse(broken, origin['sourceSHA'], 'c' * 40, 777)
            for name in value:
                with self.subTest(missing=name), self.assertRaises(ValueError):
                    release.verify_source_reuse({key: raw for key, raw in value.items() if key != name}, origin['sourceSHA'], 'c' * 40, 777)

    def test_source_reuse_rejects_foreign_producer_artifact_failure_and_acquisition_chronology(self):
        origin, value, receipt, reuse = self.source_reuse_fixture()
        mutations = [('run', 'head_sha', 'a' * 40), ('run', 'repository', {'full_name': 'other/repo'}),
            ('run', 'run_attempt', 2), ('job', 'name', 'unrelated'), ('job', 'conclusion', 'failure'),
            ('job', 'labels', ['macrunner']), ('artifact', 'digest', 'sha256:' + '0' * 64),
            ('artifact', 'expired', True), ('artifact', 'size_in_bytes', 1),
            ('artifact', 'created_at', '2026-11-01T02:00:00Z'), ('artifact', 'expires_at', '2026-11-01T02:00:00Z')]
        with patch.object(release, 'SIGNED_RESUME', origin):
            for section, key, changed in mutations:
                broken = copy.deepcopy(reuse); broken['originEvidence'][section][key] = changed
                values = dict(value, **{'bpy-source-reuse.json': json.dumps(broken)})
                with self.subTest(section=section, key=key), self.assertRaises(ValueError):
                    release.verify_source_reuse(values, origin['sourceSHA'], 'c' * 40, 777)

    def test_source_pair_commit_rejects_replaced_or_linked_destination_before_outside_writes(self):
        for changed in ('valid', 'replaced', 'linked', 'occupied', 'linked-parent'):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); stage = root / 'stage'; stage.mkdir()
                base = root / 'owned'; base.mkdir(); directory = base / 'sources'; directory.mkdir()
                outside = root / 'outside'; outside.mkdir()
                public = {'filename': 'source.tar', 'manifestFilename': 'manifest.json', 'size': 6,
                    'sha256': hashlib.sha256(b'source').hexdigest(), 'manifestSHA256': hashlib.sha256(b'manifest').hexdigest()}
                (stage / 'source.tar').write_bytes(b'source'); (stage / 'manifest.json').write_bytes(b'manifest')
                anchor = release.source_directory_identity(directory, base)
                if changed in ('replaced', 'linked'):
                    directory.rename(base / 'original')
                    directory.mkdir() if changed == 'replaced' else directory.symlink_to(outside, target_is_directory=True)
                elif changed == 'occupied': (directory / 'source.tar').write_bytes(b'occupied')
                elif changed == 'linked-parent':
                    base.rename(root / 'retired'); base.symlink_to(outside, target_is_directory=True)
                if changed == 'valid':
                    release.commit_source_pair(stage, directory, public, base, anchor)
                    self.assertEqual((directory / 'source.tar').read_bytes(), b'source')
                else:
                    with self.assertRaises((ValueError, FileExistsError)):
                        release.commit_source_pair(stage, directory, public, base, anchor)
                self.assertEqual(list(outside.iterdir()), [])

    def test_source_receivers_require_their_actual_linux_or_macos_context(self):
        parent = {'producerSourceSHA': 'c' * 40}
        for context, job, system in [('bpy-runtime', 'runtime', 'darwin'),
                ('workspace-source-preflight', 'runtime', 'linux'), ('settings-restore', 'acceptance', 'darwin')]:
            env = {'GITHUB_ACTIONS': 'true', 'GITHUB_REPOSITORY': release.REPOSITORY,
                'GITHUB_RUN_ATTEMPT': '1', 'GITHUB_JOB': job, 'GITHUB_SHA': 'c' * 40}
            with self.subTest(context=context), patch.dict(os.environ, env), patch.object(release.sys, 'platform', system):
                release.source_receiver_context(context, parent)
                with patch.dict(os.environ, GITHUB_SHA='d' * 40), self.assertRaises(ValueError):
                    release.source_receiver_context(context, parent)
                with patch.object(release.sys, 'platform', 'other'), self.assertRaises(ValueError):
                    release.source_receiver_context(context, parent)

    def test_signature_reuse_proof_rejects_original_or_current_product_substitution(self):
        origin = release.SIGNED_RESUME
        binding = {'productSourceSHA': origin['sourceSHA'], 'producerSourceSHA': 'c' * 40, 'runID': 777}
        value = {'schema': 'current-app-signature-reuse/v1', 'state': 'REUSED', 'original': origin,
            'command': release.SIGNATURE_COMMAND, 'recordSHA256': release.SIGNATURE_RECORD_SHA256,
            'current': {'productSourceSHA': origin['sourceSHA'], 'harnessSourceSHA': 'c' * 40,
                'runID': 777, 'job': 'release', 'appTreeSHA256': origin['appTreeSHA256']},
            'currentNativeSignatureVerificationPerformed': False, 'freshTrustStoreOrRevocationClaimed': False}
        release.verify_current_signature_reuse(value, binding)
        for section, key, changed in [('current', 'runID', 778), ('current', 'appTreeSHA256', 'f' * 64),
                ('original', 'runID', 123), ('recordSHA256', 'exit.json', 'f' * 64)]:
            broken = copy.deepcopy(value); broken[section][key] = changed
            with self.subTest(section=section, key=key), self.assertRaises(ValueError):
                release.verify_current_signature_reuse(broken, binding)

    def test_signed_resume_requires_actual_compiled_builder_stages_and_exact_manifest(self):
        for changed in ('valid', 'legacy-only', 'builder', 'actor', 'run-source', 'manifest', 'payload-size'):
            with self.subTest(changed=changed):
                raw = b'exact manifest'; origin = dict(release.SIGNED_RESUME, manifestSHA256=hashlib.sha256(raw).hexdigest())
                run = {'id': origin['runID'], 'head_sha': origin['sourceSHA'], 'repository': {'full_name': release.REPOSITORY},
                    'actor': {'login': 'iret77'}, 'run_attempt': 1, 'path': '.github/workflows/release.yml',
                    'event': 'workflow_dispatch', 'status': 'completed', 'conclusion': 'failure'}
                names = ['Assemble and sign the new App with unchanged retained components',
                    'Record compiled App signed input without invoking a build', 'Retain signed build input', 'Retain signed build proof']
                builder = {'id': origin['builderJobID'], 'run_id': origin['runID'], 'head_sha': origin['sourceSHA'],
                    'run_attempt': 1, 'name': 'release-build', 'labels': ['macrunner'], 'status': 'completed', 'conclusion': 'success',
                    'steps': [{'name': name, 'conclusion': 'success'} for name in names]}
                manifest = {'nativeEvidence': {'schema': 'release-native-compiled-app/v4'},
                    'identity': {'version': '1.8.0', 'build': '106', 'sourceSHA': origin['sourceSHA'],
                        'catalogURL': 'https://github.com/iret77/nexgenvideo/releases/download/plugins/catalog.json'},
                    'appTreeSHA256': origin['appTreeSHA256'], 'files': {'NexGenVideo.zip': {'sha256': origin['appArchiveSHA256']},
                        'bpy-source-receipt.json': {'sha256': origin['sourceReceiptSHA256']}}}
                payload = {'size_in_bytes': origin['artifactBytes']}
                if changed == 'legacy-only': builder['steps'][0]['name'] = 'Build and sign app'
                elif changed == 'builder': builder['id'] += 1
                elif changed == 'actor': run['actor']['login'] = 'other'
                elif changed == 'run-source': run['head_sha'] = 'f' * 40
                elif changed == 'manifest': raw += b'changed'
                elif changed == 'payload-size': payload['size_in_bytes'] += 1
                raw_json = json.dumps(manifest).encode()
                if changed != 'manifest': origin['manifestSHA256'] = hashlib.sha256(raw_json).hexdigest(); raw = raw_json
                with patch.object(release, 'SIGNED_RESUME', origin), patch.object(release.checkpoint, 'verify_manifest', return_value=manifest), \
                        patch.object(release, 'verify_artifact') as verifier:
                    if changed == 'valid':
                        result = release.verify_signed_resume(run, builder, payload, {}, raw, verifier=verifier)
                        self.assertEqual(result['original'], origin)
                        self.assertFalse(result['freshCompilerCoreAssemblyOrRootSignPerformed'])
                        self.assertEqual(verifier.call_count, 2)
                    else:
                        with self.assertRaises(ValueError): release.verify_signed_resume(run, builder, payload, {}, raw, verifier=verifier)

    def test_source_consumers_reuse_exact_receipt_and_pair_in_all_three_real_contexts(self):
        import consume_bpy_distributable_source as source
        import retained_packaging as packaging
        for context, job, system in [('bpy-runtime', 'runtime', 'darwin'),
                ('workspace-source-preflight', 'runtime', 'linux'), ('settings-restore', 'acceptance', 'darwin')]:
            for changed in ('valid', 'input-receipt', 'replaced-during-acquisition'):
                with self.subTest(context=context, changed=changed), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary); runner = root / 'runner'; runner.mkdir(); outside = root / 'outside'; outside.mkdir()
                    directory, evidence = runner / 'qualified', runner / 'evidence/reused.json'
                    public = {'filename': 'source.tar', 'manifestFilename': 'manifest.json', 'size': 6,
                        'sha256': hashlib.sha256(b'source').hexdigest(), 'manifestSHA256': hashlib.sha256(b'manifest').hexdigest(),
                        'producer': {'runID': 123}}
                    receipt = {'schema': source.SCHEMA, 'sourceSHA': release.SIGNED_RESUME['sourceSHA'], 'publicSourceAsset': public,
                        'origin': {'kind': 'actions'}, 'validation': {'archiveSHA256': public['sha256'], 'manifestSHA256': public['manifestSHA256']}}
                    raw = json.dumps(receipt, indent=4) + '\n'
                    value = {'bpy-source-receipt.json': raw, 'bpy-source-reuse.json': '{"state":"REUSED"}\n'}
                    parent = {'stage': 'complete', 'producerSourceSHA': 'c' * 40, 'runID': 777,
                        'final': {'bpySourceReuse': value, 'bpySourceReceiptSHA256': hashlib.sha256(raw.encode()).hexdigest()}}
                    binding = {'selector': 'authenticated canonical proof'}
                    input_receipt = runner / 'receipt.json'; input_receipt.write_text(raw if changed != 'input-receipt' else '{}')
                    def acquire(public, stage):
                        (stage / 'source.tar').write_bytes(b'source'); (stage / 'manifest.json').write_bytes(b'manifest')
                        if changed == 'replaced-during-acquisition':
                            directory.rename(runner / 'original'); directory.symlink_to(outside, target_is_directory=True)
                        return {'run': {}, 'job': {}, 'artifact': {}}
                    env = {'GITHUB_ACTIONS': 'true', 'GITHUB_REPOSITORY': release.REPOSITORY, 'GITHUB_RUN_ATTEMPT': '1',
                        'GITHUB_JOB': job, 'GITHUB_SHA': 'c' * 40, 'GITHUB_RUN_ID': '888', 'RUNNER_TEMP': str(runner)}
                    with patch.dict(os.environ, env), patch.object(release.sys, 'platform', system), \
                            patch.object(packaging, 'consumer_record', return_value=parent), \
                            patch.object(packaging, 'compiled_signed_product', return_value=True), \
                            patch.object(release, 'verify_source_reuse', return_value=(receipt, {})), \
                            patch.object(release, 'verify_source_origin'), patch.object(source, 'public_asset', return_value=public), \
                            patch.object(release, 'acquire_source_pair', side_effect=acquire), patch.object(source, 'validate') as semantic, \
                            patch.object(release.subprocess, 'run') as native, patch('builtins.print'):
                        if changed == 'valid':
                            result = release.consume_packaging_source(directory, receipt['sourceSHA'], input_receipt, binding,
                                context=context, evidence=evidence)
                            self.assertEqual((directory / source.RECEIPT).read_bytes(), raw.encode())
                            self.assertEqual(result['receipt'], receipt)
                            self.assertFalse(result['reuse']['semanticSourceValidationPerformed'])
                            self.assertTrue(release.verify_received_source(directory, receipt['sourceSHA'], binding, evidence, context=context))
                            (directory / 'source.tar').write_bytes(b'change')
                            with self.assertRaises(ValueError):
                                release.verify_received_source(directory, receipt['sourceSHA'], binding, evidence, context=context)
                        else:
                            with self.assertRaises(ValueError):
                                release.consume_packaging_source(directory, receipt['sourceSHA'], input_receipt, binding,
                                    context=context, evidence=evidence)
                            self.assertFalse(evidence.exists())
                        self.assertEqual(list(outside.iterdir()), [])
                        semantic.assert_not_called(); native.assert_not_called()

    def test_compiled_source_handoff_preserves_signed_input_and_derives_only_the_consumer_identity(self):
        import consume_bpy_distributable_source as source
        import retained_packaging as packaging
        for changed in ('valid', 'existing-app-submission', 'receipt', 'app', 'directory-during-download', 'pair-after-app-check'):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary); workspace = base / 'workspace'; workspace.mkdir(); runner = base / 'runner'; runner.mkdir()
                root = runner / 'release-signed-binding'; (root / 'payload').mkdir(parents=True)
                directory = workspace / '.build/bpy-source'; directory.mkdir(parents=True)
                app = workspace / '.build/NexGenVideo.app'; app.mkdir(); app.chmod(0o755)
                outside = base / 'outside'; outside.mkdir()
                archive = workspace / '.build/NexGenVideo.zip'; archive.write_bytes(b'signed product')
                public = {'filename': 'source.tar', 'manifestFilename': 'manifest.json', 'size': 6,
                    'sha256': hashlib.sha256(b'source').hexdigest(), 'manifestSHA256': hashlib.sha256(b'manifest').hexdigest(),
                    'producer': {'runID': 123}}
                original = {'schema': source.SCHEMA, 'sourceSHA': release.RETAINED_SOURCE, 'publicSourceAsset': public,
                    'origin': {'kind': 'actions'}, 'validation': {'archiveSHA256': public['sha256'], 'manifestSHA256': public['manifestSHA256']}}
                raw = json.dumps(original, indent=2).encode() + b'\n'
                (directory / source.RECEIPT).write_bytes(raw if changed != 'receipt' else b'{}')
                immutable = root / 'payload/bpy-source-receipt.json'; immutable.write_bytes(raw)
                origin = dict(release.SIGNED_RESUME, sourceReceiptSHA256=hashlib.sha256(raw).hexdigest(),
                    appArchiveSHA256=hashlib.sha256(archive.read_bytes()).hexdigest())
                manifest = {'appTreeSHA256': origin['appTreeSHA256']}
                parent = {'runID': 777, 'productSourceSHA': origin['sourceSHA'], 'producerSourceSHA': 'c' * 40,
                    'signedInput': {'manifest': manifest}}
                if changed == 'existing-app-submission': parent['previousNotary'] = {'journals': {'existing': {'submissionID': 'kept'}}}
                signed = {'manifest': manifest, 'sourceSHA': origin['sourceSHA'], 'executionRunID': 777,
                    'producerSourceSHA': 'c' * 40, 'packagingInputSHA256': 'd' * 64}
                (root / 'binding.json').write_text(json.dumps(signed))
                def acquire(public, stage):
                    (stage / 'source.tar').write_bytes(b'source'); (stage / 'manifest.json').write_bytes(b'manifest')
                    if changed == 'directory-during-download':
                        directory.rename(workspace / '.build/original-source'); directory.symlink_to(outside, target_is_directory=True)
                    return {'run': {}, 'job': {}, 'artifact': {}}
                def app_tree(app):
                    if changed == 'pair-after-app-check': (directory / 'source.tar').write_bytes(b'change')
                    return 'f' * 64 if changed == 'app' else origin['appTreeSHA256']
                env = {'GITHUB_ACTIONS': 'true', 'GITHUB_REPOSITORY': release.REPOSITORY, 'GITHUB_RUN_ATTEMPT': '1',
                    'GITHUB_JOB': 'release', 'GITHUB_SHA': 'c' * 40, 'GITHUB_RUN_ID': '777', 'RUNNER_TEMP': str(runner),
                    'GITHUB_WORKSPACE': str(workspace), 'NGV_COMPILED_APP_RELEASE': 'true', 'RETAINED_PACKAGING_INPUT_SHA256': 'd' * 64}
                with patch.dict(os.environ, env), patch.object(release.sys, 'platform', 'darwin'), \
                        patch.object(release, 'SIGNED_RESUME', origin), patch.object(packaging, 'current_binding', return_value=parent), \
                        patch.object(packaging, 'compiled_signed_product', return_value=True), \
                        patch.object(packaging, 'compiled_first_notary', side_effect=AssertionError('Source reuse is independent from Apple submission state')), \
                        patch.object(release, 'verify_source_origin'), \
                        patch.object(source, 'public_asset', return_value=public), patch.object(release.targets.capture, 'git', return_value='same-runtime'), \
                        patch.object(release, 'acquire_source_pair', side_effect=acquire), \
                        patch.object(release.checkpoint, 'tree_digest', side_effect=app_tree), \
                        patch.object(source, 'validate') as semantic, patch.object(release.subprocess, 'run') as native, patch('builtins.print'):
                    if changed in ('valid', 'existing-app-submission'):
                        release.prepare_resumed_source(root, directory)
                        derived = json.loads((directory / source.RECEIPT).read_bytes())
                        self.assertEqual(derived, dict(original, sourceSHA=origin['sourceSHA']))
                        self.assertEqual((directory / 'bpy-source-original-receipt.json').read_bytes(), raw)
                        proof = json.loads((directory / 'bpy-source-reuse.json').read_bytes())
                        self.assertEqual(proof['originalValidation'], original['validation'])
                        self.assertFalse(proof['semanticSourceValidationPerformed'])
                    else:
                        with self.assertRaises(ValueError): release.prepare_resumed_source(root, directory)
                        self.assertFalse((directory / 'bpy-source-reuse.json').exists())
                    self.assertEqual(immutable.read_bytes(), raw)
                    self.assertEqual(archive.read_bytes(), b'signed product')
                    self.assertEqual(list(outside.iterdir()), [])
                    semantic.assert_not_called(); native.assert_not_called()

    def test_current_local_pack_binds_product_harness_runtime_and_canonical_final_bytes_separately(self):
        import retained_packaging as packaging
        for changed in ('valid', 'producer-source', 'app', 'guide', 'dmg', 'missing-parent'):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary); dmg = root / 'NexGenVideo.dmg'; dmg.write_bytes(b'current DMG')
                digest = hashlib.sha256(dmg.read_bytes()).hexdigest(); source = release.SIGNED_RESUME['sourceSHA']
                selected = {'schema': 'authenticated-consumer'}
                binding = {'sourceSHA': source, 'dmgSHA256': digest, 'appTreeSHA256': 'a' * 64,
                    'guideSHA256': 'e' * 64, 'packaging': selected}
                parent = {'stage': 'complete', 'producerSourceSHA': 'c' * 40,
                    'final': {'dmgSHA256': digest, 'appTreeSHA256': 'a' * 64, 'guideSHA256': 'e' * 64}}
                inputs = {'candidate_kind': 'signed-journey', 'journey_scenario': 'normal-fresh-local-musicvideo',
                    'run_id': '777', 'artifact_id': '888', 'artifact_sha256': 'b' * 64, 'source_sha': source, 'expected_dmg_sha256': digest}
                event = root / 'event.json'; event.write_text(json.dumps({'inputs': inputs}))
                run = {'id': 777, 'head_sha': 'c' * 40, 'run_attempt': 1, 'workflow_id': 303346287,
                    'path': '.github/workflows/release.yml', 'event': 'workflow_dispatch', 'repository': {'full_name': release.REPOSITORY},
                    'actor': {'login': 'iret77'}, 'status': 'completed', 'conclusion': 'success'}
                job = {'id': 999, 'run_id': 777, 'head_sha': 'c' * 40, 'run_attempt': 1, 'labels': ['macrunner'],
                    'name': 'release', 'status': 'completed', 'conclusion': 'success'}
                if changed == 'producer-source': run['head_sha'] = source
                elif changed == 'app': parent['final']['appTreeSHA256'] = 'f' * 64
                elif changed == 'guide': parent['final']['guideSHA256'] = 'f' * 64
                elif changed == 'dmg': parent['final']['dmgSHA256'] = 'f' * 64
                elif changed == 'missing-parent': binding.pop('packaging')
                with patch.dict(os.environ, GITHUB_EVENT_PATH=str(event)), \
                        patch.object(packaging, 'consumer_record', return_value=parent), \
                        patch.object(packaging, 'compiled_signed_product', return_value=True), patch.object(packaging, 'consumer_harness'), \
                        patch.object(release, 'api', side_effect=[run, {'total_count': 1, 'jobs': [job]}, {}]), \
                        patch.object(release, 'verify_artifact'):
                    if changed == 'valid':
                        actual = release.local_pack_runtime_origin(binding, dmg)
                        self.assertEqual(actual['sourceSHA'], source)
                        self.assertEqual(actual['producerSourceSHA'], 'c' * 40)
                        self.assertEqual(actual['packaging'], selected)
                    else:
                        with self.assertRaises(ValueError): release.local_pack_runtime_origin(binding, dmg)

    def test_pack_copies_require_same_job_parent_and_complete_current_copy_without_native_fallback(self):
        tree = '0a5115a344f565f3f3456120e67407846dcd0a4d4e93923f19ed48e90c695921'
        contexts = ('external-load', 'pre-dmg', 'dmg-copy', 'installed-dmg')
        for context in contexts:
            for case in ('valid', 'missing-parent', 'parent-source', 'parent-run', 'parent-job', 'parent-claim',
                    'contents', 'mode', 'root-mode', 'root-link', 'archive', 'changed-during-origin',
                    'parent-changed-during-origin', 'proof-root-link', 'consumed', 'job', 'context'):
                with self.subTest(context=context, case=case), tempfile.TemporaryDirectory() as temporary:
                    base = Path(temporary)
                    runner, bundle = base / 'runner', base / 'musicvideo.ngvpack'
                    runner.mkdir(); bundle.mkdir(); bundle.chmod(0o755)
                    image = bundle / 'image'
                    image.write_bytes(b'qualified pack copy\n'); image.chmod(0o644)
                    archive, dmg = base / 'pack.zip', base / 'current.dmg'
                    archive.write_bytes(b'qualified archive'); dmg.write_bytes(b'exact current DMG')
                    archive_sha = hashlib.sha256(archive.read_bytes()).hexdigest()
                    marker = runner / 'pack-copy-reuse' / (context + '.json')
                    if case == 'contents': image.write_bytes(b'changed pack\n')
                    elif case == 'mode': image.chmod(0o755)
                    elif case == 'root-mode': bundle.chmod(0o700)
                    elif case == 'root-link':
                        alias = base / 'alias.ngvpack'; alias.symlink_to(bundle, target_is_directory=True); bundle = alias
                    elif case == 'archive': archive.write_bytes(b'changed archive')
                    elif case == 'consumed': marker.parent.mkdir(); marker.write_bytes(b'consumed')
                    elif case == 'proof-root-link':
                        outside = base / 'outside'; outside.mkdir()
                        marker.parent.symlink_to(outside, target_is_directory=True)
                    env = {'GITHUB_ACTIONS': 'true', 'GITHUB_REPOSITORY': release.REPOSITORY, 'GITHUB_RUN_ATTEMPT': '1',
                        'GITHUB_JOB': 'acceptance' if case == 'job' else 'release', 'GITHUB_SHA': 'c' * 40,
                        'GITHUB_RUN_ID': '555', 'RUNNER_TEMP': str(runner)}

                    def origin():
                        if case == 'changed-during-origin': image.write_bytes(b'changed during origin read\n')
                        if case == 'parent-changed-during-origin': parent_path.write_bytes(b'changed parent')
                        return {'id': release.RETAINED_RUN}, {'id': release.PACK_NATIVE_PROOF['jobID']}, {
                            'id': release.FINAL_ARTIFACT[0], 'digest': 'sha256:' + release.FINAL_ARTIFACT[1]}

                    with patch.object(release, 'PACK_SHA', archive_sha), patch.object(release, 'PACK_TREE', tree), \
                            patch.object(release, 'pack_verification_origin', side_effect=origin), \
                            patch.object(release.sys, 'platform', 'darwin'), patch.dict(os.environ, env), \
                            patch.object(release.subprocess, 'run') as native, patch('builtins.print') as emitted:
                        parent = {'schema': 'retained-pack-shell-verification-reuse/v1', 'state': 'REUSED',
                            'original': release.original_pack_proof(), 'newAppPackLoadQualified': False,
                            'currentNativeCodesignOrStaplerPerformed': False, 'currentPackNotarizationPerformed': False,
                            'freshTrustStoreOrRevocationClaimed': False,
                            'currentMaterialization': {'sourceSHA': 'c' * 40, 'runID': 555, 'job': 'release',
                                'packTreeSHA256': tree, 'packArchiveSHA256': archive_sha}}
                        if case == 'parent-source': parent['currentMaterialization']['sourceSHA'] = 'f' * 40
                        elif case == 'parent-run': parent['currentMaterialization']['runID'] = 556
                        elif case == 'parent-job': parent['currentMaterialization']['job'] = 'release-build'
                        elif case == 'parent-claim': parent['freshTrustStoreOrRevocationClaimed'] = True
                        parent_path = runner / 'retained-pack-verification.reused.json'
                        if case != 'missing-parent': parent_path.write_text(json.dumps(parent))
                        selected = 'unknown' if case == 'context' else context
                        if case == 'valid':
                            record = release.verify_pack_copy(bundle, selected, archive, dmg)
                            self.assertEqual(json.loads(marker.read_text()), record)
                            self.assertEqual(record['parentSHA256'], hashlib.sha256(parent_path.read_bytes()).hexdigest())
                            self.assertEqual(record['currentDMGSHA256'], hashlib.sha256(dmg.read_bytes()).hexdigest())
                            self.assertIsNone(record['runtimeProducer'])
                            self.assertFalse(record['currentNativeCodesignOrStaplerPerformed'])
                            self.assertFalse(record['newAppPackLoadQualified'])
                            with self.assertRaises(ValueError): release.verify_pack_copy(bundle, selected, archive, dmg)
                            emitted.assert_called_once()
                        else:
                            with self.assertRaises(ValueError): release.verify_pack_copy(bundle, selected, archive, dmg)
                            if case == 'consumed': self.assertEqual(marker.read_bytes(), b'consumed')
                            else: self.assertFalse(marker.exists())
                            emitted.assert_not_called()
                        native.assert_not_called()

    def test_local_pack_copy_authenticates_its_own_current_dmg_runtime_without_another_vm_parent(self):
        for case in ('valid', 'event', 'selector', 'source', 'artifact', 'producer', 'actor', 'dmg'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                dmg = root / 'current.dmg'; dmg.write_bytes(b'exact current DMG')
                digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
                binding = {'sourceSHA': 'd' * 40, 'dmgSHA256': digest, 'appTreeSHA256': 'a' * 64, 'guideSHA256': 'e' * 64}
                inputs = {'candidate_kind': 'signed-journey', 'journey_scenario': 'normal-fresh-local-musicvideo',
                    'run_id': '777', 'artifact_id': '888', 'artifact_sha256': 'b' * 64,
                    'source_sha': binding['sourceSHA'], 'expected_dmg_sha256': digest}
                run = {'id': 777, 'head_sha': binding['sourceSHA'], 'run_attempt': 1, 'workflow_id': 303346287,
                    'path': '.github/workflows/release.yml', 'event': 'workflow_dispatch', 'repository': {'full_name': release.REPOSITORY},
                    'actor': {'login': 'iret77'}, 'status': 'completed', 'conclusion': 'success'}
                job = {'id': 999, 'name': 'release', 'run_id': 777, 'head_sha': binding['sourceSHA'], 'run_attempt': 1,
                    'labels': ['macrunner'], 'status': 'completed', 'conclusion': 'success',
                    'started_at': '2026-11-10T03:00:00Z', 'completed_at': '2026-11-10T04:00:00Z'}
                artifact = {'id': 888, 'name': 'release-user-journey-input', 'digest': 'sha256:' + 'b' * 64,
                    'expired': False, 'workflow_run': {'id': 777, 'head_sha': binding['sourceSHA']},
                    'created_at': '2026-11-10T03:30:00Z', 'updated_at': '2026-11-10T03:30:00Z', 'expires_at': '2099-01-01T00:00:00Z'}
                if case == 'event': inputs['journey_scenario'] = 'journey'
                elif case == 'selector': inputs['artifact_id'] = ''
                elif case == 'source': run['head_sha'] = 'f' * 40
                elif case == 'artifact': artifact['digest'] = 'sha256:' + 'f' * 64
                elif case == 'producer': job['conclusion'] = 'failure'
                elif case == 'actor': run['actor']['login'] = 'other'
                elif case == 'dmg': dmg.write_bytes(b'changed DMG')
                event = root / 'event.json'; event.write_text(json.dumps({'inputs': inputs}))
                values = {'actions/runs/777': run, 'actions/runs/777/attempts/1/jobs?per_page=100': {'total_count': 1, 'jobs': [job]},
                    'actions/artifacts/888': artifact}
                with patch.dict(os.environ, GITHUB_EVENT_PATH=str(event)), patch.object(release, 'api', side_effect=values.__getitem__):
                    if case == 'valid':
                        result = release.local_pack_runtime_origin(binding, dmg)
                        self.assertEqual((result['runID'], result['artifactID'], result['producerJobID']), (777, 888, 999))
                        self.assertEqual(result['intakeBinding'], binding)
                        runner, bundle = root / 'runner', root / 'musicvideo.ngvpack'
                        runner.mkdir(); bundle.mkdir(); bundle.chmod(0o755)
                        (bundle / 'image').write_bytes(b'qualified pack copy\n'); (bundle / 'image').chmod(0o644)
                        native_origin = ({'id': release.RETAINED_RUN}, {'id': release.PACK_NATIVE_PROOF['jobID']},
                            {'id': release.FINAL_ARTIFACT[0], 'digest': 'sha256:' + release.FINAL_ARTIFACT[1]})
                        env = {'GITHUB_ACTIONS': 'true', 'GITHUB_REPOSITORY': release.REPOSITORY, 'GITHUB_RUN_ATTEMPT': '1',
                            'GITHUB_JOB': 'acceptance', 'GITHUB_SHA': 'c' * 40, 'GITHUB_RUN_ID': '555', 'RUNNER_TEMP': str(runner)}
                        with patch.dict(os.environ, env), patch.object(release.sys, 'platform', 'darwin'), \
                                patch.object(release, 'PACK_TREE', '0a5115a344f565f3f3456120e67407846dcd0a4d4e93923f19ed48e90c695921'), \
                                patch.object(release, 'pack_verification_origin', return_value=native_origin), \
                                patch.object(release.subprocess, 'run') as native, patch('builtins.print'):
                            for context in ('local-dmg', 'local-installed'):
                                record = release.verify_pack_copy(bundle, context, dmg=dmg, binding=binding, evidence=runner / 'gui')
                                self.assertIsNone(record['parentSHA256'])
                                self.assertEqual(record['runtimeProducer'], result)
                                self.assertEqual(record['currentSourceSHA'], 'c' * 40)
                                self.assertEqual(record['currentJob'], 'acceptance')
                            linked = runner / 'linked-evidence'; linked.mkdir()
                            outside = root / 'outside'; outside.mkdir()
                            (linked / 'pack-reuse').symlink_to(outside, target_is_directory=True)
                            with self.assertRaises(ValueError):
                                release.verify_pack_copy(bundle, 'local-dmg', dmg=dmg, binding=binding, evidence=linked)
                            self.assertFalse(list(outside.iterdir()))
                            def mutate_dmg():
                                dmg.write_bytes(b'changed during original-origin reads')
                                return native_origin
                            with patch.object(release, 'pack_verification_origin', side_effect=mutate_dmg):
                                with self.assertRaises(ValueError):
                                    release.verify_pack_copy(bundle, 'local-dmg', dmg=dmg, binding=binding, evidence=runner / 'changed-dmg')
                            self.assertFalse((runner / 'changed-dmg/pack-reuse/local-dmg.json').exists())
                            native.assert_not_called()
                    else:
                        with self.assertRaises(ValueError): release.local_pack_runtime_origin(binding, dmg)

    def test_original_signature_reuse_binds_origin_and_checks_the_materialized_tree_after_reads(self):
        tree = 'f7b7fe360a3bd5d023503745a5236b332c6f998bc68c318b32d3766ec89b074a'
        for case in ('valid', 'contents', 'mode', 'root-mode', 'root-link', 'run', 'job', 'artifact',
                'expiry', 'record', 'manifest-source', 'manifest-tree', 'changed-during-origin', 'consumed'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary)
                root, app = base / 'evidence', base / 'App'
                root.mkdir()
                app.mkdir()
                app.chmod(0o755)
                image = app / 'image'
                image.write_bytes(b'old signed application\n')
                image.chmod(0o644)
                origin = release.SIGNATURE_ORIGIN
                run = {'id': origin['runID'], 'head_sha': origin['sourceSHA'], 'run_attempt': 1,
                    'workflow_id': 303346287, 'path': '.github/workflows/release.yml', 'event': 'workflow_dispatch',
                    'status': 'completed', 'conclusion': 'failure', 'repository': {'full_name': release.REPOSITORY},
                    'actor': {'login': 'iret77'}}
                job = {'id': origin['jobID'], 'run_id': origin['runID'], 'head_sha': origin['sourceSHA'],
                    'run_attempt': 1, 'name': 'release-build', 'labels': ['macrunner'], 'status': 'completed',
                    'conclusion': 'failure', 'started_at': '2026-11-10T03:51:00Z', 'completed_at': '2026-11-10T04:08:00Z'}
                artifact = {'id': origin['artifactID'], 'name': 'release-compiled-app-assembly-' + str(origin['runID']) + '-a1',
                    'digest': 'sha256:' + origin['artifactSHA256'], 'size_in_bytes': origin['artifactBytes'], 'expired': False,
                    'workflow_run': {'id': origin['runID'], 'head_sha': origin['sourceSHA']},
                    'created_at': '2026-11-10T04:06:00Z', 'updated_at': '2026-11-10T04:07:00Z',
                    'expires_at': '2099-01-01T00:00:00Z'}
                manifest = {'sourceSHA': release.RETAINED_SOURCE, 'runID': release.RETAINED_RUN, 'appTreeSHA256': tree}
                command = copy.deepcopy(release.SIGNATURE_COMMAND)
                marker = root / 'verify-retained-signature.reused.json'
                if case == 'contents': image.write_bytes(b'changed application\n')
                elif case == 'mode': image.chmod(0o755)
                elif case == 'root-mode': app.chmod(0o700)
                elif case == 'root-link':
                    alias = base / 'Alias'
                    alias.symlink_to(app, target_is_directory=True)
                    app = alias
                elif case == 'run': run['head_sha'] = 'f' * 40
                elif case == 'job': job['labels'] = ['ubuntu-24.04']
                elif case == 'artifact': artifact['digest'] = 'sha256:' + 'f' * 64
                elif case == 'expiry': artifact['expired'] = True
                elif case == 'record': command['exitCode'] = 1
                elif case == 'manifest-source': manifest['sourceSHA'] = 'f' * 40
                elif case == 'manifest-tree': manifest['appTreeSHA256'] = 'f' * 64
                elif case == 'consumed': marker.write_bytes(b'consumed')
                values = {'actions/runs/' + str(origin['runID']): run,
                    'actions/jobs/' + str(origin['jobID']): job, 'actions/artifacts/' + str(origin['artifactID']): artifact}

                def read_origin(route):
                    if case == 'changed-during-origin' and route.startswith('actions/artifacts/'):
                        image.write_bytes(b'changed while reading origin\n')
                    return values[route]

                with patch.object(release, 'native_guard'), patch.object(release, 'api', side_effect=read_origin), \
                        patch.object(release, 'SIGNATURE_APP_TREE', tree), patch.object(release, 'SIGNATURE_COMMAND', command), \
                        patch.object(release.subprocess, 'run') as native, \
                        patch.dict(os.environ, GITHUB_SHA='c' * 40, GITHUB_RUN_ID='555'):
                    if case == 'valid':
                        release.reuse_retained_signature(root, app, manifest)
                        record = json.loads(marker.read_text())
                        self.assertEqual(record['state'], 'REUSED')
                        self.assertEqual(record['original']['sourceSHA'], origin['sourceSHA'])
                        self.assertEqual(record['original']['command'], command)
                        self.assertEqual(record['original']['recordSHA256'], release.SIGNATURE_RECORD_SHA256)
                        self.assertEqual(record['currentMaterialization']['sourceSHA'], 'c' * 40)
                        self.assertEqual(record['currentMaterialization']['runID'], 555)
                        self.assertFalse(record['currentNativeSignatureVerificationPerformed'])
                        self.assertFalse(record['freshTrustStoreOrRevocationClaimed'])
                        with self.assertRaises(ValueError): release.reuse_retained_signature(root, app, manifest)
                    else:
                        with self.assertRaises(ValueError): release.reuse_retained_signature(root, app, manifest)
                        if case == 'consumed': self.assertEqual(marker.read_bytes(), b'consumed')
                        else: self.assertFalse(marker.exists())
                    native.assert_not_called()

    def test_stapled_pack_uses_canonical_bundle_identity_and_reuses_qualified_native_shell_steps(self):
        canonical = '1913adf849f6ef4b32cdaa44a476b78617689e81724b57d74b03ea516cacdc95'
        for caller in ('release-build', 'release'):
            for case in ('valid', 'contents', 'mode', 'root-mode', 'root-link', 'escaping-link', 'archive',
                    'run', 'job', 'artifact', 'expiry', 'step19', 'step21', 'changed-during-origin', 'context', 'workspace', 'consumed'):
                with self.subTest(caller=caller, case=case), tempfile.TemporaryDirectory() as temporary:
                    base = Path(temporary)
                    root, runner = base / '.build/plugins', base / 'runner'
                    runner.mkdir()
                    bundle = root / 'musicvideo.ngvpack'
                    contents = bundle / 'Contents'
                    contents.mkdir(parents=True)
                    bundle.chmod(0o755)
                    contents.chmod(0o755)
                    executable = contents / 'Entry'
                    executable.write_bytes(b'pack executable\n')
                    executable.chmod(0o755)
                    metadata = contents / 'Info.plist'
                    metadata.write_bytes(b'pack metadata\n')
                    metadata.chmod(0o644)
                    (bundle / 'active').symlink_to('Contents/Entry')
                    archive = root / 'musicvideo.ngvpack.zip'
                    archive.write_bytes(b'qualified archive')
                    archive_sha = hashlib.sha256(archive.read_bytes()).hexdigest()
                    self.assertNotEqual(release.checkpoint.tree_digest(bundle), canonical)
                    run = {'id': release.RETAINED_RUN, 'head_sha': release.RETAINED_SOURCE, 'run_attempt': 1,
                        'workflow_id': 303346287, 'path': '.github/workflows/release.yml', 'event': 'workflow_dispatch',
                        'status': 'completed', 'conclusion': 'failure', 'repository': {'full_name': release.REPOSITORY},
                        'actor': {'login': 'iret77'}}
                    proof = release.PACK_NATIVE_PROOF
                    job = {'id': proof['jobID'], 'run_id': release.RETAINED_RUN, 'head_sha': release.RETAINED_SOURCE,
                        'run_attempt': 1, 'name': 'release', 'labels': ['macrunner'], 'status': 'completed',
                        'conclusion': 'success', 'started_at': '2026-11-08T21:15:34Z', 'completed_at': '2026-11-08T22:02:43Z',
                        'steps': copy.deepcopy(proof['steps'])}
                    artifact = {'id': release.FINAL_ARTIFACT[0], 'name': 'NexGenVideo-1.8.0-artifact-only',
                        'digest': 'sha256:' + release.FINAL_ARTIFACT[1], 'size_in_bytes': proof['artifactBytes'], 'expired': False,
                        'workflow_run': {'id': release.RETAINED_RUN, 'head_sha': release.RETAINED_SOURCE},
                        'created_at': '2026-11-08T22:01:27Z', 'updated_at': '2026-11-08T22:01:27Z',
                        'expires_at': '2099-01-01T00:00:00Z'}
                    marker = runner / 'retained-pack-verification.reused.json'
                    if case == 'contents': executable.write_bytes(b'changed executable\n')
                    elif case == 'mode': executable.chmod(0o644)
                    elif case == 'root-mode': bundle.chmod(0o700)
                    elif case == 'root-link':
                        bundle.rename(root / 'original.ngvpack')
                        bundle.symlink_to('original.ngvpack', target_is_directory=True)
                    elif case == 'escaping-link':
                        (base / 'outside').write_bytes(b'outside')
                        (bundle / 'escape').symlink_to(base / 'outside')
                    elif case == 'archive': archive.write_bytes(b'changed archive')
                    elif case == 'run': run['head_sha'] = 'f' * 40
                    elif case == 'job': job['labels'] = ['ubuntu-24.04']
                    elif case == 'artifact': artifact['digest'] = 'sha256:' + 'f' * 64
                    elif case == 'expiry': artifact['expired'] = True
                    elif case in ('step19', 'step21'): job['steps'][0 if case == 'step19' else 1]['conclusion'] = 'failure'
                    elif case == 'consumed': marker.write_bytes(b'consumed')
                    values = {'actions/runs/' + str(release.RETAINED_RUN): run,
                        'actions/jobs/' + str(proof['jobID']): job, 'actions/artifacts/' + str(release.FINAL_ARTIFACT[0]): artifact}

                    def read_origin(route):
                        if case == 'changed-during-origin' and route.startswith('actions/artifacts/'):
                            executable.write_bytes(b'changed while reading origin\n')
                        return values[route]

                    env = {'GITHUB_ACTIONS': 'true', 'GITHUB_REPOSITORY': release.REPOSITORY, 'GITHUB_RUN_ATTEMPT': '1',
                        'GITHUB_JOB': 'unknown' if case == 'context' else caller, 'GITHUB_SHA': 'c' * 40, 'GITHUB_RUN_ID': '555',
                        'RUNNER_TEMP': str(runner), 'GITHUB_WORKSPACE': str(base / 'other') if case == 'workspace' else str(base)}
                    with patch.object(release, 'PACK_SHA', archive_sha), patch.object(release, 'PACK_TREE', canonical), \
                            patch.object(release, 'api', side_effect=read_origin), patch.object(release.sys, 'platform', 'darwin'), \
                            patch.object(release.subprocess, 'run') as native, patch.dict(os.environ, env), \
                            patch('builtins.print') as emitted:
                        if case == 'valid':
                            release.verify_pack(root)
                            record = json.loads(marker.read_text())
                            self.assertEqual(record['state'], 'REUSED')
                            self.assertEqual(record['original']['qualifiedShellEvidence'], proof)
                            self.assertEqual(record['currentMaterialization']['job'], caller)
                            self.assertEqual(record['currentMaterialization']['sourceSHA'], 'c' * 40)
                            self.assertFalse(record['currentNativeCodesignOrStaplerPerformed'])
                            self.assertFalse(record['freshTrustStoreOrRevocationClaimed'])
                            self.assertFalse(record['currentPackNotarizationPerformed'])
                            self.assertFalse(record['newAppPackLoadQualified'])
                            with self.assertRaises(ValueError): release.verify_pack(root)
                            emitted.assert_called_once()
                            self.assertEqual(json.loads(emitted.call_args.args[0].removeprefix('PACK_VERIFICATION_REUSED ')), record)
                        else:
                            with self.assertRaises(ValueError): release.verify_pack(root)
                            if case == 'consumed': self.assertEqual(marker.read_bytes(), b'consumed')
                            else: self.assertFalse(marker.exists())
                            emitted.assert_not_called()
                        native.assert_not_called()

    def test_native_parameter_events_preserve_unicode_and_reject_malformed_or_extra_cases(self):
        identity = 'NexGenVideoTests.JSONLTests/probe()/Test.swift:1:1'
        expected = {'exactDiscoveredFunctionIDs': [identity], 'exactEndedFunctionIDs': [identity],
            'exactSkippedFunctionIDs': [], 'expectedCaseCountsByFunction': {identity: 1}}
        event = lambda kind: {'version': 0, 'kind': 'event', 'payload': {'kind': kind, 'testID': identity}}
        records = [{'version': 0, 'kind': 'test', 'payload': {'kind': 'function', 'id': identity,
            'sourceLocation': {'fileID': 'NexGenVideoTests/Test.swift'}}},
            event('runStarted'), event('testStarted'), event('testCaseStarted'),
            event('testCaseEnded'), event('testEnded'), event('runEnded')]
        for separator in ('\u0085', '\u2028', '\u2029'):
            for framing in ('\n', '\r\n'):
                with self.subTest(separator=repr(separator), framing=repr(framing)), tempfile.TemporaryDirectory() as temporary:
                    path = Path(temporary) / 'events.jsonl'
                    rows = copy.deepcopy(records)
                    rows[3]['payload']['message'] = 'before' + separator + 'after'
                    text = framing.join(json.dumps(row, ensure_ascii=False) for row in rows) + framing
                    path.write_bytes(text.encode('utf-8'))
                    self.assertEqual(release.verify_events(path, expected, 'NexGenVideoTests')['recordCount'], 7)
                    path.write_bytes(text.replace(separator, '\n').encode('utf-8'))
                    with self.assertRaises(json.JSONDecodeError):
                        release.verify_events(path, expected, 'NexGenVideoTests')
                    path.write_bytes((text + '{"version":').encode('utf-8'))
                    with self.assertRaises(json.JSONDecodeError):
                        release.verify_events(path, expected, 'NexGenVideoTests')
                    rows[5:5] = [event('testCaseStarted'), event('testCaseEnded')]
                    path.write_bytes((framing.join(json.dumps(row, ensure_ascii=False) for row in rows) + framing).encode('utf-8'))
                    with self.assertRaisesRegex(ValueError, 'parameter-case coverage'):
                        release.verify_events(path, expected, 'NexGenVideoTests')

    def test_acquisition_reads_only_the_authenticated_runtime_bank_manifest_without_requiring_it_in_metadata(self):
        class RestoreReached(Exception):
            pass

        for case in ('valid', 'metadata-decoy', 'tampered-bank-manifest', 'missing-bank-root-record', 'changed-bank-metadata'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary)
                runner = base / 'runner'
                roles, event = self.inputs()
                native = {'Sources': 'd' * 40}
                bank_id, bank_digest, bank_name = release.retained.ARTIFACTS['runtime']
                bank = {'id': bank_id, 'digest': 'sha256:' + bank_digest, 'name': bank_name, 'expired': False}
                actual_bank = {**bank, 'expired': True} if case == 'changed-bank-metadata' else bank
                binding = {'schema': 'native-app-target-source-binding/v1', 'sourceSHA': roles['metadata']['sourceSHA'],
                    'appSourceSHA': release.APP_SOURCE, 'nativeSourceObjects': native,
                    'metadata': {'artifact': {'id': 13647433566,
                        'digest': 'sha256:b6f5e0ef652fd5996760ce5f59f19239760563216d2504ff6ee056fa4dee74a9'}},
                    'retainedBank': {'runtimeArtifact': bank}}
                prepared = {'schema': 'native-app-target-prepared/v1', 'sourceSHA': roles['metadata']['sourceSHA'],
                    'appSourceSHA': release.APP_SOURCE, 'nativeSourceObjects': native, 'compilerSHA256': release.COMPILER_SHA,
                    'plans': {phase: {'operations': {'arena': str(runner / 'app-build-plan-evidence'
                        / ('production' if phase == 'production' else 'testable') / 'derived-data')}} for phase in release.PHASES}}
                metadata_zip, runtime_zip = base / 'metadata.zip', base / 'bank.zip'
                with zipfile.ZipFile(metadata_zip, 'w') as archive:
                    archive.writestr('binding.json', json.dumps(binding))
                    archive.writestr('prepared.json', json.dumps(prepared))
                    if case == 'metadata-decoy': archive.writestr('bank-runtime-manifest.json', b'untrusted decoy')
                roles['metadata']['artifactSHA256'] = hashlib.sha256(metadata_zip.read_bytes()).hexdigest()
                manifest = {'binaryRoot': '/original/Release', 'files': {}}
                raw_manifest = json.dumps(manifest, sort_keys=True).encode()
                with zipfile.ZipFile(runtime_zip, 'w') as archive:
                    member = 'nested/runtime-manifest.json' if case == 'missing-bank-root-record' else 'runtime-manifest.json'
                    archive.writestr(member, b'{}' if case == 'tampered-bank-manifest' else raw_manifest)
                event_path = base / 'event.json'
                event_path.write_text(json.dumps(event))
                root = base / 'acquisition'

                def download(artifact, destination):
                    shutil.copyfile(metadata_zip if artifact['id'] == 201 else runtime_zip, destination)

                with patch.object(release, 'native_guard', return_value=runner), \
                        patch.object(release, 'producer', return_value={'artifact': {'id': 201}}), \
                        patch.object(release, 'source_objects', return_value=native), \
                        patch.object(release, 'download', side_effect=download), \
                        patch.object(release, 'api', return_value=actual_bank) as api, \
                        patch.object(release.retained, 'MANIFEST_SHA', hashlib.sha256(raw_manifest).hexdigest()), \
                        patch.object(release.retained, 'restore_runtime', side_effect=RestoreReached) as restore, \
                        patch.dict(os.environ, COMPILED_APP_TARGETS=json.dumps(roles), GITHUB_EVENT_PATH=str(event_path)):
                    if case in ('valid', 'metadata-decoy'):
                        with self.assertRaises(RestoreReached): release.acquire_products(root)
                        self.assertEqual(restore.call_args.args[:2], (root, manifest))
                        self.assertEqual((root / 'bank-runtime-manifest.json').read_bytes(), raw_manifest)
                    else:
                        with self.assertRaises(ValueError): release.acquire_products(root)
                        restore.assert_not_called()
                api.assert_called_once_with('actions/artifacts/' + str(bank_id))

    def test_failure_retains_signed_app_modes_links_symbols_and_incomplete_archives_without_acceptance(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root, output, build = base / 'evidence', base / 'signed-input', base / '.build'
            root.mkdir()
            output.mkdir()
            image = build / 'NexGenVideo.app/Contents/MacOS/NexGenVideo'
            image.parent.mkdir(parents=True)
            image.write_bytes(b'new signed executable')
            image.chmod(0o755)
            (image.parent / 'alias').symlink_to('NexGenVideo')
            symbols = build / 'NexGenVideo.dSYM/symbols'
            symbols.parent.mkdir(parents=True)
            symbols.write_bytes(b'new symbols')
            partial = output / 'NexGenVideo.zip'
            partial.write_bytes(b'incomplete zip, not a qualified product')
            with patch.object(release, 'native_guard'), patch.object(release, 'Path',
                    side_effect=lambda value: build if value == '.build' else Path(value)), \
                    patch.dict(os.environ, {'GITHUB_SHA': 'a' * 40, 'GITHUB_RUN_ID': '101'}):
                release.retain_assembly(root, output, 'failure')
            state = json.loads((root / 'assembly-retention.json').read_text())
            self.assertEqual(state['status'], 'RETAINED_UNQUALIFIED_BYTES')
            self.assertFalse(state['functionalRCAccepted'])
            self.assertFalse(state['rawProductsArchive']['qualified'])
            self.assertEqual(state['signedInputFiles']['NexGenVideo.zip']['sha256'],
                hashlib.sha256(partial.read_bytes()).hexdigest())
            self.assertEqual(set(state['products']), {'NexGenVideo.app', 'NexGenVideo.dSYM'})
            entries = state['products']['NexGenVideo.app']['entries']
            self.assertEqual(entries['Contents/MacOS/NexGenVideo']['mode'], 0o755)
            self.assertEqual(entries['Contents/MacOS/alias']['target'], 'NexGenVideo')
            self.assertEqual(entries['Contents/MacOS/NexGenVideo']['sha256'],
                hashlib.sha256(b'new signed executable').hexdigest())
            with tarfile.open(root / 'unqualified-app-products.tar') as archive:
                name = 'NexGenVideo.app/Contents/MacOS/NexGenVideo'
                self.assertEqual(archive.extractfile(name).read(), b'new signed executable')
                self.assertEqual(archive.getmember(name).mode, 0o755)
                self.assertEqual(archive.getmember('NexGenVideo.app/Contents/MacOS/alias').linkname, 'NexGenVideo')
                self.assertEqual(archive.extractfile('NexGenVideo.dSYM/symbols').read(), b'new symbols')
            self.assertEqual(image.read_bytes(), b'new signed executable')
            self.assertEqual(partial.read_bytes(), b'incomplete zip, not a qualified product')

    def test_retained_engine_environment_requires_all_original_context_fields_and_arm64(self):
        original = {'swift': 'measured Swift', 'xcode': 'measured Xcode', 'python': '3.13.17',
            'osVersion': '27.2', 'osBuild': 'measured build'}
        commands = {('swift', '--version'): 'swift', ('xcodebuild', '-version'): 'xcode',
            ('sw_vers', '-productVersion'): 'osVersion', ('sw_vers', '-buildVersion'): 'osBuild'}
        for changed in (None, 'swift', 'xcode', 'python', 'osVersion', 'osBuild', 'architecture'):
            current = dict(original)
            if changed in current: current[changed] = 'different'
            with self.subTest(changed=changed), patch.object(release.engine, 'toolchain', return_value=original), \
                    patch.object(release.engine, 'command', side_effect=lambda *args: current[commands[args]]), \
                    patch.object(release.platform, 'python_version', return_value=current['python']), \
                    patch.object(release.platform, 'machine', return_value='x86_64' if changed == 'architecture' else 'arm64'):
                if changed is None:
                    self.assertEqual(release.engine_environment(b'authenticated log'),
                        {'original': original, 'current': original, 'architecture': 'arm64'})
                else:
                    with self.assertRaisesRegex(ValueError, 'runtime or toolchain differs'):
                        release.engine_environment(b'authenticated log')

    def inputs(self):
        selected = {'runID': 101, 'artifactID': 201, 'sourceSHA': 'a' * 40,
            'artifactSHA256': 'b' * 64, 'receiptSHA256': 'c' * 64}
        roles = {role: dict(selected) for role in release.PHASES}
        roles['metadata'] = {key: value for key, value in selected.items() if key != 'receiptSHA256'}
        event = {'inputs': {'artifact_only': 'true', 'dry_run': 'true', 'version': '1.8.0',
            'verified_pr_run_id': '301'}}
        return roles, event

    def test_compiled_input_roles_are_closed_and_duplicate_json_fields_are_rejected(self):
        roles, event = self.inputs()
        self.assertEqual(release.selectors(json.dumps(roles), event), roles)
        for value in ({}, {**roles, 'other': roles['production']},
                {key: item for key, item in roles.items() if key != 'tests'}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                release.selectors(json.dumps(value), event)
        raw = json.dumps(roles)
        with self.assertRaises(ValueError):
            release.selectors(raw[:-1] + ', "production": ' + json.dumps(roles['production']) + '}', event)

    def test_compiled_rc_cannot_enable_publication_or_mix_other_resume_selectors(self):
        roles, event = self.inputs()
        changes = [('artifact_only', 'false'), ('dry_run', 'false'), ('version', '1.8.1'),
            ('verified_pr_run_id', '')]
        changes += [(name, '101') for name in ('completed_release_tests_run_id', 'completed_engine_tests_run_id',
            'signed_build_run_id', 'notary_progress_run_id', 'retained_product_source_sha',
            'retained_product_source_pr_run_id', 'prior_packaging_producer_source_sha',
            'prior_packaging_provenance_artifact_id', 'prior_packaging_provenance_artifact_sha256')]
        for name, value in changes:
            broken = copy.deepcopy(event)
            broken['inputs'][name] = value
            with self.subTest(name=name), self.assertRaises(ValueError):
                release.selectors(json.dumps(roles), broken)

    def test_compiled_selector_identity_rejects_boolean_ids_and_extra_fields(self):
        roles, event = self.inputs()
        for role, key, value in [('tests', 'runID', True), ('production', 'artifactID', 0),
                ('metadata', 'sourceSHA', 'a' * 39), ('testable', 'receiptSHA256', 'x' * 64),
                ('metadata', 'receiptSHA256', 'c' * 64)]:
            broken = copy.deepcopy(roles)
            broken[role][key] = value
            with self.subTest(role=role, key=key), self.assertRaises(ValueError):
                release.selectors(json.dumps(broken), event)

    def product(self):
        selected = self.inputs()[0]['production']
        prepared = {'plans': {'production': {'operations': {'arena': '/owned/production'}}}}
        receipt = {'schema': 'native-app-target-product/v1', 'phase': 'production',
            'sourceSHA': selected['sourceSHA'], 'runID': selected['runID'], 'attempt': 1,
            'appSourceSHA': release.APP_SOURCE, 'nativeSourceObjects': {'Sources': 'd' * 40},
            'compilerSHA256': release.COMPILER_SHA, 'recipeSHA256': 'e' * 64, 'arena': '/owned/production',
            'files': {'Products/Release/NexGenVideo': {'kind': 'file'}},
            'state': {'compileComplete': True, 'linkComplete': True, 'linkerCommandSucceeded': True,
                'unsignedLinkSHA256': 'f' * 64, 'dsymComplete': True,
                'imageUUID': 'UUID: 12345678-1234-1234-1234-123456789ABC (arm64) /owned/NexGenVideo\n',
                'dsymUUID': 'UUID: 12345678-1234-1234-1234-123456789ABC (arm64) /owned/NexGenVideo.dSYM\n'}}
        return selected, prepared, receipt

    def test_production_uuid_binding_compares_uuid_and_architecture_without_equating_pathnames(self):
        selected, prepared, receipt = self.product()
        with patch.object(release, 'source_objects', return_value=receipt['nativeSourceObjects']), \
                patch.object(release.targets, 'recipe_identity', return_value='e' * 64):
            self.assertIs(release.verify_product(receipt, selected, 'production', prepared), receipt)
            for replacement in ('UUID: 00000000-1234-1234-1234-123456789ABC (arm64) symbols',
                    'UUID: 12345678-1234-1234-1234-123456789ABC (x86_64) symbols', ''):
                broken = copy.deepcopy(receipt)
                broken['state']['dsymUUID'] = replacement
                with self.subTest(replacement=replacement), self.assertRaises(ValueError):
                    release.verify_product(broken, selected, 'production', prepared)

    def test_successful_product_cannot_cross_sources_recipes_targets_or_incomplete_link_boundaries(self):
        selected, prepared, receipt = self.product()
        with patch.object(release, 'source_objects', return_value=receipt['nativeSourceObjects']), \
                patch.object(release.targets, 'recipe_identity', return_value='e' * 64):
            for key, value in [('sourceSHA', 'f' * 40), ('runID', 102), ('attempt', 2),
                    ('phase', 'tests'), ('appSourceSHA', 'f' * 40), ('recipeSHA256', 'f' * 64),
                    ('nativeSourceObjects', {'Sources': 'f' * 40}), ('compilerSHA256', 'f' * 64),
                    ('arena', '/foreign/production')]:
                broken = copy.deepcopy(receipt)
                broken[key] = value
                with self.subTest(key=key), self.assertRaises(ValueError):
                    release.verify_product(broken, selected, 'production', prepared)
            for key in ('compileComplete', 'linkComplete', 'linkerCommandSucceeded', 'dsymComplete'):
                broken = copy.deepcopy(receipt)
                broken['state'][key] = False
                with self.subTest(key=key), self.assertRaises(ValueError):
                    release.verify_product(broken, selected, 'production', prepared)

    def test_independent_inventory_keeps_all_original_failures_and_the_full_app_and_engine_scopes(self):
        value = release.criteria()
        app = value['modules']['app']
        engine = value['modules']['engine']
        self.assertEqual(len(app['exactDiscoveredFunctionIDs']), 3720)
        self.assertEqual(len(app['exactEndedFunctionIDs']), 3712)
        self.assertEqual(len(app['exactSkippedFunctionIDs']), 8)
        self.assertEqual(len(engine['exactEndedFunctionIDs']), 896)
        self.assertEqual(len(engine['exactSkippedFunctionIDs']), 14)
        self.assertEqual(len(value['xctest']['exactIndividualPassedIDs']), 48)
        self.assertEqual(len(value['originalEightAppFailureIDsRequiredToEndWithoutIssues']), 8)
        self.assertLessEqual(set(value['originalEightAppFailureIDsRequiredToEndWithoutIssues']), set(app['exactEndedFunctionIDs']))
        self.assertEqual(sum(app['expectedCaseCountsByFunction'].values()), 371)
        self.assertEqual(sum(engine['expectedCaseCountsByFunction'].values()), 49)


if __name__ == '__main__':
    unittest.main()
