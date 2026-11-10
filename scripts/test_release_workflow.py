import ast
import copy
import os
import hashlib
import plistlib
import sys
import tarfile
import json
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/release.yml"
BUNDLE = ROOT / "scripts/bundle.sh"
ASSEMBLE_PACK = ROOT / "scripts/assemble_ngvpack.sh"


def reusable_permission_violations(workflows):
    ranks = {"none": 0, "read": 1, "write": 2}
    failures = []
    for caller_name, caller in workflows.items():
        for job_name, job in caller.get("jobs", {}).items():
            target = job.get("uses", "")
            prefix = "./.github/workflows/"
            if not target.startswith(prefix):
                continue
            callee_name = target.removeprefix(prefix)
            callee = workflows[callee_name]
            granted = job.get("permissions", caller.get("permissions", {}))
            requested = [callee.get("permissions", {})]
            requested += [child["permissions"] for child in callee.get("jobs", {}).values() if "permissions" in child]
            scopes = set().union(*(value.keys() for value in requested))
            for scope in sorted(scopes):
                needed = max(ranks[value.get(scope, "none")] for value in requested)
                if ranks[granted.get(scope, "none")] < needed:
                    failures.append((caller_name, job_name, callee_name, scope))
    return failures


def named_release_steps(text):
    result = []
    for name in ("release-build", "release"):
        header = "\n  " + name + ":\n"
        release = text[text.index(header) + len(header) :]
        release = re.split(r"(?m)^  [A-Za-z0-9_-]+:\n", release, maxsplit=1)[0]
        steps = release[release.index("    steps:\n") + len("    steps:\n") :]
        for chunk in re.split(r"(?m)^      - ", steps)[1:]:
            match = re.match(r"name: ([^\n]+)", chunk)
            if match:
                result.append((match.group(1), chunk))
    return result


def single_line_run(step):
    match = re.search(r"(?m)^        run: ([^|][^\n]*)$", step)
    if not match:
        raise AssertionError("expected one active single-line run command")
    return match.group(1)


def matching_shell_lines(step, prefix):
    return [line.strip() for line in step.splitlines() if line.strip().startswith(prefix)]


def condition_enabled(condition, artifact_only, dry_run, resumed=False, *, needs_results=None, ancestry_success=True, compiled_targets="", component_continuation=False):
    expression = str(condition or "true").removeprefix("${{").removesuffix("}}").strip()
    if not ancestry_success and not re.search(r"\b(?:always|cancelled|success|failure)\(\)", expression):
        return False
    values = {
        "inputs.artifact_only": artifact_only,
        "inputs.compiled_app_targets_json": compiled_targets,
        "needs.bpy-source.result": "success",
        "env.NGV_COMPILED_APP_RELEASE": "true" if compiled_targets else "",
        "env.NGV_COMPONENT_NOTARY_CONTINUATION": "true" if component_continuation else "",
        "inputs.dry_run": dry_run,
        "env.REL_DRY": str(dry_run).lower(),
        "needs.release-gate.outputs.publication-resumed": str(resumed).lower(),
        "steps.publication-state.outputs.resumed": str(resumed).lower(),
        "needs.release.result": "success",
        "needs.release-gate.result": "success",
        "needs.release-build.result": "success",
        "needs.diagnostic-acceptance.result": "success",
        "needs.bpy-runtime.result": "success",
        "needs.external-user-acceptance.result": "success",
        "inputs.signed_build_run_id": "",
        "inputs.completed_release_tests_run_id": "",
        "inputs.notary_progress_run_id": "",
        "steps.restore-notary.outputs.dmg_present": "",
    }
    values.update({f"needs.{name}.result": result for name, result in (needs_results or {}).items()})
    expression = re.sub(r"\b(?:inputs|env|needs|steps)\.[\w.-]+",
                        lambda match: repr(values[match.group()]), expression)
    expression = expression.replace("!cancelled()", "true").replace("&&", " and ").replace("||", " or ")
    tree = ast.parse(expression, mode="eval")
    allowed = (ast.Expression, ast.BoolOp, ast.And, ast.Or, ast.Compare, ast.Eq,
               ast.NotEq, ast.Constant, ast.Name, ast.Load)
    if any(not isinstance(node, allowed) for node in ast.walk(tree)):
        raise AssertionError(f"unsupported publication condition: {condition}")
    if any(isinstance(node, ast.Name) and node.id not in ("true", "false")
           for node in ast.walk(tree)):
        raise AssertionError(f"unknown publication condition: {condition}")
    return bool(eval(compile(tree, "<workflow condition>", "eval"),
                     {"__builtins__": {}, "true": True, "false": False}))


def active_publication_steps(workflow, artifact_only, dry_run, resumed=False):
    mutation = re.compile(
        r"\bgh\s+release\s+(?!(?:view|download|list)\b)\w+"
        r"|\bgh\s+(?:pr|repo|workflow|run)\s+(?:create|edit|merge|delete|run|rerun)\b"
        r"|\bgh\s+api\b[\s\S]*?(?:--method|-X)\s+(?:POST|PUT|PATCH|DELETE)\b"
        r"|\bgit\s+(?:push|tag)\b"
        r"|\bscripts/(?:publish_release_metadata\.sh|update_appcast\.py|update_release_metadata\.py)\b"
    )
    active = []
    for job_name, job in workflow["jobs"].items():
        for step in job.get("steps", []):
            if not mutation.search(step.get("run", "")):
                continue
            if (condition_enabled(job.get("if"), artifact_only, dry_run, resumed)
                    and condition_enabled(step.get("if"), artifact_only, dry_run, resumed)):
                active.append((job_name, step.get("name", step["run"])))
    return active


