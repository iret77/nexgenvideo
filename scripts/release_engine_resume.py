"""Retain the completed Engine backend from the pinned failed Release test run."""
import argparse
import ast
import copy
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import zipfile

from retained_app_test_products import api, archive_bytes, checksum, download, require, verify_artifact, write
from verify_swift_test_output import ANSI, assess_output


RUN = 41830485668
JOB = 126577339321
SOURCE = "abb97672b1699af433673582545859c2b292bffb"
ARTIFACT = 13324133993
DIGEST = "7a000e82a53debe556234c1fc8364434b13f1284a4cca70ae62793e40e826d77"
LOG_DIGEST = "0f634eddc6ed44ed1afb4b7ad0be28e0f5e130d90f885a2c8bdd5ed6841f928f"
PHASE_DIGEST = "c8580031c5cfe3844f2169d03bf947847c34f1099c9a09cf2fe4f40b301925d9"
EVENT_DIGEST = "2f872313ee84af000898df20f29be6a62154c87524cce06d8059a089d27206ed"
CONSOLE_DIGEST = "a97b3156108f080b112d3ce9019985bceebed8d2a16bf7e81024b77fff9f9ac9"
NAME = "engine-swift-testing"
FIXTURE = "Tests/NexGenVideoTests/UI/NativeSegmentInteractionTests.swift"
BUTTON_FIXTURE = "Tests/NexGenVideoTests/UI/NativeButtonInteractionTests.swift"
BUTTON_TEST_METHODS = {
    "aSecondOwnCGWindowAtTheSameFramePreventsWindowBinding", "actualDisabledSwiftUIButtonIsExcluded",
    "actualDuplicateButtonsCannotBecomeAUniqueTarget", "actualSwiftUIButtonIsDiscoveredWithoutAnExternalReader",
    "actualTraversalBudgetCannotQualifyAPartialTree", "anUnreadableSecondButtonCannotMakeTheFirstButtonUnique",
    "anUnreadableSecondWindowCannotMakeTheFirstWindowUnique", "cancellationDuringTheLastChildMessageCannotQualifyATree",
    "cancellationIsRetainedAsAnIncompleteQuery", "failedGeometryOrPIDAttributesCannotSupplyAFrame",
    "incompleteAndAmbiguousWindowEvidenceCannotSelectAButton", "nonfiniteEmptyAndOutOfProbeFramesAreRejected",
    "ownProcessBoundaryRejectsForeignRequests", "realDecorationTolerancePreservesTheActualProbeCenter",
    "roleLabelAndEnabledStateAreIndependentRequirements", "theLastChildMessageUsesItsOwnRemainingTimeout",
    "unknownCGMetadataCannotHideACompetingOwnWindow",
}
ORIGINAL_BUTTON_TEST_METHODS = frozenset(BUTTON_TEST_METHODS)
BUTTON_TEST_METHODS |= {
    "actualReaderExportBindsTheLoadedAppCodeImage", "actualPreparedReaderProvesItsOwnParentImageAndTrust",
    "missingAmbiguousAndUnreadableContentRootsRemainUnqualified", "actualWindowFrameCannotSubstituteForTheContentRoot",
    "completedReplyCannotSurviveDeliveryCancellation", "trailingPartialDuplicateAndFailedPeerOutputCannotBecomeCleanEOF",
    "nestedPeerFieldsCannotBeSilentlyIgnored",
    "malformedOrAmbiguousWindowAttributeListsAreRejected", "chromeSupportNeverInventsAnUnadvertisedSlot",
    "failedWindowAttributeAuthorityCannotQualifyContent", "actualWindowAttributeInventoryIsBoundToTheCompleteContent",
}
APP_READER = "Sources/NexGenVideo/App/NativeAXPeer.swift"
APP_HOST = "Tests/AppKitTestHost"
APP_HOST_FILE = APP_HOST + "/AppKitTestHost.swift"
APP_HOST_BLOB = "ee3f621d4d33243ad39268ef64f939797f17b929"
APP_HOST_TREE = "04baf7ac5e107a119133859694b2b176291ac8f9"
APP_HOST_NORMAL_SHA256 = "38f4cf2870cc763af6ac20778c0be1243f09f8a59654050dfff4155f5ae3f151"
APP_HOST_BRANCH_SHA256 = "569026d1fee3b5ce57095e06624155dba60540f28ee0304df9ed3ad4df29bf83"
APP_HOST_ROLE = {
    "schema": "app-only-reader-host-role/v1", "hostTree": APP_HOST_TREE, "hostBlob": APP_HOST_BLOB,
    "normalHostSHA256": APP_HOST_NORMAL_SHA256, "earlyReaderSHA256": APP_HOST_BRANCH_SHA256,
    "enginePhaseSHA256": PHASE_DIGEST, "engineTestProduct": "NexGenEngineTests",
}
# Retain the exact App inventories from candidate N artifact 13429616466.
APP_BASELINE_INVENTORY_HASHES = {
    "discoveredFunctionIDs": "6df708800b56cfd5a024ea069ce6c8699c8fba023a0d2a628726de6c83899cc9",
    "startedFunctionIDs": "a04165ed3fdd3eebe321250903e5a3c758b3f5faca762b9a638684d5bd50f154",
    "endedFunctionIDs": "a04165ed3fdd3eebe321250903e5a3c758b3f5faca762b9a638684d5bd50f154",
    "skippedFunctionIDs": "b2638f6ed2917cc9610e45aa2fbf9c434235e3f5cf0db78d63c15ce44e248b18",
}
ORIGINAL_PATHS = {
    FIXTURE, ".github/workflows/release.yml", "scripts/release_engine_resume.py",
    "scripts/test_release_engine_resume.py", "scripts/run_macos_tests.py",
    "scripts/test_run_macos_tests.py", "scripts/release_checkpoint.py",
    "scripts/test_release_recovery.py", "scripts/test_release_workflow.py",
}
PATHS = ORIGINAL_PATHS | {
    "scripts/test_swift_test_failure_propagation.py",
    "Sources/NexGenVideo/Resources/Changelog/changelog.json",
    "Sources/NexGenVideo/ThreeD/SpatialSceneSession.swift",
    "Sources/NexGenVideo/ThreeD/BpyRuntimeSelfTest.swift",
    "Sources/NexGenVideo/App/ProductionSpatialHistoryAcceptance.swift",
    "Sources/NexGenVideo/App/ProductionSpatialAcceptance.swift",
    "Sources/NexGenVideo/App/ProductionSceneUIAcceptance.swift",
    "Sources/NexGenVideo/App/ProductionVisualSourcesDriver.swift",
    "Sources/NexGenVideo/ThreeD/SpatialSceneView.swift", "Sources/NexGenVideo/UI/AppTheme.swift",
    ".github/workflows/ci-batch.yml", ".github/workflows/diagnostic-acceptance.yml",
    ".github/workflows/external-gui-acceptance.yml", ".github/workflows/settings-owner-acceptance.yml",
    "scripts/external-gui/NexGenVideoExternalUITests/UserJourneyTests.swift",
    "scripts/external-gui/acceptance.py", "scripts/external-gui/transport.py",
    "scripts/external-gui/transport_fixture.py", "scripts/pack_recovery_owner_acceptance.py",
    "scripts/release_acceptance_identity.py", "scripts/retained_release_runtime.py",
    "scripts/settings_owner_acceptance.py", "scripts/test_ci_workflow.py",
    "scripts/test_external_gui_test_bundle.py", "scripts/test_external_transport.py",
    "scripts/test_release_acceptance_identity.py", "scripts/verify_diagnostic_candidate.py",
    "scripts/test_verified_pr_source_checks.py",
}
ENGINE_SOURCE_OBJECTS = {
    "Engine": "29cfed623d13e6d84d5822a30b98e088fc123c3f",
    "Package.swift": "37f605bfb8cdccc48821b39484c819ba3e5eff43",
    "Package.resolved": "530cdaed0a29a65181353d86d05cf9dc04890cc2",
    "Tests/NexGenEngineTests": "bbb8baff2d9dcfb569f5828fc0de5c36a0589826",
    "Sources/MusicvideoPlugin": "2eeef41c978f57342cc9534defec31ab5fba39ea",
    "Sources/FixtureFictionPlugin": "ec63ab91074a258add456a1059049779b338cd7d",
    "Sources/NexGenVideo/Resources/AppResources.txt": "ed934b45d5a6ee37540078228114536ea83d1c98",
    "docs/migrations/ai-film-production-d07a1ce5.inventory.json": "89d5b2ba08800cf90ba879b824db1e7ab951bc34",
    "Runtime": "910b87b08a3a8c976e0f2502580c843b0df74154",
    "Metal": "4fddc68f15d9ff70104869a2dffd8e5956e9b5d8",
    "Vendor": "51e93c100e00dcd196edac0e70e1af921d52055a",
    "plugins": "b75e017d3145010368ae417bc410574f3f0300c1",
    "Tests/AppKitTestHost": "087f895d5e7243a0cbf4bf8b7775f974cffdc2c3",
    "Tests/AppKitTestHostSupport": "180f486523e826b8b462011d42bf758fdc4e1d6f",
    "Sources/BpyRuntimeProtocol": "4bf768314bb52830a55da47d6a25ff36e9f2cf94",
    "Sources/BpySupervisorPOSIX": "f1469002cfa83206e5d74aa6c71aba4aab365f6b",
    "Sources/NexGenVideoBpyService": "b7d478b9196a2bc0c2eb4b4876c012f44a4045d1",
    "Sources/NexGenVideoBpyStorage": "b9bf2fa702b820f2eb88f95591ad9eb76c7dc776",
    "Sources/NexGenVideoBpySupervisor": "27230f5bbb93ad75eebf69bc6520c951213dc800",
    "scripts/stage_test_runtime.sh": "7f83d8afe0c3a769c5f8d67e2ce59a041ec831dd",
    "scripts/verify_swift_test_output.py": "5b8993b80a71ad03807b8116b2bc50fc795a90e2",
}


