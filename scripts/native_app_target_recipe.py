import hashlib
import json
import math
from pathlib import Path, PurePosixPath
import re
import shlex
import struct

from native_app_build_plan import planned_app_tasks


def require(value, message):
    if not value:
        raise ValueError(message)


class TaskStoreReader:
    def __init__(self, raw):
        require(isinstance(raw, bytes) and 0 < len(raw) <= 32 * 1024**2, 'Task store exceeds its bound')
        self.raw, self.offset, self.values = raw, 0, 0

    def take(self, count):
        require(0 <= count <= len(self.raw) - self.offset, 'Truncated task store')
        result = self.raw[self.offset:self.offset + count]
        self.offset += count
        return result

    def integer(self, count, signed=False):
        return int.from_bytes(self.take(count), 'big', signed=signed)

    def value(self, depth=0):
        self.values += 1
        require(self.values <= 2_000_000 and depth < 100, 'Task store nesting or item bound exceeded')
        tag = self.integer(1)
        if tag <= 0x7f: return tag
        if tag == 0xe0: return self.integer(1)
        if tag >= 0xe1: return tag - 256
        if 0xa0 <= tag <= 0xbf: return self.take(tag & 31).decode('utf-8')
        if 0x90 <= tag <= 0x9f: return [self.value(depth + 1) for _ in range(tag & 15)]
        if 0x80 <= tag <= 0x8f: return self.mapping(tag & 15, depth)
        if tag == 0xc0: return None
        if tag in (0xc2, 0xc3): return tag == 0xc3
        if tag in (0xcc, 0xcd, 0xce, 0xcf): return self.integer(1 << (tag - 0xcc))
        if tag in (0xd0, 0xd1, 0xd2, 0xd3): return self.integer(1 << (tag - 0xd0), True)
        if tag in (0xca, 0xcb):
            result = struct.unpack('>f' if tag == 0xca else '>d', self.take(4 if tag == 0xca else 8))[0]
            require(math.isfinite(result), 'Nonfinite task store number')
            return result
        if tag in (0xd9, 0xda, 0xdb): return self.take(self.integer(1 << (tag - 0xd9))).decode('utf-8')
        if tag in (0xc4, 0xc5, 0xc6): return self.take(self.integer(1 << (tag - 0xc4)))
        if tag in (0xdc, 0xdd):
            count = self.integer(2 if tag == 0xdc else 4)
            require(count <= 200_000, 'Task store array exceeds its bound')
            return [self.value(depth + 1) for _ in range(count)]
        if tag in (0xde, 0xdf): return self.mapping(self.integer(2 if tag == 0xde else 4), depth)
        raise ValueError('Unsupported task store tag: ' + hex(tag))

    def mapping(self, count, depth):
        require(count <= 200_000, 'Task store map exceeds its bound')
        result = {}
        for _ in range(count):
            key, value = self.value(depth + 1), self.value(depth + 1)
            require(type(key) in (str, int) and key not in result, 'Invalid or duplicated task store map key')
            result[key] = value
        return result

    def tasks(self):
        result = self.value()
        require(self.offset == len(self.raw) and isinstance(result, list) and result,
            'Task store must contain one complete task array')
        require(all(isinstance(task, list) and len(task) == 25 for task in result), 'Unsupported serialized task layout')
        return result


def configured_tasks(tasks):
    targets, parameters, result = [], [], []
    for task in tasks:
        encoded = task[3]
        if encoded is None:
            result.append((None, task))
            continue
        require(isinstance(encoded, list) and len(encoded) == 2 and type(encoded[0]) is int,
            'Invalid configured target reference')
        if encoded[0] == 0:
            target = encoded[1]
            require(isinstance(target, list) and len(target) == 4 and isinstance(target[0], str)
                and type(target[1]) is bool and type(target[2]) is int, 'Unsupported configured target definition')
            if target[2] == 0:
                require(isinstance(target[3], bytes), 'Missing serialized build parameters')
                current = json.loads(target[3])
                require(isinstance(current, dict), 'Invalid configured build parameters')
                parameters.append(current)
            else:
                require(target[2] == 1 and type(target[3]) is int and 0 <= target[3] < len(parameters),
                    'Unknown configured build parameter reference')
                current = parameters[target[3]]
            resolved = {'guid': target[0], 'specialization': target[1], 'parameters': current}
            targets.append(resolved)
        else:
            require(encoded[0] == 1 and type(encoded[1]) is int and 0 <= encoded[1] < len(targets),
                'Unknown configured target reference')
            resolved = targets[encoded[1]]
        result.append((resolved, task))
    return result


