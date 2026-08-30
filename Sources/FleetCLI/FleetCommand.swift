import ArgumentParser
import Fleet
import FleetConduit
import Foundation

@main
struct FleetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fleet",
        abstract: "Train and run LoRA-gated JSON state machines.",
        discussion: """
            A dataset is N input JSON documents paired by index with N output JSON
            documents. Fleet extracts the output schema (keys, nesting, and value
            types), trains a LoRA to produce the values, and constrains decoding so
            the output always matches that schema.
            """,
        subcommands: [
            Datasets.self, Train.self, Test.self, Loras.self, Groups.self, Smoke.self,
            Serve.self,
        ]
    )
}

// MARK: - Shared helpers

private func makeService() async -> FleetService {
    let service = FleetService()
    let report = await service.start()
    if !report.isClean {
        print(
            "Reconciled store: removed \(report.removedEntries) stale entr(ies), "
                + "\(report.removedDirectories) director(ies), "
                + "\(report.removedLegacyPaths) legacy path(s).")
    }
    return service
}

private func jsonFiles(in directory: URL) throws -> [URL] {
    try FileManager.default
        .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension.lowercased() == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private func printReport(_ report: ValidationReport) {
    if let schema = report.schema {
        print("Schema: \(schema.description)")
        print("Schema id: \(String(schema.hashHex.prefix(8)))")
    }
    print("Pairs: \(report.pairCount)")
    if let cid = report.inputCID {
        print("Content id: \(cid)")
        if let generation = report.existingGeneration {
            print(
                "  ⚠︎ A LoRA already exists at this id (generation \(generation)). "
                    + "Training will replace it.")
        }
    }
    for problem in report.fileProblems {
        print("  ✗ \(problem.role.rawValue)[\(problem.index)] \(problem.fileName): \(problem.message)")
    }
    for error in report.schemaErrors {
        print("  ✗ \(error)")
    }
    for warning in report.warnings {
        print("  ! \(warning)")
    }
    print(report.isTrainable ? "Ready to train." : "Not trainable yet.")
}

// MARK: - Datasets

struct Datasets: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dataset",
        abstract: "Create, inspect, and list training sets.",
        subcommands: [Import.self, Mock.self, Validate.self, List.self, Delete.self]
    )

    struct Import: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Build a dataset from a folder of inputs and a folder of outputs.")

        @Option(name: .long, help: "Directory of input JSON files.")
        var inputs: String

        @Option(name: .long, help: "Directory of output JSON files, matched by sorted file name.")
        var outputs: String

        @Option(name: .long, help: "Name for the dataset.")
        var name: String?

        func run() async throws {
            let service = await makeService()
            let inputURLs = try jsonFiles(in: URL(fileURLWithPath: inputs))
            let outputURLs = try jsonFiles(in: URL(fileURLWithPath: outputs))
            let entry = try await service.importDataset(
                name: name ?? URL(fileURLWithPath: inputs).lastPathComponent,
                inputFiles: inputURLs,
                outputFiles: outputURLs
            )
            print("Created dataset \(entry.id) — \(entry.name)")
            printReport(try await service.validationReport(datasetId: entry.id))
            await service.shutdown()
        }
    }

    struct Mock: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Generate a deterministic mock dataset.")

        @Option(name: .long, help: "Domain: \(MockDomain.allCases.map(\.rawValue).joined(separator: ", ")).")
        var domain: String = MockDomain.weatherReport.rawValue

        @Option(name: .long, help: "How many pairs to generate.")
        var count: Int = 40

        @Option(name: .long, help: "Seed; the same seed always produces the same data.")
        var seed: UInt64 = 42

        @Option(name: .long, help: "Name for the dataset.")
        var name: String?

        func run() async throws {
            guard let selected = MockDomain(rawValue: domain) else {
                throw ValidationError(
                    "Unknown domain '\(domain)'. Choose one of: "
                        + MockDomain.allCases.map(\.rawValue).joined(separator: ", "))
            }
            let service = await makeService()
            let entry = try await service.generateMockDataset(
                domain: selected, count: count, seed: seed, name: name)
            print("Created dataset \(entry.id) — \(entry.name)")
            printReport(try await service.validationReport(datasetId: entry.id))
            await service.shutdown()
        }
    }

    struct Validate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show the extracted schema and any problems.")

        @Argument(help: "Dataset id.")
        var id: String

        func run() async throws {
            guard let uuid = UUID(uuidString: id) else {
                throw ValidationError("'\(id)' is not a dataset id.")
            }
            let service = await makeService()
            printReport(try await service.validationReport(datasetId: uuid))
            await service.shutdown()
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List datasets.")

        func run() async throws {
            let service = await makeService()
            let datasets = await service.allDatasets()
            if datasets.isEmpty {
                print("No datasets yet. Try: fleet dataset mock --domain weatherReport")
            }
            for entry in datasets {
                print("\(entry.id)  \(entry.pairCount) pairs  \(entry.name)")
                print("    schema \(entry.schemaDescription)")
                print("    cid    \(ContentID.short(entry.inputCID))")
            }
            await service.shutdown()
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a dataset.")

        @Argument(help: "Dataset id.")
        var id: String

        func run() async throws {
            guard let uuid = UUID(uuidString: id) else {
                throw ValidationError("'\(id)' is not a dataset id.")
            }
            let service = await makeService()
            await service.deleteDataset(id: uuid)
            print("Deleted \(uuid).")
            await service.shutdown()
        }
    }
}

