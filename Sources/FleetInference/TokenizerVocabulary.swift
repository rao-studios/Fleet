import FleetCore
import Foundation
import Tokenizers

/// Adapts a real tokenizer to the gate's ``TokenVocabulary``.
///
/// Building this means decoding every id once, which is the only way to know what
/// text a token actually contributes — `convertIdToToken` returns the *internal*
/// spelling (byte-level BPE markers and all), not the characters that reach the
/// output. Two classes of token are excluded so the gate can never pick them:
/// specials (which decode to nothing once skipped) and byte fragments that are
/// not valid UTF-8 on their own (they decode containing U+FFFD).
public struct TokenizerVocabulary: TokenVocabulary {

    private let texts: [String?]

    public var count: Int { texts.count }

    public func text(of tokenId: Int) -> String? {
        guard tokenId >= 0 && tokenId < texts.count else { return nil }
        return texts[tokenId]
    }

    /// - Parameter size: the vocabulary size, taken from the model's logit width.
    public init(tokenizer: any Tokenizer, size: Int) {
        var texts = [String?](repeating: nil, count: size)
        let replacement = "\u{FFFD}"
        for id in 0 ..< size {
            let decoded = tokenizer.decode(tokens: [id])
            guard !decoded.isEmpty, !decoded.contains(replacement) else { continue }
            // A special token decodes to its literal spelling but vanishes when
            // specials are skipped — that difference is how we spot one without
            // needing the tokenizer's private special-token set.
            let withoutSpecials = tokenizer.decode(tokens: [id], skipSpecialTokens: true)
            guard !withoutSpecials.isEmpty else { continue }
            texts[id] = decoded
        }
        self.texts = texts
    }

    /// Build directly from a table (tests, or a cached vocabulary).
    public init(texts: [String?]) {
        self.texts = texts
    }

    // MARK: - Caching

    /// Materializing the table costs one decode per id, so it is cached per model
    /// for the lifetime of the process. Gate construction then costs only the trie.
    private static let cache = Cache()

    public static func shared(for modelId: String, tokenizer: any Tokenizer, size: Int)
        -> TokenizerVocabulary
    {
        cache.value(key: "\(modelId)#\(size)") {
            TokenizerVocabulary(tokenizer: tokenizer, size: size)
        }
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: TokenizerVocabulary] = [:]

        func value(key: String, build: () -> TokenizerVocabulary) -> TokenizerVocabulary {
            lock.lock()
            if let existing = storage[key] {
                lock.unlock()
                return existing
            }
            lock.unlock()

            let built = build()

            lock.lock()
            storage[key] = built
            lock.unlock()
            return built
        }
    }
}
