"""Measure the unchanged test host's external AX availability in repository CI."""
import argparse
from collections import Counter
from contextlib import ExitStack
from datetime import datetime, timezone
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import signal
import struct
import subprocess
import sys
import time
import zipfile

from button_query_diagnostic import source_subset

ROOT = Path(__file__).resolve().parents[1]
SOURCE = 'd7eb426e1d3e5ab0c6bd87f2906872bf317c7023'
RUN, JOB, ARTIFACT = 42213973803, 127880239639, 13501418118
DIGEST = '34224c6db872f83840acc5cb55b07b29d030e7f9bef431eff700ade974a937cb'
RAW_DIGEST = 'bd2d78334004370d8a70a8911443de4f9631dbd6b80da03b694c71b81ffbd385'
LEGACY = {'run': 42252721451, 'sourceJob': 128011793185, 'nativeJob': 128011947696,
    'source': 'aa61cedccde8ca79c6051e0cfae7d4896af26ac5', 'tree': 'e234ffbe9090bf502963ccdbb3c01ad78269313b',
    'artifact': 13521506821, 'bytes': 77022,
    'digest': '6891e6ead209ef3a7efe9c55506914bf4ef90014af36109bfc91a895ebd1da31',
    'bindingArtifact': 13521696426, 'bindingBytes': 2346935,
    'bindingDigest': '72712775bf94f792d6af1010bb690db103ab2b66e8d27a547255e3dc01ac34bb'}
RESUME_RUN, RESUME_SOURCE_JOB, RESUME_JOB = 42269511007, 128070108626, 128070294906
RESUME_SOURCE = 'e849d35776e94ac0c0fea272d553482cf6cfeac6'
RESUME_TREE = 'c240b5a184c8a313a54789f2866320b5f9724558'
RESUME_ARTIFACT = 13528492969
RESUME_DIGEST = '6ce79cb7d9fb4d4e4b3cdffbf5bce972c4e49b23fa8f2c39a6afde4418c48266'
RESUME_BINDING_ARTIFACT = 13529041111
RESUME_BINDING_DIGEST = '0fc6642042fb2350770d1e83a42ad7e4649529dd44a8d2842dd56878e53c8371'
RESUME_BYTES, RESUME_BINDING_BYTES = 3093998, 4771187
CURRENT_RESUME = {'run': RESUME_RUN, 'sourceJob': RESUME_SOURCE_JOB, 'nativeJob': RESUME_JOB,
    'source': RESUME_SOURCE, 'tree': RESUME_TREE, 'artifact': RESUME_ARTIFACT, 'bytes': RESUME_BYTES,
    'digest': RESUME_DIGEST, 'bindingArtifact': RESUME_BINDING_ARTIFACT,
    'bindingBytes': RESUME_BINDING_BYTES, 'bindingDigest': RESUME_BINDING_DIGEST}
REUSED_RAW = {'member': 'peer-availability-raw', 'bytes': 601400,
    'SHA256': 'bde23de0dbc52aff0a334df6d0dc1c92da6aca3dc5696cecd864229d336a9a17',
    'uuid': '93292012aefd362fa8d0dcf3506beac2', 'machOType': 2}
SWIFT_VERSION = 'Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1)'
SWIFT_TARGET = SWIFT_VERSION + '\nTarget: arm64-apple-macosx27.2.0'
SUPPORT_MODULE = b'module AppKitTestHostSupport { header "AppKitTestHostSupport.h" export * }\n'
RETAINED = {
    'host': {'member': 'NexGenVideoAppKitTestHost', 'bytes': 129592,
        'SHA256': '8920c3511b809394ae79cf2f0410654b81d0dd1d2f702bbefd3e5c7ac663fc8f',
        'uuid': 'bacb31e1a13433158a98a4de94bab0c8', 'machOType': 2},
    'support': {'member': 'host-support.o', 'bytes': 13664,
        'SHA256': 'c54ae21621080173356419b30f9a70ed6075bbc63815589a655e407d654714fd',
        'machOType': 1}}
KIND = 'native-peer-availability'
QUERY = 'Sources/NexGenVideo/App/NativeButtonAccessibility.swift'
PEER = 'Sources/NexGenVideo/App/NativeAXPeer.swift'
FIXTURE = 'Tests/NexGenVideoTests/UI/NativeButtonInteractionTests.swift'
HOST = 'Tests/AppKitTestHost/AppKitTestHost.swift'
SUPPORT = 'Tests/AppKitTestHostSupport/AppKitTestHostSupport.m'
HEADER = 'Tests/AppKitTestHostSupport/include/AppKitTestHostSupport.h'
FILES = (QUERY, PEER, FIXTURE, HOST, SUPPORT, HEADER, *(
    'Sources/NexGenVideo/UI/' + name for name in
    ('CapsuleButton.swift', 'AppTheme.swift', 'DesignSystem.swift', 'PackAccent.swift')))
HARNESS = {'.github/workflows/diagnostic-acceptance.yml', 'scripts/test_diagnostic_acceptance.py',
    'scripts/peer_availability_diagnostic.py', 'scripts/peer_availability_diagnostic.swift',
    'scripts/peer_availability_raw.swift', 'scripts/test_peer_availability_diagnostic.py'}


def require(value, message):
    if not value:
        raise ValueError(message)


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def write(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], stdin=subprocess.DEVNULL, timeout=30)


def validate_inputs(env):
    require(env['KIND'] == KIND and env['CANDIDATE_RUN'] == str(RUN)
            and env['CANDIDATE_SOURCE'] == SOURCE and env['CANDIDATE_ARTIFACT'] == str(ARTIFACT)
            and env['CANDIDATE_DIGEST'] == DIGEST, 'Exact Native777 failure required')
    require(re.fullmatch('[1-9][0-9]*', env['VERIFIED_PR']) and env['SCALE'] == '1',
            'Current complete Source proof and normal scale required')
    require(env.get('EXTRA_FAILURE') == str(RESUME_ARTIFACT)
            and env.get('EXTRA_FAILURE_SHA') == RESUME_DIGEST, 'Exact Native787 retained compiler pair required')
    require(not any(env.get(key, '') for key in ('DMG_DIGEST', 'JOURNEY_JOB', 'JOURNEY_ARTIFACT',
        'JOURNEY_DIGEST', 'EXTRA_SOURCE', 'EXTRA_PRODUCTS', 'EXTRA_PRODUCTS_SHA',
        'RUNTIME_FAILURE_BINDING', 'PACKAGING_PRODUCER_SOURCE',
        'PACKAGING_PROVENANCE_ARTIFACT_ID', 'PACKAGING_PROVENANCE_ARTIFACT_SHA256')),
        'Unused peer diagnostic selectors cannot be ignored')


def failure_archive(path):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)) == 20 and archive.testzip() is None,
                'Native777 original archive inventory or CRC differs')
        events = [json.loads(line) for line in archive.read(
            '_temp/release-test-evidence/app-swift-testing/events.jsonl').split(b'\n') if line]
        issues = [event['payload'] for event in events
                  if event['kind'] == 'event' and event['payload']['kind'] == 'issueRecorded']
        counts = Counter(issue['testID'] for issue in issues)
        require(len(issues) == 20 and len(counts) == 8 and all(
            identity.startswith('NexGenVideoTests.NativeButtonInteractionTests/') for identity in counts),
            'The actual original eight-method failure differs')
        host = json.loads(archive.read('_temp/release-test-evidence/app-swift-testing/host-receipt.json'))
        require(host['sourceSHA'] == SOURCE and host['completed'] is True
                and host['abiSucceeded'] is False and host['eventRecordCount'] == 13464,
                'Original completed failed host differs')
        return {'issueCounts': dict(counts), 'host': host,
                'memberHashes': {name: digest(archive.read(name)) for name in names}}


def fixture_subset(raw):
    start = b'    @MainActor private final class Fixture {'
    following = b'    @MainActor private final class LastChildRoot: NSView {'
    ready = b'        func ready(using session: NativeAXPeer.Session)'
    close = b'        func close() { window.contentView = nil; window.close() }\n    }'
    require(raw.count(start) == raw.count(following) == 1, 'Fixture class boundaries changed')
    left, end = raw.index(start), raw.index(following)
    require(left < end, 'Fixture class order changed')
    fixture = raw[left:end]
    require(fixture.count(ready) == fixture.count(close) == 1, 'Fixture ranges changed')
    middle, right = left + fixture.index(ready), left + fixture.index(close)
    require(left < middle < right and not raw[right + len(close):end].strip(), 'Fixture range order changed')
    ranges = [(left, middle), (right, right + len(close))]
    return b''.join(raw[a:b] for a, b in ranges), ranges


def validate_changed_paths(paths):
    require(set(paths) <= HARNESS, 'App or unrelated source changed')