REVIEWED_HARNESS_SOURCE = '55a13d86438208d9e801f243f9051f83a75e6c10'
REVIEWED_QUERY_SOURCE = '1472febfd2be2dbe6affa3a183e436ff38b9711d'
REVIEWED_QUERY_OBJECTS = {
    'scripts/button_query_diagnostic.py': '2140732ff99bde9d6ef03956b40ee2b1b989d618',
    'scripts/button_query_diagnostic.swift': 'ce96ee94e0f04b85ca07e340a684657adf1235bf',
    'scripts/test_button_query_diagnostic.py': '9c646f6d450de9436ec70dc26bae09470cf0c4ba',
    'scripts/test_diagnostic_acceptance.py': '8e108ae3c51a5fc3558057a61abab81ab3124b6e',
}
REVIEWED_HARNESS_OBJECTS = {
    ".github/actions/prepare-bpy-source/action.yml": "467d96269e791bebf8e15f75bb5882511fd8257f",
    ".github/workflows/bpy-runtime-acceptance.yml": "49a290fb27991ef29b8e7830e674bb67e403fa31",
    ".github/workflows/chat-hang-replay.yml": "9979ecf70abf89e74efe2d95356be7b1d6e65f0a",
    ".github/workflows/private-example-analysis.yml": "de7c832cbb2e7562a18d7468c417ddda6f6481fb",
    ".github/workflows/retained-runtime-failure-diagnostic.yml": "6b92cc75f5de30de492ab8e812ea6e59f30f2af2",
    ".github/workflows/workspace-ui-acceptance.yml": "142a72ff347d0f7a0d646b0accbb7e07b6ecd9ea",
    "scripts/app_termination_acceptance.py": "99fc7b59b031e93cf8773b558d7a64b04d94387e",
    "scripts/notarize.sh": "9caf88403052ad45fa81dedfaab5d88cdb5d1903",
    "scripts/plan_dmg_capacity.py": "c3069b43a1df557d67b49f778ab46e16b6953288",
    "scripts/retained_packaging.py": "65ac9762e16b52e562112e960d7953872adb008b",
    "scripts/retained_runtime_failure_diagnostic.py": "e0c86caf002a7d9c4907ad41b6a2b3a06a68beac",
    "scripts/runtime_pointer_diagnostic.swift": "e3c65906f7d614505d843c4f1d64d05fde1149d6",
    "scripts/runtime_pointer_source.py": "96a452607a2ad5b233ed6cb49d22d82131c2c516",
    "scripts/test_app_termination_acceptance.py": "6d73f7773410aee316c3430b26cd95545a9c32c4",
    "scripts/test_release_dmg_packaging.py": "27442c52f51ce04ae8e69e578b2865ba1dfcfc55",
    "scripts/test_retained_packaging.py": "3f586f596b3a63f61f005ec3a520c5d2ef4de4b8",
    "scripts/test_retained_runtime_failure_diagnostic.py": "b16fa818f049f88663d2236a61c3255bcee78ef7",
    "scripts/workspace_native_ci.py": "75334f813fee5bd1564eb5225b7579ffd20c0465"
}
PATHS |= set(REVIEWED_HARNESS_OBJECTS)
PATHS |= set(REVIEWED_QUERY_OBJECTS)
PATHS |= {
    BUTTON_FIXTURE, "Sources/NexGenVideo/App/NativeButtonAccessibility.swift",
    APP_READER, APP_HOST_FILE, "Sources/NexGenVideo/App/main.swift",
    ".github/workflows/scene-history-hierarchy-diagnostic.yml", "scripts/external-gui/test_bundle.py",
    "scripts/scene_history_ax_observer.swift", "scripts/scene_history_hierarchy.py",
    "scripts/test_scene_history_hierarchy.py",
}


