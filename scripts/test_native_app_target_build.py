import copy
import json
import io
import os
from pathlib import Path
import unittest
import zipfile
import tempfile
from unittest.mock import Mock, call, patch

import native_app_target_build as build


class NativeAppTargetBuildTests(unittest.TestCase):
    def host_repair_fixture(self):
        import native_xctest_host
        sources = {name: ('original ' + name).encode() for name in native_xctest_host.INPUTS}
        previous = {name: build.hashlib.sha256(raw).hexdigest() for name, raw in sources.items()}
        current = dict(previous, **{'scripts/native_xctest_host.m': 'a' * 64})
        output = '/owned/Products/Release/NexGenVideoTests.xctest/Contents/MacOS/NexGenVideoTests'
        prepared = {'appSourceSHA': build.cohort.APP_SOURCE, 'nativeSourceObjects': {'Sources': 's', 'Tests': 't'},
            'compilerSHA256': 'c' * 64, 'xctestHostInputs': current,
            'plans': {'tests': {'driver': {'argv': ['swiftc', '-O'], 'targetGUID': 'tests'},
                'operations': {'arena': '/owned', 'links': [{'targetGUID': 'tests', 'output': output}]}}}}
        original = dict(prepared, xctestHostInputs=previous)
        receipt = {'sourceSHA': 'b' * 40, 'recipeSHA256': build.recipe_identity(original, 'tests'),
            'state': {'compileComplete': True, 'linkerCommandSucceeded': True, 'linkComplete': False,
                'linkedOutput': output, 'unsignedLinkSHA256': '1' * 64,
                'imageUUID': 'UUID: 00000000-1111-2222-3333-444444444444 (arm64) ' + output + '\n'}}
        host = {'schema': 'native-xctest-host-build/v1', 'sourceSHA': receipt['sourceSHA'],
            'appSourceSHA': prepared['appSourceSHA'], 'inputs': previous,
            'supportObjectSHA256': native_xctest_host.SUPPORT_SHA}
        origin = {'selected': {'sourceSHA': receipt['sourceSHA'], 'runID': 11, 'artifactID': 12}}
        return sources, prepared, receipt, host, origin

    def host_repair_image_records(self, receipt):
        output = receipt['state']['linkedOutput']
        result = {}
        for label, argv in [('image', ['otool', '-hvL', output]), ('uuid', ['xcrun', 'dwarfdump', '--uuid', output])]:
            result[label + '.argv.json'] = json.dumps(argv).encode()
            result[label + '.exit.json'] = json.dumps({'exitCode': 0}).encode()
            result[label + '.stderr'] = b''
            result[label + '.stdout'] = (b'ARM64 MH_BUNDLE\n@rpath/libNexGenEngine.dylib\n'
                if label == 'image' else receipt['state']['imageUUID'].encode())
        return result

    def test_host_repair_preserves_the_exact_prior_swift_recipe_and_requires_a_fresh_host(self):
        sources, prepared, receipt, host, origin = self.host_repair_fixture()
        original_receipt = copy.deepcopy(receipt)
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, 'w') as archive:
            archive.writestr('evidence/xctest-host-build-inputs.json', json.dumps(host))
            archive.writestr('evidence/xctest-host-compile-link.exit.json', json.dumps({'exitCode': 1}))
            for name, raw in self.host_repair_image_records(receipt).items(): archive.writestr('evidence/' + name, raw)
        with zipfile.ZipFile(buffer) as archive, patch.object(build.capture, 'command',
                side_effect=lambda argv: sources[argv[-1].split(':', 1)[1]]), patch.object(build, 'logged') as logged:
            proof = build.resumed_recipe_context(archive, receipt, prepared, 'tests', origin)
        logged.assert_not_called()
        self.assertEqual(receipt, original_receipt)
        self.assertEqual(proof['originalRecipeSHA256'], receipt['recipeSHA256'])
        self.assertNotEqual(proof['originalRecipeSHA256'], proof['currentRecipeSHA256'])
        self.assertEqual(proof['swiftCompilerExecutionsRequired'], 0)
        self.assertEqual(proof['swiftLinkerExecutionsRequired'], 0)
        self.assertTrue(proof['freshHostCompilationRequired'])
        self.assertFalse(proof['qualifiedHostReused'])
        self.assertEqual(proof['retainedImageChecks']['newInspectionExecutions'], 0)
        self.assertEqual(proof['retainedImageChecks']['unsignedImageSHA256'], receipt['state']['unsignedLinkSHA256'])
        unchanged = dict(prepared, xctestHostInputs=host['inputs'])
        self.assertIsNone(build.resumed_recipe_context(None, receipt, unchanged, 'tests', origin))

    def test_host_repair_rejects_changed_swift_inputs_and_unproven_original_host_failure(self):
        for changed in ('phase', 'not-compiled', 'not-linked', 'completed-bundle', 'qualified-host', 'swift-source',
                        'swift-driver', 'swift-compiler', 'swift-operations', 'host-source', 'success-host',
                        'foreign-host-source', 'support-object', 'image-argv', 'image-exit', 'image-type',
                        'uuid', 'unsigned-path', 'unsigned-sha'):
            with self.subTest(changed=changed):
                sources, prepared, receipt, host, origin = self.host_repair_fixture()
                records = self.host_repair_image_records(receipt)
                phase, status = 'tests', 1
                if changed == 'phase':
                    phase = 'production'; prepared['plans'][phase] = copy.deepcopy(prepared['plans']['tests'])
                elif changed == 'not-compiled': receipt['state']['compileComplete'] = False
                elif changed == 'not-linked': receipt['state']['linkerCommandSucceeded'] = False
                elif changed == 'completed-bundle': receipt['state']['linkComplete'] = True
                elif changed == 'qualified-host': receipt['state']['xctestHost'] = {'signedSHA256': 'd' * 64}
                elif changed == 'swift-source': prepared['nativeSourceObjects']['Sources'] = 'changed'
                elif changed == 'swift-driver': prepared['plans']['tests']['driver']['argv'].append('-different')
                elif changed == 'swift-compiler': prepared['compilerSHA256'] = 'changed'
                elif changed == 'swift-operations': prepared['plans']['tests']['operations']['arena'] = '/foreign'
                elif changed == 'host-source': sources['scripts/native_xctest_host.m'] = b'substituted source'
                elif changed == 'success-host': status = 0
                elif changed == 'foreign-host-source': host['sourceSHA'] = 'e' * 40
                elif changed == 'support-object': host['supportObjectSHA256'] = 'f' * 64
                elif changed == 'image-argv': records['image.argv.json'] = json.dumps(['otool', '-hvL', '/foreign']).encode()
                elif changed == 'image-exit': records['image.exit.json'] = json.dumps({'exitCode': 2}).encode()
                elif changed == 'image-type': records['image.stdout'] = b'ARM64 MH_OBJECT\n@rpath/libNexGenEngine.dylib\n'
                elif changed == 'uuid': records['uuid.stdout'] = b'UUID: unqualified\n'
                elif changed == 'unsigned-path': receipt['state']['linkedOutput'] = '/foreign'
                elif changed == 'unsigned-sha': receipt['state']['unsignedLinkSHA256'] = 'invalid'
                buffer = io.BytesIO()
                with zipfile.ZipFile(buffer, 'w') as archive:
                    archive.writestr('evidence/xctest-host-build-inputs.json', json.dumps(host))
                    archive.writestr('evidence/xctest-host-compile-link.exit.json', json.dumps({'exitCode': status}))
                    for name, raw in records.items(): archive.writestr('evidence/' + name, raw)
                with zipfile.ZipFile(buffer) as archive, patch.object(build.capture, 'command',
                        side_effect=lambda argv: sources[argv[-1].split(':', 1)[1]]), self.assertRaises(ValueError):
                    build.resumed_recipe_context(archive, receipt, prepared, phase, origin)

    def test_tests_plan_is_pinned_requires_both_completed_apps_and_conflicts_only_with_completed_tests(self):
        selected = {'production': dict(build.DRIVER_INPUT_ORIGINS['production-plan']['selected']),
            'testable': dict(build.DRIVER_INPUT_ORIGINS['production-plan']['selected']),
            'tests-plan': dict(build.TESTS_PLAN_ORIGIN['selected'])}
        self.assertEqual(build.resume_inputs(json.dumps(selected)), selected)
        for missing in ('production', 'testable'):
            broken = {key: value for key, value in selected.items() if key != missing}
            with self.subTest(missing=missing), self.assertRaisesRegex(ValueError, 'both completed'):
                build.resume_inputs(json.dumps(broken))
        with self.assertRaisesRegex(ValueError, 'Conflicting completed Tests'):
            build.resume_inputs(json.dumps({**selected, 'tests': selected['tests-plan']}))
        broken = copy.deepcopy(selected); broken['tests-plan']['artifactID'] += 1
        with patch.object(build, 'api') as api, self.assertRaisesRegex(ValueError, 'Unqualified printed Tests'):
            build.resumed_products({'tests-plan': broken['tests-plan']}, {}, 'a' * 40)
        api.assert_not_called()

    def test_retained_tests_plan_stages_cache_and_exact_tmp_with_fresh_session_without_another_print(self):
        for changed in ('valid', 'cache-bytes', 'namespace', 'copy', 'collision'):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve(); archive_path, records = self.planning_fixture(root)
                renamed = {name.replace('pzfKPD', 'R93c7x'): item for name, item in records.items()}
                with zipfile.ZipFile(archive_path) as original, zipfile.ZipFile(root / 'tests.zip', 'w') as archive:
                    for item in original.infolist():
                        name = item.filename.replace('pzfKPD', 'R93c7x')
                        copied = zipfile.ZipInfo(name); copied.create_system = 3; copied.external_attr = item.external_attr
                        archive.writestr(copied, original.read(item))
                stored = root / 'stored'
                with zipfile.ZipFile(root / 'tests.zip') as archive:
                    inputs = build.restore_planning_files(archive, renamed, stored, 'tmp/TemporaryDirectory.R93c7x')
                cache_root, arena, folder = root / 'cache', root / 'arena', root / 'tests'
                arena.mkdir(); folder.mkdir(); candidate = cache_root / 'ModuleCache.noindex/Bucket/original.pcm'
                candidate.parent.mkdir(parents=True); candidate.write_bytes(b'CPCH original'); candidate.chmod(0o644)
                cache_files = {'ModuleCache.noindex/Bucket/original.pcm': {'kind': 'file', 'sha256': build.capture.sha(candidate),
                    'bytes': candidate.stat().st_size, 'mode': 0o644}}
                stdout = root / 'stdout'; stdout.write_text('original Tests jobs\n')
                prepared = {'appSourceSHA': 'a' * 40, 'nativeSourceObjects': {}, 'compilerSHA256': 'b' * 64,
                    'plans': {'tests': {'driver': {'argv': ['swiftc']}, 'operations': {'arena': str(arena)}}},
                    'clangBuildSessions': {'testable': {'sessionTimestamp': 1234567890.5}}}
                planning = {'schema': 'native-app-retained-printed-driver-plan/v1',
                    'recipeSHA256': build.recipe_identity(prepared, 'tests'),
                    'origin': {'selected': dict(build.TESTS_PLAN_ORIGIN['selected'])},
                    'temporaryRoot': str(stored), 'temporaryFiles': inputs, 'stdoutPath': str(stdout),
                    'stdoutSHA256': build.capture.sha(stdout), 'cacheRoot': str(cache_root), 'cacheFiles': cache_files}
                prepared['retainedTestsPlanning'] = planning
                if changed == 'cache-bytes': candidate.write_bytes(b'corrupt')
                elif changed == 'namespace':
                    name, item = planning['temporaryFiles'].popitem(); planning['temporaryFiles'][name.replace('R93c7x', 'foreign')] = item
                elif changed == 'collision':
                    destination = arena / next(iter(cache_files)); destination.parent.mkdir(parents=True)
                    destination.write_bytes(b'another cached product')
                with patch.object(build, 'logged') as logged:
                    if changed == 'copy':
                        with patch.object(build.shutil, 'copyfile', side_effect=lambda source, destination: destination.write_bytes(b'bad')), \
                                self.assertRaises(ValueError):
                            build.driver_planning_jobs(folder, 'tests', prepared, {}, {})
                    elif changed != 'valid':
                        with self.assertRaises(ValueError): build.driver_planning_jobs(folder, 'tests', prepared, {}, {})
                    else:
                        self.assertEqual(build.driver_planning_jobs(folder, 'tests', prepared, {}, {}), stdout.read_text())
                        record = json.loads((folder / 'driver-jobs-reused.json').read_text())
                        self.assertEqual(record['currentPlanningExecutions'], 0)
                        self.assertEqual(record['newSession'], prepared['clangBuildSessions']['testable'])
                        self.assertFalse((folder / 'driver-jobs.exit.json').exists())
                        self.assertEqual((arena / next(iter(cache_files))).read_bytes(), b'CPCH original')
                    logged.assert_not_called()

    def test_platform_test_input_recheck_rejects_byte_mode_and_resolved_path_substitution(self):
        for changed in ('valid', 'bytes', 'mode', 'path', 'compiler', 'sdk'):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve(); path = root / 'interface'; path.write_bytes(b'original'); path.chmod(0o644)
                compiler = root / 'compiler'; compiler.write_bytes(b'compiler')
                sdk = root / 'SDK'; sdk.mkdir()
                item = {'path': str(path), 'resolvedPath': str(path), 'sha256': build.capture.sha(path), 'bytes': 8, 'mode': 0o644,
                    'compilerPath': str(compiler), 'resolvedCompiler': str(compiler), 'sdkPath': str(sdk), 'resolvedSDK': str(sdk)}
                if changed == 'bytes': path.write_bytes(b'modified')
                elif changed == 'mode': path.chmod(0o600)
                elif changed == 'path': path.rename(root / 'original'); path.symlink_to('original')
                elif changed == 'compiler': compiler.rename(root / 'original-compiler'); compiler.symlink_to('original-compiler')
                elif changed == 'sdk': sdk.rename(root / 'original-SDK'); sdk.symlink_to('original-SDK', target_is_directory=True)
                if changed == 'valid': build.verify_platform_developer_inputs({'platformDeveloperInputs': [item]})
                else:
                    with self.assertRaises(ValueError): build.verify_platform_developer_inputs({'platformDeveloperInputs': [item]})

    def test_raw_tests_plan_archive_checks_all_outputs_and_keeps_cache_private_until_tests_execute(self):
        for changed in ('valid', 'cache-bytes', 'state', 'argv'):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve(); arena = root / 'arena'; arena.mkdir()
                payloads = {f'ModuleCache.noindex/Bucket/cache{index}.pcm': b'CPCH' + str(index).encode() for index in range(327)}
                payloads.update({f'SDKExplicitPrecompiledModules/Module{index}.swiftmodule': b'swiftmodule' + str(index).encode() for index in range(6)})
                payloads.update({'ModuleCache.noindex/Session.modulevalidation': b'old session',
                    'ModuleCache.noindex/modules.timestamp': b'', **{f'Intermediates.noindex/aux{index}.json': b'{}' for index in range(5)}})
                files = {name: {'kind': 'file', 'bytes': len(raw), 'sha256': build.hashlib.sha256(raw).hexdigest(), 'mode': 0o644}
                    for name, raw in payloads.items()}
                temporary_files = {f'tmp/TemporaryDirectory.R93c7x/input{index}': b'input' + str(index).encode() for index in range(6)}
                spec = copy.deepcopy(build.TESTS_PLAN_ORIGIN)
                prepared = {'appSourceSHA': 'a' * 40, 'nativeSourceObjects': {'Sources': 'b' * 40},
                    'compilerSHA256': 'c' * 64, 'plans': {'tests': {'driver': {'argv': ['swiftc']}, 'operations': {'arena': str(arena)}}}}
                receipt = {'schema': 'native-app-target-product/v1', 'phase': 'tests',
                    'sourceSHA': spec['selected']['sourceSHA'], 'runID': spec['selected']['runID'], 'attempt': 1,
                    'appSourceSHA': prepared['appSourceSHA'], 'nativeSourceObjects': prepared['nativeSourceObjects'],
                    'arena': str(arena), 'compilerSHA256': prepared['compilerSHA256'], 'recipeSHA256': spec['recipeSHA256'],
                    'state': {'compileComplete': False, 'linkComplete': False, 'compilerExecutions': 0, 'resumed': False},
                    'files': files, 'temporaryFiles': {name: {'kind': 'file', 'bytes': len(raw),
                        'sha256': build.hashlib.sha256(raw).hexdigest()} for name, raw in temporary_files.items()}}
                if changed == 'state': receipt['state']['compileComplete'] = True
                raw_receipt = (json.dumps(receipt, indent=2) + '\n').encode()
                spec['selected']['receiptSHA256'] = build.hashlib.sha256(raw_receipt).hexdigest()
                lines = ['swift-frontend -frontend' for _ in range(111)]
                stdout = '\n'.join(lines) + '\n'
                stdout = stdout[:-1] + ' ' * (1062030 - len(stdout)) + '\n'
                spec['stdoutSHA256'] = build.hashlib.sha256(stdout.encode()).hexdigest()
                archive_path = root / 'original-tests.zip'
                with zipfile.ZipFile(archive_path, 'w') as archive:
                    def put(name, raw):
                        entry = zipfile.ZipInfo(name); entry.create_system = 3
                        entry.external_attr = (build.stat.S_IFREG | 0o644) << 16
                        archive.writestr(entry, raw)
                    put('product-receipt.json', raw_receipt)
                    for name, raw in payloads.items():
                        put('outputs/' + name, b'bad' if changed == 'cache-bytes' and name.endswith('cache0.pcm') else raw)
                    for name, raw in temporary_files.items(): put('evidence/' + name, raw)
                    put('evidence/driver-jobs.stdout', stdout.encode()); put('evidence/driver-jobs.stderr', b'')
                    put('evidence/driver-jobs.exit.json', b'{"exitCode": 0}')
                    put('evidence/driver-jobs.argv.json', json.dumps(['swiftc', '-driver-print-jobs']
                        + (['--changed'] if changed == 'argv' else [])).encode())
                spec['nestedSHA256'] = build.capture.sha(archive_path)
                origin = {'selected': spec['selected'], 'artifact': {}}
                with patch.object(build, 'TESTS_PLAN_ORIGIN', spec), patch.object(build, 'product_archive', return_value=archive_path), \
                        patch.object(build, 'recipe_identity', return_value=spec['recipeSHA256']):
                    if changed != 'valid':
                        with self.assertRaises(ValueError): build.restore_tests_driver_plan(root, prepared, origin)
                    else:
                        plan = build.restore_tests_driver_plan(root, prepared, origin)
                        self.assertEqual(len(plan['cacheFiles']), 333)
                        self.assertEqual(len(plan['temporaryFiles']), 6)
                        self.assertEqual(plan['currentPlanningExecutions'], 0)
                        self.assertEqual(list(arena.iterdir()), [])
                        self.assertNotIn('ModuleCache.noindex/Session.modulevalidation', plan['cacheFiles'])
                        self.assertNotIn('ModuleCache.noindex/modules.timestamp', plan['cacheFiles'])

    def test_original_test_entry_materialization_preserves_full_source_and_rejects_role_path_or_byte_substitution(self):
        for changed in ('valid', 'module', 'cwd', 'signature', 'source-list', 'occupied', 'parent-link', 'retained-copy'):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve(); arena, folder = root / 'arena', root / 'evidence'
                arena.mkdir(); folder.mkdir()
                target = arena / 'Intermediates.noindex/NexGenVideo.build/Release/NexGenVideoTests-p.build/DerivedSources/test_entry_point.swift'
                guid = 'PACKAGE-PRODUCT:nexgenvideo_NexGenVideoTests.NexGenVideoTests'
                node = {'targetGUID': guid, 'output': str(target),
                    'argv': ['builtin-generateTestEntryPoint', '--output', str(target)], 'cwd': str(Path.cwd()),
                    'taskSignature': '60b01ab02c84a798dd3a2e1572c272a3',
                    'sourceFixture': 'scripts/fixtures/native-test-entry-point.json', 'sourceBytes': 17932,
                    'sourceSHA256': '7eba94b97a5454ac6bad83d7354eeef272610d96830aa07a06b607adf191af51'}
                plan = {'driver': {'module': 'NexGenVideoTests', 'targetGUID': guid},
                    'operations': {'arena': str(arena), 'testEntryPoint': node}}
                sources = [str(target)]
                if changed == 'module': plan['driver']['module'] = 'NexGenVideo'
                elif changed == 'cwd': node['cwd'] = '/driver/instead/of/original/workspace'
                elif changed == 'signature': node['taskSignature'] = 'different'
                elif changed == 'source-list': sources = ['/unreviewed/Test.swift']
                elif changed == 'occupied': target.parent.mkdir(parents=True); target.write_bytes(b'occupied')
                elif changed == 'parent-link':
                    outside = root / 'outside'; outside.mkdir(); (arena / 'Intermediates.noindex').symlink_to(outside)
                if changed == 'retained-copy':
                    with patch.object(build.shutil, 'copyfile', side_effect=lambda source, destination: destination.write_bytes(b'corrupt')), \
                            self.assertRaisesRegex(ValueError, 'Retained original'):
                        build.materialize_test_entry_point(folder, plan, sources)
                elif changed != 'valid':
                    with self.assertRaises(ValueError): build.materialize_test_entry_point(folder, plan, sources)
                    if changed == 'parent-link': self.assertEqual(list(outside.iterdir()), [])
                else:
                    proof = build.materialize_test_entry_point(folder, plan, sources)
                    self.assertEqual(proof['sha256'], node['sourceSHA256'])
                    self.assertEqual(proof['mode'], 0o644)
                    self.assertEqual(target.read_bytes(), (folder / 'test-entry-point.swift').read_bytes())
                    raw = target.read_text()
                    self.assertIn('public final class __SwiftPMXCTestObserver', raw)
                    self.assertIn('await Testing.__swiftPMEntryPoint() as Never', raw)
                    retained = json.loads((folder / 'test-entry-point.json').read_text())
                    self.assertFalse(retained['nativeOriginalGeneratorInvoked'])
                    self.assertFalse(retained['qualifiedAsTestExecution'])

    def test_printed_plan_role_is_pinned_and_mutually_exclusive_with_completed_or_partial_production(self):
        item = dict(build.DRIVER_INPUT_ORIGINS['production-plan']['selected'])
        self.assertEqual(build.resume_inputs(json.dumps({'production-plan': item})), {'production-plan': item})
        for role in ('production', 'production-cache'):
            with self.subTest(role=role), self.assertRaisesRegex(ValueError, 'Conflicting'):
                build.resume_inputs(json.dumps({'production-plan': item, role: item}))
        item['artifactID'] += 1
        with patch.object(build, 'api') as api, self.assertRaisesRegex(ValueError, 'Unqualified partial'):
            build.resumed_products({'production-plan': item}, {}, 'a' * 40)
        api.assert_not_called()

    def planning_fixture(self, root, changed='valid'):
        records = {}
        path = root / 'planning.zip'
        with zipfile.ZipFile(path, 'w') as archive:
            for index in range(6):
                name = 'tmp/TemporaryDirectory.pzfKPD/input' + str(index)
                if changed == 'namespace' and index == 0: name = 'tmp/TemporaryDirectory.foreign/input0'
                raw = ('payload' + str(index)).encode()
                records[name] = {'kind': 'file', 'sha256': build.hashlib.sha256(raw).hexdigest(), 'bytes': len(raw)}
                info = zipfile.ZipInfo('evidence/' + name); info.create_system = 3
                info.external_attr = (build.stat.S_IFREG | (0o600 if changed == 'mode' and index == 0 else 0o644)) << 16
                if changed == 'symlink' and index == 0: info.external_attr = (build.stat.S_IFLNK | 0o777) << 16
                archive.writestr(info, b'corrupt' if changed == 'bytes' and index == 0 else raw)
        return path, records

    def test_planning_inputs_measure_original_unix_modes_and_exact_six_file_namespace_after_restore(self):
        for changed in ('valid', 'mode', 'symlink', 'bytes', 'namespace', 'occupied', 'copy'):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temp:
                root = Path(temp).resolve(); archive_path, records = self.planning_fixture(root, changed)
                destination = root / 'restored'
                if changed == 'occupied':
                    target = destination / next(iter(records)); target.parent.mkdir(parents=True); target.write_text('occupied')
                with zipfile.ZipFile(archive_path) as archive:
                    if changed == 'copy':
                        with patch.object(build.shutil, 'copyfileobj', side_effect=lambda source, output, length: output.write(b'corrupt')), \
                                self.assertRaisesRegex(ValueError, 'Restored planning temporary'):
                            build.restore_planning_files(archive, records, destination)
                    elif changed != 'valid':
                        with self.assertRaises(ValueError):
                            build.restore_planning_files(archive, records, destination)
                    else:
                        result = build.restore_planning_files(archive, records, destination)
                        self.assertEqual(len(result), 6)
                        for name, item in result.items():
                            path = destination / name
                            self.assertEqual(item['mode'], 0o644)
                            self.assertEqual(item['sha256'], build.capture.sha(path))
                            self.assertEqual(item['bytes'], path.stat().st_size)

    def test_staged_printed_plan_rechecks_original_inputs_and_records_reuse_with_the_new_session(self):
        for changed in ('valid', 'source-bytes', 'source-mode', 'recipe', 'stdout'):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temp:
                root = Path(temp).resolve(); archive_path, records = self.planning_fixture(root)
                stored = root / 'stored'
                with zipfile.ZipFile(archive_path) as archive:
                    inputs = build.restore_planning_files(archive, records, stored)
                stdout = root / 'stdout'; stdout.write_text('original successful printed jobs\n')
                prepared = {'appSourceSHA': 'a' * 40, 'nativeSourceObjects': {}, 'compilerSHA256': 'b' * 64,
                    'plans': {'production': {'driver': {'argv': ['swiftc']}, 'operations': {'arena': str(root / 'arena')}}},
                    'clangBuildSessions': {'production': {'sessionTimestamp': 1234567890.5}}}
                planning = {'schema': 'native-app-retained-printed-driver-plan/v1',
                    'recipeSHA256': build.recipe_identity(prepared, 'production'),
                    'origin': {'selected': dict(build.DRIVER_INPUT_ORIGINS['production-plan']['selected'])},
                    'temporaryRoot': str(stored), 'temporaryFiles': inputs, 'stdoutPath': str(stdout),
                    'stdoutSHA256': build.capture.sha(stdout)}
                prepared['retainedProductionPlanning'] = planning
                victim = stored / next(iter(inputs))
                if changed == 'source-bytes': victim.write_bytes(b'changed')
                elif changed == 'source-mode': victim.chmod(0o600)
                elif changed == 'recipe': planning['recipeSHA256'] = 'f' * 64
                elif changed == 'stdout': stdout.write_text('changed')
                folder = root / 'production'; (folder / 'tmp').mkdir(parents=True)
                if changed != 'valid':
                    with self.assertRaises(ValueError): build.stage_printed_driver_plan(folder, prepared)
                else:
                    self.assertEqual(build.stage_printed_driver_plan(folder, prepared), stdout.read_text())
                    receipt = json.loads((folder / 'driver-jobs-reused.json').read_text())
                    self.assertEqual(receipt['currentPlanningExecutions'], 0)
                    self.assertEqual(receipt['originalPlanningExitCode'], 0)
                    self.assertEqual(receipt['newSession'], prepared['clangBuildSessions']['production'])
                    for name, item in inputs.items():
                        target = folder / name
                        self.assertEqual(build.capture.sha(target), item['sha256'])
                        self.assertEqual(build.stat.S_IMODE(target.stat().st_mode), item['mode'])

    def test_retained_production_plan_does_not_execute_another_print_jobs_command_or_change_other_roles(self):
        prepared = {'retainedProductionPlanning': {'origin': 'reviewed'}}
        driver = {'argv': ['swiftc', '-O'], 'cwd': '/workspace'}
        with patch.object(build, 'stage_printed_driver_plan', return_value='retained') as stage, \
                patch.object(build, 'logged', return_value='fresh') as logged:
            self.assertEqual(build.driver_planning_jobs(Path('/owned'), 'production', prepared, driver, {}), 'retained')
            logged.assert_not_called()
            stage.assert_called_once()
            self.assertEqual(build.driver_planning_jobs(Path('/owned'), 'testable', prepared, driver, {}), 'fresh')
            logged.assert_called_once_with(Path('/owned'), 'driver-jobs', ['swiftc', '-O', '-driver-print-jobs'], {}, '/workspace', 600)

    def session_plans(self, temporary):
        plans = {}
        for phase in ('production', 'testable', 'tests'):
            profile = 'production' if phase == 'production' else 'testable'
            arena = temporary / 'app-build-plan-evidence' / profile / 'derived-data'
            plans[phase] = {'operations': {'arena': str(arena)}, 'driver': {'argv': [
                'swiftc', '-clang-build-session-file', str(arena / 'ModuleCache.noindex/Session.modulevalidation')]}}
        return plans

    def test_real_clang_sessions_preserve_exact_driver_paths_new_job_time_and_primary_source_format(self):
        with tempfile.TemporaryDirectory() as temp:
            temporary = Path(temp); root = temporary / 'evidence'; root.mkdir()
            plans = self.session_plans(temporary)
            with patch.object(build.time, 'time', return_value=1234567890.25), \
                    patch.dict(build.os.environ, {'GITHUB_SHA': 'a' * 40, 'GITHUB_RUN_ID': '101'}):
                result = build.create_clang_sessions(root, plans, temporary)
            self.assertEqual(set(result), {'production', 'testable'})
            for profile, item in result.items():
                path = Path(item['path'])
                self.assertEqual(path.read_text(), '1234567890.25: Module build session file for module cache at ' + str(path.parent) + '\n')
                self.assertEqual(item['sha256'], build.capture.sha(path))
                self.assertEqual(item['mtimeNS'], path.stat().st_mtime_ns)
                self.assertEqual(item['sourceSHA'], 'a' * 40)
                self.assertEqual(item['runID'], 101)
                self.assertEqual(item['driverRoles'], ['production'] if profile == 'production' else ['testable', 'tests'])
            self.assertEqual(json.loads((root / 'clang-build-sessions.json').read_text()), result)
            with self.assertRaisesRegex(ValueError, 'occupied'):
                build.create_clang_sessions(root, plans, temporary)

    def test_missing_ambiguous_foreign_or_aliased_clang_session_inputs_fail_before_materialization(self):
        for changed in ('missing', 'duplicate', 'foreign', 'profile', 'arena'):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temp:
                temporary = Path(temp); root = temporary / 'evidence'; root.mkdir()
                plans = self.session_plans(temporary)
                if changed == 'missing': plans['production']['driver']['argv'].pop()
                elif changed == 'duplicate': plans['production']['driver']['argv'] += ['-clang-build-session-file', '/foreign']
                elif changed == 'foreign': plans['production']['driver']['argv'][-1] = str(temporary / 'foreign')
                elif changed == 'profile': plans['tests']['driver']['argv'][-1] = plans['production']['driver']['argv'][-1]
                else: plans['production']['operations']['arena'] = str(temporary / 'foreign')
                with self.assertRaises(ValueError):
                    build.create_clang_sessions(root, plans, temporary)
                self.assertFalse((temporary / 'app-build-plan-evidence').exists())
        with tempfile.TemporaryDirectory() as temp:
            temporary = Path(temp); root = temporary / 'evidence'; root.mkdir()
            plans = self.session_plans(temporary)
            path = Path(plans['testable']['driver']['argv'][-1]); path.parent.mkdir(parents=True)
            linked = temporary / 'linked'; linked.mkdir()
            path.symlink_to(linked / 'session')
            with self.assertRaisesRegex(ValueError, 'occupied|linked'):
                build.create_clang_sessions(root, plans, temporary)
            self.assertFalse(Path(plans['production']['driver']['argv'][-1]).exists())

    def test_product_archive_unwraps_only_the_actual_single_checkpoint_and_retains_original_bytes(self):
        inner = io.BytesIO()
        with zipfile.ZipFile(inner, 'w') as archive: archive.writestr('product-receipt.json', '{}')
        for members, accepted in [(['production-products.zip'], True),
                (['product-receipt.json'], False), (['production-products.zip', 'extra'], False)]:
            with self.subTest(members=members), tempfile.TemporaryDirectory() as temp:
                root = Path(temp); outer = io.BytesIO()
                with zipfile.ZipFile(outer, 'w') as archive:
                    for name in members: archive.writestr(name, inner.getvalue())
                raw = outer.getvalue()
                with patch.object(build, 'download', side_effect=lambda artifact, path: path.write_bytes(raw)):
                    if accepted:
                        path = build.product_archive(root, 'production', {})
                        self.assertEqual(path.read_bytes(), inner.getvalue())
                    else:
                        with self.assertRaisesRegex(ValueError, 'outer archive'):
                            build.product_archive(root, 'production', {})
                self.assertEqual((root / 'original.zip').read_bytes(), raw)

    def test_partial_cache_role_is_separate_and_cannot_override_a_successful_product_or_select_an_arbitrary_failure(self):
        item = {'runID': 11, 'sourceSHA': 'a' * 40, 'artifactID': 12,
            'artifactSHA256': 'b' * 64, 'receiptSHA256': 'c' * 64}
        self.assertEqual(build.resume_inputs(json.dumps({'production-cache': item})), {'production-cache': item})
        with self.assertRaisesRegex(ValueError, 'Conflicting'):
            build.resume_inputs(json.dumps({'production': item, 'production-cache': item}))
        with patch.object(build, 'api') as api, self.assertRaisesRegex(ValueError, 'Unqualified partial'):
            build.resumed_products({'production-cache': item}, {}, 'd' * 40)
        api.assert_not_called()

    def test_incomplete_cache_receipt_stays_rejected_by_the_existing_completed_product_restorer(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); arena = root / 'arena'; archive_path = root / 'partial.zip'
            selected = {'sourceSHA': 'a' * 40, 'runID': 101, 'receiptSHA256': ''}
            prepared = {'appSourceSHA': 'b' * 40, 'nativeSourceObjects': {}, 'compilerSHA256': 'c' * 64,
                'plans': {'production': {'driver': {'targetGUID': 'app', 'argv': ['swiftc', '-emit-module-path', str(arena / 'objects/App.swiftmodule')]},
                    'operations': {'arena': str(arena), 'copies': [], 'headers': [],
                        'links': [{'targetGUID': 'app', 'output': str(arena / 'Products/Release/NexGenVideo')}]}}}}
            receipt = {'schema': 'native-app-target-product/v1', 'phase': 'production', 'sourceSHA': selected['sourceSHA'],
                'runID': 101, 'attempt': 1, 'appSourceSHA': prepared['appSourceSHA'], 'nativeSourceObjects': {},
                'arena': str(arena), 'compilerSHA256': prepared['compilerSHA256'],
                'recipeSHA256': build.recipe_identity(prepared, 'production'),
                'state': {'compileComplete': False, 'linkComplete': False}}
            raw = json.dumps(receipt).encode(); selected['receiptSHA256'] = build.hashlib.sha256(raw).hexdigest()
            with zipfile.ZipFile(archive_path, 'w') as archive: archive.writestr('product-receipt.json', raw)
            with patch.object(build, 'product_archive', return_value=archive_path), self.assertRaisesRegex(ValueError, 'successful compilation'):
                build.restore_product(root, 'production', prepared, {'artifact': {}, 'selected': selected})

    def partial_cache_fixture(self, root, changed):
        arena = root / 'arena'; archive_path = root / 'original-fixture.zip'
        prepared = {'sourceSHA': 'd' * 40, 'appSourceSHA': 'b' * 40, 'nativeSourceObjects': {},
            'compilerSHA256': 'c' * 64,
            'plans': {'production': {'driver': {'argv': ['swiftc']}, 'operations': {'arena': str(arena)}}}}
        selected = {'sourceSHA': 'ce3f5dab418cb740159d9348d2cca4921ce81b04', 'runID': 42579228502}
        files = {}
        payloads = {}
        for index in range(114):
            name = ('ModuleCache.noindex/1U72Z291X4DNG/Module' + str(index) + '.pcm'
                if index < 108 else 'objects/failure-evidence' + str(index))
            if changed == 'path' and index == 0: name = 'ModuleCache.noindex/foreign/Module0.pcm'
            raw = b'CPCH' + str(index).encode() if index < 108 else b'auxiliary'
            if changed == 'magic' and index == 0: raw = b'NOPE'
            files[name] = {'kind': 'file', 'sha256': build.hashlib.sha256(raw).hexdigest(), 'bytes': len(raw), 'mode': 0o644}
            payloads[name] = raw + b'changed' if changed == 'bytes' and index == 0 else raw
        receipt = {'schema': 'native-app-target-product/v1', 'phase': 'production', 'sourceSHA': selected['sourceSHA'],
            'runID': selected['runID'], 'attempt': 1, 'appSourceSHA': prepared['appSourceSHA'],
            'nativeSourceObjects': {}, 'arena': str(arena), 'compilerSHA256': prepared['compilerSHA256'],
            'recipeSHA256': build.recipe_identity(prepared, 'production'), 'files': files,
            'state': {'compileComplete': False, 'linkComplete': False, 'compilerExecutions': 0, 'resumed': False}}
        if changed == 'recipe': receipt['recipeSHA256'] = 'f' * 64
        if changed == 'source': receipt['sourceSHA'] = 'f' * 40
        if changed == 'complete': receipt['state']['compileComplete'] = True
        raw = json.dumps(receipt).encode(); selected['receiptSHA256'] = build.hashlib.sha256(raw).hexdigest()
        with zipfile.ZipFile(archive_path, 'w') as archive:
            archive.writestr('product-receipt.json', raw)
            for name, payload in payloads.items(): archive.writestr('outputs/' + name, payload)
        return archive_path, prepared, {'artifact': {}, 'selected': selected}

    def test_actual_partial_restorer_measures_all_108_outputs_rejects_changed_inputs_and_rechecks_before_planning(self):
        for changed in ('valid', 'recipe', 'source', 'bytes', 'path', 'magic', 'complete', 'copy'):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temp:
                root = Path(temp).resolve()
                archive_path, prepared, origin = self.partial_cache_fixture(root, changed)
                actual_sha = build.capture.sha
                measured_sha = lambda path: ('399b9393316c96bda5d0f69af81dbf0e4fb5bad3596fa91d6644c5b8e148e6f1'
                    if path == archive_path else actual_sha(path))
                with patch.object(build, 'product_archive', return_value=archive_path), \
                        patch.object(build.capture, 'sha', side_effect=measured_sha):
                    if changed == 'copy':
                        with patch.object(build.shutil, 'copyfileobj', side_effect=lambda source, destination, length: destination.write(b'corrupt')), \
                                self.assertRaisesRegex(ValueError, 'Restored partial PCM'):
                            build.restore_partial_driver_cache(root, prepared, origin)
                    elif changed != 'valid':
                        with self.assertRaises(ValueError):
                            build.restore_partial_driver_cache(root, prepared, origin)
                    else:
                        result = build.restore_partial_driver_cache(root, prepared, origin)
                        self.assertEqual(len(result['restoredPCMCandidates']), 108)
                        self.assertFalse(result['successfulAppCompilationClaimed'])
                        self.assertTrue(result['currentCompilerValidationRequired'])
                        prepared['partialDriverCaches'] = result
                        with patch.dict(build.os.environ, {'GITHUB_RUN_ID': '202'}):
                            build.verify_partial_driver_cache(root, prepared)
                            before = json.loads((root / 'partial-driver-cache-before-planning.json').read_text())
                            self.assertEqual(before['actualFiles'], result['restoredPCMCandidates'])
                            victim = Path(prepared['plans']['production']['operations']['arena']) / next(iter(result['restoredPCMCandidates']))
                            victim.write_bytes(b'corrupted after restore')
                            with self.assertRaisesRegex(ValueError, 'changed before planning'):
                                build.verify_partial_driver_cache(root, prepared)

    def checkout_pins(self):
        return [{'identity': 'package' + str(i), 'kind': 'remoteSourceControl',
            'location': 'https://github.com/example/package' + str(i) + '.git',
            'state': {'revision': format(i + 1, '040x')}} for i in range(18)]

    def checkout_packages(self, scratch, workspace):
        names = ['Package0'] + ['package' + str(i) for i in range(1, 18)]
        return [{'packageKind': {'root': [str(workspace)]}}] + [
            {'packageKind': {'root': [str(scratch / 'checkouts' / name)]}} for name in names]

    def test_source_checkout_restore_never_resolves_or_downloads_binary_targets(self):
        for cache_status in (None, 0, 1, 'wrong-origin'):
            with self.subTest(cache_status=cache_status), tempfile.TemporaryDirectory() as temp:
                root = Path(temp); scratch = root / 'scratch'; cache = root / 'cache'
                cached = cache / 'repositories/package0-cached'
                if cache_status is not None: cached.mkdir(parents=True)
                calls = []
                def logged(folder, label, argv, environment, **options):
                    calls.append(argv)
                    if 'clone' in argv or 'init' in argv: Path(argv[-1]).mkdir()
                    return ''
                def cached_probe(argv, **options):
                    if 'config' in argv:
                        origin = 'https://github.com/another/package0.git' if cache_status == 'wrong-origin' else self.checkout_pins()[0]['location']
                        return build.subprocess.CompletedProcess(argv, 0, stdout=origin.encode())
                    return build.subprocess.CompletedProcess(argv, cache_status or 0)
                with patch.object(build, 'logged', side_effect=logged), patch.object(build.subprocess, 'run',
                        side_effect=cached_probe) as probe:
                    build.restore_checkouts(root, scratch, cache, self.checkout_pins(), {}, self.checkout_packages(scratch, root), root)
                clones = [argv for argv in calls if 'clone' in argv]
                self.assertEqual(len(clones), 1 if cache_status == 0 else 0)
                if clones: self.assertEqual(clones[0][-2], str(cached))
                self.assertTrue(all(argv[0] == 'git' for argv in calls))
                self.assertTrue(all('--no-checkout' in argv and '--no-hardlinks' in argv for argv in clones))
                initialized = [argv for argv in calls if 'init' in argv]
                fetched = [argv for argv in calls if 'fetch' in argv]
                self.assertEqual(len(initialized), 18 - len(clones))
                self.assertEqual(len(fetched), 18 - len(clones))
                expected = {pin['identity']: pin for pin in self.checkout_pins()}
                for argv in fetched:
                    identity = Path(argv[argv.index('-C') + 1]).name.lower()
                    self.assertEqual(argv[-2:], ['origin', expected[identity]['state']['revision']])
                    self.assertTrue(all(flag in argv for flag in ('--depth=1', '--no-tags', '--no-recurse-submodules')))
                    origin = next(command for command in calls if 'add' in command
                        and command[command.index('-C') + 1] == argv[argv.index('-C') + 1])
                    self.assertEqual(origin[-2:], ['origin', expected[identity]['location']])
                detached = [argv[-1] for argv in calls if 'checkout' in argv and '--detach' in argv]
                self.assertEqual(detached, [pin['state']['revision'] for pin in self.checkout_pins()])
                self.assertEqual(sorted(p.name for p in (scratch / 'checkouts').iterdir()),
                    sorted(Path(package['packageKind']['root'][0]).name for package in self.checkout_packages(scratch, root)[1:]))
                self.assertEqual(probe.call_count, 0 if cache_status is None else 1 if cache_status == 'wrong-origin' else 2)
                receipt = json.loads((root / 'restored-source-checkouts.json').read_text())
                self.assertEqual(receipt['checkouts'][0]['originalCacheOrigin'], self.checkout_pins()[0]['location'] if cache_status == 0 else None)

    def test_source_checkout_pin_fetch_failure_stops_before_checkout_or_later_dependencies(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); scratch = root / 'scratch'; calls = []
            error = build.subprocess.TimeoutExpired(['git', 'fetch'], 180)
            def logged(folder, label, argv, environment, **options):
                calls.append((label, argv))
                if 'init' in argv: Path(argv[-1]).mkdir()
                if 'fetch' in argv: raise error
                return ''
            with patch.object(build, 'logged', side_effect=logged):
                with self.assertRaises(build.subprocess.TimeoutExpired) as raised:
                    build.restore_checkouts(root, scratch, root / 'cache', self.checkout_pins(), {},
                        self.checkout_packages(scratch, root), root)
            self.assertIs(raised.exception, error)
            self.assertEqual([label for label, _ in calls], ['package0-initialize-source',
                'package0-canonical-origin', 'package0-fetch-source-pin'])
            self.assertFalse((root / 'restored-source-checkouts.json').exists())
            self.assertFalse((scratch / 'checkouts/package1').exists())

    def test_pinned_source_transport_preserves_exact_commit_tree_and_primary_failure(self):
        pin = {'identity': 'onnxruntime-swift-package-manager',
            'location': 'https://github.com/microsoft/onnxruntime-swift-package-manager',
            'state': {'revision': 'b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2'}}
        for primary_ok in (True, False):
            with self.subTest(primary_ok=primary_ok), tempfile.TemporaryDirectory() as temp:
                root = Path(temp); calls = []; original = copy.deepcopy(pin)
                def logged(folder, label, argv, environment, **options):
                    calls.append((label, argv, options))
                    if label.endswith('-fetch-source-pin') and not primary_ok:
                        (root / (label + '.exit.json')).write_text(json.dumps({'exitCode': 128, 'ownedProcessGroupAbsent': True}))
                        raise ValueError('Canonical origin unavailable')
                    return '59178cede37305e8725fd09d5907d872a55004f1\n' if 'rev-parse' in argv else ''
                with patch.object(build, 'logged', side_effect=logged):
                    receipt = build.fetch_pinned_source(root, ['git'], root / 'checkout', pin, {})
                self.assertEqual(pin, original)
                fetches = [argv for _, argv, _ in calls if 'fetch' in argv]
                self.assertEqual(fetches[0][-2:], ['origin', pin['state']['revision']])
                self.assertTrue(all(all(flag in argv for flag in ('--depth=1', '--no-tags', '--no-recurse-submodules'))
                    for argv in fetches))
                self.assertTrue(all(options.get('timeout') == 180 for _, argv, options in calls
                    if 'fetch' in argv or 'fsck' in argv))
                if primary_ok:
                    self.assertEqual(receipt, {'kind': 'canonical', 'url': pin['location']})
                    self.assertEqual(len(calls), 1)
                else:
                    self.assertEqual(fetches[1][-2:],
                        ['https://github.com/notahotel/onnxruntime-swift-package-manager.git', pin['state']['revision']])
                    self.assertEqual(receipt['treeGitObject'], '59178cede37305e8725fd09d5907d872a55004f1')
                    self.assertEqual(json.loads((root / receipt['primaryFailureReceipt']).read_text()),
                        {'exitCode': 128, 'ownedProcessGroupAbsent': True})
                    self.assertEqual([argv[-4:] for _, argv, _ in calls if 'fsck' in argv],
                        [['fsck', '--full', '--strict', pin['state']['revision']]])

    def test_pinned_source_transport_refuses_changed_pin_unsafe_cleanup_and_wrong_tree(self):
        for changed in ('identity', 'origin', 'revision', 'success-receipt', 'missing-cleanup', 'unsafe-cleanup', 'tree', 'fsck'):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temp:
                root = Path(temp); calls = []
                pin = {'identity': 'onnxruntime-swift-package-manager',
                    'location': 'https://github.com/microsoft/onnxruntime-swift-package-manager',
                    'state': {'revision': 'b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2'}}
                if changed == 'identity': pin['identity'] = 'another-package'
                elif changed == 'origin': pin['location'] = 'https://github.com/another/onnxruntime-swift-package-manager'
                elif changed == 'revision': pin['state']['revision'] = '1' * 40
                primary_error = ValueError('Canonical origin unavailable')
                def logged(folder, label, argv, environment, **options):
                    calls.append(argv)
                    if label.endswith('-fetch-source-pin'):
                        failure = {'exitCode': 0 if changed == 'success-receipt' else 128, 'ownedProcessGroupAbsent': True}
                        if changed == 'missing-cleanup': failure.pop('ownedProcessGroupAbsent')
                        if changed == 'unsafe-cleanup': failure.update(interrupted=True, ownedProcessGroupAbsent=False)
                        (root / (label + '.exit.json')).write_text(json.dumps(failure))
                        raise primary_error
                    if 'fsck' in argv and changed == 'fsck': raise ValueError('Corrupt source objects')
                    return '0' * 40 if 'rev-parse' in argv else ''
                with patch.object(build, 'logged', side_effect=logged), self.assertRaises(ValueError) as raised:
                    build.fetch_pinned_source(root, ['git'], root / 'checkout', pin, {})
                if changed in {'identity', 'origin', 'revision'}:
                    self.assertIs(raised.exception, primary_error)
                self.assertEqual(len([argv for argv in calls if 'fetch' in argv]),
                    2 if changed in {'tree', 'fsck'} else 1)
                self.assertFalse(any('checkout' in argv for argv in calls))

    def test_source_checkout_git_isolation_covers_cached_and_remote_paths_without_mutating_compiler_environment(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); scratch = root / 'scratch'; cache = root / 'cache'
            (cache / 'repositories/package0-cached').mkdir(parents=True)
            parent = {'HOME': str(root), 'PATH': '/fixture/tools', 'GIT_ASKPASS': '/untrusted',
                'GIT_CONFIG_COUNT': '1', 'GIT_CONFIG_KEY_0': 'url.rewrite', 'GIT_CONFIG_VALUE_0': 'untrusted',
                'GH_TOKEN': 'fixture-only', 'GITHUB_TOKEN': 'fixture-only', 'SSH_AUTH_SOCK': '/untrusted'}
            original = dict(parent); observed = []
            def logged(folder, label, argv, environment, **options):
                observed.append(environment)
                if 'clone' in argv or 'init' in argv: Path(argv[-1]).mkdir()
                self.assertIn('credential.helper=', argv)
                return ''
            def probe(argv, **options):
                observed.append(options['env'])
                return build.subprocess.CompletedProcess(argv, 0,
                    stdout=self.checkout_pins()[0]['location'].encode() if 'config' in argv else b'')
            with patch.object(build, 'logged', side_effect=logged), patch.object(build.subprocess, 'run', side_effect=probe):
                build.restore_checkouts(root, scratch, cache, self.checkout_pins(), parent,
                    self.checkout_packages(scratch, root), root)
            self.assertEqual(parent, original)
            self.assertGreater(len(observed), 18)
            for environment in observed:
                self.assertEqual(environment, {'HOME': str(root), 'PATH': '/fixture/tools',
                    'GIT_TERMINAL_PROMPT': '0', 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': os.devnull})

    def test_logged_failures_reap_term_ignoring_descendants_and_preserve_original_evidence(self):
        for mode in ('timeout', 'nonzero'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temp:
                root = Path(temp); parent_file = root / 'parent.pid'; child_file = root / 'child.pid'
                child = ('import os,signal,time;from pathlib import Path;'
                    'signal.signal(signal.SIGTERM,signal.SIG_IGN);'
                    'Path(' + repr(str(child_file)) + ').write_text(str(os.getpid()));time.sleep(60)')
                parent = ('import os,subprocess,sys,time;from pathlib import Path;'
                    'Path(' + repr(str(parent_file)) + ').write_text(str(os.getpid()));'
                    'subprocess.Popen([sys.executable,"-c",' + repr(child) + '])\n'
                    'while not Path(' + repr(str(child_file)) + ').exists(): time.sleep(0.01)\n'
                    + ('sys.exit(128)' if mode == 'nonzero' else 'time.sleep(60)'))
                environment = {'HOME': str(root), 'CFFIXED_USER_HOME': str(root), 'PATH': os.environ.get('PATH', '')}
                group = None
                try:
                    expected = build.subprocess.TimeoutExpired if mode == 'timeout' else ValueError
                    with self.assertRaises(expected) as raised:
                        build.logged(root, 'failed-family', [build.sys.executable, '-c', parent], environment, timeout=2)
                    group = int(parent_file.read_text())
                    self.assertTrue(child_file.is_file())
                    with self.assertRaises(ProcessLookupError): os.killpg(group, 0)
                    receipt = json.loads((root / 'failed-family.exit.json').read_text())
                    self.assertTrue(receipt['ownedProcessGroupAbsent'])
                    self.assertEqual(receipt['ownedProcessGroupID'], group)
                    if mode == 'timeout':
                        self.assertEqual(raised.exception.timeout, 2)
                        self.assertTrue(receipt['timedOut'])
                        self.assertEqual(receipt['exceptionType'], 'TimeoutExpired')
                    else:
                        self.assertEqual(receipt['exitCode'], 128)
                        self.assertFalse(receipt.get('timedOut', False))
                    self.assertTrue((root / 'failed-family.stdout').is_file())
                    self.assertTrue((root / 'failed-family.stderr').is_file())
                finally:
                    if group is None and parent_file.exists(): group = int(parent_file.read_text())
                    if group is not None:
                        try: os.killpg(group, build.signal.SIGKILL)
                        except ProcessLookupError: pass

    def test_cleanup_waits_for_absence_after_a_denied_group_probe(self):
        process = Mock(pid=12345)
        for final_probe in (ProcessLookupError(), PermissionError()):
            with self.subTest(final_probe=type(final_probe).__name__), \
                    patch.object(os, 'killpg', side_effect=[None, None, PermissionError(), final_probe]) as signal_group, \
                    patch.object(build.time, 'monotonic', side_effect=[0, 1, 11]), patch.object(build.time, 'sleep') as pause:
                if isinstance(final_probe, PermissionError):
                    with self.assertRaisesRegex(RuntimeError, 'process group did not terminate'):
                        build.stop_logged_process(process)
                else:
                    build.stop_logged_process(process)
                self.assertEqual(signal_group.call_args_list, [call(process.pid, build.signal.SIGTERM),
                    call(process.pid, build.signal.SIGKILL), call(process.pid, 0), call(process.pid, 0)])
                pause.assert_called_once_with(0.05)

    def test_logged_interruption_records_cleanup_failure_without_claiming_a_safe_group(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            process = build.subprocess.CompletedProcess(['fixture'], -15)
            process.pid = 12345
            process.wait = lambda **options: (_ for _ in ()).throw(build.subprocess.TimeoutExpired(['fixture'], 1))
            process.poll = lambda: -15
            with patch.object(build.subprocess, 'Popen', return_value=process), \
                    patch.object(build, 'stop_logged_process', side_effect=RuntimeError('Group survives')), \
                    self.assertRaisesRegex(RuntimeError, 'cleanup failed'):
                build.logged(root, 'unsafe-family', ['fixture'], {}, timeout=1)
            receipt = json.loads((root / 'unsafe-family.exit.json').read_text())
            self.assertFalse(receipt['ownedProcessGroupAbsent'])
            self.assertTrue(receipt['timedOut'])
            self.assertEqual(receipt['exitCode'], -15)

    def test_source_checkout_restore_rejects_ambiguous_paths_origins_and_unpinned_revisions_before_any_git(self):
        for field, value in [('identity', '../escape'), ('identity', 'package1'), ('kind', 'binaryTarget'),
                ('location', 'http://github.com/example/package0.git'), ('location', 'https://user@github.com/example/package0'),
                ('location', 'https://github.com/../package0'), ('state', {'revision': 'main'}), ('state', None)]:
            with self.subTest(field=field, value=value), tempfile.TemporaryDirectory() as temp:
                root = Path(temp); pins = self.checkout_pins(); pins[0][field] = value
                with patch.object(build, 'logged') as logged, patch.object(build.subprocess, 'run') as probe, self.assertRaises(ValueError):
                    build.restore_checkouts(root, root / 'scratch', root / 'cache', pins, {},
                        self.checkout_packages(root / 'scratch', root), root)
                logged.assert_not_called(); probe.assert_not_called()
                self.assertFalse((root / 'scratch').exists())

    def test_qualified_checkout_spelling_and_strict_header_roots_are_preserved_without_aliases(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); scratch = root / 'scratch'; packages = self.checkout_packages(scratch, root)
            identities = {pin['identity'] for pin in self.checkout_pins()}
            locations = build.checkout_locations(packages, identities, scratch, root)
            self.assertEqual(locations['package0'], scratch / 'checkouts/Package0')
            self.assertNotEqual(str(locations['package0']), str(scratch / 'checkouts/package0'))
            for changed in ('missing', 'nested', 'duplicate', 'foreign', 'root', 'parent-alias', 'backslash', 'nul'):
                broken = copy.deepcopy(packages)
                if changed == 'missing': broken.pop()
                elif changed == 'nested': broken[1]['packageKind']['root'][0] += '/nested'
                elif changed == 'duplicate': broken[2]['packageKind']['root'] = [str(scratch / 'checkouts/package0')]
                elif changed == 'foreign': broken[1]['packageKind']['root'] = [str(root / 'foreign/Package0')]
                elif changed == 'root': broken[0]['packageKind']['root'] = [str(root / 'other')]
                elif changed == 'parent-alias': broken[1]['packageKind']['root'] = [str(scratch) + '/checkouts/../Package0']
                elif changed == 'backslash': broken[1]['packageKind']['root'] = [str(scratch / 'checkouts/Package0') + '\\alias']
                else: broken[1]['packageKind']['root'] = [str(scratch / 'checkouts/Package0') + '\0alias']
                with self.subTest(changed=changed), self.assertRaises(ValueError):
                    build.checkout_locations(broken, identities, scratch, root)

    def inputs(self):
        identifier, digest, _ = build.retained.ARTIFACTS['runtime']
        return {'KIND': 'native-app-targets', 'SCALE': '1', 'PRODUCER_RUN': '101', 'PRODUCER_SHA': 'a' * 40,
            'DIAGNOSTIC_ID': '201', 'DIAGNOSTIC_DIGEST': 'b' * 64, 'PRODUCT_SHA': 'c' * 40,
            'VERIFIED_PR': '301', 'FAILURE_ID': '401', 'FAILURE_DIGEST': 'd' * 64,
            'PRODUCTS_ID': str(identifier), 'PRODUCTS_DIGEST': digest}

    def test_compiler_role_requires_all_source_metadata_and_exact_retained_bank_selectors(self):
        selected = build.validate_inputs(self.inputs())
        self.assertEqual(selected['app']['appSourceSHA'], 'c' * 40)
        self.assertEqual(selected['metadata']['artifactID'], 401)
        self.assertEqual(selected['resume'], {})
        for key in self.inputs():
            changed = self.inputs(); changed[key] = ''
            with self.subTest(missing=key), self.assertRaises(ValueError): build.validate_inputs(changed)
        for key in ('DMG_DIGEST', 'JOURNEY_JOB', 'PACKAGING_PRODUCER_SOURCE'):
            changed = self.inputs(); changed[key] = 'unexpected'
            with self.subTest(unrelated=key), self.assertRaises(ValueError): build.validate_inputs(changed)
        changed = self.inputs(); changed['PRODUCTS_ID'] = '999'
        with self.assertRaises(ValueError): build.validate_inputs(changed)

    def test_aliases_cannot_hide_different_app_metadata_or_compiler_bank_inputs(self):
        for original, alias in [('KIND', 'REPLAY_KIND'), ('PRODUCT_SHA', 'EXTRA_SOURCE'),
                ('FAILURE_ID', 'EXTRA_FAILURE'), ('FAILURE_DIGEST', 'EXTRA_FAILURE_SHA'),
                ('PRODUCTS_ID', 'EXTRA_PRODUCTS'), ('PRODUCTS_DIGEST', 'EXTRA_PRODUCTS_SHA')]:
            changed = self.inputs(); changed[alias] = changed[original]
            build.validate_inputs(changed)
            changed[alias] = 'conflict'
            with self.subTest(alias=alias), self.assertRaises(ValueError): build.validate_inputs(changed)
            changed[alias] = False
            with self.subTest(nonstring=alias), self.assertRaises(ValueError): build.validate_inputs(changed)

    def test_resume_requires_exact_known_roles_complete_producer_identity_and_no_duplicate_json_fields(self):
        item = {'runID': 11, 'sourceSHA': 'a' * 40, 'artifactID': 12,
            'artifactSHA256': 'b' * 64, 'receiptSHA256': 'c' * 64}
        self.assertEqual(build.resume_inputs(json.dumps({'production': item})), {'production': item})
        for key in item:
            changed = dict(item); changed.pop(key)
            with self.subTest(missing=key), self.assertRaises(ValueError): build.resume_inputs(json.dumps({'production': changed}))
        for key, value in [('runID', True), ('artifactID', 0), ('sourceSHA', None), ('artifactSHA256', 'bad')]:
            changed = dict(item); changed[key] = value
            with self.subTest(field=key), self.assertRaises(ValueError): build.resume_inputs(json.dumps({'production': changed}))
        with self.assertRaises(ValueError): build.resume_inputs(json.dumps({'engine': item}))
        with self.assertRaises(ValueError): build.resume_inputs('{"production":{},"production":{}}')

    def test_native_guard_rejects_non_actions_wrong_job_or_non_arm64_without_running_commands(self):
        values = {'RUNNER_TEMP': '/owned', 'GITHUB_REPOSITORY': 'iret77/nexgenvideo', 'GITHUB_ACTIONS': 'true',
            'GITHUB_RUN_ATTEMPT': '1', 'GITHUB_JOB': 'app-target-build', 'REPLAY_KIND': 'native-app-targets'}
        with patch.dict(os.environ, values, clear=True), patch.object(build.sys, 'platform', 'linux'), patch.object(build.platform, 'machine', return_value='arm64'):
            with self.assertRaises(ValueError): build.native_guard(Path('/owned/app-target-build'))
        for key, value in [('GITHUB_JOB', 'source'), ('GITHUB_RUN_ATTEMPT', '2'), ('GITHUB_REPOSITORY', 'other/repository')]:
            changed = dict(values); changed[key] = value
            with self.subTest(key=key), patch.dict(os.environ, changed, clear=True), patch.object(build.sys, 'platform', 'darwin'), patch.object(build.platform, 'machine', return_value='arm64'):
                with self.assertRaises(ValueError): build.native_guard(Path('/owned/app-target-build'))

    def test_product_recipe_identity_changes_with_native_inputs_or_arguments_but_not_ci_only_source(self):
        prepared = {'plans': {'production': {'driver': {'argv': ['compiler', '-O']}, 'operations': {'arena': '/owned'}}},
            'nativeSourceObjects': {'Sources': 'a'}, 'appSourceSHA': 'b', 'compilerSHA256': 'c', 'sourceSHA': 'first-ci'}
        original = build.recipe_identity(prepared, 'production')
        changed = copy.deepcopy(prepared); changed['sourceSHA'] = 'second-ci'
        self.assertEqual(build.recipe_identity(changed, 'production'), original)
        for field in ('argv', 'source', 'compiler'):
            changed = copy.deepcopy(prepared)
            if field == 'argv': changed['plans']['production']['driver']['argv'].append('-different')
            elif field == 'source': changed['nativeSourceObjects']['Sources'] = 'changed'
            else: changed['compilerSHA256'] = 'changed'
            with self.subTest(field=field): self.assertNotEqual(build.recipe_identity(changed, 'production'), original)

    def test_clang_header_ingress_uses_the_actual_pinned_root_instead_of_a_checkout_path_segment(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); package = root / 'pinned/package'; headers = package / 'Sources/C/include'
            headers.mkdir(parents=True); workspace = root / 'repository'; workspace.mkdir()
            arena = root / 'arena'
            plan = {'driver': {'argv': ['compiler', '-Xcc', '-I' + str(headers)]}, 'operations': {'arena': str(arena)}}
            with patch.object(build.retained, 'header_inputs', return_value={'Sources/C/include/public.h': 'a' * 64}) as bind:
                found = build.pinned_header_inputs({'production': plan}, [package], workspace)
                self.assertEqual(found, {str(headers / 'public.h'): 'a' * 64})
                bind.assert_called_once_with(package.resolve(), headers.parent, headers)
            altered = copy.deepcopy(plan); altered['driver']['argv'][-1] = '-I' + str(root / 'outside/checkouts/package/include')
            with patch.object(build.retained, 'header_inputs') as bind, self.assertRaises(ValueError):
                build.pinned_header_inputs({'production': altered}, [package], workspace)
            bind.assert_not_called()