def retained_product(raw, expected):
    require(len(raw) == expected['bytes'] and digest(raw) == expected['SHA256'] and len(raw) >= 32,
            'Retained compiler product bytes differ')
    header = struct.unpack('<8I', raw[:32])
    require(header[0] == 0xfeedfacf and header[1] == 0x0100000c and header[3] == expected['machOType'],
            'Retained compiler product Mach-O type differs')
    if 'uuid' in expected:
        require(macho_uuid_data(raw) == expected['uuid'], 'Retained compiler product UUID differs')


def retained_process(receipt, command, log, parent, exit_code=0):
    require(receipt['command'] == command and receipt['exitCode'] == exit_code
            and receipt['timedOut'] is False and receipt['processReaped'] is True
            and type(receipt['PID']) is int and receipt['PID'] > 1
            and type(parent) is int and receipt['parentPID'] == parent
            and receipt['separateStderr'] is False and receipt['stderrFile'] is None
            and receipt['stderrSHA256'] is None and receipt['stdoutSHA256'] == digest(log)
            and all(type(receipt[key]) in (int, float) and math.isfinite(receipt[key])
                    for key in ('started', 'finished', 'startedWall', 'finishedWall', 'timeout'))
            and 0 < receipt['finished'] - receipt['started'] <= receipt['timeout'] <= 70
            and 0 < receipt['finishedWall'] - receipt['startedWall'] <= receipt['timeout'] + 1,
            'Retained compiler recipe or process provenance differs')


def retained_job_lifetime(process, jobs, identity):
    selected = [job for job in jobs['jobs'] if job['id'] == identity]
    require(len(selected) == 1, 'Retained compiler producer job missing')
    job = selected[0]
    start, end = (datetime.fromisoformat(job[key].replace('Z', '+00:00')).timestamp()
                  for key in ('started_at', 'completed_at'))
    require(start <= process['startedWall'] <= process['finishedWall'] <= end,
            'Retained compiler lies outside its original job lifetime')


def retained_raw_source(current, prior):
    require(current == prior, 'Current Raw compiler input differs from the retained producer')
    return digest(current)


def resume_785_archives(folder, originals, old_template, old_harness, raw_archives):
    contents, inventories = [], []
    for filename, checksum, size in [('retained-native.zip', LEGACY['digest'], 77022),
                                    ('retained-source.zip', LEGACY['bindingDigest'], 2346935)]:
        raw = raw_archives[filename]
        require(len(raw) == size and digest(raw) == checksum, 'Exact retained archive bytes differ')
        with zipfile.ZipFile(io.BytesIO(raw)) as archive:
            names = archive.namelist()
            require(len(names) == len(set(names)) and archive.testzip() is None
                    and all(not Path(name).is_absolute() and '..' not in Path(name).parts for name in names)
                    and sum(item.file_size for item in archive.infolist()) < 20_000_000,
                    'Retained archive inventory or CRC differs')
            data = {name: archive.read(name) for name in names}
            contents.append(data)
            inventories.append({name: digest(value) for name, value in data.items()})
    native, source = contents
    require(len(native) == 39 and set(source) == {'binding.json', 'original-evidence.zip', 'original-builder.log'},
            'Retained producer archives incomplete')
    prior = json.loads(source['binding.json'])
    require(prior['schema'] == 'nexgenvideo/peer-availability-binding/1'
            and prior['sourceSHA'] == LEGACY['source'] and prior['treeSHA'] == LEGACY['tree']
            and prior['runID'] == str(LEGACY['run']) and prior['attempt'] == '1'
            and prior['sourceFiles'] == {name: digest(value) for name, value in originals.items()}
            and prior['harnessFiles'] == {name: digest(value) for name, value in old_harness.items()}
            and source['original-evidence.zip'] == (folder / 'original-evidence.zip').read_bytes()
            and source['original-builder.log'] == (folder / 'original-builder.log').read_bytes()
            and digest(source['original-evidence.zip']) == DIGEST
            and digest(source['original-builder.log']) == prior['originalFullLogSHA256'] == RAW_DIGEST
            and prior['originalEvidence'] == failure_archive(io.BytesIO(source['original-evidence.zip'])),
            'Retained producer source or original777 bridge differs')
    subset, ranges = source_subset(originals)
    subset['NativeAXPeer.swift'] = originals[PEER]
    fixture, fixture_ranges = fixture_subset(originals[FIXTURE])
    require(old_template.count(b'// NGV_DIAGNOSTIC_FIXTURE') == 1, 'Prior diagnostic fixture marker differs')
    subset['PeerAvailability.swift'] = old_template.replace(b'// NGV_DIAGNOSTIC_FIXTURE', fixture)
    selected = json.loads(native['source-subsets.json'])
    require(selected['ranges'] == json.loads(json.dumps(ranges))
            and selected['fixtureRanges'] == [list(pair) for pair in fixture_ranges]
            and selected['emittedHashes'] == {name: digest(value) for name, value in subset.items()}
            and all(native['sources/' + name] == value for name, value in subset.items())
            and native['support-module/AppKitTestHostSupport.h'] == originals[HEADER]
            and native['support-module/module.modulemap'] == SUPPORT_MODULE,
            'Retained emitted sources, ranges or support module differ')
    git_command = json.loads(native['git-head.process.json'])['command']
    require(len(git_command) == 5 and git_command[:2] == ['git', '-C']
            and git_command[3:] == ['rev-parse', 'HEAD'] and Path(git_command[2]).is_absolute()
            and native['git-head.log'].decode().strip() == LEGACY['source']
            and native['git-tree.log'].decode().strip() == LEGACY['tree']
            and not native['git-status.log'].strip(), 'Prior compiler checkout differs')
    root = Path(git_command[2])
    support_receipt = json.loads(native['compile-support.process.json'])
    output = Path(support_receipt['command'][-1]).parent
    require(output.is_absolute(), 'Prior compiler output path missing')
    include = output / 'support-module'
    parent = support_receipt['parentPID']
    prefix = ['xcrun', 'swiftc', '-swift-version', '6', '-O', '-enable-testing', '-parse-as-library',
              '-target', 'arm64-apple-macos26.0']
    recipes = {
        'support': ['xcrun', 'clang', '-fobjc-arc', '-target', 'arm64-apple-macos26.0', '-I', str(include),
            '-c', str(root / SUPPORT), '-o', str(output / RETAINED['support']['member'])],
        'host': [*prefix, '-I', str(include), str(root / HOST), str(output / RETAINED['support']['member']),
            '-framework', 'AppKit', '-o', str(output / RETAINED['host']['member'])]}
    receipts = {}
    for role in ('support', 'host'):
        receipt = json.loads(native['compile-' + role + '.process.json'])
        retained_process(receipt, recipes[role], native['compile-' + role + '.log'], parent)
        require(receipt['stdoutFile'] == 'compile-' + role + '.log', 'Prior compiler log path differs')
        retained_product(native[RETAINED[role]['member']], RETAINED[role])
        receipts[role] = receipt
    require(receipts['support']['finished'] <= receipts['host']['started']
            and receipts['support']['PID'] != receipts['host']['PID'], 'Prior compiler order differs')
    for name, expected in [('swift', SWIFT_TARGET), ('xcode', 'Xcode 27.2\nBuild version 27B52'),
                           ('os-version', '27.2'), ('os-build', '26B123')]:
        stem = 'toolchain-' + name
        receipt = json.loads(native[stem + '.process.json'])
        require(native[stem + '.log'].decode().strip() == expected and receipt['exitCode'] == 0
                and receipt['timedOut'] is False and receipt['processReaped'] is True
                and receipt['separateStderr'] is True and receipt['parentPID'] == parent
                and receipt['stdoutFile'] == stem + '.log' and receipt['stderrFile'] == stem + '.stderr'
                and receipt['stdoutSHA256'] == digest(native[stem + '.log'])
                and receipt['stderrSHA256'] == digest(native[stem + '.stderr']),
                'Prior compiler toolchain identity differs')
    return {'runID': LEGACY['run'], 'sourceSHA': LEGACY['source'], 'treeSHA': LEGACY['tree'],
        'nativeArtifactID': LEGACY['artifact'], 'nativeArtifactSHA256': LEGACY['digest'],
        'sourceArtifactID': LEGACY['bindingArtifact'], 'sourceArtifactSHA256': LEGACY['bindingDigest'],
        'archiveMemberHashes': inventories, 'compilerReceipts': receipts, 'recipes': recipes,
        'sdkPlatform': native['sdk-platform.log'].decode().strip()}


