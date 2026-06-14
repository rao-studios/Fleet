import Foundation
import MLXLLM
import MLXLMCommon

/// Thin wrapper over Frigate's model loading so callers (e.g. the client app)
/// don't need to depend on MLX modules directly.
public enum ModelLoader {

    /// Download (if needed) and warm a HuggingFace MLX model, reporting progress
    /// as `(fractionCompleted, status)`. Throws if the id is invalid/unavailable.
    public static func warm(
        id: String,
        onProgress: @Sendable @escaping (Double, String) -> Void
    ) async throws {
        _ = try await loadModelContainer(id: id) { progress in
            onProgress(progress.fractionCompleted, progress.localizedDescription ?? "Working…")
        }
    }
}
