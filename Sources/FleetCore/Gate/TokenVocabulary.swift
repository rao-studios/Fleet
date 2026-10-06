import Foundation

/// The tokenizer as the gate needs to see it.
///
/// Keeping this abstract is what lets the whole masking layer live in FleetCore
/// and be tested against a handful of made-up tokens instead of a 150k-entry
/// vocabulary and an MLX runtime.
public protocol TokenVocabulary: Sendable {
    /// One past the highest valid token id.
    var count: Int { get }
    /// The surface text a token decodes to, or `nil` when the token can never
    /// appear in gated output (special tokens, partial-UTF8 byte fragments).
    func text(of tokenId: Int) -> String?
}

/// A simple in-memory vocabulary, used by tests and by the MLX adapter once it
/// has materialized its token table.
public struct ArrayTokenVocabulary: TokenVocabulary {
    private let texts: [String?]

    public init(_ texts: [String?]) {
        self.texts = texts
    }

    public var count: Int { texts.count }

    public func text(of tokenId: Int) -> String? {
        guard tokenId >= 0 && tokenId < texts.count else { return nil }
        return texts[tokenId]
    }
}
