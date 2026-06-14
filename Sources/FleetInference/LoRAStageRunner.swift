import FleetCore
import FleetGraph
import Foundation
import MLXLLM
import MLXLMCommon

/// Runs LoRA-conditioned generation stages against a **shared base model**.
///
/// Loads the base model once, then per stage: applies the adapter
/// (`LoRAContainer.load(into:)`), generates, and reverts it (`unload(from:)`).
/// Adapters are used purely as adapters — `fuse(with:)` (weight merging) is never
/// called. The `actor` serializes stages so they never race the shared model.
public actor LoRAStageRunner {

    private let modelId: String
    private var context: ModelContext?

    public init(modelId: String) {
        self.modelId = modelId
    }

    public func warmup() async throws {
        _ = try await loadedContext()
    }

    private func loadedContext() async throws -> ModelContext {
        if let context { return context }
        let ctx = try await loadModel(id: modelId)
        context = ctx
        return ctx
    }

    /// Apply `adapterDirectory` (if any), generate, then revert — all on the
    /// shared base model.
    private func produce(
        adapterDirectory: URL?,
        history: [ChatTurn],
        maxTokens: Int,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        do {
            let ctx = try await loadedContext()

            var adapter: LoRAContainer?
            if let adapterDirectory {
                let container = try LoRAContainer.from(directory: adapterDirectory)
                try container.load(into: ctx.model)  // dynamic adapter — not merged
                adapter = container
            }
            defer {
                adapter?.unload(from: ctx.model)  // revert so the next stage starts clean
            }

            let messages: [Chat.Message] = history.map { turn in
                switch turn.role {
                case .system: return .system(turn.text)
                case .user: return .user(turn.text)
                case .assistant: return .assistant(turn.text)
                }
            }
            let input = try await ctx.processor.prepare(input: UserInput(chat: messages))
            let stream = try MLXLMCommon.generate(
                input: input, parameters: GenerateParameters(maxTokens: maxTokens), context: ctx)
            for await item in stream {
                if Task.isCancelled { break }
                if case .chunk(let text) = item {
                    continuation.yield(text)
                }
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
}

extension LoRAStageRunner: StageExecuting {
    public nonisolated func run(
        adapterDirectory: URL?,
        history: [ChatTurn],
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.produce(
                    adapterDirectory: adapterDirectory, history: history,
                    maxTokens: maxTokens, into: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
