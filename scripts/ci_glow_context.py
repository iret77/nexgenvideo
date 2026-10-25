import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import time
import zipfile

from ci_builtin_blur import (api, command, digest, environment, owned_process, sample_proof, save)
from ci_builtin_blur_floor import IMAGES, member, platform
from ci_builtin_blur_preheat import build_version, collect_reports, launch, summarize
from run_macos_tests import prepare_post_mortem


BASE = "6aeb1f817befe7b14e83391de460fe4e6d9bd4ed"
MODE = "ci-glow-context"
RUN = 40232568309
RUNTIME = (12613669597, "9547bbc7a7f7aa2e9a1f2167f2885daf729d26251f503e0e04bf1514aa67b423")
PRODUCTS = (12613990274, "1e9a6c7c284e22f62f64d27a3c944b3d2b1dbe721de0b25978b1041248c0dee6")
ORIGINAL_BINARY = "abeaa09d2e6600195564e8c7dd32240603783851d42b84dcaa34010cc4dfd18b"
TEMPLATE = "scripts/ci_glow_context.swift"
TEST_SOURCE = "Tests/NexGenVideoTests/Rendering/GlowKernelTests.swift"
COMPOSITOR = "Sources/NexGenVideo/Compositing/CustomVideoCompositor.swift"
KERNEL = "Sources/NexGenVideo/Compositing/Kernels/GlowKernel.swift"
LOADER = "Sources/NexGenVideo/Compositing/Kernels/CIKernelLoader.swift"
METAL = "Metal/Glow.metal"
METAL_SCRIPT = "scripts/compile_metal_resources.sh"
PACKAGE = "Package.swift"
APP_FAILURE_SOURCE = "eed03423b5e9fcd1f6cbf66618100ddada2ed17e"
PRODUCT_INPUTS = {TEST_SOURCE, COMPOSITOR, KERNEL, LOADER, METAL, METAL_SCRIPT,
    PACKAGE, "scripts/bundle.sh", "scripts/stage_test_runtime.sh"}
CHANGED = {TEMPLATE, "scripts/ci_glow_context.py", "scripts/test_ci_glow_context.py",
    "scripts/ci_builtin_blur_preheat.py", "scripts/test_ci_builtin_blur_preheat.py", ".github/workflows/diagnostic-acceptance.yml"}
DEPENDENCIES = PRODUCT_INPUTS | {
    "scripts/ci_builtin_blur.py", "scripts/ci_builtin_blur_floor.py", "scripts/run_macos_tests.py",
    "scripts/app_host_zombie_diagnostic.py", "scripts/verify_diagnostic_candidate.py",
    "scripts/verify_swift_test_output.py", ".github/actions/setup-xcode-27/action.yml"}
APP = "NGVGlowContext.app"
BINARY = APP + "/Contents/MacOS/NGVBuiltinBlur"
LIBRARY = APP + "/Contents/Resources/Glow.metallib"
INFO = APP + "/Contents/Info.plist"
SEAL = APP + "/Contents/_CodeSignature/CodeResources"
BUNDLE_FILES = {BINARY, LIBRARY, INFO, SEAL}


def compilation_contract(root):
    package = (root / PACKAGE).read_text()
    version = re.match(r"// swift-tools-version: (\d+)\.(\d+)\n", package)
    if not version or version.groups() != ("6", "2") or any(token in package for token in
            ("swiftSettings", "swiftLanguageModes", "swiftLanguageVersions", "defaultIsolation", "plugins:", ".plugin(")):
        raise ValueError("Product Swift mode/settings or build-plugin contract changed")
    if "platforms: [.macOS(.v26)]" not in package:
        raise ValueError("Product deployment floor changed")
    script = (root / METAL_SCRIPT).read_text()
    if ('"$XCRUN" metal -c -fcikernel "$source" -o "$air"' not in script
            or '"$XCRUN" metallib -cikernel "$air" -o "$metallib"' not in script):
        raise ValueError("Production Metal compiler flags changed")
    for caller in ("scripts/bundle.sh", "scripts/stage_test_runtime.sh"):
        if '"$ROOT/scripts/compile_metal_resources.sh" "$ROOT/Metal"' not in (root / caller).read_text():
            raise ValueError("Product shader staging caller changed")
    return {"swiftFlags": ["-g", "-Onone", "-swift-version", version[1], "-D", "SWIFT_PACKAGE", "-D", "DEBUG", "-enable-testing"],
        "target": "arm64-apple-macos26.0", "packageSHA256": digest(root / PACKAGE),
        "basis": "Swift tools6.2 defaults to Swift6; no swiftSettings/language override or build plugin. Debug fixture build; original source has no conditional compilation. Metal built by bundle.sh/stage_test_runtime.sh with default xcrun, not a SwiftPM plugin.",
        "languageReference": "https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/enabledataracesafety/"}


