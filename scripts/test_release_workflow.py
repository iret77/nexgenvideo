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


def named_release_steps(text):
    release = text[text.index("\n  release:\n") + 1 :]
    steps = release[release.index("    steps:\n") + len("    steps:\n") :]
    chunks = re.split(r"(?m)^      - ", steps)[1:]
    result = []
    for chunk in chunks:
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


def condition_enabled(condition, artifact_only, dry_run, resumed=False):
    expression = str(condition or "true").removeprefix("${{").removesuffix("}}").strip()
    values = {
        "inputs.artifact_only": artifact_only,
        "inputs.dry_run": dry_run,
        "env.REL_DRY": str(dry_run).lower(),
        "needs.release-gate.outputs.publication-resumed": str(resumed).lower(),
        "steps.publication-state.outputs.resumed": str(resumed).lower(),
        "needs.release.result": "success",
    }
    expression = re.sub(r"\b(?:inputs|env|needs|steps)\.[\w.-]+",
                        lambda match: repr(values[match.group()]), expression)
    expression = expression.replace("&&", " and ").replace("||", " or ")
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

    def test_artifact_only_keeps_distribution_and_native_gates(self):
        workflow = self.workflow()
        release = workflow["jobs"]["release"]
        self.assertTrue(condition_enabled(release.get("if"), True, True))
        steps = {step.get("name"): step for step in release["steps"]}
        for name in (
            "Build and sign app", "Assemble format packs (.ngvpack + catalog entry)",
            "Notarize and staple downloadable format packs",
            "Load-test — the SIGNED app actually loads the SIGNED pack from an EXTERNAL dir",
            "Notarize app and build signed, notarized DMG", "Verify the exact DMG users install",
            "Record unpublished candidate bytes", "Upload unpublished candidate",
        ):
            self.assertTrue(condition_enabled(steps[name].get("if"), True, True), name)
            self.assertFalse(steps[name].get("continue-on-error", False), name)
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
            self.assertEqual((proof['runID'], proof['runAttempt']), ('77', '2'))

    def test_final_dmg_transfer_rejects_changed_dmg_app_pack_and_source(self):
        shell = next(s['run'] for s in self.workflow()['jobs']['release']['steps']
                     if s.get('name') == 'Transfer the verified installed DMG app for workspace acceptance')
        for mutation in ('dmg', 'app', 'pack', 'pack-zip', 'source', 'mode', 'symlink'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                root, environment = self.release_transfer_fixture(directory)
                paths = {'dmg': root / '.build/NexGenVideo.dmg',
                         'app': root / 'installed/NexGenVideo.app/Contents/MacOS/NexGenVideo',
                         'pack': root / 'installed/plugins/musicvideo.ngvpack/pack',
                         'pack-zip': root / '.build/musicvideo.ngvpack.zip'}
                if mutation == 'source': environment['GITHUB_SHA'] = 'b' * 40
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
            'swift build --cache-path "$NGV_SWIFTPM_CACHE_PATH" -c release '
            '--scratch-path "$RUNNER_TEMP/release-tests" --build-tests -Xswiftc -enable-testing'
        )
        stage = 'scripts/stage_test_runtime.sh release "$RUNNER_TEMP/release-tests"'
        test = (
            'python3 scripts/run_macos_tests.py --cache-path "$NGV_SWIFTPM_CACHE_PATH" \\'
        )
        bundle = "scripts/bundle.sh release --sign"
        pack = 'scripts/assemble_ngvpack.sh plugins/musicvideo.json release .build/plugins "${SIGN_IDENTITY:-}"'

        for name in (build_name, stage_name, test_name, bundle_name, pack_name):
            self.assertEqual(names.count(name), 1)
            self.assertNotRegex(by_name[name], r"(?m)^        if:")
            self.assertNotRegex(by_name[name], r"(?m)^        continue-on-error:")
        self.assertEqual(single_line_run(by_name[build_name]), build)
        self.assertEqual(single_line_run(by_name[stage_name]), stage)
        self.assertEqual(matching_shell_lines(by_name[test_name], "python3 scripts/run_macos_tests.py "), [test])
        self.assertIn('-c release --scratch-path "$RUNNER_TEMP/release-tests" --swiftc-flag=-enable-testing',
                      by_name[test_name])
        self.assertIn('--evidence "$RUNNER_TEMP/release-test-evidence" 2>&1 | tee release-test.log',
                      by_name[test_name])
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

    def test_all_notary_submissions_use_the_retrying_helper(self):
        workflow = WORKFLOW.read_text()
        bundle = BUNDLE.read_text()

        self.assertNotIn("notarytool submit", workflow)
        self.assertNotIn("notarytool submit", bundle)
        self.assertEqual(workflow.count('scripts/notarize.sh "$PACK_ZIP"'), 1)
        self.assertEqual(bundle.count('"$ROOT/scripts/notarize.sh"'), 2)


if __name__ == "__main__":
    unittest.main()
