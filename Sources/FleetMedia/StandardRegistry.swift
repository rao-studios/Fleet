import FleetCore
import Foundation

extension DecoderRegistry {

    /// The default registry covering this demo's media types.
    ///
    /// Text-family decoders are always available and Linux-clean. PDF is included
    /// only where PDFKit exists. Image/audio decoders take optional inference
    /// closures — pass `FleetVision.ImageCaptioner.caption` and a
    /// `FleetAudio.AudioTranscriber.transcribe` to enable real captioning /
    /// transcription; omit them to fall back to metadata-only fragments.
    public static func standard(
        imageCaptioning: ImageCaptioning? = nil,
        audioTranscribing: AudioTranscribing? = nil
    ) -> DecoderRegistry {
        var registry = DecoderRegistry()
        registry.register(PlainTextDecoder())
        registry.register(MarkdownDecoder())
        registry.register(CodeDecoder())
        registry.register(JSONFleetDecoder())
        registry.register(CSVDecoder())
        #if canImport(PDFKit)
        registry.register(PDFTextDecoder())
        #endif
        registry.register(ImageDecoder(captioning: imageCaptioning))
        registry.register(AudioDecoder(transcribing: audioTranscribing))
        return registry
    }
}