// MARK: - Train

struct Train: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Train a LoRA from a dataset, stored under its input content id.")

    @Argument(help: "Dataset id.")
    var id: String

    @Option(name: .long, help: "Base model id.")
    var model: String = TrainingConfig.defaultModelId

    @Option(name: .long, help: "LoRA rank.")
    var rank: Int = 8

    @Option(name: .long, help: "Training iterations.")
    var iterations: Int = 200

    @Option(name: .long, help: "Batch size.")
    var batchSize: Int = 4

    func run() async throws {
        guard let uuid = UUID(uuidString: id) else {
            throw ValidationError("'\(id)' is not a dataset id.")
        }
        let service = await makeService()
        let report = try await service.validationReport(datasetId: uuid)
        guard report.isTrainable else {
            printReport(report)
            throw ExitCode.failure
        }
        if let generation = report.existingGeneration {
            print(
                "Retraining content id \(ContentID.short(report.inputCID ?? "")) "
                    + "(generation \(generation) → \(generation + 1)).")
        }

        let config = TrainingConfig(
            modelId: model, rank: rank, iterations: iterations, batchSize: batchSize)
        let stream = try await service.train(datasetId: uuid, config: config)
        for try await progress in stream {
            switch progress {
            case .preparing(let pairs, let tokens):
                print("Preparing \(pairs) pairs (longest example \(tokens) tokens)…")
            case .loadingModel(let fraction, let status):
                print("Loading model \(Int(fraction * 100))% — \(status)")
            case .step(let iteration, let loss, let itersPerSecond, _):
                print(
                    "  iter \(iteration)  loss \(String(format: "%.4f", loss))  "
                        + "\(String(format: "%.2f", itersPerSecond)) it/s")
            case .validation(let iteration, let loss, _):
                print("  iter \(iteration)  validation loss \(String(format: "%.4f", loss))")
            case .checkpointed(let iteration):
                print("  checkpoint at \(iteration)")
            case .finished(let cid, let directory):
                print("Trained LoRA \(ContentID.short(cid))")
                print("  \(directory.path)")
            }
        }
        await service.shutdown()
    }
}

// MARK: - Test