def resume_archives(folder, originals, old_template, old_harness, legacy_harness):
    contents, inventories = [], []
    for filename, checksum, size in [('retained-native.zip', RESUME_DIGEST, RESUME_BYTES),
                                    ('retained-source.zip', RESUME_BINDING_DIGEST, RESUME_BINDING_BYTES)]:
        raw = (folder / filename).read_bytes()
        require(len(raw) == size and digest(raw) == checksum, 'Exact retained archive bytes differ')
        with zipfile.ZipFile(io.BytesIO(raw)) as archive:
            names = archive.namelist()
            require(len(names) == len(set(names)) and archive.testzip() is None
                    and all(not Path(name).is_absolute() and '..' not in Path(name).parts for name in names)
                    and sum(item.file_size for item in archive.infolist()) < 20_000_000,
                    'Retained archive inventory or CRC differs')
            values = {name: archive.read(name) for name in names}
            contents.append(values)
            inventories.append({name: digest(raw) for name, raw in values.items()})
    native, source = contents
    require(len(native) == 85 and set(source) == {'binding.json', 'original-evidence.zip', 'original-builder.log',
            'retained-native.zip', 'retained-source.zip', 'prior-producer.json'}, 'Exact Native787 archive roles required')
    binding = json.loads(source['binding.json'])
    require(binding['schema'] == 'nexgenvideo/peer-availability-binding/1'
            and binding['sourceSHA'] == RESUME_SOURCE and binding['treeSHA'] == RESUME_TREE
            and binding['runID'] == str(RESUME_RUN) and binding['attempt'] == '1'
            and binding['sourceFiles'] == {name: digest(raw) for name, raw in originals.items()}
            and binding['harnessFiles'] == {name: digest(raw) for name, raw in old_harness.items()}
            and source['original-evidence.zip'] == (folder / 'original-evidence.zip').read_bytes()
            and source['original-builder.log'] == (folder / 'original-builder.log').read_bytes()
            and digest(source['original-evidence.zip']) == DIGEST
            and digest(source['original-builder.log']) == RAW_DIGEST,
            'Exact Native787 source and original777 bridge required')
    nested = {name: source[name] for name in ('retained-native.zip', 'retained-source.zip')}
    require(all(native['prior-producer/' + name] == raw for name, raw in nested.items())
            and native['prior-producer/prior-producer.json'] == source['prior-producer.json'],
            'Nested Native785 archives or producer bytes differ')
    legacy = resume_785_archives(folder, originals,
        legacy_harness['scripts/peer_availability_diagnostic.swift'], legacy_harness, nested)
    old_producer = json.loads(source['prior-producer.json'])
    resume_producer(old_producer['run'], old_producer['jobs'],
        {int(key): value for key, value in old_producer['artifacts'].items()}, legacy=True)
    require(old_producer['provenance'] == binding['priorProducer'] == legacy, 'Nested original785 provenance differs')
    for process in legacy['compilerReceipts'].values():
        retained_job_lifetime(process, old_producer['jobs'], LEGACY['nativeJob'])
    subset, ranges = source_subset(originals)
    subset['NativeAXPeer.swift'] = originals[PEER]
    fixture, fixture_ranges = fixture_subset(originals[FIXTURE])
    require(old_template.count(b'// NGV_DIAGNOSTIC_FIXTURE') == 1, 'Prior diagnostic fixture marker differs')
    subset['PeerAvailability.swift'] = old_template.replace(b'// NGV_DIAGNOSTIC_FIXTURE', fixture)
    selected = json.loads(native['source-subsets.json'])
    require(selected['ranges'] == json.loads(json.dumps(ranges))
            and selected['fixtureRanges'] == [list(pair) for pair in fixture_ranges]
            and selected['emittedHashes'] == {name: digest(raw) for name, raw in subset.items()}
            and all(native['sources/' + name] == raw for name, raw in subset.items())
            and native['support-module/AppKitTestHostSupport.h'] == originals[HEADER]
            and native['support-module/module.modulemap'] == SUPPORT_MODULE,
            'Prior787 emitted or support-module bytes differ')
    current_checkout = json.loads(native['git-head.process.json'])['command']
    require(len(current_checkout) == 5 and current_checkout[:2] == ['git', '-C']
            and current_checkout[3:] == ['rev-parse', 'HEAD'] and Path(current_checkout[2]).is_absolute()
            and native['git-head.log'].decode().strip() == RESUME_SOURCE
            and native['git-tree.log'].decode().strip() == RESUME_TREE and not native['git-status.log'].strip(),
            'Prior787 checkout differs')
    products = json.loads(native['compiler-products.json'])
    require(set(products) == {'host', 'bundle', 'raw'}, 'Prior787 product inventory differs')
    output = Path(products['host']['path']).parent
    require(output.is_absolute(), 'Prior787 product output root missing')
    origins = {}
    for role in ('support', 'host'):
        expected = RETAINED[role]
        raw = native[expected['member']]
        retained_product(raw, expected)
        process = legacy['compilerReceipts'][role]
        origin = {'kind': 'reused-prior-product', 'sourceSHA': LEGACY['source'], 'runID': LEGACY['run'],
            'jobID': LEGACY['nativeJob'], 'artifactID': LEGACY['artifact'], 'artifactSHA256': LEGACY['digest'],
            'recipe': legacy['recipes'][role], 'priorCompilerReceipt': process,
            'originalSourceHashes': binding['sourceFiles'], 'supportModuleSHA256': digest(SUPPORT_MODULE)}
        record = json.loads(native[role + '.product.json'])
        require(record['bytes'] == expected['bytes'] and record['SHA256'] == expected['SHA256']
                and record['path'] == str(output / expected['member']) and record['provenance'] == origin,
                'Retained original785 product record differs')
        if role == 'host':
            require(record['uuid'] == expected['uuid'] == products['host']['uuid'], 'Original Host UUID differs')
        origins[role] = origin
    raw_record = json.loads(native['raw.product.json'])
    raw_process = json.loads(native['compile-raw.process.json'])
    plugin = json.loads(native['macro-plugin.json'])
    recipe = [plugin['compiler'], '-swift-version', '6', '-O', '-enable-testing', '-parse-as-library', '-target',
        'arm64-apple-macos26.0', str(output / 'sources/NativeAXPeer.swift'),
        str(output / 'sources/NativeButtonAccessibility.swift'),
        str(Path(current_checkout[2]) / 'scripts/peer_availability_raw.swift'), '-o', str(output / REUSED_RAW['member'])]
    original_controller = json.loads(native['git-head.process.json'])['parentPID']
    retained_process(raw_process, recipe, native['compile-raw.log'], original_controller)
    require(raw_process['stdoutFile'] == 'compile-raw.log', 'Original Raw compiler log path differs')
    raw_hashes = {'NativeAXPeer.swift': digest(originals[PEER]),
        'NativeButtonAccessibility.swift': digest(originals[QUERY]),
        'peer_availability_raw.swift': retained_raw_source((ROOT / 'scripts/peer_availability_raw.swift').read_bytes(),
            old_harness['scripts/peer_availability_raw.swift'])}
    require(raw_record['provenance'] == {'kind': 'current-compilation', 'sourceSHA': RESUME_SOURCE,
            'runID': str(RESUME_RUN), 'compilerReceipt': raw_process, 'sourceHashes': raw_hashes}
            and raw_record['bytes'] == REUSED_RAW['bytes'] and raw_record['SHA256'] == REUSED_RAW['SHA256']
            and raw_record['uuid'] == REUSED_RAW['uuid'] == products['raw']['uuid']
            and raw_record['path'] == products['raw']['path'] == str(output / REUSED_RAW['member'])
            and plugin['metadataProcess'] == json.loads(native['compiler-target-info.process.json'])
            and plugin['targetMetadata'] == json.loads(native['compiler-target-info.log'])
            and plugin['metadataProcess']['parentPID'] == original_controller
            and plugin['metadataProcess']['finished'] <= raw_process['started']
            and native['selected-compiler.log'].decode().strip() == plugin['compiler'],
            'Original Raw compile provenance or actual compiler metadata differs')
    retained_product(native[REUSED_RAW['member']], REUSED_RAW)
    for name, expected in [('swift', SWIFT_TARGET), ('selected-swiftc', SWIFT_TARGET),
                           ('xcode', 'Xcode 27.2\nBuild version 27B52'), ('os-version', '27.2'), ('os-build', '26B123')]:
        stem = 'toolchain-' + name
        process = json.loads(native[stem + '.process.json'])
        require(native[stem + '.log'].decode().strip() == expected and process['exitCode'] == 0
                and process['processReaped'] is True and process['timedOut'] is False
                and process['parentPID'] == raw_process['parentPID'] and process['separateStderr'] is True
                and process['stdoutSHA256'] == digest(native[stem + '.log'])
                and process['stderrSHA256'] == digest(native[stem + '.stderr']),
                'Original787 compiler identity differs')
    origins['raw'] = {'kind': 'reused-prior-product', 'sourceSHA': RESUME_SOURCE, 'runID': RESUME_RUN,
        'jobID': RESUME_JOB, 'artifactID': RESUME_ARTIFACT, 'artifactSHA256': RESUME_DIGEST,
        'recipe': recipe, 'priorCompilerReceipt': raw_process, 'sourceHashes': raw_hashes}
    return {'runID': RESUME_RUN, 'sourceSHA': RESUME_SOURCE, 'treeSHA': RESUME_TREE,
        'nativeArtifactID': RESUME_ARTIFACT, 'nativeArtifactSHA256': RESUME_DIGEST,
        'sourceArtifactID': RESUME_BINDING_ARTIFACT, 'sourceArtifactSHA256': RESUME_BINDING_DIGEST,
        'archiveMemberHashes': inventories, 'legacyProducer': legacy, 'productOrigins': origins,
        'sdkPlatform': native['sdk-platform.log'].decode().strip(),
        'compilerSHA256': plugin['compilerSHA256'], 'pluginSHA256': plugin['pluginSHA256']}


