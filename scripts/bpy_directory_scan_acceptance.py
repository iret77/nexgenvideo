import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import time


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def validate(proof, process_id):
    if not isinstance(proof, dict) or proof.get('schema') != 'nexgenvideo/bpy-directory-deletion/1':
        raise ValueError('Missing native directory deletion evidence')
    if proof.get('events') != ['enumerated', 'unlinked', 'missing', 'completed']:
        raise ValueError('The native scanner did not observe the forced deletion in order')
    for key in ['processIdentifier', 'queuedDevice', 'queuedInode', 'retainedDevice', 'retainedInode',
                'baselineFiles', 'interruptedFiles', 'followupFiles', 'payloadBytes', 'retainedBytes',
                'interruptedRetainedBytes', 'followupRetainedBytes']:
        if type(proof.get(key)) is not int or proof[key] <= 0:
            raise ValueError('Invalid native integer: ' + key)
    for key in ['queuedDirectoryBytes', 'interruptedDirectoryBytes']:
        if type(proof.get(key)) is not int or proof[key] < 0:
            raise ValueError('Invalid native directory allocation: ' + key)
    if (proof['processIdentifier'] != process_id or proof['queuedDevice'] != proof['retainedDevice']
            or proof['queuedInode'] == proof['retainedInode']
            or proof['queuedDirectoryBytes'] != proof['interruptedDirectoryBytes']
            or [proof[key] for key in ['baselineFiles', 'interruptedFiles', 'followupFiles']] != [3, 2, 1]
            or proof['payloadBytes'] != 8192 or proof['retainedBytes'] < proof['payloadBytes']
            or proof['interruptedRetainedBytes'] != proof['retainedBytes']
            or proof['followupRetainedBytes'] != proof['retainedBytes']):
        raise ValueError('The native scanner lost identity or retained-file accounting')
    expected = hashlib.sha256(bytes([0xa5]) * 8192).hexdigest()
    if proof.get('payloadSHA256') != expected or proof.get('retainedSHA256') != expected:
        raise ValueError('The retained file bytes changed')


def run(app, output, source_sha):
    if platform.system() != 'Darwin':
        raise ValueError('The directory scanner must execute on macOS 26')
    version = subprocess.check_output(['/usr/bin/sw_vers', '-productVersion'],
                                     env=dict(os.environ, SYSTEM_VERSION_COMPAT='0'), text=True, timeout=10).strip()
    if version.split('.')[0] != '26':
        raise ValueError('The directory scanner must execute on macOS 26')
    if not re.fullmatch(r'[0-9a-f]{40}', source_sha):
        raise ValueError('An exact source SHA is required')
    binary = app / 'Contents/XPCServices/NexGenVideoBpyService0.xpc/Contents/MacOS/NexGenVideoBpyService'
    before = digest(binary)
    output.mkdir(parents=True, exist_ok=False)
    receipt = {'sourceSHA': source_sha, 'serviceSHA256': before, 'osVersion': version, 'completed': False,
               'scope': 'Direct execution of the bundled native scanner; not XPC sandbox or bpy acceptance'}
    started = time.monotonic()
    process = None
    try:
        with (output / 'stdout.json').open('xb') as stdout, (output / 'stderr.log').open('xb') as stderr:
            process = subprocess.Popen([str(binary), '--selftest-directory-deletion'],
                                       stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr)
            receipt['processIdentifier'] = process.pid
            try:
                code = process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                raise ValueError('The directly owned directory probe timed out') from None
        receipt['exitCode'] = code
        if code != 0:
            raise ValueError('The native directory probe failed; inspect original stderr')
        proof = json.loads((output / 'stdout.json').read_text())
        validate(proof, process.pid)
        if digest(binary) != before:
            raise ValueError('The bundled service changed during the probe')
        receipt.update(completed=True, proof=proof)
    finally:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait()
        receipt['processReaped'] = process is not None and process.poll() is not None
        receipt['elapsedSeconds'] = time.monotonic() - started
        (output / 'result.json').write_text(json.dumps(receipt, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--source-sha', required=True)
    args = parser.parse_args()
    run(args.app, args.output, args.source_sha)
