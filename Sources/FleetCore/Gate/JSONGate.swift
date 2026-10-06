import Foundation

/// What the gate says to do at one decoding step.
public enum GateDecision: Sendable, Equatable {
    /// The schema fixes this text, so no sampling happens: emit this token.
    case forced(tokenId: Int, text: String)
    /// A value position: the model picks, but only from these token ids.
    case free(allowed: [Int])
    /// The document is complete; the caller should emit EOS and stop.
    case complete
    /// No token can continue — the vocabulary cannot express what the schema
    /// requires here. Surfaced as an error rather than silently producing
    /// invalid JSON.
    case stuck(path: String)
}

/// Turns a schema into per-step token decisions.
///
/// This is the whole "LoRA-gated state machine" idea in one type: structure comes
/// from the schema and is *forced*, values come from the LoRA and are *masked*.
/// A model that has never seen the schema still cannot emit a wrong key, and a
/// well-trained LoRA supplies values that fit.
public final class JSONGate: @unchecked Sendable {

    public let automaton: SchemaAutomaton
    public let trie: TokenTrie
    private let vocabulary: any TokenVocabulary

    /// Allowed-token sets keyed by automaton state. Slot states repeat constantly
    /// (every character of a string body is the same state), so this hits often.
    private var allowedCache: [SchemaAutomaton.State: [Int]] = [:]
    private let cacheLock = NSLock()

    public init(schema: SchemaTemplate, vocabulary: any TokenVocabulary) {
        self.automaton = SchemaAutomaton(schema: schema)
        self.vocabulary = vocabulary
        self.trie = TokenTrie(vocabulary: vocabulary)
    }

    public init(schema: SchemaTemplate, vocabulary: any TokenVocabulary, trie: TokenTrie) {
        self.automaton = SchemaAutomaton(schema: schema)
        self.vocabulary = vocabulary
        self.trie = trie
    }

    public var initialState: SchemaAutomaton.State { automaton.initialState }

    public func isAccepting(_ state: SchemaAutomaton.State) -> Bool {
        automaton.isAccepting(state)
    }

    public func path(of state: SchemaAutomaton.State) -> String {
        automaton.path(of: state)
    }

    /// The decision for the current state.
    public func decision(for state: SchemaAutomaton.State) -> GateDecision {
        if automaton.isAccepting(state) { return .complete }

        // A literal run is fully determined, so emit it greedily rather than
        // masking: the longest token matching the remaining literal text.
        if case .literal(let text) = automaton.segments[state.segment] {
            let remaining = String(text.dropFirst(state.literalOffset))
            if let match = trie.longestPrefix(of: remaining) {
                return .forced(tokenId: match.tokenId, text: match.consumed)
            }
            return .stuck(path: automaton.path(of: state))
        }

        let allowed = cachedAllowed(for: state)
        if allowed.isEmpty { return .stuck(path: automaton.path(of: state)) }
        return .free(allowed: allowed)
    }

    private func cachedAllowed(for state: SchemaAutomaton.State) -> [Int] {
        cacheLock.lock()
        if let cached = allowedCache[state] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let computed = trie.admissibleTokens(from: state, in: automaton)

        cacheLock.lock()
        allowedCache[state] = computed
        cacheLock.unlock()
        return computed
    }

    /// The surface text of a token, or `nil` if it can never be emitted.
    public func text(of tokenId: Int) -> String? {
        vocabulary.text(of: tokenId)
    }

    /// Advance the machine by a chosen token. `nil` means the token was not
    /// admissible (a bug in the caller — the mask should have prevented it).
    public func consume(_ state: SchemaAutomaton.State, tokenId: Int) -> SchemaAutomaton.State? {
        guard let text = vocabulary.text(of: tokenId) else { return nil }
        return consume(state, text: text)
    }

    public func consume(_ state: SchemaAutomaton.State, text: String) -> SchemaAutomaton.State? {
        var current = state
        for scalar in text.unicodeScalars {
            guard let next = automaton.advance(current, scalar) else { return nil }
            current = next
        }
        return current
    }

    /// Drive the gate with a scoring function — the pure-Swift equivalent of what
    /// the MLX sampler does, and how the gate is tested without a model.
    ///
    /// `choose` receives the admissible ids and returns the one to emit.
    public func run(
        maximumTokens: Int = 512,
        choose: (_ allowed: [Int], _ state: SchemaAutomaton.State) -> Int
    ) throws -> (text: String, tokenIds: [Int]) {
        var state = initialState
        var text = String()
        var ids: [Int] = []
        for _ in 0 ..< maximumTokens {
            switch decision(for: state) {
            case .complete:
                return (text, ids)
            case .stuck(let path):
                throw GateError.stuck(path: path)
            case .forced(let tokenId, let emitted):
                guard let next = consume(state, text: emitted) else {
                    throw GateError.stuck(path: automaton.path(of: state))
                }
                state = next
                text += emitted
                ids.append(tokenId)
            case .free(let allowed):
                let tokenId = choose(allowed, state)
                guard let emitted = vocabulary.text(of: tokenId),
                    let next = consume(state, text: emitted)
                else {
                    throw GateError.inadmissibleToken(
                        tokenId: tokenId, path: automaton.path(of: state))
                }
                state = next
                text += emitted
                ids.append(tokenId)
            }
        }
        throw GateError.tokenLimitReached(produced: text)
    }
}

public enum GateError: Error, Sendable, CustomStringConvertible {
    case stuck(path: String)
    case inadmissibleToken(tokenId: Int, path: String)
    case tokenLimitReached(produced: String)
    /// The gate ran to acceptance but the text did not parse — an invariant
    /// violation worth surfacing loudly, since it means the automaton and the
    /// serializer disagree.
    case producedInvalidJSON(text: String, underlying: String)

    public var description: String {
        switch self {
        case .stuck(let path):
            return "The gate has no admissible token at \(path). "
                + "The tokenizer cannot express the schema's literal text here."
        case .inadmissibleToken(let tokenId, let path):
            return "Token \(tokenId) was sampled at \(path) but is not admissible there."
        case .tokenLimitReached(let produced):
            return "Hit the token limit before the schema completed. Produced: \(produced)"
        case .producedInvalidJSON(let text, let underlying):
            return "The gate completed but its output did not parse (\(underlying)): \(text)"
        }
    }
}