def resume_producer(run, jobs, artifacts, legacy=False):
    spec = LEGACY if legacy else CURRENT_RESUME
    def timestamp(value):
        require(isinstance(value, str) and re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', value),
                'Retained producer timestamp missing or malformed')
        return datetime.strptime(value, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)

    require(run['id'] == spec['run'] and run['head_sha'] == spec['source'] and run['run_attempt'] == 1
            and run['repository']['full_name'] == 'iret77/nexgenvideo' and run['actor']['login'] == 'iret77'
            and run['workflow_id'] == 355242770 and run['path'] == '.github/workflows/diagnostic-acceptance.yml'
            and run['event'] == 'workflow_dispatch' and run['status'] == 'completed'
            and run['conclusion'] == 'failure', 'Exact retained Native787 producer required')
    require(jobs['total_count'] == len(jobs['jobs']), 'Retained producer jobs incomplete')
    windows = {}
    observed = datetime.now(timezone.utc)
    for identity, name, conclusion, labels in [(spec['sourceJob'], 'source', 'success', ['ubuntu-24.04']),
                                               (spec['nativeJob'], KIND, 'failure', ['macrunner'])]:
        selected = [job for job in jobs['jobs'] if job['id'] == identity]
        require(len(selected) == 1, 'Retained producer job missing')
        job = selected[0]
        require(job['run_id'] == spec['run'] and job['head_sha'] == spec['source'] and job['run_attempt'] == 1
                and job['name'] == name and job['labels'] == labels and job['status'] == 'completed'
                and job['conclusion'] == conclusion, 'Retained producer job differs')
        started, completed = timestamp(job.get('started_at')), timestamp(job.get('completed_at'))
        require(started < completed <= observed, 'Retained producer job lifetime differs')
        windows[identity] = (started, completed)
    require(windows[spec['sourceJob']][1] <= windows[spec['nativeJob']][0], 'Retained producer job order differs')
    require(set(artifacts) == {spec['artifact'], spec['bindingArtifact']}, 'Retained artifacts incomplete')
    for identity, name, checksum, size in [
            (spec['artifact'], KIND + '-' + str(spec['run']) + '-a1', spec['digest'], spec['bytes']),
            (spec['bindingArtifact'], KIND + '-source-binding', spec['bindingDigest'], spec['bindingBytes'])]:
        value = artifacts[identity]
        created, updated, expires = (timestamp(value.get(key)) for key in ('created_at', 'updated_at', 'expires_at'))
        started, completed = windows[spec['nativeJob'] if identity == spec['artifact'] else spec['sourceJob']]
        require(started <= created <= updated <= completed and updated < expires and expires > observed,
                'Retained artifact lies outside its producer job lifetime')
        require(value['id'] == identity and value['name'] == name and value['digest'] == 'sha256:' + checksum
                and value['size_in_bytes'] == size and value['expired'] is False
                and value['workflow_run']['id'] == spec['run']
                and value['workflow_run']['head_sha'] == spec['source'], 'Retained producer artifact differs')


def plugin_metadata(raw, compiler):
    def unique(pairs):
        value = {}
        for key, item in pairs:
            require(key not in value, 'Duplicate compiler metadata field')
            value[key] = item
        return value

    value = json.loads(raw, object_pairs_hook=unique,
        parse_constant=lambda _: require(False, 'Nonfinite compiler metadata'))
    require(isinstance(value, dict) and value.get('compilerVersion') == SWIFT_VERSION
            and isinstance(value.get('target'), dict) and isinstance(value.get('paths'), dict),
            'Compiler target metadata incomplete')
    triple = value['target'].get('triple')
    resource = value['paths'].get('runtimeResourcePath')
    require(isinstance(triple, str) and re.fullmatch(r'arm64-apple-macosx?26(?:\.0){0,2}', triple)
            and isinstance(resource, str) and resource and '\x00' not in resource,
            'Compiler metadata target or resource path differs')
    require(compiler.is_absolute() and compiler.name == 'swiftc' and compiler.is_file(),
            'Selected compiler path differs')
    bin_path = compiler.parent.resolve(strict=True)
    resolved_compiler = compiler.resolve(strict=True)
    require(bin_path.name == 'bin' and bin_path.parent.name == 'usr'
            and resolved_compiler.parent == bin_path, 'Selected compiler escapes its toolchain')
    expected = bin_path.parent / 'lib/swift'
    path = Path(resource)
    require(path.is_absolute() and path == expected and path.resolve(strict=True) == expected,
            'Compiler resource path escapes selected toolchain')
    directory = path / 'host/plugins/testing'
    library = directory / 'libTestingMacros.dylib'
    require(directory.is_dir() and directory.resolve(strict=True) == directory
            and library.is_file() and library.resolve(strict=True) == library,
            'Unique selected-toolchain TestingMacros library missing or escaped')
    require(library.stat().st_size > 0, 'Selected TestingMacros library empty')
    return {'compiler': str(compiler), 'resolvedCompiler': str(resolved_compiler),
        'compilerSHA256': digest(resolved_compiler.read_bytes()), 'targetMetadata': value,
        'pluginDirectory': str(directory), 'pluginLibrary': str(library),
        'pluginSHA256': digest(library.read_bytes())}


def product_record(folder, role, path, provenance):
    value = {'path': str(path.resolve()), 'bytes': path.stat().st_size, 'SHA256': digest(path.read_bytes()),
        'provenance': provenance}
    if role != 'support':
        value['uuid'] = macho_uuid(path)
    write(folder / (role + '.product.json'), value)
    return value