struct Test: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run one input through a stored LoRA under its schema.")

    @Option(name: .long, help: "Content id of the LoRA (full or unique prefix).")
    var cid: String

    @Option(name: .long, help: "Path to an input JSON file.")
    var input: String

    @Flag(name: .long, help: "Show which tokens the schema forced and which the model chose.")
    var trace = false

    @Option(name: .long, help: "Sampling temperature; 0 is greedy.")
    var temperature: Float = 0

    func run() async throws {
        let service = await makeService()
        let resolved = try await resolve(cid: cid, service: service)
        let value = try JSONParser.parse(contentsOf: URL(fileURLWithPath: input))
        let result = try await service.complete(
            cid: resolved,
            input: value,
            options: GateOptions(temperature: temperature, captureTrace: trace)
        )
        print(result.rawText)
        if trace {
            print("")
            print("Trace — \(result.trace.count) tokens, "
                + "\(Int((result.forcedFraction * 100).rounded()))% forced by the schema:")
            for step in result.trace {
                let marker = step.mode == .forced ? "▮" : "▯"
                let escaped = step.text.replacingOccurrences(of: "\n", with: "\\n")
                print(
                    "  \(marker) \(escaped.padding(toLength: max(12, escaped.count), withPad: " ", startingAt: 0))"
                        + "  \(step.statePath)"
                        + (step.mode == .free ? "  (\(step.admissibleCount) allowed)" : ""))
            }
        }
        await service.shutdown()
    }
}

private func resolve(cid: String, service: FleetService) async throws -> String {
    if await service.lora(cid: cid) != nil { return cid }
    let matches = await service.allLoRAs().filter { $0.cid.hasPrefix(cid) }
    guard let match = matches.first else {
        throw ValidationError("No LoRA matching '\(cid)'.")
    }
    guard matches.count == 1 else {
        throw ValidationError("'\(cid)' matches \(matches.count) LoRAs; use a longer prefix.")
    }
    return match.cid
}

// MARK: - Library

struct Loras: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "loras",
        abstract: "Inspect and organize trained LoRAs.",
        subcommands: [List.self, Label.self, Add.self, Remove.self, Delete.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List stored LoRAs.")

        func run() async throws {
            let service = await makeService()
            let loras = await service.allLoRAs()
            if loras.isEmpty { print("No LoRAs yet. Train one with: fleet train <dataset-id>") }
            for entry in loras {
                let groups = await service.groups(forLoRA: entry.cid).map(\.label)
                print("\(entry.shortCID)  gen \(entry.generation)  \(entry.displayName)")
                print("    model  \(entry.modelId)")
                print("    schema \(entry.schemaDescription)")
                if !groups.isEmpty { print("    groups \(groups.joined(separator: ", "))") }
            }
            await service.shutdown()
        }
    }

    struct Label: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Name a LoRA.")

        @Argument(help: "Content id or unique prefix.") var cid: String
        @Argument(help: "The label.") var label: String

        func run() async throws {
            let service = await makeService()
            let resolved = try await resolve(cid: cid, service: service)
            await service.setLabel(cid: resolved, label: label)
            print("Labelled \(ContentID.short(resolved)) '\(label)'.")
            await service.shutdown()
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add a LoRA to a group.")

        @Argument(help: "Content id or unique prefix.") var cid: String
        @Option(name: .long, help: "Group id.") var group: String

        func run() async throws {
            let service = await makeService()
            let resolved = try await resolve(cid: cid, service: service)
            await service.add(cid: resolved, toGroup: group)
            print("Added \(ContentID.short(resolved)) to \(group).")
            await service.shutdown()
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a LoRA from a group.")

        @Argument(help: "Content id or unique prefix.") var cid: String
        @Option(name: .long, help: "Group id.") var group: String

        func run() async throws {
            let service = await makeService()
            let resolved = try await resolve(cid: cid, service: service)
            await service.remove(cid: resolved, fromGroup: group)
            print("Removed \(ContentID.short(resolved)) from \(group).")
            await service.shutdown()
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a LoRA and its weights.")

        @Argument(help: "Content id or unique prefix.") var cid: String

        func run() async throws {
            let service = await makeService()
            let resolved = try await resolve(cid: cid, service: service)
            await service.deleteLoRA(cid: resolved)
            print("Deleted \(ContentID.short(resolved)).")
            await service.shutdown()
        }
    }
}

struct Groups: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "groups",
        abstract: "Organize LoRAs into groups.",
        subcommands: [Create.self, List.self, Delete.self]
    )

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a group.")

        @Argument(help: "Group label.") var label: String

        func run() async throws {
            let service = await makeService()
            let group = await service.createGroup(label: label)
            print("Created group \(group.id) — \(group.label)")
            await service.shutdown()
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List groups.")

        func run() async throws {
            let service = await makeService()
            for group in await service.groups() {
                let page = await service.loras(inGroup: group.id, limit: 1000)
                print("\(group.id)  \(group.label)  (\(page.items.count) LoRAs)")
            }
            await service.shutdown()
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a group.")

        @Argument(help: "Group id.") var id: String

        func run() async throws {
            let service = await makeService()
            await service.deleteGroup(id: id)
            print("Deleted group \(id).")
            await service.shutdown()
        }
    }
}