def interpretation(result):
    if not result["valid"]:
        return "invalid"
    if not result["exposureValid"] or result["counts"]["separate"]["targetFaults"] < 7:
        return "inconclusive"
    return "shared-arm-abnormal" if result["counts"]["shared"]["abnormal"] else "association-candidate"


def resource_proof(folder, expected):
    if json.loads((folder / "resources.json").read_text()) != expected:
        raise ValueError("Process resolved different shader bytes")


def segment(source, start, end):
    if source.count(start) != 1 or source.count(end) != 1:
        raise ValueError("Production source boundary changed or is ambiguous")
    return source[source.index(start):source.index(end)]


def generated_source(root):
    tests, compositor = (root / TEST_SOURCE).read_text(), (root / COMPOSITOR).read_text()
    if tests.count("    private let n = 48\n") != 1:
        raise ValueError("Original fixture dimensions changed")
    functions = segment(tests, "    private func spot() throws -> CIImage {", "    @Test func neutralIsNoOp() throws {")
    if functions.count("    private func ") != 3 or "#expect" in functions:
        raise ValueError("Original fixture function set changed")
    context = segment(compositor, "    static let ciContext: CIContext = {", "    private let queue =")
    template = (root / TEMPLATE).read_text()
    replacements = {"    // @production-fixture-functions": functions.replace("#require(", "required("),
                    "    // @production-context-initializer": context}
    for marker, replacement in replacements.items():
        if template.count(marker) != 1:
            raise ValueError("Generated source marker changed")
        template = template.replace(marker, replacement)
    return template, {"fixtureFunctionsSHA256": hashlib.sha256(functions.encode()).hexdigest(),
        "contextInitializerSHA256": hashlib.sha256(context.encode()).hexdigest(),
        "normalization": "Only #require( becomes required(; functions otherwise unchanged",
        "scope": "First neutral Glow graph, lane readback offsets5/8; four rounds, separate contexts recreated each round, shared context retained per process"}


def verify_run(run, jobs):
    if (run.get("id") != RUN or run.get("run_attempt") != 1 or run.get("head_sha") != BASE
            or run.get("path") != ".github/workflows/diagnostic-acceptance.yml"
            or run.get("repository", {}).get("full_name") != "iret77/nexgenvideo"
            or run.get("event") != "workflow_dispatch" or run.get("actor", {}).get("login") != "iret77"
            or run.get("head_branch") != "iret77/activity-approval-layout"
            or run.get("status") != "completed" or run.get("conclusion") != "success"
            or jobs.get("total_count") != len(jobs.get("jobs", []))):
        raise ValueError("Original comparison producer differs")
    selected = {}
    for name, job_id in (("source", 121287224134), ("ci-builtin-blur-preheat-build", 121287289686),
                         ("ci-builtin-blur-preheat", 121287456513)):
        candidates = [j for j in jobs["jobs"] if j.get("name") == name]
        if len(candidates) != 1:
            raise ValueError("Original job missing or ambiguous")
        job = candidates[0]
        if (job.get("id") != job_id or job.get("run_id") != RUN or job.get("run_attempt") != 1
                or job.get("head_sha") != BASE or job.get("status") != "completed"
                or job.get("conclusion") != "success"):
            raise ValueError("Original job identity differs")
        selected[name] = job
    return selected


