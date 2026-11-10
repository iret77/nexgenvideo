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

import compiled_app_release as compiled
import compiled_component_reuse as component
import consume_bpy_distributable_source as source
import native_current_cohort
import release_checkpoint
import retained_packaging as packaging
import test_compiled_app_release as legacy_fixtures
import test_compiled_component_assembly as component_fixtures


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


class CompiledComponentReuseTests(unittest.TestCase):
    def binding(self):
        return {'productSourceSHA': component.ORIGIN['sourceSHA'], 'producerSourceSHA': 'c' * 40, 'runID': 777,
            'originalSignedBuildRunID': component.ORIGIN['runID'], 'signedInput': {'componentProduct': component.record()}}

    def origin_fixture(self):
        origin = component.ORIGIN
        run = {'id': origin['runID'], 'head_sha': origin['sourceSHA'], 'repository': {'full_name': packaging.REPOSITORY},
            'actor': {'login': 'iret77'}, 'run_attempt': 1, 'path': '.github/workflows/release.yml',
            'event': 'workflow_dispatch', 'status': 'completed', 'conclusion': 'failure'}
        builder = {'id': origin['builderJobID'], 'run_id': origin['runID'], 'head_sha': origin['sourceSHA'],
            'run_attempt': 1, 'name': 'release-build', 'labels': ['macrunner'], 'status': 'completed', 'conclusion': 'success',
            'started_at': '2026-11-10T13:00:00Z', 'completed_at': '2026-11-10T13:40:00Z',
            'steps': [{'name': name, 'conclusion': 'success'} for name in component.STEPS]}
        def artifact(identifier, digest, name, size):
            return {'id': identifier, 'digest': 'sha256:' + digest, 'name': name, 'size_in_bytes': size,
                'expired': False, 'workflow_run': {'id': origin['runID'], 'head_sha': origin['sourceSHA']},
                'created_at': '2026-11-10T13:30:00Z', 'updated_at': '2026-11-10T13:31:00Z', 'expires_at': '2099-01-01T00:00:00Z'}
        prefix = 'release-signed-input-' + origin['sourceSHA']
        payload = artifact(origin['artifactID'], origin['artifactSHA256'], prefix, origin['artifactBytes'])
        proof = artifact(origin['proofArtifactID'], origin['proofArtifactSHA256'], prefix + '-proof', 100)
        manifest = {'identity': {'version': '1.8.0', 'build': '107'}, 'appTreeSHA256': origin['appTreeSHA256'],
            'files': {'NexGenVideo.zip': {'sha256': origin['appArchiveSHA256']},
                'bpy-source-receipt.json': {'sha256': origin['sourceReceiptSHA256']}},
            'componentAssembly': {'schema': 'compiled-component-assembly/v1'},
            'nativeEvidence': {'schema': 'release-native-compiled-app/v4'}}
        raw = json.dumps(manifest).encode()
        return run, builder, payload, proof, manifest, raw, dict(origin, manifestSHA256=sha(raw))

    def test_component_origin_requires_actual_builder_stages_and_authenticated_artifact_axes(self):
        changes = ('valid', 'actor', 'repo', 'run-source', 'attempt', 'builder', 'runner', 'stage',
            'artifact-source', 'artifact-id', 'digest', 'expiry', 'window', 'manifest', 'payload-size')
        for change in changes:
            with self.subTest(change=change):
                run, builder, payload, proof, manifest, raw, origin = self.origin_fixture()
                if change == 'actor': run['actor']['login'] = 'other'
                elif change == 'repo': run['repository']['full_name'] = 'other/repository'
                elif change == 'run-source': run['head_sha'] = 'f' * 40
                elif change == 'attempt': run['run_attempt'] = 2
                elif change == 'builder': builder['id'] += 1
                elif change == 'runner': builder['labels'] = ['macos-latest']
                elif change == 'stage': builder['steps'][0]['name'] = 'Build and sign app'
                elif change == 'artifact-source': payload['workflow_run']['head_sha'] = 'f' * 40
                elif change == 'artifact-id': payload['id'] += 1
                elif change == 'digest': proof['digest'] = 'sha256:' + 'f' * 64
                elif change == 'expiry': payload['expires_at'] = '2020-01-01T00:00:00Z'
                elif change == 'window': payload['updated_at'] = '2026-11-10T13:50:00Z'
                elif change == 'manifest': raw += b'changed'
                elif change == 'payload-size': payload['size_in_bytes'] += 1
                with patch.object(component, 'ORIGIN', origin), patch.object(release_checkpoint, 'verify_manifest', return_value=manifest):
                    if change == 'valid':
                        value = component.verify_origin(run, builder, payload, proof, raw, verifier=packaging.verify_artifact)
                        self.assertEqual(value['schema'], 'compiled-component-product-reuse/v1')
                        self.assertFalse(value['freshCompilerCoreAssemblyOrRootSignPerformed'])
                    else:
                        with self.assertRaises(ValueError):
                            component.verify_origin(run, builder, payload, proof, raw, verifier=packaging.verify_artifact)

    def test_new_component_qualifier_does_not_extend_legacy_alias_or_invent_pack_journal(self):
        binding = self.binding()
        self.assertTrue(component.qualified(binding))
        self.assertFalse(packaging.compiled_signed_product(binding))
        self.assertFalse(compiled.signed_resume_source(component.ORIGIN['runID'], component.ORIGIN['sourceSHA']))
        self.assertTrue(packaging.qualified_pack_archives({'.build/plugins/musicvideo.ngvpack.zip': compiled.PACK_SHA}, binding))
        for key in ('originalSignedBuildRunID', 'productSourceSHA'):
            changed = copy.deepcopy(binding); changed[key] = 1 if key.endswith('ID') else 'f' * 40
            self.assertFalse(component.qualified(changed))
        legacy = legacy_fixtures.CompiledAppReleaseTests().source_reuse_fixture()[0]
        self.assertTrue(compiled.signed_resume_source(legacy['runID'], legacy['sourceSHA']))
        self.assertFalse(packaging.qualified_pack_archives({'.build/plugins/musicvideo.ngvpack.zip': 'f' * 64}, binding))

    def test_component_source_closure_allows_only_actual_repair_paths_and_keeps_native_inputs_out(self):
        allowed = packaging.packaging_paths(component.ORIGIN['sourceSHA'])
        self.assertEqual(allowed, component.PATHS)
        self.assertTrue(component.PATHS <= native_current_cohort.CI_PATHS)
        for name in ('Sources/NexGenVideo/App.swift', 'Engine/Registry.swift', 'scripts/unreviewed.py',
                     'Runtime/bpy/runtime-lock.json', 'Package.swift', 'plugins/musicvideo.json'):
            self.assertNotIn(name, allowed)
        self.assertNotIn('scripts/notary_continuation.py', packaging.packaging_paths(compiled.SIGNED_RESUME['sourceSHA']))

    def test_normal107_and_packaged107_local_intakes_bind_actual_runtime_and_dmg_separately(self):
        for mode, change in [('normal', 'valid'), ('packaged', 'valid'), ('packaged', 'missing-parent'),
            ('packaged', 'foreign-parent'), ('packaged', 'app'), ('packaged', 'producer')]:
            with self.subTest(mode=mode, change=change), tempfile.TemporaryDirectory() as name:
                root = Path(name); dmg = root / 'current.dmg'; dmg.write_bytes(b'current exact DMG')
                digest = sha(dmg.read_bytes()); product = component.ORIGIN['sourceSHA']
                harness = product if mode == 'normal' else 'c' * 40
                selected = {'schema': 'nexgenvideo/packaging-consumer/1', 'rawProofSHA256': 'd' * 64}
                binding = {'sourceSHA': product, 'dmgSHA256': digest, 'appTreeSHA256': 'a' * 64, 'guideSHA256': 'e' * 64}
                if mode == 'packaged': binding['packaging'] = selected
                parent = self.binding(); parent.update(stage='complete', final={
                    'dmgSHA256': digest, 'appTreeSHA256': 'a' * 64, 'guideSHA256': 'e' * 64})
                if change == 'missing-parent': binding.pop('packaging')
                elif change == 'foreign-parent': parent['signedInput']['componentProduct'] = {}
                elif change == 'app': parent['final']['appTreeSHA256'] = 'f' * 64
                run = {'id': 777, 'head_sha': harness, 'run_attempt': 1, 'workflow_id': 303346287,
                    'path': '.github/workflows/release.yml', 'event': 'workflow_dispatch', 'status': 'completed',
                    'conclusion': 'success', 'actor': {'login': 'iret77'}, 'repository': {'full_name': packaging.REPOSITORY}}
                if change == 'producer': run['head_sha'] = 'f' * 40
                job = {'id': 999, 'run_id': 777, 'head_sha': harness, 'run_attempt': 1, 'labels': ['macrunner'],
                    'name': 'release', 'status': 'completed', 'conclusion': 'success',
                    'started_at': '2026-11-10T10:00:00Z', 'completed_at': '2026-11-10T11:00:00Z'}
                artifact = {'id': 888, 'name': 'release-user-journey-input', 'digest': 'sha256:' + 'b' * 64,
                    'expired': False, 'workflow_run': {'id': 777, 'head_sha': harness},
                    'created_at': '2026-11-10T10:30:00Z', 'updated_at': '2026-11-10T10:31:00Z', 'expires_at': '2099-01-01T00:00:00Z'}
                inputs = {'candidate_kind': 'signed-journey', 'journey_scenario': 'normal-fresh-local-musicvideo',
                    'run_id': '777', 'artifact_id': '888', 'artifact_sha256': 'b' * 64,
                    'source_sha': product, 'expected_dmg_sha256': digest}
                event = root / 'event.json'; event.write_text(json.dumps({'inputs': inputs}))
                with patch.dict(os.environ, GITHUB_EVENT_PATH=str(event)), \
                    patch.object(packaging, 'consumer_record', return_value=parent), patch.object(packaging, 'consumer_harness'), \
                    patch.object(compiled, 'api', side_effect=[run, {'total_count': 1, 'jobs': [job]}, artifact]):
                    if change == 'valid':
                        result = compiled.local_pack_runtime_origin(binding, dmg)
                        self.assertEqual(result['sourceSHA'], product)
                        self.assertEqual(result.get('producerSourceSHA', product), harness)
                        self.assertEqual(result.get('packaging'), selected if mode == 'packaged' else None)
                    else:
                        with self.assertRaises(ValueError): compiled.local_pack_runtime_origin(binding, dmg)

    def source_fixture(self):
        old_origin, old_value, old_receipt, old_reuse = legacy_fixtures.CompiledAppReleaseTests().source_reuse_fixture()
        receipt = dict(json.loads(old_value['bpy-source-original-receipt.json']), sourceSHA=component.ORIGIN['sourceSHA'])
        raw = json.dumps(receipt, indent=2) + '\n'
        origin = dict(component.ORIGIN, sourceReceiptSHA256=sha(raw.encode()))
        reuse = {'schema': 'component-bpy-source-receipt-reuse/v1', 'state': 'REUSED', 'signedProduct': origin,
            'productSourceSHA': origin['sourceSHA'], 'harnessSourceSHA': 'c' * 40, 'runID': 777,
            'attempt': 1, 'job': 'release', 'publicSourceAsset': receipt['publicSourceAsset'],
            'originalValidation': receipt['validation'], 'derivedReceiptSHA256': origin['sourceReceiptSHA256'],
            'originEvidence': old_reuse['originEvidence'], 'acquiredAt': old_reuse['acquiredAt'],
            'semanticSourceValidationPerformed': False}
        value = {'bpy-source-original-receipt.json': raw, 'bpy-source-receipt.json': raw,
            'bpy-source-reuse.json': json.dumps(reuse)}
        return origin, value, receipt, reuse

    def test_component_source_reuse_preserves_exact107_consumer_and_original_semantics(self):
        origin, value, receipt, reuse = self.source_fixture()
        with patch.object(component, 'ORIGIN', origin), patch.object(source, 'validate') as semantic:
            actual, proof = compiled.verify_source_reuse(value, origin['sourceSHA'], 'c' * 40, 777)
            self.assertEqual(actual, receipt)
            self.assertEqual(proof['originalValidation'], receipt['validation'])
            source.require_receipt(actual, receipt['publicSourceAsset'], origin['sourceSHA'])
            with self.assertRaises(ValueError): source.require_receipt(actual, receipt['publicSourceAsset'], 'c' * 40)
            for change in ('receipt', 'validation', 'harness', 'run', 'fresh', 'original'):
                changed = copy.deepcopy(value); proof = json.loads(changed['bpy-source-reuse.json'])
                if change == 'receipt': changed['bpy-source-receipt.json'] += ' '
                elif change == 'original': changed['bpy-source-original-receipt.json'] += ' '
                elif change == 'validation': proof['originalValidation'] = {}
                elif change == 'harness': proof['harnessSourceSHA'] = 'f' * 40
                elif change == 'run': proof['runID'] += 1
                else: proof['semanticSourceValidationPerformed'] = True
                changed['bpy-source-reuse.json'] = json.dumps(proof)
                with self.subTest(change=change), self.assertRaises(ValueError):
                    compiled.verify_source_reuse(changed, origin['sourceSHA'], 'c' * 40, 777)
            semantic.assert_not_called()

    def test_component_native_reuse_record_cannot_claim_new_native_execution_or_another_current_run(self):
        binding = self.binding()
        value = component.native_record(binding)
        component.verify_native_record(value, binding)
        for section, key, changed_value in [('current', 'runID', 778), ('current', 'harnessSourceSHA', 'f' * 40),
            ('current', 'appTreeSHA256', 'f' * 64), ('original', 'builderJobID', 1)]:
            changed = copy.deepcopy(value); changed[section][key] = changed_value
            with self.subTest(key=key), self.assertRaises(ValueError): component.verify_native_record(changed, binding)
        changed = copy.deepcopy(value); changed['currentNativeSignatureLinkOrLoadPerformed'] = True
        with self.assertRaises(ValueError): component.verify_native_record(changed, binding)

    def test_component_writer_rebinds_current_input_object_bytes_and_physical_root_after_callouts(self):
        for change in ('valid', 'object-run', 'object-source', 'input-bytes', 'root-link', 'attempt'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as name:
                temporary = Path(name)
                root = temporary / 'packaging'; (root / 'input').mkdir(parents=True)
                binding = self.binding(); binding.update(attempt=1, stage='input')
                raw = packaging.encoded(binding); path = root / 'input/packaging-provenance.json'; path.write_bytes(raw)
                env = {'RUNNER_TEMP': str(temporary), 'GITHUB_ACTIONS': 'true', 'GITHUB_REPOSITORY': packaging.REPOSITORY,
                    'GITHUB_JOB': 'release', 'GITHUB_RUN_ATTEMPT': '1', 'GITHUB_SHA': binding['producerSourceSHA'],
                    'GITHUB_RUN_ID': '777', 'RETAINED_PACKAGING_ROOT': str(root), 'RETAINED_PACKAGING_INPUT_SHA256': sha(raw)}
                with patch.dict(os.environ, env), patch.object(component.sys, 'platform', 'darwin'):
                    anchor = component.current_execution(binding)
                    if change == 'valid': self.assertEqual(component.current_execution(binding, anchor), anchor); continue
                    if change == 'object-run': binding['runID'] = 778
                    elif change == 'object-source': binding['producerSourceSHA'] = 'f' * 40
                    elif change == 'input-bytes': path.write_bytes(raw + b' ')
                    elif change == 'attempt': os.environ['GITHUB_RUN_ATTEMPT'] = '2'
                    else:
                        root.rename(temporary / 'old-root'); root.symlink_to(temporary / 'old-root', target_is_directory=True)
                    with self.assertRaises(ValueError): component.current_execution(binding, anchor)

    def test_component_exact_source_receipt_roundtrips_through_all_actual_source_receiver_contexts(self):
        for context, job, system in [('bpy-runtime', 'runtime', 'darwin'),
            ('workspace-source-preflight', 'runtime', 'linux'), ('settings-restore', 'acceptance', 'darwin')]:
            for change in ('valid', 'input-receipt', 'replaced-destination'):
                with self.subTest(context=context, change=change), tempfile.TemporaryDirectory() as name:
                    temporary = Path(name); runner = temporary / 'runner'; runner.mkdir()
                    outside = temporary / 'outside'; outside.mkdir()
                    origin, value, receipt, reuse = self.source_fixture()
                    public = dict(receipt['publicSourceAsset'], filename='source.tar', manifestFilename='manifest.json', size=6,
                        sha256=sha(b'source'), manifestSHA256=sha(b'manifest'))
                    receipt = dict(receipt, publicSourceAsset=public, validation={**receipt['validation'],
                        'archiveSHA256': public['sha256'], 'manifestSHA256': public['manifestSHA256']})
                    raw = json.dumps(receipt, indent=2) + '\n'; origin['sourceReceiptSHA256'] = sha(raw.encode())
                    reuse.update(signedProduct=origin, publicSourceAsset=public, originalValidation=receipt['validation'],
                        derivedReceiptSHA256=origin['sourceReceiptSHA256'])
                    value = {'bpy-source-original-receipt.json': raw, 'bpy-source-receipt.json': raw,
                        'bpy-source-reuse.json': json.dumps(reuse)}
                    directory, evidence = runner / 'qualified', runner / 'evidence/reused.json'
                    input_path = runner / 'receipt.json'; input_path.write_text(raw if change != 'input-receipt' else '{}')
                    with patch.object(component, 'ORIGIN', origin): parent = self.binding()
                    parent.update(stage='complete', final={'bpySourceReuse': value, 'bpySourceReceiptSHA256': sha(raw.encode())})
                    selected = {'selector': 'canonical current parent'}
                    def acquire(public, stage):
                        (stage / 'source.tar').write_bytes(b'source'); (stage / 'manifest.json').write_bytes(b'manifest')
                        if change == 'replaced-destination':
                            directory.rename(runner / 'old-destination'); directory.symlink_to(outside, target_is_directory=True)
                        return reuse['originEvidence']
                    env = {'GITHUB_ACTIONS': 'true', 'GITHUB_REPOSITORY': packaging.REPOSITORY, 'GITHUB_RUN_ATTEMPT': '1',
                        'GITHUB_JOB': job, 'GITHUB_SHA': 'c' * 40, 'GITHUB_RUN_ID': '888', 'RUNNER_TEMP': str(runner)}
                    with patch.dict(os.environ, env), patch.object(compiled.sys, 'platform', system), \
                        patch.object(component, 'ORIGIN', origin), patch.object(packaging, 'consumer_record', return_value=parent), \
                        patch.object(source, 'public_asset', return_value=public), \
                        patch.object(compiled, 'acquire_source_pair', side_effect=acquire), \
                        patch.object(source, 'validate') as semantic, patch.object(compiled.subprocess, 'run') as native:
                        if change == 'valid':
                            result = compiled.consume_packaging_source(directory, origin['sourceSHA'], input_path,
                                selected, context=context, evidence=evidence)
                            self.assertEqual(result['receipt'], receipt)
                            self.assertTrue(compiled.verify_received_source(directory, origin['sourceSHA'], selected, evidence, context=context))
                            self.assertEqual((directory / source.RECEIPT).read_bytes(), raw.encode())
                        else:
                            with self.assertRaises(ValueError):
                                compiled.consume_packaging_source(directory, origin['sourceSHA'], input_path,
                                    selected, context=context, evidence=evidence)
                        semantic.assert_not_called(); native.assert_not_called()
                    self.assertEqual(list(outside.iterdir()), [])

    def test_real_component_create_checkpoint_restore_and_source_handoff_keep_bytes_without_native_replay(self):
        original_restore = release_checkpoint.restore
        observed = []
        def packaged_restore(old_root):
            old = json.loads((old_root / 'binding.json').read_bytes())
            base, manifest = old_root.parent, old['manifest']
            product, run_id = old['sourceSHA'], old['producer']['id']
            origin = dict(component.ORIGIN, sourceSHA=product, runID=run_id,
                appTreeSHA256=manifest['appTreeSHA256'], appArchiveSHA256=manifest['files']['NexGenVideo.zip']['sha256'],
                sourceReceiptSHA256=manifest['files']['bpy-source-receipt.json']['sha256'],
                artifactBytes=old['artifact']['size_in_bytes'], artifactSHA256=old['artifact']['digest'][7:])
            manifest_raw = json.dumps(manifest, indent=2).encode(); origin['manifestSHA256'] = sha(manifest_raw)
            buffer = io.BytesIO()
            with zipfile.ZipFile(buffer, 'w') as archive: archive.writestr('manifest.json', manifest_raw)
            proof_raw = buffer.getvalue(); origin['proofArtifactSHA256'] = sha(proof_raw)
            raw_builder, raw_release = b'original signature commands exit0', b'original external signed pack load exit0'
            origin.update(builderRawSHA256=sha(raw_builder), releaseRawSHA256=sha(raw_release))
            def artifact(identifier, digest, name, size):
                return {'id': identifier, 'name': name, 'digest': 'sha256:' + digest, 'size_in_bytes': size,
                    'expired': False, 'workflow_run': {'id': run_id, 'head_sha': product},
                    'created_at': '2026-11-10T12:10:00Z', 'updated_at': '2026-11-10T12:11:00Z', 'expires_at': '2099-01-01T00:00:00Z'}
            run = {'id': run_id, 'head_sha': product, 'repository': {'full_name': packaging.REPOSITORY},
                'actor': {'login': 'iret77'}, 'run_attempt': 1, 'path': '.github/workflows/release.yml',
                'event': 'workflow_dispatch', 'status': 'completed', 'conclusion': 'failure'}
            def job(identifier, name, state, steps):
                return {'id': identifier, 'name': name, 'run_id': run_id, 'head_sha': product, 'run_attempt': 1,
                    'labels': ['macrunner'], 'status': 'completed', 'conclusion': state,
                    'started_at': '2026-11-10T12:00:00Z', 'completed_at': '2026-11-10T12:59:00Z',
                    'steps': [{'name': step, 'conclusion': 'success'} for step in steps]}
            builder = job(origin['builderJobID'], 'release-build', 'success', component.STEPS)
            release = job(origin['releaseJobID'], 'release', 'failure', component.RELEASE_STEPS)
            prefix = 'release-signed-input-' + product
            payload = artifact(origin['artifactID'], origin['artifactSHA256'], prefix, origin['artifactBytes'])
            proof = artifact(origin['proofArtifactID'], origin['proofArtifactSHA256'], prefix + '-proof', len(proof_raw))
            assembly = artifact(origin['assemblyArtifactID'], origin['assemblyArtifactSHA256'],
                'release-compiled-app-assembly-' + str(run_id) + '-a1', 1)
            routes = {'actions/runs/' + str(run_id): run,
                'actions/jobs/' + str(builder['id']): builder, 'actions/jobs/' + str(release['id']): release,
                **{'actions/artifacts/' + str(item['id']): item for item in (payload, proof, assembly)}}
            originals = {'actions/artifacts/' + str(proof['id']) + '/zip': proof_raw,
                'actions/jobs/' + str(builder['id']) + '/logs': raw_builder,
                'actions/jobs/' + str(release['id']) + '/logs': raw_release}
            root = base / 'release-signed-binding'; root.mkdir()
            packaging_root = base / 'packaging'; (packaging_root / 'input').mkdir(parents=True)
            with patch.object(component, 'ORIGIN', origin):
                binding = {'productSourceSHA': product, 'producerSourceSHA': 'b' * 40, 'runID': 999,
                    'attempt': 1, 'stage': 'input', 'files': {}, 'originalSignedBuildRunID': run_id,
                    'signedInput': {'componentProduct': component.record(), 'manifest': manifest}, 'previousNotary': {}}
            raw = packaging.encoded(binding); input_hash = sha(raw)
            (packaging_root / 'input/packaging-provenance.json').write_bytes(raw)
            saved = dict(old, schema='release-signed-binding/v2', producerSourceSHA='b' * 40,
                executionRunID=999, packagingInputSHA256=input_hash)
            (root / 'binding.json').write_text(json.dumps(saved))
            env = {'GITHUB_SHA': 'b' * 40, 'GITHUB_RUN_ID': '999', 'GITHUB_RUN_ATTEMPT': '1', 'GITHUB_JOB': 'release',
                'GITHUB_ACTIONS': 'true', 'GITHUB_REPOSITORY': packaging.REPOSITORY, 'NGV_COMPILED_APP_RELEASE': 'true',
                'RETAINED_PACKAGING_ROOT': str(packaging_root), 'RETAINED_PACKAGING_INPUT_SHA256': input_hash}
            native_run = release_checkpoint.run
            def acquire(public, stage):
                (stage / public['filename']).write_bytes(b'original'); (stage / public['manifestFilename']).write_bytes(b'{}')
                producer = public['producer']
                if mutation == 'source-object': binding['runID'] += 1
                elif mutation == 'source-input': (packaging_root / 'input/packaging-provenance.json').write_bytes(raw + b' ')
                return {'run': {'id': producer['runID'], 'head_sha': producer['sourceSHA'], 'run_attempt': 1,
                    'repository': {'full_name': packaging.REPOSITORY}, 'head_repository': {'full_name': packaging.REPOSITORY},
                    'status': 'completed', 'event': 'workflow_dispatch', 'path': producer['workflowPath']},
                    'job': {'id': producer['jobID'], 'run_id': producer['runID'], 'head_sha': producer['sourceSHA'],
                        'run_attempt': 1, 'name': 'bpy-qualification / source', 'status': 'completed', 'conclusion': 'success',
                        'labels': ['ubuntu-24.04'], 'started_at': '2026-11-01T00:00:00Z', 'completed_at': '2026-11-01T01:00:00Z'},
                    'artifact': {'id': producer['artifactID'], 'name': producer['artifactName'], 'digest': producer['artifactDigest'],
                        'size_in_bytes': producer['artifactSize'], 'expired': False,
                        'workflow_run': {'id': producer['runID'], 'head_sha': producer['sourceSHA']},
                        'created_at': '2026-11-01T00:30:00Z', 'updated_at': '2026-11-01T00:30:01Z', 'expires_at': '2099-01-01T00:00:00Z'}}
            def api(route):
                if route == 'actions/artifacts/' + str(origin['assemblyArtifactID']):
                    if mutation == 'native-object': binding['runID'] += 1
                    elif mutation == 'native-input': (packaging_root / 'input/packaging-provenance.json').write_bytes(raw + b' ')
                return routes[route]
            with patch.dict(os.environ, env), patch.object(component.sys, 'platform', 'darwin'), \
                patch.object(component, 'ORIGIN', origin), patch.object(release_checkpoint, 'packaging_binding', return_value=binding), \
                patch.object(packaging, 'current_binding', return_value=binding), patch.object(packaging, 'api', side_effect=api), \
                patch.object(packaging, 'read_api', side_effect=lambda route, **kwargs: originals[route]), \
                patch.object(compiled, 'pack_verification_origin'), patch.object(compiled, 'acquire_source_pair', side_effect=acquire), \
                patch.object(release_checkpoint, 'run', wraps=native_run) as calls:
                try:
                    original_restore(root)
                    if mutation.startswith('native-'):
                        self.assertFalse((root / 'component-native-checks.reused.json').exists())
                    compiled.prepare_resumed_source(root, base / '.build/bpy-source')
                except ValueError:
                    if mutation.startswith('native-'):
                        self.assertFalse((root / 'component-native-checks.reused.json').exists())
                    elif mutation.startswith('source-'):
                        public = json.loads(manifest['componentAssembly']['sourceHandoff']['originalReceipt'])['publicSourceAsset']
                        self.assertFalse((base / '.build/bpy-source' / public['filename']).exists())
                        self.assertFalse((base / '.build/bpy-source' / public['manifestFilename']).exists())
                    raise
                value = compiled.capture_source_reuse(base / '.build/bpy-source', binding)
                component.verify_native_materialization(binding, root, base / '.build/NexGenVideo.app')
                self.assertEqual(sha(value['bpy-source-receipt.json'].encode()), origin['sourceReceiptSHA256'])
                self.assertEqual(value['bpy-source-original-receipt.json'], value['bpy-source-receipt.json'])
                self.assertTrue((root / 'component-native-checks.reused.json').is_file())
                self.assertFalse(any(call.args[0] == 'codesign' for call in calls.call_args_list))
                observed.append('actual checkpoint and source handoff preserved')
        for mutation in ('valid', 'native-object', 'native-input', 'source-object', 'source-input'):
            with self.subTest(mutation=mutation), patch.object(release_checkpoint, 'restore', side_effect=packaged_restore):
                if mutation == 'valid':
                    component_fixtures.CompiledComponentAssemblyTests().test_real_create_restore_and_source_receiver_keep_exact_component_and_original_validation()
                else:
                    with self.assertRaises(ValueError):
                        component_fixtures.CompiledComponentAssemblyTests().test_real_create_restore_and_source_receiver_keep_exact_component_and_original_validation()
        self.assertEqual(observed, ['actual checkpoint and source handoff preserved'])
