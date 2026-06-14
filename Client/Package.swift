// swift-tools-version: 6.0
// FleetClient — a macOS app to drive Fleet's fine-tune loop interactively:
// download a model, build a dataset (notes / Q&A), fine-tune, then A/B chat the
// base vs the fine-tuned LoRA to test memory recall.
//
// Standalone SwiftPM executable (mirrors Totem/Client). It depends on the Fleet
// package next door and calls it in-process (no server).

import PackageDescription

let package = Package(
    name: "FleetClient",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "FleetClient",
            dependencies: [
                .product(name: "Fleet", package: "Fleet"),
            ],
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