class ReleaseWorkflowTests(unittest.TestCase):
    def test_compiled_source_handoff_routes_only_the_authenticated_singleton_and_binds_both_receivers(self):
        action = (ROOT / '.github/actions/prepare-bpy-source/action.yml').read_text()
        self.assertIn('if [ "${NGV_CURRENT_COMPILED_SOURCE_REUSE:-}" = true ]; then', action)
        self.assertNotIn('if [ "${NGV_COMPILED_APP_RELEASE:-}" = true ]', action)
        tree = ast.parse((ROOT / 'scripts/release_checkpoint.py').read_text())
        restore = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'restore')
        guards = [node for node in ast.walk(restore) if isinstance(node, ast.If)
            and any(isinstance(call, ast.Call) and isinstance(call.func, ast.Name) and call.func.id == 'compiled_signed_product'
                for call in ast.walk(node.test))
            and 'NGV_CURRENT_COMPILED_SOURCE_REUSE=true' in ast.get_source_segment(
                (ROOT / 'scripts/release_checkpoint.py').read_text(), node)]
        self.assertEqual(len(guards), 1)
        self.assertIn('NGV_CURRENT_COMPILED_SOURCE_REUSE=true', ast.get_source_segment(
            (ROOT / 'scripts/release_checkpoint.py').read_text(), guards[0]))
        workflow = yaml.load((ROOT / '.github/workflows/bpy-runtime-acceptance.yml').read_text(), Loader=yaml.BaseLoader)
        steps = {step.get('name'): step for step in workflow['jobs']['runtime']['steps']}
        for name, call in [('Prepare qualified source for the original CI app', 'consume_packaging_source'),
                ('Relocate the exact app and prepare denied resources', 'verify_received_source')]:
            step = steps[name]
            self.assertEqual(step['env']['ORIGINAL_RUN'], '${{ inputs.runtime_run_id || github.run_id }}')
            self.assertIn(call + '(', step['run'])
            self.assertIn("binding.get('selectors') != selected", step['run'])
            self.assertIn("binding.get('producerRunID') != int(os.environ['ORIGINAL_RUN'])", step['run'])

    def test_pack_copy_branches_reuse_only_the_closed_candidate_and_never_fallback_after_failure(self):
        workflow = yaml.safe_load(WORKFLOW.read_text())
        steps = {step.get('name'): step for step in workflow['jobs']['release']['steps']}
        scripts = [steps['Load-test — the SIGNED app actually loads the SIGNED pack from an EXTERNAL dir']['run'],
            steps['Verify the exact DMG users install']['run'], BUNDLE.read_text().split('build_dmg() {', 1)[1].split('notarize_dmg() {', 1)[0]]
        pattern = r'if \[ "\$\{NGV_COMPILED_APP_RELEASE:-\}" = true \]; then\n.*?\n\s*fi'
        for script in scripts:
            blocks = re.findall(pattern, script, re.S)
            self.assertEqual(len(blocks), 1)
            for selected in ('', 'true'):
                for failure in (0, 9):
                    with self.subTest(selected=selected, failure=failure, block=blocks[0]), tempfile.TemporaryDirectory() as temporary:
                        calls = Path(temporary) / 'calls'
                        functions = '''python3() { printf 'bridge:%s\\n' "$#" >> "$CALLS"; return "$BRIDGE_RC"; }
codesign() { printf 'codesign\\n' >> "$CALLS"; return "$NATIVE_RC"; }
xcrun() { printf 'stapler\\n' >> "$CALLS"; return "$NATIVE_RC"; }
'''
                        env = os.environ | {'NGV_COMPILED_APP_RELEASE': selected, 'CALLS': str(calls),
                            'BRIDGE_RC': str(failure), 'NATIVE_RC': str(failure), 'ROOT': '/qualified repo',
                            'PACK_BUNDLE': '/qualified copy/musicvideo.ngvpack', 'DMG_PACK': '/qualified copy/musicvideo.ngvpack',
                            'PACK_ZIP': '/qualified copy/musicvideo.ngvpack.zip'}
                        result = subprocess.run(['bash', '-euo', 'pipefail', '-c', functions + blocks[0]],
                            stdin=subprocess.DEVNULL, capture_output=True, env=env, timeout=10)
                        rows = calls.read_text().splitlines()
                        self.assertEqual(result.returncode, failure, result.stderr.decode())
                        if selected:
                            self.assertEqual(rows, ['bridge:10' if '--dmg' in blocks[0] else 'bridge:8'])
                        elif failure:
                            self.assertEqual(len(rows), 1)
                            self.assertIn(rows[0], ('codesign', 'stapler'))
                        else:
                            self.assertTrue(all(row in ('codesign', 'stapler') for row in rows))

    def test_local_reusable_workflow_permissions_are_granted_by_every_caller(self):
        workflows = {path.name: yaml.safe_load(path.read_text()) for path in (ROOT / ".github/workflows").glob("*.yml")}
        self.assertEqual(reusable_permission_violations(workflows), [])
        changed = copy.deepcopy(workflows)
        changed["release.yml"]["jobs"]["external-user-acceptance"]["permissions"].pop("pull-requests")
        self.assertIn(("release.yml", "external-user-acceptance", "external-gui-acceptance.yml", "pull-requests"),
                      reusable_permission_violations(changed))

    def test_reusable_permission_comparison_obeys_job_override_inheritance_and_scope_strength(self):
        callee = {"permissions": {"contents": "read", "pull-requests": "read"}, "jobs": {"run": {}}}
        caller = {"permissions": {"contents": "write", "pull-requests": "write"},
                  "jobs": {"call": {"uses": "./.github/workflows/callee.yml"}}}
        fixture = {"caller.yml": caller, "callee.yml": callee}
        self.assertEqual(reusable_permission_violations(fixture), [])
        caller["jobs"]["call"]["permissions"] = {"contents": "read"}
        self.assertEqual(reusable_permission_violations(fixture),
                         [("caller.yml", "call", "callee.yml", "pull-requests")])
        caller["jobs"]["call"]["permissions"]["pull-requests"] = "none"
        self.assertEqual(reusable_permission_violations(fixture),
                         [("caller.yml", "call", "callee.yml", "pull-requests")])
        caller["jobs"]["call"]["permissions"]["pull-requests"] = "read"
        self.assertEqual(reusable_permission_violations(fixture), [])
        callee["jobs"]["run"]["permissions"] = {"contents": "write"}
        self.assertEqual(reusable_permission_violations(fixture),
                         [("caller.yml", "call", "callee.yml", "contents")])
        caller["jobs"]["call"]["permissions"]["contents"] = "write"
        self.assertEqual(reusable_permission_violations(fixture), [])

    def workflow(self):
        return yaml.safe_load(WORKFLOW.read_text())

    def test_artifact_only_has_no_active_publication_including_resume(self):
        workflow = self.workflow()
        inputs = workflow[True]["workflow_dispatch"]["inputs"]
        self.assertEqual(inputs["artifact_only"]["type"], "boolean")
        self.assertIs(inputs["artifact_only"]["default"], False)
        for dry_run in (True, False):
            for resumed in (True, False):
                with self.subTest(dry_run=dry_run, resumed=resumed):
                    self.assertEqual(active_publication_steps(workflow, True, dry_run, resumed), [])
        self.assertEqual(active_publication_steps(workflow, False, True), [
            ("release", "Publish isolated preview plugin channel"),
        ])
        self.assertEqual(set(active_publication_steps(workflow, False, False)), {
            ("release-gate", "Inspect or resume release publication"),
            ("release", "Stage stable plugin publication transaction"),
            ("release", "Stage draft GitHub release"),
            ("publish", "Record completed native acceptance for publication recovery"),
            ("publish", "Publish protected release metadata"),
            ("publish", "Promote stable plugin catalog"),
        })

    def test_publication_discovery_catches_new_steps_and_lost_guards(self):
        workflow = self.workflow()
        workflow["jobs"]["release"]["steps"].append({"run": "gh release create unexpected"})
        self.assertTrue(active_publication_steps(workflow, True, True))
        for job_name, step_name, dry_run in (
            ("release", "Publish isolated preview plugin channel", True),
            ("release-gate", "Inspect or resume release publication", False),
        ):
            changed = copy.deepcopy(self.workflow())
            step = next(step for step in changed["jobs"][job_name]["steps"]
                        if step.get("name") == step_name)
            step.pop("if")
            self.assertIn((job_name, step_name), active_publication_steps(changed, True, dry_run))
        changed = copy.deepcopy(self.workflow())
        changed["jobs"]["publish"].pop("if")
        self.assertTrue(active_publication_steps(changed, True, True))

    def test_mode_combinations_use_the_real_input_and_catalog_shell(self):
        workflow = self.workflow()
        validate = next(step["run"] for step in workflow["jobs"]["release-gate"]["steps"]
                        if step.get("name") == "Validate release input")
        resolve = next(step["run"] for step in workflow["jobs"]["release"]["steps"]
                       if step.get("name") == "Resolve version + mode")
        for artifact_only in (False, True, ""):
            for dry_run in (False, True):
                with self.subTest(artifact_only=artifact_only, dry_run=dry_run), tempfile.TemporaryDirectory() as directory:
                    environment = dict(os.environ, REL_VERSION="1.8.0",
                                       ARTIFACT_ONLY=str(artifact_only).lower(),
                                       DRY_RUN=str(dry_run).lower(), GITHUB_ENV=f"{directory}/env")
                    result = subprocess.run(["bash", "-c", validate], env=environment,
                                            capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode == 0, not artifact_only or dry_run)
                    if result.returncode:
                        self.assertIn("artifact_only requires dry_run=true", result.stdout)
                        continue
                    substitutions = {
                        "inputs.version": "1.8.0", "inputs.dry_run": str(dry_run).lower(),
                        "github.run_id": "123", "github.server_url": "https://github.com",
                        "github.repository": "iret77/nexgenvideo",
                    }
                    shell = re.sub(r"\$\{\{\s*([\w.]+)\s*\}\}",
                                   lambda match: substitutions[match.group(1)], resolve)
                    subprocess.run(["bash", "-c", shell], env=environment, check=True,
                                   capture_output=True, text=True, timeout=5)
                    actual = Path(environment["GITHUB_ENV"]).read_text()
                    channel = "preview-123" if dry_run and not artifact_only else "plugins"
                    self.assertIn(f"PLUGIN_CHANNEL_TAG={channel}\n", actual)
                    self.assertIn(f"PLUGIN_CATALOG_URL=https://github.com/iret77/nexgenvideo/releases/download/{channel}/catalog.json\n", actual)
        for selector in ("SIGNED_BUILD_RUN", "NOTARY_PROGRESS_RUN"):
            for artifact_only, dry_run, accepted in ((True, True, True), (False, False, True), (False, True, False)):
                with self.subTest(selector=selector, artifact_only=artifact_only, dry_run=dry_run):
                    environment = dict(os.environ)
                    environment.update(REL_VERSION="1.8.0", ARTIFACT_ONLY=str(artifact_only).lower(),
                                       DRY_RUN=str(dry_run).lower(), RELEASE_TEST_RUN="", SIGNED_BUILD_RUN="",
                                       NOTARY_PROGRESS_RUN="")
                    environment[selector] = "123"
                    result = subprocess.run(["bash", "-c", validate], env=environment,
                                            capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode == 0, accepted, result.stdout + result.stderr)
                    if not accepted:
                        self.assertIn("Preview channels are run-specific", result.stdout)

    def test_artifact_only_keeps_distribution_and_native_gates(self):
        workflow = self.workflow()
        release = workflow["jobs"]["release"]
        self.assertTrue(condition_enabled(release.get("if"), True, True))
        steps = {step.get("name"): step for job in ("release-build", "release")
                 for step in workflow["jobs"][job]["steps"]}
        for name in (
            "Build and sign app", "Assemble format packs (.ngvpack + catalog entry)",
            "Notarize and staple downloadable format packs",
            "Load-test — the SIGNED app actually loads the SIGNED pack from an EXTERNAL dir",
            "Notarize and staple app", "Build and sign DMG", "Notarize and staple DMG",
            "Verify the exact DMG users install",
            "Record unpublished candidate bytes", "Upload unpublished candidate",
        ):
            self.assertTrue(condition_enabled(steps[name].get("if"), True, True), name)
            self.assertFalse(steps[name].get("continue-on-error", False), name)
        reuse = steps["Verify retained signature, shared links and actual external pack load evidence"]
        self.assertFalse(condition_enabled(reuse.get("if"), True, True))
        self.assertTrue(condition_enabled(reuse.get("if"), True, True, component_continuation=True))
        self.assertEqual(reuse["run"], "python3 scripts/compiled_component_reuse.py verify-native")
        self.assertFalse(reuse.get("continue-on-error", False))
        for name in (
            "Verify pack links the SHARED engine (guards the PackEntry-cast regression)",
            "Load-test — the SIGNED app actually loads the SIGNED pack from an EXTERNAL dir",
        ):
            self.assertTrue(condition_enabled(steps[name].get("if"), True, True), name)
            self.assertFalse(condition_enabled(steps[name].get("if"), True, True, component_continuation=True), name)
        for name in ("Notarize and staple app", "Build and sign DMG", "Notarize and staple DMG",
                     "Verify the exact DMG users install"):
            self.assertTrue(condition_enabled(steps[name].get("if"), True, True, component_continuation=True), name)
        upload = steps["Upload unpublished candidate"]["with"]
        for path in (".build/NexGenVideo.dmg", ".build/plugins/*.ngvpack.zip",
                     ".build/plugins/*.entry.json", ".build/artifact-only-candidate.json",
                     ".build/bpy-source/NexGenVideo-bpy-5.2.2-corresponding-source.tar",
                     ".build/bpy-source/NexGenVideo-bpy-5.2.2-corresponding-source.manifest.json"):
            self.assertIn(path, upload["path"].splitlines())
        self.assertEqual(upload["if-no-files-found"], "error")
        for name in ("diagnostic-acceptance", "bpy-runtime", "external-user-acceptance"):
            job = workflow["jobs"][name]
            self.assertEqual(job["needs"], "release")
            self.assertTrue(condition_enabled(job.get("if"), True, True), name)
            self.assertFalse(job.get("continue-on-error", False), name)
        external = workflow["jobs"]["external-user-acceptance"]["with"]
        self.assertEqual(external["artifact_mode"], "dmg")
        self.assertEqual(external["expected_dmg_sha256"], "${{ needs.release.outputs.dmg_sha256 }}")
        self.assertIs(workflow["jobs"]["bpy-runtime"]["with"]["distribution"], True)
        diagnostic = workflow["jobs"]["diagnostic-acceptance"]["steps"]
        by_name = {step.get("name"): step for step in diagnostic}
        for name, command in (
            ("Exercise native Export Cancel, Retry and Reveal actions",
             "python3 scripts/export_actions_acceptance.py NexGenVideo.app --output evidence/export-actions.json"),
            ("Verify asynchronous termination, cancellation and restart",
             'python3 scripts/app_termination_acceptance.py NexGenVideo.app --output evidence/termination --product-source "$PRODUCT_SOURCE"'),
        ):
            self.assertEqual(by_name[name]["run"], command)
            self.assertFalse(by_name[name].get("continue-on-error", False))
        self.assertEqual(by_name["Verify asynchronous termination, cancellation and restart"]["if"], "${{ !cancelled() }}")
        self.assertEqual(by_name["Verify asynchronous termination, cancellation and restart"]["env"]["PRODUCT_SOURCE"],
                         "${{ needs.release.outputs.product_source_sha }}")
        self.assertNotIn("if", by_name["Exercise native Export Cancel, Retry and Reveal actions"])
        pricing = by_name["Verify generation batch pricing recovery"]
        self.assertNotIn("if", pricing)
        for required in ("set -euo pipefail", "NGV_SELFTEST_GENERATION_BATCH_RECOVERY=1",
                         "NexGenVideo.app/Contents/MacOS/NexGenVideo", "grep -qx 'SELFTEST_GENERATION_BATCH_RECOVERY_OK'"):
            self.assertIn(required, pricing["run"])
        self.assertFalse(pricing.get("continue-on-error", False))
        upload = next(step for step in diagnostic if step.get("with", {}).get("name") == "diagnostic-runtime-acceptance")
        self.assertEqual(upload["if"], "always()")
        for path in ("evidence/*.json", "evidence/*.log", "evidence/*.png",
                     "evidence/helper-recovery-recordings.zip", "evidence/termination/"):
            self.assertIn(path, upload["with"]["path"].splitlines())
        inputs = workflow[True]["workflow_dispatch"]["inputs"]
        self.assertEqual(inputs["verified_pr_run_id"]["type"], "string")
        self.assertEqual(inputs["verified_pr_run_id"]["default"], "")
        gates = {step.get("name"): step for step in workflow["jobs"]["release-gate"]["steps"]}
        binding = gates["Bind exact PR source checks"]
        self.assertEqual(binding["if"], "inputs.verified_pr_run_id != ''")
        self.assertFalse(binding.get("continue-on-error", False))
        self.assertIn('scripts/verified_pr_source_checks.py prepare --run-id "$VERIFIED_PR_RUN"', binding["run"])
        self.assertEqual(binding["env"]["VERIFIED_PR_RUN"], "${{ inputs.verified_pr_run_id }}")
        for name in ("Enforce AppTheme", "Verify private fixture bundle tooling"):
            self.assertEqual(gates[name]["if"], "inputs.verified_pr_run_id == ''")
        preflight_condition = gates["Release source preflight"]["if"]
        self.assertEqual(preflight_condition, "${{ steps.publication-state.outputs.resumed != 'true' }}")
        self.assertNotIn("verified_pr_run_id", preflight_condition)
        for artifact_only, dry_run in ((True, True), (False, False)):
            self.assertTrue(condition_enabled(preflight_condition, artifact_only, dry_run, False))
        for name in ("chat-hang-replay", "musicvideo-analysis-acceptance"):
            job = workflow["jobs"][name]
            self.assertEqual(job["needs"], ["release", "diagnostic-acceptance", "bpy-runtime"])
            self.assertTrue(condition_enabled(job.get("if"), True, True))
            self.assertFalse(condition_enabled(job.get("if"), False, False))
            self.assertEqual(job["with"]["runtime_artifact"], "workspace-ui-app")
        private = workflow["jobs"]["musicvideo-analysis-acceptance"]
        self.assertEqual(private["permissions"]["pull-requests"], "read")
        self.assertEqual(private["with"]["verified_pr_run_id"], "${{ inputs.verified_pr_run_id }}")
        self.assertEqual(private["secrets"], {"NGV_GHCR_TOKEN": "${{ secrets.NGV_GHCR_TOKEN }}"})
        analysis = yaml.safe_load((ROOT / ".github/workflows/private-example-analysis.yml").read_text())
        self.assertEqual(analysis["permissions"]["actions"], "read")
        self.assertEqual(analysis["permissions"]["pull-requests"], "read")
        private_gates = {step.get("name"): step for step in analysis["jobs"]["source-gate"]["steps"]}
        self.assertEqual(private_gates["Bind exact PR source checks"]["if"], "inputs.verified_pr_run_id != ''")
        self.assertIn('scripts/verified_pr_source_checks.py prepare --run-id "$VERIFIED_PR_RUN"',
                      private_gates["Bind exact PR source checks"]["run"])
        self.assertFalse(private_gates["Bind exact PR source checks"].get("continue-on-error", False))
        self.assertEqual(private_gates["Verify fixture bundle tooling"]["if"], "inputs.verified_pr_run_id == ''")

    def release_transfer_fixture(self, directory):
        root = Path(directory)
        (root / 'scripts').symlink_to(ROOT / 'scripts', target_is_directory=True)
        install = root / 'installed'
        app = install / 'NexGenVideo.app'
        executable = app / 'Contents/MacOS/NexGenVideo'
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b'installed-final-app')
        executable.chmod(0o755)
        info = {'CFBundleIdentifier': 'de.h5ventures.nexgenvideo', 'CFBundleExecutable': 'NexGenVideo',
                'CFBundleShortVersionString': '1.8.0', 'CFBundleVersion': '123',
                'NGVSourceCommit': 'a' * 40, 'LSMinimumSystemVersion': '26.0'}
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        (app / 'Contents/Current').symlink_to('MacOS')
        staged_pack = install / 'plugins/musicvideo.ngvpack'
        staged_pack.mkdir(parents=True)
        (staged_pack / 'pack').write_bytes(b'final-notarized-pack')
        original_pack = root / 'checked-pack/musicvideo.ngvpack'
        original_pack.mkdir(parents=True)
        (original_pack / 'pack').write_bytes(b'final-notarized-pack')
        build = root / '.build'
        (build / 'bpy-source').mkdir(parents=True)
        (build / 'bpy-source/bpy-source-receipt.json').write_text('{"sourceSHA":"' + 'a' * 40 + '"}')
        (build / 'NexGenVideo.dmg').write_bytes(b'exact-final-dmg')
        (build / 'musicvideo.ngvpack.zip').write_bytes(b'exact-final-pack-zip')
        stale = build / 'NexGenVideo.app/Contents/MacOS/NexGenVideo'
        stale.parent.mkdir(parents=True)
        stale.write_bytes(b'wrong-earlier-build')
        def tree(path):
            return subprocess.check_output([sys.executable, str(ROOT / 'scripts/external-gui/acceptance.py'),
                                            'tree-sha256', '--app', str(path)], text=True).strip()
        environment = dict(os.environ, RUNNER_TEMP=str(root / 'runner-temp'), GITHUB_SHA='a' * 40,
                           GITHUB_RUN_ID='77', GITHUB_RUN_ATTEMPT='2',
                           NGV_RELEASE_INSTALL_CHECK=str(install),
                           NGV_RELEASE_DMG_SHA256=hashlib.sha256((build / 'NexGenVideo.dmg').read_bytes()).hexdigest(),
                           NGV_RELEASE_MOUNTED_APP_TREE_SHA256=tree(app),
                           NGV_RELEASE_PACK_BUNDLE=str(original_pack),
                           NGV_RELEASE_PACK_TREE_SHA256=tree(original_pack),
                           NGV_RELEASE_MOUNTED_PACK_TREE_SHA256=tree(original_pack),
                           NGV_RELEASE_PACK_ZIP=str(build / 'musicvideo.ngvpack.zip'),
                           NGV_RELEASE_PACK_ZIP_SHA256=hashlib.sha256((build / 'musicvideo.ngvpack.zip').read_bytes()).hexdigest())
        return root, environment

    def test_final_dmg_workspace_transfer_keeps_the_installed_bytes_and_existing_format(self):
        workflow = self.workflow()
        steps = workflow['jobs']['release']['steps']
        by_name = {s.get('name'): s for s in steps}
        name = 'Transfer the verified installed DMG app for workspace acceptance'
        shell = by_name[name]['run']
        self.assertFalse(by_name[name].get('continue-on-error', False))
        self.assertTrue(condition_enabled(by_name[name].get('if'), True, True))
        self.assertLess(steps.index(by_name['Verify the exact DMG users install']), steps.index(by_name[name]))
        self.assertLess(steps.index(by_name[name]), steps.index(by_name['Bind the exact DMG for the external user journey']))
        self.assertNotRegex(shell, r'swift build|bundle\.sh|sign_app\.sh|notarytool')
        installed_checks = by_name['Verify the exact DMG users install']['run']
        self.assertLess(installed_checks.index('NGV_RELEASE_MOUNTED_APP_TREE_SHA256='),
                        installed_checks.index('ditto "$MOUNT_POINT/NexGenVideo.app" "$INSTALL_APP"'))
        self.assertLess(installed_checks.index('bash scripts/relaunch_selftest.sh'),
                        installed_checks.index('echo "NGV_RELEASE_INSTALL_CHECK='))
        pack_pin = installed_checks.index('NGV_RELEASE_PACK_TREE_SHA256=')
        self.assertLess(installed_checks.index('/usr/bin/ditto -x -k "$PACK_ZIP" "$PACK_EXTRACT"'), pack_pin)
        self.assertLess(pack_pin, installed_checks.index('/usr/bin/xattr -r -w'))
        self.assertLess(installed_checks.index('NGV_RELEASE_PACK_ZIP_SHA256='),
                        installed_checks.index('/usr/bin/ditto -x -k "$PACK_ZIP" "$PACK_EXTRACT"'))
        self.assertEqual(installed_checks.count('NGV_RELEASE_PACK_TREE_SHA256='), 2)
        self.assertLess(installed_checks.index('ditto "$MOUNT_POINT/musicvideo.ngvpack"'), installed_checks.index('cleanup_mount\n'))
        self.assertIn('PACK_BUNDLE="$INSTALL_CHECK/plugins/musicvideo.ngvpack"', installed_checks)
        self.assertIn('"$PACK_ZIP_BUNDLE")" = "$NGV_RELEASE_MOUNTED_PACK_TREE_SHA256"', installed_checks)
        upload = by_name['Upload final DMG app for selected workspace acceptance']['with']
        self.assertEqual(upload['name'], 'workspace-ui-app')
        self.assertEqual({Path(n).name for n in upload['path'].splitlines()},
                         {'workspace-ui.tar.gz', 'workspace-ui-input.json', 'bpy-source-receipt.json'})
        self.assertEqual(upload['if-no-files-found'], 'error')
        with tempfile.TemporaryDirectory() as directory:
            root, environment = self.release_transfer_fixture(directory)
            subprocess.run(['bash', '-c', shell], cwd=root, env=environment, check=True,
                           capture_output=True, text=True, timeout=15)
            transfer = root / 'runner-temp/release-workspace-transfer'
            self.assertEqual({p.name for p in transfer.iterdir()},
                             {'workspace-ui.tar.gz', 'workspace-ui-input.json', 'bpy-source-receipt.json'})
            receipt = json.loads((transfer / 'workspace-ui-input.json').read_text())
            self.assertEqual(set(receipt), {'schema', 'sourceSHA', 'archiveSHA256', 'appTreeSHA256'})
            self.assertEqual(receipt['schema'], 'nexgenvideo/workspace-ui-input/1')
            self.assertEqual(receipt['sourceSHA'], 'a' * 40)
            self.assertEqual(receipt['archiveSHA256'], hashlib.sha256((transfer / 'workspace-ui.tar.gz').read_bytes()).hexdigest())
            self.assertEqual(receipt['appTreeSHA256'], environment['NGV_RELEASE_MOUNTED_APP_TREE_SHA256'])
            with tarfile.open(transfer / 'workspace-ui.tar.gz') as archive:
                self.assertEqual(archive.extractfile('NexGenVideo.app/Contents/MacOS/NexGenVideo').read(), b'installed-final-app')
                self.assertEqual(archive.getmember('NexGenVideo.app/Contents/MacOS/NexGenVideo').mode & 0o777, 0o755)
                self.assertTrue(archive.getmember('NexGenVideo.app/Contents/Current').issym())
                self.assertEqual(archive.extractfile('plugins/musicvideo.ngvpack/pack').read(), b'final-notarized-pack')
            proof = json.loads((root / '.build/release-workspace-producer.json').read_text())
            self.assertEqual(proof['dmgSHA256'], environment['NGV_RELEASE_DMG_SHA256'])
            self.assertEqual(proof['app']['treeSHA256'], receipt['appTreeSHA256'])
            self.assertEqual(proof['archiveSHA256'], receipt['archiveSHA256'])
            self.assertEqual(proof['runtimeInputSHA256'], hashlib.sha256((transfer / 'workspace-ui-input.json').read_bytes()).hexdigest())
            self.assertEqual(proof['bpySourceReceiptSHA256'], hashlib.sha256((transfer / 'bpy-source-receipt.json').read_bytes()).hexdigest())
            self.assertEqual(proof['packArchiveSHA256'], environment['NGV_RELEASE_PACK_ZIP_SHA256'])
            self.assertEqual(proof['packTreeSHA256'], environment['NGV_RELEASE_PACK_TREE_SHA256'])
            self.assertEqual(proof['mountedPackTreeSHA256'], environment['NGV_RELEASE_MOUNTED_PACK_TREE_SHA256'])
            self.assertEqual(proof['packOrigin'], 'mounted-dmg')
            self.assertEqual((proof['runID'], proof['runAttempt']), ('77', '2'))

    def test_final_dmg_transfer_rejects_changed_dmg_app_pack_and_source(self):
        shell = next(s['run'] for s in self.workflow()['jobs']['release']['steps']
                     if s.get('name') == 'Transfer the verified installed DMG app for workspace acceptance')
        for mutation in ('dmg', 'app', 'pack', 'pack-zip', 'mounted-pack', 'source', 'mode', 'symlink'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                root, environment = self.release_transfer_fixture(directory)
                paths = {'dmg': root / '.build/NexGenVideo.dmg',
                         'app': root / 'installed/NexGenVideo.app/Contents/MacOS/NexGenVideo',
                         'pack': root / 'installed/plugins/musicvideo.ngvpack/pack',
                         'pack-zip': root / '.build/musicvideo.ngvpack.zip'}
                if mutation == 'source': environment['GITHUB_SHA'] = 'b' * 40
                elif mutation == 'mounted-pack': environment['NGV_RELEASE_MOUNTED_PACK_TREE_SHA256'] = '0' * 64
                elif mutation == 'mode': paths['app'].chmod(0o700)
                elif mutation == 'symlink':
                    link = root / 'installed/NexGenVideo.app/Contents/Current'
                    link.unlink()
                    link.symlink_to('Info.plist')
                else: paths[mutation].write_bytes(paths[mutation].read_bytes() + b'changed')
                result = subprocess.run(['bash', '-c', shell], cwd=root, env=environment,
                                        capture_output=True, text=True, timeout=15)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((root / '.build/release-workspace-producer.json').exists())

    def test_unpublished_candidate_keeps_the_transferred_dmg_identity(self):
        steps = {s.get('name'): s for s in self.workflow()['jobs']['release']['steps']}
        transfer = steps['Transfer the verified installed DMG app for workspace acceptance']['run']
        record = steps['Record unpublished candidate bytes']['run']
        script = record.split("python3 - <<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
        for changed in (False, True):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as directory:
                root, environment = self.release_transfer_fixture(directory)
                subprocess.run(['bash', '-c', transfer], cwd=root, env=environment, check=True,
                               capture_output=True, text=True, timeout=15)
                build = root / '.build'
                plugins = build / 'plugins'
                plugins.mkdir()
                archive = plugins / 'musicvideo.ngvpack.zip'
                archive.write_bytes((build / 'musicvideo.ngvpack.zip').read_bytes())
                (plugins / 'musicvideo.entry.json').write_text(json.dumps({
                    'zip': archive.name, 'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
                }))
                for name in ('NexGenVideo-bpy-5.2.2-corresponding-source.tar',
                             'NexGenVideo-bpy-5.2.2-corresponding-source.manifest.json'):
                    (build / 'bpy-source' / name).write_bytes(b'candidate-input')
                environment.update(REL_VERSION='1.8.0', BUILD_NUMBER='123',
                                   PLUGIN_CATALOG_URL='https://example.test/catalog.json')
                if changed:
                    (build / 'NexGenVideo.dmg').write_bytes(b'changed-after-transfer')
                result = subprocess.run([sys.executable, '-c', script], cwd=root, env=environment,
                                        capture_output=True, text=True, timeout=15)
                candidate = build / 'artifact-only-candidate.json'
                self.assertEqual(result.returncode == 0, not changed)
                self.assertEqual(candidate.exists(), not changed)
                if changed:
                    self.assertIn('candidate DMG differs from the checked workspace producer', result.stderr)

    def test_staged_release_tests_share_the_testable_build_configuration(self):
        text = WORKFLOW.read_text()
        steps = named_release_steps(text)
        names = [name for name, _ in steps]
        by_name = dict(steps)

        build_name = "Build the exact release test configuration"
        stage_name = "Stage release test runtime inputs"
        test_name = "Test the exact release configuration"
        bundle_name = "Build and sign app"
        pack_name = "Assemble format packs (.ngvpack + catalog entry)"
        build = (
            'swift build --jobs 1 --cache-path "$NGV_SWIFTPM_CACHE_PATH" -c release '
            '--scratch-path "$RUNNER_TEMP/release-tests" --build-tests -Xswiftc -enable-testing'
        )
        stage = 'scripts/stage_test_runtime.sh release "$RUNNER_TEMP/release-tests"'
        test = (
            'TEST_COMMAND=(python3 scripts/run_macos_tests.py --cache-path "$NGV_SWIFTPM_CACHE_PATH" \\'
        )
        bundle = "scripts/bundle.sh release --sign"
        pack = 'scripts/assemble_ngvpack.sh plugins/musicvideo.json release .build/plugins "${SIGN_IDENTITY:-}"'

        for name in (build_name, stage_name, test_name, bundle_name, pack_name):
            self.assertEqual(names.count(name), 1)
            if name in (build_name, stage_name, test_name):
                self.assertIn("        if: inputs.completed_release_tests_run_id == '' && inputs.compiled_app_targets_json == ''", by_name[name])
            else:
                self.assertEqual(re.findall(r"(?m)^        if: (.+)$", by_name[name]), ["inputs.compiled_app_targets_json == ''"])
            self.assertNotRegex(by_name[name], r"(?m)^        continue-on-error:")
        self.assertEqual(single_line_run(by_name[build_name]), build)
        self.assertEqual(single_line_run(by_name[stage_name]), stage)
        self.assertEqual(matching_shell_lines(by_name[test_name], "TEST_COMMAND=(python3 scripts/run_macos_tests.py "), [test])
        self.assertIn('-c release --scratch-path "$RUNNER_TEMP/release-tests" --swiftc-flag=-enable-testing',
                      by_name[test_name])
        self.assertIn('--evidence "$RUNNER_TEMP/release-test-evidence")',
                      by_name[test_name])
        self.assertIn('"${TEST_COMMAND[@]}" 2>&1 | tee release-test.log', by_name[test_name])
        self.assertIn('scripts/verify_swift_test_output.py --log release-test.log --swift-testing-runs 2 --xctest-runs 2',
                      by_name[test_name])
        self.assertIn('name: release-test-evidence', by_name['Upload release test evidence'])
        self.assertEqual(matching_shell_lines(by_name[bundle_name], "scripts/bundle.sh "), [bundle])
        bundle_verification = "scripts/verify_bpy_bundle.sh .build/NexGenVideo.app --distribution"
        self.assertEqual(
            matching_shell_lines(by_name[bundle_name], "scripts/verify_bpy_bundle.sh "),
            [bundle_verification],
        )
        self.assertLess(by_name[bundle_name].index(bundle), by_name[bundle_name].index(bundle_verification))
        self.assertEqual(
            matching_shell_lines(by_name[pack_name], "scripts/assemble_ngvpack.sh "),
            [pack],
        )
        self.assertLess(names.index(build_name), names.index(stage_name))
        self.assertLess(names.index(stage_name), names.index(test_name))
        self.assertLess(names.index(test_name), names.index(bundle_name))
        self.assertLess(names.index(bundle_name), names.index(pack_name))
        self.assertNotIn("-enable-testing", BUNDLE.read_text())
        self.assertNotIn("--scratch-path", BUNDLE.read_text())
        self.assertNotIn("-enable-testing", ASSEMBLE_PACK.read_text())
        self.assertNotIn("--scratch-path", ASSEMBLE_PACK.read_text())
        self.assertNotIn("$RUNNER_TEMP", by_name[pack_name])

        compile_block = BUNDLE.read_text().split('echo "==> Building ($CONFIG)"', 1)[1].split('BIN_DIRECTORY=', 1)[0]
        for config in ("release", "debug"):
            with self.subTest(config=config), tempfile.TemporaryDirectory() as directory:
                capture = Path(directory) / "arguments"
                shell = 'set -euo pipefail\nswift() { printf \'%s\\0\' "$@" > "$NGV_TEST_BUILD_ARGUMENTS"; }\n' + compile_block
                environment = {**os.environ, "CONFIG": config, "NGV_SWIFTPM_CACHE_PATH": "/exact/cache",
                               "NGV_TEST_BUILD_ARGUMENTS": str(capture)}
                subprocess.run(["bash", "-c", shell], env=environment, check=True, capture_output=True, timeout=10)
                arguments = [item.decode() for item in capture.read_bytes().split(b"\0")[:-1]]
                expected = ["build", "--cache-path", "/exact/cache"]
                if config == "release": expected += ["--jobs", "1"]
                self.assertEqual(arguments, expected + ["-c", config])

    def test_native_products_survive_staging_and_execution_failures(self):
        steps = self.workflow()['jobs']['release-build']['steps']
        names = [step.get('name') for step in steps]
        by_name = {step.get('name'): step for step in steps}
        ordered = ['Record native test product paths before compilation',
                   'Build the exact release test configuration',
                   'Checkpoint successful native compiler products before staging',
                   'Upload native compiler products before staging',
                   'Confirm compiler product upload before staging',
                   'Stage release test runtime inputs',
                   'Retain staged runtime products before native tests',
                   'Upload staged runtime products before native tests',
                   'Test the exact release configuration']
        self.assertEqual(sorted(ordered, key=names.index), ordered)
        for name in ordered:
            self.assertEqual(names.count(name), 1)
            self.assertNotIn('continue-on-error', by_name[name])
            self.assertEqual(by_name[name]['if'], "inputs.completed_release_tests_run_id == '' && inputs.compiled_app_targets_json == ''")
        confirm = by_name['Confirm compiler product upload before staging']
        self.assertEqual(confirm['env']['GH_TOKEN'], '${{ github.token }}')
        self.assertEqual(confirm['env']['CHECKPOINT_ID'], '${{ steps.native_compiler_products.outputs.artifact-id }}')
        self.assertEqual(confirm['env']['CHECKPOINT_DIGEST'], '${{ steps.native_compiler_products.outputs.artifact-digest }}')
        metadata = by_name['Preserve native checkpoint records after success or failure']
        self.assertEqual(metadata['if'], "always() && inputs.completed_release_tests_run_id == '' && inputs.compiled_app_targets_json == ''")
        self.assertNotIn('NGV_RELEASE_TEST_PRODUCTS_ROOT', metadata['with']['path'])
        self.assertIn('*.json', metadata['with']['path'])
        partial = by_name['Preserve every available native product after failure']
        self.assertEqual(partial['if'], "always() && (failure() || cancelled()) && inputs.completed_release_tests_run_id == '' && inputs.compiled_app_targets_json == '' && env.NGV_RELEASE_TEST_PRODUCTS_ROOT != ''")
        self.assertEqual(partial['with']['path'], '${{ env.NGV_RELEASE_TEST_PRODUCTS_ROOT }}/')
        self.assertTrue(partial['with']['include-hidden-files'])
        for name in ('Upload native compiler products before staging', 'Upload staged runtime products before native tests'):
            self.assertEqual(by_name[name]['with']['if-no-files-found'], 'error')
            self.assertTrue(by_name[name]['with']['include-hidden-files'])
        runtime = by_name['Upload staged runtime products before native tests']['with']['path']
        self.assertIn('runtime-*', runtime)
        self.assertNotIn('compiler-products.zip', runtime)
        self.assertIn('--serialize-app-tests', by_name['Test the exact release configuration']['run'])

    def test_compiled_products_skip_legacy_compilers_but_require_full_new_app_tests_and_pack_verification(self):
        workflow = self.workflow()
        jobs = workflow['jobs']
        steps = {step.get('name'): step for step in jobs['release-build']['steps']}
        legacy = ('Build the exact release test configuration', 'Stage release test runtime inputs',
                  'Test the exact release configuration', 'Build and sign app',
                  'Assemble format packs (.ngvpack + catalog entry)', 'Record signed build before notarization')
        compiled = ('Restore the exact new App compiler products', 'Verify the complete new App and XCTest scope',
                    'Assemble and sign the new App with unchanged retained components',
                    'Record compiled App signed input without invoking a build')
        for selected in ('', 'exact-reviewed-products'):
            with self.subTest(selected=selected):
                for name in legacy:
                    self.assertEqual(condition_enabled(steps[name]['if'], True, True, compiled_targets=selected), not bool(selected))
                for name in compiled:
                    self.assertEqual(condition_enabled(steps[name]['if'], True, True, compiled_targets=selected), bool(selected))
                self.assertEqual(condition_enabled(jobs['bpy-source']['if'], True, True, compiled_targets=selected), not bool(selected))
                if selected:
                    self.assertTrue(condition_enabled(jobs['release-build']['if'], True, True,
                        needs_results={'bpy-source': 'skipped'}, ancestry_success=False, compiled_targets=selected))
        names = [step.get('name') for step in jobs['release-build']['steps']]
        self.assertLess(names.index(compiled[1]), names.index(compiled[2]))
        self.assertNotIn('continue-on-error', steps[compiled[1]])
        retention = steps['Record all available compiled App assembly outputs without qualifying partial products']
        self.assertEqual(retention['if'], "always() && inputs.compiled_app_targets_json != ''")
        self.assertLess(names.index(compiled[3]), names.index(retention['name']))
        signing_upload = steps['Preserve original signing inputs and the complete new App assembly receipt']
        self.assertIn('${{ runner.temp }}/release-signed-input/', signing_upload['with']['path'])
        for name in ('Preserve original signing inputs and the complete new App assembly receipt',
                'Preserve all original compiled inputs and native execution evidence'):
            upload = steps[name]
            self.assertEqual(upload['if'], "always() && inputs.compiled_app_targets_json != ''")
            self.assertIn('${{ runner.temp }}/compiled-app-release/retained-current-xctest/', upload['with']['path'])
            self.assertTrue(upload['with']['include-hidden-files'])
        partial = steps['Preserve complete new App and symbols plus every partial signed archive after failure']
        self.assertEqual(partial['if'], "always() && (failure() || cancelled()) && inputs.compiled_app_targets_json != ''")
        for path in ('unqualified-app-products.tar', 'assembly-retention.json', 'release-signed-input/',
                '.build/NexGenVideo.app/', '.build/NexGenVideo.dSYM/'):
            self.assertIn(path, partial['with']['path'])
        self.assertTrue(partial['with']['include-hidden-files'])
        pack_steps = {step.get('name'): step for step in jobs['release']['steps']}
        self.assertTrue(condition_enabled(pack_steps['Verify the exact retained stapled format pack']['if'],
            True, True, compiled_targets='exact-reviewed-products'))
        self.assertFalse(condition_enabled(pack_steps['Notarize and staple downloadable format packs']['if'],
            True, True, compiled_targets='exact-reviewed-products'))
        self.assertIn('NGV_SELFTEST_PACK=', pack_steps['Load-test — the SIGNED app actually loads the SIGNED pack from an EXTERNAL dir']['run'])

    def test_engine_resume_preserves_fresh_app_commands_and_failure_propagation(self):
        workflow = self.workflow()
        steps = {step.get("name"): step for step in workflow["jobs"]["release-build"]["steps"]}
        shell = steps["Test the exact release configuration"]["run"]
        for retained, status in ((None, 0), ("", 0), ("41830485668", 0), ("41830485668", 7)):
            with self.subTest(retained=retained, status=status), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                shim = root / "python3"
                shim.write_text("#!" + sys.executable + "\nimport json, os, sys\n"
                                "with open(os.environ['ARG_LOG'], 'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\n"
                                "sys.exit(int(os.environ['TEST_STATUS']) if sys.argv[1].endswith('run_macos_tests.py') else 0)\n")
                shim.chmod(0o755)
                environment = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                                   ARG_LOG=str(root / "args.jsonl"), TEST_STATUS=str(status),
                                   RELEASE_ENGINE_RUN=retained or "", RUNNER_TEMP=str(root / "runtime with spaces"),
                                   NGV_SWIFTPM_CACHE_PATH="dependency cache with spaces")
                if retained is None:
                    environment.pop("RELEASE_ENGINE_RUN", None)
                result = subprocess.run(["bash", "-c", shell], env=environment, cwd=root,
                                        capture_output=True, text=True, timeout=10)
                calls = [json.loads(line) for line in (root / "args.jsonl").read_text().splitlines()]
                expected = ["scripts/run_macos_tests.py", "--cache-path", environment["NGV_SWIFTPM_CACHE_PATH"],
                            "-c", "release", "--scratch-path", environment["RUNNER_TEMP"] + "/release-tests",
                            "--swiftc-flag=-enable-testing", "--serialize-app-tests", "--evidence",
                            environment["RUNNER_TEMP"] + "/release-test-evidence"]
                if retained:
                    expected += ["--retained-release-engine", environment["RUNNER_TEMP"] + "/release-engine"]
                self.assertEqual(calls[0], expected)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertEqual(len(calls), 1 if status else 2)
                if not status:
                    self.assertEqual(calls[1], ["scripts/verify_swift_test_output.py", "--log", "release-test.log",
                                               "--swift-testing-runs", "2", "--xctest-runs", "2"])

        gate = {step.get("name"): step for step in workflow["jobs"]["release-gate"]["steps"]}
        for changes in ({}, {"ARTIFACT_ONLY": "false"}, {"DRY_RUN": "false"},
                        {"RELEASE_TEST_RUN": "123"}, {"SIGNED_BUILD_RUN": "123"}, {"NOTARY_PROGRESS_RUN": "123"}):
            with self.subTest(changes=changes):
                environment = dict(os.environ, REL_VERSION="1.8.0", ARTIFACT_ONLY="true", DRY_RUN="true",
                                   RELEASE_ENGINE_RUN="41830485668", RELEASE_TEST_RUN="", SIGNED_BUILD_RUN="",
                                   NOTARY_PROGRESS_RUN="")
                environment.update(changes)
                result = subprocess.run(["bash", "-c", gate["Validate release input"]["run"]],
                                        env=environment, capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode == 0, not changes, result.stdout + result.stderr)

    def test_all_notary_submissions_use_the_retrying_helper(self):
        workflow = WORKFLOW.read_text()
        bundle = BUNDLE.read_text()

        self.assertNotIn("notarytool submit", workflow)
        self.assertNotIn("notarytool submit", bundle)
        self.assertEqual(workflow.count('scripts/notarize.sh "$PACK_ZIP"'), 1)
        self.assertEqual(bundle.count('"$ROOT/scripts/notarize.sh"'), 2)


if __name__ == "__main__":
    unittest.main()
