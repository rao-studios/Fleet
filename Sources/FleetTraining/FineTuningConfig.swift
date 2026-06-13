import Foundation

/// Knobs for a LoRA fine-tuning job.
///
/// Mirrors the parameters Frigate's `LoRATrain` and `LoRAConfiguration` expect,
/// but exposes them as plain values so callers (the CLI, tests) don't touch MLX
/// types directly.
public struct FineTuningConfig: Sendable {

    /// HuggingFace model id of the base model to adapt. Must conform to `LoRAModel`
    /// (the default Qwen3 does).
    public var modelId: String

    /// LoRA rank.
    public var rank: Int

    /// LoRA scale.
    public var scale: Float

    /// Number of trailing layers to attach adapters to.
    public var numLayers: Int

    /// Training iterations.
    public var iterations: Int

    /// Batch size (prompts per step).
    public var batchSize: Int

    /// Optimizer learning rate.
    public var learningRate: Float

    /// Fraction of examples held out for validation (clamped to 0...0.9).
    public var validationFraction: Double

    /// Steps between training-loss reports.
    public var stepsPerReport: Int

    /// Steps between validation passes.
    public var stepsPerEval: Int

    /// Directory to write the adapter into (`adapter_config.json` + `adapters.safetensors`).
    public var outputAdapterDir: URL

    public init(
        outputAdapterDir: URL,
        modelId: String = "mlx-community/Qwen3-0.6B-4bit",
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
        self.outputAdapterDir = outputAdapterDir
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
}

public enum FleetTrainingError: Error, CustomStringConvertible {
    case emptyCorpus

    public var description: String {
        switch self {
        case .emptyCorpus:
            return "No text examples were produced from the provided context. "
                + "Check that the folder contains decodable text/markdown/code/PDF, "
                + "or enable --vision/--audio for media files."
        }
    }
}
