"""Verify private originals in CI; publish only a finite provenance receipt."""
import argparse
import datetime
import hashlib
import io
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.error
import urllib.request
import zipfile

from retained_app_test_products import api, archive_bytes, checksum, download, require, verify_artifact

REPOSITORY = 'iret77/nexgenvideo'
REPORT_REPO = 'ghcr.io/iret77/nexgenvideo-analysis-reports'
FIXTURE_REPO = 'ghcr.io/iret77/nexgenvideo-examples'
DIGEST = re.compile(r'sha256:[a-f0-9]{64}')
SHA = re.compile(r'[a-f0-9]{64}')
COMMIT = re.compile(r'[a-f0-9]{40}')
POINTER_KEYS = {'schema', 'nativeRunID', 'nativeAttempt', 'nativeHarnessSourceSHA', 'reportDigest', 'fixtureDigest',
    'productRunID', 'productSourceSHA', 'runtimeArtifactID', 'runtimeArtifactSHA256'}
CHECKS = ('native_origin', 'oci_descriptors', 'fixture_bytes', 'runtime_origin', 'measured_analysis',
    'independent_expectations', 'measurement_lineage', 'lyrics_stems', 'native_intake', 'approved_project',
    'phase_order', 'canonical_media', 'playback_range', 'private_inventory')
ERRORS = {'REGISTRY', 'OCI', 'ARCHIVE', 'FIXTURE', 'ORIGIN', 'RUNTIME', 'ANALYSIS', 'EXPECTATIONS',
    'MEASUREMENT', 'INTAKE', 'PROJECT', 'PHASES', 'PLAYBACK', 'CANONICAL', 'INPUT', 'INTERNAL',
    'REGISTRY_AUTH', 'REGISTRY_PERMISSION', 'REGISTRY_MISSING', 'REGISTRY_HTTP', 'REGISTRY_TRANSPORT',
    'REGISTRY_RESPONSE', 'REGISTRY_SCHEMA', 'REGISTRY_OWNER'}
PUBLIC_KEYS = {'schema', 'status', 'errorCode', 'reportDigest', 'fixtureDigest', 'privateInventorySHA256',
    'productRunID', 'productSourceSHA', 'runtimeArtifactID', 'runtimeArtifactSHA256', 'nativeRunID', 'nativeJobID',
    'nativeHarnessSourceSHA', 'verificationRunID', 'verificationHarnessSourceSHA', 'checks'}
LAYERS = {'provenance.json': 'application/vnd.nexgenvideo.example-analysis-provenance.v6+json',
    'analysis.json': 'application/vnd.nexgenvideo.analysis.v3+json',
    'measurement-proof.json': 'application/vnd.nexgenvideo.analysis-measurement-proof.v1+json',
    'musicvideo-acceptance.tar.gz': 'application/vnd.nexgenvideo.musicvideo-acceptance.v1+tar+gzip'}
NATIVE_STEPS = ('Restore the original signed App and external pack without rebuilding', 'Run exact-file analysis through the real app and pack', 'Verify actual optional material intake',
    'Publish private analysis report', 'Verify report package isolation', 'Write finite private report pointer', 'Retain finite private report pointer')
PHASES = ['project_init', 'analysis', 'brief', 'production_design', 'treatment', 'script', 'storyboard',
    'shot_planning', 'bible', 'shotlist', 'sanity', 'frames', 'render_review', 'render']


class VerificationError(ValueError):
    pass


def check(value, code):
    if not value:
        raise VerificationError(code)


def raw_json(raw):
    def unique(items):
        result = {}
        for key, value in items:
            check(key not in result, 'INPUT'); result[key] = value
        return result
    def number(raw):
        value = float(raw);check(math.isfinite(value), 'INPUT');return value
    return json.loads(raw, object_pairs_hook=unique, parse_float=number, parse_constant=lambda _: (_ for _ in ()).throw(VerificationError('INPUT')))


def read_json(path):
    check(path.is_file() and not path.is_symlink() and path.stat().st_size <= 32 * 1024**2, 'INPUT')
    return raw_json(path.read_bytes())


def local(root, name):
    check(isinstance(name, str) and name and '\\' not in name and '\0' not in name, 'ARCHIVE')
    relative = PurePosixPath(name)
    check(str(relative) == name and not relative.is_absolute() and '..' not in relative.parts, 'ARCHIVE')
    target = root.joinpath(*relative.parts)
    check(target.resolve().is_relative_to(root.resolve()) and target.is_file() and not target.is_symlink(), 'ARCHIVE')
    check(all(not parent.is_symlink() for parent in target.parents if parent.is_relative_to(root)), 'ARCHIVE')
    return target


def project_local(data, name):
    check(isinstance(name, str) and name and not PurePosixPath(name).is_absolute()
        and '..' not in PurePosixPath(name).parts and '\\' not in name, 'CANONICAL')
    for base in (data, data.parent):
        target = base / name
        check(not target.is_symlink() and all(not p.is_symlink() for p in target.parents if p.is_relative_to(base)), 'CANONICAL')
        if target.is_file():return local(base, name)
    raise VerificationError('CANONICAL')


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def pointer(value):
    check(isinstance(value, dict) and set(value) == POINTER_KEYS and value.get('schema') == 'private-analysis-pointer/v1', 'INPUT')
    check(all(type(value[key]) is int and value[key] > 0 for key in ('nativeRunID', 'productRunID', 'runtimeArtifactID'))
        and type(value.get('nativeAttempt')) is int and value['nativeAttempt'] == 1, 'INPUT')
    check(all(COMMIT.fullmatch(value.get(key, '')) for key in ('nativeHarnessSourceSHA', 'productSourceSHA'))
        and SHA.fullmatch(value.get('runtimeArtifactSHA256', ''))
        and all(DIGEST.fullmatch(value.get(key, '')) for key in ('reportDigest', 'fixtureDigest')), 'INPUT')
    return value