// MARK: - Smoke

struct Smoke: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "End-to-end check: generate mock data, train briefly, then test the gate.")

    @Option(name: .long, help: "Domain to exercise.")
    var domain: String = MockDomain.weatherReport.rawValue

    @Option(name: .long, help: "Pairs to generate.")
    var count: Int = 20

    @Option(name: .long, help: "Training iterations (small on purpose).")
    var iterations: Int = 50

    @Option(name: .long, help: "Base model id.")
    var model: String = TrainingConfig.defaultModelId

    func run() async throws {
        guard let selected = MockDomain(rawValue: domain) else {
            throw ValidationError("Unknown domain '\(domain)'.")
        }
        let service = await makeService()

        print("1. Generating \(count) \(selected.title) pairs (seed 42)…")
        let entry = try await service.generateMockDataset(
            domain: selected, count: count, seed: 42, name: "smoke · \(selected.rawValue)")
        let report = try await service.validationReport(datasetId: entry.id)
        printReport(report)
        guard report.isTrainable else { throw ExitCode.failure }

        print("\n2. Training \(iterations) iterations…")
        let stream = try await service.train(
            datasetId: entry.id,
            config: TrainingConfig(modelId: model, iterations: iterations)
        )
        var cid: String?
        for try await progress in stream {
            switch progress {
            case .step(let iteration, let loss, _, _):
                print("  iter \(iteration)  loss \(String(format: "%.4f", loss))")
            case .finished(let published, _):
                cid = published
            default:
                break
            }
        }
        guard let cid else {
            print("Training produced no adapter.")
            throw ExitCode.failure
        }
        print("  trained \(ContentID.short(cid))")

        print("\n3. Testing the gate on a held-out input…")
        // Generating past the training count gives an input the LoRA has not seen.
        let heldOut = MockDatasetGenerator.generate(
            domain: selected, count: count + 1, seed: 42).last!
        let result = try await service.complete(cid: cid, input: heldOut.input)
        print("  input:    \(JSONCanonical.serialize(heldOut.input))")
        print("  produced: \(result.rawText)")
        print("  expected: \(JSONCanonical.serialize(heldOut.output))")

        guard let schema = await service.schema(cid: cid) else {
            print("The stored LoRA has no schema.")
            throw ExitCode.failure
        }
        let errors = SchemaExtractor.validate(result.json, against: schema)
        guard errors.isEmpty else {
            print("✗ The gated output did not match the schema: \(errors)")
            throw ExitCode.failure
        }
        print(
            "\n✓ Output matched the schema. "
                + "\(Int((result.forcedFraction * 100).rounded()))% of tokens were forced.")
        await service.shutdown()
    }
}

// MARK: - Serve

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Host FleetLoRA gRPC plus HTTP /health for Mary to dial.")

    @Option(name: .long, help: "HTTP health port.")
    var port: Int = FleetLoRAServer.defaultHTTPPort

    @Option(name: .long, help: "gRPC FleetLoRA port.")
    var grpcPort: Int = FleetLoRAServer.defaultGRPCPort

    @Option(name: .long, help: "Local Totem host for ExportCorpus pull.")
    var totemHost: String = "127.0.0.1"

    @Option(name: .long, help: "Local Totem gRPC port.")
    var totemGrpcPort: Int = 9090

    func run() async throws {
        print("fleet serve — health http://127.0.0.1:\(port)/health  gRPC \(grpcPort)")
        try await FleetLoRAServer.serve(
            httpPort: port,
            grpcPort: grpcPort,
            totemHost: totemHost,
            totemPort: totemGrpcPort)
    }
}
