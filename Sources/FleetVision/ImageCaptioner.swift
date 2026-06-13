import Foundation

#if canImport(CoreImage)
import MLX
import MLXLMCommon
import MLXVLM

/// Captions images into text using a vision-language model through Frigate.
///
/// Apple-only: Frigate excludes its `MLXVLM` factory and model files on Linux
/// (they use CoreImage/AVFoundation), so this real implementation is gated on
/// `canImport(CoreImage)`. The model container is loaded once and reused.
public actor ImageCaptioner {

    private let modelId: String
    private let prompt: String
    private let maxTokens: Int
    private var container: ModelContainer?

    public init(
        modelId: String = "mlx-community/SmolVLM-Instruct-4bit",
        prompt: String = "Describe this image in detail.",
        maxTokens: Int = 256
    ) {
        self.modelId = modelId
        self.prompt = prompt
        self.maxTokens = maxTokens
    }

    /// Produce a caption for the image at `imageURL`.
    public func caption(_ imageURL: URL) async throws -> String {
        let container = try await loadedContainer()
        let userInput = UserInput(prompt: prompt, images: [.url(imageURL)])
        let input = try await container.prepare(input: userInput)
        let stream = try await container.generate(
            input: input,
            parameters: GenerateParameters(maxTokens: maxTokens)
        )

        var caption = ""
        for await item in stream {
            if case .chunk(let text) = item {
                caption += text
            }
        }
        return caption.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadedContainer() async throws -> ModelContainer {
        if let container { return container }
        let loaded = try await VLMModelFactory.shared.loadContainer(
            configuration: ModelConfiguration(id: modelId)
        )
        container = loaded
        return loaded
    }
}

#else

/// Linux / non-Apple fallback: Frigate's VLM stack is unavailable, so captioning
/// is a graceful no-op. The signature matches the Apple implementation so callers
/// compile unchanged.
public actor ImageCaptioner {
    public init(
        modelId: String = "mlx-community/SmolVLM-Instruct-4bit",
        prompt: String = "Describe this image in detail.",
        maxTokens: Int = 256
    ) {}

    public func caption(_ imageURL: URL) async throws -> String { "" }
}

#endif
