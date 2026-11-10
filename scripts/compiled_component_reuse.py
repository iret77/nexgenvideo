import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import tempfile

from retained_app_test_products import checksum, require


ORIGIN = {'sourceSHA': 'a1375966dbe6d2dd7b918c726f09ac5d1f4f16fb', 'runID': 42822598973,
    'builderJobID': 129851825955, 'releaseJobID': 129864612990,
    'artifactID': 13769391943, 'artifactBytes': 1696850395,
    'artifactSHA256': '4dd7c9afd04a08039ac8ff0c1d7381d0bd779cbd3b5d405d978e502cf446a583',
    'proofArtifactID': 13769367412,
    'proofArtifactSHA256': '6a21867ad5474418ef37590da4d3f35b1b409089928796b4a4aeec42c6624ee0',
    'assemblyArtifactID': 13769032781,
    'assemblyArtifactSHA256': 'f81c8bed3217e9f39089d94584653523407b8ca5ece780ed304ffc884acb3855',
    'manifestSHA256': 'dc29cc53937d8b6136bcb4239de3d6ea95a9f321aa855da9f83f9d63d98d968b',
    'appArchiveSHA256': '251008735347f303055a3931330c2f15375d2717920c0c34bf9b65a9de42b0e1',
    'appTreeSHA256': 'df1e8d1c7ec100dad95fa7b0f9a9d6d75a87ccf957fe3200e9c0769ba1df41ba',
    'sourceReceiptSHA256': '015aa71e5dd5f47ce98569cf6d3f7ecabb9da13671eb6dd4acc24661eaa7e9ba',
    'releaseRawSHA256': 'e23cc8791a2749264ac49c65e1825418ba281da47ef480276b721783ec9779d5',
    'builderRawSHA256': 'a7bef321573a6c97412761d5ee15c2199cb9da6ccde8402c5194986db2b8ddbf'}
STEPS = ('Assemble and sign the new App with unchanged retained components',
    'Record compiled App signed input without invoking a build',
    'Preserve original signing inputs and the complete new App assembly receipt',
    'Retain signed build input', 'Retain signed build proof')
RELEASE_STEPS = ('Verify pack links the SHARED engine (guards the PackEntry-cast regression)',
    'Load-test — the SIGNED app actually loads the SIGNED pack from an EXTERNAL dir')
PATHS = {'scripts/compiled_component_reuse.py', 'scripts/test_compiled_component_reuse.py',
    'scripts/notary_continuation.py', 'scripts/test_notary_continuation.py', 'scripts/bundle.sh',
    '.github/workflows/release.yml', 'scripts/notarize.sh', 'scripts/compiled_app_release.py',
    'scripts/release_checkpoint.py', 'scripts/retained_packaging.py', 'scripts/native_current_cohort.py'}


def matches(run, source):
    return (run, source) == (ORIGIN['runID'], ORIGIN['sourceSHA'])


def record():
    from compiled_app_release import PACK_SHA, PACK_TREE
    return {'schema': 'compiled-component-product-reuse/v1', 'original': dict(ORIGIN),
        'packArchiveSHA256': PACK_SHA, 'packTreeSHA256': PACK_TREE, 'appRootMode': 0o755,
        'freshCompilerCoreAssemblyOrRootSignPerformed': False}


def qualified(binding):
    return (type(binding) is dict and binding.get('productSourceSHA') == ORIGIN['sourceSHA']
        and binding.get('originalSignedBuildRunID') == ORIGIN['runID']
        and binding.get('signedInput', {}).get('componentProduct') == record())