def arguments(encoded):
    require(isinstance(encoded, list), 'Missing typed command arguments')
    result = []
    for item in encoded:
        require(isinstance(item, list) and len(item) == 2 and type(item[0]) is int,
            'Invalid typed command argument')
        if item[0] == 0:
            require(isinstance(item[1], bytes), 'Literal argument is not a byte string')
            value = item[1].decode('utf-8')
        else:
            require(item[0] == 1 and isinstance(item[1], str), 'Unsupported command path argument')
            value = item[1]
        require('\0' not in value, 'Command argument contains NUL')
        result.append(value)
    return result


def environment(task, expected_keys=None):
    encoded = task[8]
    require(isinstance(encoded, list) and len(encoded) == 2 and all(isinstance(x, list) for x in encoded),
        'Invalid serialized command environment')
    keys, values = encoded
    require(len(keys) == len(values) and all(isinstance(x, str) and '\0' not in x for x in keys + values)
        and len(set(keys)) == len(keys), 'Invalid command environment bindings')
    require(set(keys) == (expected_keys if expected_keys is not None else {'DEVELOPER_DIR', 'SDKROOT', 'TOOLCHAINS'}),
        'Unexpected command environment override')
    return dict(zip(keys, values))


def unique_option(argv, flag):
    require(argv.count(flag) == 1 and argv.index(flag) + 1 < len(argv), 'Missing or ambiguous compiler option: ' + flag)
    return argv[argv.index(flag) + 1]


def canonical_path(value):
    require(isinstance(value, str) and '\0' not in value, 'Invalid native path')
    path = PurePosixPath(value)
    require(path.is_absolute() and str(path) == value and '..' not in path.parts, 'Noncanonical native path')
    return path


def copy_paths(rule, inputs, outputs):
    require(isinstance(rule, list) and len(rule) == 3 and rule[0] == 'Copy', 'Unsupported native copy rule')
    destination, source = canonical_path(rule[1]), canonical_path(rule[2])
    require(inputs == [str(source) + '/'] and outputs == [str(destination)], 'Native copy scan marker differs from its rule')
    return str(source), str(destination)


def auxiliary_context(action):
    require(isinstance(action, list) and len(action) == 2 and type(action[0]) is int and action[0] == 1
        and isinstance(action[1], list) and len(action[1]) == 7, 'Unsupported auxiliary file task')
    context = action[1]
    require(context[2] is None and context[3] is False and context[4] == [] and type(context[5]) is bool,
        'Unreviewed auxiliary permissions, forced write, diagnostics or logging mode')
    require(isinstance(context[6], list) and len(context[6]) == 1 and isinstance(context[6][0], bytes),
        'Missing auxiliary task signature')
    return {'output': str(canonical_path(context[0])), 'input': str(canonical_path(context[1])), 'logContents': context[5]}


