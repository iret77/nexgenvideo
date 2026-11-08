import json
import os
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch

import release_test_repair as repair


ROOT = Path(__file__).resolve().parent.parent


def receipt():
    methods = re.findall(r"@Test(?:\([^\n]*\))?\s+func\s+(\w+)\(([^)]*)\)", (ROOT / repair.FIXTURE).read_text())
    selected = sorted(repair.PREFIX + name + "(" + "".join(
        item.strip().split(":")[0].split()[0] + ":" for item in parameters.split(",") if item.strip()) + ")"
        for name, parameters in methods)
    source, run = "a" * 40, 123456
    return {"schema": "release-native-scoped-repair/v1", "sourceSHA": source, "runID": run, "attempt": 1,
            "originalSourceSHA": repair.SOURCE, "originalRun": repair.RUN, "originalEventSHA256": repair.EVENT_SHA,
            "originalRuntimeSHA256": repair.RUNTIME_SHA, "originalRuntimeTreeSHA256": repair.TREE_SHA, "passed": True,
            "hostSHA256": repair.HOST_SHA, "appObjectSHA256": repair.APP_OBJECT_SHA, "selectedMethods": selected,
            "reusedAppMethodIDsSHA256": repair.REUSED_SHA,
            "counts": {"freshAppMethods": 59, "reusedAppMethods": 3646, "reusedXCTest": 48, "reusedEngineMethods": 896,
                       "executions": 4649, "declaredAppMethods": 3713, "appSkips": 8, "engineSkips": 14, "freshParameterCases": 9},
            **{name: "b" * 64 for name in ("eventSHA256", "consoleSHA256", "hostReceiptSHA256", "compileReceiptSHA256", "testBundleSHA256")},
            "compilerUpload": {"artifact": {"id": 56789, "expired": False, "name": "release-scoped-test-products-123456-a1", "digest": "sha256:" + "c" * 64,
                               "workflow_run": {"id": run, "head_sha": source}},
                               "built": {"schema": "release-native-scoped-products/v1", "archiveSHA256": "e" * 64,
                                         "sourceSHA": source, "runID": run, "attempt": 1, "compileReceiptSHA256": "b" * 64}}}


