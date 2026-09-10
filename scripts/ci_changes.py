#!/usr/bin/env python3
import argparse
import os
import subprocess
from fnmatch import fnmatchcase


BUNDLE_PATHS = (
    'Package.swift',
    'Package.resolved',
    'Engine/**',
    'Metal/**',
    'Sources/MusicvideoPlugin/**',
    'Sources/FixtureFictionPlugin/**',
    'Sources/NexGenVideo/Agent/Intake/HardStepManifest.swift',
    'Sources/NexGenVideo/Agent/Pipeline/**',
    'Sources/NexGenVideo/Agent/Tools/ToolDefinitions.swift',
    'Sources/NexGenVideo/Agent/Tools/ToolExecutor*.swift',
    'Sources/NexGenVideo/App/AppDelegate.swift',
    'Sources/NexGenVideo/App/Changelog.swift',
    'Sources/NexGenVideo/App/AppRelaunch.swift',
    'Sources/NexGenVideo/App/AppRelaunchSelfTest.swift',
    'Sources/NexGenVideo/App/ExampleAudioAnalysisSelfTest.swift',
    'Sources/NexGenVideo/App/main.swift',
    'Sources/NexGenVideo/Utilities/HangDiagnostic*.swift',
    'Sources/NexGenVideo/Project/HomeView.swift',
    'Sources/NexGenVideo/Project/UpdateOverlay.swift',
    'Sources/NexGenVideo/Inspector/Cockpit/NativeCockpitReader.swift',
    'Sources/NexGenVideo/Inspector/Cockpit/NativeGateWriter.swift',
    'Sources/NexGenVideo/Plugins/**',
    'Sources/NexGenVideo/Resources/**',
    'scripts/**',
    'plugins/**',
    '.github/actions/cache-swiftpm-dependencies/**',
    '.github/actions/setup-xcode-27/**',
    '.github/workflows/bundle.yml',
    '.github/workflows/ci.yml',
    'Sources/HangDiagnostics/**',
    'Sources/HangStackSampler/**',
    'Sources/NexGenVideoDiagnostics/**',
)
UI_PATHS = (
    "docs/ui/**",
    "scripts/render_agent_chat_spec.py",
    "scripts/test_render_agent_chat_spec.py",
    ".github/workflows/ci.yml",
)


def classify(paths):
    if not paths:
        return dict(build_required=True, bundle_required=True, ui_required=True)
    bundle = any(fnmatchcase(path, pattern) for path in paths for pattern in BUNDLE_PATHS)
    ui = any(fnmatchcase(path, pattern) for path in paths for pattern in UI_PATHS)
    build = bundle or any(not (path.startswith("docs/") or ("/" not in path and path.endswith(".md"))) for path in paths)
    return dict(build_required=build, bundle_required=bundle, ui_required=ui)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="")
    parser.add_argument("--head", default="")
    parser.add_argument("--metadata-verified", choices=("true", "false"), default="false")
    args = parser.parse_args()
    if args.metadata_verified == "true":
        plan = dict(build_required=False, bundle_required=False, ui_required=False)
    elif args.base and args.head:
        paths = subprocess.check_output([
            "git", "diff", "--no-renames", "--name-only", "-z", f"{args.base}...{args.head}"
        ]).decode().split("\0")
        plan = classify([path for path in paths if path])
    else:
        plan = classify([])
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        for key, required in plan.items():
            print(f"{key}={str(required).lower()}", file=output)
    print("CI plan: " + ", ".join(f"{key}={str(value).lower()}" for key, value in plan.items()))


if __name__ == "__main__":
    main()
