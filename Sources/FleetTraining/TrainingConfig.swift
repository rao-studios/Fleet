import Foundation

/// Knobs for a LoRA training run.
///
/// Plain values mirroring what Frigate's `LoRATrain` and `LoRAConfiguration`
/// expect, so callers (the app, the CLI, tests) never touch MLX types. There is
/// no output directory here on purpose: a LoRA's location is derived from the
/// content id of its training inputs, which the store owns.
public struct TrainingConfig: Sendable, Codable, Equatable {

    /// HuggingFace id of the base model to adapt. Must conform to `LoRAModel`
    /// (the default Qwen3 does).
    public var modelId: String
    public var rank: Int
    public var scale: Float
    /// How many trailing layers get adapters.
    public var numLayers: Int
    public var iterations: Int
    public var batchSize: Int
    public var learningRate: Float
    /// Fraction of pairs held out for validation, clamped to `0...0.9`.
    public var validationFraction: Double
    public var stepsPerReport: Int
    public var stepsPerEval: Int

    public init(
        modelId: String = TrainingConfig.defaultModelId,
        rank: Int = 8,
        scale: Float = 20.0,
        numLayers: Int = 16,
        iterations: Int = 200,
        batchSize: Int = 4,
        learningRate: Float = 1e-5,
        validationFraction: Double = 0.1,
        stepsPerReport: Int = 10,
        stepsPerEval: Int = 50
    ) {
        self.modelId = modelId
        self.rank = rank
        self.scale = scale
        self.numLayers = numLayers
        self.iterations = iterations
        self.batchSize = batchSize
        self.learningRate = learningRate
        self.validationFraction = validationFraction
        self.stepsPerReport = stepsPerReport
        self.stepsPerEval = stepsPerEval
    }

    public static let defaultModelId = "mlx-community/Qwen3-0.6B-4bit"
}

/// Progress from a training run, in Fleet's own vocabulary.
///
/// Frigate's `LoRATrain.Progress` deliberately does not appear here: letting it
/// through would drag MLXLLM into every target that merely observes training,
/// including the app's view models.
public enum TrainingProgress: Sendable {
    /// Emitted once before the model loads.
    case preparing(pairCount: Int, longestExampleTokens: Int)
    /// The base model is being downloaded or read into memory.
    case loadingModel(fraction: Double, status: String)
    case step(
        iteration: Int,
        trainLoss: Float,
        iterationsPerSecond: Double,
        tokensPerSecond: Double
    )
    case validation(iteration: Int, loss: Float, seconds: Double)
    case checkpointed(iteration: Int)
    /// Weights and metadata are written; the caller publishes them under `cid`.
    case finished(cid: String, adapterDirectory: URL)
}

public enum TrainingError: Error, Sendable, CustomStringConvertible {
    case emptyDataset
    case cancelled

    public var description: String {
        switch self {
        case .emptyDataset:
            return "The dataset has no pairs to train on."
        case .cancelled:
            return "Training was cancelled."
        }
    }
}