def current_execution(binding, expected=None):
    import compiled_app_release as compiled
    import retained_packaging as packaging
    require(qualified(binding) and sys.platform == 'darwin' and os.environ.get('GITHUB_ACTIONS') == 'true'
        and os.environ.get('GITHUB_REPOSITORY') == packaging.REPOSITORY and os.environ.get('GITHUB_JOB') == 'release'
        and os.environ.get('GITHUB_RUN_ATTEMPT') == '1' and type(binding.get('attempt')) is int and binding.get('attempt') == 1
        and binding.get('stage') == 'input' and binding.get('producerSourceSHA') == os.environ.get('GITHUB_SHA')
        and str(binding.get('runID')) == os.environ.get('GITHUB_RUN_ID'), 'Component writer lost its actual current execution')
    temporary = Path(os.environ['RUNNER_TEMP'])
    root = Path(os.environ['RETAINED_PACKAGING_ROOT'])
    root_anchor = compiled.source_directory_identity(root, temporary)
    input_anchor = compiled.source_directory_identity(root / 'input', temporary)
    path = root / 'input/packaging-provenance.json'
    require(path.is_file() and not path.is_symlink(), 'Component canonical input is absent or linked')
    raw = path.read_bytes()
    require(hashlib.sha256(raw).hexdigest() == os.environ.get('RETAINED_PACKAGING_INPUT_SHA256')
        and raw == packaging.encoded(binding), 'Component canonical input bytes or mutable object changed')
    actual = (root_anchor, input_anchor, hashlib.sha256(raw).hexdigest(), binding['producerSourceSHA'], binding['runID'])
    require(expected is None or expected == actual, 'Component writer execution changed during origin acquisition')
    return actual


def verify_origin(producer, builder, payload, proof, manifest_raw, *, verifier):
    from release_checkpoint import verify_manifest
    require(matches(producer.get('id'), producer.get('head_sha'))
        and producer.get('repository', {}).get('full_name') == 'iret77/nexgenvideo'
        and producer.get('actor', {}).get('login') == 'iret77' and producer.get('run_attempt') == 1
        and producer.get('path') == '.github/workflows/release.yml' and producer.get('event') == 'workflow_dispatch'
        and producer.get('status') == 'completed' and producer.get('conclusion') == 'failure',
        'Component signed-product origin differs')
    require(builder.get('id') == ORIGIN['builderJobID'] and builder.get('run_id') == ORIGIN['runID']
        and builder.get('head_sha') == ORIGIN['sourceSHA'] and builder.get('run_attempt') == 1
        and builder.get('name') == 'release-build' and builder.get('labels') == ['macrunner']
        and builder.get('status') == 'completed' and builder.get('conclusion') == 'success',
        'Component signed-product builder differs')
    for name in STEPS:
        steps = [step for step in builder.get('steps', []) if step.get('name') == name]
        require(len(steps) == 1 and steps[0].get('conclusion') == 'success', 'Component signed stage did not pass: ' + name)
    prefix = 'release-signed-input-' + ORIGIN['sourceSHA']
    for artifact, identifier, digest, name in (
        (payload, ORIGIN['artifactID'], ORIGIN['artifactSHA256'], prefix),
        (proof, ORIGIN['proofArtifactID'], ORIGIN['proofArtifactSHA256'], prefix + '-proof')):
        verifier(artifact, producer, builder, identifier, digest, name)
    require(payload.get('size_in_bytes') == ORIGIN['artifactBytes']
        and hashlib.sha256(manifest_raw).hexdigest() == ORIGIN['manifestSHA256'], 'Component signed bytes differ')
    manifest = verify_manifest(json.loads(manifest_raw), ORIGIN['sourceSHA'], ORIGIN['runID'])
    require(manifest['identity']['build'] == '107' and manifest['identity']['version'] == '1.8.0'
        and manifest['appTreeSHA256'] == ORIGIN['appTreeSHA256']
        and manifest['files']['NexGenVideo.zip']['sha256'] == ORIGIN['appArchiveSHA256']
        and manifest['files']['bpy-source-receipt.json']['sha256'] == ORIGIN['sourceReceiptSHA256']
        and manifest.get('componentAssembly', {}).get('schema') == 'compiled-component-assembly/v1'
        and manifest['nativeEvidence'].get('schema') == 'release-native-compiled-app/v4',
        'Component signed manifest lost its exact App, symbols, source or native scope')
    return record()