def module_driver(folder, profile, module, source_root, compiler):
    pif = json.loads((folder / 'workspace.pif').read_text())
    manifests = list(folder.glob('**/*.xcbuilddata/manifest.json'))
    require(len(manifests) == 1, 'Missing or ambiguous native manifest')
    manifest_path = manifests[0]
    manifest = json.loads(manifest_path.read_text())
    selected = [row for row in planned_app_tasks(manifest, pif, profile, source_root) if row['module'] == module]
    require(len(selected) == 2 and len({row['targetGUID'] for row in selected}) == 1, 'Missing exact module task pair')
    raw = (manifest_path.parent / 'task-store.msgpack').read_bytes()
    reader = TaskStoreReader(raw)
    tasks = configured_tasks(reader.tasks())
    request = json.loads((folder / 'request.json').read_text())
    parameters = request['parameters']
    sdk_version = (folder.parent / 'sdk-version.stdout').read_text().strip()
    require(re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}', sdk_version), 'Missing measured SDK version')
    overrides = dict(parameters['overrides']['synthesized']['table'])
    require(not set(overrides).intersection({'SDKROOT', 'SDK_VARIANT', 'SUPPORTS_MACCATALYST'}),
        'Request overrides replace backend destination bindings')
    overrides.update(SDKROOT='macosx' + sdk_version, SDK_VARIANT='macos', SUPPORTS_MACCATALYST='NO')
    recipes = []
    for item in selected:
        wanted = item['command']['description']
        matches = [(target, task) for target, task in tasks if target and target['guid'] == item['targetGUID']
            and isinstance(task[4], list) and all(isinstance(value, str) for value in task[4])
            and ' '.join(task[4]) == wanted]
        require(len(matches) == 1, 'Task store does not uniquely bind the manifest module task')
        target, task = matches[0]
        context = target['parameters']
        require(target['specialization'] is False and context['action'] == 'build' and context['configuration'] == 'Release'
            and context['overrides'] == overrides, 'Configured target context differs')
        require(context['packageConfigurationOverride'] == 'Release' and all(context[key] == {} for key in
            ('commandLineOverrides', 'commandLineConfigOverrides', 'environmentConfigOverrides')),
            'Configured target contains an unreviewed configuration override')
        require(context['arena'] == {key: value for key, value in parameters['arenaInfo'].items() if value is not None},
            'Configured target arena differs')
        destination = context['activeRunDestination']
        require(destination['targetArchitecture'] == 'arm64' and destination['platform'] == 'macosx'
            and destination['buildTarget']['toolchainSDK']['sdk'] == parameters['activeRunDestination']['sdk'],
            'Configured target SDK or architecture differs')
        require(task[0] == ['', 'com.apple.xcode.tools.swift.compiler'], 'Unexpected driver task implementation')
        argv = arguments(task[6])
        wrapper = 'builtin-Swift-Compilation' if item['taskRole'] == 'swift-driver-compilation' else 'builtin-Swift-Compilation-Requirements'
        require(argv[:3] == [wrapper, '--', compiler], 'Unexpected Swift driver wrapper or compiler')
        require(unique_option(argv, '-module-name') == module and unique_option(argv, '-target') == 'arm64-apple-macos26.0',
            'Actual compiler module or target differs')
        env = environment(task)
        sdk = PurePosixPath(unique_option(argv, '-sdk'))
        require(str(sdk) == env['SDKROOT'] and sdk.name == 'MacOSX' + sdk_version + '.sdk'
            and sdk.parent == PurePosixPath(parameters['activeRunDestination']['sdk']).parent,
            'Compiler SDK does not bind the measured destination')
        require(isinstance(task[9], str) and PurePosixPath(task[9]).is_absolute(), 'Missing actual task working directory')
        require(unique_option(argv, '-working-directory') == task[9], 'Driver and task working directories differ')
        physical = {path for path in item['command']['inputs'] if not (path.startswith('<') and path.endswith('>'))}
        require(physical == set(task[17]) and set(item['command']['outputs']) == set(task[18]),
            'Task store and native manifest input/output boundaries differ')
        recipes.append({'targetGUID': target['guid'], 'module': module, 'argv': argv[2:], 'cwd': task[9],
            'environment': env, 'ruleInfo': task[4], 'manifestKey': item['key']})
    require(all(recipes[0][key] == recipes[1][key] for key in ('argv', 'cwd', 'environment', 'targetGUID', 'module')),
        'Compilation and requirement tasks disagree')
    return {'schema': 'native-app-module-driver/v1', **recipes[0],
        'manifestSHA256': hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
        'taskStoreSHA256': hashlib.sha256(raw).hexdigest(), 'taskStoreBytes': len(raw),
        'decodedTasks': len(tasks), 'decodedValues': reader.values, 'commandsExecuted': 0}


