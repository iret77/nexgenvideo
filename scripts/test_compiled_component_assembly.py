import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import struct
import tarfile
import tempfile
import unittest
import app_cohort_v2
from unittest.mock import patch
import uuid
import zipfile

import compiled_app_release as release
import consume_bpy_distributable_source as source


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def image(kind, identifier, payload=b'engine instructions', signature=b'old signature'):
    commands = struct.pack('<II16s', 0x1b, 24, uuid.UUID(identifier).bytes)
    if kind in (2, 6):
        commands += struct.pack('<II16sQQQQiiII', 0x19, 72, b'__LINKEDIT', 4096, 4096, 136, 4096, 1, 1, 0, 0)
        start = 32 + 24 + 72 + 16 + len(payload)
        commands += struct.pack('<IIII', 0x1d, 16, start, len(signature))
    else:
        signature = b''
    return struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, kind, 3 if kind in (2, 6) else 1,
        len(commands), 0, 0) + commands + payload + signature


class CompiledComponentAssemblyTests(unittest.TestCase):
    def fixture(self, base):
        root = base / 'evidence'; root.mkdir()
        runtime = root / 'runtime'; runtime.mkdir()
        app = base / '.build/NexGenVideo.app'
        engine = app / 'Contents/Frameworks/libNexGenEngine.dylib'; engine.parent.mkdir(parents=True)
        engine.write_bytes(b'old distribution image'); engine.chmod(0o755)
        main = app / 'Contents/MacOS/NexGenVideo'; main.parent.mkdir()
        main.write_bytes(image(2, 'C1AB1815-D829-3F3E-B536-C8F3D703FEE2')); main.chmod(0o755)
        self.main_sha = sha(main.read_bytes())
        old_symbols = base / '.build/NexGenEngine.dSYM'; old_symbols.mkdir(); (old_symbols / 'old').write_bytes(b'old symbols')
        identifier = 'CB1CDC7B-9591-32A1-9FC5-735183BA68E2'
        linked = runtime / engine.name; linked.write_bytes(image(6, identifier)); linked.chmod(0o755)
        module = runtime / 'NexGenEngine.swiftmodule/arm64-apple-macos.swiftmodule'
        module.parent.mkdir(); module.write_bytes(b'qualified compiler module'); module.chmod(0o644)
        symbols = runtime / 'libNexGenEngine.dylib.dSYM'
        dwarf = symbols / 'Contents/Resources/DWARF/libNexGenEngine.dylib'
        dwarf.parent.mkdir(parents=True); dwarf.write_bytes(image(10, identifier)); dwarf.chmod(0o644)
        (symbols / 'Contents/Info.plist').write_bytes(b'original symbol metadata')
        files = {}
        for path in [symbols, *symbols.rglob('*'), linked, module]:
            mode = stat.S_IMODE(path.lstat().st_mode)
            files[path.relative_to(runtime).as_posix()] = {'kind': 'directory', 'mode': mode} if path.is_dir() else {
                'kind': 'file', 'mode': mode, 'bytes': path.stat().st_size, 'sha256': sha(path.read_bytes())}
        production = root / 'production-main'; production.write_bytes(main.read_bytes()); production.chmod(0o755)
        main_symbols = Path(str(production) + '.dSYM')
        main_dwarf = main_symbols / 'Contents/Resources/DWARF/NexGenVideo'
        main_dwarf.parent.mkdir(parents=True)
        main_dwarf.write_bytes(image(10, 'C1AB1815-D829-3F3E-B536-C8F3D703FEE2')); main_dwarf.chmod(0o644)
        (main_symbols / 'Contents/Info.plist').write_bytes(b'original Main symbol metadata')
        shutil.copytree(main_symbols, base / '.build/NexGenVideo.dSYM')
        arena = str(base / 'production-arena')
        linked_path = str(Path(arena) / 'Products/Release/libNexGenEngine.dylib')
        manifest = {'sourceObjects': {'Engine': 'a' * 40}, 'binaryRoot': str(base / 'original-bank'),
            'configuration': 'release', 'swiftcFlags': ['-enable-testing'], 'files': files}
        raw = (json.dumps(manifest, indent=2) + '\n').encode(); (root / 'bank-runtime-manifest.json').write_bytes(raw)
        bound = {'runtime': str(runtime), 'runtimeManifestSHA256': sha(raw),
            'products': {'production': {'output': str(production)}},
            'prepared': {'plans': {'production': {'driver': {'targetGUID': 'APP'},
                'operations': {'arena': arena, 'links': [{'targetGUID': 'APP', 'argv': ['clang', linked_path]}]}}}}}
        pins = {'sha256': sha(linked.read_bytes()), 'bytes': linked.stat().st_size, 'uuid': identifier,
            'dsymSHA256': sha(dwarf.read_bytes()), 'moduleSHA256': sha(module.read_bytes()),
            'mainUnsignedSHA256': sha(production.read_bytes()), 'retiredImageSHA256': sha(engine.read_bytes()),
            'payloadSHA256': release.signed_payload_sha(linked), 'symbolsTreeSHA256': release.canonical_bundle_tree(symbols)}
        return root, app, bound, pins, sha(raw)

    def install(self, base, setup=None, signer=None):
        root, app, bound, pins, manifest_sha = self.fixture(base)
        self.component_bound = bound
        if setup: setup(root, app, bound, pins)
        calls = []
        self.sign_calls = calls
        def logged(folder, label, argv, **kwargs):
            calls.append((label, argv))
            if label == 'sign-linked-engine':
                path = Path(argv[-1]); raw = bytearray(path.read_bytes())
                if signer:
                    raw = signer(raw)
                else:
                    raw[-13:] = b'new signature'
                path.write_bytes(raw)
        previous = Path.cwd()
        os.chdir(base)
        try:
            with patch.object(release, 'LINKED_ENGINE', pins), patch.object(release.retained, 'MANIFEST_SHA', manifest_sha), \
                    patch.object(release, 'source_objects', return_value={'Engine': 'a' * 40}), \
                    patch.object(release.targets, 'logged', side_effect=logged):
                result = release.install_linked_engine(root, app, bound, 'Developer ID Application: Test')
                release.verify_engine_materialization(result, app, base / '.build/NexGenEngine.dSYM')
                return result, calls, root, app, pins
        finally:
            os.chdir(previous)

    def test_actual_link_dependency_and_complete_symbols_are_reused_with_only_required_leaf_signing(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, calls, root, app, pins = self.install(Path(temporary))
            self.assertEqual([name for name, _ in calls], ['sign-linked-engine', 'verify-linked-engine-signature'])
            self.assertIn('Developer ID Application: Test', calls[0][1])
            self.assertEqual(sha((app / 'Contents/MacOS/NexGenVideo').read_bytes()), self.main_sha)
            self.assertEqual((root / 'retired-original-engine-image').read_bytes(), b'old distribution image')
            self.assertEqual(result['original'], pins)
            self.assertFalse(result['compilerOrLinkerInvoked'])
            self.assertEqual(result['payloadSHA256'], pins['payloadSHA256'])
            self.assertNotEqual(result['distributionImageSHA256'], pins['sha256'])
            self.assertTrue((Path(temporary) / '.build/NexGenEngine.dSYM/Contents/Resources/DWARF/libNexGenEngine.dylib').is_file())

    def test_wrong_engine_module_main_link_or_symbol_inputs_fail_before_native_signing(self):
        variants = ('engine', 'module', 'main', 'link', 'symbol', 'extra-symbol', 'symbol-mode', 'symbol-root-mode', 'engine-mode')
        for changed in variants:
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temporary:
                def mutate(root, app, bound, pins):
                    runtime = root / 'runtime'
                    paths = {'engine': runtime / 'libNexGenEngine.dylib',
                        'module': runtime / 'NexGenEngine.swiftmodule/arm64-apple-macos.swiftmodule',
                        'main': Path(bound['products']['production']['output']),
                        'symbol': runtime / 'libNexGenEngine.dylib.dSYM/Contents/Info.plist'}
                    if changed in paths: paths[changed].write_bytes(b'changed bytes')
                    elif changed == 'link': bound['prepared']['plans']['production']['operations']['links'][0]['argv'][-1] = '/other/libNexGenEngine.dylib'
                    elif changed == 'extra-symbol': (runtime / 'libNexGenEngine.dylib.dSYM/unqualified').write_bytes(b'extra')
                    elif changed == 'symbol-mode': (runtime / 'libNexGenEngine.dylib.dSYM/Contents/Info.plist').chmod(0o755)
                    elif changed == 'symbol-root-mode': (runtime / 'libNexGenEngine.dylib.dSYM').chmod(0o700)
                    else: (runtime / 'libNexGenEngine.dylib').chmod(0o644)
                with self.assertRaises(ValueError): self.install(Path(temporary), mutate)
                self.assertEqual(self.sign_calls, [])

    def test_signature_callout_cannot_change_engine_instructions_with_preserved_uuid(self):
        with tempfile.TemporaryDirectory() as temporary:
            def mutate(raw):
                raw[144] ^= 1
                return raw
            with self.assertRaisesRegex(ValueError, 'signature changed'):
                self.install(Path(temporary), signer=mutate)

    def test_signature_callout_cannot_change_symbol_metadata_with_preserved_dwarf_uuid(self):
        with tempfile.TemporaryDirectory() as temporary:
            def mutate(raw):
                path = Path(temporary) / '.build/NexGenEngine.dSYM/Contents/Info.plist'
                path.write_bytes(b'mutated during signing')
                return raw
            with self.assertRaisesRegex(ValueError, 'component image'):
                self.install(Path(temporary), signer=mutate)

    def test_component_materialization_rejects_false_signed_hash_even_when_syntactically_valid(self):
        with tempfile.TemporaryDirectory() as temporary:
            result, _, _, app, pins = self.install(Path(temporary))
            result['distributionImageSHA256'] = 'f' * 64
            with patch.object(release, 'LINKED_ENGINE', pins), self.assertRaises(ValueError):
                release.verify_engine_materialization(result, app, Path(temporary) / '.build/NexGenEngine.dSYM')

    def main_pins(self, root, app):
        production = root / 'production-main'
        symbols = Path(str(production) + '.dSYM')
        return {'compiledImageSHA256': sha(production.read_bytes()),
            'uuid': release.image_uuid(production, 2), 'payloadSHA256': release.signed_payload_sha(app / 'Contents/MacOS/NexGenVideo', 2),
            'symbolsTreeSHA256': release.canonical_bundle_tree(symbols),
            'dwarfSHA256': sha((symbols / 'Contents/Resources/DWARF/NexGenVideo').read_bytes())}

    def test_macho_uuid_and_signature_bounds_reject_truncated_or_foreign_images(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'image'
            for raw in (b'not Mach-O', image(2, '11111111-1111-1111-1111-111111111111'),
                    image(6, '11111111-1111-1111-1111-111111111111')[:-1]):
                path.write_bytes(raw)
                with self.subTest(size=len(raw)), self.assertRaises(ValueError): release.signed_payload_sha(path)

    def test_ad_hoc_identity_is_not_admitted_as_a_distribution_signature(self):
        with self.assertRaisesRegex(ValueError, 'Developer ID'):
            release.install_linked_engine(Path('/unused'), Path('/unused/App'), {}, '-')

    def test_qualified_archive_crc_is_reused_only_for_exact_original_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'original.zip'
            with zipfile.ZipFile(path, 'x') as archive: archive.writestr('product', b'qualified bytes')
            digest = sha(path.read_bytes())
            with patch.object(zipfile.ZipFile, 'testzip', side_effect=AssertionError('old CRC repeated')):
                with release.verified_zip(path, 1024, qualified_sha=digest) as archive:
                    self.assertEqual(archive.namelist(), ['product'])
                with self.assertRaises(ValueError): release.verified_zip(path, 1024, qualified_sha='f' * 64)

    def test_component_checkpoint_roundtrip_preserves_source_and_rejects_component_or_receipt_aliases(self):
        with tempfile.TemporaryDirectory() as temporary:
            engine, _, root, app, pins = self.install(Path(temporary))
            main_pins = self.main_pins(root, app)
            public = json.loads(Path('Runtime/bpy/runtime-lock.json').read_text())['distributionClosure']['publicSourceAsset']
            original = {'schema': source.SCHEMA, 'sourceSHA': release.RETAINED_SOURCE, 'publicSourceAsset': public,
                'origin': {'kind': 'actions', 'producer': public['producer']}, 'validation': {
                    'schema': 'nexgenvideo/bpy-distributable-source-validation/1', 'archiveSHA256': public['sha256'],
                    'manifestSHA256': public['manifestSHA256'], 'correspondenceComplete': True,
                    'noticeComplete': True, 'notices': 965, 'sources': 144}}
            raw = json.dumps(original, indent=2, sort_keys=True) + '\n'
            self.assertEqual(sha(raw.encode()), release.SIGNED_RESUME['sourceReceiptSHA256'])
            consumer = 'a' * 40
            derived = dict(original, sourceSHA=consumer)
            derived_sha = sha((json.dumps(derived, indent=2, sort_keys=True) + '\n').encode())
            component = {'schema': 'compiled-component-assembly/v1', 'sourceSHA': consumer, 'runID': 777,
                'attempt': 1, 'build': '107', 'engine': engine, 'sourceHandoff': {
                    'schema': 'compiled-component-source-handoff/v1', 'state': 'REUSED', 'originalReceipt': raw,
                    'originalReceiptSHA256': sha(raw.encode()), 'qualification': source.QUALIFIED_HANDOFF,
                    'consumerSourceSHA': consumer, 'receiptSHA256': derived_sha, 'semanticSourceValidationPerformed': False},
                'main': {'original': main_pins, 'distributionImageSHA256': sha((app / 'Contents/MacOS/NexGenVideo').read_bytes())}}
            arena = str(Path(engine['productionLinkerInput']).parents[2])
            native = {'schema': 'release-native-compiled-app/v4', 'products': {'production': {'receipt': {
                'arena': arena, 'state': {'unsignedLinkSHA256': pins['mainUnsignedSHA256']}}}}}
            manifest = {'schema': 'release-signed-input/v1', 'repository': release.REPOSITORY,
                'sourceSHA': consumer, 'runID': 777, 'attempt': 1,
                'identity': {'version': '1.8.0', 'build': '107', 'sourceSHA': consumer, 'catalogURL': 'https://example.test/catalog'},
                'appTreeSHA256': 'b' * 64, 'nativeEvidence': native, 'componentAssembly': component,
                'files': {name: {'bytes': 10, 'sha256': derived_sha if name == 'bpy-source-receipt.json' else 'c' * 64}
                    for name in release.checkpoint.FILES}}
            with patch.object(release, 'LINKED_ENGINE', pins), \
                    patch.object(release, 'MAIN_PRODUCT', main_pins), \
                    patch.object(release.retained, 'MANIFEST_SHA', engine['manifestSHA256']), \
                    patch.object(release, 'verify_receipt'):
                actual = json.loads(json.dumps(manifest))
                release.checkpoint.verify_manifest(actual, consumer, 777)
                release.verify_component_materialization(actual['componentAssembly'], app, Path(temporary) / '.build/NexGenEngine.dSYM')
                for section, key, changed in [('engine', 'symbolsTreeSHA256', 'f' * 64),
                        ('engine', 'productionLinkerInput', '/other/libNexGenEngine.dylib'),
                        ('engine', 'original', {}), ('sourceHandoff', 'consumerSourceSHA', release.RETAINED_SOURCE),
                        ('sourceHandoff', 'receiptSHA256', 'f' * 64), ('sourceHandoff', 'semanticSourceValidationPerformed', True)]:
                    broken = copy.deepcopy(actual); broken['componentAssembly'][section][key] = changed
                    with self.subTest(section=section, key=key), self.assertRaises(ValueError):
                        release.checkpoint.verify_manifest(broken, consumer, 777)
                broken = copy.deepcopy(actual); del broken['componentAssembly']
                with self.assertRaises(ValueError): release.checkpoint.verify_manifest(broken, consumer, 777)

    def normal_runtime(self, base, mutation=None):
        directory = base / 'chat-replay'; bundle = directory / 'plugins/musicvideo.ngvpack'; bundle.mkdir(parents=True)
        product, harness = 'a' * 40, 'b' * 40
        identity = {'CFBundleVersion': '107', 'CFBundleShortVersionString': '1.8.0', 'NGVSourceCommit': product,
            'treeSHA256': 'c' * 64, 'executableSHA256': 'd' * 64}
        receipt = {'schema': 'nexgenvideo/workspace-ui-input/1', 'sourceSHA': product,
            'appTreeSHA256': identity['treeSHA256'], 'archiveSHA256': 'e' * 64}
        proof = {'schema': 'nexgenvideo/retained-release-runtime/1', 'productSourceSHA': product,
            'harnessSourceSHA': harness, 'executionRunID': '55', 'executionAttempt': '1', 'producerAttempt': 1,
            'producerRunID': 777, 'producerJobID': 888, 'runtimeArtifactID': 999, 'runtimeArtifactSHA256': 'f' * 64}
        producer = {'id': 777, 'head_sha': product, 'run_attempt': 1, 'repository': {'full_name': release.REPOSITORY},
            'actor': {'login': 'iret77'}, 'path': '.github/workflows/release.yml', 'workflow_id': 303346287,
            'event': 'workflow_dispatch', 'status': 'completed'}
        job = {'id': 888, 'run_id': 777, 'name': 'release', 'head_sha': product, 'run_attempt': 1,
            'labels': ['macrunner'], 'conclusion': 'success', 'started_at': '2026-11-01T00:00:00Z',
            'completed_at': '2026-11-01T01:00:00Z'}
        artifact = {'id': 999, 'name': 'workspace-ui-app', 'digest': 'sha256:' + 'f' * 64, 'expired': False,
            'workflow_run': {'id': 777, 'head_sha': product}, 'created_at': '2026-11-01T00:30:00Z',
            'updated_at': '2026-11-01T00:30:01Z', 'expires_at': '2099-01-01T00:00:00Z'}
        rows = {'actions/runs/777': producer, 'actions/jobs/888': job, 'actions/artifacts/999': artifact}
        origin = ({'id': release.RETAINED_RUN}, {'id': release.PACK_NATIVE_PROOF['jobID']},
            {'id': release.FINAL_ARTIFACT[0], 'digest': 'sha256:' + release.FINAL_ARTIFACT[1]})
        if mutation: mutation(proof, receipt, identity, artifact, job)
        environment = {'RUNNER_TEMP': str(base), 'GITHUB_WORKSPACE': str(base), 'GITHUB_ACTIONS': 'true',
            'GITHUB_REPOSITORY': release.REPOSITORY, 'GITHUB_SHA': harness, 'GITHUB_RUN_ID': '55',
            'GITHUB_RUN_ATTEMPT': '1', 'GITHUB_JOB': 'replay'}
        with patch.dict(os.environ, environment), patch.object(release.sys, 'platform', 'darwin'), \
                patch.object(release, 'api', side_effect=lambda route: rows[route]), \
                patch.object(release, 'pack_verification_origin', return_value=origin), \
                patch.object(release, 'canonical_bundle_tree', return_value=release.PACK_TREE), \
                patch.object(app_cohort_v2, 'has_manifest', return_value=False), \
                patch.object(release.subprocess, 'run', side_effect=AssertionError('old native pack check repeated')):
            return release.verify_component_runtime_pack(directory, product, receipt, proof, identity)

    def test_new_normal_product_runtime_reuses_original_pack_with_exact_current_producer(self):
        with tempfile.TemporaryDirectory() as temporary:
            actual = self.normal_runtime(Path(temporary))
            self.assertEqual(actual['schema'], 'component-runtime-pack-copy-reuse/v1')
            self.assertEqual(actual['producerRunID'], 777)
            self.assertEqual(actual['runtimeArtifactID'], 999)
            self.assertEqual(actual['packTreeSHA256'], release.PACK_TREE)
            self.assertFalse(actual['currentNativeCodesignOrStaplerPerformed'])
            self.assertFalse(actual['newAppPackLoadQualified'])
            self.assertTrue((Path(temporary) / 'chat-replay/pack-verification.reused.json').is_file())

    def test_new_normal_runtime_pack_refuses_foreign_artifact_job_or_consumer(self):
        for changed in ('artifact', 'job', 'build', 'harness', 'attempt', 'receipt'):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temporary:
                def mutate(proof, receipt, identity, artifact, job):
                    if changed == 'artifact': artifact['digest'] = 'sha256:' + '0' * 64
                    elif changed == 'job': job['labels'] = ['macos-latest']
                    elif changed == 'build': identity['CFBundleVersion'] = '106'
                    elif changed == 'harness': proof['harnessSourceSHA'] = '0' * 40
                    elif changed == 'attempt': proof['executionAttempt'] = '2'
                    else: receipt['appTreeSHA256'] = '0' * 64
                with self.assertRaises(ValueError): self.normal_runtime(Path(temporary), mutate)
                self.assertFalse((Path(temporary) / 'chat-replay/pack-verification.reused.json').exists())

    def test_root_sign_callback_cannot_requalify_changed_main_or_original_symbols(self):
        for changed in ('installed-main', 'original-main', 'installed-symbols'):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary)
                engine, _, root, app, engine_pins = self.install(base)
                main_pins = self.main_pins(root, app)
                calls = []
                def logged(folder, label, argv, **kwargs):
                    calls.append(label)
                    if label == 'sign-new-app-root':
                        path = {'installed-main': app / 'Contents/MacOS/NexGenVideo',
                            'original-main': root / 'production-main',
                            'installed-symbols': base / '.build/NexGenVideo.dSYM/Contents/Info.plist'}[changed]
                        raw = bytearray(path.read_bytes()); raw[-1] ^= 1
                        if changed == 'installed-main': raw[144] ^= 1
                        path.write_bytes(raw)
                previous = Path.cwd(); os.chdir(base)
                try:
                    with patch.dict(os.environ, {'GITHUB_SHA': 'a' * 40, 'GITHUB_RUN_ID': '777'}), \
                            patch.object(release, 'LINKED_ENGINE', engine_pins), patch.object(release, 'MAIN_PRODUCT', main_pins), \
                            patch.object(release.targets, 'logged', side_effect=logged):
                        with self.assertRaises(ValueError):
                            release.seal_component_app(root, app, self.component_bound, 'Developer ID Application: Test', engine, {})
                    self.assertEqual(calls.count('sign-new-app-root'), 1)
                    self.assertFalse((root / 'assembled.json').exists())
                finally: os.chdir(previous)

    def test_real_create_restore_and_source_receiver_keep_exact_component_and_original_validation(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            engine, _, root, app, engine_pins = self.install(base)
            main_pins = self.main_pins(root, app)
            consumer = 'a' * 40
            public = copy.deepcopy(json.loads(Path('Runtime/bpy/runtime-lock.json').read_text())['distributionClosure']['publicSourceAsset'])
            public.update(size=8, sha256=sha(b'original'), manifestSHA256=sha(b'{}'))
            lock = base / 'lock.json'; lock.write_text(json.dumps({'distributionStatus': 'ready',
                'distributionClosure': {'publicSourceAsset': public}}))
            validation = {'schema': 'nexgenvideo/bpy-distributable-source-validation/1',
                'archiveSHA256': public['sha256'], 'manifestSHA256': public['manifestSHA256'],
                'correspondenceComplete': True, 'noticeComplete': True, 'sources': 144, 'notices': 965}
            original = {'schema': source.SCHEMA, 'sourceSHA': release.RETAINED_SOURCE, 'publicSourceAsset': public,
                'origin': {'kind': 'actions', 'producer': public['producer']}, 'validation': validation}
            original_raw = (json.dumps(original, indent=2, sort_keys=True) + '\n').encode()
            qualification = {'originalReceiptSHA256': sha(original_raw),
                'publicSourceAssetSHA256': source.canonical_sha(public), 'validationSHA256': source.canonical_sha(validation)}
            source_dir = base / '.build/bpy-source'; source_dir.mkdir()
            (source_dir / source.RECEIPT).write_bytes(original_raw)
            (source_dir / public['filename']).write_bytes(b'original')
            (source_dir / public['manifestFilename']).write_bytes(b'{}')
            info = {'CFBundleShortVersionString': '1.8.0', 'CFBundleVersion': '107', 'NGVSourceCommit': consumer,
                'NGVPluginCatalogURL': 'https://github.com/iret77/nexgenvideo/releases/download/plugins/catalog.json'}
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            for name in ('NexGenVideoDiagnostics.dSYM', 'MusicvideoPlugin.dSYM', 'plugins/musicvideo.ngvpack'):
                path = base / '.build' / name; path.mkdir(parents=True); (path / 'preserved').write_bytes(b'unchanged')
            arena = str(Path(engine['productionLinkerInput']).parents[2])
            native = {'schema': 'release-native-compiled-app/v4', 'products': {'production': {'receipt': {
                'arena': arena, 'state': {'unsignedLinkSHA256': main_pins['compiledImageSHA256']}}}}}
            (root / 'receipt.json').write_text(json.dumps(native))
            environment = {'GITHUB_SHA': consumer, 'GITHUB_RUN_ID': '777', 'GITHUB_RUN_ATTEMPT': '1',
                'GITHUB_JOB': 'release-build', 'RUNNER_TEMP': str(base), 'GITHUB_WORKSPACE': str(base),
                'GITHUB_ENV': str(base / 'github-env'), 'REL_VERSION': '1.8.0',
                'PLUGIN_CATALOG_URL': info['NGVPluginCatalogURL'], 'NOTARY_STATE_DIR': ''}
            calls = []
            def logged(folder, label, argv, **kwargs):
                calls.append(label)
                if label == 'archive-new-signed-app':
                    bundle, target = Path(argv[-2]), Path(argv[-1])
                    with zipfile.ZipFile(target, 'x') as archive:
                        for path in [bundle, *bundle.rglob('*')]: archive.write(path, path.relative_to(bundle.parent))
                elif label.startswith('checkpoint-'):
                    with tarfile.open(argv[2], 'w:gz') as archive:
                        for name in argv[5:]: archive.add(Path(argv[4]) / name, arcname=name)
                else:
                    self.assertIn(label, ['sign-new-app-root', 'verify-new-app-signature', 'verify-distributable-bpy'])
            def native_run(*argv):
                if argv[0] == '/usr/bin/ditto':
                    with zipfile.ZipFile(argv[3]) as archive:
                        archive.extractall(argv[4])
                        for item in archive.infolist():
                            (Path(argv[4]) / item.filename).chmod(stat.S_IMODE(item.external_attr >> 16))
                else: self.assertEqual(list(argv[:3]), ['codesign', '--verify', '--strict'])
            producer = public['producer']
            origin = {'run': {'id': producer['runID'], 'head_sha': producer['sourceSHA'], 'run_attempt': 1,
                'repository': {'full_name': release.REPOSITORY}, 'head_repository': {'full_name': release.REPOSITORY},
                'status': 'completed', 'event': 'workflow_dispatch', 'path': producer['workflowPath']},
                'job': {'id': producer['jobID'], 'run_id': producer['runID'], 'head_sha': producer['sourceSHA'],
                    'run_attempt': 1, 'name': 'bpy-qualification / source', 'status': 'completed', 'conclusion': 'success',
                    'labels': ['ubuntu-24.04'], 'started_at': '2026-11-01T00:00:00Z', 'completed_at': '2026-11-01T01:00:00Z'},
                'artifact': {'id': producer['artifactID'], 'name': producer['artifactName'],
                    'digest': producer['artifactDigest'], 'size_in_bytes': producer['artifactSize'], 'expired': False,
                    'workflow_run': {'id': producer['runID'], 'head_sha': producer['sourceSHA']},
                    'created_at': '2026-11-01T00:30:00Z', 'updated_at': '2026-11-01T00:30:01Z', 'expires_at': '2099-01-01T00:00:00Z'}}
            def acquire(public, stage):
                (stage / public['filename']).write_bytes(b'original')
                (stage / public['manifestFilename']).write_bytes(b'{}')
                return origin
            previous = Path.cwd(); os.chdir(base)
            try:
                with patch.dict(os.environ, environment), patch.object(release, 'LINKED_ENGINE', engine_pins), \
                        patch.object(release, 'MAIN_PRODUCT', main_pins), \
                        patch.object(release.retained, 'MANIFEST_SHA', engine['manifestSHA256']), \
                        patch.object(release, 'SIGNED_RESUME', {**release.SIGNED_RESUME, 'sourceReceiptSHA256': sha(original_raw)}), \
                        patch.object(source, 'QUALIFIED_HANDOFF', qualification), patch.object(source, 'LOCK_PATH', lock), \
                        patch.object(release, 'source_objects', return_value={'Runtime': 'b' * 40}), \
                        patch.object(release, 'native_guard'), patch.object(release, 'verify_receipt'), \
                        patch.object(release.targets, 'logged', side_effect=logged), patch.object(source, 'validate') as validate:
                    handoff = release.derive_component_source(root, source_dir)
                    component = release.seal_component_app(root, app, self.component_bound, 'Developer ID Application: Test', engine, handoff)
                    (root / 'assembled.json').write_text(json.dumps({'sourceSHA': consumer, 'runID': 777,
                        'appTreeSHA256': release.checkpoint.tree_digest(app), 'identity': release.checkpoint.identity(base / '.build'),
                        'componentAssembly': component, 'mainSymbolsTreeSHA256': main_pins['symbolsTreeSHA256']}))
                    assembled_raw = (root / 'assembled.json').read_bytes()
                    missing = json.loads(assembled_raw); del missing['componentAssembly']
                    (root / 'assembled.json').write_text(json.dumps(missing))
                    with self.assertRaisesRegex(ValueError, 'lacks its actual component assembly'):
                        release.create_signed_input(root, base / 'missing-component-output')
                    self.assertFalse((base / 'missing-component-output').exists())
                    for index, (key, changed) in enumerate([('schema', 'wrong'), ('sourceSHA', 'b' * 40),
                            ('runID', 778), ('attempt', 2), ('sourceHandoff', {**handoff, 'receiptSHA256': 'f' * 64}),
                            ('component-null', None)]):
                        invalid = json.loads(assembled_raw)
                        if key == 'component-null': invalid['componentAssembly'] = None
                        else: invalid['componentAssembly'][key] = changed
                        (root / 'assembled.json').write_text(json.dumps(invalid))
                        before_calls = len(calls); refused = base / ('invalid-component-' + str(index))
                        with self.subTest(key=key), self.assertRaises(ValueError):
                            release.create_signed_input(root, refused)
                        self.assertEqual(len(calls), before_calls)
                        self.assertFalse(refused.exists())
                    (root / 'assembled.json').write_bytes(assembled_raw)
                    output = base / 'signed-output'
                    release.create_signed_input(root, output)
                    manifest = json.loads((output / 'manifest.json').read_text())
                    payload = base / 'signed-payload.zip'
                    with zipfile.ZipFile(payload, 'x') as archive:
                        for path in output.iterdir(): archive.write(path, path.name)
                    (base / '.build').rename(base / 'before-restore')
                    restore = base / 'restore'; restore.mkdir()
                    (restore / 'binding.json').write_text(json.dumps({'schema': 'release-signed-binding/v1', 'sourceSHA': consumer,
                        'producer': {'id': 777}, 'manifest': manifest, 'artifact': {
                            'size_in_bytes': payload.stat().st_size, 'digest': 'sha256:' + sha(payload.read_bytes())}}))
                    with patch.object(release.checkpoint, 'packaging_binding', return_value=None), \
                            patch.object(release.checkpoint, 'download', side_effect=lambda artifact, target: shutil.copyfile(payload, target)), \
                            patch.object(release.checkpoint, 'run', side_effect=native_run):
                        release.checkpoint.restore(restore)
                    restored_app = base / '.build/NexGenVideo.app'
                    release.verify_component_materialization(manifest['componentAssembly'], restored_app, base / '.build/NexGenEngine.dSYM')
                    self.assertEqual(manifest['componentAssembly'], component)
                    self.assertEqual((root / 'component-source-original-receipt.json').read_bytes(), original_raw)
                    self.assertEqual(sha((base / '.build/bpy-source/bpy-source-receipt.json').read_bytes()), handoff['receiptSHA256'])
                    with patch.dict(os.environ, {'GITHUB_RUN_ID': '999', 'GITHUB_JOB': 'runtime'}), \
                            patch.object(release, 'acquire_source_pair', side_effect=acquire):
                        source.consume(base / 'receiver', consumer, base / '.build/bpy-source/bpy-source-receipt.json')
                        actual = source.verify_reuse(base / 'receiver', consumer, base / 'receiver-evidence/source.json')
                    self.assertEqual(actual['validation'], validation)
                    self.assertFalse(actual['semanticSourceValidationPerformed'])
                    validate.assert_not_called()
                    self.assertIn('archive-new-signed-app', calls)
                    self.assertEqual(calls.count('sign-new-app-root'), 1)
            finally: os.chdir(previous)


if __name__ == '__main__':
    unittest.main()
