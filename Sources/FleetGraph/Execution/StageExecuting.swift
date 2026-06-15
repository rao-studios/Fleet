import FleetCore
import Foundation

/// Runs one LoRA-conditioned generation stage.
///
/// `FleetGraph` is MLX-free; the real implementation (`LoRAStageRunner`) lives in
/// `FleetInference` and conforms to this protocol. Tests inject a lightweight fake
/// so `GraphRunner` can be exercised without loading a model.
public protocol StageExecuting: Sendable {
    /// Apply `adapterDirectory` (if any) to a shared base model, generate a reply
    /// to `history`, then revert the adapter. Streams output text.
    func run(
        adapterDirectory: URL?,
        history: [ChatTurn],
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error>
}
