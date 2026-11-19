import argparse
import hashlib
import json
import os
from pathlib import Path

from retained_app_test_products import checksum, require


RECEIPT = 'engine-test-preparation.json'
ENGINE_FILES = (
    'carrier-acquisition.json',
    'current-environment.json',
    'engine-swift-testing/console.log',
    'engine-swift-testing/events.jsonl',
    'original-job.log',
    'original.zip',
)


def identity(bound_bytes, expected):
    criterion = json.dumps(expected, sort_keys=True, separators=(',', ':')).encode()
    return {
        'schema': 'compiled-app-engine-test-preparation/v1',
        'sourceSHA': os.environ['GITHUB_SHA'],
        'runID': int(os.environ['GITHUB_RUN_ID']),
        'attempt': int(os.environ['GITHUB_RUN_ATTEMPT']),
        'bindingSHA256': hashlib.sha256(bound_bytes).hexdigest(),
        'engineCriteriaSHA256': hashlib.sha256(criterion).hexdigest(),
    }


def evidence_files(root):
    folder = root / 'retained-engine'
    result = {}
    for name in ENGINE_FILES:
        path = folder / name
        require(path.is_file() and path.absolute() == path.resolve(), 'Prepared Engine evidence is missing or redirected')
        result[name] = {'bytes': path.stat().st_size, 'sha256': checksum(path)}
    return result


def prepare(root):
    import compiled_app_release as release

    release.native_guard(root)
    require('COMPILED_APP_ENGINE_PREPARED' not in os.environ, 'Engine preparation cannot consume a receipt')
    require(not (root / RECEIPT).exists(), 'Engine preparation already completed')
    bound_bytes = (root / 'bound.json').read_bytes()
    bound = json.loads(bound_bytes)
    require(bound['sourceSHA'] == os.environ['GITHUB_SHA'] and bound['runID'] == int(os.environ['GITHUB_RUN_ID'])
        and bound['nativeSourceObjects'] == release.source_objects('HEAD'), 'Compiled App test source changed')
    if bound.get('prepared', {}).get('cohortV2'):
        import app_cohort_v2
        import compiled_current_core_reuse
        if compiled_current_core_reuse.matches(bound):
            return
        criteria = app_cohort_v2.criteria()
    else:
        import compiled_core_reuse
        if release.APP_SOURCE == compiled_core_reuse.origin()['appSourceSHA']:
            return
        criteria = release.criteria()
    expected = criteria['modules']['engine']
    evidence = release.retained_engine_evidence(root, expected)
    require((root / 'bound.json').read_bytes() == bound_bytes, 'Compiled App binding changed during Engine preparation')
    receipt = {'identity': identity(bound_bytes, expected), 'files': evidence_files(root), 'evidence': evidence}
    with (root / RECEIPT).open('x') as stream:
        json.dump(receipt, stream, sort_keys=True)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())


def consume(root, expected):
    receipt = json.loads((root / RECEIPT).read_bytes())
    require(receipt.get('identity') == identity((root / 'bound.json').read_bytes(), expected),
        'Prepared Engine source, attempt, product binding or criteria differ')
    require(receipt.get('files') == evidence_files(root), 'Prepared Engine evidence changed')
    return receipt['evidence']


if __name__ == '__main__':
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument('root', type=Path)
    prepare(parser.parse_args().root)