def command(*args):
    return subprocess.check_output(args, stdin=subprocess.DEVNULL, text=True, timeout=40).strip()


def event_parser(source):
    tree = ast.parse(source)
    function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "swift_events")
    return ast.dump(function, include_attributes=False)


def verify_app_host_role(before, after):
    before, after = before.rstrip("\n") + "\n", after.rstrip("\n") + "\n"
    marker = "    static func main() {\n"
    require(before.count(marker) == after.count(marker) == 1, "App Host entry is ambiguous")
    start = after.index(marker) + len(marker)
    require(after.count("        UserDefaults.standard.register") == 1, "App Host normal entry changed")
    end = after.index("        UserDefaults.standard.register", start)
    require(after[:start] + after[end:] == before
            and hashlib.sha256(before.encode()).hexdigest() == APP_HOST_NORMAL_SHA256
            and hashlib.sha256(after[start:end].encode()).hexdigest() == APP_HOST_BRANCH_SHA256,
            "Only the exact reviewed early App reader branch may differ")
    return dict(APP_HOST_ROLE)


def verify_engine_source_objects(head):
    actual, compatibility = {}, None
    for path, pinned in ENGINE_SOURCE_OBJECTS.items():
        require(command("git", "rev-parse", SOURCE + ":" + path) == pinned,
                "Original Engine dependency object changed: " + path)
        current = command("git", "rev-parse", head + ":" + path)
        if path == APP_HOST and current != pinned:
            require(current == APP_HOST_TREE
                    and command("git", "rev-parse", head + ":" + APP_HOST_FILE) == APP_HOST_BLOB,
                    "Unreviewed App Host object changed")
            compatibility = verify_app_host_role(command("git", "show", SOURCE + ":" + APP_HOST_FILE),
                                                 command("git", "show", head + ":" + APP_HOST_FILE))
        else:
            require(current == pinned, "Retained Engine dependency object changed: " + path)
        actual[path] = current
    return actual, compatibility