def download(folder, identity, name, job):
    artifact_id, checksum = identity
    artifact = api(f"actions/artifacts/{artifact_id}")
    if (artifact.get("id") != artifact_id or artifact.get("name") != name
            or artifact.get("expired") is not False or artifact.get("digest") != "sha256:" + checksum
            or artifact.get("workflow_run", {}).get("id") != RUN
            or artifact["workflow_run"].get("head_sha") != BASE
            or not job["started_at"] <= artifact["created_at"] <= artifact["updated_at"] <= job["completed_at"]):
        raise ValueError("Original artifact identity differs")
    path = folder / (name + ".zip")
    with path.open("xb") as out:
        subprocess.run(["gh", "api", f"repos/iret77/nexgenvideo/actions/artifacts/{artifact_id}/zip"],
            stdin=subprocess.DEVNULL, stdout=out, timeout=120, check=True)
    if path.stat().st_size != artifact["size_in_bytes"] or digest(path) != checksum:
        raise ValueError("Original artifact bytes differ")
    save(folder / (name + "-producer.json"), artifact)
    return path


def bind(folder):
    folder.mkdir()
    expected = {"REPLAY_KIND": MODE, "CANDIDATE_RUN": str(RUN), "CANDIDATE_SOURCE": BASE,
        "CANDIDATE_ARTIFACT": str(RUNTIME[0]), "CANDIDATE_DIGEST": RUNTIME[1]}
    if any(os.environ.get(k) != v for k, v in expected.items()) or any(os.environ.get(k)
            for k in ("PRODUCT_SHA", "PRODUCTS_ID", "PRODUCTS_DIGEST", "FAILURE_ID", "FAILURE_DIGEST")):
        raise ValueError("Exact-product comparison inputs differ")
    head = command(["git", "rev-parse", "HEAD"]).strip()
    if head != os.environ["GITHUB_SHA"] or command(["git", "status", "--porcelain"]).strip():
        raise ValueError("Dirty or unbound checkout")
    command(["git", "merge-base", "--is-ancestor", BASE, head])
    if set(command(["git", "diff", "--no-renames", "--name-only", BASE, head]).splitlines()) != CHANGED:
        raise ValueError("Source changed beyond the exact diagnostic file list")
    command(["git", "diff", "--quiet", APP_FAILURE_SOURCE, head, "--", *sorted(PRODUCT_INPUTS)])
    contract = compilation_contract(Path.cwd())
    run, jobs = api(f"actions/runs/{RUN}"), api(f"actions/runs/{RUN}/attempts/1/jobs?per_page=100")
    selected = verify_run(run, jobs)
    save(folder / "producer.json", dict(run=run, jobs=jobs))
    runtime = download(folder, RUNTIME, f"preheat-runtime-{RUN}-a1", selected["ci-builtin-blur-preheat"])
    products = download(folder, PRODUCTS, "preheat-products", selected["ci-builtin-blur-preheat-build"])
    with zipfile.ZipFile(runtime) as z:
        result = json.loads(member(z, "result.json"))
    with zipfile.ZipFile(products) as z:
        original = member(z, "NGVBuiltinBlur")
        binary_record = json.loads(member(z, "binary.json"))
    if (result.get("outcome") != "association-candidate" or not result.get("complete") or not result.get("exposureValid")
            or result.get("counts", {}).get("cold", {}).get("targetFaults") != 17
            or result.get("counts", {}).get("warm", {}).get("abnormal") != 0
            or result.get("binarySHA256") != ORIGINAL_BINARY or binary_record.get("sha256") != ORIGINAL_BINARY
            or hashlib.sha256(original).hexdigest() != ORIGINAL_BINARY
            or binary_record.get("harnessSHA") != BASE or binary_record.get("xcode") != "Xcode 27.0\nBuild version 27A266a"):
        raise ValueError("Original comparison outcome or executable differs")
    generated, fragments = generated_source(Path.cwd())
    (folder / "main.swift").write_text(generated)
    save(folder / "binding.json", {"harnessSHA": head, "baseSHA": BASE,
        "hashes": {name: digest(Path(name)) for name in sorted(CHANGED | DEPENDENCIES)},
        "workflowRun": os.environ["GITHUB_RUN_ID"], "attempt": os.environ["GITHUB_RUN_ATTEMPT"],
        "generatedSHA256": digest(folder / "main.swift"), "fragments": fragments,
        "compilation": contract, "appFailureSource": APP_FAILURE_SOURCE,
        "appProductInputsUnchanged": sorted(PRODUCT_INPUTS),
        "originalSDK": build_version(original), "diagnosticOnly": True, "productAcceptance": False})


