import Foundation

/// Speech-to-text for a single audio file.
///
/// Pluggable so the on-device backend can evolve. Today the only real backend is
/// Apple's `Speech` framework (``SpeechTranscriber``). The intended cross-platform
/// follow-up is a Whisper-on-MLX backend once a Whisper model is vendored into
/// Frigate — Frigate ships no ASR today.
public protocol AudioTranscriber: Sendable {
    func transcribe(_ audioURL: URL) async throws -> String
}

/// A transcriber that always returns an empty string.
///
/// Used on platforms without a real ASR backend so audio degrades gracefully to a
/// metadata-only fragment rather than failing the run.
public struct NoOpAudioTranscriber: AudioTranscriber {
    public init() {}
    public func transcribe(_ audioURL: URL) async throws -> String { "" }
}

public enum AudioTranscriptionError: Error, CustomStringConvertible {
    case recognizerUnavailable
    case notAuthorized
    case unsupportedPlatform

    public var description: String {
        switch self {
        case .recognizerUnavailable: return "No speech recognizer is available for the requested locale."
        case .notAuthorized: return "Speech recognition was not authorized."
        case .unsupportedPlatform: return "Audio transcription is not supported on this platform."
        }
    }
}