def validate_reuse(raw):
    if not raw:
        return None
    value = raw_json(raw)
    check(isinstance(value, dict) and set(value) == {'runID', 'sourceSHA', 'jobID', 'reportDigest', 'fixtureDigest',
        'pointerArtifactID', 'pointerArtifactSHA256'}, 'INPUT')
    check(all(type(value[key]) is int and value[key] > 0 for key in ('runID', 'jobID', 'pointerArtifactID'))
        and COMMIT.fullmatch(value.get('sourceSHA', '')) and SHA.fullmatch(value.get('pointerArtifactSHA256', ''))
        and all(DIGEST.fullmatch(value.get(key, '')) for key in ('reportDigest', 'fixtureDigest')), 'INPUT')
    return value


def write_pointer(output):
    reference = os.environ['PRIVATE_REPORT_REFERENCE']
    check(reference.startswith(REPORT_REPO + '@'), 'INPUT')
    value = pointer({'schema': 'private-analysis-pointer/v1', 'nativeRunID': int(os.environ['GITHUB_RUN_ID']),
        'nativeAttempt': int(os.environ['GITHUB_RUN_ATTEMPT']), 'nativeHarnessSourceSHA': os.environ['GITHUB_SHA'],
        'reportDigest': reference.removeprefix(REPORT_REPO + '@'), 'fixtureDigest': os.environ['FIXTURE_DIGEST'],
        'productRunID': int(os.environ['ORIGINAL_RUN']), 'productSourceSHA': os.environ['ORIGINAL_SOURCE'],
        'runtimeArtifactID': int(os.environ['ORIGINAL_ARTIFACT']), 'runtimeArtifactSHA256': os.environ['ORIGINAL_DIGEST']})
    check(os.environ.get('GITHUB_ACTIONS') == 'true' and os.environ.get('GITHUB_REPOSITORY') == REPOSITORY
        and os.environ.get('GITHUB_JOB') == 'analyze', 'ORIGIN')
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open('x') as stream:json.dump(value, stream, sort_keys=True); stream.write('\n')


