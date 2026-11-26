from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import notarization_proof
import verify_release_image as image
from test_notarization_proof import APP_HASH, PACK_HASH, FakeTools, own_hash, sample_proof


ARM64, X86_64 = 0x0100000C, 0x01000007


def thin(cpu=ARM64, minos=(26, 0), legacy=False):
    if legacy:
        command = struct.pack('<IIII', image.LC_VERSION_MIN_MACOSX, 16, (minos[0] << 16) | (minos[1] << 8), 0)
    else:
        command = struct.pack('<IIIIII', image.LC_BUILD_VERSION, 24, 1, (minos[0] << 16) | (minos[1] << 8), 0, 0)
    return struct.pack('<IiiIIIII', 0xFEEDFACF, cpu, 0, 6, 1, len(command), 0, 0) + command


def fat(*slices):
    offset, header, body = 4096, struct.pack('>II', 0xCAFEBABE, len(slices)), b''
    for cpu, data in slices:
        header += struct.pack('>iiIII', cpu, 0, offset + len(body), len(data), 12)
        body += data
    return header + b'\0' * (offset - len(header)) + body


class ImageTools(FakeTools):
    def __call__(self, arguments, log=None, timeout=120):
        arguments = [str(item) for item in arguments]
        if arguments[:2] == ['codesign', '--verify'] or arguments[0] in ('ditto', 'xattr'):
            self.calls.append(arguments)
            return 0, ''
        if arguments[:2] == ['codesign', '-d'] and arguments[-1].endswith('Sparkle'):
            self.calls.append(arguments)
            return 0, 'flags=0x10000(runtime)\nCDHash=' + '5' * 40 + '\nTeamIdentifier=' + self.team + '\n'
        return super().__call__(arguments, log, timeout)


