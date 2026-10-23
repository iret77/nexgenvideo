import subprocess
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from verify_macho_dependencies import DYLIB_LOADS, main, verify_load_commands


def command(kind, name):
    return f"Load command 0\n          cmd {kind}\n      cmdsize 64\n         name {name} (offset 24)\n"


class MachODependencyTests(unittest.TestCase):
    def test_library_identity_is_not_a_load_dependency(self):
        verify_load_commands(command("LC_ID_DYLIB", "libtcl9thread3.0.6.dylib")
                             + command("LC_LOAD_DYLIB", "/usr/lib/libSystem.B.dylib"))

    def test_actual_bare_or_host_dependencies_remain_rejected(self):
        for kind in DYLIB_LOADS:
            for name in ("libtcl9thread3.0.6.dylib", "/opt/homebrew/lib/libtcl.dylib",
                         "/Users/builder/lib.dylib"):
                with self.subTest(kind=kind, name=name), self.assertRaises(ValueError):
                    verify_load_commands(command("LC_ID_DYLIB", name) + command(kind, name))

    def test_relocatable_and_system_loads_preserve_names_with_spaces(self):
        for kind in DYLIB_LOADS:
            for prefix in ("@rpath/", "@loader_path/", "@executable_path/",
                           "/usr/lib/", "/System/Library/"):
                with self.subTest(kind=kind, prefix=prefix):
                    verify_load_commands(command(kind, prefix + "A Framework/A"))

    def test_missing_or_malformed_output_fails_closed(self):
        for output in ("", "binary:\n", "Load command 0\ncmd LC_LOAD_DYLIB\n",
                       command("LC_FUTURE_DYLIB", "@rpath/A"),
                       command("?(0x999)", "@rpath/A"),
                       "Load command 0\ncmd LC_LOAD_DYLIB\ncmd LC_ID_DYLIB\n",
                       command("LC_LOAD_DYLIB", "@rpath/A") + "name /bad (offset 24)\n"):
            with self.subTest(output=output), self.assertRaises(ValueError):
                verify_load_commands(output)

    def test_otool_failure_is_not_an_empty_success(self):
        with patch("sys.argv", ["verify", "binary"]), patch(
            "verify_macho_dependencies.subprocess.run",
            side_effect=subprocess.CalledProcessError(1, ["otool"]),
        ), self.assertRaises(subprocess.CalledProcessError):
            main()

    def test_cli_requests_load_commands_and_rejects_a_bad_load(self):
        with patch("sys.argv", ["verify", "binary"]), patch(
            "verify_macho_dependencies.subprocess.run",
            return_value=SimpleNamespace(stdout=command("LC_LOAD_DYLIB", "/bad")),
        ) as run, self.assertRaises(SystemExit):
            main()
        self.assertEqual(run.call_args.args[0], ["otool", "-l", "binary"])
        self.assertTrue(run.call_args.kwargs["check"])


if __name__ == "__main__":
    unittest.main()
