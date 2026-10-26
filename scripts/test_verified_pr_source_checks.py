from copy import deepcopy
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest
from unittest.mock import MagicMock, patch
import zipfile

import verified_pr_source_checks as proof


HEAD = "a" * 40
CHECKOUT = "b" * 40
MERGE = "c" * 40
TREE = "d" * 40


def fixtures():
    run = {"id": 100, "repository": {"full_name": proof.REPOSITORY}, "event": "pull_request",
           "path": ".github/workflows/pr-checks.yml", "head_sha": HEAD, "run_attempt": 1,
           "status": "completed", "conclusion": "success", "actor": {"login": "iret77"}}
    steps = [{"name": name, "status": "completed", "conclusion": "success"}
             for name in (*proof.CHECKS, "Record verified source checkout", "Upload verified source checkout")]
    jobs = {"total_count": 1, "jobs": [{"id": 200, "name": "Light Checks", "run_id": 100,
            "run_attempt": 1, "head_sha": HEAD, "status": "completed", "conclusion": "success", "steps": steps}]}
    receipt = {"schema": "verified-pr-source/v1", "repository": proof.REPOSITORY,
               "headRepository": proof.REPOSITORY, "runID": 100, "attempt": 1, "headSHA": HEAD,
               "pullRequest": 300, "checkoutSHA": CHECKOUT, "treeSHA": TREE, "baseRef": "rc"}
    pr = {"number": 300, "merged": True, "merge_commit_sha": MERGE,
          "head": {"sha": HEAD, "repo": {"full_name": proof.REPOSITORY}},
          "base": {"ref": "rc", "repo": {"full_name": proof.REPOSITORY}}}
    commit = {"sha": CHECKOUT, "tree": {"sha": TREE}}
    data = io.BytesIO()
    with zipfile.ZipFile(data, "w") as archive:
        archive.writestr("receipt.json", json.dumps(receipt))
    raw = data.getvalue()
    artifact = {"id": 400, "name": "verified-pr-source-100-a1", "expired": False,
                "workflow_run": {"id": 100, "head_sha": HEAD}, "size_in_bytes": len(raw),
                "digest": "sha256:" + proof.digest(raw)}
    log = b"2026-10-26T01:00:00Z python3 -m unittest discover -s scripts -p 'test_*.py' -v\n2026-10-26T01:00:02Z Ran 1391 tests in 368.418s\n2026-10-26T01:00:02Z OK (skipped=4)\n"
    return run, jobs, receipt, pr, commit, artifact, raw, log


