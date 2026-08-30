// swift-tools-version: 6.0
// Fleet — LoRA-gated JSON state machine training service.
// Trains LoRA adapters through the Frigate (MLX/GPU) engine so that a small
// on-device LLM always emits JSON matching a fixed schema of semantic keys.
// A dataset is N input JSONs paired by index with N output JSONs; the schema
// template is extracted from the outputs (keys + nesting + value types) and
// enforced at decode time by masking logits against a schema automaton.
//
// Layout (one package, several library targets = "subpackages"):
//   FleetCore      JSON model, schema extraction, CID, gate automaton, mocks (Foundation only)
//   FleetStore     fleet-db: content-addressed LoRA storage + registry       (Foundation only)
//   FleetTasks     objective planning + dependency-aware deployment          (Foundation only)
//   FleetTraining  StateDataset -> Frigate LoRATrain.train -> adapter        (MLX/Frigate)
//   FleetInference schema-gated constrained decoding over a base + LoRA      (MLX/Frigate)
//   FleetService   the orchestration facade the app and CLI both drive
//   FleetConduit   Fleet as a Conduit mothership Totems dial into            (gRPC)
//   Fleet          umbrella that re-exports the above
//   FleetCLI       the `fleet` executable

import PackageDescription

// MLX-facing and legacy targets use Swift 5 language mode because Frigate's MLX
// types are not Sendable and flow through async glue. New Foundation-only targets
// such as FleetTasks stay in Swift 6 mode and receive strict concurrency checks.
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
        .library(name: "FleetStore", targets: ["FleetStore"]),
        .library(name: "FleetTasks", targets: ["FleetTasks"]),
        .library(name: "FleetTraining", targets: ["FleetTraining"]),
        .library(name: "FleetInference", targets: ["FleetInference"]),
        .library(name: "FleetService", targets: ["FleetService"]),
        .library(name: "FleetConduit", targets: ["FleetConduit"]),
        .executable(name: "fleet", targets: ["FleetCLI"]),
    ],
    dependencies: [
        .package(path: "../Frigate"),
        .package(path: "../Conduit"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "1.0.0"),
    ],
    targets: [
        .target(name: "FleetCore", swiftSettings: v5),
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
                "FleetService",
                .product(name: "Conduit", package: "Conduit"),
                .product(name: "GRPCCore", package: "grpc-swift"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
            ],
            swiftSettings: v5
        ),
        .target(name: "FleetTasks"),
        .target(
            name: "FleetInference",
            dependencies: [
                "FleetCore",
                .product(name: "Frigate", package: "Frigate"),
                .product(name: "MLXLLM", package: "Frigate"),
                .product(name: "MLXLMCommon", package: "Frigate"),
                .product(name: "MLX", package: "Frigate"),
                .product(name: "FrigateTokenizers", package: "Frigate"),
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
                .product(name: "FrigateTokenizers", package: "Frigate"),
            ],
            swiftSettings: v5
        ),
        .target(
            name: "FleetService",
            dependencies: ["FleetCore", "FleetStore", "FleetTraining", "FleetInference"],
            swiftSettings: v5
        ),
        .target(
            name: "Fleet",
            dependencies: [
                "FleetCore", "FleetStore", "FleetTasks",
                "FleetTraining", "FleetInference", "FleetService",
            ],
            swiftSettings: v5
        ),
        .executableTarget(
            name: "FleetCLI",
            dependencies: [
                "Fleet",
                "FleetConduit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: v5
        ),
        .testTarget(
            name: "FleetTests",
            dependencies: [
                "FleetCore", "FleetStore", "FleetTraining", "FleetService", "FleetConduit",
                .product(name: "Conduit", package: "Conduit"),
            ],
            swiftSettings: v5
        ),
        .testTarget(
            name: "FleetTasksTests",
            dependencies: ["FleetTasks"]
        ),
    ]
)
