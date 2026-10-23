import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
CI = WORKFLOWS / "ci.yml"
DIAGNOSTIC_ACCEPTANCE = WORKFLOWS / "diagnostic-acceptance.yml"
PR_CHECKS = WORKFLOWS / "pr-checks.yml"
CI_BATCH = WORKFLOWS / "ci-batch.yml"
AUTOMATIC_TRIGGERS = {"push", "pull_request", "pull_request_target", "schedule", "merge_group"}


def triggers(path):
    lines = path.read_text().splitlines()
    keys = []
    for line in lines[lines.index("on:") + 1:]:
        if line and not line.startswith(" "):
            break
        stripped = line.strip()
        if line.startswith("  ") and not line.startswith("   ") and stripped and not stripped.startswith("#"):
            keys.append(stripped.split(":", 1)[0])
    return keys


def run_commands(text):
    commands = []
    for block in text.split("run: ")[1:]:
        first = block.split("\n", 1)[0]
        if first.strip() == "|":
            body = []
            for line in block.split("\n")[1:]:
                if line.strip() and not line.startswith("            "):
                    break
                body.append(line.strip())
            commands.append("\n".join(line for line in body if line))
        else:
            commands.append(first.strip())
    return commands


class CIWorkflowTests(unittest.TestCase):
    def test_ui_render_diagnostics_upload_on_failure_without_qualifying_partial_captures(self):
        job = CI.read_text().split("  ui_render:\n", 1)[1].split("  bpy-source:\n", 1)[0]
        render = job.split("      - name: Render Agent UI specification\n", 1)[1].split("      - name:", 1)[0]
        for renderer in ("render_agent_chat_spec.py", "render_generation_batch_review_spec.py", "render_workbench_reference.py"):
            self.assertEqual(render.count(f"python3 scripts/{renderer} --output"), 1)
        self.assertNotIn("continue-on-error", job)
        success = job.split("      - name: Upload Agent UI render evidence\n", 1)[1].split("      - name:", 1)[0]
        self.assertIn("name: agent-chat-spec-${{ github.run_id }}", success)
        self.assertNotIn("if: always()", success)
        diagnostic = job.split("      - name: Upload Agent UI renderer diagnostics\n", 1)[1]
        self.assertIn("if: always()", diagnostic)
        self.assertIn("name: agent-ui-render-diagnostics-${{ github.run_id }}-a${{ github.run_attempt }}", diagnostic)
        for path in ("agent-chat-spec/diagnostics", "agent-chat-spec/*.png", "workbench-reference/diagnostics", "workbench-reference/*.png"):
            self.assertIn("${{ runner.temp }}/" + path, diagnostic)
        self.assertIn("if-no-files-found: error", diagnostic)
        self.assertIn("retention-days: 14", diagnostic)

    def test_bpy_host_crash_cleanup_rejects_an_orphan_in_the_first_mode(self):
        workflow = (WORKFLOWS / "bpy-runtime-acceptance.yml").read_text()
        step = workflow.split("      - name: Prove pre-lease and post-exec host-crash cleanup\n", 1)[1]
        step = step.split("      - name:", 1)[0]
        run = textwrap.dedent(step.split("        run: |\n", 1)[1])
        for orphan, ordinary_failure in ((True, False), (False, False), (False, True)):
            with self.subTest(first_mode_orphan=orphan, ordinary_failure=ordinary_failure), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                app = root / "relocated/NexGenVideo.app/Contents/MacOS/NexGenVideo"
                app.parent.mkdir(parents=True)
                app.write_text(textwrap.dedent("""\
                    #!/usr/bin/env python3
                    import json, os, signal, uuid
                    from pathlib import Path
                    mode = os.environ["NGV_SELFTEST_BPY_HOST_CRASH"]
                    with open(os.environ["FAKE_APP_CALLS"], "a") as calls:
                        calls.write(mode + "\\n")
                    Path(os.environ["FAKE_MODE"]).write_text(mode + "\\n")
                    if os.environ["FAKE_ORDINARY_FAILURE"] == "1":
                        raise SystemExit(1)
                    proof = dict(schema=1, mode=mode, state="running", pid=os.getpid(),
                                 sourceSHA=os.environ["EXPECTED_SOURCE"], jobID=str(uuid.uuid4()),
                                 supervisorPID=100000000)
                    if mode == "before-authorization":
                        proof["authorizationID"] = str(uuid.uuid4())
                    else:
                        proof["workerPID"] = 100000001
                    Path(os.environ["NGV_SELFTEST_BPY_HOST_CRASH_EVIDENCE"]).write_text(json.dumps(proof))
                    os.kill(os.getpid(), signal.SIGKILL)
                    """))
                (root / "scripts").mkdir()
                shutil.copyfile(ROOT / "scripts/bpy_runtime_acceptance.py", root / "scripts/bpy_runtime_acceptance.py")
                app.chmod(0o755)
                binary = root / "bin"
                binary.mkdir()
                pgrep = binary / "pgrep"
                pgrep.write_text(textwrap.dedent("""\
                    #!/bin/bash
                    set -euo pipefail
                    if [ "$FAKE_FIRST_ORPHAN" = 1 ] && [ "$(cat "$FAKE_MODE")" = before-authorization ]; then
                      exit 0
                    fi
                    exit 1
                    """))
                pgrep.chmod(0o755)
                sleep = binary / "sleep"
                sleep.write_text("#!/bin/sh\nexit 0\n")
                sleep.chmod(0o755)
                env = dict(os.environ, RUNNER_TEMP=str(root), PATH=str(binary) + os.pathsep + os.environ["PATH"],
                           FAKE_APP_CALLS=str(root / "calls"), FAKE_MODE=str(root / "mode"),
                           FAKE_FIRST_ORPHAN="1" if orphan else "0", EXPECTED_SOURCE="a" * 40,
                           FAKE_ORDINARY_FAILURE="1" if ordinary_failure else "0",
                           NGV_BPY_DIAGNOSTIC_DEADLINE=str(time.time() + 1200))
                result = subprocess.run(
                    ["bash", "--noprofile", "--norc", "-c", run], cwd=root, env=env,
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=10,
                )
                self.assertEqual(result.returncode, 1 if orphan or ordinary_failure else 0, result.stdout)
                expected = ["before-authorization"] if orphan or ordinary_failure else ["before-authorization", "after-authorization"]
                self.assertEqual((root / "calls").read_text().splitlines(), expected)
                if orphan:
                    self.assertIn("orphan bpy process after before-authorization", result.stdout)
                if ordinary_failure:
                    self.assertIn("host probe failed before its crash was armed", result.stdout)

    def test_merge_gate_requires_every_selected_job(self):
        text = CI.read_text().split("  merge_gate:\n", 1)[1]
        code = text.split("          python3 - <<'PYTHON'\n", 1)[1].split("          PYTHON", 1)[0]
        code = "\n".join(line[10:] for line in code.splitlines())
        for required in (True, False):
            needs = {
                "source_gate": {"result": "success", "outputs": {
                    key: str(required).lower() for key in ("build_required", "bundle_required", "ui_required")
                }},
                **{job: {"result": "success" if required else "skipped"}
                   for job in ("build_test", "ui_render", "diagnostic-startup", "bpy-source", "bpy-runtime")},
            }
            def check():
                return subprocess.run([sys.executable, "-c", code], env={**os.environ, "NEEDS_JSON": json.dumps(needs)}, capture_output=True)
            self.assertEqual(check().returncode, 0)
            for job in needs:
                previous = needs[job]["result"]
                unexpected = "skipped" if required or job == "source_gate" else "success"
                for result in ("failure", "cancelled", unexpected):
                    with self.subTest(required=required, job=job, result=result):
                        needs[job]["result"] = result
                        self.assertNotEqual(check().returncode, 0)
                needs[job]["result"] = previous
            needs["source_gate"]["outputs"].pop("bundle_required")
            self.assertNotEqual(check().returncode, 0)

    def test_debug_bundle_reuses_the_build_job_and_keeps_load_checks(self):
        text = CI.read_text()
        build = text.split("  build_test:\n", 1)[1].split("  diagnostic-startup:\n", 1)[0]
        self.assertIn("--build-tests", build)
        self.assertIn("scripts/bundle.sh debug", build)
        self.assertIn("scripts/assemble_ngvpack.sh", build)
        self.assertIn("NGV_SELFTEST_PACK=", build)
        self.assertIn("NGV_SELFTEST_EXPECT_ENGINE_INCOMPATIBLE=1", build)
        self.assertIn("scripts/relaunch_selftest.sh", build)
        self.assertNotIn("render_agent_chat_spec.py", build)
        self.assertNotIn("pull_request:", (ROOT / ".github/workflows/bundle.yml").read_text())

    def test_native_export_actions_run_for_pr_bundle_and_signed_release(self):
        ci = CI.read_text()
        startup = ci.split("  diagnostic-startup:\n", 1)[1].split("  merge_gate:\n", 1)[0]
        self.assertIn("runs-on: macos-26", startup)
        self.assertIn("name: NexGenVideo-app", startup)
        self.assertIn("scripts/export_actions_acceptance.py candidate/NexGenVideo.app", startup)
        self.assertIn("evidence/export-actions.json", startup)
        self.assertIn("if: always()", startup)

        release = DIAGNOSTIC_ACCEPTANCE.read_text()
        self.assertIn("runs-on: macos-26", release)
        self.assertIn("scripts/export_actions_acceptance.py NexGenVideo.app", release)
        self.assertIn("evidence/export-actions.json", release)

    def test_generation_review_is_independent_and_uses_the_same_immutable_runtime(self):
        workspace = (WORKFLOWS / "workspace-ui-acceptance.yml").read_text()
        batch = workspace.split("  batch-review:\n", 1)[1].split("  qualification:\n", 1)[0]
        self.assertIn("needs: [source, runtime]", batch)
        self.assertNotIn("needs: acceptance", batch)
        self.assertIn("runs-on: macos-26", batch)
        self.assertIn("uses: ./.github/actions/prepare-native-runtime", batch)
        self.assertIn("artifact-id: ${{ needs.runtime.outputs.artifact_id }}", batch)
        self.assertIn("scripts/workspace_native_case.py", batch)
        self.assertIn("scripts/workspace_native_ci.py archive", batch)
        self.assertIn("always() && steps.runtime.outcome == 'success'", batch)
        self.assertNotIn("continue-on-error", batch)
        driver = (ROOT / "scripts/workspace_native_case.py").read_text()
        self.assertIn("NGV_SELFTEST_GENERATION_BATCH_REVIEW", driver)
        self.assertIn("SELFTEST_GENERATION_BATCH_REVIEW_OK", driver)
        self.assertIn("process.wait(timeout=300)", driver)

    def test_workspace_unit_regressions_are_optional_filtered_and_staged(self):
        workspace = (WORKFLOWS / "workspace-ui-acceptance.yml").read_text()
        for trigger in ("workflow_dispatch", "workflow_call"):
            inputs = workspace.split(f"  {trigger}:\n", 1)[1].split("\n\n", 1)[0].split("  workflow_call:", 1)[0]
            self.assertIn("unit_test_filter:", inputs)
            self.assertIn("type: string", inputs)
            self.assertIn("default: ''", inputs)
        build = workspace.split("  build:\n", 1)[1].split("  runtime:\n", 1)[0]
        self.assertLess(build.index("name: Build acceptance app"), build.index("name: Run selected unit regressions"))
        selected = build.split("      - name: Run selected unit regressions\n", 1)[1]
        self.assertIn("if: inputs.unit_test_filter != ''", selected)
        self.assertIn("NGV_UNIT_TEST_FILTER: ${{ inputs.unit_test_filter }}", selected)
        run = selected.split("        run: |\n", 1)[1].split("      - name:", 1)[0]
        self.assertNotIn("${{", run)
        self.assertLess(run.index("--build-tests"), run.index("scripts/stage_test_runtime.sh debug"))
        self.assertLess(run.index("scripts/stage_test_runtime.sh debug"), run.index("scripts/run_macos_tests.py"))
        self.assertIn('python3 scripts/run_macos_tests.py --cache-path "$NGV_SWIFTPM_CACHE_PATH"', run)
        self.assertIn('--filter "$NGV_UNIT_TEST_FILTER" --evidence "$RUNNER_TEMP/workspace-unit-tests"', run)
        self.assertIn('name: workspace-unit-tests-${{ github.run_id }}', selected)
        self.assertNotIn("scripts/bundle.sh", run)

    def test_workspace_native_acceptance_keeps_the_uploaded_app_after_unit_failure(self):
        workspace = (WORKFLOWS / "workspace-ui-acceptance.yml").read_text()
        build = workspace.split("  build:\n", 1)[1].split("  runtime:\n", 1)[0]
        runtime = workspace.split("  runtime:\n", 1)[1].split("  acceptance:\n", 1)[0]
        self.assertLess(build.index("name: Build acceptance app"), build.index("name: Upload acceptance app"))
        self.assertLess(build.index("name: Upload acceptance app"), build.index("name: Run selected unit regressions"))
        self.assertIn("app_artifact_id: ${{ steps.upload_app.outputs.artifact-id }}", build)
        self.assertIn("needs.build.outputs.app_ready == 'true'", runtime)
        self.assertIn("NGV_RUNTIME_ARTIFACT_ID: ${{ needs.build.outputs.app_artifact_id }}", runtime)
        self.assertIn("scripts/workspace_native_ci.py download-runtime", runtime)
        self.assertIn("identity_sha: ${{ steps.prepare.outputs.identity_sha256 }}", runtime)
        self.assertNotIn("continue-on-error", build)

    def test_workspace_case_and_scale_are_validated_before_any_native_launch(self):
        workspace = (WORKFLOWS / "workspace-ui-acceptance.yml").read_text()
        source = workspace.split("  source:\n", 1)[1].split("  build:\n", 1)[0]
        self.assertIn("scripts/workspace_native_ci.py plan", source)
        self.assertIn("test_workspace_native_ci.py", source)
        self.assertIn("test_generation_batch_busy_evidence.py", source)
        self.assertIn("NGV_ACCEPTANCE_CASE: ${{ inputs.acceptance_case }}", source)
        native = workspace.split("  acceptance:\n", 1)[1].split("  batch-review:\n", 1)[0]
        self.assertIn("needs: [source, runtime]", native)
        self.assertIn("max-parallel: 3", native)
        self.assertIn("matrix: ${{ fromJSON(needs.source.outputs.matrix) }}", native)
        self.assertIn('--case "$NGV_NATIVE_CASE" --scale "$NGV_NATIVE_SCALE"', native)
        self.assertIn("native-evidence-${{ matrix.id }}-a${{ github.run_attempt }}", native)
        self.assertNotIn("/evidence/scale-*", native)
        gate = workspace.split("  qualification:\n", 1)[1]
        self.assertIn("needs: [source, runtime, acceptance, batch-review]", gate)
        self.assertIn("scripts/workspace_native_ci.py summary", gate)
        self.assertIn('"$NGV_NATIVE_IDENTITY_SHA" --remote', gate)
        self.assertIn("GH_TOKEN: ${{ github.token }}", gate)
        self.assertNotIn("pattern: native-evidence-*", gate)
        self.assertIn("cancel-in-progress: false", workspace)

    def test_only_the_light_pull_request_check_starts_automatically(self):
        for path in sorted(WORKFLOWS.glob("*.yml")):
            automatic = set(triggers(path)) & AUTOMATIC_TRIGGERS
            with self.subTest(workflow=path.name):
                if path == PR_CHECKS:
                    self.assertEqual(automatic, {"pull_request"})
                else:
                    self.assertEqual(automatic, set())
        text = PR_CHECKS.read_text()
        header = text.split("jobs:", 1)[0].splitlines()
        self.assertFalse(any(line.strip().startswith(("paths:", "paths-ignore:")) for line in header))
        self.assertNotIn("runs-on: macos", text)
        self.assertNotIn("runs-on: xcode", text)
        self.assertNotIn("runs-on: macrunner", text)
        self.assertNotIn("uses: ./.github/workflows/", text)

    def test_macos_builds_use_macrunner_and_runtime_acceptance_keeps_the_macos_26_floor(self):
        for path in sorted(WORKFLOWS.glob("*.yml")):
            lines = path.read_text().splitlines()
            for index, line in enumerate(lines):
                if not line.strip().startswith("runs-on:"):
                    continue
                runner = line.split(":", 1)[1].strip()
                with self.subTest(workflow=path.name, line=index + 1):
                    self.assertIn(runner, {"ubuntu-24.04", "macrunner", "macos-26"})
                    if runner == "macos-26":
                        self.assertIn("ci-lint: allow-CI005", lines[index - 1])
                        job = []
                        for body in lines[index + 1:]:
                            if body.startswith("  ") and not body.startswith("   ") and body.strip():
                                break
                            job.append(body)
                        job = "\n".join(job)
                        for build_step in ("swift build", "swift test", "scripts/bundle.sh", "setup-xcode-27"):
                            self.assertNotIn(build_step, job)

    def test_pull_request_check_mirrors_the_ci_light_job(self):
        light = CI.read_text().split("  source_gate:\n", 1)[1].split("\n  ui_render:\n", 1)[0]
        pr = PR_CHECKS.read_text().split("jobs:", 1)[1]
        self.assertIn("    name: Light Checks\n", light)
        self.assertIn("    name: Light Checks\n", pr)
        commands = run_commands(pr)
        self.assertTrue(commands)
        for command in commands:
            with self.subTest(command=command):
                self.assertIn(command, run_commands(light))

    def test_ci_batch_is_the_manual_heavy_entry_point(self):
        text = CI_BATCH.read_text()
        self.assertEqual(triggers(CI_BATCH), ["workflow_dispatch"])
        self.assertIn("cancel-in-progress: false", text)
        called = [line.split("./.github/workflows/", 1)[1].strip()
                  for line in text.splitlines() if "uses: ./.github/workflows/" in line]
        self.assertEqual(
            set(called),
            {"ci.yml", "chat-hang-replay.yml", "recorded-hang-replay.yml",
             "signing-preflight.yml", "workspace-ui-acceptance.yml", "private-example-analysis.yml",
             "external-gui-acceptance.yml", "settings-owner-acceptance.yml", "smart-search-owner-acceptance.yml",
             "bpy-source-closure.yml"},
        )
        for name in called:
            with self.subTest(workflow=name):
                self.assertIn("workflow_call", triggers(WORKFLOWS / name))
        analysis = text.split("  musicvideo-analysis-acceptance:\n", 1)[1]
        self.assertIn("needs: [validate, ci]", analysis)
        self.assertIn(
            "if: ${{ !cancelled() && needs.validate.result == 'success' && needs.ci.result == 'success' && needs.validate.outputs.mode == 'initial' && inputs.musicvideo_analysis_acceptance }}",
            analysis,
        )
        self.assertIn(
            "runtime_artifact: workspace-ui-app",
            analysis,
        )
        self.assertIn("NGV_GHCR_TOKEN: ${{ secrets.NGV_GHCR_TOKEN }}", analysis)
        validation = text.split("  validate:\n", 1)[1].split("  ci:\n", 1)[0]
        code = validation.split("          python3 - <<'PYTHON'\n", 1)[1].split("          PYTHON", 1)[0]
        code = "\n".join(line[10:] for line in code.splitlines())
        defaults = {"NGV_MODE": "initial", "NGV_FOLLOWUP": "none", "NGV_RUNTIME_RUN": "",
                    "NGV_SETTINGS_SCOPE": "all", "NGV_INTERFACE_SCALE": "all", "NGV_QUALIFICATION_RUN": "",
                    "NGV_SOURCE_RUN": ""}
        valid = [({}, "initial"),
                 ({"NGV_MODE": "followup", "NGV_FOLLOWUP": "externalgui",
                   "NGV_RUNTIME_RUN": "123", "NGV_INTERFACE_SCALE": "1.25"}, "followup"),
                 ({"NGV_MODE": "followup", "NGV_FOLLOWUP": "settings",
                   "NGV_RUNTIME_RUN": "123", "NGV_SETTINGS_SCOPE": "packrecovery100"}, "followup"),
                 ({"NGV_MODE": "followup", "NGV_FOLLOWUP": "smartsearch",
                   "NGV_RUNTIME_RUN": "123"}, "followup"),
                 ({"NGV_MODE": "qualification"}, "qualification"),
                 ({"NGV_MODE": "qualification", "NGV_QUALIFICATION_RUN": "123"}, "qualification"),
                 ({"NGV_MODE": "qualification", "NGV_SOURCE_RUN": "456"}, "qualification"),
                 ({"NGV_MODE": "qualification", "NGV_SOURCE_RUN": "456",
                   "NGV_QUALIFICATION_RUN": "123"}, "qualification")]
        followup = {"NGV_MODE": "followup", "NGV_FOLLOWUP": "externalgui", "NGV_RUNTIME_RUN": "123"}
        valid += [({"NGV_MODE": "followup", "NGV_FOLLOWUP": "settings", "NGV_RUNTIME_RUN": "123",
                    "NGV_SETTINGS_SCOPE": scope}, "followup")
                  for scope in ("packresume172", "packresume172100", "packresume172125", "packresume172150")]
        invalid = [{"NGV_MODE": ""}, {"NGV_MODE": "unknown"}, {"NGV_MODE": "followup"},
                   {"NGV_RUNTIME_RUN": "123"}, {"NGV_FOLLOWUP": "settings"},
                   {"NGV_SETTINGS_SCOPE": "settings125"}, {"NGV_INTERFACE_SCALE": "1"},
                   *[{**followup, "NGV_RUNTIME_RUN": value} for value in ("", "0", "-1", " 123", "abc", "1.5")],
                   {**followup, "NGV_FOLLOWUP": "unknown"},
                   {**followup, "NGV_SETTINGS_SCOPE": "settings100"},
                   {**followup, "NGV_INTERFACE_SCALE": "2"},
                   {**followup, "NGV_FOLLOWUP": "settings", "NGV_INTERFACE_SCALE": "1"},
                   {**followup, "NGV_FOLLOWUP": "smartsearch", "NGV_SETTINGS_SCOPE": "settings"},
                   {**followup, "NGV_FOLLOWUP": "settings", "NGV_SETTINGS_SCOPE": "unknown"},
                   {**followup, "NGV_FOLLOWUP": "settings", "NGV_SETTINGS_SCOPE": "packrecovery172100"},
                   {"NGV_QUALIFICATION_RUN": "123"}, {**followup, "NGV_QUALIFICATION_RUN": "123"},
                   {"NGV_SOURCE_RUN": "456"}, {**followup, "NGV_SOURCE_RUN": "456"},
                   *[{"NGV_MODE": "qualification", "NGV_QUALIFICATION_RUN": value}
                     for value in ("0", "-1", " 123", "abc", "1.5")],
                   *[{"NGV_MODE": "qualification", "NGV_SOURCE_RUN": value}
                     for value in ("0", "-1", " 123", "abc", "1.5")],
                   {"NGV_MODE": "qualification", "NGV_FOLLOWUP": "externalgui"},
                   {"NGV_MODE": "qualification", "NGV_RUNTIME_RUN": "123"},
                   {"NGV_MODE": "qualification", "NGV_SETTINGS_SCOPE": "settings100"},
                   {"NGV_MODE": "qualification", "NGV_INTERFACE_SCALE": "1"}]
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "outputs"
            for values, mode in valid:
                with self.subTest(valid=values):
                    output.write_text("")
                    result = subprocess.run([sys.executable, "-c", code], capture_output=True,
                        env={**os.environ, **defaults, **values, "GITHUB_OUTPUT": str(output)})
                    self.assertEqual(result.returncode, 0, result.stderr.decode())
                    self.assertEqual(output.read_text(), "mode=" + mode + "\n")
            for values in invalid:
                with self.subTest(invalid=values):
                    output.write_text("")
                    result = subprocess.run([sys.executable, "-c", code], capture_output=True,
                        env={**os.environ, **defaults, **values, "GITHUB_OUTPUT": str(output)})
                    self.assertNotEqual(result.returncode, 0)
                    self.assertTrue(result.stderr.strip())
                    self.assertEqual(output.read_text(), "")

    def test_settings_recovery_families_keep_stable_cases_and_add_exact_preview_resume_cases(self):
        text = (WORKFLOWS / "settings-owner-acceptance.yml").read_text()
        code = text.split("          python3 - <<'PY'\n", 1)[1].split("          PY", 1)[0]
        code = "\n".join(line[10:] for line in code.splitlines())
        groups = {
            "settings": {"settings100", "settings125", "settings150"},
            "packrecovery": {"packrecovery100", "packrecovery125", "packrecovery150"},
            "packresume172": {"packresume172100", "packresume172125", "packresume172150"},
        }
        selections = {**groups, "all": set().union(*groups.values()),
                      **{case: {case} for cases in groups.values() for case in cases}}
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "outputs"
            for scope, expected in selections.items():
                with self.subTest(scope=scope):
                    output.write_text("")
                    result = subprocess.run([sys.executable, "-c", code], capture_output=True,
                        env={**os.environ, "NGV_ACCEPTANCE_SCOPE": scope, "GITHUB_OUTPUT": str(output)})
                    self.assertEqual(result.returncode, 0, result.stderr.decode())
                    selected = json.loads(output.read_text().removeprefix("matrix="))["include"]
                    self.assertEqual({case["id"] for case in selected}, expected)
                    self.assertEqual(len(selected), len(expected))
                    for case in selected:
                        family = next(name for name, cases in groups.items() if case["id"] in cases)
                        self.assertEqual(case["family"], family)
                        self.assertEqual(case["scale"], {"100": 1, "125": 1.25, "150": 1.5}[case["id"][-3:]])
                        self.assertEqual(case["baseline_version"], "0.5.16" if family == "packresume172" else "0.5.8")
                        self.assertEqual(case["baseline_profile"], "known-preview172-approved-resume"
                                         if family == "packresume172" else "stable-compatible")
            for scope in ("packresume", "packrecovery172100", "packresume172200", "unknown"):
                output.write_text("")
                result = subprocess.run([sys.executable, "-c", code], capture_output=True,
                    env={**os.environ, "NGV_ACCEPTANCE_SCOPE": scope, "GITHUB_OUTPUT": str(output)})
                with self.subTest(invalid=scope):
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(output.read_text(), "")


if __name__ == "__main__":
    unittest.main()
