"""Fresh App roles with unchanged signed components and independently derived coverage."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import zipfile

import app_cohort_v2 as cohort
import native_xctest_host
from native_xctest_host import HOST_NAME, persist_proof
from retained_app_test_products import api, checksum, download, require, verify_artifact, write

SUPERVISOR = 'NexGenVideoBpySupervisor'
SERVICE = 'NexGenVideoBpyService'
SUPERVISOR_SOURCE_ROOTS = ('Sources/BpyRuntimeProtocol', 'Sources/BpySupervisorPOSIX',
    'Sources/NexGenVideoBpySupervisor')
SUPERVISOR_PACKAGE_SHA256 = '8b9c4bef0703bf4456ab04a7dbe3f8bd551b8807df3642243660b12cd38edc76'
SUPERVISOR_TARGETS = (
    '        .target(name: "BpyRuntimeProtocol", dependencies: ["BpySupervisorPOSIX"], path: "Sources/BpyRuntimeProtocol"),',
    '        .target(name: "BpySupervisorPOSIX", path: "Sources/BpySupervisorPOSIX",\n'
    '                linkerSettings: [.linkedFramework("Foundation")]),',
    '        .executableTarget(\n'
    '            name: "NexGenVideoBpySupervisor", dependencies: ["BpyRuntimeProtocol", "BpySupervisorPOSIX"], '
    'path: "Sources/NexGenVideoBpySupervisor",\n'
    '            linkerSettings: [.linkedLibrary("proc", .when(platforms: [.macOS]))]\n'
    '        ),',
)


def verify_reused_host(build, value):
    host = value['retainedXCTestHost']
    original = build.get('original', {})
    require(build.get('schema') == 'native-xctest-host-reuse/v1'
        and build.get('selected') == host['producer'] and build.get('hostSHA256') == host['sha256']
        and build.get('compilerExecutions') == 0 and build.get('appSourceSHA') == value['appSourceSHA']
        and original.get('schema') == 'native-xctest-host-build/v1'
        and original.get('signedSHA256') == host['sha256'] and original.get('unsignedSHA256') == host['unsignedSHA256']
        and original.get('appSourceSHA') == host['originalAppSourceSHA']
        and original.get('sourceSHA') == host['producer']['sourceSHA']
        and original.get('compilerSHA256') == host['compilerSHA256']
        and original.get('supportObjectSHA256') == host['supportObjectSHA256']
        and all(original.get('inputs', {}).get(name) == sha for name, sha in host['compiledInputs'].items()),
        'XCTest host lost its original compiler provenance')
    return build


def original_signed_input(root, value):
    import signed_component_carrier
    return signed_component_carrier.acquire(root, value)


def source_handoff(root, folder, original, value, manifest):
    import consume_bpy_distributable_source as source
    public = source.public_asset(json.loads(source.LOCK_PATH.read_bytes()))
    import signed_component_carrier
    raw = signed_component_carrier.original_source_receipt(manifest, value)
    prior = source.qualified_handoff(json.loads(raw), public, value['signedBase']['sourceSHA'])
    require(cohort.objects(os.environ['GITHUB_SHA'], ['Runtime']) ==
        cohort.objects(value['signedBase']['sourceSHA'], ['Runtime']), 'Corresponding-source runtime pins changed')
    folder.mkdir(exist_ok=False)
    receipt_path = folder / source.RECEIPT
    receipt_path.write_bytes((json.dumps(dict(prior, sourceSHA=os.environ['GITHUB_SHA']), indent=2, sort_keys=True) + '\n').encode())
    source.consume(folder, os.environ['GITHUB_SHA'], receipt_path)
    handoff = {'schema': 'compiled-component-source-handoff/v2', 'state': 'REUSED',
        'originalReceipt': raw.decode(), 'originalReceiptSHA256': hashlib.sha256(raw).hexdigest(),
        'qualification': source.QUALIFIED_HANDOFF, 'consumerSourceSHA': os.environ['GITHUB_SHA'],
        'receiptSHA256': checksum(receipt_path), 'semanticSourceValidationPerformed': False}
    write(root / 'component-source-handoff.json', handoff)
    return handoff


def main_product(bound):
    import compiled_app_release as release
    image = Path(bound['products']['production']['output'])
    symbols = Path(str(image) + '.dSYM')
    dwarf = symbols / 'Contents/Resources/DWARF/NexGenVideo'
    receipt = bound['products']['production']['receipt']
    require(image.is_file() and not image.is_symlink() and checksum(image) == receipt['state']['unsignedLinkSHA256']
        and symbols.is_dir() and not symbols.is_symlink() and all(not p.is_symlink() for p in symbols.rglob('*'))
        and release.image_uuid(image, 2) == release.image_uuid(dwarf, 10), 'Fresh Main image or matching symbols changed')
    plan = receipt['recipePlan']['production']
    links = [item for item in plan['operations']['links'] if item['targetGUID'] == plan['driver']['targetGUID']]
    linked = str(Path(receipt['arena']) / 'Products/Release/libNexGenEngine.dylib')
    require(len(links) == 1 and links[0]['argv'].count(linked) == 1 and '-lNexGenEngine' not in links[0]['argv'],
        'Fresh App lost its exact qualified Engine linker input')
    engine = Path(bound['runtime']) / 'libNexGenEngine.dylib'
    require(checksum(engine) == release.LINKED_ENGINE['sha256']
        and checksum(Path(bound['runtime']) / 'NexGenEngine.swiftmodule/arm64-apple-macos.swiftmodule')
        == release.LINKED_ENGINE['moduleSHA256'], 'Fresh App linked a different Engine product')
    return {'compiledImageSHA256': checksum(image), 'uuid': release.image_uuid(image, 2),
        'payloadSHA256': release.signed_payload_sha(image, 2), 'symbolsTreeSHA256': release.canonical_bundle_tree(symbols),
        'dwarfSHA256': checksum(dwarf)}


def unchanged_components(app):
    result = {}
    for root in ('Frameworks', 'Helpers', 'XPCServices'):
        folder = app / 'Contents' / root
        for path in [folder, *sorted(folder.rglob('*'))]:
            if not path.exists() and not path.is_symlink():
                continue
            item = {'mode': stat.S_IMODE(path.lstat().st_mode)}
            if path.is_symlink():
                item.update(kind='symlink', target=os.readlink(path))
            elif path.is_dir():
                item['kind'] = 'directory'
            else:
                require(path.is_file(), 'Retained component contains a special file')
                item.update(kind='file', sha256=checksum(path))
            result[path.relative_to(app).as_posix()] = item
    return result


def supervisor_package_manifest(original):
    require(hashlib.sha256(original).hexdigest() == SUPERVISOR_PACKAGE_SHA256,
        'Supervisor package declaration changed')
    tools_version = '// swift-tools-version: 6.2'
    product = '        .executable(name: "NexGenVideoBpySupervisor", targets: ["NexGenVideoBpySupervisor"]),'
    platform = '    platforms: [.macOS(.v26)],'
    declarations = original.decode()
    require(all(declarations.count(entry) == 1 for entry in (tools_version, product, platform, *SUPERVISOR_TARGETS)),
        'Supervisor product, local targets or platform differ')
    return ('\n'.join((tools_version, '', 'import PackageDescription', '',
        'let package = Package(', '    name: "NexGenVideo",', platform,
        '    products: [', product, '    ],', '    targets: [', *SUPERVISOR_TARGETS, '    ]', ')')) + '\n').encode()


def supervisor_package(source, inputs, destination=None):
    def git_bytes(*args):
        return subprocess.check_output(['git', *args], stdin=subprocess.DEVNULL, timeout=30)

    paths = ('Package.swift', *SUPERVISOR_SOURCE_ROOTS)
    require(cohort.objects(source, paths) == {name: inputs[name] for name in paths},
        'Supervisor source closure changed')
    package = supervisor_package_manifest(git_bytes('show', source + ':Package.swift'))
    if destination is not None:
        destination.mkdir(exist_ok=False)
        (destination / 'Package.swift').write_bytes(package)
    files = {}
    rows = git_bytes('ls-tree', '-rz', source, '--', *SUPERVISOR_SOURCE_ROOTS).split(b'\0')
    for row in filter(None, rows):
        metadata, raw_path = row.split(b'\t', 1)
        mode, kind, blob = metadata.decode().split()
        name = raw_path.decode()
        relative = Path(name)
        require(mode == '100644' and kind == 'blob' and any(name.startswith(root + '/') for root in SUPERVISOR_SOURCE_ROOTS)
            and '..' not in relative.parts and name not in files and relative.suffix in ('.swift', '.c', '.m', '.h'),
            'Unexpected Supervisor package input')
        raw = git_bytes('cat-file', 'blob', blob)
        files[name] = {'gitObject': blob, 'sha256': hashlib.sha256(raw).hexdigest(), 'bytes': len(raw), 'mode': mode}
        if destination is not None:
            path = destination / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open('xb') as stream:
                stream.write(raw)
    require(all(any(name.startswith(root + '/') for name in files) for root in SUPERVISOR_SOURCE_ROOTS),
        'Supervisor package target is missing')
    return {'rootManifestSHA256': SUPERVISOR_PACKAGE_SHA256,
        'derivedManifestSHA256': hashlib.sha256(package).hexdigest(), 'sourceFiles': files}


def replace_supervisors(root, app, candidate, sign, baseline, driver):
    import compiled_app_release as release
    import signed_component_carrier as carrier
    declared = candidate['componentSourceObjects']
    original = carrier.origin(candidate)['componentSourceObjects']
    path = carrier.REBUILT_SUPERVISOR
    if declared[path] == original[path]:
        return None, baseline
    require(cohort.objects(os.environ['GITHUB_SHA'], declared) == declared, 'Current supervisor source changed')
    targets = release.targets
    scratch = root / 'supervisor-compiler'
    require(not scratch.exists() and not scratch.is_symlink(), 'Supervisor compiler scratch is already occupied')
    package = root / 'supervisor-package' / 'nexgenvideo'
    package.parent.mkdir(exist_ok=False)
    recipe = supervisor_package(os.environ['GITHUB_SHA'], declared, package)
    write(root / 'bpy-supervisor-package.json', recipe)
    swift = Path(targets.logged(root, 'bpy-supervisor-swift', ['xcrun', '--find', 'swift']).strip())
    swiftc = Path(targets.logged(root, 'bpy-supervisor-swiftc', ['xcrun', '--find', 'swiftc']).strip())
    sdk = Path(targets.logged(root, 'bpy-supervisor-sdk', ['xcrun', '--sdk', 'macosx', '--show-sdk-path']).strip())
    require(swift.is_absolute() and swiftc.is_absolute() and swift.parent == swiftc.parent
        and checksum(swiftc) == candidate['compilerSHA256'] and driver.count('-sdk') == 1
        and sdk.is_absolute() and sdk.resolve(strict=True) == Path(driver[driver.index('-sdk') + 1]).resolve(strict=True),
        'Supervisor compiler or SDK differs from the reviewed toolchain')
    environment = dict(os.environ, SWIFT_EXEC=str(swiftc), SDKROOT=str(sdk))
    args = [str(swift), 'build', '--package-path', str(package), '--configuration', 'release', '--arch', 'arm64',
            '--disable-automatic-resolution', '--scratch-path', str(scratch)]
    compile_args = args + ['--product', SUPERVISOR, '--verbose']
    targets.logged(root, 'bpy-supervisor-compile', compile_args, env=environment, timeout=900)
    bin_path = Path(targets.logged(root, 'bpy-supervisor-bin-path',
        args + ['--show-bin-path'], env=environment).strip())
    binary = bin_path / SUPERVISOR
    require(bin_path.is_absolute() and bin_path.resolve().is_relative_to(scratch.resolve())
        and binary.is_file() and not binary.is_symlink(), 'Supervisor compiler did not produce its owned binary')
    build = targets.logged(root, 'bpy-supervisor-deployment', ['xcrun', 'vtool', '-show-build', str(binary)])
    require(re.search(r'^\s*platform\s+MACOS\s*$', build, re.M)
        and re.search(r'^\s*minos\s+26\.0(?:\.0)?\s*$', build, re.M),
        'Supervisor deployment floor changed')
    unsigned = checksum(binary)
    payload = release.signed_payload_sha(binary, 2)
    uuid = release.image_uuid(binary, 2)
    entitlements = 'Runtime/bpy/PythonChild.entitlements'
    service_entitlements = 'Runtime/bpy/NexGenVideoBpyService.entitlements'
    targets.logged(root, 'bpy-supervisor-sign', ['codesign', '--force', '--options', 'runtime', '--timestamp',
        '--sign', sign, '--entitlements', entitlements, str(binary)], timeout=180)
    require(release.signed_payload_sha(binary, 2) == payload and release.image_uuid(binary, 2) == uuid,
        'Signing changed the freshly compiled Supervisor payload')
    signed = checksum(binary)
    services = []
    for slot in range(2):
        xpc = app / 'Contents/XPCServices' / f'{SERVICE}{slot}.xpc'
        target = xpc / 'Contents/MacOS' / SUPERVISOR
        service = xpc / 'Contents/MacOS' / SERVICE
        require(target.is_file() and not target.is_symlink() and service.is_file() and not service.is_symlink()
            and checksum(target) == baseline[target.relative_to(app).as_posix()]['sha256'],
            'Retained XPC image differs before the Supervisor replacement')
        service_identity = {'slot': slot, 'uuid': release.image_uuid(service, 2),
            'payloadSHA256': release.signed_payload_sha(service, 2)}
        require(release.image_uuid(target, 2) != uuid, 'Fresh Supervisor reused the old executable identity')
        shutil.copyfile(binary, target)
        targets.logged(root, f'bpy-service-{slot}-reseal', ['codesign', '--force', '--options', 'runtime', '--timestamp',
            '--sign', sign, '--entitlements', service_entitlements, str(xpc)], timeout=180)
        require(checksum(target) == signed and release.image_uuid(service, 2) == service_identity['uuid']
            and release.signed_payload_sha(service, 2) == service_identity['payloadSHA256'],
            'XPC resealing changed retained service code or new Supervisor bytes')
        services.append(service_identity)
    current = unchanged_components(app)
    require(current.keys() == baseline.keys(), 'Supervisor replacement changed the component inventory')
    delta = {name:{'before': before, 'after': current[name]} for name, before in baseline.items()
             if before != current[name]}
    receipt = {'schema': 'bpy-supervisor-component-rebuild/v2', 'target': SUPERVISOR,
        'sourceSHA': os.environ['GITHUB_SHA'], 'runID': int(os.environ['GITHUB_RUN_ID']),
        'inputs': {name:declared[name] for name in (path, 'Sources/BpyRuntimeProtocol',
            'Sources/BpySupervisorPOSIX', 'Package.swift', 'Package.resolved')},
        'compilerPath': str(swiftc), 'compilerSHA256': checksum(swiftc), 'compileExitCode': 0,
        'package': recipe, 'sdkPath': str(sdk),
        'unsignedImageSHA256': unsigned, 'signedImageSHA256': signed, 'payloadSHA256': payload, 'uuid': uuid,
        'compilerLogSHA256': checksum(root / 'bpy-supervisor-compile.stdout'),
        'deploymentLogSHA256': checksum(root / 'bpy-supervisor-deployment.stdout'),
        'retainedServices': services, 'files': delta}
    write(root / 'bpy-supervisor-component-rebuild.json', receipt)
    return receipt, {name:entry for name, entry in baseline.items() if name not in delta}


def verify_components(value, candidate):
    import signed_component_carrier as carrier
    selected = carrier.origin(candidate)
    path = carrier.REBUILT_SUPERVISOR
    rebuilt = selected['componentSourceObjects'][path] != candidate['componentSourceObjects'][path]
    baseline = value['unchangedSignedComponents']
    require(type(value.get('componentCompilerExecutions')) is int
        and value['componentCompilerExecutions'] == int(rebuilt), 'Component compiler execution count differs')
    if not rebuilt:
        require('supervisorReplacement' not in value, 'Unexpected Supervisor replacement')
        if 'signedBaseCarrier' in value or int(candidate['build']) > int(selected['build']):
            carrier.verify_record(value.get('signedBaseCarrier'), candidate)
            carrier.verify_components(baseline, candidate)
        return baseline
    carrier.verify_record(value.get('signedBaseCarrier'), candidate)
    receipt = value.get('supervisorReplacement', {})
    inputs = candidate['componentSourceObjects']
    require(receipt.get('schema') == 'bpy-supervisor-component-rebuild/v2' and receipt.get('target') == SUPERVISOR
        and receipt.get('sourceSHA') == value['sourceSHA'] and receipt.get('runID') == value['runID']
        and receipt.get('compilerSHA256') == candidate['compilerSHA256'] and receipt.get('compileExitCode') == 0
        and Path(receipt.get('compilerPath', '')).is_absolute()
        and Path(receipt['compilerPath']).name == 'swiftc'
        and Path(receipt.get('sdkPath', '')).is_absolute()
        and receipt.get('inputs') == {name: inputs[name] for name in (path, 'Sources/BpyRuntimeProtocol',
            'Sources/BpySupervisorPOSIX', 'Package.swift', 'Package.resolved')}
        and all(re.fullmatch('[a-f0-9]{64}', receipt.get(key, '')) for key in ('unsignedImageSHA256',
            'signedImageSHA256', 'payloadSHA256', 'compilerLogSHA256', 'deploymentLogSHA256'))
        and re.fullmatch(r'[A-F0-9]{8}(?:-[A-F0-9]{4}){3}-[A-F0-9]{12}', receipt.get('uuid', '')),
        'Fresh Supervisor build receipt differs')
    require(receipt.get('package') == supervisor_package(receipt['sourceSHA'], inputs),
        'Fresh Supervisor package source closure differs')
    services = receipt.get('retainedServices', [])
    require([service.get('slot') for service in services] == [0, 1] and all(
        re.fullmatch(r'[A-F0-9]{8}(?:-[A-F0-9]{4}){3}-[A-F0-9]{12}', service.get('uuid', ''))
        and re.fullmatch('[a-f0-9]{64}', service.get('payloadSHA256', '')) for service in services),
        'Retained XPC executable identity is incomplete')
    files = receipt.get('files', {})
    required, allowed = set(), set()
    for slot in range(2):
        prefix = f'Contents/XPCServices/{SERVICE}{slot}.xpc/Contents/'
        image = prefix + 'MacOS/' + SUPERVISOR
        required.update((image, prefix + '_CodeSignature/CodeResources'))
        allowed.add(prefix + 'MacOS/' + SERVICE)
        require(files.get(image, {}).get('after', {}).get('sha256') == receipt['signedImageSHA256'],
            'New Supervisor bytes differ between XPC slots')
    require(required <= set(files) <= required | allowed and not set(files) & set(baseline)
        and all(set(item) == {'before', 'after'} and item['before'].get('kind') == item['after'].get('kind') == 'file'
            and item['before'].get('mode') == item['after'].get('mode')
            and all(re.fullmatch('[a-f0-9]{64}', entry.get('sha256', '')) for entry in item.values())
            and item['before']['sha256'] != item['after']['sha256'] for item in files.values()),
        'Replacement changed files outside the two Supervisor executables and their XPC seals')
    carrier.verify_components(baseline | {name: item['before'] for name, item in files.items()}, candidate)
    return baseline | {name: item['after'] for name, item in files.items()}


def assemble(root):
    import compiled_app_release as release
    checkpoint, targets = release.checkpoint, release.targets
    release.native_guard(root)
    bound = json.loads((root / 'bound.json').read_bytes())
    receipt = json.loads((root / 'receipt.json').read_bytes())
    release.verify_receipt(receipt, os.environ['GITHUB_SHA'], int(os.environ['GITHUB_RUN_ID']))
    value = cohort.verify_context(bound['prepared']['cohortV2'])
    origin = value['signedBase']
    import signed_component_carrier
    original_components = signed_component_carrier.origin(value)['componentSourceObjects']
    require(cohort.git('rev-parse', 'HEAD') == os.environ['GITHUB_SHA']
        and cohort.objects(os.environ['GITHUB_SHA'], value['componentSourceObjects']) == value['componentSourceObjects']
        and cohort.objects(origin['sourceSHA'], original_components) == original_components,
        'Signed component source changed')
    resources = 'Sources/NexGenVideo/Resources'
    fresh_resources = {resources + '/Info.plist', resources + '/Changelog/changelog.json'}
    require(set(cohort.git('diff', '--name-only', '--no-renames', origin['sourceSHA'], 'HEAD', '--', resources).splitlines())
        <= fresh_resources, 'Retained App resources changed outside the declared replacements')
    original, manifest = original_signed_input(root, value)
    build = Path('.build'); build.mkdir(exist_ok=True)
    app = build / 'NexGenVideo.app'
    require(not app.exists() and not app.is_symlink(), 'Fresh App destination is occupied')
    checkpoint.validate_app_zip(original / 'NexGenVideo.zip')
    targets.logged(root, 'restore-signed-components', ['/usr/bin/ditto', '-x', '-k', str(original / 'NexGenVideo.zip'), str(build)])
    require(checkpoint.tree_digest(app) == manifest['appTreeSHA256'], 'Restored signed component carrier changed')
    baseline = unchanged_components(app)
    signed_component_carrier.verify_components(baseline, value)
    checkpoint.extract_tar(original / 'symbols.tar.gz', build, {
        'NexGenVideo.dSYM', 'NexGenVideoDiagnostics.dSYM', 'NexGenEngine.dSYM', 'MusicvideoPlugin.dSYM'})
    checkpoint.extract_tar(original / 'plugins.tar.gz', build, {'plugins'})
    require(checksum(build / 'plugins/musicvideo.ngvpack.zip') == origin['packArchiveSHA256'], 'Retained pack archive changed')
    if not (build / 'plugins/musicvideo.ngvpack').exists():
        targets.logged(root, 'restore-retained-pack', ['/usr/bin/ditto', '-x', '-k',
            str(build / 'plugins/musicvideo.ngvpack.zip'), str(build / 'plugins')])
    release.verify_pack(build / 'plugins', product=receipt['sourceSHA'])
    handoff = source_handoff(root, build / 'bpy-source', original, value, manifest)
    main = main_product(bound)
    image, symbols = app / 'Contents/MacOS/NexGenVideo', build / 'NexGenVideo.dSYM'
    image.rename(root / 'retired-base-main'); symbols.rename(root / 'retired-base-main-symbols')
    production = Path(bound['products']['production']['output'])
    shutil.copyfile(production, image); os.chmod(image, 0o755)
    shutil.copytree(Path(str(production) + '.dSYM'), symbols, symlinks=True)
    targets.logged(root, 'distribution-rpath', ['install_name_tool', '-add_rpath', '@executable_path/../Frameworks', str(image)])
    distribution_payload = release.signed_payload_sha(image, 2)
    require(release.image_uuid(image, 2) == main['uuid'], 'Distribution rpath changed Main identity')
    prior_info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    info = plistlib.loads(Path(resources + '/Info.plist').read_bytes())
    require(info.get('CFBundleIdentifier') == prior_info.get('CFBundleIdentifier')
        and int(value['build']) > int(manifest['identity']['build']), 'Fresh App identity or build did not advance')
    if 'SentryDSN' in prior_info:
        info['SentryDSN'] = prior_info['SentryDSN']
    info.update(NGVSourceCommit=os.environ['GITHUB_SHA'], NGVBuildConfiguration='release', NGVBuildSDK='27.2',
        CFBundleShortVersionString=value['version'], CFBundleVersion=value['build'])
    require(info.get('NGVPluginCatalogURL') == manifest['identity']['catalogURL'], 'App catalog channel changed')
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    (app / 'Contents/Resources/Changelog/changelog.json').write_bytes(Path(resources + '/Changelog/changelog.json').read_bytes())
    sign = os.environ.get('SIGN_IDENTITY', '')
    require(re.fullmatch('[a-fA-F0-9]{40}', sign) or sign.startswith('Developer ID Application: '), 'Missing Developer ID signer')
    supervisor, retained_components = replace_supervisors(root, app, value, sign, baseline,
        bound['prepared']['plans']['production']['driver']['argv'])
    targets.logged(root, 'sign-new-app-root', ['codesign', '--force', '--options', 'runtime', '--timestamp',
        '--sign', sign, '--entitlements', 'scripts/NexGenVideo.entitlements', str(app)], timeout=180)
    targets.logged(root, 'verify-new-app-signature', ['codesign', '--verify', '--deep', '--strict', str(app)])
    targets.logged(root, 'verify-distributable-bpy', ['bash', 'scripts/verify_bpy_bundle.sh', str(app), '--distribution'], timeout=300)
    require(main_product(bound) == main, 'Signing changed the original Main compiler product')
    component = {'schema': 'compiled-component-assembly/v2', 'sourceSHA': os.environ['GITHUB_SHA'],
        'runID': int(os.environ['GITHUB_RUN_ID']), 'attempt': 1, 'build': value['build'], 'cohortV2': receipt['cohortV2'],
        'signedBase': origin, 'signedBaseCarrier': signed_component_carrier.record(value),
        'unchangedSignedComponents': retained_components, 'sourceHandoff': handoff,
        'main': {'original': main, 'distributionImageSHA256': checksum(image), 'payloadSHA256': distribution_payload},
        'componentCompilerExecutions': int(supervisor is not None)}
    if supervisor is not None:
        component['supervisorReplacement'] = supervisor
    verify_materialization(component, app, build / 'NexGenEngine.dSYM')
    write(root / 'assembled.json', {'sourceSHA': os.environ['GITHUB_SHA'], 'runID': int(os.environ['GITHUB_RUN_ID']),
        'appTreeSHA256': checkpoint.tree_digest(app), 'identity': checkpoint.identity(build),
        'newCompiledImageSHA256': main['compiledImageSHA256'], 'distributionImageSHA256': checksum(image),
        'retainedPackSHA256': origin['packArchiveSHA256'], 'retainedPackTreeSHA256': origin['packTreeSHA256'],
        'mainSymbolsTreeSHA256': main['symbolsTreeSHA256'], 'componentAssembly': component})


def verify_main_symbol_identity(product, main):
    state = product.get('state', {})
    uuids = lambda text: re.findall(r'UUID: ([A-Fa-f0-9-]{36}) \(arm64\)', text)
    require(main.get('compiledImageSHA256') == state.get('unsignedLinkSHA256')
        and uuids(state.get('imageUUID', '')) == uuids(state.get('dsymUUID', '')) == [main.get('uuid')],
        'Fresh Main image and symbols lost their actual compiler identity')


def verify_assembly(value, source_sha, run_id, identity, files, native):
    import consume_bpy_distributable_source as source
    candidate = cohort.verify_context(native.get('cohortV2'))
    require(value.get('schema') == 'compiled-component-assembly/v2' and value.get('sourceSHA') == source_sha
        and value.get('runID') == run_id and value.get('attempt') == 1
        and value.get('cohortV2') == native['cohortV2'] and value.get('signedBase') == candidate['signedBase']
        and value.get('build') == identity.get('build') == candidate['build']
        and identity.get('version') == candidate['version']
        and value.get('unchangedSignedComponents'), 'Fresh App component assembly identity changed')
    verify_components(value, candidate)
    product = native['products']['production']['receipt']
    main = value.get('main', {}).get('original', {})
    verify_main_symbol_identity(product, main)
    require(all(re.fullmatch('[a-f0-9]{64}', main.get(key, '')) for key in
            ('compiledImageSHA256', 'payloadSHA256', 'symbolsTreeSHA256', 'dwarfSHA256'))
        and all(re.fullmatch('[a-f0-9]{64}', value['main'].get(key, '')) for key in ('distributionImageSHA256', 'payloadSHA256')),
        'Fresh Main provenance or symbols differ')
    handoff = value.get('sourceHandoff', {})
    raw = handoff.get('originalReceipt', '').encode()
    public = source.public_asset(json.loads(source.LOCK_PATH.read_bytes()))
    prior = source.qualified_handoff(json.loads(raw), public, candidate['signedBase']['sourceSHA'])
    derived = (json.dumps(dict(prior, sourceSHA=source_sha), indent=2, sort_keys=True) + '\n').encode()
    require(handoff.get('schema') == 'compiled-component-source-handoff/v2'
        and handoff.get('originalReceiptSHA256') == hashlib.sha256(raw).hexdigest()
        and handoff.get('qualification') == source.QUALIFIED_HANDOFF and handoff.get('consumerSourceSHA') == source_sha
        and handoff.get('semanticSourceValidationPerformed') is False and handoff.get('state') == 'REUSED'
        and handoff.get('receiptSHA256') == hashlib.sha256(derived).hexdigest() == files['bpy-source-receipt.json']['sha256'],
        'Fresh App lost its retained corresponding-source qualification')
    return value


def verify_materialization(value, app, symbols):
    import compiled_app_release as release
    candidate = cohort.verify_context(value.get('cohortV2'))
    components = verify_components(value, candidate)
    if 'supervisorReplacement' in value:
        replacement = value['supervisorReplacement']
        for entry in replacement['retainedServices']:
            folder = app / 'Contents/XPCServices' / f"{SERVICE}{entry['slot']}.xpc" / 'Contents/MacOS'
            require(release.image_uuid(folder / SERVICE, 2) == entry['uuid']
                and release.signed_payload_sha(folder / SERVICE, 2) == entry['payloadSHA256']
                and release.image_uuid(folder / SUPERVISOR, 2) == replacement['uuid']
                and release.signed_payload_sha(folder / SUPERVISOR, 2) == replacement['payloadSHA256'],
                'Materialization changed a retained XPC executable or the new Supervisor payload')
    base, main = candidate['signedBase'], value['main']['original']
    image, dwarf = app / 'Contents/MacOS/NexGenVideo', symbols.parent / 'NexGenVideo.dSYM/Contents/Resources/DWARF/NexGenVideo'
    engine = app / 'Contents/Frameworks/libNexGenEngine.dylib'
    require(unchanged_components(app) == components
        and checksum(engine) == base['engineImageSHA256'] and release.image_uuid(engine, 6) == base['engineUUID']
        and release.signed_payload_sha(engine) == base['enginePayloadSHA256']
        and release.canonical_bundle_tree(symbols) == base['engineSymbolsTreeSHA256']
        and checksum(image) == value['main']['distributionImageSHA256']
        and release.signed_payload_sha(image, 2) == value['main']['payloadSHA256']
        and release.image_uuid(image, 2) == release.image_uuid(dwarf, 10) == main['uuid']
        and checksum(dwarf) == main['dwarfSHA256']
        and release.canonical_bundle_tree(symbols.parent / 'NexGenVideo.dSYM') == main['symbolsTreeSHA256'],
        'Materialized App changed its fresh Main or retained signed components')
    return value


def signed_product(manifest):
    value = cohort.verify_context(manifest['nativeEvidence'].get('cohortV2'))
    return {'schema': 'compiled-signed-product-reuse/v2', 'sourceSHA': manifest['sourceSHA'], 'runID': manifest['runID'],
        'appArchiveSHA256': manifest['files']['NexGenVideo.zip']['sha256'], 'appTreeSHA256': manifest['appTreeSHA256'],
        'cohortManifestSHA256': manifest['nativeEvidence']['cohortV2']['manifestSHA256'],
        'packArchiveSHA256': value['signedBase']['packArchiveSHA256'], 'packTreeSHA256': value['signedBase']['packTreeSHA256'],
        'compilerOrSignatureRepeated': False}


def pre_submit(producer, job):
    names = ('Submit App notarization exactly once', 'Notarize and staple app',
        'Notarize and staple downloadable format packs', 'Submit DMG notarization exactly once', 'Notarize and staple DMG')
    if not (job.get('run_id') == producer.get('id') and job.get('head_sha') == producer.get('head_sha')
            and job.get('labels') == ['macrunner'] and job.get('run_attempt') == 1 and job.get('status') == 'completed'):
        return None
    steps = job.get('steps', [])
    if not all(len([s for s in steps if s.get('name') == name]) == 1
            and next(s for s in steps if s.get('name') == name).get('conclusion') == 'skipped' for name in names):
        return None
    if not cohort.has_manifest(producer['head_sha']):
        return None
    return {'schema': 'release-proven-pre-submit/v1', 'sourceSHA': producer['head_sha'],
        'runID': producer['id'], 'jobID': job['id'], 'appleStagesAllSkipped': True}


def verify_xctest(proof, expected, source, product, value):
    require(proof.get('schema') == 'native-xctest-host-proof/v2' and proof.get('passed') is True
        and proof.get('originalExitCode') == 0 and proof.get('outputEOF') is True
        and proof.get('individualPassedIDs') == expected
        and type(proof.get('pid')) is int and proof['pid'] > 1
        and type(proof.get('parentPID')) is int and proof['parentPID'] > 1
        and all(re.fullmatch('[a-f0-9]{64}', proof.get(key, '')) for key in
            ('eventSHA256', 'hostReceiptSHA256', 'consoleSHA256', 'bundleImageSHA256', 'hostSHA256')),
        'Fresh XCTest proof lacks the actual complete process or inventory')
    build = product.get('state', {}).get('xctestHost', {})
    previous = cohort.verify_context(product.get('cohortV2'))
    require(previous['retainedXCTestHost'] == value['retainedXCTestHost'], 'XCTest host changed between compiler and runtime')
    verify_reused_host(build, previous)
    require(proof['hostSHA256'] == value['retainedXCTestHost']['sha256'], 'XCTest proof changed the retained host')
    for suffix, expected_hash in [('NexGenVideoTests.xctest/Contents/MacOS/NexGenVideoTests', proof['bundleImageSHA256']),
            ('NexGenVideoTests.xctest/Contents/Helpers/' + HOST_NAME, proof['hostSHA256'])]:
        selected = [item for name, item in product.get('files', {}).items() if name.endswith('/' + suffix)]
        require(len(selected) == 1 and selected[0].get('kind') == 'file' and selected[0].get('sha256') == expected_hash,
            'Fresh XCTest process did not consume its exact signed test product')
    event_bytes = proof.get('originalEventsUTF8', '').encode()
    receipt_bytes = proof.get('originalHostReceiptUTF8', '').encode()
    require(hashlib.sha256(event_bytes).hexdigest() == proof['eventSHA256']
        and hashlib.sha256(receipt_bytes).hexdigest() == proof['hostReceiptSHA256']
        and [json.loads(line) for line in event_bytes.decode().splitlines()] == proof.get('events')
        and json.loads(receipt_bytes) == proof.get('hostReceipt'), 'XCTest original observations or receipt bytes changed')
    receipt = proof.get('hostReceipt', {})
    prefix = 'Products/Release/NexGenVideoTests.xctest/Contents/Frameworks/'
    roots = {name.removeprefix(prefix).split('/')[0] for name in product.get('files', {}) if name.startswith(prefix)}
    kinds = sorted(Path(name).stem if name.endswith('.framework') else name for name in roots if name.endswith(('.framework', '.dylib')))
    require(kinds and receipt.get('runtimeKinds') == kinds, 'XCTest transitive runtime inventory lost its signed product binding')
    native_xctest_host.verify_receipt(receipt, proof.get('events', []), expected, source=source, pid=proof['pid'], parent=proof['parentPID'],
        bundle=Path(receipt.get('bundlePath', '')), host=Path(receipt.get('hostPath', '')))
    return proof


def run_xctest(folder, bound, image, expected):
    from run_macos_tests import prepare_post_mortem, run_process
    folder.mkdir(exist_ok=False)
    bundle = image.parents[2]
    host = bundle / 'Contents/Helpers' / HOST_NAME
    build_proof = bound['products']['tests']['receipt']['state'].get('xctestHost', {})
    import app_cohort_v2
    value = app_cohort_v2.verify_context(bound['prepared']['cohortV2'])
    previous = cohort.verify_context(bound['products']['tests']['receipt'].get('cohortV2'))
    require(previous['retainedXCTestHost'] == value['retainedXCTestHost'], 'XCTest host changed between compiler and runtime')
    verify_reused_host(build_proof, previous)
    require(checksum(host) == value['retainedXCTestHost']['sha256'], 'Reused host executable changed')
    write(folder / 'expected.json', expected)
    environment = dict(os.environ)
    require(not any(key.startswith('DYLD_') and value for key, value in environment.items()), 'Ambient native loader override')
    frameworks = bundle / 'Contents/Frameworks'
    environment['DYLD_FRAMEWORK_PATH'] = str(frameworks)
    environment['DYLD_LIBRARY_PATH'] = os.pathsep.join((str(frameworks), bound['runtime']))
    write(folder / 'loader-paths.json', {key: value for key, value in environment.items() if key.startswith('DYLD_')})
    require(not any(key.startswith(('NGV_ACCEPTANCE', 'NGV_APP_DIAGNOSTIC', 'NSZombie')) for key in environment),
        'XCTest acceptance cannot use a diagnostic substitute')
    command = [str(host), str(bundle), str(folder / 'expected.json'), str(folder / 'receipt.json'),
        str(folder / 'events.jsonl'), str(folder / 'exception.jsonl')]
    write(folder / 'command.json', command)
    observation = prepare_post_mortem(host)
    code, pid = run_process(command, folder / 'console.log', environment, observation)
    write(folder / 'process.json', {'exitCode': code, 'pid': pid, 'parentPID': os.getpid(), 'observation': observation})
    require(code == 0 and observation.get('outputCapture', {}).get('originalExitCode') == 0
        and observation['outputCapture'].get('eof') is True, 'Native XCTest process or output capture failed')
    receipt = json.loads((folder / 'receipt.json').read_text())
    records = [json.loads(line) for line in (folder / 'events.jsonl').read_text().splitlines()]
    native_xctest_host.verify_receipt(receipt, records, expected, source=bound['sourceSHA'], pid=pid, parent=os.getpid(), bundle=bundle, host=host)
    console = (folder / 'console.log').read_text()
    require(not re.search(r'Test run started|Testing Library Version|◇ Test|✘ Test|✔ Test', console),
        'Unexpected Swift Testing execution in XCTest host')
    require((folder / 'exception.jsonl').is_file() and (folder / 'exception.jsonl').stat().st_size == 0,
        'Native AppKit exception evidence is missing or nonempty')
    proof = {'schema': 'native-xctest-host-proof/v2', 'pid': pid, 'parentPID': os.getpid(),
        'individualPassedIDs': expected, 'hostReceipt': receipt, 'events': records, 'originalEventsUTF8': (folder / 'events.jsonl').read_text(),
        'originalHostReceiptUTF8': (folder / 'receipt.json').read_text(), 'hostReceiptSHA256': checksum(folder / 'receipt.json'),
        'eventSHA256': checksum(folder / 'events.jsonl'), 'consoleSHA256': checksum(folder / 'console.log'),
        'hostSHA256': checksum(host), 'bundleImageSHA256': checksum(image), 'originalExitCode': code,
        'outputEOF': observation['outputCapture']['eof'], 'passed': True}
    verify_xctest(proof, expected, bound['sourceSHA'], bound['products']['tests']['receipt'], value)
    persist_proof(folder / 'verified.json', proof)
    return proof
