import FleetCore
import Foundation
import MLX
import MLXLMCommon
import MLXRandom

/// One decoding step, as the debugger shows it.
public struct GateTraceStep: Sendable, Codable, Identifiable {
    public enum Mode: String, Sendable, Codable {
        /// The schema fixed this text; the model had no say.
        case forced
        /// A value position: the model chose, from the admissible tokens only.
        case free
    }

    public struct Alternative: Sendable, Codable {
        public var text: String
        public var logProbability: Float

        public init(text: String, logProbability: Float) {
            self.text = text
            self.logProbability = logProbability
        }
    }

    public var index: Int
    public var tokenId: Int
    public var text: String
    public var mode: Mode
    /// Where in the schema this token landed, e.g. `$.tags[] (string)`.
    public var statePath: String
    /// How many tokens the mask allowed here (1 when forced).
    public var admissibleCount: Int
    /// The model's own top candidates, for comparing what it wanted against what
    /// the gate permitted.
    public var alternatives: [Alternative]

    public var id: Int { index }
}

/// Options for a gated generation.
public struct GateOptions: Sendable {
    /// 0 means greedy.
    public var temperature: Float
    public var maxTokens: Int
    /// Recording alternatives costs a sort per step; off by default outside the
    /// playground.
    public var captureTrace: Bool
    public var alternativesPerStep: Int

    public init(
        temperature: Float = 0,
        maxTokens: Int = 512,
        captureTrace: Bool = true,
        alternativesPerStep: Int = 5
    ) {
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.captureTrace = captureTrace
        self.alternativesPerStep = alternativesPerStep
    }
}

/// Mutable decoding state shared with the sampler.
///
/// `LogitSampler` is a protocol on value types and `TokenIterator` copies the
/// sampler it is given, so the state that has to survive across steps lives here,
/// behind a reference.
final class GateBox: @unchecked Sendable {
    let gate: JSONGate
    let options: GateOptions
    let eosTokenId: Int

    var state: SchemaAutomaton.State
    var trace: [GateTraceStep] = []
    var text = String()
    var finished = false
    var failure: Error?

    /// Additive masks (0 for allowed, a large negative for banned) keyed by
    /// automaton state. String bodies revisit the same state on every character,
    /// so this is close to a one-time cost per slot.
    private var maskCache: [SchemaAutomaton.State: MLXArray] = [:]

    init(gate: JSONGate, options: GateOptions, eosTokenId: Int) {
        self.gate = gate
        self.options = options
        self.eosTokenId = eosTokenId
        self.state = gate.initialState
    }

    func mask(for state: SchemaAutomaton.State, allowed: [Int], width: Int) -> MLXArray {
        if let cached = maskCache[state], cached.dim(-1) == width { return cached }
        var values = [Float](repeating: -1e9, count: width)
        for id in allowed where id < width {
            values[id] = 0
        }
        let mask = MLXArray(values)
        maskCache[state] = mask
        return mask
    }
}

/// The sampler that makes the output conform.
///
/// Structural positions are emitted without consulting the model at all, and
/// value positions are sampled from a masked distribution. A model that has never
/// seen this schema still cannot misspell a key; a well-trained LoRA supplies
/// values that belong.
struct JSONGatedSampler: LogitSampler {

    let box: GateBox
    private let randomState = MLXRandom.RandomState()

    init(box: GateBox) {
        self.box = box
    }

    func sample(logits: MLXArray) -> MLXArray {
        if box.finished { return MLXArray([box.eosTokenId]) }

        let width = logits.dim(-1)
        var flat = logits
        if flat.ndim > 1 { flat = flat.reshaped([-1, width])[0] }
        if flat.dtype == .bfloat16 { flat = flat.asType(.float32) }

        switch box.gate.decision(for: box.state) {
        case .complete:
            box.finished = true
            return MLXArray([box.eosTokenId])

        case .stuck(let path):
            box.failure = GateError.stuck(path: path)
            box.finished = true
            return MLXArray([box.eosTokenId])

        case .forced(let tokenId, let text):
            record(
                tokenId: tokenId,
                text: text,
                mode: .forced,
                admissibleCount: 1,
                logits: flat
            )
            advance(text: text, tokenId: tokenId)
            return MLXArray([tokenId])

        case .free(let allowed):
            let mask = box.mask(for: box.state, allowed: allowed, width: width)
            let masked = flat + mask
            let tokenId: Int
            if box.options.temperature <= 0 {
                tokenId = argMax(masked, axis: -1).item(Int.self)
            } else {
                tokenId = withRandomState(randomState) {
                    categorical(masked * (1 / box.options.temperature)).item(Int.self)
                }
            }
            guard let text = box.gate.text(of: tokenId) else {
                box.failure = GateError.inadmissibleToken(
                    tokenId: tokenId, path: box.gate.path(of: box.state))
                box.finished = true
                return MLXArray([box.eosTokenId])
            }
            record(
                tokenId: tokenId,
                text: text,
                mode: .free,
                admissibleCount: allowed.count,
                logits: masked
            )
            advance(text: text, tokenId: tokenId)
            return MLXArray([tokenId])
        }
    }

    private func advance(text: String, tokenId: Int) {
        guard let next = box.gate.consume(box.state, text: text) else {
            box.failure = GateError.inadmissibleToken(
                tokenId: tokenId, path: box.gate.path(of: box.state))
            box.finished = true
            return
        }
        box.state = next
        box.text += text
        if box.gate.isAccepting(next) { box.finished = true }
    }

    private func record(
        tokenId: Int,
        text: String,
        mode: GateTraceStep.Mode,
        admissibleCount: Int,
        logits: MLXArray
    ) {
        guard box.options.captureTrace else { return }
        box.trace.append(
            GateTraceStep(
                index: box.trace.count,
                tokenId: tokenId,
                text: text,
                mode: mode,
                statePath: box.gate.path(of: box.state),
                admissibleCount: admissibleCount,
                alternatives: topAlternatives(logits: logits)
            ))
    }

    /// The model's highest-scoring candidates at this step. On a forced step these
    /// show what the model *wanted* — the most useful signal in the debugger, since
    /// a LoRA that has learned the schema should be picking the forced token anyway.
    private func topAlternatives(logits: MLXArray) -> [GateTraceStep.Alternative] {
        let count = box.options.alternativesPerStep
        guard count > 0 else { return [] }
        let probabilities = softmax(logits, axis: -1)
        let order = argSort(probabilities, axis: -1)
        let width = probabilities.dim(-1)
        var results: [GateTraceStep.Alternative] = []
        for offset in 0 ..< min(count, width) {
            let id = order[width - 1 - offset].item(Int.self)
            let probability = probabilities[id].item(Float.self)
            let text = box.gate.text(of: id) ?? "<special>"
            results.append(
                .init(text: text, logProbability: probability > 0 ? log(probability) : -1e9))
        }
        return results
    }
}