def verify_harness_source_objects(head, changed):
    for source, objects in ((REVIEWED_HARNESS_SOURCE, REVIEWED_HARNESS_OBJECTS),
                            (REVIEWED_QUERY_SOURCE, REVIEWED_QUERY_OBJECTS)):
        if set(changed).intersection(objects):
            for path, pinned in objects.items():
                require(command("git", "rev-parse", source + ":" + path) == pinned
                        and command("git", "rev-parse", head + ":" + path) == pinned,
                        "Reviewed retained CI source object changed: " + path)


def verify_sources(head, version_bump=False):
    require(re.fullmatch(r"[a-f0-9]{40}", head) and command("git", "rev-parse", "HEAD") == head,
            "Release Engine resume checkout differs")
    subprocess.run(["git", "merge-base", "--is-ancestor", SOURCE, head],
                   stdin=subprocess.DEVNULL, check=True, timeout=30)
    changed = command("git", "diff", "--name-only", "--no-renames", SOURCE, head).splitlines()
    require(FIXTURE in changed and set(changed) <= PATHS,
            "Unreviewed Engine, pack, app, dependency, runtime or unrelated source changed")
    dirty = command("git", "diff", "HEAD", "--name-only", "--no-renames").splitlines()
    require(set(dirty) <= ({"Sources/NexGenVideo/Resources/Info.plist"} if version_bump else set()),
            "Engine resume tracked inputs are dirty")
    verify_engine_source_objects(head)
    verify_harness_source_objects(head, changed)
    before = command("git", "show", SOURCE + ":scripts/run_macos_tests.py")
    require(event_parser(before) == event_parser(Path("scripts/run_macos_tests.py").read_text()),
            "The retained native event verification contract changed")
    return changed


def verify_original(run, jobs):
    require(run.get("id") == RUN and run.get("head_sha") == SOURCE
            and run.get("repository", {}).get("full_name") == "iret77/nexgenvideo"
            and run.get("path") == ".github/workflows/release.yml" and run.get("run_attempt") == 1
            and run.get("actor", {}).get("login") == "iret77" and run.get("event") == "workflow_dispatch"
            and run.get("status") == "completed" and run.get("conclusion") == "failure",
            "Original partial Release run differs")
    require(jobs.get("total_count") == len(jobs.get("jobs", [])), "Incomplete original Release jobs")
    matches = [job for job in jobs["jobs"] if job.get("id") == JOB and job.get("name") == "release-build"]
    require(len(matches) == 1, "Original Release builder is absent or ambiguous")
    job = matches[0]
    require(job.get("run_id") == RUN and job.get("head_sha") == SOURCE and job.get("run_attempt") == 1
            and job.get("labels") == ["macrunner"] and job.get("status") == "completed"
            and job.get("conclusion") == "failure", "Original builder execution differs")
    for name, conclusion in (("Record release compiler configuration", "success"),
                             ("Build the exact release test configuration", "success"),
                             ("Verify release build did not mutate tracked source", "success"),
                             ("Stage release test runtime inputs", "success"),
                             ("Test the exact release configuration", "failure"),
                             ("Upload release test evidence", "success")):
        steps = [step for step in job.get("steps", []) if step.get("name") == name]
        require(len(steps) == 1 and steps[0].get("conclusion") == conclusion,
                "Original builder stage differs: " + name)
    require([step["name"] for step in job["steps"] if step.get("conclusion") == "failure"]
            == ["Test the exact release configuration"], "Original builder has another failure")
    return job


