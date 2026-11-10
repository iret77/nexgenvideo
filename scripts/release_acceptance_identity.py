"""Bind retained acceptance inputs to their original final DMG and full bundle trees."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FIELDS = {'schema', 'sourceSHA', 'runID', 'attempt', 'runtimeArtifactID', 'runtimeArtifactSHA256',
          'producerArtifactID', 'producerArtifactSHA256', 'dmgSHA256', 'appTreeSHA256', 'packTreeSHA256'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def gui_tools():
    directory = ROOT / 'scripts/external-gui'
    sys.path.insert(0, str(directory))
    try:
        import acceptance
    finally:
        sys.path.pop(0)
    require(Path(acceptance.__file__).resolve() == directory / 'acceptance.py', 'Unexpected bundle identity implementation')
    return acceptance


def tree_sha256(path):
    return gui_tools().tree_sha256(path)


def declared_binding(value):
    require(type(value) is dict, 'Incomplete explicit release binding')
    if value.get('schema') == 'nexgenvideo/release-acceptance-binding/2':
        from retained_packaging import selectors
        require(set(value) == FIELDS | {'packaging', 'packagingProvenanceSHA256'}
                and type(value.get('packaging')) is dict
                and set(value['packaging']) == {'producerSourceSHA', 'artifactID', 'artifactSHA256'}, 'Incomplete packaging release binding')
        selected = value['packaging']
        require(type(selected.get('artifactID')) is int and selectors(selected.get('producerSourceSHA'),
                str(selected.get('artifactID')), selected.get('artifactSHA256')) == selected
                and re.fullmatch('[a-f0-9]{64}', value.get('packagingProvenanceSHA256', '')), 'Invalid packaging release binding')
    else:
        require(set(value) == FIELDS and value.get('schema') == 'nexgenvideo/release-acceptance-binding/1', 'Incomplete explicit release binding')
    require(re.fullmatch('[a-f0-9]{40}', value.get('sourceSHA', '')), 'Invalid retained product source')
    require(value.get('attempt') == 1 and type(value.get('attempt')) is int, 'Only the bound original attempt is accepted')
    for key in ('runID', 'runtimeArtifactID', 'producerArtifactID'):
        require(type(value.get(key)) is int and value[key] > 0, 'Invalid release artifact identity: ' + key)
    for key in ('runtimeArtifactSHA256', 'producerArtifactSHA256', 'dmgSHA256', 'appTreeSHA256', 'packTreeSHA256'):
        require(isinstance(value.get(key), str) and re.fullmatch('[a-f0-9]{64}', value[key]), 'Invalid release digest: ' + key)
    return value


def validate_producer(producer, binding, runtime_receipt=None):
    declared_binding(binding)
    schema = 'nexgenvideo/release-workspace-producer/1'
    if binding['schema'] == 'nexgenvideo/release-acceptance-binding/2':
        from retained_packaging import consumer_binding, consumer_record, validate_runtime_receipt
        proof = consumer_binding(binding['runID'], binding['sourceSHA'], binding['packaging'])
        record = consumer_record(proof, binding['sourceSHA'], binding['runID'])
        require(proof['rawProofSHA256'] == binding['packagingProvenanceSHA256']
                == producer.get('packagingProvenanceSHA256')
                and producer.get('producerSourceSHA') == record['producerSourceSHA']
                and all(binding[key] == record['final'][key] for key in ('dmgSHA256', 'appTreeSHA256', 'packTreeSHA256')),
                'Final producer differs from canonical packaging proof')
        if runtime_receipt is not None:
            validate_runtime_receipt(runtime_receipt, binding['sourceSHA'], proof)
        schema = 'nexgenvideo/release-workspace-producer/2'
    else:
        require('producerSourceSHA' not in producer and 'packagingProvenanceSHA256' not in producer,
                'Packaging producer requires its explicit binding schema')
    require(producer.get('schema') == schema
            and producer.get('sourceSHA') == binding['sourceSHA']
            and producer.get('runID') == str(binding['runID']) and producer.get('runAttempt') == '1'
            and producer.get('dmgSHA256') == binding['dmgSHA256']
            and producer.get('mountedAppTreeSHA256') == binding['appTreeSHA256']
            and producer.get('packTreeSHA256') == binding['packTreeSHA256'], 'Final DMG producer differs from the reviewed release')
    app = producer.get('app', {})
    require(app.get('NGVSourceCommit') == binding['sourceSHA'] and app.get('treeSHA256') == binding['appTreeSHA256']
            and app.get('CFBundleIdentifier') == 'de.h5ventures.nexgenvideo'
            and isinstance(app.get('CFBundleShortVersionString'), str)
            and re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', app['CFBundleShortVersionString'])
            and isinstance(app.get('CFBundleVersion'), str) and re.fullmatch(r'[1-9][0-9]*', app['CFBundleVersion']),
            'Release app metadata differs from the exact mounted DMG')
    if runtime_receipt is not None:
        require(runtime_receipt.get('sourceSHA') == binding['sourceSHA']
                and runtime_receipt.get('archiveSHA256') == producer.get('archiveSHA256')
                and runtime_receipt.get('appTreeSHA256') == binding['appTreeSHA256'], 'Runtime receipt does not match the final DMG producer')


def snapshot(executable, pack):
    executable = executable.resolve(strict=True)
    app = executable.parents[2]
    require(app.name == 'NexGenVideo.app' and executable.relative_to(app).as_posix() == 'Contents/MacOS/NexGenVideo',
            'Acceptance executable is outside the expected bundle')
    require(pack.is_dir() and not pack.is_symlink(), 'Missing real target format pack')
    return {'appTreeSHA256': tree_sha256(app), 'executableSHA256': digest(executable),
            'packTreeSHA256': tree_sha256(pack)}


def validate_snapshot(actual, binding):
    require(actual.get('appTreeSHA256') == binding['appTreeSHA256']
            and actual.get('packTreeSHA256') == binding['packTreeSHA256'], 'Actual app or pack differs from final DMG runtime bytes')


def before_case(executable, pack, identity=None):
    actual = snapshot(executable, pack)
    if identity is not None:
        record = json.loads(identity.read_text())
        validate_snapshot(actual, declared_binding(record['binding']))
        require(actual == record['actualBefore'], 'Retained input changed after its Mac qualification')
        return {'schema': 'nexgenvideo/settings-byte-binding/1', 'before': actual,
                'inputIdentitySHA256': digest(identity), 'releaseBinding': record['binding']}
    return {'schema': 'nexgenvideo/settings-byte-binding/1', 'before': actual,
            'releaseBinding': None, 'inputIdentitySHA256': None}


def after_case(executable, pack, before, output=None):
    actual = snapshot(executable, pack)
    record = before | {'after': actual, 'unchanged': actual == before['before']}
    if output is not None:
        output.write_text(json.dumps(record, indent=2) + '\n')
    require(actual == before['before'], 'Acceptance changed app executable, resources, signature, target pack or modes')
    return record


def installed_target(home, target, expected_tree):
    require(re.fullmatch('[a-f0-9]{64}', expected_tree), 'Missing full target pack fingerprint')
    matches = list(home.rglob(target['version'] + '.ngvpack/Contents/Info.plist'))
    require(len(matches) == 1, 'Installed target pack is missing or ambiguous')
    root = matches[0].parents[1]
    require(not root.is_symlink() and root.resolve(strict=True).is_relative_to(home.resolve(strict=True)), 'Installed target escaped its isolated home')
    actual = tree_sha256(root)
    require(actual == expected_tree, 'Installed target pack changed executable, resources, signature, links or modes')
    return {'treeSHA256': actual, 'relativePath': root.relative_to(home).as_posix()}


def bind(binding, source_run, destination):
    from reuse_bpy_binary_evidence import api, download
    from retained_release_runtime import bind as bind_runtime
    from verify_diagnostic_candidate import SIGNED_SETTINGS_HARNESS_PATHS, verify_signed_bpy, verify_signed_settings
    from verified_pr_source_checks import prepare

    binding = declared_binding(binding)
    require(source_run > 0 and os.environ['GITHUB_REPOSITORY'] == 'iret77/nexgenvideo'
            and os.environ['GITHUB_RUN_ATTEMPT'] == '1', 'A current owned first-attempt source proof is required')
    destination.mkdir(parents=True, exist_ok=False)
    source = destination / 'source-proof'
    prepare(source_run, source)
    artifact, retained = bind_runtime(binding['runID'], binding['sourceSHA'], binding['runtimeArtifactID'],
                                      binding['runtimeArtifactSHA256'], verifier=verify_signed_settings,
                                      **({'packaging': binding['packaging']} if 'packaging' in binding else {}))
    run = api('/actions/runs/' + str(binding['runID']))
    jobs = api(f"/actions/runs/{binding['runID']}/attempts/1/jobs?per_page=100")
    producer_artifact = api('/actions/artifacts/' + str(binding['producerArtifactID']))
    verify_signed_bpy(run, jobs, producer_artifact, binding['runID'], binding['sourceSHA'], binding['producerArtifactID'],
        binding['producerArtifactSHA256'], retained['changedHarnessPaths'], artifact_name='release-workspace-producer',
        harness_paths=SIGNED_SETTINGS_HARNESS_PATHS, **({'packaging': binding['packaging']} if 'packaging' in binding else {}))
    archive = destination / 'producer.zip'
    download(producer_artifact, archive)
    with zipfile.ZipFile(archive) as bundle:
        require(bundle.namelist() == ['release-workspace-producer.json']
                and bundle.getinfo(bundle.namelist()[0]).file_size <= 100_000, 'Unexpected release producer archive')
        producer = json.loads(bundle.read(bundle.namelist()[0]))
    validate_producer(producer, binding)
    files = {path.relative_to(destination).as_posix(): digest(path) for path in sorted(source.iterdir())}
    files['producer.zip'] = digest(archive)
    record = {'schema': 'nexgenvideo/retained-settings-input/1', 'binding': binding, 'retainedRuntime': retained,
              'runtimeArtifact': artifact, 'producerArtifact': producer_artifact, 'producer': producer,
              'sourceRunID': source_run, 'sourceProofSHA256': digest(source / 'receipt.json'), 'files': files,
              'harnessSourceSHA': os.environ['GITHUB_SHA'], 'executionRunID': os.environ['GITHUB_RUN_ID'], 'attempt': '1'}
    (destination / 'identity.json').write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    return record


def restore(directory, expected_sha, destination):
    from consume_bpy_distributable_source import consume
    from retained_release_runtime import bind as bind_runtime, restore as restore_runtime
    from verify_diagnostic_candidate import verify_signed_settings
    from workspace_native_ci import source_composition

    require(sys.platform == 'darwin' and os.environ.get('GITHUB_ACTIONS') == 'true'
            and os.environ.get('RUNNER_ENVIRONMENT') == 'self-hosted', 'Restore only on macrunner in GitHub Actions')
    require(re.fullmatch('[a-f0-9]{64}', expected_sha) and digest(directory / 'identity.json') == expected_sha,
            'Settings preflight identity changed')
    record = json.loads((directory / 'identity.json').read_text())
    require(record.get('schema') == 'nexgenvideo/retained-settings-input/1'
            and record.get('harnessSourceSHA') == os.environ['GITHUB_SHA']
            and record.get('executionRunID') == os.environ['GITHUB_RUN_ID']
            and record.get('attempt') == os.environ['GITHUB_RUN_ATTEMPT'] == '1', 'Settings input belongs to another execution')
    for name, expected in record['files'].items():
        require(Path(name).as_posix() == name and not Path(name).is_absolute() and '..' not in Path(name).parts
                and digest(directory / name) == expected, 'Settings source or producer evidence changed')
    source_composition(directory / 'source-proof', record['sourceProofSHA256'], record['sourceRunID'])
    binding = declared_binding(record['binding'])
    artifact, retained = bind_runtime(binding['runID'], binding['sourceSHA'], binding['runtimeArtifactID'],
                                      binding['runtimeArtifactSHA256'], verifier=verify_signed_settings,
                                      **({'packaging': binding['packaging']} if 'packaging' in binding else {}))
    require(retained == record['retainedRuntime'] and artifact == record['runtimeArtifact'], 'Original runtime or current harness changed')
    restore_runtime(artifact, retained, destination)
    if 'packVerificationReuse' in retained:
        record['packVerificationReuse'] = retained['packVerificationReuse']
    payload = destination.parent / (destination.name + '-retained-transfer') / 'payload'
    receipt = json.loads((payload / 'workspace-ui-input.json').read_text())
    require(digest(payload / 'workspace-ui-input.json') == record['producer']['runtimeInputSHA256']
            and digest(payload / 'bpy-source-receipt.json') == record['producer']['bpySourceReceiptSHA256'], 'Final runtime sidecar bytes changed')
    validate_producer(record['producer'], binding, receipt)
    from compiled_app_release import consume_packaging_source
    reused = consume_packaging_source(destination / 'qualified-source', binding['sourceSHA'],
        payload / 'bpy-source-receipt.json', retained.get('packaging'), context='settings-restore',
        evidence=destination / 'bpy-source-consumer-reused.json')
    if reused is None:
        consume(destination / 'qualified-source', binding['sourceSHA'], payload / 'bpy-source-receipt.json')
    else:
        record['sourceReuse'] = reused['reuse']
        record['sourceReuseSHA256'] = reused['evidenceSHA256']
    actual = snapshot(destination / 'NexGenVideo.app/Contents/MacOS/NexGenVideo', destination / 'plugins/musicvideo.ngvpack')
    validate_snapshot(actual, binding)
    require(gui_tools().metadata(destination / 'NexGenVideo.app', binding['sourceSHA']) == record['producer']['app'],
            'Restored app metadata differs from the final DMG producer')
    record['actualBefore'] = actual
    record['inputIdentitySHA256'] = expected_sha
    (destination / 'acceptance-input.json').write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    sub = parser.add_subparsers(dest='mode', required=True)
    prepare = sub.add_parser('bind')
    prepare.add_argument('--binding', required=True)
    prepare.add_argument('--source-run', required=True, type=int)
    prepare.add_argument('--output', required=True, type=Path)
    consume = sub.add_parser('restore')
    consume.add_argument('--identity', required=True, type=Path)
    consume.add_argument('--identity-sha256', required=True)
    consume.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if args.mode == 'bind':
        bind(json.loads(args.binding), args.source_run, args.output)
        with Path(os.environ['GITHUB_OUTPUT']).open('a') as output:
            output.write('identity_sha256=' + digest(args.output / 'identity.json') + '\n')
    else:
        restore(args.identity, args.identity_sha256, args.output)


if __name__ == '__main__':
    main()