def verify_native_originals(producer, builder):
    import retained_packaging as packaging
    release = packaging.api('actions/jobs/' + str(ORIGIN['releaseJobID']))
    require(release.get('id') == ORIGIN['releaseJobID'] and release.get('run_id') == ORIGIN['runID']
        and release.get('head_sha') == ORIGIN['sourceSHA'] and release.get('run_attempt') == 1
        and release.get('name') == 'release' and release.get('labels') == ['macrunner']
        and release.get('status') == 'completed' and release.get('conclusion') == 'failure', 'Original component release differs')
    for name in RELEASE_STEPS:
        steps = [step for step in release.get('steps', []) if step.get('name') == name]
        require(len(steps) == 1 and steps[0].get('conclusion') == 'success', 'Original component native step did not pass')
    for job, field in ((builder, 'builderRawSHA256'), (release, 'releaseRawSHA256')):
        raw = packaging.read_api('actions/jobs/' + str(job['id']) + '/logs', maximum=1024 * 1024)
        require(hashlib.sha256(raw).hexdigest() == ORIGIN[field], 'Original component full native log differs')
    assembly = packaging.api('actions/artifacts/' + str(ORIGIN['assemblyArtifactID']))
    packaging.verify_artifact(assembly, producer, builder, ORIGIN['assemblyArtifactID'], ORIGIN['assemblyArtifactSHA256'],
        'release-compiled-app-assembly-' + str(ORIGIN['runID']) + '-a1')


def materialized(binding, app, *, before_saved_dmg=False):
    import compiled_app_release as compiled
    import release_checkpoint as checkpoint
    expected_tree = ORIGIN['appTreeSHA256']
    if not before_saved_dmg and binding.get('previousNotary', {}).get('dmgArtifact') is not None:
        previous = binding['previousNotary']
        require(previous.get('acceptedAppNotary') is not None and previous.get('dmgProof', {}).get('checkpoint'),
            'Saved DMG has no authenticated accepted App request or actual checkpoint')
        expected_tree = previous['dmgProof']['checkpoint']['appTreeSHA256']
    require(qualified(binding) and app.is_dir() and not app.is_symlink()
        and stat.S_IMODE(app.lstat().st_mode) == 0o755
        and checkpoint.tree_digest(app) == expected_tree, 'Current component App bytes or mode changed')
    compiled.verify_component_materialization(binding['signedInput']['manifest']['componentAssembly'],
        app, app.parent / 'NexGenEngine.dSYM')


def native_record(binding):
    import compiled_app_release as compiled
    return {'schema': 'component-native-checks-reuse/v1', 'state': 'REUSED', 'original': dict(ORIGIN),
        'current': {'productSourceSHA': binding['productSourceSHA'], 'harnessSourceSHA': binding['producerSourceSHA'],
            'runID': binding['runID'], 'attempt': 1, 'job': 'release', 'appTreeSHA256': ORIGIN['appTreeSHA256']},
        'signatureCommand': compiled.SIGNATURE_COMMAND, 'signatureRecordSHA256': compiled.SIGNATURE_RECORD_SHA256,
        'releaseSteps': list(RELEASE_STEPS), 'packArchiveSHA256': compiled.PACK_SHA,
        'packTreeSHA256': compiled.PACK_TREE, 'currentNativeSignatureLinkOrLoadPerformed': False,
        'freshTrustStoreOrRevocationClaimed': False}


def verify_native_record(value, binding):
    require(qualified(binding) and value == native_record(binding), 'Component native reuse record lost its exact origin or scope')