def profile_operations(folder):
    manifests = list(folder.glob('**/*.xcbuilddata/manifest.json'))
    require(len(manifests) == 1, 'Missing complete task store')
    directory = manifests[0].parent
    request = json.loads((folder / 'request.json').read_text())
    arena = canonical_path(request['parameters']['arenaInfo']['derivedDataPath'])
    tasks = configured_tasks(TaskStoreReader((directory / 'task-store.msgpack').read_bytes()).tasks())
    files, copies, headers, links, caches = [], [], [], [], []
    for target, task in tasks:
        rule = task[4]
        require(isinstance(rule, list) and all(isinstance(x, str) for x in rule), 'Invalid task rule')
        if not rule: continue
        guid = target['guid'] if target else None
        if task[0] == ['', 'com.apple.build-tools.write-file']:
            context = auxiliary_context(task[12])
            output, content = context['output'], context['input']
            output_path, content_path = canonical_path(output), canonical_path(content)
            if not output_path.is_relative_to(arena / 'Intermediates.noindex'): continue
            prefix = arena / 'Intermediates.noindex/XCBuildData' / directory.name / 'attachments'
            require(content_path.parent == prefix and len(content_path.parts) == len(prefix.parts) + 1,
                'Auxiliary content does not reference this native attachment closure')
            source = directory / 'attachments' / content_path.name
            require(source.is_file() and not source.is_symlink(), 'Missing original auxiliary content')
            require(task[18] == [output] and rule == ['WriteAuxiliaryFile', output], 'Auxiliary task output differs')
            files.append({'output': output, 'attachment': source.relative_to(folder).as_posix(),
                'sha256': hashlib.sha256(source.read_bytes()).hexdigest(), 'targetGUID': guid, 'logContents': context['logContents']})
        elif rule[0] == 'Copy' and len(task[17]) == len(task[18]) == 1:
            source, output = copy_paths(rule, task[17], task[18])
            destination = canonical_path(output)
            if destination.is_relative_to(arena / 'Intermediates.noindex/GeneratedModuleMaps'):
                require(canonical_path(source).is_relative_to(arena / 'Intermediates.noindex'), 'Module map source escapes the arena')
                copies.append({'source': source, 'output': output, 'targetGUID': guid, 'kind': 'module-map'})
            elif destination.is_relative_to(arena / 'Products/Release') and destination.suffix in {'.swiftmodule', '.swiftdoc', '.json'}:
                require(canonical_path(source).is_relative_to(arena / 'Intermediates.noindex'), 'Swift module source escapes the arena')
                copies.append({'source': source, 'output': output, 'targetGUID': guid, 'kind': 'swift-module'})
        elif rule[0] == 'SwiftMergeGeneratedHeaders':
            argv = arguments(task[6])
            single = argv[1:2] == ['-single']
            expected = argv[:1] + (['-single'] if single else [])
            start = len(expected)
            require(argv[:1] == ['builtin-swiftHeaderTool'] and len(argv) == start + 5
                and argv[start:start + 2] == ['-arch', 'arm64'] and argv[start + 3] == '-o',
                'Unsupported generated Swift header merge')
            source, output = argv[start + 2], argv[start + 4]
            require(task[17] == [source] and task[18] == [output]
                and canonical_path(source).is_relative_to(arena / 'Intermediates.noindex')
                and canonical_path(output).is_relative_to(arena / 'Intermediates.noindex/GeneratedModuleMaps'),
                'Generated header task paths differ')
            headers.append({'source': source, 'output': output, 'targetGUID': guid, 'single': single})
        elif rule[0] == 'Ld' and guid:
            argv = arguments(task[6])
            output = unique_option(argv, '-o')
            require(canonical_path(output).is_relative_to(arena / 'Products/Release'), 'Linker output escapes the products arena')
            links.append({'argv': argv, 'output': output, 'targetGUID': guid, 'cwd': task[9], 'environment': environment(task, {'PATH'})})
        elif rule[0] == 'ClangStatCache':
            argv = arguments(task[6])
            require(len(argv) == 4 and PurePosixPath(argv[0]).name == 'clang-stat-cache' and argv[2] == '-o'
                and task[18] == [argv[3]] and canonical_path(argv[3]).is_relative_to(arena / 'SDKStatCaches.noindex'),
                'Unsupported SDK stat cache task')
            caches.append({'argv': argv, 'cwd': task[9], 'environment': environment(task, set())})
    require(files and len({row['output'] for row in files}) == len(files), 'Missing or duplicated auxiliary outputs')
    return {'arena': str(arena), 'auxiliaryFiles': files, 'copies': copies, 'headers': headers, 'links': links, 'sdkStatCaches': caches}


def generated_header(raw, single):
    require(isinstance(raw, bytes) and type(single) is bool, 'Invalid Swift generated header input')
    if single: return raw
    return (b'#if 0\n#elif defined(__arm64__) && __arm64__\n' + raw +
        b'\n#else\n#error unsupported Swift architecture\n#endif\n')


