import FleetCore
import Foundation
import MLXLLM
import MLXLMCommon
import MLXOptimizers

/// Trains a LoRA to produce the values of a fixed JSON schema.
///
/// Fleet owns no training math — this coordinates Frigate's `LoRATrain.train`.
/// What it does own is the text the model learns from: every pair becomes one
/// `PromptBuilder` example, so the tokens seen here are the tokens the decoding
/// gate will later force and mask against.
public struct StateTrainer {

    public let config: TrainingConfig

    public init(config: TrainingConfig) {
        self.config = config
    }

    /// Run the job into `stagingDirectory`, streaming progress.
    ///
    /// The caller publishes the staging directory under the dataset's content id
    /// once the stream finishes, so a failed or cancelled run never lands in the
    /// library.
    public func run(
        dataset: StateDataset,
        stagingDirectory: URL
    ) -> AsyncThrowingStream<TrainingProgress, Error> {
        AsyncThrowingStream { continuation in
            // Detached: the training loop is synchronous and long-running, and must
            // never occupy the caller's actor (the app's main actor, typically).
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await train(
                        dataset: dataset,
                        stagingDirectory: stagingDirectory,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func train(
        dataset: StateDataset,
        stagingDirectory: URL,
        continuation: AsyncThrowingStream<TrainingProgress, Error>.Continuation
    ) async throws {
        let examples = dataset.trainingTexts
        guard !examples.isEmpty else { throw TrainingError.emptyDataset }

        let split = Self.split(examples, validationFraction: config.validationFraction)
        let trainSet = split.train
        // Frigate's evaluate() divides by token count, so an empty validation set
        // would produce NaN. Reusing the training set is the honest fallback.
        let validSet = split.valid.isEmpty ? trainSet : split.valid

        try FileManager.default.createDirectory(
            at: stagingDirectory, withIntermediateDirectories: true)

        let context = try await loadModel(id: config.modelId)

        // A rough token estimate for the warning the UI shows; Frigate's batch
        // iterator warns past 2048 and truncation would silently damage examples.
        let longest = examples.map { context.tokenizer.encode(text: $0).count }.max() ?? 0
        continuation.yield(
            .preparing(pairCount: dataset.pairs.count, longestExampleTokens: longest))

        let loraConfiguration = LoRAConfiguration(
            numLayers: config.numLayers,
            fineTuneType: .lora,
            loraParameters: .init(rank: config.rank, scale: config.scale)
        )
        // Attaches LoRA layers in place and freezes the base weights.
        _ = try LoRAContainer.from(model: context.model, configuration: loraConfiguration)

        let optimizer = Adam(learningRate: config.learningRate)
        let iterations = max(1, config.iterations)
        let parameters = LoRATrain.Parameters(
            batchSize: min(config.batchSize, trainSet.count),
            iterations: iterations,
            stepsPerReport: min(max(1, config.stepsPerReport), iterations),
            stepsPerEval: min(max(1, config.stepsPerEval), iterations),
            saveEvery: iterations,
            adapterURL: nil
        )

        try LoRATrain.train(
            model: context.model,
            train: trainSet,
            validate: validSet,
            optimizer: optimizer,
            tokenizer: context.tokenizer,
            parameters: parameters
        ) { progress in
            switch progress {
            case .train(let iteration, let loss, let iterationsPerSecond, let tokensPerSecond):
                continuation.yield(
                    .step(
                        iteration: iteration,
                        trainLoss: loss,
                        iterationsPerSecond: iterationsPerSecond,
                        tokensPerSecond: tokensPerSecond
                    ))
            case .validation(let iteration, let loss, let time):
                continuation.yield(
                    .validation(iteration: iteration, loss: loss, seconds: time))
            case .save(let iteration, _):
                continuation.yield(.checkpointed(iteration: iteration))
            }
            // The only way cancellation reaches the synchronous MLX loop.
            return Task.isCancelled ? .stop : .more
        }

        if Task.isCancelled { throw TrainingError.cancelled }

        try writeArtifacts(
            dataset: dataset,
            loraConfiguration: loraConfiguration,
            model: context.model,
            into: stagingDirectory
        )

        continuation.yield(
            .finished(cid: dataset.inputCID, adapterDirectory: stagingDirectory))
    }

    /// Write everything that makes the stored LoRA self-describing.
    private func writeArtifacts(
        dataset: StateDataset,
        loraConfiguration: LoRAConfiguration,
        model: any LanguageModel,
        into directory: URL
    ) throws {
        try LoRATrain.saveLoRAWeights(
            model: model,
            url: directory.appendingPathComponent(LoRAArtifactName.weights)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        try encoder.encode(loraConfiguration)
            .write(to: directory.appendingPathComponent(LoRAArtifactName.adapterConfig))
        try encoder.encode(dataset.schema)
            .write(to: directory.appendingPathComponent(LoRAArtifactName.schema))

        // The CID hashes inputs only, so the snapshot is the record of which
        // outputs this generation was actually trained on.
        try encoder.encode(TrainingSnapshot(dataset: dataset, config: config))
            .write(to: directory.appendingPathComponent(LoRAArtifactName.datasetSnapshot))
        try encoder.encode(AttributionManifest(dataset: dataset))
            .write(to: directory.appendingPathComponent(LoRAArtifactName.manifest))
    }

    /// Deterministic split: every nth example is held out, so the same dataset
    /// always trains and validates on the same halves.
    static func split(
        _ examples: [String],
        validationFraction: Double
    ) -> (train: [String], valid: [String]) {
        let fraction = min(max(validationFraction, 0), 0.9)
        let validCount = Int((Double(examples.count) * fraction).rounded(.down))
        guard validCount > 0, examples.count > 1 else { return (examples, []) }
        let stride = max(2, examples.count / validCount)
        var train: [String] = []
        var valid: [String] = []
        for (index, example) in examples.enumerated() {
            if index % stride == 0 && valid.count < validCount {
                valid.append(example)
            } else {
                train.append(example)
            }
        }
        return (train.isEmpty ? examples : train, valid)
    }
}

/// Artifact file names, duplicated from FleetStore's `LoRAArtifact` so the
/// training target does not depend on the store.
enum LoRAArtifactName {
    static let weights = "adapters.safetensors"
    static let adapterConfig = "adapter_config.json"
    static let schema = "schema.json"
    static let datasetSnapshot = "dataset-snapshot.json"
    static let manifest = "manifest.json"
}

/// What this generation of a LoRA was trained on.
public struct TrainingSnapshot: Codable, Sendable {
    public var datasetId: UUID
    public var datasetName: String
    public var promptVersion: Int
    public var config: TrainingConfig
    public var schema: SchemaTemplate
    public var pairs: [JSONPair]
    public var trainedAt: Date

    public init(dataset: StateDataset, config: TrainingConfig) {
        self.datasetId = dataset.id
        self.datasetName = dataset.name
        self.promptVersion = PromptBuilder.version
        self.config = config
        self.schema = dataset.schema
        self.pairs = dataset.pairs
        self.trainedAt = .now
    }
}

/// Who contributed the text this LoRA learned from.
///
/// Shares are proportional to the characters each source contributed to the
/// *outputs* — the values the model was actually taught to produce.
public struct AttributionManifest: Codable, Sendable {
    public struct Share: Codable, Sendable, Identifiable {
        public var key: String
        public var characters: Int
        public var share: Double

        public var id: String { key }
    }

    public var datasetId: UUID
    public var pairCount: Int
    public var totalCharacters: Int
    public var shares: [Share]
    public var generatedAt: Date

    public init(dataset: StateDataset) {
        var byKey: [String: Int] = [:]
        var total = 0
        for pair in dataset.pairs {
            let characters = JSONCanonical.serialize(pair.output).count
            total += characters
            let key = pair.provenance?.attributionKey ?? "unattributed"
            byKey[key, default: 0] += characters
        }
        self.datasetId = dataset.id
        self.pairCount = dataset.pairs.count
        self.totalCharacters = total
        self.shares = byKey
            .map { Share(key: $0.key, characters: $0.value,
                         share: total > 0 ? Double($0.value) / Double(total) : 0) }
            .sorted { $0.characters > $1.characters }
        self.generatedAt = .now
    }

    public var summaryLine: String {
        let parts = shares.map { "\($0.key) \(Int(($0.share * 100).rounded()))%" }
        return "Attribution · " + parts.joined(separator: " · ")
    }
}
