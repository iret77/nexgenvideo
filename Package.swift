// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NexGenVideo",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "NexGenVideo", targets: ["NexGenVideo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/dmrschmidt/DSWaveformImage", from: "14.2.2"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "8.40.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"),
        .package(url: "https://github.com/airbnb/lottie-ios", from: "4.6.1"),
        .package(url: "https://github.com/jpsim/Yams", from: "5.0.0"),
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
                "NexGenEngine",
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
        .target(
            name: "NexGenEngine",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/NexGenEngine",
            resources: [
                .copy("Resources/MusicvideoPack"),
            ]
        ),
        .testTarget(
            name: "NexGenVideoTests",
            dependencies: ["NexGenVideo", "NexGenEngine"],
            path: "Tests/NexGenVideoTests"
        ),
        .testTarget(
            name: "NexGenEngineTests",
            dependencies: ["NexGenEngine"],
            path: "Tests/NexGenEngineTests",
            resources: [
                .copy("Fixtures"),
                .copy("Goldens"),
            ]
        ),
    ]
)
