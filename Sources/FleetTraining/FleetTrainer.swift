import FleetCore
import Foundation
import MLXLLM
import MLXLMCommon
import MLXOptimizers

/// Events emitted while a fine-tuning job runs.
public enum TrainingEvent: Sendable {
    /// A progress update from Frigate's training loop.
    case progress(LoRATrain.Progress)
    /// Training finished; the adapter has been written to `adapterDirectory`.
    case finished(adapterDirectory: URL)
}

/// Drives a LoRA fine-tune end-to-end: format the corpus, load the base model
/// through Frigate, attach LoRA, run Frigate's training loop, and package the
/// resulting adapter so it can be reloaded with `LoRAContainer.from(directory:)`.
///
/// Fleet owns no training math — it coordinates Frigate's `LoRATrain.train`.
public struct FleetTrainer {

    public let config: FineTuningConfig

    public init(config: FineTuningConfig) {
        self.config = config
    }

    /// Run the job, streaming progress. The heavy synchronous training loop runs
    /// inside the stream's task; cancelling the stream stops training.
    public func run(corpus: Corpus) -> AsyncThrowingStream<TrainingEvent, Error> {
        AsyncThrowingStream { continuation in
            // Detached so the heavy synchronous training loop never runs on the
            // caller's actor (e.g. the app's main actor).
            let task = Task.detached(priority: .userInitiated) { [self] in
                do {
                    try await train(corpus: corpus, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func train(
        corpus: Corpus,
        continuation: AsyncThrowingStream<TrainingEvent, Error>.Continuation
    ) async throws {
        let formatter = DatasetFormatter()
        let split = formatter.split(corpus, validationFraction: config.validationFraction)
        let train = split.train

        guard !train.isEmpty else { throw FleetTrainingError.emptyCorpus }
        // Frigate's evaluate() divides by token count; an empty validation set
        // would yield NaN, so fall back to the training set.
        let valid = split.valid.isEmpty ? train : split.valid

        // Write the JSONL the run actually used, for inspection.
        try formatter.writeJSONL(train: train, valid: valid, to: config.outputAdapterDir)

        // Load base model + tokenizer through Frigate.
        let context = try await loadModel(id: config.modelId)

        // Attach LoRA layers in place (freezes base weights).
        let loraConfiguration = LoRAConfiguration(
            numLayers: config.numLayers,
            fineTuneType: .lora,
            loraParameters: .init(rank: config.rank, scale: config.scale)
        )
        _ = try LoRAContainer.from(model: context.model, configuration: loraConfiguration)

        // Run Frigate's training loop.
        let optimizer = Adam(learningRate: config.learningRate)
        let safeIterations = max(1, config.iterations)
        let parameters = LoRATrain.Parameters(
            batchSize: config.batchSize,
            iterations: safeIterations,
            stepsPerReport: min(max(1, config.stepsPerReport), safeIterations),
            stepsPerEval: min(max(1, config.stepsPerEval), safeIterations),
            saveEvery: safeIterations,
            adapterURL: nil
        )

        try LoRATrain.train(
            model: context.model,
            train: train,
            validate: valid,
            optimizer: optimizer,
            tokenizer: context.tokenizer,
            parameters: parameters
        ) { progress in
            continuation.yield(.progress(progress))
            return Task.isCancelled ? .stop : .more
        }

        // Package the adapter so LoRAContainer.from(directory:) can reload it.
        let directory = config.outputAdapterDir
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let weightsURL = directory.appendingPathComponent("adapters.safetensors")
        try LoRATrain.saveLoRAWeights(model: context.model, url: weightsURL)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let configURL = directory.appendingPathComponent("adapter_config.json")
        try encoder.encode(loraConfiguration).write(to: configURL)

        continuation.yield(.finished(adapterDirectory: directory))
    }
}