def verify_archive(path, root):
    from run_macos_tests import swift_events
    with zipfile.ZipFile(path) as archive:
        names = [name for name in archive.namelist() if name.rsplit("/", 1)[-1] == "suite.json"]
        require(len(names) == 1, "Original partial suite is ambiguous")
        prefix = names[0][:-len("suite.json")]
        suite = json.loads(archive_bytes(archive, names[0]))
        require(suite.get("schema") == 1 and suite.get("sourceSHA") == SOURCE
                and suite.get("configuration") == "release" and suite.get("scope") == "all"
                and suite.get("filter") == "" and suite.get("completed") is False
                and not any(key in suite for key in ("retainedBackends", "productSourceSHA", "harnessSourceSHA")),
                "Original partial Release suite differs")
        phases = suite.get("phases", [])
        require([phase.get("name") for phase in phases] == ["xctest", NAME, "app-swift-testing"],
                "Original backend order differs")
        phase = phases[1]
        require(phase.get("status") == "verified-execution" and phase.get("exitCode") == 0
                and phase.get("outputCapture", {}).get("originalExitCode") == 0
                and phase.get("outputCapture", {}).get("eof") is True
                and not any(value.startswith("--filter") for value in phase.get("command", []))
                and "diagnostic" not in phase, "Original Engine backend was filtered, failed or incomplete")
        folder = root / NAME
        folder.mkdir()
        for name in ("console.log", "events.jsonl"):
            (folder / name).write_bytes(archive_bytes(archive, prefix + NAME + "/" + name))
        events = swift_events(folder / "events.jsonl", "NexGenEngineTests")
        framework = assess_output(folder / "console.log", swift_testing_runs=1, xctest_runs=0)
        require(events == phase.get("events") and events["functionExecutions"] == 896
                and len(events["discoveredFunctionIDs"]) == 910 and len(events["skippedFunctionIDs"]) == 14
                and framework.get("passed") is True and framework == phase.get("framework"),
                "Original complete Engine execution proof differs")
        return {"phase": phase, "eventsSHA256": checksum(folder / "events.jsonl"),
                "logSHA256": checksum(folder / "console.log")}


def toolchain(raw):
    text = "\n".join(re.sub(r"^\d{4}-\d\d-\d\dT\S+Z ", "", line)
                     for line in ANSI.sub("", raw.decode()).splitlines())
    patterns = {"swift": r"(?m)^Apple Swift version [^\n]+\nTarget: [^\n]+",
                "xcode": r"(?m)^Xcode [^\n]+\nBuild version [^\n]+",
                "python": r"Successfully set up CPython \(([^)]+)\)",
                "osVersion": r"(?m)^ProductVersion:\s*([^\n]+)",
                "osBuild": r"(?m)^BuildVersion:\s*([^\n]+)"}
    result = {}
    for key, pattern in patterns.items():
        matches = set(re.findall(pattern, text))
        require(len(matches) == 1, "Original toolchain identity is missing or ambiguous: " + key)
        result[key] = matches.pop().strip()
    return result


