import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import isolated_test_home


class IsolatedTestHomeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.account = self.root / 'account'
        self.account.mkdir()
        account = patch.object(isolated_test_home.pwd, 'getpwuid',
                               return_value=SimpleNamespace(pw_dir=str(self.account)))
        account.start()
        self.addCleanup(account.stop)

    def test_child_home_and_foundation_home_share_the_owned_directory(self):
        home_path = self.root / 'case' / 'home'
        evidence = self.root / 'home.json'
        parent = {'HOME': str(self.account), 'CFFIXED_USER_HOME': str(self.account), 'PATH': '/tools'}
        child = isolated_test_home.environment(parent, home_path, evidence)
        self.assertEqual(child, {'HOME': str(home_path), 'CFFIXED_USER_HOME': str(home_path), 'PATH': '/tools'})
        self.assertEqual(parent['HOME'], str(self.account))
        self.assertTrue(home_path.is_dir())
        self.assertEqual(json.loads(evidence.read_text())['HOME'], str(home_path))

    def test_account_home_and_its_ancestors_are_refused_before_writing(self):
        for home_path in (self.account, self.root):
            with self.subTest(home_path=home_path), self.assertRaises(ValueError):
                isolated_test_home.environment({}, home_path, self.root / 'unexpected.json')
        self.assertFalse((self.root / 'unexpected.json').exists())
        self.assertEqual(list(self.account.iterdir()), [])

    def test_symlink_home_is_refused_before_writing(self):
        alias = self.root / 'alias'
        alias.symlink_to(self.account, target_is_directory=True)
        with self.assertRaises(ValueError):
            isolated_test_home.environment({}, alias)
        self.assertEqual(list(self.account.iterdir()), [])

    def test_existing_isolated_home_is_shared_with_nested_processes(self):
        home_path = self.root / 'case' / 'home'
        with patch.object(isolated_test_home.tempfile, 'mkdtemp') as allocate:
            child = isolated_test_home.process_environment({'CFFIXED_USER_HOME': str(home_path)}, self.root / 'proof.json')
        allocate.assert_not_called()
        self.assertEqual(child['HOME'], str(home_path))

    def test_missing_override_allocates_a_runner_temporary_home(self):
        home_path = self.root / 'runner' / 'allocated-home'
        with patch.object(isolated_test_home.tempfile, 'mkdtemp', return_value=str(home_path)) as allocate:
            child = isolated_test_home.process_environment({'RUNNER_TEMP': str(self.root / 'runner')}, self.root / 'proof.json')
        allocate.assert_called_once_with(prefix='nexgenvideo-test-home-', dir=str(self.root / 'runner'))
        self.assertEqual(child['HOME'], child['CFFIXED_USER_HOME'])
        self.assertEqual(child['HOME'], str(home_path))
