import FleetCore
import Foundation

/// Images → text via an injected captioner (``ImageCaptioning``).
///
/// Takes a closure rather than a concrete captioner so `FleetMedia` stays free of
/// the MLX/Frigate graph. When no captioner is provided (or it fails) the image
/// still produces a metadata-only fragment for provenance, with empty text.
public struct ImageDecoder: MediaDecoder {

    private let captioning: ImageCaptioning?

    public init(captioning: ImageCaptioning? = nil) {
        self.captioning = captioning
    }

    public var supportedExtensions: Set<String> {
        ["png", "jpg", "jpeg", "heic", "heif", "gif", "bmp", "tiff", "tif", "webp"]
    }

    public func decode(_ url: URL) async throws -> [ContextFragment] {
        guard let captioning else {
            return [
                ContextFragment(
                    id: fragmentID(url, 0), source: url, mediaType: .image, text: "",
                    metadata: ["status": "no-captioner"])
            ]
        }
        let caption = (try? await captioning(url)) ?? ""
        return [
            ContextFragment(
                id: fragmentID(url, 0), source: url, mediaType: .image, text: caption,
                metadata: ["kind": "caption"])
        ]
    }
}

/// Audio → text via an injected transcriber (``AudioTranscribing``).
///
/// Same degradation contract as ``ImageDecoder``: no transcriber (or a failure)
/// yields a metadata-only fragment rather than aborting the run.
public struct AudioDecoder: MediaDecoder {

    private let transcribing: AudioTranscribing?

    public init(transcribing: AudioTranscribing? = nil) {
        self.transcribing = transcribing
    }

    public var supportedExtensions: Set<String> {
        ["wav", "mp3", "m4a", "aac", "flac", "aiff", "aif", "caf"]
    }

    public func decode(_ url: URL) async throws -> [ContextFragment] {
        guard let transcribing else {
            return [
                ContextFragment(
                    id: fragmentID(url, 0), source: url, mediaType: .audio, text: "",
                    metadata: ["status": "no-transcriber"])
            ]
        }
        let transcript = (try? await transcribing(url)) ?? ""
        return [
            ContextFragment(
                id: fragmentID(url, 0), source: url, mediaType: .audio, text: transcript,
                metadata: ["kind": "transcript"])
        ]
    }
}