def prepare(run_id, root):
    require(run_id == RUN and os.environ["GITHUB_REPOSITORY"] == "iret77/nexgenvideo",
            "Only the pinned completed Engine backend can resume")
    require(os.environ["GITHUB_RUN_ATTEMPT"] == "1", "Engine acquisition cannot reuse another Actions attempt")
    head = os.environ["GITHUB_SHA"]
    changed = verify_sources(head)
    root.mkdir(parents=True, exist_ok=False)
    original = api(f"actions/runs/{RUN}")
    jobs = api(f"actions/runs/{RUN}/attempts/1/jobs?per_page=100")
    job = verify_original(original, jobs)
    artifact = api(f"actions/artifacts/{ARTIFACT}")
    verify_artifact(artifact, original, job, ARTIFACT, DIGEST, "release-test-evidence")
    download(artifact, root / "original.zip")
    proof = verify_archive(root / "original.zip", root)
    from verified_pr_source_checks import read_api
    raw = read_api(f"actions/jobs/{JOB}/logs", 4_000_000)
    require(hashlib.sha256(raw).hexdigest() == LOG_DIGEST, "Original complete builder log changed")
    (root / "original-job.log").write_bytes(raw)
    verify_artifact(artifact, original, job, ARTIFACT, DIGEST, "release-test-evidence")
    receipt = {"schema": "release-engine-resume/v1", "sourceSHA": head,
               "runID": int(os.environ["GITHUB_RUN_ID"]), "attempt": int(os.environ["GITHUB_RUN_ATTEMPT"]),
               "originalSourceSHA": SOURCE, "originalRun": original, "originalJobs": jobs,
               "artifact": artifact, "artifactSHA256": DIGEST, "originalLogSHA256": LOG_DIGEST,
               "changedPaths": changed, "engineSourceObjects": verify_engine_source_objects(head)[0],
               "reviewedHarnessSourceSHA": REVIEWED_HARNESS_SOURCE, "reviewedHarnessObjects": REVIEWED_HARNESS_OBJECTS,
               "toolchain": toolchain(raw), "proof": proof,
               "acquiredAt": datetime.now(timezone.utc).isoformat()}
    compatibility = verify_engine_source_objects(head)[1]
    if compatibility:
        receipt["engineHostCompatibility"] = compatibility
    if APP_READER in changed:
        receipt["nativeButtonMethods"] = sorted(BUTTON_TEST_METHODS)
    if set(changed).intersection(REVIEWED_QUERY_OBJECTS):
        receipt.update(reviewedQuerySourceSHA=REVIEWED_QUERY_SOURCE, reviewedQueryObjects=REVIEWED_QUERY_OBJECTS)
    verify_receipt(receipt, head, int(os.environ["GITHUB_RUN_ID"]))
    write(root / "receipt.json", receipt)


