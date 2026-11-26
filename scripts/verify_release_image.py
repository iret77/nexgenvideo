"""Check the installed release image against fixed product expectations, independent of the build outputs."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import time

import notarization_proof


SCHEMA = 'nexgenvideo/release-image-check/1'
ARCH = 'arm64'
MAXIMUM_MINOS = (26, 0)
MINIMUM_SYSTEM = '26.0'
BUNDLE_ID = 'de.h5ventures.nexgenvideo'
TEAM = notarization_proof.TEAM
RUNTIME_FLAG = 0x10000
CPU = {0x0100000C: 'arm64', 0x01000007: 'x86_64', 0x00000007: 'i386', 0x0200000C: 'arm64_32'}
LC_BUILD_VERSION, LC_VERSION_MIN_MACOSX = 0x32, 0x24


def require(condition, message):
    if not condition:
        raise ValueError(message)


def version(value):
    return (value >> 16, (value >> 8) & 0xFF)


def thin_slice(stream, offset):
    stream.seek(offset)
    header = stream.read(32)
    require(len(header) >= 28, 'Truncated Mach-O header')
    magic = struct.unpack('<I', header[:4])[0]
    require(magic in (0xFEEDFACF, 0xFEEDFACE), 'Unsupported Mach-O byte order')
    cputype, _, filetype, ncmds, size = struct.unpack('<iIIII', header[4:24])
    stream.seek(offset + (32 if magic == 0xFEEDFACF else 28))
    commands = stream.read(size)
    require(len(commands) == size, 'Truncated Mach-O load commands')
    minos, cursor = None, 0
    for _ in range(ncmds):
        require(cursor + 8 <= size, 'Malformed Mach-O load commands')
        command, length = struct.unpack('<II', commands[cursor:cursor + 8])
        require(length >= 8 and cursor + length <= size, 'Malformed Mach-O load command')
        if command == LC_BUILD_VERSION:
            minos = version(struct.unpack('<I', commands[cursor + 12:cursor + 16])[0])
        elif command == LC_VERSION_MIN_MACOSX and minos is None:
            minos = version(struct.unpack('<I', commands[cursor + 8:cursor + 12])[0])
        cursor += length
    return {'arch': CPU.get(cputype & 0xFFFFFFFF, hex(cputype & 0xFFFFFFFF)), 'filetype': filetype, 'minos': minos}


def macho(path):
    with Path(path).open('rb') as stream:
        magic = stream.read(8)
        if len(magic) < 8:
            return None
        if magic[:4] in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe'):
            return [thin_slice(stream, 0)]
        if magic[:4] not in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
            return None
        count = struct.unpack('>I', magic[4:])[0]
        if not 0 < count <= 20:
            return None
        wide = magic[:4] == b'\xca\xfe\xba\xbf'
        entries = stream.read(count * (32 if wide else 20))
        offsets = []
        for index in range(count):
            if wide:
                offsets.append(struct.unpack('>iiQQII', entries[index * 32:index * 32 + 32])[2])
            else:
                offsets.append(struct.unpack('>iiIII', entries[index * 20:index * 20 + 20])[2])
        return [thin_slice(stream, offset) for offset in offsets]


def binaries(root):
    found = {}
    for path in sorted(Path(root).rglob('*')):
        if path.is_file() and not path.is_symlink():
            slices = macho(path)
            if slices is not None:
                found[path.relative_to(root).as_posix()] = slices
    return found


def architecture_failures(name, slices, own):
    failures = []
    archs = sorted({item['arch'] for item in slices})
    if own and archs != [ARCH]:
        failures.append(name + ' must be arm64 only, found ' + ','.join(archs))
    if not own and ARCH not in archs:
        failures.append(name + ' has no arm64 slice')
    for item in slices:
        if item['minos'] is None or item['minos'] > MAXIMUM_MINOS:
            failures.append(name + ' ' + item['arch'] + ' requires macOS ' + str(item['minos']))
    return failures


def checked(arguments, log, timeout=180):
    return notarization_proof.checked(arguments, log, timeout)


def check(app, pack, dmg, expected, proof, diagnostic, home, log):
    failures = []
    info = plistlib.loads((Path(app) / 'Contents/Info.plist').read_bytes())
    plist = {key: info.get(key) for key in ('CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion',
                                              'NGVSourceCommit', 'LSMinimumSystemVersion')}
    wanted = {'CFBundleIdentifier': BUNDLE_ID, 'CFBundleShortVersionString': expected['version'],
              'CFBundleVersion': expected['build'], 'NGVSourceCommit': expected['sourceSHA'],
              'LSMinimumSystemVersion': MINIMUM_SYSTEM}
    failures += [key + ' is ' + str(plist[key]) + ', expected ' + str(value)
                 for key, value in wanted.items() if plist[key] != value]
    own_names = {'app/' + name for name in notarization_proof.OWN_BINARIES}
    inventory = {}
    for prefix, root in (('app', app), ('pack', pack)):
        for name, slices in binaries(root).items():
            inventory[prefix + '/' + name] = (Path(root) / name, slices)
    require(own_names <= set(inventory), 'Own binaries are missing from the image')
    signatures, coverage = {}, []
    for name, (path, slices) in inventory.items():
        own = name in own_names or name.startswith('pack/')
        failures += architecture_failures(name, slices, own)
        value = notarization_proof.signature(path)
        signatures[name] = value
        if value['team'] != TEAM:
            failures.append(name + ' is signed by team ' + repr(value['team']))
        if value['flags'] is None or not value['flags'] & RUNTIME_FLAG:
            failures.append(name + ' lacks the hardened runtime')
        if value['cdhash'] not in proof['ticketCDHashes']:
            coverage.append(name)
    for name in own_names | {name for name in inventory if name.startswith('pack/')}:
        if name in coverage:
            failures.append(name + ' is not covered by the DMG notarization ticket')
    for target in (app, pack):
        checked(['codesign', '--verify', '--deep', '--strict', '--verbose=2', target], log)
    checked(['xcrun', 'stapler', 'validate', dmg], log)
    checked(['xcrun', 'stapler', 'validate', pack], log)
    stapled = notarization_proof.run(['xcrun', 'stapler', 'validate', app], log)[0] == 0
    if expected['notaryMode'] == 'app-and-dmg' and not stapled:
        failures.append('The two-submission app copy carries no stapled ticket')
    if diagnostic is not None:
        checked(['xcrun', 'stapler', 'validate', diagnostic], log)
        require(notarization_proof.signature(diagnostic)['cdhash'] == proof['app']['cdhash'],
                'Diagnostic app is not the notarized DMG app')
    require(notarization_proof.sha256(dmg) == expected['dmgSHA256'], 'The DMG differs from the notarized DMG')
    installed = notarization_proof.verify_installed(app, dmg, proof, log)
    with tempfile.TemporaryDirectory(prefix='ngv-image-pack-') as directory:
        copy = Path(directory) / 'musicvideo.ngvpack'
        checked(['ditto', pack, copy], log)
        checked(['xattr', '-r', '-w', 'com.apple.quarantine',
                 '0083;%x;NexGenVideo image check;' % int(time.time()), copy], log)
        environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home), NGV_SELFTEST_PACK=str(copy))
        launched = subprocess.run([str(Path(app) / 'Contents/MacOS/NexGenVideo')], stdin=subprocess.DEVNULL,
                                  capture_output=True, text=True, timeout=180, env=environment)
        with Path(log).open('a', encoding='utf-8') as stream:
            stream.write(launched.stdout + launched.stderr)
        if launched.returncode != 0 or 'SELFTEST_PACK_OK loaded musicvideo' not in launched.stdout:
            failures.append('The quarantined pack did not load into the installed app')
    return {'schema': SCHEMA, 'passed': not failures, 'failures': failures,
            'dmgSHA256': notarization_proof.sha256(dmg),
            'expected': dict(expected, arch=ARCH, maximumMinos='%d.%d' % MAXIMUM_MINOS,
                             minimumSystem=MINIMUM_SYSTEM, team=TEAM, bundleIdentifier=BUNDLE_ID),
            'infoPlist': plist, 'machOCount': len(inventory),
            'ownBinaries': sorted(own_names | {name for name in inventory if name.startswith('pack/')}),
            'stapledAppCopy': stapled, 'installedNotarization': installed,
            'ticketUncovered': sorted(coverage),
            'signatures': {name: dict(value, archs=sorted({item['arch'] for item in inventory[name][1]}))
                           for name, value in signatures.items()}}


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    for name in ('--app', '--pack', '--dmg', '--proof', '--evidence', '--home', '--log'):
        parser.add_argument(name, required=True, type=Path)
    parser.add_argument('--diagnostic-app', type=Path)
    for name in ('--version', '--build', '--source-sha', '--dmg-sha256'):
        parser.add_argument(name, required=True)
    args = parser.parse_args()
    proof = notarization_proof.load(args.proof)
    expected = {'version': args.version, 'build': args.build, 'sourceSHA': args.source_sha, 'notaryMode': proof['mode'],
                'dmgSHA256': args.dmg_sha256}
    result = check(args.app, args.pack, args.dmg, expected, proof, args.diagnostic_app, args.home, args.log)
    args.evidence.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n')
    for failure in result['failures']:
        print('::error::' + failure, file=sys.stderr)
    if not result['passed']:
        raise SystemExit('Release image check failed')
    print('Release image check passed for ' + str(result['machOCount']) + ' Mach-O files')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        raise SystemExit('::error::Release image check could not complete: ' + str(error).replace('\n', ' '))