def bind(args):
    env = os.environ
    validate_inputs(env)
    require(env['GITHUB_ACTIONS'] == 'true' and env['GITHUB_REPOSITORY'] == 'iret77/nexgenvideo'
            and env['GITHUB_RUN_ATTEMPT'] == '1', 'First repository CI attempt required')
    require(git('rev-parse', 'HEAD').decode().strip() == env['GITHUB_SHA']
            and not git('status', '--porcelain', '--untracked-files=no').strip(), 'Current source changed')
    git('merge-base', '--is-ancestor', SOURCE, env['GITHUB_SHA'])
    validate_changed_paths(git('diff', '--no-renames', '--name-only', SOURCE, env['GITHUB_SHA']).decode().splitlines())
    proof = json.loads((args.source_proof / 'receipt.json').read_text())
    require(proof['schema'] == 'core-pr-source-composition/v1' and proof['sourceSHA'] == env['GITHUB_SHA']
            and proof['runID'] == env['GITHUB_RUN_ID'] and proof['attempt'] == '1'
            and proof['originalRun']['id'] == int(env['VERIFIED_PR']), 'Current Source proof differs')
    sys.path.insert(0, str(ROOT / 'scripts/external-gui'))
    import test_bundle
    run = test_bundle.api('/actions/runs/' + str(RUN))
    jobs = test_bundle.api('/actions/runs/' + str(RUN) + '/jobs?per_page=100')
    artifact = test_bundle.api('/actions/artifacts/' + str(ARTIFACT))
    require(run['id'] == RUN and run['head_sha'] == SOURCE and run['run_attempt'] == 1
            and run['repository']['full_name'] == 'iret77/nexgenvideo' and run['actor']['login'] == 'iret77'
            and run['path'] == '.github/workflows/release.yml' and run['event'] == 'workflow_dispatch'
            and run['status'] == 'completed' and run['conclusion'] == 'failure', 'Original producer differs')
    require(jobs['total_count'] == len(jobs['jobs']), 'Original jobs incomplete')
    selected = [job for job in jobs['jobs'] if job['id'] == JOB]
    require(len(selected) == 1, 'Original builder missing')
    job = selected[0]
    require(job['run_id'] == RUN and job['head_sha'] == SOURCE and job['run_attempt'] == 1
            and job['name'] == 'release-build' and job['labels'] == ['macrunner']
            and job['status'] == 'completed' and job['conclusion'] == 'failure', 'Original builder differs')
    steps = {step['name']: step['conclusion'] for step in job['steps']}
    require(steps.get('Build the exact release test configuration') == 'success'
            and steps.get('Test the exact release configuration') == 'failure', 'Original compile/test differs')
    require(artifact['id'] == ARTIFACT and artifact['name'] == 'release-test-evidence'
            and artifact['digest'] == 'sha256:' + DIGEST and artifact['expired'] is False
            and artifact['workflow_run']['id'] == RUN and artifact['workflow_run']['head_sha'] == SOURCE,
            'Original artifact differs')
    args.evidence.mkdir(parents=True, exist_ok=False)
    original = args.evidence / 'original-evidence.zip'
    test_bundle.download(artifact, original)
    require(original.stat().st_size == artifact['size_in_bytes'] and digest(original.read_bytes()) == DIGEST,
            'Original archive bytes changed')
    observed = failure_archive(original)
    from verified_pr_source_checks import read_api
    raw = read_api('actions/jobs/' + str(JOB) + '/logs', maximum=8_000_000)
    require(digest(raw) == RAW_DIGEST, 'Original full builder log differs')
    (args.evidence / 'original-builder.log').write_bytes(raw)
    files = {name: git('show', SOURCE + ':' + name) for name in FILES}
    require(all((ROOT / name).read_bytes() == raw for name, raw in files.items()), 'Original sources changed')
    resume_run = test_bundle.api('/actions/runs/' + str(RESUME_RUN))
    resume_jobs = test_bundle.api('/actions/runs/' + str(RESUME_RUN) + '/jobs?per_page=100')
    artifacts = {identity: test_bundle.api('/actions/artifacts/' + str(identity))
                 for identity in (RESUME_ARTIFACT, RESUME_BINDING_ARTIFACT)}
    resume_producer(resume_run, resume_jobs, artifacts)
    for identity, filename in [(RESUME_ARTIFACT, 'retained-native.zip'),
                               (RESUME_BINDING_ARTIFACT, 'retained-source.zip')]:
        test_bundle.download(artifacts[identity], args.evidence / filename)
    old_harness = {name: git('show', RESUME_SOURCE + ':' + name) for name in HARNESS}
    legacy_harness = {name: git('show', LEGACY['source'] + ':' + name) for name in HARNESS}
    prior = resume_archives(args.evidence, files, old_harness['scripts/peer_availability_diagnostic.swift'],
        old_harness, legacy_harness)
    retained_job_lifetime(prior['productOrigins']['raw']['priorCompilerReceipt'], resume_jobs, RESUME_JOB)
    write(args.evidence / 'prior-producer.json', {'provenance': prior, 'run': resume_run, 'jobs': resume_jobs,
        'artifacts': {str(key): value for key, value in artifacts.items()}})
    write(args.evidence / 'binding.json', {'schema': 'nexgenvideo/peer-availability-binding/1',
        'sourceSHA': env['GITHUB_SHA'], 'treeSHA': git('rev-parse', 'HEAD^{tree}').decode().strip(),
        'runID': env['GITHUB_RUN_ID'], 'attempt': '1', 'originalRun': run, 'originalJob': job,
        'originalArtifact': artifact, 'originalEvidence': observed, 'sourceProof': proof,
        'originalFullLogSHA256': RAW_DIGEST,
        'priorProducer': prior,
        'sourceFiles': {name: digest(raw) for name, raw in files.items()},
        'harnessFiles': {name: digest((ROOT / name).read_bytes()) for name in sorted(HARNESS)},
        'appAcceptance': False, 'appBuilds': 0, 'nativeRegressionSuiteRepeats': 0,
        'diagnosticFunctionExecutionsExpected': 2})


def command_timeout(deadline, now):
    remaining = deadline - now - 10
    require(remaining > 0, 'Absolute diagnostic deadline reached; reserve cleanup and upload time')
    return min(70, remaining)


def valid_frame(value):
    return isinstance(value, list) and len(value) == 4 and all(
        type(item) in (int, float) and math.isfinite(item) for item in value) and value[2] > 0 and value[3] > 0


def same_frame(actual, expected):
    return valid_frame(actual) and valid_frame(expected) and all(abs(a - b) <= 0.5 for a, b in zip(actual, expected))


def raw_window_bound(observed, request):
    if not all(window.get('PID') == request['PID'] and window.get('PIDStatus') == 0
               and window.get('role') == 'AXWindow' and valid_frame(window.get('frame'))
               for window in observed['windows']):
        return False
    candidates = [window for window in observed['windows'] if window.get('PID') == request['PID']
        and window.get('PIDStatus') == 0 and window.get('role') == 'AXWindow'
        and window.get('matchesRequestedFrame') is True and same_frame(window.get('frame'), request['windowFrame'])]
    cg = []
    for window in observed['CGWindows']:
        bounds = window.get('bounds')
        frame = [bounds.get(key) for key in ('X', 'Y', 'Width', 'Height')] if isinstance(bounds, dict) else None
        if window.get('PID') != request['PID'] or type(window.get('number')) is not int or window['number'] <= 0 \
                or window.get('onscreen') is not True or not valid_frame(frame):
            return False
        if same_frame(frame, request['windowFrame']):
            cg.append(window)
    if len(candidates) != 1 or len(cg) != 1 or cg[0]['number'] != request['windowNumber']:
        return False
    frame = [cg[0]['bounds'].get(key) for key in ('X', 'Y', 'Width', 'Height')]
    return same_frame(frame, request['windowFrame'])


def macho_uuid(path):
    return macho_uuid_data(path.read_bytes())


def macho_uuid_data(raw):
    require(len(raw) >= 32, 'Mach-O header missing')
    magic, cpu, _, _, count, size, _, _ = struct.unpack_from('<8I', raw)
    require(magic == 0xfeedfacf and cpu == 0x0100000c and 0 < count <= 4096
            and 32 + size <= len(raw), 'Actual Mach-O architecture or commands differ')
    offset, found = 32, []
    for _ in range(count):
        require(offset + 8 <= 32 + size, 'Mach-O command header truncated')
        command, length = struct.unpack_from('<II', raw, offset)
        require(length >= 8 and offset + length <= 32 + size, 'Mach-O command truncated')
        if command == 0x1b:
            require(length == 24, 'Mach-O UUID size differs')
            found.append(raw[offset + 8:offset + 24].hex())
        offset += length
    require(offset == 32 + size and len(found) == 1 and found[0] != '0' * 32, 'Mach-O UUID missing or ambiguous')
    return found[0]


def verify_cg_samples(value):
    samples = value['preAXCGStability']['samples']
    require(isinstance(samples, list) and 2 <= len(samples) <= 50, 'Two actual CG stability samples required')
    previous = None
    for sample in samples:
        require(type(sample['at']) in (int, float) and math.isfinite(sample['at'])
                and (previous is None or sample['at'] > previous), 'CG sample times differ')
        previous = sample['at']
    for sample in samples[-2:]:
        request, windows = sample['request'], sample['windows']
        require(request == value['requestBefore'] and valid_frame(request['windowFrame'])
                and valid_frame(request['contentFrame']) and type(request['windowNumber']) is int
                and request['windowNumber'] > 0 and request['PID'] == value['PID'] and windows,
                'Actual stable NS request differs')
        require(all(window['pid'] == value['PID'] and type(window['number']) is int and window['number'] > 0
                    and window['onscreen'] is True and valid_frame(window['frame']) for window in windows),
                'CG stability inventory is unreadable')
        candidates = [window for window in windows if same_frame(window['frame'], request['windowFrame'])]
        require(len(candidates) == 1 and candidates[0]['number'] == request['windowNumber'], 'CG window not uniquely bound')
    require(samples[-1]['at'] <= value['firstPeer']['before']['at'], 'CG samples occur after first Peer started')


