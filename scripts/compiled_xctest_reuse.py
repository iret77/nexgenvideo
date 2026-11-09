import hashlib
import json
import os
from pathlib import Path
import re
import zipfile

from retained_app_test_products import api, archive_bytes, checksum, download, require, verify_artifact
from verify_swift_test_output import ANSI


RUN = 42623486001
JOB = 129181460988
SOURCE = 'cde0a25e1622b0aa1c6802da6b42c239591c2bff'
ARTIFACT = 13679065595
DIGEST = 'c0c9b18604f9b6afa2c44fd960aac45689a7073fc51e500a124459d299136af1'
LOG_DIGEST = '8492af1b2f4b89b33b379f8787631af2335bd22e31ac87b01180800b1402cbe2'
IMAGE_SHA = '16920ea94149a378af41db4f5a684e3d2f1163a5c3a272c283ba67a9b37f36f9'
MEMBERS = {
    "bound.json": {
        "bytes": 6135416,
        "sha256": "69c31bfa718bf0035f0b698112826f07c680d35acff0ea0d7a504410af5275c8"
    },
    "native-tests.STARTED.json": {
        "bytes": 1171,
        "sha256": "6fd8cbb8a56fbd3f2f02d86099956961913b511d3f43f46bc55f507a266bd689"
    },
    "retained-engine/current-environment.json": {
        "bytes": 545,
        "sha256": "94836daa4da522eb551c6943483af87c759cc81391013fe9f026e24da96a934f"
    },
    "verify-test-bundle.argv.json": {
        "bytes": 179,
        "sha256": "f78ffd3374ff7caafdce1d397f9668f33fcc672567d2b8f540871e676635a906"
    },
    "verify-test-bundle.exit.json": {
        "bytes": 20,
        "sha256": "ff8ae5796bcef71911ff9c5c3eaea341819c471f669549e252b830106edd4305"
    },
    "verify-test-bundle.stderr": {
        "bytes": 0,
        "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    },
    "verify-test-bundle.stdout": {
        "bytes": 0,
        "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    },
    "xctest/command.json": {
        "bytes": 193,
        "sha256": "bd614b823a5f402467e80413a31042b2b1e647446d7d003482f6087567b0f234"
    },
    "xctest/console.log": {
        "bytes": 1430688,
        "sha256": "433a8bcc26dc89d1ee7131953c906689685c8635cffd1a2cec32a075aeab5992"
    },
    "xctest/process.json": {
        "bytes": 265,
        "sha256": "4e3502237f4fcb8382867fc8f0beb911888f19003de24d22cbf770248f69d775"
    }
}


def framework(raw, process, command, expected):
    require(process.get('exitCode') == 1 and type(process.get('pid')) is int and process['pid'] > 0
        and process.get('observation', {}).get('outputCapture') == {
            'eof': True, 'originalExitCode': 1, 'postExitDrainSeconds': 2}, 'Original mixed process identity differs')
    require(isinstance(command, list) and len(command) == 2 and Path(command[0]).name == 'xctest'
        and Path(command[1]).name == 'NexGenVideoTests.xctest', 'Original XCTest command was filtered or substituted')
    lines = ANSI.sub('', raw.decode()).splitlines()
    starts = [index for index, line in enumerate(lines) if re.fullmatch(r"Test Suite 'All tests' started at .+\.", line)]
    ends = [index for index, line in enumerate(lines) if re.fullmatch(r"Test Suite 'All tests' passed at .+\.", line)]
    swift = [index for index, line in enumerate(lines) if line == '◇ Test run started.']
    require(len(starts) == len(ends) == len(swift) == 1 and starts[0] < ends[0] < swift[0], 'XCTest did not finish before the unexpected Swift run')
    prefix = '\n'.join(lines[:swift[0]])
    started = re.findall(r"(?m)^Test Case '([^']+)' started\.$", prefix)
    passed = re.findall(r"(?m)^Test Case '([^']+)' passed \([0-9.]+ seconds\)\.$", prefix)
    require(len(started) == len(set(started)) == len(passed) == len(set(passed)) == 48
        and sorted(started) == sorted(passed) == sorted(expected)
        and not re.search(r"(?m)^Test (?:Case|Suite) '.+' failed", prefix), 'Original exact XCTest cases did not all complete successfully')
    summaries = [line.strip() for line in lines[ends[0] + 1:swift[0]]]
    require(len(summaries) == 1 and re.fullmatch(r'Executed 48 tests, with 0 failures \(0 unexpected\) in [0-9.]+ \([0-9.]+\) seconds', summaries[0]),
        'Original XCTest completion summary differs')
    require(len([line for line in lines[swift[0] + 1:] if re.fullmatch(
        r'✘ Test run with 3716 tests in 528 suites failed after [0-9.]+ seconds with 285 issues\.', line)]) == 1,
        'Original subsequent failed Swift run is missing')
    return {'schema': 'completed-xctest-subframework/v1', 'individualStartedIDs': sorted(started), 'individualPassedIDs': sorted(passed),
        'xctestFrameworkStarted': 1, 'xctestFrameworkCompleted': 1, 'xctestFrameworkFailures': 0,
        'xctestCompletedBeforeUnexpectedSwiftStart': True, 'originalProcessExitCode': 1, 'originalProcessEOF': True,
        'wholeProcessQualifiedAsSuccess': False, 'unexpectedSwiftTestingQualified': False,
        'pid': process['pid'], 'consoleSHA256': hashlib.sha256(raw).hexdigest()}


def verify(proof, expected, selected, native_objects, environment):
    require(proof.get('schema') == 'retained-current-candidate-xctest/v1' and proof.get('runID') == RUN
        and proof.get('sourceSHA') == SOURCE and proof.get('artifactID') == ARTIFACT and proof.get('artifactSHA256') == DIGEST
        and proof.get('fullRawSHA256') == LOG_DIGEST and proof.get('signedTestsImageSHA256') == IMAGE_SHA
        and proof.get('selected') == selected and proof.get('nativeSourceObjects') == native_objects
        and proof.get('originalEnvironment') == environment
        and proof.get('memberIdentities') == MEMBERS and proof.get('originalSignatureVerificationExitCode') == 0,
        'Retained current-candidate XCTest provenance differs')
    producer = proof.get('producer', {})
    origin, job, artifact = producer.get('run', {}), producer.get('job', {}), producer.get('artifact', {})
    require(origin.get('id') == RUN and origin.get('head_sha') == SOURCE and origin.get('run_attempt') == 1
        and origin.get('status') == 'completed' and origin.get('conclusion') == 'failure'
        and origin.get('workflow_id') == 303346287 and origin.get('path') == '.github/workflows/release.yml'
        and origin.get('event') == 'workflow_dispatch' and origin.get('actor', {}).get('login') == 'iret77'
        and origin.get('repository', {}).get('full_name') == 'iret77/nexgenvideo'
        and job.get('id') == JOB and job.get('run_id') == RUN and job.get('head_sha') == SOURCE
        and job.get('run_attempt') == 1 and job.get('name') == 'release-build'
        and job.get('status') == 'completed' and job.get('conclusion') == 'failure' and job.get('labels') == ['macrunner'],
        'Retained XCTest original failed producer or job differs')
    verify_artifact(artifact, origin, job, ARTIFACT, DIGEST, f'release-compiled-app-evidence-{RUN}-a1')
    scope = proof.get('framework', {})
    require(scope.get('schema') == 'completed-xctest-subframework/v1' and scope.get('individualStartedIDs') == sorted(expected)
        and scope.get('individualPassedIDs') == sorted(expected) and len(expected) == len(set(expected)) == 48
        and scope.get('xctestFrameworkStarted') == scope.get('xctestFrameworkCompleted') == 1
        and scope.get('xctestFrameworkFailures') == 0 and scope.get('xctestCompletedBeforeUnexpectedSwiftStart') is True
        and scope.get('originalProcessExitCode') == 1 and scope.get('originalProcessEOF') is True
        and scope.get('wholeProcessQualifiedAsSuccess') is False and scope.get('unexpectedSwiftTestingQualified') is False
        and scope.get('pid') == 1729 and scope.get('consoleSHA256') == MEMBERS['xctest/console.log']['sha256'],
        'Retained XCTest framework scope or original process truth differs')
    return proof


def acquire(root, bound, expected, environment):
    from verified_pr_source_checks import read_api
    original = api('actions/runs/' + str(RUN))
    jobs = api(f'actions/runs/{RUN}/attempts/1/jobs?per_page=100')
    require(original.get('id') == RUN and original.get('head_sha') == SOURCE and original.get('run_attempt') == 1
        and original.get('status') == 'completed' and original.get('conclusion') == 'failure'
        and original.get('workflow_id') == 303346287 and original.get('path') == '.github/workflows/release.yml'
        and original.get('event') == 'workflow_dispatch' and original.get('actor', {}).get('login') == 'iret77'
        and original.get('repository', {}).get('full_name') == 'iret77/nexgenvideo'
        and jobs.get('total_count') == len(jobs.get('jobs', [])), 'Original XCTest producer differs')
    selected_jobs = [row for row in jobs['jobs'] if row['id'] == JOB]
    require(len(selected_jobs) == 1, 'Original XCTest producer job is missing')
    job = selected_jobs[0]
    require(job.get('run_id') == RUN and job.get('head_sha') == SOURCE and job.get('run_attempt') == 1
        and job.get('name') == 'release-build' and job.get('status') == 'completed'
        and job.get('conclusion') == 'failure' and job.get('labels') == ['macrunner'], 'Original XCTest job differs')
    artifact = api('actions/artifacts/' + str(ARTIFACT))
    verify_artifact(artifact, original, job, ARTIFACT, DIGEST, f'release-compiled-app-evidence-{RUN}-a1')
    folder = root / 'retained-current-xctest'; folder.mkdir()
    download(artifact, folder / 'original.zip')
    raw_log = read_api(f'actions/jobs/{JOB}/logs', 4_000_000)
    require(hashlib.sha256(raw_log).hexdigest() == LOG_DIGEST, 'Original complete XCTest producer log differs')
    (folder / 'original-job.log').write_bytes(raw_log)
    records = {}
    with zipfile.ZipFile(folder / 'original.zip') as archive:
        for name, expected_record in MEMBERS.items():
            raw = archive_bytes(archive, name, 16 * 1024**2)
            require(len(raw) == expected_record['bytes'] and hashlib.sha256(raw).hexdigest() == expected_record['sha256'],
                'Original XCTest evidence record differs: ' + name)
            target = folder / name; target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(raw)
            records[name] = raw
    prior = json.loads(records['bound.json'])
    require(prior.get('schema') == 'compiled-app-release-binding/v1' and prior.get('sourceSHA') == SOURCE and prior.get('runID') == RUN
        and prior.get('appSourceSHA') == bound['appSourceSHA'] and prior.get('nativeSourceObjects') == bound['nativeSourceObjects']
        and prior.get('selected') == bound['selected'] and prior['products']['tests']['receipt'] == bound['products']['tests']['receipt'],
        'Current XCTest compiler inputs or exact original selectors changed')
    image = Path(bound['products']['tests']['output'])
    require(checksum(image) == IMAGE_SHA and json.loads(records['verify-test-bundle.exit.json']) == {'exitCode': 0},
        'Current signed XCTest image or retained native signature verification differs')
    original_environment = json.loads(records['retained-engine/current-environment.json'])
    require(original_environment['current'] == environment['current'] == environment['original'] == original_environment['original']
        and original_environment['architecture'] == environment['architecture'] == 'arm64', 'Current XCTest runtime context changed')
    proof = {'schema': 'retained-current-candidate-xctest/v1', 'runID': RUN, 'sourceSHA': SOURCE, 'artifactID': ARTIFACT,
        'artifactSHA256': DIGEST, 'fullRawSHA256': LOG_DIGEST, 'signedTestsImageSHA256': IMAGE_SHA,
        'selected': bound['selected'], 'nativeSourceObjects': bound['nativeSourceObjects'], 'originalEnvironment': environment,
        'memberIdentities': MEMBERS, 'originalSignatureVerificationExitCode': 0,
        'producer': {'run': original, 'job': job, 'artifact': artifact},
        'framework': framework(records['xctest/console.log'], json.loads(records['xctest/process.json']),
            json.loads(records['xctest/command.json']), expected)}
    verify(proof, expected, bound['selected'], bound['nativeSourceObjects'], environment)
    with (folder / 'verified.json').open('x') as stream:
        json.dump(proof, stream, indent=2); stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
    return proof
