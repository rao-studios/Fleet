import FleetCore
import Foundation
import MLXLLM
import MLXLMCommon

/// A streaming chat session against a base model, optionally with a LoRA adapter
/// applied.
///
/// This is the inference path Frigate's `FrigateLLM` lacks: when
/// `adapterDirectory` is set, the base model is loaded and the adapter is applied
/// via `LoRAContainer.from(directory:).load(into:)`. The A/B chat in the client
/// runs two sessions — one with `nil` (base) and one with the adapter dir
/// (fine-tuned) — against the same prompt.
///
/// An `actor`, so the non-`Sendable` `ModelContext` it holds never escapes.
public actor ChatSession {

    private let modelId: String
    private let adapterDirectory: URL?
    private var context: ModelContext?

    public init(modelId: String, adapterDirectory: URL? = nil) {
        self.modelId = modelId
        self.adapterDirectory = adapterDirectory
    }

    /// Load the model (and adapter) ahead of the first message.
    public func warmup() async throws {
        _ = try await loadedContext()
    }

    /// Stream the assistant's reply to the given conversation.
    public func reply(history: [ChatTurn], maxTokens: Int = 512) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let ctx = try await loadedContext()
                    let messages: [Chat.Message] = history.map { turn in
                        switch turn.role {
                        case .system: return .system(turn.text)
                        case .user: return .user(turn.text)
                        case .assistant: return .assistant(turn.text)
                        }
                    }
                    let input = try await ctx.processor.prepare(input: UserInput(chat: messages))
                    let stream = try MLXLMCommon.generate(
                        input: input,
                        parameters: GenerateParameters(maxTokens: maxTokens),
                        context: ctx
                    )
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
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func loadedContext() async throws -> ModelContext {
        if let context { return context }
        let ctx = try await loadModel(id: modelId)
        if let adapterDirectory {
            let container = try LoRAContainer.from(directory: adapterDirectory)
            try container.load(into: ctx.model)
        }
        context = ctx
        return ctx
    }
}
