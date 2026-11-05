"""Measure failed retained-runtime checks without rebuilding the product."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import zipfile

from retained_packaging import (PRODUCT_OBJECTS, consumer_binding, consumer_harness,
                                consumer_record, environment_selectors, git, verify_app_bytes)
from retained_release_runtime import bind as bind_runtime, restore
from reuse_bpy_binary_evidence import api, download
from verify_diagnostic_candidate import verify_signed_bpy


HARNESS_PATHS = {
    '.github/workflows/diagnostic-acceptance.yml', '.github/workflows/release.yml',
    '.github/workflows/retained-runtime-failure-diagnostic.yml',
    'scripts/app_termination_acceptance.py', 'scripts/test_app_termination_acceptance.py',
    'scripts/test_release_workflow.py', 'scripts/retained_runtime_failure_diagnostic.py',
    'scripts/test_retained_runtime_failure_diagnostic.py',
    'scripts/runtime_pointer_diagnostic.swift', 'scripts/runtime_pointer_source.py',
}
FAILURES = {
    'diagnostic': ('diagnostic-acceptance', 'diagnostic-runtime-acceptance',
                   'Verify asynchronous termination, cancellation and restart'),
    'bpy': ('bpy-runtime / runtime', None, 'Run real bpy acceptance without ambient Blender or Python'),
}
EXTRA_FIELDS = ('JOURNEY_JOB', 'JOURNEY_ARTIFACT', 'JOURNEY_DIGEST', 'EXTRA_SOURCE',
                'EXTRA_PRODUCTS', 'EXTRA_FAILURE', 'EXTRA_PRODUCTS_SHA', 'EXTRA_FAILURE_SHA')


def require(value, message):
    if not value:
        raise ValueError(message)


def failure_selectors(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, 'Duplicate failure selector key')
            result[key] = value
        return result
    require(isinstance(raw, str) and 0 < len(raw) <= 2048, 'Missing or oversized failure binding')
    value = json.loads(raw, object_pairs_hook=unique)
    require(type(value) is dict and set(value) == set(FAILURES), 'Exactly two failure bindings are required')
    for item in value.values():
        require(type(item) is dict and set(item) == {'jobID', 'artifactID', 'artifactSHA256'},
                'Unexpected failure selector fields')
        require(all(type(item[key]) is int and item[key] > 0 for key in ('jobID', 'artifactID'))
                and isinstance(item['artifactSHA256'], str)
                and re.fullmatch('[a-f0-9]{64}', item['artifactSHA256']), 'Invalid failure identity')
    require(len({item['jobID'] for item in value.values()}) == 2
            and len({item['artifactID'] for item in value.values()}) == 2, 'Failures must have distinct producers')
    return value


def validate_inputs(env):
    require(env.get('KIND', env.get('REPLAY_KIND')) == 'native-retained-failures', 'Wrong diagnostic mode')
    for key in ('CANDIDATE_RUN', 'CANDIDATE_ARTIFACT', 'VERIFIED_PR'):
        require(re.fullmatch('[1-9][0-9]*', env.get(key, '')), 'Missing exact run, artifact or source receipt')
    require(re.fullmatch('[a-f0-9]{40}', env.get('CANDIDATE_SOURCE', ''))
            and re.fullmatch('[a-f0-9]{40}', env.get('PACKAGING_PRODUCER_SOURCE', '')),
            'Missing product and packaging source identities')
    require(re.fullmatch('[1-9][0-9]*', env.get('PACKAGING_PROVENANCE_ARTIFACT_ID', ''))
            and all(re.fullmatch('[a-f0-9]{64}', env.get(key, ''))
                    for key in ('CANDIDATE_DIGEST', 'PACKAGING_PROVENANCE_ARTIFACT_SHA256', 'DMG_DIGEST')),
            'Missing exact runtime, canonical proof or DMG digest')
    require(env.get('SCALE') == '1' and not any(env.get(key, '') for key in EXTRA_FIELDS),
            'Retained failure measurement requires scale1 and no unrelated reuse selectors')
    return failure_selectors(env.get('RUNTIME_FAILURE_BINDING', ''))


def verify_failure(run, jobs, artifact, kind, selected, product):
    name, artifact_name, step = FAILURES[kind]
    if kind == 'bpy':
        artifact_name = 'managed-bpy-original-app-diagnostic-' + product + '-harness-' + run['head_sha']
    require(run.get('status') == 'completed' and run.get('conclusion') == 'failure'
            and run.get('run_attempt') == 1 and run.get('actor', {}).get('login') == 'iret77',
            'Require the original completed failed release attempt')
    require(jobs.get('total_count') == len(jobs.get('jobs', [])) <= 100, 'Incomplete original job inventory')
    matches = [job for job in jobs['jobs'] if job.get('name') == name]
    require(len(matches) == 1, 'Ambiguous original failure job')
    job = matches[0]
    require(job.get('id') == selected['jobID'] and job.get('run_id') == run['id']
            and job.get('head_sha') == run['head_sha'] and job.get('run_attempt') == 1
            and job.get('labels') == ['macrunner'] and job.get('status') == 'completed'
            and job.get('conclusion') == 'failure', 'Original failed job identity differs')
    failures = [item for item in job.get('steps', []) if item.get('conclusion') == 'failure']
    require(len(failures) == 1 and failures[0].get('name') == step, 'Original failure step changed')
    require(artifact.get('id') == selected['artifactID'] and artifact.get('name') == artifact_name
            and artifact.get('digest') == 'sha256:' + selected['artifactSHA256']
            and artifact.get('expired') is False and type(artifact.get('size_in_bytes')) is int
            and 0 < artifact['size_in_bytes'] <= 64 * 1024**2
            and artifact.get('workflow_run', {}).get('id') == run['id']
            and artifact.get('workflow_run', {}).get('head_sha') == run['head_sha'],
            'Original failure artifact identity differs')
    instant = lambda value: datetime.fromisoformat(value.replace('Z', '+00:00'))
    require(instant(job['started_at']) <= instant(artifact['created_at']) <= instant(artifact['updated_at'])
            <= instant(job['completed_at']) and instant(artifact['expires_at']) > datetime.now(timezone.utc),
            'Failure artifact does not belong to this attempt')
    return job


def read_failure_archive(path):
    values, expanded = {}, 0
    with zipfile.ZipFile(path) as archive:
        require(0 < len(archive.infolist()) <= 1024, 'Failure archive member count exceeds its bound')
        for member in archive.infolist():
            name = PurePosixPath(member.filename)
            require(not name.is_absolute() and '..' not in name.parts and '\\' not in member.filename
                    and str(name) == member.filename and member.filename not in values and not member.is_dir()
                    and stat.S_IFMT(member.external_attr >> 16) in (0, stat.S_IFREG)
                    and not member.flag_bits & 1, 'Unsafe failure archive member')
            expanded += member.file_size
            require(member.file_size <= 64 * 1024**2 and expanded <= 256 * 1024**2,
                    'Failure archive expansion exceeds its bound')
            values[member.filename] = archive.read(member)
    return values


def failure_geometry(files, product):
    value = json.loads(files['spatial-scene-100.json'])
    observation = json.loads(files['runtime-failure-observation.json'])
    require('native scene revision committed after undo' in value.get('failure', '')
            and observation.get('sourceSHA') == product, 'Original Undo failure is missing or foreign')
    controls = {}
    for name in ('spatial.undo', 'spatial.transform.apply'):
        rows = [row for row in value['interactions'] if row.get('kind') == 'pointer' and row.get('id') == name]
        require(len(rows) == 1 and rows[0].get('localMonitorDownObserved') is True
                and rows[0].get('localMonitorUpObserved') is True, 'Original pointer observation is ambiguous')
        row = rows[0]
        frame = row.get('frame')
        require(isinstance(frame, list) and len(frame) == 4
                and all(type(v) in (float, int) and math.isfinite(v) for v in frame)
                and frame[2] > 0 and frame[3] > 0 and frame[0] >= 0 and frame[1] >= 0
                and frame[0] + frame[2] <= 960 and frame[1] + frame[3] <= 640,
                'Original control geometry is outside the measured window')
        require(row.get('point') == [frame[0] + frame[2] / 2, frame[1] + frame[3] / 2]
                and row.get('windowPoint') == [row['point'][0], 640 - row['point'][1]],
                'Original pointer and window geometry differ')
        controls[name] = row
    return {'windowSize': [960, 640], 'interfaceScale': 1, 'controls': controls,
            'originalSemanticCallbackObserved': False, 'appAcceptance': False}


def bind(output):
    require(os.environ.get('GITHUB_REPOSITORY') == 'iret77/nexgenvideo'
            and os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('GITHUB_ACTOR') == 'iret77'
            and os.environ.get('GITHUB_RUN_ATTEMPT') == '1', 'Require the original authorized diagnostic execution')
    selected = validate_inputs(os.environ)
    run_id, product = int(os.environ['CANDIDATE_RUN']), os.environ['CANDIDATE_SOURCE']
    packaging = environment_selectors()
    output.mkdir(parents=True, exist_ok=False)
    binding = consumer_binding(run_id, product, packaging, archive_root=output / 'canonical')
    harness = consumer_harness(binding, product, HARNESS_PATHS)
    producer = packaging['producerSourceSHA']
    for path in PRODUCT_OBJECTS:
        require(git('rev-parse', producer + ':' + path) == git('rev-parse', harness + ':' + path),
                'Product Git object changed: ' + path)
    record = consumer_record(binding, product, run_id)
    require(record['final']['dmgSHA256'] == os.environ['DMG_DIGEST'], 'Final DMG differs from canonical producer')

    def verifier(*args, **kwargs):
        verify_signed_bpy(*args, artifact_name='workspace-ui-app', harness_paths=HARNESS_PATHS, **kwargs)
    artifact, proof = bind_runtime(run_id, product, int(os.environ['CANDIDATE_ARTIFACT']),
                                   os.environ['CANDIDATE_DIGEST'], verifier=verifier, packaging=packaging)
    require(proof['packaging'] == binding, 'Runtime and failure canonical bindings differ')
    run = api('/actions/runs/' + str(run_id))
    jobs = api(f'/actions/runs/{run_id}/attempts/1/jobs?per_page=100')
    failures = {}
    for kind, identity in selected.items():
        metadata = api('/actions/artifacts/' + str(identity['artifactID']))
        job = verify_failure(run, jobs, metadata, kind, identity, product)
        destination = output / (kind + '-original.zip')
        download(metadata, destination)
        files = read_failure_archive(destination)
        if kind == 'bpy':
            geometry = failure_geometry(files, product)
            (output / 'pointer-input.json').write_text(json.dumps(geometry, indent=2) + '\n')
        else:
            from app_termination_acceptance import MODES
            for mode in MODES:
                failure = json.loads(files['termination/' + mode + '/failure.json'])
                require(failure.get('error') == 'missing or foreign-source events', 'Termination failure changed')
                events = [json.loads(line) for line in files['termination/' + mode + '/events.jsonl'].splitlines()]
                require(events and all(event.get('sourceSHA') == product for event in events),
                        'Original termination events do not prove the retained product identity')
        failures[kind] = {'job': job, 'artifact': metadata,
                          'members': {name: {'bytes': len(raw), 'sha256': hashlib.sha256(raw).hexdigest()}
                                      for name, raw in files.items()}}
    result = {'schema': 'nexgenvideo/retained-runtime-failures/1', 'productSourceSHA': product,
              'harnessSourceSHA': harness, 'producerSourceSHA': producer, 'run': run, 'jobs': jobs,
              'runtimeArtifact': artifact, 'runtimeProof': proof, 'failures': failures,
              'finalDMGSHA256': os.environ['DMG_DIGEST'], 'appAcceptance': False}
    (output / 'binding.json').write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    return result


def run(output):
    require(sys.platform == 'darwin' and os.environ.get('GITHUB_ACTIONS') == 'true'
            and os.environ.get('GITHUB_REPOSITORY') == 'iret77/nexgenvideo', 'Native diagnostics require macrunner Actions')
    result = bind(output)
    runtime = output / 'runtime'
    restore(result['runtimeArtifact'], result['runtimeProof'], runtime)
    app = runtime / 'NexGenVideo.app'
    binding = result['runtimeProof']['packaging']
    before = verify_app_bytes(app, binding)
    from release_acceptance_identity import tree_sha256
    canonical = consumer_record(binding, result['productSourceSHA'])
    pack = runtime / 'plugins/musicvideo.ngvpack'
    pack_before = tree_sha256(pack)
    require(pack_before == canonical['final']['packTreeSHA256'], 'External pack differs from canonical final bytes')
    statuses = {}
    try:
        with (output / 'termination.log').open('wb') as log:
            completed = subprocess.run([sys.executable, 'scripts/app_termination_acceptance.py', str(app),
                '--output', str(output / 'termination'), '--product-source', result['productSourceSHA']],
                stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, timeout=480)
            statuses['termination'] = completed.returncode
        from runtime_pointer_source import prepare, validate_measurement
        support = prepare(output / 'pointer-support.swift')
        binary = output / 'pointer-diagnostic'
        with (output / 'pointer-compile.log').open('wb') as log:
            compilation = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6',
                str(support), 'Sources/NexGenVideo/UI/CapsuleButton.swift', 'scripts/runtime_pointer_diagnostic.swift',
                '-o', str(binary)], stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, timeout=90)
        statuses['frameworkCompile'] = compilation.returncode
        if compilation.returncode == 0:
            with (output / 'pointer.log').open('wb') as log:
                measured = subprocess.run([str(binary), str(output / 'pointer-input.json'), str(output)],
                    stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, timeout=90)
            statuses['frameworkMeasurement'] = measured.returncode
            if measured.returncode == 0:
                validate_measurement(output)
                statuses['frameworkEvidence'] = 0
    finally:
        after = verify_app_bytes(app, binding)
        pack_after = tree_sha256(pack)
        (output / 'execution.json').write_text(json.dumps({'before': before, 'after': after, 'statuses': statuses,
            'packBeforeSHA256': pack_before, 'packAfterSHA256': pack_after,
            'runtimeProof': result['runtimeProof'], 'appAcceptance': False}, indent=2) + '\n')
        require(pack_before == pack_after, 'External pack changed during native measurements')
    require(statuses == {'termination': 0, 'frameworkCompile': 0, 'frameworkMeasurement': 0, 'frameworkEvidence': 0},
            'One or more isolated runtime measurements failed; inspect complete evidence')


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('mode', choices=('validate-inputs', 'bind', 'run'))
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.mode == 'validate-inputs':
        require(args.output is None, 'Input validation has no output directory')
        validate_inputs(os.environ)
    else:
        require(args.output is not None, 'A new evidence destination is required')
        (run if args.mode == 'run' else bind)(args.output.resolve())


if __name__ == '__main__':
    main()
