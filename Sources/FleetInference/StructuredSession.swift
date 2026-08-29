import FleetCore
import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// The result of a gated generation.
public struct GatedResult: Sendable {
    /// The parsed output. Valid by construction — the gate could not have
    /// completed otherwise.
    public var json: FleetCore.JSONValue
    public var rawText: String
    public var trace: [GateTraceStep]
    public var promptTokenCount: Int

    public init(json: FleetCore.JSONValue, rawText: String, trace: [GateTraceStep], promptTokenCount: Int) {
        self.json = json
        self.rawText = rawText
        self.trace = trace
        self.promptTokenCount = promptTokenCount
    }

    /// The share of tokens the schema fixed rather than the model choosing —
    /// a quick read on how much of the output the LoRA is actually responsible for.
    public var forcedFraction: Double {
        guard !trace.isEmpty else { return 0 }
        let forced = trace.filter { $0.mode == .forced }.count
        return Double(forced) / Double(trace.count)
    }
}

public enum GateEvent: Sendable {
    case token(GateTraceStep)
    case finished(GatedResult)
}

/// Runs a base model plus an optional LoRA under schema constraints.
///
/// An `actor`, so the non-`Sendable` `ModelContext` it holds never escapes, and
/// two generations can't race on the same model weights.
public actor StructuredSession {

    private let modelId: String
    private let adapterDirectory: URL?
    private var context: ModelContext?
    private var vocabulary: TokenizerVocabulary?
    private var gates: [String: JSONGate] = [:]

    public init(modelId: String, adapterDirectory: URL? = nil) {
        self.modelId = modelId
        self.adapterDirectory = adapterDirectory
    }

    /// Load the model, adapter, and token table ahead of the first request.
    public func warmup(schema: SchemaTemplate? = nil) async throws {
        let ctx = try await loadedContext()
        if let schema {
            _ = try gate(for: schema, context: ctx)
        }
    }

    /// Generate the output for one input, constrained to `schema`.
    public func generate(
        input: FleetCore.JSONValue,
        schema: SchemaTemplate,
        options: GateOptions = GateOptions()
    ) -> AsyncThrowingStream<GateEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await run(
                        input: input,
                        schema: schema,
                        options: options,
                        onStep: { continuation.yield(.token($0)) }
                    )
                    continuation.yield(.finished(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Generate without streaming.
    public func complete(
        input: FleetCore.JSONValue,
        schema: SchemaTemplate,
        options: GateOptions = GateOptions()
    ) async throws -> GatedResult {
        try await run(input: input, schema: schema, options: options, onStep: { _ in })
    }

    private func run(
        input: FleetCore.JSONValue,
        schema: SchemaTemplate,
        options: GateOptions,
        onStep: @escaping @Sendable (GateTraceStep) -> Void
    ) async throws -> GatedResult {
        let ctx = try await loadedContext()
        let gate = try gate(for: schema, context: ctx)

        // Encode the raw prompt rather than applying a chat template: the LoRA was
        // trained on exactly this text, and the gate's forced literals assume the
        // model resumes at the same place.
        let promptText = PromptBuilder.prompt(input: input)
        let promptTokens = ctx.tokenizer.encode(text: promptText, addSpecialTokens: false)
        let lmInput = LMInput(tokens: MLXArray(promptTokens))

        let box = GateBox(
            gate: gate,
            options: options,
            eosTokenId: ctx.tokenizer.eosTokenId ?? 0
        )
        let sampler = JSONGatedSampler(box: box)

        var iterator = try TokenIterator(
            input: lmInput,
            model: ctx.model,
            processor: nil,
            sampler: sampler,
            maxTokens: options.maxTokens
        )

        var emitted = 0
        while let token = iterator.next() {
            if Task.isCancelled { throw CancellationError() }
            if let failure = box.failure { throw failure }
            // The sampler emits EOS once the schema is satisfied.
            if box.finished || token == box.eosTokenId { break }
            while emitted < box.trace.count {
                onStep(box.trace[emitted])
                emitted += 1
            }
        }
        if let failure = box.failure { throw failure }
        while emitted < box.trace.count {
            onStep(box.trace[emitted])
            emitted += 1
        }

        guard gate.isAccepting(box.state) else {
            throw GateError.tokenLimitReached(produced: box.text)
        }

        do {
            let json = try JSONParser.parse(box.text)
            return GatedResult(
                json: json,
                rawText: box.text,
                trace: box.trace,
                promptTokenCount: promptTokens.count
            )
        } catch {
            // The gate accepted but the text does not parse: the automaton and the
            // serializer disagree, which is a bug worth surfacing rather than
            // papering over.
            throw GateError.producedInvalidJSON(text: box.text, underlying: "\(error)")
        }
    }

    // MARK: - Loading

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

    /// Gates are cached per schema: building one walks the whole token table into
    /// a trie, which is far too expensive to repeat per request.
    private func gate(for schema: SchemaTemplate, context ctx: ModelContext) throws -> JSONGate {
        if let existing = gates[schema.hashHex] { return existing }
        let vocabulary = try loadedVocabulary(context: ctx)
        let gate = JSONGate(schema: schema, vocabulary: vocabulary)
        gates[schema.hashHex] = gate
        return gate
    }

    private func loadedVocabulary(context ctx: ModelContext) throws -> TokenizerVocabulary {
        if let vocabulary { return vocabulary }
        // The tokenizer exposes no vocabulary size, so it is probed from the
        // model's own logit width — the only number that matters for masking.
        let width = try logitWidth(context: ctx)
        let built = TokenizerVocabulary.shared(
            for: modelId, tokenizer: ctx.tokenizer, size: width)
        vocabulary = built
        return built
    }

    private func logitWidth(context ctx: ModelContext) throws -> Int {
        let tokens = MLXArray([ctx.tokenizer.eosTokenId ?? 0])[.newAxis, 0...]
        let output = ctx.model(LMInput.Text(tokens: tokens), cache: nil, state: nil)
        return output.logits.dim(-1)
    }
}
