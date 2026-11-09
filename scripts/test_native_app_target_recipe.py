import copy
import json
from pathlib import Path
import tempfile
import unittest

import native_app_target_recipe as recipe


def wire(value):
    if value is None: return b'\xc0'
    if type(value) is bool: return b'\xc3' if value else b'\xc2'
    if type(value) is int:
        if 0 <= value < 128: return bytes([value])
        return b'\xd3' + value.to_bytes(8, 'big', signed=True)
    if isinstance(value, bytes): return b'\xc6' + len(value).to_bytes(4, 'big') + value
    if isinstance(value, str):
        raw = value.encode(); return b'\xdb' + len(raw).to_bytes(4, 'big') + raw
    if isinstance(value, list): return b'\xdd' + len(value).to_bytes(4, 'big') + b''.join(wire(item) for item in value)
    raise TypeError(type(value).__name__)


class NativeAppTargetRecipeTests(unittest.TestCase):
    def test_sdk_default_alias_must_resolve_to_the_same_directory_in_both_physical_layouts(self):
        for default_is_link in (True, False):
            with self.subTest(default_is_link=default_is_link), tempfile.TemporaryDirectory() as temp:
                root = Path(temp).resolve(); sdk = root / 'MacOSX27.2.sdk'; alias = root / 'MacOSX.sdk'
                real, link = (sdk, alias) if default_is_link else (alias, sdk)
                real.mkdir(); link.symlink_to(real.name, target_is_directory=True)
                module = real / 'module.modulemap'; module.write_text('module ExactSDK {}')
                bindings = {}
                self.assertTrue(recipe.sdk_interface_input(recipe.canonical_path(str(alias / module.name)),
                    recipe.canonical_path(str(sdk)), bindings))
                item = bindings[str(alias / module.name)]
                self.assertEqual(item['resolvedSDK'], str(real))
                self.assertEqual(item['resolvedPath'], str(module))
                self.assertEqual(item['sha256'], recipe.hashlib.sha256(module.read_bytes()).hexdigest())
                self.assertEqual((item['device'], item['inode']), (real.stat().st_dev, real.stat().st_ino))

    def test_sdk_alias_does_not_admit_foreign_sdks_arbitrary_aliases_or_escaping_interface_links(self):
        for changed in ('different-sdk', 'missing', 'other-alias', 'escaping-interface'):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temp:
                root = Path(temp).resolve(); sdk = root / 'MacOSX27.2.sdk'; sdk.mkdir()
                foreign = root / 'Foreign.sdk'; foreign.mkdir(); (foreign / 'module.modulemap').write_text('foreign')
                alias = root / 'MacOSX.sdk'
                if changed == 'missing': pass
                elif changed == 'different-sdk': alias.symlink_to(foreign.name, target_is_directory=True)
                elif changed == 'other-alias':
                    alias = root / 'Unbound.sdk'; alias.symlink_to(sdk.name, target_is_directory=True)
                else:
                    alias.symlink_to(sdk.name, target_is_directory=True)
                    (sdk / 'module.modulemap').symlink_to(foreign / 'module.modulemap')
                arguments = (recipe.canonical_path(str(alias / 'module.modulemap')), recipe.canonical_path(str(sdk)), {})
                if changed == 'other-alias':
                    self.assertFalse(recipe.sdk_interface_input(*arguments))
                else:
                    with self.assertRaises((ValueError, FileNotFoundError)):
                        recipe.sdk_interface_input(*arguments)

    def test_swiftbuild_uint8_discriminator_consumes_its_payload_instead_of_a_negative_fixint(self):
        reader = recipe.TaskStoreReader(b'\x93\xe0\xff\xc3\x92\xa1x\xc4\x01y')
        self.assertEqual(reader.value(), [255, True, ['x', b'y']])
        self.assertEqual(reader.offset, len(reader.raw))
        for raw in (b'\xe0', b'\xc6\x00\x00\x10\x00short', b'\xc1'):
            with self.subTest(raw=raw), self.assertRaises(ValueError): recipe.TaskStoreReader(raw).value()

    def test_complete_task_array_rejects_trailing_bytes_and_unknown_layout(self):
        task = [None] * 25
        self.assertEqual(recipe.TaskStoreReader(wire([task])).tasks(), [task])
        for raw in (wire([task]) + b'\xc0', wire([[None] * 24]), wire([])):
            with self.subTest(raw=raw[:8]), self.assertRaises(ValueError): recipe.TaskStoreReader(raw).tasks()

    def test_target_and_build_parameter_references_require_prior_integer_definitions(self):
        first = [None] * 25; first[3] = [0, ['PACKAGE-TARGET:App', False, 0, b'{"configuration":"Release"}']]
        second = [None] * 25; second[3] = [1, 0]
        third = [None] * 25; third[3] = [0, ['PACKAGE-TARGET:Tests', False, 1, 0]]
        records = recipe.configured_tasks([first, second, third])
        self.assertEqual(records[0][0], records[1][0])
        self.assertEqual(records[2][0]['parameters'], {'configuration': 'Release'})
        for bad in ([1, 0], [True, 0], [False, first[3][1]], [0, ['GUID', False, True, 0]],
                [0, ['GUID', False, 1, 0]], [0, ['GUID', False, 0, b'[]']]):
            task = [None] * 25; task[3] = bad
            with self.subTest(reference=bad), self.assertRaises(ValueError): recipe.configured_tasks([task])

    def test_typed_arguments_and_environment_do_not_silently_coerce_other_wire_kinds(self):
        self.assertEqual(recipe.arguments([[0, b'-sdk'], [1, '/SDK']]), ['-sdk', '/SDK'])
        for value in ([[True, b'x']], [[0, 'x']], [[2, '/parent']], [[0, b'nul\0']]):
            with self.subTest(value=value), self.assertRaises(ValueError): recipe.arguments(value)
        task = [None] * 25; task[8] = [['PATH'], ['/tools']]
        self.assertEqual(recipe.environment(task, {'PATH'}), {'PATH': '/tools'})
        with self.assertRaises(ValueError): recipe.environment(task)
        task[8] = [['PATH', 'PATH'], ['/one', '/two']]
        with self.assertRaises(ValueError): recipe.environment(task, {'PATH'})

    def test_arm64_header_merge_preserves_the_actual_backend_single_flag_and_wrapper_bytes(self):
        raw = b'header\n'
        self.assertEqual(recipe.generated_header(raw, True), raw)
        self.assertEqual(recipe.generated_header(raw, False),
            b'#if 0\n#elif defined(__arm64__) && __arm64__\nheader\n\n#else\n#error unsupported Swift architecture\n#endif\n')
        with self.assertRaises(ValueError): recipe.generated_header(raw, 1)

    def test_native_paths_cannot_use_parent_traversal_or_relative_aliases(self):
        self.assertEqual(str(recipe.canonical_path('/owned/a')), '/owned/a')
        for path in ('owned/a', '/owned/../outside', '/owned//alias', '/owned/nul\0'):
            with self.subTest(path=path), self.assertRaises(ValueError): recipe.canonical_path(path)

    def test_backend_copy_scan_marker_is_bound_to_the_actual_rule_not_used_as_a_filename(self):
        rule = ['Copy', '/arena/output.swiftmodule', '/arena/input.swiftmodule']
        self.assertEqual(recipe.copy_paths(rule, ['/arena/input.swiftmodule/'], ['/arena/output.swiftmodule']),
            ('/arena/input.swiftmodule', '/arena/output.swiftmodule'))
        for source in ('/arena/input.swiftmodule', '/arena/input.swiftmodule//', '/other/input.swiftmodule/'):
            with self.subTest(source=source), self.assertRaises(ValueError): recipe.copy_paths(rule, [source], [rule[1]])
        with self.assertRaises(ValueError): recipe.copy_paths(rule, [rule[2] + '/'], ['/other/output'])

    def test_auxiliary_response_logging_boolean_does_not_change_its_exact_file_bytes_or_weaken_other_modes(self):
        for logging in (False, True):
            action = [1, ['/arena/args.resp', '/arena/attachments/actual', None, False, [], logging, [b'signature']]]
            context = recipe.auxiliary_context(action)
            self.assertEqual(context, {'output': '/arena/args.resp', 'input': '/arena/attachments/actual', 'logContents': logging})
            for index, value in ((2, 0o755), (3, True), (4, ['diagnostic']), (5, 1)):
                broken = copy.deepcopy(action); broken[1][index] = value
                with self.subTest(field=index, logging=logging), self.assertRaises(ValueError): recipe.auxiliary_context(broken)

    def test_frontend_graph_must_compile_every_exact_source_and_no_retained_package_sources(self):
        driver = {'argv': ['/tools/swiftc', '-sdk', '/SDK'], 'module': 'App'}
        valid = '/tools/swift-frontend -frontend -c /source/App.swift -module-name App -o /arena/App.o'
        proof = recipe.validate_frontend_jobs(valid, driver, ['/source/App.swift'], '/arena', '/source', '/tmp/owned')
        self.assertEqual(proof['moduleSourceCount'], 1)
        for text in (valid.replace('/source/App.swift', '/source/Engine/Sources/Engine.swift'),
                valid.replace('-module-name App', '-module-name Engine'), valid.replace('/arena/App.o', '/outside/App.o'),
                valid.replace('/tools/swift-frontend', '/outside/swift-frontend')):
            with self.subTest(text=text), self.assertRaises(ValueError):
                recipe.validate_frontend_jobs(text, driver, ['/source/App.swift'], '/arena', '/source', '/tmp/owned')
        with self.assertRaises(ValueError):
            recipe.validate_frontend_jobs(valid, driver, ['/source/App.swift', '/source/Missing.swift'], '/arena', '/source', '/tmp/owned')
        injected = '/tools/clang -emit-pcm /outside/checkouts/package/public.modulemap -o /arena/foreign.pcm\n' + valid
        with self.assertRaises(ValueError):
            recipe.validate_frontend_jobs(injected, driver, ['/source/App.swift'], '/arena', '/source', '/tmp/owned')

    def test_frontend_response_and_file_lists_are_bounded_to_the_owned_job(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); arena = root / 'arena'; temporary = root / 'tmp'
            arena.mkdir(); temporary.mkdir()
            source_list = arena / 'sources'; source_list.write_text('/source/App.swift\n')
            response = temporary / 'args'; response.write_text('-frontend -c -filelist ' + str(source_list) +
                ' -module-name App -o ' + str(arena / 'App.o'))
            driver = {'argv': ['/tools/swiftc', '-sdk', '/SDK'], 'module': 'App'}
            command = '/tools/swift-frontend @' + str(response)
            proof = recipe.validate_frontend_jobs(command, driver, ['/source/App.swift'], str(arena), '/source', str(temporary))
            self.assertEqual(len(proof['consumedInputs']), 2)
            self.assertTrue(all(item['sha256'] and item['bytes'] for item in proof['consumedInputs']))
            self.assertIn('/source/App.swift', proof['expandedJobs'][0])
            response.write_text('@' + str(response))
            with self.assertRaises(ValueError):
                recipe.validate_frontend_jobs(command, driver, ['/source/App.swift'], str(arena), '/source', str(temporary))
            outside = root / 'outside'; outside.write_text('/source/App.swift')
            with self.assertRaises(ValueError):
                recipe.validate_frontend_jobs('/tools/swift-frontend @' + str(outside), driver,
                    ['/source/App.swift'], str(arena), '/source', str(temporary))

    def driver_fixture(self, directory):
        folder = directory / 'production'; folder.mkdir()
        identifier = 'a' * 32
        data = folder / 'derived-data/Intermediates.noindex/XCBuildData' / (identifier + '.xcbuilddata')
        data.mkdir(parents=True)
        guid = 'PACKAGE-PRODUCT:fixture.App'
        pif = [{'type': 'target', 'contents': {'name': 'NexGenVideo-product', 'guid': guid,
            'buildConfigurations': [{'name': 'Release', 'buildSettings': {'PRODUCT_MODULE_NAME': 'NexGenVideo'}}]}}]
        parameters = {'action': 'build', 'configurationName': 'Release', 'arenaInfo': {'derivedDataPath': '/arena',
            'buildProductsPath': '/arena/Products', 'buildIntermediatesPath': '/arena/Intermediates.noindex', 'optional': None},
            'activeRunDestination': {'sdk': '/SDKs/MacOSX.sdk', 'targetArchitecture': 'arm64'},
            'overrides': {'synthesized': {'table': {'OTHER_SWIFT_FLAGS': '$(inherited)'}}}}
        (folder / 'request.json').write_text(json.dumps({'parameters': parameters}))
        (folder / 'workspace.pif').write_text(json.dumps(pif))
        (directory / 'sdk-version.stdout').write_text('27.2\n')
        context = {'action': 'build', 'configuration': 'Release', 'arena': {k: v for k, v in parameters['arenaInfo'].items() if v is not None},
            'activeRunDestination': {'platform': 'macosx', 'targetArchitecture': 'arm64',
                'buildTarget': {'toolchainSDK': {'sdk': '/SDKs/MacOSX.sdk'}}},
            'overrides': {'OTHER_SWIFT_FLAGS': '$(inherited)', 'SDKROOT': 'macosx27.2', 'SDK_VARIANT': 'macos', 'SUPPORTS_MACCATALYST': 'NO'},
            'commandLineOverrides': {}, 'commandLineConfigOverrides': {}, 'environmentConfigOverrides': {}, 'packageConfigurationOverride': 'Release'}
        tasks, commands = [], {}
        for index, (role, title, stage, wrapper) in enumerate([
                ('swift-driver-compilation', 'SwiftDriver Compilation', 'P0', 'builtin-Swift-Compilation'),
                ('swift-driver-compilation-requirement', 'SwiftDriver Compilation Requirements', 'P2', 'builtin-Swift-Compilation-Requirements')]):
            rule = [title, 'NexGenVideo', 'normal', 'arm64', 'com.apple.xcode.tools.swift.compiler']
            key = stage + ':target-NexGenVideo-product-' + guid + '-SDKROOT:macosx27.2:SDK_VARIANT:macos:Release:' + ' '.join(rule)
            task = [None] * 25
            task[0] = ['', 'com.apple.xcode.tools.swift.compiler']
            task[3] = [0, [guid, False, 0, json.dumps(context).encode()]] if index == 0 else [1, 0]
            task[4] = rule
            argv = [wrapper, '--', '/tools/swiftc', '-module-name', 'NexGenVideo', '-sdk', '/SDKs/MacOSX27.2.sdk',
                '-target', 'arm64-apple-macos26.0', '-working-directory', '/source']
            task[6] = [[0, value.encode()] for value in argv]
            task[8] = [['DEVELOPER_DIR', 'SDKROOT', 'TOOLCHAINS'], ['/tools', '/SDKs/MacOSX27.2.sdk', 'measured']]
            task[9] = '/source'; task[17] = ['/source/app/Sources/NexGenVideo/App.swift']; task[18] = ['/arena/App.o']
            commands[key] = {'tool': role, 'description': ' '.join(rule),
                'inputs': task[17] + ['<WorkspaceHeaderMapVFSFilesWritten>'], 'outputs': task[18]}
            tasks.append(task)
        (data / 'manifest.json').write_text(json.dumps({'commands': commands}))
        (data / 'task-store.msgpack').write_bytes(wire(tasks))
        return folder, data, tasks

    def test_actual_driver_pair_binds_native_backend_overrides_references_and_parent_cwd(self):
        with tempfile.TemporaryDirectory() as temp:
            folder, data, tasks = self.driver_fixture(Path(temp))
            value = recipe.module_driver(folder, 'production', 'NexGenVideo', '/source/app', '/tools/swiftc')
            self.assertEqual(value['cwd'], '/source')
            self.assertEqual(value['module'], 'NexGenVideo')
            self.assertEqual(value['decodedTasks'], 2)
            for mutation in ('override', 'package-configuration', 'arena', 'module', 'cwd', 'sdk', 'missing-pair'):
                changed = copy.deepcopy(tasks)
                if mutation in {'override', 'package-configuration', 'arena'}:
                    context = json.loads(changed[0][3][1][3])
                    if mutation == 'override': context['overrides']['UNREVIEWED'] = 'YES'
                    elif mutation == 'package-configuration': context['packageConfigurationOverride'] = 'Debug'
                    else: context['arena']['buildProductsPath'] = '/outside/Products'
                    changed[0][3][1][3] = json.dumps(context).encode()
                elif mutation == 'module': changed[0][6][4][1] = b'Engine'
                elif mutation == 'cwd': changed[0][9] = '/source/app'
                elif mutation == 'sdk': changed[0][6][6][1] = b'/SDKs/MacOSX28.0.sdk'
                else: changed.pop()
                (data / 'task-store.msgpack').write_bytes(wire(changed))
                with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                    recipe.module_driver(folder, 'production', 'NexGenVideo', '/source/app', '/tools/swiftc')