class ReleaseImageTests(unittest.TestCase):
    def test_macho_parser_reads_thin_fat_and_legacy_targets_and_ignores_other_magic(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            samples = {'thin': thin(), 'fat': fat((X86_64, thin(X86_64, (10, 13))), (ARM64, thin())),
                       'legacy': thin(minos=(11, 0), legacy=True), 'java': b'\xca\xfe\xba\xbe\x00\x00\x00\x34rest',
                       'text': b'#!/bin/sh\n'}
            for name, data in samples.items():
                (root / name).write_bytes(data)
            self.assertEqual(image.macho(root / 'thin'), [{'arch': 'arm64', 'filetype': 6, 'minos': (26, 0)}])
            self.assertEqual([item['arch'] for item in image.macho(root / 'fat')], ['x86_64', 'arm64'])
            self.assertEqual(image.macho(root / 'fat')[0]['minos'], (10, 13))
            self.assertEqual(image.macho(root / 'legacy')[0]['minos'], (11, 0))
            self.assertIsNone(image.macho(root / 'java'))
            self.assertIsNone(image.macho(root / 'text'))
            self.assertEqual(sorted(image.binaries(root)), ['fat', 'legacy', 'thin'])

    def test_architecture_rules_separate_own_and_third_party_binaries(self):
        arm = [{'arch': 'arm64', 'minos': (26, 0)}]
        universal = [{'arch': 'x86_64', 'minos': (10, 13)}, {'arch': 'arm64', 'minos': (11, 0)}]
        self.assertEqual(image.architecture_failures('own', arm, True), [])
        self.assertEqual(image.architecture_failures('vendor', universal, False), [])
        self.assertTrue(image.architecture_failures('own', universal, True))
        self.assertTrue(image.architecture_failures('vendor', [{'arch': 'x86_64', 'minos': (10, 13)}], False))
        self.assertTrue(image.architecture_failures('own', [{'arch': 'arm64', 'minos': (27, 0)}], True))
        self.assertTrue(image.architecture_failures('vendor', [{'arch': 'arm64', 'minos': None}], False))

    def fixture(self, root, *, own=None, build='141'):
        app = root / 'NexGenVideo.app'
        for name in notarization_proof.OWN_BINARIES:
            (app / name).parent.mkdir(parents=True, exist_ok=True)
            (app / name).write_bytes(own if own is not None and name.endswith('NexGenVideoDiagnostics') else thin())
        sparkle = app / 'Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle'
        sparkle.parent.mkdir(parents=True)
        sparkle.write_bytes(fat((X86_64, thin(X86_64, (10, 13))), (ARM64, thin(minos=(10, 13)))))
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'de.h5ventures.nexgenvideo', 'CFBundleShortVersionString': '1.8.0',
            'CFBundleVersion': build, 'NGVSourceCommit': 'c' * 40, 'LSMinimumSystemVersion': '26.0'}))
        pack = root / 'musicvideo.ngvpack'
        (pack / 'Contents/MacOS').mkdir(parents=True)
        (pack / 'Contents/MacOS/musicvideo').write_bytes(thin())
        dmg = root / 'NexGenVideo.dmg'
        dmg.write_bytes(b'stapled dmg')
        hashes = {'NexGenVideo.app': APP_HASH, 'musicvideo.ngvpack': PACK_HASH, 'MacOS/musicvideo': PACK_HASH,
                  **{name: (APP_HASH if index == 0 else own_hash(index))
                     for index, name in enumerate(notarization_proof.OWN_BINARIES)}}
        tools = ImageTools(root, hashes)
        tools.team = 'VG5X6JCLGF'
        tools.stapled.update({str(dmg), str(pack)})
        proof = sample_proof(notarization_proof.sha256(dmg))
        expected = {'version': '1.8.0', 'build': '141', 'sourceSHA': 'c' * 40, 'notaryMode': 'dmg-only',
                    'dmgSHA256': notarization_proof.sha256(dmg)}
        return app, pack, dmg, tools, proof, expected

    def check(self, root, app, pack, dmg, tools, proof, expected, launched=True):
        result = subprocess.CompletedProcess([], 0 if launched else 1, 'SELFTEST_PACK_OK loaded musicvideo v0.6.0\n', '')
        with patch.object(notarization_proof, 'run', side_effect=tools), \
                patch.object(image.subprocess, 'run', return_value=result):
            return image.check(app, pack, dmg, expected, proof, None, root / 'home', root / 'image.log')

    def test_image_passes_only_with_fixed_identity_slices_signatures_and_tickets(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, pack, dmg, tools, proof, expected = self.fixture(root)
            result = self.check(root, app, pack, dmg, tools, proof, expected)
            self.assertEqual(result['failures'], [])
            self.assertTrue(result['passed'])
            self.assertEqual(result['machOCount'], len(notarization_proof.OWN_BINARIES) + 2)
            self.assertEqual(result['ticketUncovered'], ['app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle'])
            self.assertEqual(result['expected']['team'], 'VG5X6JCLGF')

    def test_image_reports_each_independent_deviation(self):
        cases = {'build': dict(build='140'), 'universal-own': dict(own=fat((X86_64, thin(X86_64)), (ARM64, thin()))),
                 'future-floor': dict(own=thin(minos=(27, 0)))}
        for name, options in cases.items():
            with self.subTest(case=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                arguments = self.fixture(root, **options)
                result = self.check(root, *arguments)
                self.assertFalse(result['passed'])
                self.assertTrue(result['failures'])
        for name in ('team', 'launch', 'uncovered-own', 'unstapled-dmg'):
            with self.subTest(case=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                app, pack, dmg, tools, proof, expected = self.fixture(root)
                if name == 'team': tools.team = 'OTHERTEAM1'
                if name == 'uncovered-own':
                    tools.hashes['MacOS/musicvideo'] = '6' * 40
                if name == 'unstapled-dmg':
                    tools.stapled.discard(str(dmg))
                if name in ('unstapled-dmg', 'team'):
                    with self.assertRaises(ValueError):
                        self.check(root, app, pack, dmg, tools, proof, expected)
                    continue
                result = self.check(root, app, pack, dmg, tools, proof, expected, launched=name != 'launch')
                self.assertFalse(result['passed'])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, pack, dmg, tools, proof, expected = self.fixture(root)
            self.check(root, app, pack, dmg, tools, proof, expected)
            self.assertFalse(any(call[0] == 'spctl' for call in tools.calls))

    def test_dmg_must_match_the_independently_bound_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app, pack, dmg, tools, proof, expected = self.fixture(root)
            expected['dmgSHA256'] = '0' * 64
            with self.assertRaisesRegex(ValueError, 'notarized DMG'):
                self.check(root, app, pack, dmg, tools, proof, expected)


if __name__ == '__main__':
    unittest.main()
