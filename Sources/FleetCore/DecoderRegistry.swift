import Foundation

/// Routes media files to the decoder that claims their extension.
///
/// This is the "coordination" step of the harness: many heterogeneous media
/// types funnel through one registry into a single fragment representation.
public struct DecoderRegistry: Sendable {

    private var decoders: [any MediaDecoder] = []

    public init() {}

    /// Register a decoder. Later registrations win on extension conflicts.
    public mutating func register(_ decoder: any MediaDecoder) {
        decoders.append(decoder)
    }

    /// The decoder that claims `url`, if any (most recently registered wins).
    public func decoder(for url: URL) -> (any MediaDecoder)? {
        decoders.last { $0.handles(url) }
    }

    /// Decode `url` by routing it to the matching decoder.
    ///
    /// Returns an empty array (rather than throwing) for unknown extensions, so a
    /// folder of mixed/binary files degrades gracefully instead of failing.
    public func decode(_ url: URL) async throws -> [ContextFragment] {
        guard let decoder = decoder(for: url) else { return [] }
        return try await decoder.decode(url)
    }

    /// Whether any registered decoder claims `url`.
    public func canDecode(_ url: URL) -> Bool {
        decoder(for: url) != nil
    }
}
