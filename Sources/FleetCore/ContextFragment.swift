import Foundation

/// The kind of source a ``ContextFragment`` was aligned from.
///
/// Deliberately mirrors Totem's `Database.Partition.MediaType` so a fragment can
/// later be bridged into a Totem partition without an impedance mismatch.
public enum FragmentMediaType: String, Codable, Sendable {
    case text
    case code
    case table
    case image
    case audio
}

/// The single, unified unit that every decoder produces and that the whole
/// harness coordinates around.
///
/// A `ContextFragment` is intentionally shaped like Totem's `Database.Partition`
/// (`url` / `mediaType` / `text` / `metadata`). For this demo we keep only the
/// fields the fine-tuning path needs; an embedding/owner bridge can be added when
/// Totem exposes a public library and becomes a ``ContextProvider``.
public struct ContextFragment: Codable, Sendable, Identifiable {

    /// Stable identifier. Decoders use `"<file>#<index>"`; otherwise a UUID.
    public let id: String

    /// The file (or, later, remote resource) this fragment was aligned from.
    public var source: URL

    /// How the source was interpreted.
    public var mediaType: FragmentMediaType

    /// The aligned textual representation fed into training.
    ///
    /// Empty when a non-text source could not be reduced to text on this platform
    /// (e.g. an image with no captioner, or audio with no transcriber). Such
    /// fragments are preserved for provenance but filtered out of ``Corpus/textExamples``.
    public var text: String

    /// Optional provenance / decoder annotations.
    public var metadata: [String: String]?

    public init(
        id: String = UUID().uuidString,
        source: URL,
        mediaType: FragmentMediaType = .text,
        text: String,
        metadata: [String: String]? = nil
    ) {
        self.id = id
        self.source = source
        self.mediaType = mediaType
        self.text = text
        self.metadata = metadata
    }
}