def registry_metadata(path):
    token = os.environ.get('NGV_GHCR_TOKEN', '')
    check(bool(token), 'REGISTRY_AUTH')
    request = urllib.request.Request('https://api.github.com' + path,
        headers={'Authorization': 'Bearer ' + token, 'Accept': 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28'})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:raw = response.read(1024**2 + 1)
    except urllib.error.HTTPError as error:
        code = {401: 'REGISTRY_AUTH', 403: 'REGISTRY_PERMISSION', 404: 'REGISTRY_MISSING'}.get(error.code, 'REGISTRY_HTTP')
        error.close()
        raise VerificationError(code) from None
    except (urllib.error.URLError, TimeoutError):
        raise VerificationError('REGISTRY_TRANSPORT') from None
    check(len(raw) <= 1024**2, 'REGISTRY_RESPONSE')
    try:value = raw_json(raw)
    except (ValueError, UnicodeError):raise VerificationError('REGISTRY_RESPONSE') from None
    check(isinstance(value, dict), 'REGISTRY_SCHEMA')
    return value


def package_isolation():
    check(registry_metadata('/user').get('login') == 'iret77', 'REGISTRY_OWNER')
    for name in ('nexgenvideo-examples', 'nexgenvideo-analysis-reports'):
        value = registry_metadata('/user/packages/container/' + name)
        check(isinstance(value.get('owner'), dict), 'REGISTRY_SCHEMA')
        check(value.get('visibility') == 'private' and value.get('repository') is None
            and value['owner'].get('login') == 'iret77'
            and value.get('name') == name and value.get('package_type') == 'container', 'REGISTRY')


def native_origin(selected, root):
    run = api('actions/runs/' + str(selected['runID']))
    jobs = api(f"actions/runs/{selected['runID']}/attempts/1/jobs?per_page=100")
    check(run.get('head_sha') == selected['sourceSHA'] and run.get('run_attempt') == 1 and (run.get('status') == 'completed' or str(run.get('id')) == os.environ.get('GITHUB_RUN_ID')
            and os.environ.get('GITHUB_JOB') == 'verify-report' and run.get('status') == 'in_progress')
        and run.get('repository', {}).get('full_name') == REPOSITORY and run.get('actor', {}).get('login') == 'iret77'
        and run.get('path') in {'.github/workflows/private-example-analysis.yml', '.github/workflows/ci-batch.yml', '.github/workflows/release.yml'}
        and jobs.get('total_count') == len(jobs.get('jobs', [])), 'ORIGIN')
    found = [job for job in jobs['jobs'] if job.get('id') == selected['jobID']]
    check(len(found) == 1, 'ORIGIN'); job = found[0]
    check(job.get('labels') == ['macrunner'] and job.get('run_id') == run['id'] and job.get('head_sha') == run['head_sha']
        and job.get('run_attempt') == 1 and job.get('status') == 'completed' and job.get('conclusion') == 'success', 'ORIGIN')
    for name in NATIVE_STEPS:
        check([s.get('conclusion') for s in job.get('steps', []) if s.get('name') == name] == ['success'], 'ORIGIN')
    artifact = api('actions/artifacts/' + str(selected['pointerArtifactID']))
    verify_artifact(artifact, run, job, selected['pointerArtifactID'], selected['pointerArtifactSHA256'],
        f"private-analysis-pointer-{run['id']}-a1")
    check(artifact['size_in_bytes'] <= 65536, 'ORIGIN')
    archive_path = root / 'pointer-original.zip'; download(artifact, archive_path)
    check(checksum(archive_path) == selected['pointerArtifactSHA256'], 'ORIGIN')
    with zipfile.ZipFile(archive_path) as archive:
        check(archive.namelist() == ['private-analysis-pointer.json'], 'ORIGIN')
        value = pointer(raw_json(archive_bytes(archive, 'private-analysis-pointer.json', 32768)))
    check(value['nativeRunID'] == run['id'] and value['nativeHarnessSourceSHA'] == run['head_sha']
        and value['reportDigest'] == selected['reportDigest'] and value['fixtureDigest'] == selected['fixtureDigest'], 'ORIGIN')
    for key, env in [('productRunID', 'ORIGINAL_RUN'), ('productSourceSHA', 'ORIGINAL_SOURCE'),
            ('runtimeArtifactID', 'ORIGINAL_ARTIFACT'), ('runtimeArtifactSHA256', 'ORIGINAL_DIGEST')]:
        expected = int(os.environ[env]) if type(value[key]) is int else os.environ[env]
        check(value[key] == expected, 'RUNTIME')
    return value, {'run': run, 'job': job, 'artifact': artifact}


def registry_command(argv):
    result = subprocess.run(['oras', *argv, '--registry-config', os.environ['ORAS_AUTH_FILE']],
        stdin=subprocess.DEVNULL, capture_output=True, timeout=600)
    check(result.returncode == 0, 'REGISTRY')


def oci(root, repository, reference, role):
    check(DIGEST.fullmatch(reference) and repository in {REPORT_REPO, FIXTURE_REPO}, 'OCI')
    root.mkdir(exist_ok=False)
    path = root / 'manifest.json'
    registry_command(['manifest', 'fetch', '--output', str(path), repository + '@' + reference])
    check(path.stat().st_size <= 65536 and 'sha256:' + checksum(path) == reference, 'OCI')
    value = read_json(path)
    check(value.get('schemaVersion') == 2 and value.get('mediaType') == 'application/vnd.oci.image.manifest.v1+json'
        and isinstance(value.get('layers'), list) and len(value['layers']) == (4 if role == 'report' else 2), 'OCI')
    check(value.get('artifactType') == ('application/vnd.nexgenvideo.example-analysis-report.v6'
        if role == 'report' else 'application/vnd.nexgenvideo.example-fixtures.v2'), 'OCI')
    expected = LAYERS if role == 'report' else {
        'examples.tar.gz': 'application/vnd.nexgenvideo.example-fixtures.v2.tar+gzip',
        'fixtures.manifest.json': 'application/vnd.nexgenvideo.example-fixtures.manifest.v2+json'}
    found = {}
    for index, item in enumerate([value['config'], *value['layers']]):
        check(isinstance(item, dict) and DIGEST.fullmatch(item.get('digest', '')) and type(item.get('size')) is int
            and 0 <= item['size'] <= (8 * 1024**3 if index else 65536), 'OCI')
        name = item.get('annotations', {}).get('org.opencontainers.image.title') if index else 'config.blob'
        check(name not in found and (index == 0 or name in expected and item.get('mediaType') == expected[name]), 'OCI')
        target = root / name
        registry_command(['blob', 'fetch', '--no-tty', '--output', str(target), repository + '@' + item['digest']])
        check(target.stat().st_size == item['size'] and 'sha256:' + checksum(target) == item['digest'], 'OCI')
        found[name] = item['digest']
    check(set(found) == {'config.blob', *expected} and value['config'].get('mediaType') == 'application/vnd.oci.empty.v1+json'
        and (root / 'config.blob').read_bytes() == b'{}', 'OCI')
    return found


def extract_report(archive, root):
    root.mkdir(exist_ok=False)
    with tarfile.open(archive, 'r:gz') as stream:
        entries = stream.getmembers()
        check(0 < len(entries) <= 100000 and sum(x.size for x in entries) <= 16 * 1024**3, 'ARCHIVE')
        seen = set()
        for entry in entries:
            name = entry.name
            while name.startswith('./'):name = name[2:]
            if not name or name == '.':check(entry.isdir(), 'ARCHIVE');continue
            relative = PurePosixPath(name)
            check(not relative.is_absolute() and str(relative) == name and '..' not in relative.parts and '\\' not in name
                and '\0' not in name and name.casefold() not in seen and (entry.isfile() or entry.isdir()), 'ARCHIVE')
            seen.add(name.casefold())
            target = root.joinpath(*relative.parts)
            check(target.resolve().is_relative_to(root.resolve()), 'ARCHIVE')
            if entry.isdir():target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with stream.extractfile(entry) as source, target.open('xb') as output:shutil.copyfileobj(source, output, 1024 * 1024)
    return root


def foundation_field(path, field, output):
    check(sys.platform == 'darwin' and os.environ.get('GITHUB_ACTIONS') == 'true'
        and os.environ.get('GITHUB_REPOSITORY') == REPOSITORY and os.environ.get('GITHUB_JOB') == 'verify-report', 'CANONICAL')
    script = Path(__file__).with_name('canonical_analysis.jxa')
    result = subprocess.run(['osascript', '-l', 'JavaScript', str(script), str(path), field, str(output)],
        stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
    check(result.returncode == 0 and output.is_file() and not output.is_symlink(), 'CANONICAL')
    return checksum(output)


def foundation_probe(root):
    source = root / 'canonical-probe-input.json'
    output = root / 'canonical-probe-output.json'
    source.write_bytes(b'{"alignment":[{"z":1.25,"a":"/\xc3\xa4"}]}')
    expected = b'[{"a":"/\xc3\xa4","z":1.25}]'
    check(foundation_field(source, 'alignment', output) == digest(expected) and output.read_bytes() == expected, 'CANONICAL')


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def numeric_expectations(analysis, expected):
    for key, tolerance in [('duration_s', 'duration_tolerance_s'), ('bpm', 'bpm_tolerance')]:
        check(finite(analysis.get(key)) and finite(expected.get(key)) and finite(expected.get(tolerance))
            and expected[tolerance] >= 0 and abs(analysis[key] - expected[key]) <= expected[tolerance], 'EXPECTATIONS')
    sections = analysis.get('sections', [])
    check(sections and len(sections) == len(expected['section_boundaries_s']) + 1
        and [x.get('label') for x in sections] == expected['section_labels'], 'EXPECTATIONS')
    boundaries = [x.get('start') for x in sections[1:]]
    check(all(finite(a) and abs(a - b) <= expected['section_boundary_tolerance_s']
        for a, b in zip(boundaries, expected['section_boundaries_s'])), 'EXPECTATIONS')
    end = 0
    for index, item in enumerate(sections):
        start, stop = item.get('start'), item.get('end')
        check(finite(start) and finite(stop) and 0 <= start < stop <= analysis['duration_s'] + 0.001
            and abs(start - end) < 0.001 and item.get('index') == index, 'ANALYSIS');end = stop
    check(abs(end - analysis['duration_s']) < 0.001, 'ANALYSIS')
    for key in ('beats', 'downbeats'):
        values = analysis.get(key)
        check(isinstance(values, list) and values and all(finite(x) and 0 <= x <= analysis['duration_s'] for x in values)
            and values == sorted(set(values)), 'ANALYSIS')
    resolution = analysis.get('structure_resolution', {})
    check(resolution.get('status') == 'resolved' and resolution.get('method') == 'per_boundary_evidence'
        and resolution.get('hierarchy') is None and resolution.get('accepted_boundary_count') == len(boundaries), 'ANALYSIS')
    if expected['expect_boundary_reduction']:
        check(type(resolution.get('candidate_boundary_count')) is int
            and resolution['candidate_boundary_count'] > len(boundaries) > 0, 'EXPECTATIONS')


def inventory(root):
    result = []
    for path in sorted(root.rglob('*')):
        check(not path.is_symlink(), 'ARCHIVE')
        if path.is_file():result.append([path.relative_to(root).as_posix(), path.stat().st_size, checksum(path)])
        else:check(path.is_dir(), 'ARCHIVE')
    check(result, 'ARCHIVE')
    return result


def png(root, name):
    path = local(root, name)
    check(path.stat().st_size > 1000 and path.read_bytes().startswith(b'\x89PNG\r\n\x1a\n'), 'INTAKE')


def project_evidence(root, analysis, song, lyrics, canonicalizer):
    flow = read_json(local(root, 'fullflow.json'))
    owner = read_json(local(root, 'owner-v2-result.json'))
    check(flow.get('complete') is True and flow.get('owner') == owner, 'PROJECT')
    check(owner.get('workflow') == 'musicvideo' and owner.get('executionFixture') == 'private_song_imported'
        and owner.get('retainedProject') == 'approved-project.ngv' and owner.get('phases') == PHASES, 'PHASES')
    check(all(owner.get(key) is True for key in ('allPhasesApproved', 'savedAndReopened', 'nativeScriptEdit',
        'nativeMultipleMoments', 'nativeStoryboardUndoRedo', 'nativeMomentAssignments', 'nativeAnimaticMomentChange',
        'nativeShotSourceAndRange', 'nativeShotUndoRedo', 'nativePreRenderReview')), 'PROJECT')
    project = root / 'approved-project.ngv'
    data = project / 'pipeline'
    check(project.is_dir() and not project.is_symlink() and data.is_dir() and not data.is_symlink()
        and local(data, 'project.yaml').stat().st_size > 0, 'PROJECT')
    pinned = read_json(local(project, 'ngv.json'))
    check(pinned.get('activePlugin') == 'musicvideo' and pinned.get('activePluginVersion') == '0.6.0'
        and pinned.get('activePluginProjectSchema') == 'musicvideo/3.0.0', 'PROJECT')
    measured = local(root, 'analysis.json'); approved = local(root, 'approved-analysis.json')
    check(flow.get('analysisLineage') == {'measured': {'path': 'analysis.json', 'sha256': checksum(measured)},
        'approved': {'path': 'approved-analysis.json', 'sha256': checksum(approved)}}, 'MEASUREMENT')
    approved_object = read_json(approved)
    check({k:v for k,v in analysis.items() if k not in {'interpretation', 'sections', 'tempo_multiplier'}}
        == {k:v for k,v in approved_object.items() if k not in {'interpretation', 'sections', 'tempo_multiplier'}}
        and approved_object.get('tempo_multiplier') == 1.0, 'MEASUREMENT')
    original_sections, approved_sections = analysis['sections'], approved_object['sections']
    check(len(original_sections) == len(approved_sections), 'MEASUREMENT')
    for index, (before, after) in enumerate(zip(original_sections, approved_sections)):
        check({k:v for k,v in before.items() if k != 'label'} == {k:v for k,v in after.items() if k != 'label'}
            and after.get('label') == (before.get('label') or f'Section {index + 1}'), 'MEASUREMENT')
    song_path = local(data, analysis['song_path'])
    check(song_path.read_bytes() == song.read_bytes(), 'PROJECT')
    analysis_path = 'analysis/' + song_path.stem + '.json'
    check(local(data, analysis_path).read_bytes() == approved.read_bytes(), 'MEASUREMENT')
    hashes = owner.get('canonicalSHA256')
    check(isinstance(hashes, dict) and hashes and all(isinstance(k, str) and SHA.fullmatch(v) for k, v in hashes.items()), 'CANONICAL')
    required = {'script/current.v1.json': 'script/v1', 'storyboard/current.v2.yaml': 'storyboard/v2',
        'storyboard/timing-current.v1.json': 'storyboard-timing/v1', 'shot-planning/current.v1.json': 'shot-planning-draft/v1',
        'render-review/current.v1.json': 'render-review/v1',
        'execution/extensions/production-plan-assembly.v1.json': 'production-plan-assembly/v1',
        'reviews/sequence/current.v2.json': 'production-sequence-review/v2',
        'review/timeline-style.v2.json': 'timeline-style-review/v2', 'gates.yaml': 'gates/v2'}
    import yaml
    check(set(required) <= set(hashes) and any(re.fullmatch(r'shotlist/v[1-9][0-9]*\.v5\.yaml', k) for k in hashes), 'CANONICAL')
    for name, expected in hashes.items():
        check(checksum(project_local(data, name)) == expected, 'CANONICAL')
        if name in required:check(yaml.safe_load(project_local(data, name).read_bytes()).get('schema') == required[name], 'CANONICAL')
    playback_name = 'brief/playback-range.v1.json'; playback = local(data, playback_name)
    value = read_json(playback)
    check(value.get('schema') == 'playback-range/v1' and value.get('analysis') == {'id': 'analysis', 'role': 'musicvideo.analysis',
        'path': analysis_path, 'sha256': checksum(approved)}, 'PLAYBACK')
    ticks = [value.get(key) for key in ('audioDurationTicks', 'startTicks', 'durationTicks')]
    check(all(type(x) is int for x in ticks) and ticks[0] > 0 and 0 <= ticks[1] < ticks[0]
        and ticks[2] > 0 and ticks[1] + ticks[2] <= ticks[0], 'PLAYBACK')
    check(value.get('kind') in {'fullSong', 'excerpt'} and (value['kind'] != 'fullSong'
        or ticks == [ticks[0], 0, ticks[0]]), 'PLAYBACK')
    check(owner.get('privateSongBinding') == {'songSHA256': checksum(song), 'analysisSHA256': checksum(approved),
        'playbackRangeSHA256': checksum(playback)}, 'PLAYBACK')
    import yaml
    state = yaml.safe_load(local(data, 'gates.yaml').read_bytes())
    check(state.get('schema') == 'gates/v2' and set(state.get('gates', {})) == set(PHASES)
        and all(state['gates'][phase].get('approved') is True
            and state['gates'][phase].get('state') in {'approved', 'approved_with_notes'} for phase in PHASES), 'PHASES')
    timebase = value.get('timebase', {})
    check(all(type(timebase.get(k)) is int and timebase[k] > 0 for k in ('ticksPerSecond', 'fpsNumerator', 'fpsDenominator'))
        and timebase['ticksPerSecond'] * timebase['fpsDenominator'] % timebase['fpsNumerator'] == 0
        and abs(ticks[0] / timebase['ticksPerSecond'] - analysis['duration_s']) <= 0.0005 + 1 / timebase['ticksPerSecond'], 'PLAYBACK')
    for item in value.get('header', {}).get('inputs', []):
        check(checksum(project_local(data, item['path'])) == item['sha256'], 'PLAYBACK')
    gates = owner.get('nativeGateApprovals')
    from workspace_ui_acceptance import valid_v2_gates
    check(valid_v2_gates(gates, 'musicvideo'), 'PHASES')
    check(isinstance(gates, list) and [g.get('phase') for g in gates] == PHASES, 'PHASES')
    for gate in gates:
        check(isinstance(gate.get('screenshots'), list) and gate['screenshots'], 'PHASES')
        for name in gate['screenshots']:png(root, name)
    native = owner.get('nativeEvidence', {})
    check(isinstance(native.get('interactions'), list) and native['interactions'] and native.get('screenshots'), 'PROJECT')
    progress = read_json(local(root, native.get('progress')))
    check(progress.get('schema') == 'native-visual-source-progress/v1' and progress.get('failure') is None
        and progress.get('interactions') == native['interactions'] and progress.get('screenshots') == native['screenshots'], 'PROJECT')
    pointers = {i.get('id') for i in native['interactions'] if i.get('kind') == 'pointer'}
    check({'script.scene.apply', 'storyboard.edit.apply', 'storyboard.undo', 'storyboard.redo', 'animatic.play',
        'storyboard.view', 'sequence.build', 'sequence.play', 'sequence.pause', 'sequence.record',
        'style.begin', 'style.record', 'export.start', 'storyboard.native-sketch.confirm', 'render-review.record-native',
        'production.assembly.build', 'sequence.whole', 'export.artwork.frame', 'export.artwork.remove', 'export.qc.recheck'} <= pointers, 'PROJECT')
    states = {}
    for item in native['interactions']:
        if item.get('kind') == 'verified-state':states.setdefault(item.get('label'), []).append(item.get('evidence'))
    required_states = ('native Script revision', 'multiple moments with native Undo and Redo', 'two moments within one shot',
        'native Shot Planning Undo and Redo', 'complete native film playback', 'actual exported movie and poster',
        'imported reference contract', 'reference-only Frames contract', 'native pre-render inspection',
        'native production assembly', 'native timeline style', 'native delivery byte changes rejected')
    check(all(len(states.get(label, [])) == 1 for label in required_states), 'PROJECT')
    script = states['native Script revision'][0]
    check(type(script.get('before')) is int and type(script.get('after')) is int and script['after'] > script['before'], 'PROJECT')
    moments = states['multiple moments with native Undo and Redo'][0].get('momentIDs')
    check(isinstance(moments, list) and len(set(moments)) == len(moments) >= 2, 'PROJECT')
    animatic = states['two moments within one shot'][0]
    check(all(animatic.get(k) is True for k in ('cutUnchanged', 'playingWhenLeaving', 'stoppedAfterLeaving', 'playbackDetached'))
        and type(animatic.get('stoppedTick')) is int and type(animatic.get('endTick')) is int
        and 0 <= animatic['stoppedTick'] < animatic['endTick'], 'PROJECT')
    shot = states['native Shot Planning Undo and Redo'][0]
    check(all(type(shot.get(k)) is int for k in ('before', 'applied', 'undone', 'redone'))
        and shot['before'] < shot['applied'] < shot['undone'] < shot['redone'], 'PROJECT')
    reference = states['imported reference contract'][0];frames = states['reference-only Frames contract'][0]
    check(reference.get('requiredObligations') == [] and reference.get('nativeReferenceSelectionClaim') is False
        and frames.get('requiredFrameRoles') == [] and frames.get('generatedFrameClaim') is False
        and frames.get('nativePhaseApproval') is True, 'PROJECT')
    pre = states['native pre-render inspection'][0]
    check(all(isinstance(pre.get(k), str) and SHA.fullmatch(pre[k]) for k in ('fingerprint', 'reviewEvidenceSHA256')), 'PROJECT')
    assembly = states['native production assembly'][0]
    check(isinstance(assembly.get('shotIDs'), list) and assembly['shotIDs'] and isinstance(assembly.get('clipIDs'), list)
        and len(assembly['shotIDs']) == len(assembly['clipIDs']), 'PROJECT')
    playback_observation = states['complete native film playback'][0]
    check(playback_observation.get('firstFrame') == 0 and type(playback_observation.get('endFrame')) is int
        and playback_observation['endFrame'] > 0 and all(finite(playback_observation.get(k)) and playback_observation[k] > 0
        for k in ('observedSeconds', 'decodedSeconds')), 'PROJECT')
    style = states['native timeline style'][0]
    check(isinstance(style.get('fingerprint'), str) and SHA.fullmatch(style['fingerprint'])
        and type(style.get('findingCount')) is int and style['findingCount'] >= 1, 'PROJECT')
    changes = states['native delivery byte changes rejected'][0]
    check(all(changes.get(k) is True for k in ('changedMovieRejected', 'changedPosterRejected', 'exactRestorationReverified'))
        and any(i.get('kind') == 'save-panel' and i.get('exactURLVerified') is True for i in native['interactions']), 'PROJECT')
    for name in native['screenshots']:png(root, name)
    from musicvideo_intake_evidence import validate as validate_intake, observation, read
    validate_intake(root, read_json(local(root, 'hostflow.json')))
    startup = observation(read(root, 'hostflow-track-lyrics-result.json'), 'native Track and optional Lyrics intake')
    check(startup['trackSHA256'] == checksum(song) and startup['trackName'] == song.name
        and startup['lyricsSupplied'] == bool(lyrics) and (not lyrics or startup['lyricsName'] == lyrics.name), 'INTAKE')
    check(local(root, 'intake-track-source.bin').read_bytes() == song.read_bytes(), 'INTAKE')
    proof = read_json(local(root, 'measurement-proof.json'))
    check(proof.get('schema') == 'analysis_measurement_proof/v1' and proof.get('song_sha256') == checksum(song), 'MEASUREMENT')
    stems = analysis.get('stems')
    check(isinstance(stems, dict) and set(stems) <= {'vocals', 'drums', 'bass', 'other'} and 'vocals' in stems, 'MEASUREMENT')
    for name in stems.values():check(local(data, name).stat().st_size > 44, 'MEASUREMENT')
    if lyrics:
        aligned = analysis.get('alignment'); timing = proof.get('lyrics_alignment', {})
        check(isinstance(aligned, list) and aligned and timing.get('source_path') in {stems['vocals'], analysis['song_path']}
            and timing.get('source_sha256') == checksum(local(data, timing['source_path']))
            and timing.get('lyrics_sha256') == digest(lyrics.read_bytes())
            and timing.get('alignment_sha256') == canonicalizer(measured, 'alignment', root / 'alignment-canonical.json')
            and timing.get('timing_evidence') == 'known_text_alignment' and timing.get('timing_method') == 'attention_dtw', 'MEASUREMENT')
        check(all(finite(item.get('start')) and finite(item.get('end')) and 0 <= item['start'] <= item['end'] <= analysis['duration_s']
            for item in aligned), 'MEASUREMENT')
        words = [word for line in aligned for word in line.get('words', [])]
        matched = sum(word.get('score') is not None for word in words)
        check(timing.get('lyric_token_count') == len(words) > 0 and timing.get('matched_token_count') == matched
            and type(timing.get('marker_count')) is int and timing['marker_count'] >= 0
            and (timing['marker_count'] > 0 or matched / len(words) >= 0.7), 'MEASUREMENT')
    recognized = analysis.get('recognized_lyrics')
    if recognized is not None:
        recognition = proof.get('recognized_lyrics', {})
        check(isinstance(recognized, dict) and recognized.get('reviewed') is False
            and recognition.get('source_path') in {analysis['song_path'], stems['vocals']}
            and recognition.get('source_sha256') == checksum(local(data, recognition['source_path']))
            and recognition.get('transcript_sha256') == canonicalizer(measured, 'recognized_lyrics', root / 'recognized-canonical.json'), 'MEASUREMENT')
    delivery = owner.get('delivery', {})
    check(all(delivery.get(k) is True for k in ('nativeAssembly', 'nativeFullFilmReview', 'nativeStyleReview',
        'nativeExportWorkspace', 'nativeSaveDestination', 'posterSelectedRemovedRestored', 'movieAndPosterPublished',
        'actualOutputQC', 'changedOutputRejected')), 'PROJECT')
    movie = local(root, delivery.get('movie'))
    check(checksum(movie) == delivery.get('outputSHA256') and movie.stat().st_size > 1000, 'PROJECT')
    poster = movie.with_suffix('.poster.png')
    check(poster.is_file() and checksum(poster) == delivery.get('posterSHA256'), 'PROJECT')
    png(root, poster.relative_to(root).as_posix())
    exported = states['actual exported movie and poster'][0]
    check(exported.get('outputSHA256') == delivery.get('outputSHA256')
        and exported.get('posterSHA256') == delivery.get('posterSHA256')
        and exported.get('filmReviewSHA256') == checksum(local(root, 'owner-v2-film-review.json'))
        and exported.get('timelineSHA256') == read_json(local(root, 'owner-v2-film-review.json')).get('timeline', {}).get('sha256'), 'PROJECT')
    decoded = delivery.get('decodedMedia', {})
    check(all(type(decoded.get(k)) is int and decoded[k] > 0 for k in ('verifiedShots', 'verifiedFrames', 'verifiedAudioClips', 'decodedAudioSamples'))
        and finite(decoded.get('audioRMS')) and decoded['audioRMS'] > 0.001 and finite(decoded.get('audioCorrelation'))
        and decoded['audioCorrelation'] >= 0.98
        and decoded['verifiedFrames'] == 3 * decoded['verifiedShots'] and finite(decoded.get('decodedDurationSeconds')) and decoded['decodedDurationSeconds'] > 0, 'PROJECT')
    return owner


def validate_report(root, fixture_root, manifest, selected, canonicalizer=foundation_field):
    report = read_json(local(root, 'provenance.json'))
    analysis_path = local(root, 'analysis.json'); analysis = read_json(analysis_path)
    check(report.get('schema') == 'nexgenvideo.example-analysis-report/v6'
        and report.get('fixture_reference') == FIXTURE_REPO + '@' + selected['fixtureDigest']
        and report.get('fixture_tree_sha256') == manifest['tree_sha256'] and report.get('commit') == selected['productSourceSHA']
        and report.get('run_id') == str(selected['nativeRunID']) and report.get('run_attempt') == '1'
        and report.get('pack_version') == '0.6.0' and report.get('acceptance') == {'status': 'passed', 'failures': []}, 'ANALYSIS')
    datasets = [d for d in manifest['datasets'] if d['id'] == report.get('dataset')]
    check(len(datasets) == 1, 'FIXTURE'); dataset = datasets[0]
    check(report.get('source_files') == dataset['files'] and report.get('expectations') == dataset['expectations'], 'FIXTURE')
    expected = dataset['expectations']['audio']
    song = local(fixture_root, expected['path'])
    check(analysis.get('schema') == 'analysis/v3' and analysis.get('song_sha256') == checksum(song)
        and analysis.get('song_path') == 'audio/' + song.name, 'ANALYSIS')
    summary = report.get('analysis', {})
    check(summary.get('sha256') == checksum(analysis_path) and summary.get('duration_s') == analysis.get('duration_s')
        and summary.get('bpm') == analysis.get('bpm') and summary.get('beat_count') == len(analysis['beats'])
        and summary.get('downbeat_count') == len(analysis['downbeats']) and summary.get('section_count') == len(analysis['sections']), 'ANALYSIS')
    resolution = analysis['structure_resolution'];hierarchy = resolution.get('hierarchy') or {}
    check(all(summary.get(k) == value for k, value in {
        'artifact': 'analysis.json', 'structure_status': resolution.get('status'), 'structure_method': resolution.get('method'),
        'candidate_boundary_count': resolution.get('candidate_boundary_count'), 'accepted_boundary_count': resolution.get('accepted_boundary_count'),
        'segment_count': len(hierarchy.get('segments', [])), 'phrase_count': len(hierarchy.get('phrases', [])),
        'alignment_timing_evidence': resolution.get('alignment_timing_evidence'), 'alignment_timing_method': resolution.get('alignment_timing_method'),
        'boundary_evidence_kinds': [r['kind'] for r in resolution.get('boundary_evidence', []) if isinstance(r.get('kind'), str)],
        'section_boundary_times_s': [r['start'] for r in analysis['sections'][1:]]}.items()), 'ANALYSIS')
    numeric_expectations(analysis, expected)
    diagnostics = analysis.get('stage_diagnostics', [])
    expected_stages = {'native_dsp': 'succeeded', 'music_understanding': 'unavailable', 'stem_separation': 'succeeded',
        'neural_beat_grid': 'succeeded', 'chord_recognition': 'succeeded'}
    lyrics = [local(fixture_root, f['path']) for f in dataset['files'] if f['kind'] == 'lyrics']
    check(len(lyrics) <= 1, 'FIXTURE')
    if lyrics:expected_stages.update(lyrics_input='succeeded', lyrics_alignment='succeeded')
    for stage, status in expected_stages.items():
        check([d.get('status') for d in diagnostics if d.get('stage') == stage] == [status], 'ANALYSIS')
    check(analysis.get('downbeat_source') == 'beat-transformer', 'ANALYSIS')
    project_evidence(root, analysis, song, lyrics[0] if lyrics else None, canonicalizer)
    return report


def public_receipt(value):
    check(isinstance(value, dict) and set(value) == PUBLIC_KEYS and value.get('schema') == 'private-analysis-verification/v1'
        and value.get('status') in {'QUALIFIED', 'FAILED'} and value.get('errorCode') in {None, *ERRORS}, 'INPUT')
    for key in ('reportDigest', 'fixtureDigest'):check(value[key] is None or isinstance(value[key], str) and DIGEST.fullmatch(value[key]), 'INPUT')
    for key in ('privateInventorySHA256', 'runtimeArtifactSHA256'):
        check(value[key] is None or isinstance(value[key], str) and SHA.fullmatch(value[key]), 'INPUT')
    for key in ('productSourceSHA', 'nativeHarnessSourceSHA', 'verificationHarnessSourceSHA'):
        check(value[key] is None or isinstance(value[key], str) and COMMIT.fullmatch(value[key]), 'INPUT')
    for key in ('productRunID', 'runtimeArtifactID', 'nativeRunID', 'nativeJobID', 'verificationRunID'):
        check(value[key] is None or type(value[key]) is int and value[key] > 0, 'INPUT')
    check(isinstance(value['checks'], dict) and set(value['checks']) == set(CHECKS)
        and all(type(v) is bool for v in value['checks'].values()), 'INPUT')
    if value['status'] == 'QUALIFIED':
        check(value['errorCode'] is None and all(value['checks'].values())
            and all(value[key] is not None for key in PUBLIC_KEYS - {'errorCode'}), 'INPUT')
    else:check(value['errorCode'] in ERRORS and not all(value['checks'].values()), 'INPUT')
    return value


def selected_origin():
    selected = validate_reuse(os.environ.get('REPORT_REUSE_JSON', ''))
    if selected is not None:return selected
    run = api('actions/runs/' + os.environ['GITHUB_RUN_ID'])
    jobs = api(f"actions/runs/{run['id']}/attempts/1/jobs?per_page=100")
    matches = [j for j in jobs['jobs'] if all(any(s.get('name') == name for s in j.get('steps', [])) for name in NATIVE_STEPS)]
    check(len(matches) == 1, 'ORIGIN')
    return {'runID': run['id'], 'sourceSHA': run['head_sha'], 'jobID': matches[0]['id'],
        'reportDigest': os.environ['PRIVATE_REPORT_REFERENCE'].removeprefix(REPORT_REPO + '@'),
        'fixtureDigest': os.environ['FIXTURE_DIGEST'], 'pointerArtifactID': int(os.environ['POINTER_ARTIFACT_ID']),
        'pointerArtifactSHA256': os.environ['POINTER_ARTIFACT_SHA256'].removeprefix('sha256:')}


def runtime_binding(runtime, bound, identity):
    check(runtime.get('schema') in {'nexgenvideo/retained-release-runtime/1', 'nexgenvideo/retained-release-runtime/2'}, 'RUNTIME')
    for key in ('productSourceSHA', 'producerRunID', 'producerAttempt', 'producerJobID', 'runtimeArtifactID', 'runtimeArtifactSHA256'):
        check(runtime.get(key) == bound.get(key), 'RUNTIME')
    check(runtime.get('executionRunID') == str(identity['nativeRunID']) and runtime.get('executionAttempt') == '1'
        and runtime.get('harnessSourceSHA') == identity['nativeHarnessSourceSHA']
        and all(isinstance(runtime.get(key), str) and SHA.fullmatch(runtime[key]) for key in
            ('archiveSHA256', 'appTreeSHA256', 'executableSHA256', 'runtimeInputSHA256')), 'RUNTIME')


def verify(output, work):
    receipt = dict.fromkeys(PUBLIC_KEYS)
    receipt.update(schema='private-analysis-verification/v1', status='FAILED', errorCode='INTERNAL', checks=dict.fromkeys(CHECKS, False))
    try:
        selected = selected_origin()
        work.mkdir(parents=True, exist_ok=False)
        identity, origin = native_origin(selected, work)
        receipt.update({k: identity[k] for k in ('reportDigest', 'fixtureDigest', 'productRunID', 'productSourceSHA',
            'runtimeArtifactID', 'runtimeArtifactSHA256', 'nativeRunID', 'nativeHarnessSourceSHA')})
        receipt.update(nativeJobID=origin['job']['id'], verificationRunID=int(os.environ['GITHUB_RUN_ID']),
            verificationHarnessSourceSHA=os.environ['GITHUB_SHA'])
        receipt['checks']['native_origin'] = True
        package_isolation()
        foundation_probe(work)
        oci(work / 'report-oci', REPORT_REPO, identity['reportDigest'], 'report')
        oci(work / 'fixture-oci', FIXTURE_REPO, identity['fixtureDigest'], 'fixture')
        receipt['checks']['oci_descriptors'] = True
        from example_fixture_bundle import load_manifest, extract_archive, assert_not_tracked, assert_not_in_history
        manifest = load_manifest(work / 'fixture-oci/fixtures.manifest.json')
        fixture_root = extract_archive(work / 'fixture-oci/examples.tar.gz', work / 'fixture-data', manifest)
        assert_not_tracked(Path.cwd(), manifest); assert_not_in_history(Path.cwd(), manifest)
        receipt['checks']['fixture_bytes'] = True
        root = extract_report(work / 'report-oci/musicvideo-acceptance.tar.gz', work / 'report')
        for name in LAYERS:
            if name != 'musicvideo-acceptance.tar.gz':check(local(root, name).read_bytes() == (work / 'report-oci' / name).read_bytes(), 'OCI')
        runtime = read_json(local(root, 'retained-runtime.json'))
        from retained_release_runtime import bind
        from retained_packaging import environment_selectors
        _, bound = bind(identity['productRunID'], identity['productSourceSHA'], identity['runtimeArtifactID'],
            identity['runtimeArtifactSHA256'], packaging=environment_selectors())
        runtime_binding(runtime, bound, identity)
        receipt['checks']['runtime_origin'] = True
        validate_report(root, fixture_root, manifest, identity)
        for name in CHECKS[4:-1]:receipt['checks'][name] = True
        receipt['privateInventorySHA256'] = digest(json.dumps(inventory(work), ensure_ascii=True, separators=(',', ':')).encode())
        receipt['checks']['private_inventory'] = True
        receipt.update(status='QUALIFIED', errorCode=None)
    except BaseException as error:
        receipt['status'] = 'FAILED'
        receipt['errorCode'] = str(error) if isinstance(error, VerificationError) and str(error) in ERRORS else 'INTERNAL'
        receipt['checks']['private_inventory'] = False
    public_receipt(receipt)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open('x') as stream:json.dump(receipt, stream, sort_keys=True);stream.write('\n')
    print('Private analysis verification: ' + receipt['status'] + (':' + receipt['errorCode'] if receipt['errorCode'] else ''))
    return receipt['status'] == 'QUALIFIED'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=('validate-input', 'write-pointer', 'isolation', 'verify', 'validate-public', 'validate-intake', 'fixture-source', 'fixture-extract'))
    parser.add_argument('--output', type=Path)
    parser.add_argument('--work', type=Path)
    args = parser.parse_args()
    try:
        if args.action == 'validate-input':
            selected = validate_reuse(os.environ.get('REPORT_REUSE_JSON', ''))
            if selected:
                check(all(os.environ.get(k) for k in ('ORIGINAL_RUN', 'ORIGINAL_SOURCE', 'ORIGINAL_ARTIFACT', 'ORIGINAL_DIGEST')), 'INPUT')
        elif args.action in {'fixture-source', 'fixture-extract'}:
            from example_fixture_bundle import load_manifest, extract_archive, assert_not_tracked, assert_not_in_history
            manifest = load_manifest(args.work / 'fixtures.manifest.json')
            extract_archive(args.work / 'examples.tar.gz', args.output, manifest)
            if args.action == 'fixture-source':
                assert_not_tracked(Path.cwd(), manifest);assert_not_in_history(Path.cwd(), manifest)
        elif args.action == 'validate-intake':
            from musicvideo_intake_evidence import validate
            validate(args.work, read_json(local(args.work, 'hostflow.json')))
        elif args.action == 'write-pointer':write_pointer(args.output)
        elif args.action == 'isolation':package_isolation()
        elif args.action == 'validate-public':public_receipt(read_json(args.output))
        else:return 0 if verify(args.output, args.work) else 1
        return 0
    except BaseException as error:
        code = str(error) if isinstance(error, VerificationError) and str(error) in ERRORS else 'INTERNAL'
        print('Private analysis verification failed: ' + code)
        return 1


if __name__ == '__main__':
    sys.exit(main())
