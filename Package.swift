// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NexGenVideo",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "NexGenVideo", targets: ["NexGenVideo"]),
        // The first loadable pack — built as a dynamic library, then assembled +
        // signed into `musicvideo.ngvpack` by the release workflow. NOT a
        // dependency of the app: it ships OUTSIDE the DMG and loads at runtime.
        .library(name: "MusicvideoPlugin", type: .dynamic, targets: ["MusicvideoPlugin"]),
    ],
    dependencies: [
        // NexGenEngine is its OWN package (Engine/) so the app AND the pack link its
        // DYNAMIC product — one shared `Pack`/`PackEntry` class, embedded once in
        // Contents/Frameworks. A same-package target dependency would statically absorb
        // the engine into both binaries and break the cross-bundle PackEntry cast.
        .package(path: "Engine"),
        .package(url: "https://github.com/dmrschmidt/DSWaveformImage", from: "14.2.2"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "8.40.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"),
        .package(url: "https://github.com/airbnb/lottie-ios", from: "4.6.1"),
        // ONNX Runtime (ObjC/C bindings via a checksummed pod-archive binaryTarget) — the on-device
        // inference runtime behind the app's Demucs (stem separation) and Beat This! (neural downbeat)
        // implementations of the engine's audio-ML seams.
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.19.2"),
    ],
    targets: [
        .executableTarget(
            name: "NexGenVideo",
            dependencies: [
                .product(name: "DSWaveformImage", package: "DSWaveformImage"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Sentry", package: "sentry-cocoa"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Lottie", package: "lottie-ios"),
                .product(name: "NexGenEngine", package: "Engine"),
                "whisper",
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            path: "Sources/NexGenVideo",
            exclude: [
                "Resources/Info.plist",
                "Resources/AppIcon.icns",
                "Resources/AppIcon.png",
            ],
            resources: [
                .copy("Resources/Fonts"),
                .copy("Resources/MCPB/nexgen.mcpb"),
                .copy("Resources/Images"),
                .copy("Resources/Changelog"),
            ],
            plugins: ["MetalCIKernelPlugin"]
        ),
        .plugin(name: "MetalCIKernelPlugin", capability: .buildTool()),
        // Vendored whisper.cpp (macOS/arm64 slice) — on-device speech recognition behind the app's
        // AudioTranscribing seam. See Vendor/README.md for provenance + update steps.
        .binaryTarget(name: "whisper", path: "Vendor/whisper.xcframework"),
        // The musicvideo format pack. Links the shared NexGenEngine dynamic product
        // (from the Engine package) so its `Pack`/`PackEntry` metadata is IDENTICAL to
        // the host's. Its knowledge (pattern library, phase docs, badge) ships as target
        // resources, assembled into the `.ngvpack` alongside the signed dylib.
        .target(
            name: "MusicvideoPlugin",
            dependencies: [.product(name: "NexGenEngine", package: "Engine")],
            path: "Sources/MusicvideoPlugin",
            resources: [
                .copy("Resources/MusicvideoPack"),
            ]
        ),
        .testTarget(
            name: "NexGenVideoTests",
            dependencies: [
                "NexGenVideo",
                .product(name: "NexGenEngine", package: "Engine"),
                "MusicvideoPlugin",
            ],
            path: "Tests/NexGenVideoTests"
        ),
        // Depends on MusicvideoPlugin too: the pack is no longer compiled into the
        // engine, so the pack-specific tests link it and register it explicitly.
        .testTarget(
            name: "NexGenEngineTests",
            dependencies: [
                .product(name: "NexGenEngine", package: "Engine"),
                "MusicvideoPlugin",
            ],
            path: "Tests/NexGenEngineTests",
            resources: [
                .copy("Fixtures"),
                .copy("Goldens"),
            ]
        ),
    ]
)
