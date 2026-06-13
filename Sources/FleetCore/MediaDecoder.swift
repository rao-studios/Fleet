import Foundation

/// Async closure that turns an image into a textual caption.
///
/// Defined here (rather than referencing a concrete captioner) so `FleetMedia`
/// stays free of the heavy MLX/Frigate graph. `FleetVision` supplies a real
/// implementation; callers pass it in at wiring time.
public typealias ImageCaptioning = @Sendable (URL) async throws -> String

/// Async closure that turns an audio file into a textual transcript.
///
/// `FleetAudio` supplies a real implementation; callers pass it in at wiring time.
public typealias AudioTranscribing = @Sendable (URL) async throws -> String

/// A component that knows how to turn one media file into aligned fragments.
///
/// This is the leaf of the coordination pattern: ``DecoderRegistry`` routes each
/// file to the decoder that claims its extension.
public protocol MediaDecoder: Sendable {

    /// Lowercased file extensions (no leading dot) this decoder handles.
    var supportedExtensions: Set<String> { get }

    /// Decode a single file into zero or more ``ContextFragment`` values.
    ///
    /// Implementations should chunk large inputs (see ``TextChunker``) so each
    /// fragment stays within a reasonable training-example size.
    func decode(_ url: URL) async throws -> [ContextFragment]
}

extension MediaDecoder {
    /// Whether this decoder claims the given file by extension.
    public func handles(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}