def reuse_native(root, app, manifest, binding):
    import compiled_app_release as compiled
    import retained_packaging as packaging
    from compiled_core_reuse import persist
    require(sys.platform == 'darwin' and os.environ.get('GITHUB_ACTIONS') == 'true'
        and os.environ.get('GITHUB_REPOSITORY') == 'iret77/nexgenvideo'
        and os.environ.get('GITHUB_JOB') == 'release' and os.environ.get('GITHUB_RUN_ATTEMPT') == '1'
        and qualified(binding) and manifest == binding['signedInput']['manifest'], 'Unknown component reuse execution')
    execution = current_execution(binding)
    temporary, workspace = Path(os.environ['RUNNER_TEMP']), Path(os.environ['GITHUB_WORKSPACE'])
    require(root.absolute() == temporary.absolute() / 'release-signed-binding', 'Component proof root differs')
    root_anchor = compiled.source_directory_identity(root, temporary)
    app_anchor = compiled.source_directory_identity(app, workspace)
    materialized(binding, app, before_saved_dmg=True)
    run = packaging.api('actions/runs/' + str(ORIGIN['runID']))
    builder = packaging.api('actions/jobs/' + str(ORIGIN['builderJobID']))
    payload = packaging.api('actions/artifacts/' + str(ORIGIN['artifactID']))
    proof = packaging.api('actions/artifacts/' + str(ORIGIN['proofArtifactID']))
    proof_raw = packaging.read_api('actions/artifacts/' + str(ORIGIN['proofArtifactID']) + '/zip', maximum=16 * 1024**2)
    require(hashlib.sha256(proof_raw).hexdigest() == ORIGIN['proofArtifactSHA256'], 'Component original proof changed')
    members = packaging.read_proof_archive(proof_raw)
    require(set(members) == {'manifest.json'}, 'Component original proof members differ')
    verify_origin(run, builder, payload, proof, members['manifest.json'], verifier=packaging.verify_artifact)
    verify_native_originals(run, builder)
    compiled.pack_verification_origin()
    verify_origin(packaging.api('actions/runs/' + str(ORIGIN['runID'])),
        packaging.api('actions/jobs/' + str(ORIGIN['builderJobID'])),
        packaging.api('actions/artifacts/' + str(ORIGIN['artifactID'])),
        packaging.api('actions/artifacts/' + str(ORIGIN['proofArtifactID'])), members['manifest.json'], verifier=packaging.verify_artifact)
    materialized(binding, app, before_saved_dmg=True)
    compiled.source_directory_identity(root, temporary, root_anchor)
    compiled.source_directory_identity(app, workspace, app_anchor)
    current_execution(binding, execution)
    persist(root / 'component-native-checks.reused.json', native_record(binding))


def verify_native_materialization(binding, root, app):
    require(qualified(binding), 'Component native reuse lacks its canonical product')
    path = root / 'component-native-checks.reused.json'
    require(path.is_file() and not path.is_symlink(), 'Component native reuse record is absent or linked')
    verify_native_record(json.loads(path.read_bytes()), binding)
    materialized(binding, app)


def source_record(value, product, harness, run_id):
    import compiled_app_release as compiled
    import consume_bpy_distributable_source as source
    require(type(value) is dict and set(value) == {'bpy-source-original-receipt.json', 'bpy-source-receipt.json', 'bpy-source-reuse.json'}
        and all(type(raw) is str for raw in value.values()), 'Incomplete component source reuse proof')
    original_raw, receipt_raw = (value[name].encode() for name in ('bpy-source-original-receipt.json', 'bpy-source-receipt.json'))
    original, receipt, reuse = (json.loads(value[name], object_pairs_hook=compiled.unique_object)
        for name in ('bpy-source-original-receipt.json', 'bpy-source-receipt.json', 'bpy-source-reuse.json'))
    public = source.public_asset(json.loads(source.LOCK_PATH.read_text()))
    require(product == ORIGIN['sourceSHA'] and original_raw == receipt_raw
        and hashlib.sha256(receipt_raw).hexdigest() == ORIGIN['sourceReceiptSHA256']
        and original == receipt and receipt.get('sourceSHA') == product, 'Exact component source receipt changed')
    source.require_receipt(receipt, public, product)
    require(reuse.get('schema') == 'component-bpy-source-receipt-reuse/v1' and reuse.get('state') == 'REUSED'
        and reuse.get('signedProduct') == ORIGIN and reuse.get('productSourceSHA') == product
        and reuse.get('harnessSourceSHA') == harness and reuse.get('runID') == run_id
        and reuse.get('attempt') == 1 and reuse.get('job') == 'release'
        and reuse.get('originalValidation') == receipt['validation'] and reuse.get('publicSourceAsset') == public
        and reuse.get('derivedReceiptSHA256') == ORIGIN['sourceReceiptSHA256']
        and reuse.get('semanticSourceValidationPerformed') is False, 'Component source reuse scope or provenance changed')
    compiled.verify_source_origin(reuse.get('originEvidence', {}), public, reuse['acquiredAt'])
    return receipt, reuse