def validate_frontend_jobs(text, driver, sources, arena, source_root, temporary_root, pinned_headers=None):
    require(isinstance(text, str) and len(text) <= 16 * 1024**2, 'Driver job output exceeds its bound')
    jobs = [shlex.split(line) for line in text.splitlines() if line.strip()]
    require(jobs and len(jobs) <= 2000, 'Missing or oversized frontend job graph')
    expected = set(sources)
    require(expected and all(canonical_path(path) for path in expected), 'Missing exact module source list')
    compiled = set()
    sdk = canonical_path(unique_option(driver['argv'], '-sdk'))
    tools = canonical_path(driver['argv'][0]).parent
    arena = canonical_path(arena)
    temporary = canonical_path(temporary_root)
    pinned_headers = pinned_headers or {}
    consumed = {}
    expanded_jobs = []
    def owned_file(value):
        path = canonical_path(value)
        require(path.is_relative_to(arena) or path.is_relative_to(temporary), 'Frontend auxiliary file escapes its job')
        file = Path(path)
        require(file.is_file() and file.stat().st_size <= 16 * 1024**2 and not file.is_symlink()
            and (file.resolve().is_relative_to(Path(arena).resolve()) or file.resolve().is_relative_to(Path(temporary).resolve())),
            'Missing or linked frontend auxiliary file')
        raw = file.read_bytes()
        consumed[str(file)] = {'path': str(file), 'sha256': hashlib.sha256(raw).hexdigest(), 'bytes': len(raw)}
        return raw
    def expand(argv, depth=0):
        require(depth < 8, 'Recursive frontend response file')
        expanded = []
        index = 0
        while index < len(argv):
            value = argv[index]
            if value.startswith('@'):
                expanded.extend(expand(shlex.split(owned_file(value[1:]).decode()), depth + 1))
            elif value == '-filelist':
                require(index + 1 < len(argv), 'Missing frontend source file list')
                index += 1
                expanded.extend(shlex.split(owned_file(argv[index]).decode()))
            else:
                expanded.append(value)
            require(len(expanded) <= 100_000, 'Frontend argument expansion exceeds its bound')
            index += 1
        return expanded
    for argv in jobs:
        argv = expand(argv)
        expanded_jobs.append(argv)
        require(argv and canonical_path(argv[0]).parent == tools and PurePosixPath(argv[0]).name in {'swift-frontend', 'clang'},
            'Unreviewed frontend job executable')
        swift_sources = {value for value in argv if value.endswith('.swift')}
        if swift_sources:
            require(swift_sources <= expected and unique_option(argv, '-module-name') == driver['module'],
                'Frontend would compile a different App or package source')
            compiled.update(swift_sources)
        else:
            require(any(flag in argv for flag in ('-emit-module', '-emit-pcm', '-compile-module-from-interface')),
                'Unreviewed dependency job operation')
            require(sdk != PurePosixPath('/') and tools.parent != PurePosixPath('/'),
                'Dependency toolchain or SDK root is unbounded')
            interface_values = [value.split('=', 1)[1] if value.startswith(('-fmodule-map-file=', '-module-map-file=')) else value
                for value in argv if value.endswith(('.swiftinterface', '.modulemap', '.h'))]
            interfaces = [canonical_path(value) for value in interface_values]
            require(interfaces and all(not path.is_relative_to(PurePosixPath(source_root) / 'Engine/Sources')
                and not path.is_relative_to(PurePosixPath(source_root) / 'Sources/NexGenVideo') for path in interfaces),
                'Dependency cache job would compile a retained host module')
            require(all(path.is_relative_to(sdk) or path.is_relative_to(tools.parent)
                or path.is_relative_to(arena) or str(path) in pinned_headers for path in interfaces),
                'Dependency cache input is outside the pinned toolchain, SDK and package graph')
            for path in interfaces:
                if str(path) in pinned_headers:
                    require(hashlib.sha256(Path(path).read_bytes()).hexdigest() == pinned_headers[str(path)],
                        'Pinned compiler header changed after preparation')
        for index, value in enumerate(argv[:-1]):
            if value in {'-o', '-emit-module-path', '-emit-objc-header-path', '-serialize-diagnostics-path'}:
                output = canonical_path(argv[index + 1])
                require(output.is_relative_to(arena) or output.is_relative_to(temporary),
                    'Frontend output escapes the exact module arena')
            elif value in {'-supplementary-output-file-map', '-output-file-map'}:
                mapping = json.loads(owned_file(argv[index + 1]))
                require(isinstance(mapping, dict) and mapping, 'Invalid frontend output map')
                for entry in mapping.values():
                    require(isinstance(entry, dict), 'Invalid frontend output map entry')
                    for path in entry.values():
                        output = canonical_path(path)
                        require(output.is_relative_to(arena) or output.is_relative_to(temporary),
                            'Frontend output map escapes its module arena')
    require(compiled == expected, 'Frontend job graph omits actual module sources')
    return {'jobs': len(jobs), 'moduleSourceCount': len(compiled), 'retainedPackageSourceCompilations': 0,
        'driverOutputSHA256': hashlib.sha256(text.encode()).hexdigest(), 'expandedJobs': expanded_jobs,
        'consumedInputs': sorted(consumed.values(), key=lambda item: item['path'])}
