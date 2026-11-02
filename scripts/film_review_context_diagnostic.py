"""Replay the bounded native-export context using the exact isolated-test products."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import zipfile

from app_host_zombie_diagnostic import FILM_REVIEW_CONTEXT_FILTER
import film_review_export_diagnostic as original
from retained_app_test_products import (api, archive_bytes, archive_json, checksum, command,
                                        download, manifest, require, verify_artifact, verify_tree, write, UUID)

PRODUCT = "21160564f484cbd9aaa1a563d561077e523a03ab"
PRODUCER = 41378923780
DIAGNOSTIC = 13112521512
DIAGNOSTIC_DIGEST = "c09415efe56b38c884ec12eeef48446e74a61a81d5f3e4e0bc240b21b2aa1153"
PRODUCTS = 13113005465
PRODUCTS_DIGEST = "aa453ce97bcf94ecc60a3c2ad7720fc2410b939ce6662390a82f94c8a732a3f2"
PATHS = {".github/workflows/diagnostic-acceptance.yml", "scripts/app_host_zombie_diagnostic.py",
         "scripts/run_macos_tests.py", "scripts/capture_render_review_test_diagnostic.py",
         "scripts/test_native_test_python_workflow.py", "scripts/film_review_context_diagnostic.py",
         "scripts/test_film_review_context_diagnostic.py"}


def selected_inventory(rows):
    functions = sorted(row["payload"]["id"] for row in rows if row.get("kind") == "test"
                       and row.get("payload", {}).get("kind") == "function"
                       and re.search(FILM_REVIEW_CONTEXT_FILTER, row["payload"]["id"]))
    require(len(functions) == len(set(functions)) == 41 and original.TEST_ID in functions,
            "The original bounded export context differs")
    return functions


def executed_product_root(suite, compiled, profile, harness):
    phase = suite["phases"][0]
    receipt, observed = phase["originalHostReceipt"], phase["diagnostic"]
    host = compiled["binaries"]["NexGenVideoAppKitTestHost"]
    root = suite["binPath"]
    require(Path(root).is_absolute() and Path(root).parts[-4:] == (".build", "out", "Products", "Debug")
            and receipt["hostExecutable"] == root + "/NexGenVideoAppKitTestHost"
            and receipt["bundleBinary"] == root + "/NexGenVideoTests.xctest/Contents/MacOS/NexGenVideoTests"
            and observed["pid"] == receipt["pid"] == phase["pid"]
            and observed["parentPID"] == receipt["parentPID"]
            and observed["profile"] == profile and observed["status"] == "verified"
            and observed["environment"] == {"NGV_FILM_REVIEW_EXPORT_DIAGNOSTIC": "1", "otherDiagnosticVariablesPresent": False}
            and observed["hostSHA256"] == host["sha256"]
            and observed["hostUUID"].lower() in {u.lower() for u in re.findall(UUID, host["uuidOutput"])}
            and observed["sourceSHA"] == observed["harnessSourceSHA"] == receipt["sourceSHA"] == harness
            and observed["productSourceSHA"] == compiled["sourceSHA"] == PRODUCT,
            "Executed native host, environment or product root differs")
    return root


def read_markers(path):
    records, malformed = [], 0
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        for part in line.split("[film-review-export] ")[1:]:
            try:
                row, _ = json.JSONDecoder().raw_decode(part.lstrip())
                require(isinstance(row, dict) and isinstance(row.get("stage"), str)
                        and isinstance(row.get("exportID"), str), "Malformed context marker")
                records.append(row)
            except ValueError:
                malformed += 1
    return records, malformed


def marker_summary(records):
    captures = {}
    for begin in (row for row in records if row["stage"] == "capture.begin"):
        rows = [row for row in records if row["exportID"] == begin["exportID"]]
        stages = [row["stage"] for row in rows if row["stage"] != "heartbeat"]
        boundaries = [stage for stage in stages if stage != "states.ended"]
        heartbeats = [row for row in rows if row["stage"] == "heartbeat"]
        last = heartbeats[-1] if heartbeats else {}
        ledger = last.get("ledger", [])
        own = next((row for row in ledger if isinstance(row, dict)
                    and row.get("instance") == last.get("compositor")), None) if isinstance(ledger, list) else None
        ended = [row for row in rows if row["stage"] == "states.ended"]
        captures[begin["exportID"]] = {"stages": stages, "lastBoundary": boundaries[-1] if boundaries else None,
            "sessionReturned": "session.returned" in stages,
            "statesEnded": {"present": bool(ended), "cancelled": ended[-1].get("cancelled") if ended else None},
            "ownCompositor": last.get("compositor"), "ownLedger": own,
            "nativeState": {"value": last.get("nativeState"), "scope": "last states() emission, not live progress"}}
    heartbeats = [row for row in records if row["stage"] == "heartbeat"]
    latest = heartbeats[-1] if heartbeats else {}
    ledger = latest.get("ledger", [])
    unbalanced = []
    for row in ledger if isinstance(ledger, list) else []:
        if not isinstance(row, dict):
            continue
        counts = [row.get(key) for key in ("started", "frame", "error", "cancelled", "pending", "dropped")]
        if not all(type(value) is int for value in counts) or counts[4] > 0 or counts[5] > 0 or counts[0] != sum(counts[1:4]):
            unbalanced.append(row)
    created = {row["instance"] for row in records if row["stage"] == "compositor.created" and type(row.get("instance")) is int}
    destroyed = [row for row in records if row["stage"] == "compositor.destroyed" and type(row.get("instance")) is int]
    return {"captures": captures, "ledger": {"snapshotUptime": latest.get("uptime"), "unbalanced": unbalanced,
            "destroyedWithOwnerPending": [row for row in destroyed if type(row.get("ownerPending")) is not int or row["ownerPending"] > 0],
            "neverDestroyed": sorted(created - {row["instance"] for row in destroyed})}}


def source(folder):
    expected = {"REPLAY_KIND": "ci-film-review-context", "CANDIDATE_RUN": str(PRODUCER),
                "CANDIDATE_SOURCE": PRODUCT, "CANDIDATE_ARTIFACT": str(DIAGNOSTIC),
                "CANDIDATE_DIGEST": DIAGNOSTIC_DIGEST, "PRODUCT_SHA": PRODUCT,
                "PRODUCTS_ID": str(PRODUCTS), "PRODUCTS_DIGEST": PRODUCTS_DIGEST}
    require(all(os.environ.get(k) == v for k, v in expected.items()), "Context producer inputs differ")
    require(os.environ.get("GITHUB_REPOSITORY") == "iret77/nexgenvideo", "Context repository differs")
    sha = command(["git", "rev-parse", "HEAD"])
    require(sha == os.environ.get("GITHUB_SHA") and command(["git", "show", "-s", "--format=%P"]) == PRODUCT,
            "Context harness must be a direct child of the unchanged product")
    changed = set(command(["git", "diff", "--name-only", PRODUCT, sha]).splitlines())
    require(changed == PATHS and checksum(original.TEST) == original.TEST_DIGEST,
            "Context harness changed unreviewed source or the original test")
    folder.mkdir(parents=True, exist_ok=False)
    run = api(f"actions/runs/{PRODUCER}")
    jobs = api(f"actions/runs/{PRODUCER}/jobs?per_page=100")
    require(run.get("head_sha") == PRODUCT and run.get("id") == PRODUCER and run.get("run_attempt") == 1
            and run.get("repository", {}).get("full_name") == "iret77/nexgenvideo"
            and run.get("path") == ".github/workflows/diagnostic-acceptance.yml"
            and run.get("event") == "workflow_dispatch" and run.get("status") == "completed"
            and run.get("conclusion") == "success", "Isolated native producer differs")
    require(jobs.get("total_count") == len(jobs.get("jobs", [])), "Producer jobs are incomplete")
    producers = {name: [j for j in jobs["jobs"] if j.get("name") == name]
                 for name in ("source", "ci-film-review-export")}
    for name, matches in producers.items():
        require(len(matches) == 1 and matches[0].get("head_sha") == PRODUCT
                and matches[0].get("run_id") == PRODUCER and matches[0].get("run_attempt") == 1
                and matches[0].get("status") == "completed" and matches[0].get("conclusion") == "success",
                "Missing or failed isolated producer job: " + name)
    job = producers["ci-film-review-export"][0]
    for name in ("Compile diagnostic native products", "Retain compiled products before diagnostic execution",
                 "Diagnose only the original unfinished film-review test once", "Preserve diagnostic interpretation"):
        require(sum(s.get("name") == name and s.get("conclusion") == "success" for s in job["steps"]) == 1,
                "Isolated producer step differs: " + name)
    artifacts = {}
    for key, identity, digest, name in (
            ("diagnostic", DIAGNOSTIC, DIAGNOSTIC_DIGEST, f"film-review-export-diagnostic-{PRODUCER}-a1"),
            ("products", PRODUCTS, PRODUCTS_DIGEST, f"film-review-test-products-{PRODUCER}-a1")):
        item = api(f"actions/artifacts/{identity}")
        verify_artifact(item, run, job, identity, digest, name)
        artifacts[key] = item
        write(folder / (key + "-artifact.json"), item)
    archive = folder / "isolated-original.zip"
    download(artifacts["diagnostic"], archive)
    with zipfile.ZipFile(archive) as zipped:
        compiled = archive_json(zipped, "film-review-binding/compiled-products.json")
        suite = archive_json(zipped, "film-review-export/hosted-suite/suite.json")
        interpretation = archive_json(zipped, "film-review-export/interpretation.json")
        old_archive = archive_bytes(zipped, "film-review-binding/original.zip")
        old_run = archive_json(zipped, "film-review-binding/run.json")
        old_artifact = archive_json(zipped, "film-review-binding/artifact.json")
    require(hashlib.sha256(old_archive).hexdigest() == original.DIGEST, "Original failed archive differs")
    with zipfile.ZipFile(io.BytesIO(old_archive)) as zipped:
        rows = [json.loads(line) for line in archive_bytes(zipped, "hosted-suite/app-swift-testing/events.jsonl").splitlines()]
    original.verify_original(old_run, old_artifact, rows)
    phase = suite["phases"][0]
    require(suite["completed"] is True and len(suite["phases"]) == 1 and suite["sourceSHA"]
            == suite["harnessSourceSHA"] == suite["productSourceSHA"] == compiled["sourceSHA"] == PRODUCT
            and phase["events"]["startedFunctionIDs"] == phase["events"]["endedFunctionIDs"] == [original.TEST_ID]
            and phase["exitCode"] == phase["outputCapture"]["originalExitCode"] == 0
            and phase["outputCapture"]["eof"] is True and phase["diagnostic"]["status"] == "verified"
            and interpretation["status"] == "isolated-original-test-passed-cause-not-proven"
            and interpretation["coreAcceptance"] is interpretation["releaseAcceptance"] is False,
            "Isolated test did not produce its original complete diagnostic")
    original_root = executed_product_root(suite, compiled, "film-review-export", PRODUCT)
    binding = {"harnessSHA": sha, "productSHA": PRODUCT, "producerRun": PRODUCER,
               "kind": "ci-film-review-context", "selection": FILM_REVIEW_CONTEXT_FILTER,
               "expectedFunctionIDs": selected_inventory(rows), "compiled": compiled, "originalBinRoot": original_root,
               "productsArtifact": artifacts["products"], "originalFailureRun": original.RUN,
               "originalFailureDigest": original.DIGEST, "coreAcceptance": False, "releaseAcceptance": False}
    write(folder / "binding.json", binding)


def restore(folder):
    binding = json.loads((folder / "binding.json").read_text())
    require(binding["productSHA"] == command(["git", "rev-parse", "HEAD"]) == PRODUCT
            and binding["harnessSHA"] == os.environ.get("GITHUB_SHA")
            and binding["kind"] == os.environ.get("REPLAY_KIND") == "ci-film-review-context"
            and binding["selection"] == FILM_REVIEW_CONTEXT_FILTER, "Restored source binding differs")
    compiled = binding["compiled"]
    require(command(["sw_vers", "-productVersion"]) == compiled["productVersion"] == "27.0"
            and command(["sw_vers", "-buildVersion"]) == compiled["buildVersion"] == "26A428"
            and command(["xcodebuild", "-version"]) == compiled["xcode"].strip(), "Native context platform differs")
    workspace = Path(os.environ["GITHUB_WORKSPACE"]).resolve(strict=True)
    root = workspace / ".build/out/Products/Debug"
    require(str(root) == binding["originalBinRoot"], "Retained products would move from their original executed root")
    artifact = api(f"actions/artifacts/{PRODUCTS}")
    require(artifact == binding["productsArtifact"], "Retained product metadata changed")
    outer = folder / "products-original.zip"
    download(artifact, outer)
    inner = folder / "products.zip"
    with zipfile.ZipFile(outer) as zipped:
        require(zipped.namelist() == ["film-review-test-products.zip"], "Product outer archive differs")
        with zipped.open("film-review-test-products.zip") as source_file, inner.open("xb") as destination:
            for block in iter(lambda: source_file.read(1024 * 1024), b""):
                destination.write(block)
    records = manifest(inner)
    engine = {name: row for name, row in records.items() if Path(name).name == "libNexGenEngine.dylib" and row["kind"] == "file"}
    require(set(engine) == {"Debug/libNexGenEngine.dylib",
            "Debug/NexGenVideoTests.xctest/Contents/Frameworks/libNexGenEngine.dylib",
            "Debug/NexGenEngineTests.xctest/Contents/Frameworks/libNexGenEngine.dylib"}
            and len({row["sha256"] for row in engine.values()}) == 1, "Retained Engine copies differ")
    require(not root.exists() and not root.is_symlink(), "Product destination is occupied")
    require(not any(path.is_symlink() for path in (workspace / ".build", workspace / ".build/out", root.parent)),
            "Product parent contains a symbolic link")
    root.parent.mkdir(parents=True, exist_ok=True)
    require(root.parent.resolve(strict=True).is_relative_to(workspace), "Product destination escapes checkout")
    with (folder / "restore.stdout.log").open("xb") as output, (folder / "restore.stderr.log").open("xb") as error:
        subprocess.run(["ditto", "-x", "-k", str(inner), str(root.parent)], stdin=subprocess.DEVNULL,
                       stdout=output, stderr=error, check=True, timeout=120)
    verify_tree(root, records)
    for relative, expected in compiled["binaries"].items():
        actual = root / relative
        require(checksum(actual) == expected["sha256"]
                and re.findall(UUID, command(["xcrun", "dwarfdump", "--uuid", str(actual)]))
                == re.findall(UUID, expected["uuidOutput"]), "Retained native binary differs")
    write(folder / "restored-manifest.json", records)
    write(folder / "restore.json", {"status": "verified", "binRoot": str(root), "harnessSHA": binding["harnessSHA"],
          "productSHA": PRODUCT, "outerSHA256": checksum(outer), "innerSHA256": checksum(inner),
          "manifestSHA256": checksum(folder / "restored-manifest.json"), "entryCount": len(records)})


def verify(folder, evidence):
    evidence.mkdir(parents=True, exist_ok=True)
    binding, restored, records = {}, {}, []
    report = {"status": "incomplete-context", "coreAcceptance": False, "releaseAcceptance": False,
              "rootCause": "not-established", "productSHA": PRODUCT,
              "malformedMarkers": 0,
              "progressLimitation": "Native fraction is the last state emission; explicit session boundaries determine completion."}
    try:
        records, report["malformedMarkers"] = read_markers(evidence / "hosted-suite/app-swift-testing/console.log")
    except OSError as error:
        report["markerReadError"] = str(error)
    try:
        binding = json.loads((folder / "binding.json").read_text())
        restored = json.loads((folder / "restore.json").read_text())
        report["harnessSHA"] = binding["harnessSHA"]
        suite = json.loads((evidence / "hosted-suite/suite.json").read_text())
        wrapper = json.loads((evidence / "run.json").read_text())
        require(report["malformedMarkers"] == 0 and "markerReadError" not in report, "Context markers are incomplete")
        require(suite["completed"] is True and len(suite["phases"]) == 1 and suite["filter"] == FILM_REVIEW_CONTEXT_FILTER
                and suite["scope"] == "app-swift-testing" and wrapper["testExitCode"] == wrapper["effectiveExitCode"] == 0
                and wrapper["sourceSHA"] == binding["harnessSHA"] and wrapper["runID"] == os.environ.get("GITHUB_RUN_ID")
                and suite["productSourceSHA"] == PRODUCT and suite["sourceSHA"] == suite["harnessSourceSHA"]
                == binding["harnessSHA"] == os.environ.get("GITHUB_SHA"), "Context execution differs")
        phase = suite["phases"][0]
        require(phase["events"]["startedFunctionIDs"] == phase["events"]["endedFunctionIDs"]
                == binding["expectedFunctionIDs"] and phase["events"]["functionExecutions"] == suite["testExecutions"]
                == len(binding["expectedFunctionIDs"]) == 41 and phase["status"] == "verified-execution"
                and phase["exitCode"] == phase["outputCapture"]["originalExitCode"] == 0
                and phase["outputCapture"]["eof"] is True and phase["diagnostic"]["status"] == "verified",
                "The bounded original context did not complete once")
        require(executed_product_root(suite, binding["compiled"], "film-review-context", binding["harnessSHA"])
                == restored["binRoot"] and phase["diagnostic"]["memoryErrors"] == []
                and phase["diagnostic"]["sampleCount"] >= 2, "Owned context root or process observation differs")
        captures = [row for row in records if row["stage"] == "capture.begin"]
        target = [row for row in captures if any(s["originKind"] == "external" for s in row["sources"])]
        require(len(captures) == 4 and len(target) == 2 and 0.5 not in target[0]["opacities"]
                and 0.5 in target[1]["opacities"], "Original context capture identity differs")
        required = ["capture.begin", "slot.acquired", "session.prepared", "session.begin", "session.returned",
                    "post.effects", "post.review", "post.binding", "post.size", "capture.export.returned",
                    "capture.verify.returned", "capture.committed"]
        for capture in captures:
            rows = [row for row in records if row["exportID"] == capture["exportID"]]
            require([row["stage"] for row in rows if row["stage"] in required] == required, "A review capture is incomplete")
            last = [row for row in rows if row["stage"] == "heartbeat"][-1]
            ledger = next(row for row in last["ledger"] if row["instance"] == last["compositor"])
            require(ledger["started"] == ledger["frame"] == 240 and ledger["pending"] == ledger["dropped"]
                    == ledger["error"] == ledger["cancelled"] == 0, "A review request is unfinished")
        report.update(status="bounded-context-completed-cause-not-proven", functionCount=len(binding["expectedFunctionIDs"]),
                      captureCount=len(captures), targetCaptureCount=len(target))
    except (OSError, ValueError, TypeError, KeyError, IndexError, StopIteration) as error:
        report["limitation"] = str(error)
    try:
        verify_tree(Path(restored["binRoot"]), json.loads((folder / "restored-manifest.json").read_text()))
        report["retainedProductTreeUnchanged"] = True
    except (OSError, ValueError, KeyError) as error:
        report.update(status="incomplete-context", retainedProductTreeUnchanged=False, productLimitation=str(error))
    report["lastMarkers"] = {row["exportID"]: row for row in records}
    report["lastHeartbeats"] = {row["exportID"]: row for row in records if row["stage"] == "heartbeat"}
    report["markerCount"] = len(records)
    report.update(marker_summary(records))
    write(evidence / "context-markers.json", records)
    write(evidence / "context-interpretation.json", report)
    return 0 if report["status"] == "bounded-context-completed-cause-not-proven" else 1


def main():
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("action", choices=("source", "restore", "verify"))
    parser.add_argument("--metadata", required=True, type=Path)
    parser.add_argument("--evidence", type=Path)
    args = parser.parse_args()
    if args.action == "source":
        source(args.metadata)
    elif args.action == "restore":
        restore(args.metadata)
    else:
        return verify(args.metadata, args.evidence)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
