import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
NOTARIZE = ROOT / "scripts/notarize.sh"
SUBMISSION_ID = "12345678-1234-1234-1234-123456789abc"


class NotarizeTests(unittest.TestCase):
    def run_notarize(self, fake_body):
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            artifact = temp / "artifact.zip"
            artifact.touch()
            fake = temp / "notarytool"
            fake.write_text("#!/bin/bash\nset -euo pipefail\n" + textwrap.dedent(fake_body))
            fake.chmod(0o755)
            state = temp / "state"
            state.mkdir()
            env = os.environ.copy()
            env.update(
                {
                    "FAKE_STATE_DIR": str(state),
                    "NOTARYTOOL_BIN": str(fake),
                    "NOTARY_ATTEMPTS": "3",
                    "NOTARY_RETRY_DELAY_SECONDS": "0",
                    "NOTARY_KEY_FILE": "unused.p8",
                    "NOTARY_KEY_ID": "key",
                    "NOTARY_ISSUER": "issuer",
                }
            )
            result = subprocess.run(
                ["bash", str(NOTARIZE), str(artifact)],
                capture_output=True,
                env=env,
                text=True,
            )
            counts = {
                path.name: int(path.read_text())
                for path in state.iterdir()
            }
            return result, counts

    def test_retries_wait_without_resubmitting(self):
        result, counts = self.run_notarize(
            f"""
            command="$1"
            count_file="$FAKE_STATE_DIR/$command"
            count=0
            [ ! -f "$count_file" ] || count="$(<"$count_file")"
            count=$((count + 1))
            echo "$count" > "$count_file"
            if [ "$command" = submit ]; then
              echo '{{"id":"{SUBMISSION_ID}"}}'
              exit 0
            fi
            if [ "$command" = wait ] && [ "$count" -lt 3 ]; then
              exit 138
            fi
            echo '{{"status":"Accepted"}}'
            """
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(counts, {"submit": 1, "wait": 3})

    def test_retries_incomplete_upload(self):
        result, counts = self.run_notarize(
            f"""
            command="$1"
            count_file="$FAKE_STATE_DIR/$command"
            count=0
            [ ! -f "$count_file" ] || count="$(<"$count_file")"
            count=$((count + 1))
            echo "$count" > "$count_file"
            if [ "$command" = submit ] && [ "$count" -eq 1 ]; then
              exit 138
            fi
            if [ "$command" = submit ]; then
              echo '{{"id":"{SUBMISSION_ID}"}}'
            else
              echo '{{"status":"Accepted"}}'
            fi
            """
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(counts, {"submit": 2, "wait": 1})

    def test_rejects_non_accepted_status(self):
        result, counts = self.run_notarize(
            f"""
            command="$1"
            count_file="$FAKE_STATE_DIR/$command"
            count=0
            [ ! -f "$count_file" ] || count="$(<"$count_file")"
            count=$((count + 1))
            echo "$count" > "$count_file"
            if [ "$command" = submit ]; then
              echo '{{"id":"{SUBMISSION_ID}"}}'
            elif [ "$command" = wait ]; then
              echo '{{"status":"Invalid"}}'
            else
              echo '{{"issues":[]}}'
            fi
            """
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("finished with status: Invalid", result.stderr)
        self.assertEqual(counts, {"log": 1, "submit": 1, "wait": 1})


if __name__ == "__main__":
    unittest.main()
