import Foundation

/// The single aligned data structure: every decoded fragment from every media
/// type, collected into one place ready to be formatted for fine-tuning.
public struct Corpus: Sendable, Codable {

    public private(set) var fragments: [ContextFragment]

    public init(_ fragments: [ContextFragment] = []) {
        self.fragments = fragments
    }

    public mutating func append(_ more: [ContextFragment]) {
        fragments.append(contentsOf: more)
    }

    public mutating func append(_ fragment: ContextFragment) {
        fragments.append(fragment)
    }

    /// The non-empty textual examples, trimmed — the actual training material.
    public var textExamples: [String] {
        fragments.compactMap {
            let trimmed = $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    public var isEmpty: Bool { fragments.isEmpty }
    public var count: Int { fragments.count }
}