def bound(metadata):
    binding = json.loads((metadata / "binding.json").read_text())
    if (os.environ["REPLAY_KIND"] != MODE or binding["baseSHA"] != BASE
            or binding["harnessSHA"] != os.environ["GITHUB_SHA"]
            or binding["harnessSHA"] != command(["git", "rev-parse", "HEAD"]).strip()
            or binding["workflowRun"] != os.environ["GITHUB_RUN_ID"]
            or binding["attempt"] != os.environ["GITHUB_RUN_ATTEMPT"]
            or set(binding["hashes"]) != CHANGED | DEPENDENCIES):
        raise ValueError("Source/execution binding differs")
    for name, checksum in binding["hashes"].items():
        if digest(Path(name)) != checksum:
            raise ValueError("Reviewed source bytes changed")
    generated, fragments = generated_source(Path.cwd())
    if (fragments != binding["fragments"] or hashlib.sha256(generated.encode()).hexdigest() != binding["generatedSHA256"]
            or digest(metadata / "main.swift") != binding["generatedSHA256"]):
        raise ValueError("Generated product-function bytes differ")
    if (binding["compilation"] != compilation_contract(Path.cwd()) or binding["appFailureSource"] != APP_FAILURE_SOURCE
            or binding["appProductInputsUnchanged"] != sorted(PRODUCT_INPUTS)):
        raise ValueError("Original product compilation provenance differs")
    return binding


def compile_products(folder, metadata):
    binding = bound(metadata)
    folder.mkdir()
    xcode = command(["xcodebuild", "-version"]).strip()
    if xcode != "Xcode 27.0\nBuild version 27A266a" or command(["uname", "-m"]).strip() != "arm64":
        raise ValueError("Original Xcode toolchain differs")
    if any(os.environ.get(k) for k in ("NGV_XCRUN", "SDKROOT", "MACOSX_DEPLOYMENT_TARGET", "TOOLCHAINS", "SWIFT_EXEC")):
        raise ValueError("Ambient toolchain or deployment overrides")
    contract = binding["compilation"]
    binary, library, info = (folder / name for name in (BINARY, LIBRARY, INFO))
    binary.parent.mkdir(parents=True)
    library.parent.mkdir(parents=True)
    info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "de.h5ventures.nexgenvideo.glow-context-diagnostic",
        "CFBundleExecutable": "NGVBuiltinBlur", "CFBundlePackageType": "APPL", "LSUIElement": True}))
    commands = [
        ["xcrun", "metal", "-c", "-fcikernel", METAL, "-o", str(folder / "Glow.air")],
        ["xcrun", "metallib", "-cikernel", str(folder / "Glow.air"), "-o", str(library)],
        ["xcrun", "swiftc", *contract["swiftFlags"], "-target", contract["target"],
         str(metadata / "main.swift"), KERNEL, LOADER, "-o", str(binary)],
        ["codesign", "--force", "--sign", "-", str(folder / APP)],
        ["codesign", "--verify", "--strict", str(folder / APP)],
        ["codesign", "--display", "--verbose=4", str(folder / APP)],
    ]
    for index, args in enumerate(commands):
        with (folder / f"compile-{index}.log").open("xb") as out:
            subprocess.run(args, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT, timeout=120, check=True)
    if build_version(binary.read_bytes()) != binding["originalSDK"]:
        raise ValueError("New SDK/minimum/platform differs from original")
    save(folder / "binary.json", {"harnessSHA": binding["harnessSHA"], "bindingSHA256": digest(metadata / "binding.json"),
        "generatedSHA256": binding["generatedSHA256"], "commands": commands, "xcode": xcode,
        "swift": command(["xcrun", "swiftc", "--version"]), "uuid": command(["dwarfdump", "--uuid", str(binary)]),
        "files": {name: digest(folder / name) for name in sorted(BUNDLE_FILES)},
        "diagnosticOnly": True, "productAcceptance": False})