class Controller:
    def __init__(self, evidence):
        self.evidence = evidence
        self.deadline = time.monotonic() + 210

    def run(self, command, name, env=None, *, separate_stderr=False):
        limit = command_timeout(self.deadline, time.monotonic())
        path = self.evidence / (name + '.log')
        error_path = self.evidence / (name + '.stderr') if separate_stderr else None
        started = time.monotonic()
        started_wall = time.time()
        with ExitStack() as outputs:
            stream = outputs.enter_context(path.open('xb'))
            errors = outputs.enter_context(error_path.open('xb')) if error_path else None
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=stream,
                stderr=errors if separate_stderr else subprocess.STDOUT, env=env, start_new_session=True)
            timed_out = False
            try:
                code = process.wait(timeout=limit)
            except subprocess.TimeoutExpired:
                timed_out = True
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    code = process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    try:
                        code = process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        code = None
            stream.flush()
            os.fsync(stream.fileno())
            if errors:
                errors.flush()
                os.fsync(errors.fileno())
        value = {'command': command, 'PID': process.pid, 'exitCode': code, 'timedOut': timed_out,
            'parentPID': os.getpid(), 'startedWall': started_wall, 'finishedWall': time.time(),
            'processReaped': process.poll() is not None, 'started': started, 'finished': time.monotonic(), 'timeout': limit,
            'separateStderr': separate_stderr, 'stdoutFile': path.name, 'stdoutSHA256': digest(path.read_bytes()),
            'stderrFile': error_path.name if error_path else None,
            'stderrSHA256': digest(error_path.read_bytes()) if error_path else None}
        write(self.evidence / (name + '.process.json'), value)
        require(value['processReaped'] and not timed_out and code == 0,
                'Owned diagnostic command failed; original evidence retained')
        return value

    def identity(self, command, name, expected):
        result = self.run(command, 'toolchain-' + name, separate_stderr=True)
        require((self.evidence / result['stdoutFile']).read_text().strip() == expected,
                'Actual native toolchain differs from Native777: ' + name)
        return result


def verify_serialization_artifacts(folder, report, source):
    probe = folder / 'serialization-probes'
    rejected_names = {'rejected': 'unsupported-value', 'nonfinite': 'nonfinite-number',
        'non-string-key': 'non-string-key', 'cycle': 'container-cycle', 'depth': 'validation-budget'}
    require({path.name for path in probe.iterdir()} == {'valid.json'} | {
        name + '.serialization-error.json' for name in rejected_names},
            'Exact native serializer probe evidence required')
    valid = json.loads((probe / 'valid.json').read_text())
    require(set(valid) == {'mode', 'absentMode'} and valid['absentMode'] is None
            and isinstance(valid['mode'], (str, type(None))), 'Native mode/null round trip differs')
    rejected = json.loads((probe / 'rejected.serialization-error.json').read_text())
    require(rejected['schema'] == 'nexgenvideo/availability-json-error/1' and rejected['expectedProbe'] is True
            and rejected['stage'] == 'rejected' and rejected['context'] == report['context']
            and rejected['sourceSHA'] == source and rejected['PID'] == report['PID']
            and rejected['failure']['reason'] == 'unsupported-value'
            and rejected['failure']['path'] == [{'key': {'_0': 'nested'}}, {'index': {'_0': 0}}, {'key': {'_0': 'value'}}]
            and isinstance(rejected['failure']['runtimeType'], str)
            and 'AvailabilityUnsupportedProbe' in rejected['failure']['runtimeType'],
            'Real native unsupported-value rejection differs')
    errors = list(folder.rglob('*.serialization-error.json'))
    require(set(errors) == {probe / (name + '.serialization-error.json') for name in rejected_names},
            'Unexpected real serialization failure retained')
    for name, reason in rejected_names.items():
        item = json.loads((probe / (name + '.serialization-error.json')).read_text())
        require(item['schema'] == 'nexgenvideo/availability-json-error/1' and item['expectedProbe'] is True
                and item['stage'] == name and item['context'] == report['context']
                and item['sourceSHA'] == source and item['PID'] == report['PID']
                and item['failure']['reason'] == reason and item['failure']['path']
                and isinstance(item['failure']['runtimeType'], str) and item['failure']['runtimeType'],
                'Native rejection guard evidence differs: ' + name)
    names = ['launch-owner', 'cg', 'first-peer', 'raw-background-0.15', 'raw-main-0.15', 'raw-background-1']
    stages = folder / 'stages'
    require({path.name for path in stages.iterdir()} == {name + '.json' for name in names},
            'Required independent stage retention incomplete')
    for index, name in enumerate(names):
        stage = json.loads((stages / (name + '.json')).read_text())
        facts = stage['facts']
        require(stage['schema'] == 'nexgenvideo/availability-stage/1' and stage['stage'] == name
                and stage['sourceSHA'] == source and stage['PID'] == report['PID']
                and stage['context'] == report['context']
                and facts['PID'] == report['PID'] and facts['context'] == report['context']
                and all(facts[key] == report[key] for key in ('owner', 'hostImage', 'image', 'initialRequest')),
                'Stage owner/image/window identity differs')
        if index >= 1:
            require(facts['preAXCGStability'] == report['preAXCGStability'], 'Retained CG stage differs')
        if index >= 2:
            require(facts['firstPeer'] == report['firstPeer'], 'Retained first-Peer stage differs')
        if index >= 3:
            require(facts['rawAfterPeer'] == report['rawAfterPeer'][:index - 2], 'Retained incremental Raw stage differs')