def verify_receipt(receipt, source, run_id):
    require(receipt.get("schema") == "release-engine-resume/v1" and receipt.get("sourceSHA") == source
            and receipt.get("runID") == run_id and receipt.get("attempt") == 1
            and receipt.get("originalSourceSHA") == SOURCE and receipt.get("artifactSHA256") == DIGEST
            and receipt.get("originalLogSHA256") == LOG_DIGEST, "Engine resume receipt identity differs")
    job = verify_original(receipt["originalRun"], receipt["originalJobs"])
    artifact = receipt["artifact"]
    require(artifact.get("id") == ARTIFACT and artifact.get("name") == "release-test-evidence"
            and artifact.get("digest") == "sha256:" + DIGEST and artifact.get("expired") is False
            and artifact.get("workflow_run", {}).get("id") == RUN
            and artifact.get("workflow_run", {}).get("head_sha") == SOURCE,
            "Acquired Engine artifact identity differs")
    instant = lambda value: datetime.fromisoformat(value.replace("Z", "+00:00"))
    require(isinstance(receipt.get("acquiredAt"), str), "Engine acquisition timestamp is missing")
    acquired = instant(receipt["acquiredAt"])
    require(instant(job["started_at"]) <= instant(artifact["created_at"])
            <= instant(artifact["updated_at"]) <= instant(job["completed_at"])
            <= acquired < instant(artifact["expires_at"]) and acquired <= datetime.now(timezone.utc),
            "Engine artifact was not acquired during its valid retention")
    phase = receipt.get("proof", {}).get("phase", {})
    require(hashlib.sha256(json.dumps(phase, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
            == PHASE_DIGEST and receipt["proof"].get("eventsSHA256") == EVENT_DIGEST
            and receipt["proof"].get("logSHA256") == CONSOLE_DIGEST, "Pinned Engine execution bytes differ")
    require(phase.get("name") == NAME and phase.get("status") == "verified-execution"
            and phase.get("exitCode") == 0 and phase.get("outputCapture", {}).get("eof") is True
            and phase.get("events", {}).get("functionExecutions") == 896
            and phase.get("framework", {}).get("passed") is True, "Engine resume phase proof differs")
    require(FIXTURE in receipt.get("changedPaths", []) and set(receipt["changedPaths"]) <= PATHS,
            "Engine resume source closure differs")
    if "engineSourceObjects" in receipt:
        current = receipt["engineSourceObjects"]
        if current == ENGINE_SOURCE_OBJECTS:
            require("engineHostCompatibility" not in receipt and APP_HOST_FILE not in receipt["changedPaths"],
                    "Missing or unnecessary Engine Host exception")
        else:
            expected = dict(ENGINE_SOURCE_OBJECTS, **{APP_HOST: APP_HOST_TREE})
            require(current == expected and receipt.get("engineHostCompatibility") == APP_HOST_ROLE
                    and APP_HOST_FILE in receipt["changedPaths"] and APP_READER in receipt["changedPaths"],
                    "Retained Engine dependency receipt differs")
            command = phase.get("command", [])
            require(isinstance(command, list) and command[:2] == ["swift", "test"]
                    and command.count("--test-product") == 1
                    and command.index("--test-product") + 1 < len(command)
                    and command[command.index("--test-product") + 1] == "NexGenEngineTests"
                    and all(flag in command for flag in ("--skip-build", "--disable-xctest", "--enable-swift-testing"))
                    and all(Path(value).name != "NexGenVideoAppKitTestHost" for value in command),
                    "The retained Engine execution must not use the changed App Host")
    else:
        require(set(receipt["changedPaths"]) <= ORIGINAL_PATHS,
                "Extended App/CI continuation requires exact Engine dependency objects")
    expected_buttons = BUTTON_TEST_METHODS if APP_READER in receipt["changedPaths"] else ORIGINAL_BUTTON_TEST_METHODS
    if APP_READER in receipt["changedPaths"] or "nativeButtonMethods" in receipt:
        require(receipt.get("nativeButtonMethods") == sorted(expected_buttons), "Native button receipt inventory differs")
    if set(receipt["changedPaths"]).intersection(REVIEWED_HARNESS_OBJECTS) or any(
            key in receipt for key in ("reviewedHarnessSourceSHA", "reviewedHarnessObjects")):
        require(receipt.get("reviewedHarnessSourceSHA") == REVIEWED_HARNESS_SOURCE
                and receipt.get("reviewedHarnessObjects") == REVIEWED_HARNESS_OBJECTS,
                "Reviewed retained CI source receipt differs")
    if set(receipt["changedPaths"]).intersection(REVIEWED_QUERY_OBJECTS) or any(
            key in receipt for key in ("reviewedQuerySourceSHA", "reviewedQueryObjects")):
        require(receipt.get("reviewedQuerySourceSHA") == REVIEWED_QUERY_SOURCE
                and receipt.get("reviewedQueryObjects") == REVIEWED_QUERY_OBJECTS,
                "Reviewed query diagnostic receipt differs")


def verify(root, version_bump=False):
    require(os.environ["GITHUB_REPOSITORY"] == "iret77/nexgenvideo"
            and os.environ["GITHUB_RUN_ATTEMPT"] == "1", "Engine proof cannot cross repository or Actions attempt")
    receipt = json.loads((root / "receipt.json").read_text())
    require(receipt.get("attempt") == int(os.environ["GITHUB_RUN_ATTEMPT"]), "Current Engine proof attempt differs")
    verify_receipt(receipt, os.environ["GITHUB_SHA"], int(os.environ["GITHUB_RUN_ID"]))
    require(verify_sources(receipt["sourceSHA"], version_bump) == receipt["changedPaths"],
            "Current Engine source closure differs")
    actual_objects, compatibility = verify_engine_source_objects(receipt["sourceSHA"])
    require(receipt.get("engineSourceObjects", actual_objects) == actual_objects
            and receipt.get("engineHostCompatibility") == compatibility, "Current Engine role proof differs")
    require(checksum(root / "original.zip") == DIGEST and checksum(root / "original-job.log") == LOG_DIGEST,
            "Retained Engine input bytes differ")
    proof = receipt["proof"]
    require(checksum(root / NAME / "events.jsonl") == proof["eventsSHA256"]
            and checksum(root / NAME / "console.log") == proof["logSHA256"]
            and toolchain((root / "original-job.log").read_bytes()) == receipt["toolchain"],
            "Retained Engine execution data changed")
    current = {"swift": command("swift", "--version"), "xcode": command("xcodebuild", "-version"),
               "python": platform.python_version(), "osVersion": command("sw_vers", "-productVersion"),
               "osBuild": command("sw_vers", "-buildVersion")}
    require(platform.machine() == "arm64" and current == receipt["toolchain"],
            "Current Release Engine runtime or toolchain differs")
    write(root / "current-environment.json", current)
    return receipt


def install(root, evidence):
    receipt = verify(root, version_bump=True)
    target = evidence / NAME
    target.mkdir()
    for name in ("console.log", "events.jsonl"):
        (target / name).write_bytes((root / NAME / name).read_bytes())
    phase = copy.deepcopy(receipt["proof"]["phase"])
    phase.update(log=str(target / "console.log"), reusedFrom={"runID": RUN, "sourceSHA": SOURCE,
                 "jobID": JOB, "artifactID": ARTIFACT, "artifactSHA256": DIGEST})
    write(evidence / "retained-engine-receipt.json", receipt)
    return phase, receipt


def verify_button_inventory(events, methods=ORIGINAL_BUTTON_TEST_METHODS):
    prefix = "NexGenVideoTests.NativeButtonInteractionTests/"
    for key, expected_hash in APP_BASELINE_INVENTORY_HASHES.items():
        values = events.get(key)
        require(isinstance(values, list) and all(isinstance(value, str) for value in values)
                and len(values) == len(set(values)), "Fresh App function inventory is malformed or duplicated")
        added = [value for value in values if value.startswith(prefix)]
        matched = [re.fullmatch(re.escape(prefix) + r"([A-Za-z0-9_]+)\(\)/NativeButtonInteractionTests\.swift:[1-9][0-9]*:[1-9][0-9]*", value)
                   for value in added]
        expected = set() if key == "skippedFunctionIDs" else methods
        require(all(matched) and len(added) == len(expected)
                and {match[1] for match in matched} == expected, "New native button methods did not all execute exactly once")
        original = sorted(value for value in values if not value.startswith(prefix))
        digest = hashlib.sha256(json.dumps(original, separators=(",", ":")).encode()).hexdigest()
        require(digest == expected_hash, "Original App discovery, start, end or skip inventory changed")


def verify_completed_suite(suite, source, run_id):
    require(suite.get("schema") == 1 and suite.get("sourceSHA") == source and suite.get("completed") is True
            and suite.get("scope") == "all" and suite.get("configuration") == "release"
            and suite.get("filter") == "" and suite.get("reusedTestExecutions") == 896
            and (suite.get("testExecutions"), suite.get("freshTestExecutions")) in
                ((4620, 3724), (4637, 3741), (4620 + len(BUTTON_TEST_METHODS), 3724 + len(BUTTON_TEST_METHODS)))
            and suite.get("combinedFrameworks", {}).get("passed") is True,
            "Resumed Release aggregate is incomplete")
    retained = suite.get("retainedBackends", [])
    require(isinstance(retained, list) and len(retained) == 1 and isinstance(retained[0], dict),
            "Resumed Release must retain exactly the Engine backend")
    methods = BUTTON_TEST_METHODS if APP_READER in retained[0].get("changedPaths", []) else ORIGINAL_BUTTON_TEST_METHODS
    added = len(methods) if BUTTON_FIXTURE in retained[0].get("changedPaths", []) else 0
    require(suite.get("testExecutions") == 4620 + added and suite.get("freshTestExecutions") == 3724 + added,
            "Resumed Release aggregate is incomplete")
    verify_receipt(retained[0], source, run_id)
    phases = suite.get("phases", [])
    require([phase.get("name") for phase in phases] == ["xctest", NAME, "app-swift-testing"],
            "Resumed Release backend inventory differs")
    for phase in phases:
        require(phase.get("status") == "verified-execution" and phase.get("exitCode") == 0
                and phase.get("outputCapture", {}).get("originalExitCode") == 0
                and phase.get("outputCapture", {}).get("eof") is True
                and phase.get("framework", {}).get("passed") is True and "diagnostic" not in phase
                and not any(value.startswith("--filter") for value in phase.get("command", [])),
                "Resumed Release contains a failed, incomplete or filtered backend")
    expected = copy.deepcopy(retained[0]["proof"]["phase"])
    expected.update(log=phases[1]["log"], reusedFrom={"runID": RUN, "sourceSHA": SOURCE,
                    "jobID": JOB, "artifactID": ARTIFACT, "artifactSHA256": DIGEST})
    require(phases[1] == expected and all("reusedFrom" not in phases[index] for index in (0, 2)),
            "Resumed Release backend provenance differs")
    require(phases[0].get("testCaseExecutions") == 48
            and phases[2].get("events", {}).get("functionExecutions") == 3676 + added,
            "Fresh App backend execution counts differ")
    if added:
        verify_button_inventory(phases[2].get("events", {}), methods)
    host = phases[2].get("originalHostReceipt", {})
    require(host.get("sourceSHA") == source and all(host.get(key) is True for key in
            ("mainThread", "applicationRunningAtStart", "started", "completed", "abiSucceeded", "runReturnedAfterCompletion")),
            "Fresh App host did not complete successfully")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("operation", choices=("prepare", "verify"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--run-id", type=int)
    args = parser.parse_args()
    if args.operation == "prepare":
        prepare(args.run_id, args.root)
    else:
        verify(args.root)
