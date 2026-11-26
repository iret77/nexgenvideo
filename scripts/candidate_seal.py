"""Seal one release candidate only when its signed product and its native Release tests both passed."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import zipfile

from retained_app_test_products import api, archive_bytes, checksum, download, require, verify_artifact


REPOSITORY = 'iret77/nexgenvideo'
SCHEMA = 'nexgenvideo/release-candidate-seal/1'
SEAL_LABELS = ('ubuntu-24.04',)
SEALED_TESTS = 'sealed-release-tests/v1'
BINDING = 'release-candidate-binding'
TESTS_RESULT = 'release-tests-result'
BASE_MEMBERS = {'manifest.json', 'release-workspace-producer.json'}
PRODUCT_MEMBERS = BASE_MEMBERS | {'notarization-proof.json', 'release-image-check.json'}
TEST_STEP = 'Test the exact release configuration'
LIMIT = 16 * 1024**2
SHA = re.compile('[a-f0-9]{64}')


def canonical(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def job_named(jobs, name, run_id, source, labels, *, conclusion='success'):
    matches = [job for job in jobs if job.get('name') == name]
    require(len(matches) == 1, 'Missing or ambiguous candidate job: ' + name)
    job = matches[0]
    require(job.get('labels') == list(labels) and job.get('status') == 'completed'
            and job.get('conclusion') == conclusion and job.get('run_id') == run_id
            and job.get('head_sha') == source and job.get('run_attempt') == 1,
            'Candidate job identity differs: ' + name)
    return job


def release_run(run_id, source):
    run = api(f'actions/runs/{run_id}')
    require(run.get('id') == run_id and run.get('head_sha') == source and run.get('run_attempt') == 1
            and run.get('path') == '.github/workflows/release.yml' and run.get('event') == 'workflow_dispatch'
            and run.get('repository', {}).get('full_name') == REPOSITORY,
            'Candidate run identity differs')
    jobs = api(f'actions/runs/{run_id}/attempts/1/jobs?per_page=100')
    require(jobs.get('total_count') == len(jobs.get('jobs', [])), 'Incomplete candidate job inventory')
    return run, jobs['jobs']


def acquire(run, job, name, allowed):
    inventory = api(f"actions/runs/{run['id']}/artifacts?name={name}&per_page=100")
    require(inventory.get('total_count') == len(inventory.get('artifacts', [])) == 1,
            'Missing or ambiguous candidate artifact: ' + name)
    item = api('actions/artifacts/' + str(inventory['artifacts'][0]['id']))
    require(isinstance(item.get('digest'), str) and item['digest'].startswith('sha256:')
            and 0 < item.get('size_in_bytes', 0) <= LIMIT, 'Invalid candidate artifact: ' + name)
    verify_artifact(item, run, job, item['id'], item['digest'][7:], name)
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / 'artifact.zip'
        download(item, path)
        require(checksum(path) == item['digest'][7:], 'Candidate artifact changed: ' + name)
        with zipfile.ZipFile(path) as archive:
            names = set(archive.namelist())
            require(len(names) == len(archive.namelist()) and any(names == members for members in allowed),
                    'Unexpected candidate artifact entries: ' + name)
            files = {member: json.loads(archive_bytes(archive, member, LIMIT)) for member in names}
    return files, {'artifactID': item['id'], 'sha256': item['digest'][7:], 'jobID': job['id']}


def fresh_suite(suite, source):
    require(isinstance(suite, dict) and suite.get('sourceSHA') == source and suite.get('completed') is True
            and suite.get('configuration') == 'release' and suite.get('scope') == 'all' and suite.get('filter') == ''
            and not any(key in suite for key in ('retainedBackends', 'freshTestExecutions', 'reusedTestExecutions'))
            and all('reusedFrom' not in phase for phase in suite.get('phases', [])),
            'Release tests did not complete freshly for this source')
    return suite


def product_evidence(files, manifest, producer):
    from notarization_proof import summary, validate
    proof = validate(files['notarization-proof.json'], producer['dmgSHA256'])
    image = files['release-image-check.json']
    require(proof['mode'] == manifest['notaryMode'] and producer.get('notarization') == summary(proof),
            'Notarization proof differs from the signed candidate')
    expected = image.get('expected', {})
    require(image.get('schema') == 'nexgenvideo/release-image-check/1' and image.get('passed') is True
            and image.get('dmgSHA256') == producer['dmgSHA256']
            and expected.get('build') == manifest['identity']['build']
            and expected.get('version') == manifest['identity']['version']
            and expected.get('sourceSHA') == manifest['sourceSHA'] and expected.get('notaryMode') == proof['mode'],
            'Scripted image check is missing or failed')
    return {'notaryMode': proof['mode'], 'notarizationSubmissionID': proof['submissionID'],
            'appCDHash': proof['app']['cdhash'], 'imageCheckSHA256': canonical(image)}


def seal(output):
    environment = os.environ
    require(environment.get('GITHUB_REPOSITORY') == REPOSITORY and environment.get('GITHUB_JOB') == 'candidate-seal'
            and environment.get('GITHUB_RUN_ATTEMPT') == '1', 'Only the first candidate-seal attempt may seal')
    run_id, harness = int(environment['GITHUB_RUN_ID']), environment['GITHUB_SHA']
    run, jobs = release_run(run_id, harness)
    release = job_named(jobs, 'release', run_id, harness, ('macrunner',))
    files, binding = acquire(run, release, BINDING, (BASE_MEMBERS, PRODUCT_MEMBERS))
    manifest, producer = files['manifest.json'], files['release-workspace-producer.json']
    product = manifest.get('sourceSHA')
    app = producer.get('app', {})
    require(isinstance(product, str) and re.fullmatch('[a-f0-9]{40}', product)
            and producer.get('sourceSHA') == product == app.get('NGVSourceCommit')
            and producer.get('runID') == str(run_id) and producer.get('runAttempt') == '1'
            and SHA.fullmatch(producer.get('dmgSHA256', ''))
            and app.get('CFBundleVersion') == manifest.get('identity', {}).get('build')
            and app.get('CFBundleShortVersionString') == manifest['identity'].get('version'),
            'Signed manifest and final DMG product differ')
    evidence = manifest.get('nativeEvidence', {})
    record = {'schema': SCHEMA, 'harnessSourceSHA': harness, 'sourceSHA': product, 'runID': run_id, 'attempt': 1,
              'signedManifestSHA256': canonical(manifest), 'signedManifestRunID': manifest.get('runID'),
              'identity': manifest['identity'], 'appTreeSHA256': manifest.get('appTreeSHA256'),
              'dmgSHA256': producer['dmgSHA256'], 'notaryMode': manifest.get('notaryMode', 'app-and-dmg'),
              'releaseJobID': release['id'], 'binding': binding}
    if evidence.get('schema') == SEALED_TESTS:
        require(set(files) == PRODUCT_MEMBERS and product == harness and evidence.get('sourceSHA') == product
                and type(evidence.get('runID')) is int and evidence['runID'] == manifest.get('runID'),
                'Separately sealed candidate lacks its complete product evidence')
        tests_run, tests_jobs = (run, jobs) if evidence['runID'] == run_id else release_run(evidence['runID'], product)
        tester = job_named(tests_jobs, 'release-tests', tests_run['id'], product, ('macrunner',))
        steps = {step.get('name'): step.get('conclusion') for step in tester.get('steps', [])}
        require(steps.get(TEST_STEP) == 'success', 'Native Release tests did not pass')
        result, origin = acquire(tests_run, tester, TESTS_RESULT, ({'suite.json'},))
        record['tests'] = {'schema': 'fresh-release-tests/v1', 'suite': fresh_suite(result['suite.json'], product),
                           'origin': dict(origin, runID=tests_run['id'])}
        record['product'] = product_evidence(files, manifest, producer)
    else:
        require(isinstance(evidence.get('schema'), str) and evidence['schema'] and 'notaryMode' not in manifest,
                'Signed manifest carries no Release test evidence')
        record['tests'] = {'schema': evidence['schema'], 'embedded': True}
        if set(files) == PRODUCT_MEMBERS:
            record['product'] = product_evidence(files, dict(manifest, notaryMode='app-and-dmg'), producer)
    verify_record(record, harness, run_id)
    output.mkdir(parents=True, exist_ok=False)
    (output / 'release-candidate-seal.json').write_text(json.dumps(record, indent=2, sort_keys=True) + '\n')
    print('Sealed candidate ' + product + ' DMG ' + producer['dmgSHA256'] + ' with ' + record['tests']['schema'])
    return record


def verify_record(record, harness, run_id):
    tests = record.get('tests', {}) if isinstance(record, dict) else {}
    require(isinstance(record, dict) and record.get('schema') == SCHEMA and record.get('harnessSourceSHA') == harness
            and record.get('runID') == run_id and record.get('attempt') == 1
            and SHA.fullmatch(str(record.get('dmgSHA256', ''))) and SHA.fullmatch(str(record.get('signedManifestSHA256', '')))
            and record.get('notaryMode') in ('dmg-only', 'app-and-dmg')
            and isinstance(record.get('identity'), dict) and isinstance(tests.get('schema'), str),
            'Candidate seal is malformed or belongs to another run')
    if tests.get('embedded') is not True:
        require(tests['schema'] == 'fresh-release-tests/v1' and 'product' in record
                and fresh_suite(tests.get('suite'), record['sourceSHA']) is not None
                and record['product'].get('notaryMode') == record['notaryMode'],
                'Candidate seal lacks fresh Release tests or product evidence')
    return record


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('--output', required=True, type=Path)
    seal(parser.parse_args().output)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, zipfile.BadZipFile) as error:
        raise SystemExit('::error::Candidate is void: ' + str(error))
