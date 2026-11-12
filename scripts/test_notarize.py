import json
import io
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest.mock import patch
import zipfile


ROOT = Path(__file__).resolve().parents[1]
NOTARIZE = ROOT / "scripts/notarize.sh"
SUBMISSION_ID = "12345678-1234-1234-1234-123456789abc"


class NotarizeTests(unittest.TestCase):
    def run_notarize(self, fake_body, *, runs=1, submit_only=False):
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
                    "NOTARY_POLL_INTERVAL_SECONDS": "0",
                    "NOTARY_KEY_FILE": "unused.p8",
                    "NOTARY_KEY_ID": "key",
                    "NOTARY_ISSUER": "issuer",
                    "NOTARY_STATE_DIR": str(temp / "notary"),
                    "NOTARY_SUBMIT_ONLY": str(submit_only).lower(),
                }
            )
            self.results = [subprocess.run(
                ["bash", str(NOTARIZE), str(artifact)], capture_output=True,
                env=env, text=True, timeout=15) for _ in range(runs)]
            result = self.results[-1]
            self.journals = [json.loads(path.read_text()) for path in (temp / "notary").glob("*.json")]
            self.pending = [json.loads(path.read_text()) for path in (temp / "notary").glob("*.intent")]
            self.observations = [json.loads(path.read_text()) for path in sorted((temp / "notary/status-observations").glob("*.json"))]
            counts = {
                path.name: int(path.read_text())
                for path in state.iterdir()
            }
            return result, counts

    def test_retries_status_queries_without_resubmitting(self):
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
            test "$command" = info
            test "$2" = '{SUBMISSION_ID}'
            if [ "$count" -eq 1 ]; then
              exit 138
            fi
            if [ "$count" -lt 4 ]; then
              echo '{{"id":"{SUBMISSION_ID}","status":"In Progress"}}'
            else
              echo '{{"id":"{SUBMISSION_ID}","status":"Accepted"}}'
            fi
            """
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(counts, {"submit": 1, "info": 4})
        self.assertEqual([row['appleStatus'] for row in self.observations], [None, 'In Progress', 'In Progress', 'Accepted'])
        self.assertTrue(all(row['submissionID'] == SUBMISSION_ID for row in self.observations))

    def test_ambiguous_upload_never_resubmits_on_resume(self):
        result, counts = self.run_notarize(
            f"""
            command="$1"
            count_file="$FAKE_STATE_DIR/$command"
            count=0
            [ ! -f "$count_file" ] || count="$(<"$count_file")"
            count=$((count + 1))
            echo "$count" > "$count_file"
            if [ "$command" = submit ]; then
              exit 138
            fi
            echo '{{"id":"{SUBMISSION_ID}","status":"Accepted"}}'
            """, runs=2
        )
        self.assertTrue(all(value.returncode != 0 for value in self.results))
        self.assertIn("no resubmission", result.stderr)
        self.assertEqual(counts, {"submit": 1})
        self.assertEqual(self.journals, [])
        self.assertEqual(self.pending[0]["submissionID"], "")

    def test_saved_identity_survives_an_error_and_later_resume_without_reupload(self):
        result, counts = self.run_notarize(
            f"""
            command="$1"
            count_file="$FAKE_STATE_DIR/$command"
            count=0
            [ ! -f "$count_file" ] || count="$(<"$count_file")"
            echo "$((count + 1))" > "$count_file"
            if [ "$command" = submit ]; then
              echo '{{"id":"{SUBMISSION_ID}"}}'
              exit 138
            fi
            test "$2" = '{SUBMISSION_ID}'
            echo '{{"id":"{SUBMISSION_ID}","status":"Accepted"}}'
            """, runs=2
        )
        self.assertTrue(all(value.returncode == 0 for value in self.results), result.stderr)
        self.assertEqual(counts, {"submit": 1, "info": 2})
        self.assertEqual(self.journals[0]["submissionID"], SUBMISSION_ID)

    def test_submission_checkpoint_returns_before_any_apple_wait(self):
        result, counts = self.run_notarize(
            f"""
            test "$1" = submit
            echo 1 > "$FAKE_STATE_DIR/submit"
            echo '{{"id":"{SUBMISSION_ID}"}}'
            """, submit_only=True
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(counts, {"submit": 1})
        self.assertEqual(self.journals[0]["submissionID"], SUBMISSION_ID)

    def test_prepare_submit_wait_preserves_the_actual_retained_journal_guard(self):
        import notary_submission
        import retained_packaging
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact = root / "NexGenVideo.dmg"; artifact.write_bytes(b"signed DMG input")
            state = root / "state"; state.mkdir()
            source = "a" * 40
            (state / "context.json").write_text(json.dumps({"schema": "release-notary-context/v1",
                "repository": "iret77/nexgenvideo", "sourceSHA": source, "runID": 123, "buildRunID": 122}))
            (state / ("c" * 64 + ".json")).write_text(json.dumps({"schema": "release-notary/v1", "sourceSHA": source,
                "sha256": "c" * 64, "submissionID": SUBMISSION_ID}))
            calls = root / "calls"
            fake = root / "notarytool"
            fake.write_text('#!/bin/bash\nset -euo pipefail\nprintf "%s\\n" "$1" >> "' + str(calls) + '"\n'
                + 'if [ "$1" = submit ]; then printf \'{"id":"' + SUBMISSION_ID
                + '"}\\n\'; else printf \'{"id":"' + SUBMISSION_ID + '","status":"Accepted"}\\n\'; fi\n')
            fake.chmod(0o755)
            env = dict(os.environ, NOTARYTOOL_BIN=str(fake), NOTARY_KEY_FILE="unused.p8", NOTARY_KEY_ID="key",
                NOTARY_ISSUER="issuer", NOTARY_STATE_DIR=str(state), NOTARY_INTENT_ROOT=str(root / "intent"),
                RETAINED_PACKAGING_ROOT=str(root / "retained"), GITHUB_SHA=source,
                GITHUB_REPOSITORY="iret77/nexgenvideo", GITHUB_RUN_ID="123", GITHUB_RUN_ATTEMPT="1",
                NOTARY_PREPARE_ONLY="false", NOTARY_SUBMIT_ONLY="false",
                NOTARY_RETRY_DELAY_SECONDS="0")
            def retained_source(path, checkpoint):
                original = io.BytesIO()
                with zipfile.ZipFile(original, 'w') as archive:
                    for item in state.glob('*.json'): archive.write(item, item.name)
                retained_packaging.state_records(original.getvalue(), source, source, 123)
                return source
            with patch.object(retained_packaging, "notary_product_source", side_effect=retained_source):
                notary_submission.execute(artifact, dict(env, NOTARY_PREPARE_ONLY="true"))
                self.assertFalse(calls.exists())
                intent = json.loads((root / "intent/intent.json").read_text())
                self.assertEqual(intent["sha256"], notary_submission.payload_sha(artifact))
                self.assertEqual(len(list(state.glob('*.json'))), 2)
                notary_submission.execute(artifact, dict(env, NOTARY_SUBMIT_ONLY="true"))
                notary_submission.execute(artifact, env)
                self.assertEqual(calls.read_text().splitlines(), ["submit", "info"])

    def test_rejects_non_accepted_status(self):
        for identity, status in ((SUBMISSION_ID, 'Invalid'), ('ffffffff-ffff-ffff-ffff-ffffffffffff', 'Accepted')):
            with self.subTest(identity=identity, status=status):
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
                    elif [ "$command" = info ]; then
                      echo '{{"id":"{identity}","status":"{status}"}}'
                    else
                      echo '{{"issues":[]}}'
                    fi
                    """
                )
                self.assertNotEqual(result.returncode, 0)
                if status == 'Invalid':
                    self.assertIn("finished with status: Invalid", result.stderr)
                    self.assertEqual(counts, {"log": 1, "submit": 1, "info": 1})
                else:
                    self.assertIn("status query failed", result.stderr)
                    self.assertEqual(counts, {"submit": 1, "info": 3})


if __name__ == "__main__":
    unittest.main()