def reuse_source(directory, binding):
    import compiled_app_release as compiled
    import consume_bpy_distributable_source as source
    from compiled_core_reuse import persist, persist_bytes
    require(qualified(binding) and os.environ.get('GITHUB_JOB') == 'release', 'Unqualified component source handoff')
    execution = current_execution(binding)
    workspace = Path(os.environ['GITHUB_WORKSPACE'])
    require(directory.absolute() == workspace.absolute() / '.build/bpy-source', 'Component source destination differs')
    anchor = compiled.source_directory_identity(directory, workspace)
    receipt_path = directory / source.RECEIPT
    require(receipt_path.is_file() and not receipt_path.is_symlink(), 'Component source receipt is absent or linked')
    raw = receipt_path.read_bytes()
    require(hashlib.sha256(raw).hexdigest() == ORIGIN['sourceReceiptSHA256'], 'Component original source receipt changed')
    receipt = json.loads(raw)
    public = source.public_asset(json.loads(source.LOCK_PATH.read_text()))
    source.require_receipt(receipt, public, ORIGIN['sourceSHA'])
    materialized(binding, workspace / '.build/NexGenVideo.app')
    with tempfile.TemporaryDirectory(prefix='component-bpy-source-') as staging:
        stage = Path(staging)
        evidence = compiled.acquire_source_pair(public, stage)
        current_execution(binding, execution)
        compiled.commit_source_pair(stage, directory, public, workspace, anchor)
    compiled.source_directory_identity(directory, workspace, anchor)
    materialized(binding, workspace / '.build/NexGenVideo.app')
    require(receipt_path.read_bytes() == raw and not receipt_path.is_symlink()
        and source.public_asset(json.loads(source.LOCK_PATH.read_text())) == public, 'Component source inputs changed during acquisition')
    compiled.verify_source_pair(directory, public)
    value = {'schema': 'component-bpy-source-receipt-reuse/v1', 'state': 'REUSED', 'signedProduct': dict(ORIGIN),
        'productSourceSHA': ORIGIN['sourceSHA'], 'harnessSourceSHA': binding['producerSourceSHA'],
        'runID': binding['runID'], 'attempt': 1, 'job': 'release', 'publicSourceAsset': public,
        'originalValidation': receipt['validation'], 'derivedReceiptSHA256': ORIGIN['sourceReceiptSHA256'],
        'originEvidence': evidence, 'semanticSourceValidationPerformed': False,
        'acquiredAt': compiled.datetime.datetime.now(compiled.datetime.timezone.utc).isoformat()}
    compiled.verify_source_origin(evidence, public, value['acquiredAt'])
    current_execution(binding, execution)
    persist_bytes(directory / 'bpy-source-original-receipt.json', raw)
    persist(directory / 'bpy-source-reuse.json', value)
    previous = binding.get('previousNotary', {})
    if previous.get('acceptedAppNotary') is not None:
        from notary_continuation import ARCHIVE, observation_members, verify_observations
        from consume_bpy_distributable_source import physical_directory, persist_raw
        members = observation_members(bytes.fromhex(previous['acceptedAppNotary']['archiveHex']))
        verify_observations(members, binding)
        destination = Path(os.environ['NOTARY_STATE_DIR']) / 'observations' / ARCHIVE
        require(not destination.exists() and not destination.is_symlink(), 'Saved App observation reuse was consumed')
        physical_directory(destination, create=True)
        from compiled_core_reuse import sync_directory
        sync_directory(destination.parent.parent)
        sync_directory(destination.parent)
        for name, raw in members.items(): persist_raw(destination / name, raw)


def main():
    import retained_packaging
    require(sys.argv[1:] == ['verify-native'] and sys.platform == 'darwin'
        and os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('GITHUB_REPOSITORY') == 'iret77/nexgenvideo'
        and os.environ.get('GITHUB_JOB') == 'release' and os.environ.get('GITHUB_RUN_ATTEMPT') == '1',
        'Unknown component native reuse caller')
    binding = retained_packaging.current_binding()
    root = Path(os.environ['RUNNER_TEMP']) / 'release-signed-binding'
    verify_native_materialization(binding, root, Path('.build/NexGenVideo.app'))
    print('COMPONENT_SIGNATURE_LINK_AND_EXTERNAL_LOAD_REUSED', flush=True)


if __name__ == '__main__':
    main()