def verify_collection(folder, context, execution):
    value = json.loads((folder / 'observation.json').read_text())
    require(value['schema'] == 'nexgenvideo/peer-availability-observation/1'
            and value['context'] == context and value['collectionCompleted'] is True
            and value['appAcceptance'] is False and value['originalFullAppImage'] is False
            and value['diagnosticFunctionExecutions'] == 1, 'Incomplete diagnostic collection')
    process, products, source = execution['process'], execution['products'], execution['sourceSHA']
    verify_serialization_artifacts(folder, value, source)
    require(set(products) == {'host', 'bundle', 'raw'} and len({item['path'] for item in products.values()}) == 3
            and re.fullmatch('[a-f0-9]{40}', source), 'Actual compiler product or Source identity missing')
    require(type(process['PID']) is int and process['PID'] > 1
            and process['PID'] == value['PID'] and process['parentPID'] == value['parentPID']
            and process['processReaped'] is True and process['exitCode'] == 0 and process['timedOut'] is False
            and process['startedWall'] <= value['startedWall'] <= value['finishedWall'] <= process['finishedWall'],
            'Observation is not bound to the actual started Host process')
    for item in products.values():
        require(digest(Path(item['path']).read_bytes()) == item['SHA256']
                and macho_uuid(Path(item['path'])) == item['uuid'], 'Retained compiler product changed')
    require(process['command'] == [products['host']['path'], '--event-stream-version', '0']
            and value['owner']['PID'] == value['PID'] and value['owner']['executable'] == products['host']['path']
            and type(value['owner']['start']) is int and value['owner']['start'] > 0
            and value['image'] == {'path': products['bundle']['path'], 'uuid': products['bundle']['uuid'],
                                  'SHA256': products['bundle']['SHA256']}
            and value['hostImage'] == {'path': products['host']['path'], 'uuid': products['host']['uuid'],
                                      'SHA256': products['host']['SHA256']}, 'Actual Host or loaded image differs')
    launch = value['launch']
    require(launch['class'] == 'NGVTestRuntimeApplication' and launch['isRunning'] is True
            and type(launch['isFinishedLaunching']) is bool and type(launch['initialPolicy']) is int
            and type(launch['actualPolicy']) is int and isinstance(launch['bundleURL'], str)
            and isinstance(launch['runLoopMode'], (str, type(None))), 'Actual launch metadata incomplete')
    peer = value['firstPeer']
    require(value['requestBefore'] == value['requestAfterPeer'], 'Target geometry changed during the first Peer query')
    snapshot = peer['snapshot']
    reader = snapshot['reader']
    require(reader['ownerPID'] == value['PID'] and reader['ownerStart'] == value['owner']['start']
            and reader['AXTrusted'] is True
            and snapshot['pid'] == value['PID'] and reader['readerPID'] != value['PID']
            and snapshot['expectedWindowFrame'] == value['requestBefore']['windowFrame']
            and snapshot['contentFrame'] == value['requestBefore']['contentFrame'], 'Peer target identity differs')
    require(peer['before']['at'] <= snapshot['startedUptime'] <= snapshot['finishedUptime'] <= peer['after']['at'],
            'First Peer timing lies outside its recorded heartbeat interval')
    require(value['preAXCGStability']['qualified'] is True and value['heartbeat']['truncated'] is False
            and isinstance(value['heartbeat']['timeline'], list), 'CG or heartbeat collection incomplete')
    ticks = value['heartbeat']['timeline']
    heartbeat = value['heartbeat']
    verify_cg_samples(value)
    require(heartbeat['observerValid'] is True and heartbeat['observerOnMainCommonModes'] is True
            and heartbeat['installedAt'] <= value['preAXCGStability']['samples'][0]['at']
            and heartbeat['recordedAt'] >= peer['after']['at'] and ticks,
            'Actual observer installation or tick collection missing')
    require(all(type(tick['at']) in (int, float) and math.isfinite(tick['at'])
                and type(tick['mainThread']) is bool and isinstance(tick['mode'], str)
                and tick['kind'] in ('runLoop', 'dispatch') for tick in ticks)
            and [tick['at'] for tick in ticks] == sorted(tick['at'] for tick in ticks)
            and all(heartbeat['installedAt'] <= tick['at'] <= heartbeat['recordedAt'] for tick in ticks),
            'Heartbeat timeline invalid')
    require(reader['image'] == products['bundle']['path'] and reader['imageSHA256'] == products['bundle']['SHA256']
            and reader['imageUUID'] == products['bundle']['uuid'], 'Peer did not execute the actual diagnostic bundle')
    lifecycle = peer['lifecycle']
    require(lifecycle['pid'] == reader['readerPID'] and lifecycle['processReaped']
            and lifecycle['exitStatus'] == 0 and not lifecycle['forced']
            and lifecycle['stdoutClosed'] and lifecycle['stderrClosed'] and lifecycle['protocolClean'],
            'Peer did not close cleanly')
    raw = value['rawAfterPeer']
    comparisons = []
    require([(item['context'], item['seconds']) for item in raw] == [
        ('background', '0.15'), ('main', '0.15'), ('background', '1')], 'Raw measurement order changed')
    require(heartbeat['recordedAt'] >= raw[-1]['after']['at'], 'Heartbeat evidence ended before the last raw observation')
    for item in raw:
        require(item['kind'] == 'raw-after-peer' and item['primedContext'] is True
                and item['before']['at'] >= peer['after']['at'] and item['reaped'] is True
                and item['timedOut'] is False and item['cancelled'] is False
                and item['exitStatus'] == 0, 'Raw process lifetime differs')
        stem = item['context'] + '-' + item['seconds']
        require(item['stdout'] == stem + '.stdout' and item['stderr'] == stem + '.stderr',
                'Raw evidence path differs')
        require((folder / item['stderr']).is_file(), 'Raw stderr capture missing')
        lines = (folder / item['stdout']).read_bytes().split(b'\n')
        require(len(lines) == 2 and lines[-1] == b'', 'Raw output must be exactly one complete JSON frame')
        observed = json.loads(lines[0])
        require(observed['schema'] == 'nexgenvideo/peer-availability-raw/1'
                and observed['targetPID'] == value['PID'] and observed['parentPID'] == value['PID']
                and observed['readerPID'] == item['PID'] and observed['context'] == item['context']
                and observed['mainThread'] == (item['context'] == 'main'), 'Raw target or thread differs')
        require(observed['ownerStart'] == reader['ownerStart']
                and type(observed['readerStart']) is int and observed['readerStart'] > 0
                and observed['requestedWindow'] == value['requestBefore']['windowNumber']
                and observed['requestedFrame'] == value['requestBefore']['windowFrame']
                and type(observed['AXTrustedBefore']) is bool and type(observed['AXTrustedAfter']) is bool
                and observed['AXTrusted'] == (observed['AXTrustedBefore'] and observed['AXTrustedAfter']),
                'Raw kernel identity, target window or trust interval differs')
        require(observed['readerExecutable'] == observed['imagePath'] == products['raw']['path']
                and observed['imageSHA256'] == products['raw']['SHA256']
                and observed['imageUUID'] == products['raw']['uuid'], 'Raw actual image differs')
        require(observed['ownerExecutable'] == products['host']['path']
                and observed['ownerSHA256'] == products['host']['SHA256'], 'Raw target executable differs')
        require(type(observed['AXTrusted']) is bool and type(observed['AXWindowsStatus']) is int
                and type(observed['timeoutStatus']) is int
                and abs(observed['seconds'] - float(item['seconds'])) < 0.0000001
                and all(type(observed[key]) in (int, float) and math.isfinite(observed[key])
                        for key in ('started', 'finished'))
                and item['before']['at'] <= observed['started'] <= observed['finished'] <= item['after']['at'],
                'Raw timing or AX status evidence differs')
        call = observed['AXWindowsCall']
        require(call['attribute'] == 'AXWindows' and call['status'] == observed['AXWindowsStatus']
                and call['timeoutStatus'] == observed['timeoutStatus']
                and observed['started'] <= call['started'] <= call['finished'] <= observed['finished'],
                'Actual AXWindows call interval differs')
        comparisons.append({'context': item['context'], 'seconds': item['seconds'],
            'status': ('UNQUALIFIED_RAW_CLIENT_TRUST' if not observed['AXTrusted'] else
                'WINDOW_BOUND_OBSERVATION_ONLY' if observed['AXWindowsStatus'] == 0
                and raw_window_bound(observed, value['requestBefore']) else 'APP_AX_AVAILABILITY_ONLY'),
            'rawCallsFollowPeerAndMayPrimeAX': True, 'appAcceptance': False})
    events = [json.loads(line) for line in (folder / 'events.jsonl').read_bytes().split(b'\n') if line]
    functions = {event['payload']['id'] for event in events
                 if event['kind'] == 'test' and event['payload']['kind'] == 'function'}
    kinds = Counter(event['payload']['kind'] for event in events if event['kind'] == 'event')
    started = [event['payload']['testID'] for event in events if event['kind'] == 'event'
               and event['payload']['kind'] == 'testStarted' and event['payload'].get('testID') in functions]
    ended = [event['payload']['testID'] for event in events if event['kind'] == 'event'
             and event['payload']['kind'] == 'testEnded' and event['payload'].get('testID') in functions]
    require(len(functions) == 1 and started == ended and len(started) == 1
            and kinds['runStarted'] == kinds['runEnded'] == 1
            and not any(kinds[key] for key in ('testSkipped', 'issueRecorded', 'testCancelled', 'testCaseCancelled')),
            'Expected exactly one completed new diagnostic function')
    host = json.loads((folder / 'host-receipt.json').read_text())
    require(host['pid'] == value['PID'] and host['started'] and host['completed'] and host['abiSucceeded']
            and host['runReturnedAfterCompletion'] and host['applicationRunningAtStart']
            and host['mainThread'] is True and host['sourceSHA'] == source
            and host['parentPID'] == process['parentPID'] and host['hostExecutable'] == products['host']['path']
            and host['bundleBinary'] == products['bundle']['path']
            and host['eventRecordCount'] == len(events), 'Actual host completion receipt differs')
    value['rawComparisons'] = comparisons
    value['contextComparison'] = ('UNQUALIFIED_REGULAR_POLICY_CHANGE' if context == 'regular'
        and (value.get('setRegularSucceeded') is not True or value['launch']['actualPolicy'] != 0)
        else 'OBSERVATION_ONLY')
    return value


