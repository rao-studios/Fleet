// swift-tools-version: 6.0
// Fleet — Swift Agent Harness.
// Coordinates contexts from a folder of mixed media, aligns them into a single
// data structure, and off-loads a LoRA fine-tuning job onto a small on-device
// LLM through the Frigate (MLX/GPU) engine.
//
// Layout (one package, several library targets = "subpackages"):
//   FleetCore      core data structure + coordination protocols   (Foundation only)
//   FleetMedia     concrete media decoders + the routing registry  (Foundation only)
//   FleetAudio     speech-to-text transcribers                     (Apple Speech, guarded)
//   FleetVision    image captioning over Frigate MLXVLM            (Apple only, guarded)
//   FleetStore     fleet-db: UUID-keyed dataset + adapter storage   (Foundation only)
//   FleetTraining  Corpus -> Frigate LoRATrain.train -> adapter    (MLX/Frigate)
//   FleetInference adapter-aware chat (base + LoRA)                (MLX/Frigate)
//   Fleet          umbrella that re-exports the above
//   FleetCLI       the `fleet finetune ...` executable

import PackageDescription

// Build against the Swift 5 language mode to keep strict-concurrency checking off
// while still using the modern manifest API. Frigate's MLX types are not Sendable
// and flow through our async glue; v5 mode keeps that ergonomic.
let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Fleet",
    platforms: [
        .macOS("15.0"),  // Conduit (gRPC) requires macOS 15; FleetConduit needs it
        .iOS(.v17),
    ],
    products: [
        .library(name: "Fleet", targets: ["Fleet"]),
        .library(name: "FleetCore", targets: ["FleetCore"]),
        .library(name: "FleetMedia", targets: ["FleetMedia"]),
        .library(name: "FleetStore", targets: ["FleetStore"]),
        .library(name: "FleetGraph", targets: ["FleetGraph"]),
        .library(name: "FleetTraining", targets: ["FleetTraining"]),
        .library(name: "FleetInference", targets: ["FleetInference"]),
        .library(name: "FleetConduit", targets: ["FleetConduit"]),
        .executable(name: "fleet", targets: ["FleetCLI"]),
    ],
    dependencies: [
        .package(path: "../Frigate"),
        .package(path: "../Conduit"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(name: "FleetCore", swiftSettings: v5),
        .target(
            name: "FleetAudio",
            dependencies: ["FleetCore"],
            swiftSettings: v5
        ),
        .target(
            name: "FleetVision",
            dependencies: [
                "FleetCore",
                .product(name: "MLXVLM", package: "Frigate"),
                .product(name: "MLXLMCommon", package: "Frigate"),
                .product(name: "MLX", package: "Frigate"),
            ],
            swiftSettings: v5
        ),
        .target(
            name: "FleetMedia",
            dependencies: ["FleetCore"],
            swiftSettings: v5
        ),
        .target(
            name: "FleetStore",
            dependencies: ["FleetCore"],
            swiftSettings: v5
        ),
        .target(
            name: "FleetConduit",
            dependencies: [
                "FleetCore",
                "FleetStore",
                .product(name: "Conduit", package: "Conduit"),
            ],
            swiftSettings: v5
        ),
        .target(
            name: "FleetGraph",
            dependencies: ["FleetCore", "FleetStore"],
            swiftSettings: v5
        ),
        .target(
            name: "FleetInference",
            dependencies: [
                "FleetCore",
                "FleetGraph",
                .product(name: "Frigate", package: "Frigate"),
                .product(name: "MLXLLM", package: "Frigate"),
                .product(name: "MLXLMCommon", package: "Frigate"),
                .product(name: "MLX", package: "Frigate"),
                .product(name: "Tokenizers", package: "Frigate"),
            ],
            swiftSettings: v5
        ),
        .target(
            name: "FleetTraining",
            dependencies: [
                "FleetCore",
                .product(name: "MLXLLM", package: "Frigate"),
                .product(name: "MLXLMCommon", package: "Frigate"),
                .product(name: "MLXOptimizers", package: "Frigate"),
                .product(name: "MLX", package: "Frigate"),
                .product(name: "Tokenizers", package: "Frigate"),
            ],
            swiftSettings: v5
        ),
        .target(
            name: "Fleet",
            dependencies: [
                "FleetCore", "FleetMedia", "FleetAudio", "FleetVision",
                "FleetStore", "FleetGraph", "FleetTraining", "FleetInference",
            ],
            swiftSettings: v5
        ),
        .executableTarget(
            name: "FleetCLI",
            dependencies: [
                "Fleet",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: v5
        ),
        .testTarget(
            name: "FleetTests",
            dependencies: [
                "FleetCore", "FleetMedia", "FleetStore", "FleetGraph", "FleetConduit",
                .product(name: "Conduit", package: "Conduit"),
            ],
            swiftSettings: v5
        ),
    ]
)
