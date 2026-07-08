// swift-tools-version: 6.2

import PackageDescription

// NexGenEngine lives in its OWN package so the app and every loadable `.ngvpack` link
// it as a DYNAMIC PRODUCT (one shared image), not as a same-package target — a target
// dependency is statically absorbed into each consuming dynamic product, which gives the
// host and the pack two distinct `PackEntry` class objects and breaks the load-time
// `bundle.principalClass as? PackEntry.Type` cast ("entry point not found").
let package = Package(
    name: "NexGenEngine",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "NexGenEngine", type: .dynamic, targets: ["NexGenEngine"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "NexGenEngine",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
            ],
            path: "Sources/NexGenEngine"
        ),
    ]
)