class VerifiedPRSourceChecksTests(unittest.TestCase):
    def test_original_job_requires_every_named_check_and_upload_to_pass(self):
        run, jobs, *_ = fixtures()
        self.assertEqual(proof.verify_run(run, jobs, 100)["id"], 200)
        for key, value in (("event", "push"), ("run_attempt", 2), ("conclusion", "failure"),
                           ("path", ".github/workflows/ci.yml"), ("actor", {"login": "other"})):
            with self.subTest(key=key), self.assertRaises(ValueError):
                proof.verify_run(dict(run, **{key: value}), jobs, 100)
        for index in range(5):
            for conclusion in ("failure", "skipped", "cancelled", None):
                changed = deepcopy(jobs)
                changed["jobs"][0]["steps"][index]["conclusion"] = conclusion
                with self.subTest(index=index, conclusion=conclusion), self.assertRaises(ValueError):
                    proof.verify_run(run, changed, 100)
        for changed in ({"total_count": 2, "jobs": jobs["jobs"]}, {"total_count": 2, "jobs": jobs["jobs"] * 2}):
            with self.assertRaises(ValueError):
                proof.verify_run(run, changed, 100)

    def test_archive_hash_identity_and_expiry_are_mandatory(self):
        run, _, receipt, _, _, artifact, raw, _ = fixtures()
        self.assertEqual(proof.original_receipt(artifact, raw, run), receipt)
        for key, value in (("expired", True), ("digest", "sha256:wrong"), ("size_in_bytes", 1),
                           ("workflow_run", {"id": 99, "head_sha": HEAD}), ("name", "other")):
            with self.subTest(key=key), self.assertRaises(ValueError):
                proof.original_receipt(dict(artifact, **{key: value}), raw, run)
        with self.assertRaises(ValueError):
            proof.original_receipt(artifact, raw + b"changed", run)

    def test_same_tree_is_required_in_addition_to_exact_owned_pr_merge(self):
        _, _, receipt, pr, commit, *_ = fixtures()
        proof.verify_tree(receipt, pr, commit, MERGE, TREE, "rc")
        for changed in (dict(pr, merged=False), dict(pr, merge_commit_sha=HEAD),
                        dict(pr, head={"sha": HEAD, "repo": {"full_name": "fork/project"}})):
            with self.assertRaises(ValueError):
                proof.verify_tree(receipt, changed, commit, MERGE, TREE, "rc")
        for head, tree, ref in ((HEAD, TREE, "rc"), (MERGE, "e" * 40, "rc"), (MERGE, TREE, "other")):
            with self.assertRaises(ValueError):
                proof.verify_tree(receipt, pr, commit, head, tree, ref)
        with self.assertRaises(ValueError):
            proof.verify_tree(receipt, pr, dict(commit, sha=HEAD), MERGE, TREE, "rc")

    def test_receipt_content_and_archive_layout_cannot_substitute_other_sources(self):
        run, _, receipt, _, _, artifact, _, _ = fixtures()
        mutations = [(key, value) for key, value in (
            ("headRepository", "fork/project"), ("attempt", 2), ("runID", 99),
            ("checkoutSHA", "../foreign"), ("headSHA", "e" * 40),
            ("treeSHA", "invalid"), ("pullRequest", "300"), ("pullRequest", True))]
        for key, value in [*mutations, ("extra-entry", True)]:
            changed = dict(receipt, **({key: value} if key != "extra-entry" else {}))
            data = io.BytesIO()
            with zipfile.ZipFile(data, "w") as archive:
                archive.writestr("receipt.json", json.dumps(changed))
                if key == "extra-entry":
                    archive.writestr("unexpected", "content")
            raw = data.getvalue()
            metadata = dict(artifact, size_in_bytes=len(raw), digest="sha256:" + proof.digest(raw))
            with self.subTest(key=key), self.assertRaises(ValueError):
                proof.original_receipt(metadata, raw, run)

    def test_missing_ambiguous_failed_or_empty_original_suite_cannot_be_reused(self):
        log = fixtures()[-1]
        self.assertEqual(proof.test_completion(log), {"tests": 1391, "summary": "OK (skipped=4)"})
        colored = log.replace(b"Ran 1391", b"\x1b[32mRan 1391").replace(b"368.418s", b"368.418s\x1b[0m")
        self.assertEqual(proof.test_completion(colored), proof.test_completion(log))
        for changed in (b"", log + log, log.replace(b"1391 tests", b"0 tests"),
                        log.replace(b"OK (skipped=4)", b"FAILED (failures=1)"),
                        log.replace(b"skipped=4", b"skipped=1391"),
                        log + b"ERROR: fixture (test_example.Test.test_fixture)\n",
                        log + b"\x1b[31mERROR: fixture (test_example.Test.test_fixture)\x1b[0m\n",
                        log.replace(b"test_*.py", b"test_subset.py")):
            with self.assertRaises(ValueError):
                proof.test_completion(changed)

    def test_record_keeps_actual_checkout_separate_from_pr_head(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            event = root / "event.json"
            event.write_text(json.dumps({"number": 300, "pull_request": fixtures()[3]}))
            env = {"GITHUB_EVENT_NAME": "pull_request", "GITHUB_EVENT_PATH": str(event),
                   "GITHUB_SHA": CHECKOUT, "GITHUB_REPOSITORY": proof.REPOSITORY,
                   "GITHUB_RUN_ID": "100", "GITHUB_RUN_ATTEMPT": "1"}
            with patch.dict(os.environ, env), patch.object(proof, "git", side_effect=[CHECKOUT, "", TREE]):
                proof.record(root / "proof")
            receipt = json.loads((root / "proof/receipt.json").read_text())
            self.assertEqual(receipt["checkoutSHA"], CHECKOUT)
            self.assertEqual(receipt["headSHA"], HEAD)
            self.assertEqual(receipt["treeSHA"], TREE)
            with patch.dict(os.environ, env), patch.object(proof, "git", side_effect=[CHECKOUT, " M source"]):
                with self.assertRaises(ValueError):
                    proof.record(root / "dirty")
            self.assertFalse((root / "dirty").exists())

    def prepare_fixture(self, failure=None):
        run, jobs, receipt, pr, commit, artifact, raw, log = fixtures()
        if failure == "step":
            jobs["jobs"][0]["steps"][0]["conclusion"] = "skipped"
        if failure == "tree":
            commit["tree"]["sha"] = "e" * 40
        if failure == "log":
            log = b"incomplete"
        responses = {"actions/runs/100": run, "actions/runs/100/attempts/1/jobs?per_page=100": jobs,
                     "actions/runs/100/artifacts?per_page=100": {"total_count": 1, "artifacts": [artifact]},
                     "actions/artifacts/400": artifact, "pulls/300": pr, "git/commits/" + CHECKOUT: commit}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "output"
            env = {"GITHUB_REPOSITORY": proof.REPOSITORY, "GITHUB_SHA": MERGE, "GITHUB_REF_NAME": "rc",
                   "GITHUB_RUN_ID": "500", "GITHUB_RUN_ATTEMPT": "1", "GITHUB_OUTPUT": str(output)}
            with patch.dict(os.environ, env), patch.object(proof, "git", side_effect=[MERGE, "", TREE]), \
                    patch.object(proof, "api", side_effect=lambda path: responses[path]), \
                    patch.object(proof, "read_api", side_effect=lambda path, *args: raw if path.endswith("/zip") else log):
                if failure:
                    with self.assertRaises(ValueError):
                        proof.prepare(100, root / "proof")
                    self.assertFalse(output.exists())
                    return
                proof.prepare(100, root / "proof")
            self.assertEqual(output.read_text(), "verified=true\n")
            composition = json.loads((root / "proof/receipt.json").read_text())
            self.assertEqual(composition["sourceSHA"], MERGE)
            self.assertEqual(composition["originalReceipt"], receipt)
            self.assertEqual(composition["reusedSteps"], list(proof.CHECKS))
            self.assertEqual((root / "proof/original-job.log").read_bytes(), log)
            self.assertEqual((root / "proof/original-proof.zip").read_bytes(), raw)

    def test_prepare_emits_reuse_only_after_original_evidence_and_tree_checks(self):
        self.prepare_fixture()
        for failure in ("step", "tree", "log"):
            with self.subTest(failure=failure):
                self.prepare_fixture(failure)

    def test_download_is_byte_preserving_bounded_and_never_forwards_credentials(self):
        opener = MagicMock()
        response = opener.open.return_value.__enter__.return_value
        response.read.return_value = b"PK\x00\x1b\xff"
        with patch.dict(os.environ, GH_TOKEN="synthetic-test-only"), \
                patch.object(proof.urllib.request, "build_opener", return_value=opener):
            self.assertEqual(proof.read_api("actions/artifacts/400/zip", 100), b"PK\x00\x1b\xff")
            request = opener.open.call_args.args[0]
            redirected = proof.HTTPSRedirect().redirect_request(request, None, 302, "Found", {}, "https://example.test/file")
            self.assertFalse(redirected.has_header("Authorization"))
            with self.assertRaises(ValueError):
                proof.HTTPSRedirect().redirect_request(request, None, 302, "Found", {}, "http://example.test/file")
            response.read.return_value = b"x" * 101
            with self.assertRaises(ValueError):
                proof.read_api("actions/artifacts/400/zip", 100)
            response.read.side_effect = proof.http.client.IncompleteRead(b"private", 100)
            with self.assertRaisesRegex(ValueError, "^GitHub source evidence download failed$"):
                proof.read_api("actions/artifacts/400/zip", 100)

    def test_workflows_reuse_only_verified_shared_checks_and_preserve_native_gates(self):
        root = Path(__file__).resolve().parents[1]
        ci = (root / ".github/workflows/ci.yml").read_text()
        pr = (root / ".github/workflows/pr-checks.yml").read_text()
        batch = (root / ".github/workflows/ci-batch.yml").read_text()
        self.assertLess(pr.index("- name: Verify CI and fixture tooling"), pr.index("- name: Record verified source checkout"))
        self.assertNotIn("continue-on-error", pr)
        self.assertEqual(ci.count("steps.pr_source.outputs.verified != 'true'"), 3)
        for name in proof.CHECKS:
            step = ci.split("      - name: " + name + "\n", 1)[1].split("      - name:", 1)[0]
            self.assertIn("steps.pr_source.outputs.verified != 'true'", step)
        distribution = ci.split("      - name: Require distributable bpy before app transfer\n", 1)[1].split("      - name:", 1)[0]
        self.assertNotIn("pr_source", distribution)
        binding = ci.split("      - name: Bind exact PR source checks\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn('test "$OTHER_SOURCE_REUSE" = false', binding)
        self.assertNotIn("continue-on-error", binding)
        self.assertIn("verified_pr_run_id: ${{ inputs.verified_pr_run_id }}", batch)
        self.assertIn("if verified_pr and (mode != 'initial'", batch)
        for workflow in (ci, batch):
            self.assertIn("  pull-requests: read\n", re.split(r"(?m)^jobs:\s*\n", workflow, maxsplit=1)[0])

    def test_core_shell_rejects_other_reuse_before_invoking_preparation(self):
        root = Path(__file__).resolve().parents[1]
        ci = (root / ".github/workflows/ci.yml").read_text()
        binding = ci.split("      - name: Bind exact PR source checks\n", 1)[1].split("      - name:", 1)[0]
        body = textwrap.dedent(binding.split("        run: |\n", 1)[1])
        for name in ("completed_source_checks_run_id", "completed_full_core_run_id", "completed_backends_run_id",
                     "completed_app_tests_run_id", "app_inventory_run_id"):
            self.assertIn("inputs." + name + " != ''", binding)
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            marker = temp / "called"
            shim = temp / "python3"
            shim.write_text('#!/bin/sh\nprintf invoked > "$PROOF_CALL_MARKER"\n')
            shim.chmod(0o755)
            for other in ("true", "false"):
                result = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", body],
                    env={**os.environ, "PATH": str(temp) + os.pathsep + os.environ["PATH"],
                         "PROOF_CALL_MARKER": str(marker), "OTHER_SOURCE_REUSE": other,
                         "ORIGINAL_PR_RUN": "100", "RUNNER_TEMP": str(temp)}, capture_output=True, timeout=5)
                self.assertEqual(result.returncode == 0, other == "false")
                self.assertEqual(marker.exists(), other == "false")

    def test_every_reusable_ci_caller_grants_source_proof_permissions(self):
        workflows = Path(__file__).resolve().parents[1] / ".github/workflows"
        callers = set()
        for path in workflows.glob("*.yml"):
            text = path.read_text()
            if "uses: ./.github/workflows/ci.yml" not in text:
                continue
            callers.add(path.name)
            self.assertIn("  pull-requests: read\n", re.split(r"(?m)^jobs:\s*\n", text, maxsplit=1)[0], path.name)
            for job in re.split(r"(?m)^  [A-Za-z0-9_-]+:\n", re.split(r"(?m)^jobs:\s*\n", text, maxsplit=1)[1]):
                if "uses: ./.github/workflows/ci.yml" in job and "    permissions:\n" in job:
                    self.assertIn("      pull-requests: read\n", job, path.name)
        self.assertEqual(callers, {"bundle.yml", "ci-batch.yml"})


if __name__ == "__main__":
    unittest.main()