def execute(folder, metadata, products):
    start = time.monotonic()
    deadline = start + 1200
    binding = bound(metadata)
    folder.mkdir()
    environment(os.environ)
    if any(k.startswith(("CI_", "METAL_", "_Malloc", "MALLOC_")) for k in os.environ):
        raise ValueError("Ambient rendering overrides")
    proof = json.loads((products / "binary.json").read_text())
    if (proof["harnessSHA"] != binding["harnessSHA"] or proof["bindingSHA256"] != digest(metadata / "binding.json")
            or proof["generatedSHA256"] != binding["generatedSHA256"]
            or set(proof["files"]) != BUNDLE_FILES):
        raise ValueError("Compiled product binding differs")
    for name, checksum in proof["files"].items():
        if digest(products / name) != checksum:
            raise ValueError("Transferred executable or resource bytes differ")
    binary = products / BINARY
    if build_version(binary.read_bytes()) != binding["originalSDK"]:
        raise ValueError("Transferred executable platform differs")
    binary.chmod(0o755)
    platform(folder)
    command(["codesign", "--verify", "--strict", str(products / APP)])
    outcome, calibration = owned_process(binary, folder / "calibration", "calibration", deadline)
    if outcome != "clean" or calibration.get("sampleExitCode") != 0 or calibration.get("sampleTimedOut"):
        raise ValueError("Exact-product calibration failed; no cohort started")
    sample_proof((folder / "calibration/sample.txt").read_text(), calibration["pid"], os.getpid(), images=IMAGES)
    expected_resources = {"metallibSHA256": proof["files"][LIBRARY], "bytes": (products / LIBRARY).stat().st_size}
    resource_proof(folder / "calibration", expected_resources)
    identity = prepare_post_mortem(binary)
    if identity.get("preparationError") or not identity.get("hostUUID"):
        raise ValueError("Cannot bind comparison child identity")
    children, invalid = [], []
    for index, arm in enumerate(["separate", "shared", "shared", "separate"] * 200):
        if deadline - time.monotonic() < 300:
            invalid.append({"error": "Original remaining-time guard reached"})
            break
        name = f"process-{index:03d}"
        children.append((name, launch(binary, folder / name, arm, identity, deadline)))
        try:
            resource_proof(folder / name, expected_resources)
        except (OSError, ValueError) as error:
            invalid.append({"process": name, "error": str(error)})
    if len({c["pid"] for _, c in children}) != len(children):
        invalid.append({"error": "PID reused within cohort"})
    reports = collect_reports(folder, children, deadline)
    result = summarize(folder, children, reports, invalid, arms=("separate", "shared"))
    result["outcome"] = interpretation(result)
    result.update(elapsedSeconds=time.monotonic() - start, harnessSHA=binding["harnessSHA"],
        executionRun=binding["workflowRun"], executionAttempt=binding["attempt"],
        binarySHA256=proof["files"][BINARY], metallibSHA256=proof["files"][LIBRARY],
        generatedSHA256=binding["generatedSHA256"],
        scope="Actual first neutral Glow graph with original GPU pixel-readback functions; separate versus production shared context, no warmup. Not full test-suite or product acceptance.")
    save(folder / "result.json", result)
    print(json.dumps(result))
    return 0 if result["valid"] else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("bind", "compile", "run"))
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--metadata", type=Path)
    parser.add_argument("--products", type=Path)
    args = parser.parse_args()
    try:
        if args.mode == "bind":
            bind(args.evidence.resolve())
        elif args.mode == "compile":
            compile_products(args.evidence.resolve(), args.metadata.resolve())
        else:
            raise SystemExit(execute(args.evidence.resolve(), args.metadata.resolve(), args.products.resolve()))
    except Exception as error:
        args.evidence.mkdir(parents=True, exist_ok=True)
        save(args.evidence / "failure.json", {"diagnosticOnly": True, "productAcceptance": False,
            "outcome": "invalid", "error": str(error)})
        raise
