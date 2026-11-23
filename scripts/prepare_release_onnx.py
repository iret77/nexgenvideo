"""Bind the retired ONNX package address to its original Git objects and binary checksums."""
import hashlib
import json
import os
from pathlib import Path
import subprocess

from native_app_target_build import logged, source_git_environment


ORIGIN = 'https://github.com/microsoft/onnxruntime-swift-package-manager'
TRANSPORT = 'https://github.com/sackheads/onnxruntime-swift-package-manager'
VERSION = '1.24.2'
REVISION = 'b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2'
TREE = '59178cede37305e8725fd09d5907d872a55004f1'
ARCHIVES = {
    'pod-archive-onnxruntime-c-1.24.2.zip': 'f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54',
    'pod-archive-onnxruntime-extensions-c-0.13.0.zip': '346522d1171d4c99cb0908fa8e4e9330a4a6aad39cd83ce36eb654437b33e6b5',
}


def validate_pin(lock, manifest):
    pins = [p for p in lock['pins'] if p['identity'] == 'onnxruntime-swift-package-manager']
    if pins != [{'identity': 'onnxruntime-swift-package-manager', 'kind': 'remoteSourceControl',
                 'location': ORIGIN, 'state': {'revision': REVISION, 'version': VERSION}}]:
        raise ValueError('ONNX transport requires the original locked package')
    if lock['originHash'] != hashlib.sha256(manifest).hexdigest():
        raise ValueError('Resolved dependency pins do not match the root manifest')


def main():
    temporary = Path(os.environ['RUNNER_TEMP'])
    root = temporary / 'release-onnx-transport'
    root.mkdir()
    validate_pin(json.loads(Path('Package.resolved').read_bytes()), Path('Package.swift').read_bytes())
    mirror = root / 'source.git'
    git = ['git', '-c', 'credential.helper=', '-c', 'core.hooksPath=/dev/null']
    environment = source_git_environment(os.environ)
    logged(root, 'init', [*git, 'init', '--bare', str(mirror)], environment)
    git += ['--git-dir', str(mirror)]
    tag = 'refs/tags/' + VERSION
    logged(root, 'fetch', [*git, 'fetch', '--no-tags', '--no-recurse-submodules',
                           TRANSPORT + '.git', tag + ':' + tag], environment, timeout=180)
    revision = logged(root, 'revision', [*git, 'rev-parse', tag + '^{commit}'], environment).strip()
    tree = logged(root, 'tree', [*git, 'rev-parse', tag + '^{tree}'], environment).strip()
    if (revision, tree) != (REVISION, TREE):
        raise ValueError('ONNX source tag no longer matches the locked commit and tree')
    logged(root, 'verify', [*git, 'fsck', '--full', '--strict', revision], environment, timeout=180)
    logged(root, 'branch', [*git, 'update-ref', 'refs/heads/pinned', revision], environment)
    logged(root, 'head', [*git, 'symbolic-ref', 'HEAD', 'refs/heads/pinned'], environment)
    manifest = logged(root, 'manifest', [*git, 'show', revision + ':Package.swift'], environment)
    for filename, checksum in ARCHIVES.items():
        origin = 'https://download.onnxruntime.ai/' + filename
        if origin not in manifest or checksum not in manifest:
            raise ValueError('Binary artifact differs from the locked upstream declaration')
        target = TRANSPORT + '/releases/download/' + VERSION + '/' + filename
        subprocess.run(['swift', 'package', 'config', 'set-mirror', '--original', origin, '--mirror', target],
                       check=True, stdin=subprocess.DEVNULL, timeout=30)
    with Path(os.environ['GITHUB_ENV']).open('a') as output:
        count = int(os.environ.get('GIT_CONFIG_COUNT', '0'))
        for spelling in (ORIGIN, ORIGIN + '.git'):
            output.write(f'GIT_CONFIG_KEY_{count}=url.{mirror.as_uri()}.insteadOf\n')
            output.write(f'GIT_CONFIG_VALUE_{count}={spelling}\n')
            count += 1
        output.write(f'GIT_CONFIG_COUNT={count}\nGIT_TERMINAL_PROMPT=0\n')
    print('Verified ONNX 1.24.2 source', revision, tree, 'and both upstream binary declarations', flush=True)


if __name__ == '__main__':
    main()