def observe(args):
    require(os.environ['GITHUB_ACTIONS'] == 'true' and os.environ['GITHUB_REPOSITORY'] == 'iret77/nexgenvideo'
            and os.environ['GITHUB_RUN_ATTEMPT'] == '1' and sys.platform == 'darwin', 'Use first macrunner CI attempt')
    args.evidence.mkdir(parents=True, exist_ok=False)
    controller = Controller(args.evidence)
    current = {}
    for name, command in [('tree', ['rev-parse', 'HEAD^{tree}']), ('head', ['rev-parse', 'HEAD']),
                          ('status', ['status', '--porcelain', '--untracked-files=no'])]:
        controller.run(['git', '-C', str(ROOT), *command], 'git-' + name)
        current[name] = (args.evidence / ('git-' + name + '.log')).read_text().strip()
    binding = json.loads((args.binding / 'binding.json').read_text())
    require(binding['schema'] == 'nexgenvideo/peer-availability-binding/1'
            and binding['sourceSHA'] == os.environ['GITHUB_SHA'] and binding['runID'] == os.environ['GITHUB_RUN_ID']
            and binding['attempt'] == '1' and binding['treeSHA'] == current['tree']
            and current['head'] == os.environ['GITHUB_SHA'] and not current['status'], 'Transferred source binding differs')
    require(set(binding['sourceFiles']) == set(FILES) and set(binding['harnessFiles']) == HARNESS
            and all(digest((ROOT / name).read_bytes()) == checksum
                    for name, checksum in {**binding['sourceFiles'], **binding['harnessFiles']}.items()),
            'Transferred framework or harness bytes changed')
    original = args.binding / 'original-evidence.zip'
    require(digest(original.read_bytes()) == DIGEST and failure_archive(original) == binding['originalEvidence'],
            'Transferred original evidence differs')
    require(binding['originalFullLogSHA256'] == RAW_DIGEST
            and digest((args.binding / 'original-builder.log').read_bytes()) == RAW_DIGEST,
            'Transferred full original builder log differs')
    originals = {name: (ROOT / name).read_bytes() for name in FILES}
    old_harness = {}
    for index, name in enumerate(sorted(HARNESS)):
        result = controller.run(['git', '-C', str(ROOT), 'show', RESUME_SOURCE + ':' + name],
            'prior-harness-' + str(index))
        old_harness[name] = (args.evidence / result['stdoutFile']).read_bytes()
    legacy_harness = {}
    for index, name in enumerate(sorted(HARNESS)):
        result = controller.run(['git', '-C', str(ROOT), 'show', LEGACY['source'] + ':' + name],
            'legacy-harness-' + str(index))
        legacy_harness[name] = (args.evidence / result['stdoutFile']).read_bytes()
    prior = resume_archives(args.binding, originals, old_harness['scripts/peer_availability_diagnostic.swift'],
        old_harness, legacy_harness)
    transferred = json.loads((args.binding / 'prior-producer.json').read_text())
    resume_producer(transferred['run'], transferred['jobs'],
        {int(key): value for key, value in transferred['artifacts'].items()})
    require(transferred['provenance'] == binding['priorProducer'] == prior, 'Transferred prior producer differs')
    retained_job_lifetime(prior['productOrigins']['raw']['priorCompilerReceipt'], transferred['jobs'], RESUME_JOB)
    prior_folder = args.evidence / 'prior-producer'
    prior_folder.mkdir()
    for name in ('retained-native.zip', 'retained-source.zip', 'prior-producer.json'):
        (prior_folder / name).write_bytes((args.binding / name).read_bytes())
    sources = args.evidence / 'sources'
    sources.mkdir()
    subset, ranges = source_subset(originals)
    subset['NativeAXPeer.swift'] = originals[PEER]
    fixture, fixture_ranges = fixture_subset(originals[FIXTURE])
    template = (ROOT / 'scripts/peer_availability_diagnostic.swift').read_bytes()
    require(template.count(b'// NGV_DIAGNOSTIC_FIXTURE') == 1, 'Diagnostic fixture marker changed')
    subset['PeerAvailability.swift'] = template.replace(b'// NGV_DIAGNOSTIC_FIXTURE', fixture)
    for name, raw in subset.items():
        (sources / name).write_bytes(raw)
    write(args.evidence / 'source-subsets.json', {'ranges': ranges, 'fixtureRanges': fixture_ranges,
        'emittedHashes': {name: digest(raw) for name, raw in subset.items()},
        'unchangedFullSources': [PEER, QUERY, HOST, SUPPORT, HEADER], 'originalFullAppImage': False})
    include = args.evidence / 'support-module'
    include.mkdir()
    (include / 'AppKitTestHostSupport.h').write_bytes(originals[HEADER])
    (include / 'module.modulemap').write_bytes(SUPPORT_MODULE)
    support = args.evidence / 'host-support.o'
    host = args.evidence / 'NexGenVideoAppKitTestHost'
    bundle = args.evidence / 'PeerAvailability.dylib'
    raw_client = args.evidence / 'peer-availability-raw'
    with zipfile.ZipFile(args.binding / 'retained-native.zip') as archive:
        for role, path, expected in [('support', support, RETAINED['support']),
                                    ('host', host, RETAINED['host']), ('raw', raw_client, REUSED_RAW)]:
            path.write_bytes(archive.read(expected['member']))
            retained_product(path.read_bytes(), expected)
            if role != 'support':
                path.chmod(0o755)
                require(macho_uuid(path) == expected['uuid'], 'Reused executable UUID differs')
            product_record(args.evidence, role, path, prior['productOrigins'][role])
    require(os.uname().machine == 'arm64', 'Original native architecture differs')
    toolchain = {
        'swift': (['swift', '--version'], SWIFT_TARGET),
        'xcode': (['xcodebuild', '-version'], 'Xcode 27.2\nBuild version 27B52'),
        'os-version': (['sw_vers', '-productVersion'], '27.2'),
        'os-build': (['sw_vers', '-buildVersion'], '26B123')}
    for name, (command, expected) in toolchain.items():
        controller.identity(command, name, expected)
    write(args.evidence / 'python.json', {'actual': sys.version, 'exactOriginalPythonRequiredForAXMeasurement': False})
    controller.run(['xcrun', '--sdk', 'macosx', '--show-sdk-platform-path'], 'sdk-platform')
    platform = (args.evidence / 'sdk-platform.log').read_text().strip()
    frameworks = Path(platform) / 'Developer/Library/Frameworks'
    require(platform == prior['sdkPlatform'] and Path(platform).is_absolute() and frameworks.is_dir(),
            'Selected SDK framework path differs from retained compiler producer')
    selected = controller.run(['xcrun', '--find', 'swiftc'], 'selected-compiler', separate_stderr=True)
    compiler_text = (args.evidence / selected['stdoutFile']).read_text().strip()
    with zipfile.ZipFile(original) as archive:
        original_compiler = archive.read('_temp/release-test-evidence/app-swift-testing/swiftc-path.stdout').decode().strip()
    require(compiler_text == original_compiler, 'Selected compiler differs from original native producer')
    compiler = Path(compiler_text)
    controller.identity([str(compiler), '--version'], 'selected-swiftc', SWIFT_TARGET)
    metadata = controller.run([str(compiler), '-print-target-info', '-target', 'arm64-apple-macos26.0'],
        'compiler-target-info', separate_stderr=True)
    plugin = plugin_metadata((args.evidence / metadata['stdoutFile']).read_bytes(), compiler)
    require(plugin['compilerSHA256'] == prior['compilerSHA256'] and plugin['pluginSHA256'] == prior['pluginSHA256'],
            'Actual compiler or plugin changed; retained Raw identity cannot be reused blindly')
    plugin['metadataProcess'] = metadata
    write(args.evidence / 'macro-plugin.json', plugin)
    prefix = [str(compiler), '-swift-version', '6', '-O', '-enable-testing', '-parse-as-library', '-target', 'arm64-apple-macos26.0']
    process = controller.run([*prefix, '-emit-library', '-module-name', 'PeerAvailability', '-F', str(frameworks),
        '-framework', 'Testing', '-Xlinker', '-rpath', '-Xlinker', str(frameworks),
        '-plugin-path', plugin['pluginDirectory'],
        *[str(sources / name) for name in sorted(subset)], '-o', str(bundle)], 'compile-bundle')
    product_record(args.evidence, 'bundle', bundle, {'kind': 'current-compilation',
        'sourceSHA': os.environ['GITHUB_SHA'], 'runID': os.environ['GITHUB_RUN_ID'],
        'compilerReceipt': process, 'sourceHashes': {name: digest(raw) for name, raw in subset.items()},
        'macroPlugin': plugin})
    controller.run(['xcrun', 'dwarfdump', '--uuid', str(host), str(bundle), str(raw_client)], 'binary-uuids')
    write(args.evidence / 'product-hashes.json', {path.name: digest(path.read_bytes()) for path in
        [host, bundle, raw_client, support]})
    products = {name: {'path': str(path.resolve()), 'SHA256': digest(path.read_bytes()), 'uuid': macho_uuid(path)}
                for name, path in [('host', host), ('bundle', bundle), ('raw', raw_client)]}
    write(args.evidence / 'compiler-products.json', products)
    results = []
    for context in ('default', 'regular'):
        folder = args.evidence / context
        folder.mkdir()
        env = dict(os.environ, NGV_APPKIT_TEST_BUNDLE=str(bundle.resolve()),
            NGV_APPKIT_TEST_EVENTS=str((folder / 'events.jsonl').resolve()),
            NGV_APPKIT_TEST_RECEIPT=str((folder / 'host-receipt.json').resolve()),
            NGV_APPKIT_EXCEPTION_EVIDENCE=str((folder / 'exception.jsonl').resolve()),
            NGV_AVAILABILITY_CONTEXT=context, NGV_AVAILABILITY_OUTPUT=str(folder.resolve()),
            NGV_AVAILABILITY_RAW_CLIENT=str(raw_client.resolve()))
        process = controller.run([str(host.resolve()), '--event-stream-version', '0'], 'host-' + context, env)
        results.append(verify_collection(folder, context, {'process': process, 'products': products,
            'sourceSHA': os.environ['GITHUB_SHA']}))
    write(args.evidence / 'receipt.json', {'schema': 'nexgenvideo/peer-availability-collection/1',
        'sourceSHA': os.environ['GITHUB_SHA'], 'runID': os.environ['GITHUB_RUN_ID'], 'attempt': '1',
        'appAcceptance': False, 'appBuilds': 0, 'nativeRegressionSuiteRepeats': 0,
        'newCompilerInvocations': 1, 'reusedCompilerProducts': 3,
        'diagnosticFunctionExecutions': 2, 'observations': results,
        'scope': 'Isolated original host sources with a distinct small diagnostic test image; raw calls follow the first Peer query.'})


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['bind', 'observe'])
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--source-proof', type=Path)
    parser.add_argument('--binding', type=Path)
    args = parser.parse_args()
    require((args.action == 'bind' and args.source_proof is not None and args.binding is None)
            or (args.action == 'observe' and args.binding is not None and args.source_proof is None),
            'Exact action-specific paths required')
    (bind if args.action == 'bind' else observe)(args)