class ScopedReleaseRepairTests(unittest.TestCase):
    def test_exact_scoped_coverage_is_accepted_without_a_fresh_aggregate_claim(self):
        value = receipt()
        self.assertIs(repair.verify_receipt(value, value["sourceSHA"], value["runID"]), value)
        self.assertEqual(value["counts"]["executions"], sum(value["counts"][name] for name in
                         ("freshAppMethods", "reusedAppMethods", "reusedXCTest", "reusedEngineMethods")))

    def test_missing_original_failure_cannot_be_replaced_by_another_passing_method(self):
        value = receipt()
        value["selectedMethods"].remove(repair.FAILED)
        value["selectedMethods"].append(repair.PREFIX + "unrelatedPassingMethod()")
        with self.assertRaises(ValueError):
            repair.verify_receipt(value, value["sourceSHA"], value["runID"])

    def test_a_changed_other_original_method_cannot_hide_behind_the_same_count(self):
        value = receipt()
        index = next(index for index, name in enumerate(value["selectedMethods"]) if name not in (repair.FAILED, repair.ADDED))
        value["selectedMethods"][index] = repair.PREFIX + "fabricatedCoverage()"
        with self.assertRaises(ValueError):
            repair.verify_receipt(value, value["sourceSHA"], value["runID"])

    def test_failed_original_work_cannot_be_reclassified_as_reused_success(self):
        for key, replacement in (("freshAppMethods", 58), ("reusedAppMethods", 3647), ("freshParameterCases", 8),
                                 ("reusedEngineMethods", 897), ("appSkips", 9)):
            with self.subTest(key=key):
                value = receipt()
                value["counts"][key] = replacement
                with self.assertRaises(ValueError):
                    repair.verify_receipt(value, value["sourceSHA"], value["runID"])

    def test_a_different_app_host_original_or_runtime_does_not_qualify(self):
        for key in ("hostSHA256", "appObjectSHA256", "originalEventSHA256", "originalRuntimeSHA256", "originalRuntimeTreeSHA256"):
            with self.subTest(key=key):
                value = receipt()
                value[key] = "d" * 64
                with self.assertRaises(ValueError):
                    repair.verify_receipt(value, value["sourceSHA"], value["runID"])

    def test_a_compiler_upload_from_another_attempt_run_or_source_is_rejected(self):
        for target, key, replacement in (("built", "attempt", 2), ("built", "runID", 42),
                                          ("built", "sourceSHA", "d" * 40), ("artifact", "digest", ""),
                                          ("artifact", "id", 0), ("artifact", "expired", True),
                                          ("built", "schema", "other"), ("built", "archiveSHA256", "")):
            with self.subTest(target=target, key=key):
                value = receipt()
                value["compilerUpload"][target][key] = replacement
                with self.assertRaises(ValueError):
                    repair.verify_receipt(value, value["sourceSHA"], value["runID"])

    def test_a_changed_original_failure_archive_is_rejected_before_parsing(self):
        with self.assertRaisesRegex(ValueError, "Original App events differ"):
            repair.original_inventory(b'{"kind":"event","payload":{"kind":"runEnded"}}\n')

    def test_clang_imports_require_pinned_header_bytes_and_the_complete_public_inventory(self):
        original = b"int pinned_header(void);\n"
        for change in ("none", "bytes", "additional"):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                directory = root / "Sources/CFixture"
                headers = directory / "include"
                headers.mkdir(parents=True)
                header = headers / "CFixture.h"
                header.write_bytes(original if change != "bytes" else b"int changed_header(void);\n")
                if change == "additional":
                    (headers / "Extra.h").write_bytes(b"int unpinned_header(void);\n")
                name = "Sources/CFixture/include/CFixture.h"
                def git(arguments, **kwargs):
                    if "ls-tree" in arguments:
                        return ("100644 blob " + "a" * 40 + "\t" + name + "\0").encode()
                    if "cat-file" in arguments:
                        return original
                    self.fail("Unexpected header proof command")
                with patch.object(repair.subprocess, "check_output", side_effect=git):
                    if change == "none":
                        self.assertEqual(repair.header_inputs(root, directory, headers), {name: repair.sha(original)})
                    else:
                        with self.assertRaises(ValueError):
                            repair.header_inputs(root, directory, headers)

    def test_native_compilation_cannot_run_on_a_non_macos_or_foreign_job(self):
        with patch.dict(os.environ, {"GITHUB_REPOSITORY": "iret77/nexgenvideo", "GITHUB_ACTIONS": "true",
                                     "GITHUB_JOB": "release-build", "GITHUB_RUN_ATTEMPT": "1"}, clear=True), \
                patch.object(repair.sys, "platform", "linux"), patch.object(repair.subprocess, "run") as run:
            with self.assertRaises(ValueError):
                repair.execute(Path("/nonexistent/repair"))
            run.assert_not_called()

    def test_compiler_products_are_uploaded_and_confirmed_before_any_scoped_test(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        names = ("Compile the changed App test module using retained products", "Upload repaired test products before execution",
                 "Confirm repaired test product upload", "Verify the complete changed GenerationBatch test scope")
        positions = [workflow.index("      - name: " + name + "\n") for name in names]
        self.assertEqual(positions, sorted(positions))
        for position in positions:
            step = workflow[position:].split("\n      - ", 1)[0]
            self.assertIn("if: inputs.completed_release_tests_run_id == '42500881402'", step)
        self.assertIn("if: always() && inputs.completed_release_tests_run_id == '42500881402'", workflow)


if __name__ == "__main__":
    unittest.main()
