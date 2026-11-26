import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import offline_gatekeeper as offline


class FakeVM:
    def __init__(self, variant):
        self.variant, self.calls, self.blocked = variant, [], False

    def __call__(self, arguments, log, timeout=120, input_text=None):
        arguments = [str(item) for item in arguments]
        self.calls.append(arguments)
        log.append({'command': arguments})
        command = arguments[2:] if arguments[:2] == ['sudo', '-n'] else arguments
        if command[:2] == ['pfctl', '-E']:
            return 0, 'pf enabled\nToken : 42\n'
        if command[:2] == ['pfctl', '-sr']:
            return 0, 'anchor "com.apple/*" all\n'
        if command[:3] == ['pfctl', '-a', offline.ANCHOR] and command[3] == '-f':
            self.blocked = True
            return 0, ''
        if command[:3] == ['pfctl', '-a', offline.ANCHOR] and command[3:] == ['-F', 'all']:
            self.blocked = False
            return 0, ''
        if command[0] == 'pfctl':
            return 0, ''
        if command[0] == 'curl':
            if command[-1] == offline.RESTORE_PROBE and not self.blocked:
                return (7, 'unreachable') if self.variant == 'network-not-restored' else (0, '')
            reachable = self.variant == 'reachable' and command[-1] == 'https://ocsp.apple.com/'
            return (0, '') if reachable or not self.blocked else (28, 'timed out')
        if command[:2] == ['spctl', '--status']:
            return 0, 'assessments enabled'
        if command[0] == 'spctl':
            target = command[-1]
            if target.endswith('Unnotarized.app'):
                return (0, 'accepted\noverride=security disabled') if self.variant == 'enforcement-off' else (3, 'rejected')
            if not self.blocked:
                raise AssertionError('Gatekeeper assessed the product while online')
            if target.endswith('NexGenVideo.app') and self.variant == 'rejected-app':
                return 3, 'rejected\nsource=Unnotarized Developer ID'
            return 0, 'accepted\nsource=Notarized Developer ID'
        if command[:2] == ['xattr', '-p']:
            return 1, 'No such xattr'
        if command[:2] == ['codesign', '-d']:
            return 0, 'CDHash=' + 'a' * 40 + '\n'
        if command[0] in ('ditto', 'xattr', 'codesign', 'hdiutil'):
            return 0, ''
        raise AssertionError(arguments)


class OfflineGatekeeperTests(unittest.TestCase):
    def test_rules_keep_loopback_and_drop_apple_and_every_new_connection(self):
        rules = offline.rules().splitlines()
        self.assertEqual(rules[0], 'pass quick on lo0 all')
        for rule in ('block drop quick inet from any to 17.0.0.0/8', 'block drop quick inet from 17.0.0.0/8 to any',
                     'block drop out quick proto udp all', 'block drop out quick proto tcp all flags S/SA'):
            self.assertIn(rule, rules)
        self.assertTrue(any(rule.startswith('block drop quick inet6 from any to {') and '2620:149::/32' in rule
                            for rule in rules))
        self.assertFalse(any(rule.startswith('pass') for rule in rules[1:]))

    def run_check(self, variant):
        vm = FakeVM(variant)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dmg = root / 'NexGenVideo.dmg'
            dmg.write_bytes(b'stapled dmg')
            evidence = root / 'offline.json'
            launch = subprocess.CompletedProcess([], 1 if variant == 'launch-fails' else 0,
                                                 'SELFTEST_PACK_OK loaded musicvideo v0.6.0\n', '')
            def launched(*args, **kwargs):
                self.assertTrue(vm.blocked, 'the app must launch while the network is blocked')
                self.assertTrue(kwargs['env']['NGV_SELFTEST_PACK'].endswith('musicvideo.ngvpack'))
                return launch
            error = None
            with patch.object(offline, 'run', side_effect=vm), patch.object(offline.time, 'sleep'), \
                    patch.object(offline.subprocess, 'run', side_effect=launched):
                try:
                    offline.check(dmg, hashlib.sha256(b'stapled dmg').hexdigest(), evidence, root / 'home')
                except SystemExit as exit_error:
                    error = str(exit_error)
            return vm, error, json.loads(evidence.read_text())

    def test_passing_check_assesses_launches_offline_and_restores_the_network(self):
        vm, error, record = self.run_check('pass')
        self.assertIsNone(error)
        self.assertTrue(record['passed'] and record['offlineConditionProven'])
        self.assertEqual(record['appCDHash'], 'a' * 40)
        self.assertTrue(record['launch']['packLoaded'])
        self.assertFalse(vm.blocked)
        self.assertIn(['sudo', '-n', 'pfctl', '-X', '42'], vm.calls)

    def test_failures_name_their_cause_and_always_release_the_block(self):
        for variant, kind in (('reachable', 'infrastructure'), ('enforcement-off', 'infrastructure'),
                              ('rejected-app', 'gatekeeper'), ('launch-fails', 'gatekeeper'),
                              ('network-not-restored', 'infrastructure')):
            with self.subTest(variant=variant):
                vm, error, record = self.run_check(variant)
                self.assertIsNotNone(error)
                self.assertFalse(record['passed'])
                self.assertEqual(record['failure']['kind'], kind)
                self.assertIn(['sudo', '-n', 'pfctl', '-a', offline.ANCHOR, '-F', 'all'], vm.calls)
                if kind == 'gatekeeper':
                    self.assertIn('notarize_app_separately=true', error)
                    self.assertTrue(record['offlineConditionProven'])
                else:
                    self.assertIn('could not run', error)

    def test_foreign_dmg_is_rejected_before_the_network_changes(self):
        vm = FakeVM('pass')
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'NexGenVideo.dmg').write_bytes(b'another dmg')
            with patch.object(offline, 'run', side_effect=vm), self.assertRaises(SystemExit):
                offline.check(root / 'NexGenVideo.dmg', '0' * 64, root / 'offline.json', root)
        self.assertFalse(any('pfctl' in call for call in vm.calls))


if __name__ == '__main__':
    unittest.main()
