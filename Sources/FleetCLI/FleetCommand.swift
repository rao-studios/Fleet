import ArgumentParser
import Fleet
import Foundation

@main
struct FleetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fleet",
        abstract: "Swift Agent Harness — coordinate folder media into an MLX LoRA fine-tune.",
        subcommands: [Finetune.self, Chat.self]
    )
}

struct Chat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Compare a base model vs a fine-tuned LoRA adapter on one prompt."
    )

    @Option(name: .long, help: "Base model id.")
    var model = "mlx-community/Qwen3-0.6B-4bit"

    @Option(name: .long, help: "Directory of a trained adapter (adapter_config.json + adapters.safetensors).")
    var adapter: String

    @Option(name: .long, help: "Prompt to ask both models.")
    var prompt: String

    @Option(name: .long, help: "Max tokens to generate.")
    var maxTokens = 128

    func run() async throws {
        let history = [ChatTurn(role: .user, text: prompt)]
        let base = ChatSession(modelId: model, adapterDirectory: nil)
        let tuned = ChatSession(modelId: model, adapterDirectory: URL(fileURLWithPath: adapter))

        print("\n── BASE MODEL ──")
        for try await chunk in await base.reply(history: history, maxTokens: maxTokens) {
            print(chunk, terminator: "")
        }
        print("\n\n── FINE-TUNED ──")
        for try await chunk in await tuned.reply(history: history, maxTokens: maxTokens) {
            print(chunk, terminator: "")
        }
        print("")
    }
}

struct Finetune: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Fine-tune a small on-device LLM from a folder of mixed media."
    )

    @Option(name: .shortAndLong, help: "Folder (or single file) of media to use as context.")
    var input: String

    @Option(name: .shortAndLong, help: "Directory to write the LoRA adapter into.")
    var output: String

    @Option(name: .long, help: "Base model id (must support LoRA; default Qwen3 does).")
    var model = "mlx-community/Qwen3-0.6B-4bit"

    @Option(name: .long, help: "Training iterations.")
    var iterations = 200

    @Option(name: .long, help: "LoRA rank.")
    var rank = 8

    @Option(name: .long, help: "Number of trailing layers to adapt.")
    var layers = 16

    @Option(name: .long, help: "Batch size.")
    var batchSize = 4

    @Flag(name: .long, inversion: .prefixedNo, help: "Caption images with a VLM (Apple only).")
    var vision = false

    @Option(name: .long, help: "VLM model id used for image captioning.")
    var visionModel = "mlx-community/SmolVLM-Instruct-4bit"

    @Flag(name: .long, inversion: .prefixedNo, help: "Transcribe audio files (Apple only).")
    var audio = false

    func run() async throws {
        let inputURL = URL(fileURLWithPath: input)
        let outputURL = URL(fileURLWithPath: output, isDirectory: true)

        // Wire optional inference backends into media decoders.
        let imageCaptioning: ImageCaptioning?
        if vision {
            let captioner = ImageCaptioner(modelId: visionModel)
            imageCaptioning = { try await captioner.caption($0) }
        } else {
            imageCaptioning = nil
        }

        let audioTranscribing: AudioTranscribing?
        if audio {
            let transcriber = SpeechTranscriber()
            audioTranscribing = { try await transcriber.transcribe($0) }
        } else {
            audioTranscribing = nil
        }

        let registry = DecoderRegistry.standard(
            imageCaptioning: imageCaptioning,
            audioTranscribing: audioTranscribing
        )

        print("Scanning \(inputURL.path) …")
        let provider = FolderContextProvider(root: inputURL, registry: registry)
        let fragments = try await provider.fragments()
        let corpus = Corpus(fragments)
        let usable = corpus.textExamples.count
        print("Decoded \(fragments.count) fragments (\(usable) with usable text).")

        guard usable > 0 else {
            throw ValidationError(
                "No usable text was produced. Add text/markdown/code/PDF files, "
                    + "or enable --vision/--audio for media.")
        }

        var config = FineTuningConfig(outputAdapterDir: outputURL)
        config.modelId = model
        config.iterations = iterations
        config.rank = rank
        config.numLayers = layers
        config.batchSize = batchSize

        print("Fine-tuning \(model) for \(iterations) iterations (rank \(rank)) …")
        let trainer = FleetTrainer(config: config)
        for try await event in trainer.run(corpus: corpus) {
            switch event {
            case .progress(let progress):
                print(progress)
            case .finished(let directory):
                print("✓ Adapter written to \(directory.path)")
            }
        }
    }
}
