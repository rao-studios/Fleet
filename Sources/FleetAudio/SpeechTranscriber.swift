import Foundation

#if canImport(Speech)
import Speech

/// On-device speech-to-text using Apple's `Speech` framework.
///
/// Notes / caveats for CLI use:
/// - Requires speech-recognition authorization (`NSSpeechRecognitionUsageDescription`).
/// - Forces on-device recognition; the locale must support it or transcription fails.
/// - Best-effort: callers should treat a thrown error as "skip this file".
public struct SpeechTranscriber: AudioTranscriber {

    public let locale: Locale

    public init(locale: Locale = .current) {
        self.locale = locale
    }

    public func transcribe(_ audioURL: URL) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw AudioTranscriptionError.recognizerUnavailable
        }

        guard await Self.requestAuthorization() == .authorized else {
            throw AudioTranscriptionError.notAuthorized
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = true

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeGuard()
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if resumed.claim() { continuation.resume(throwing: error) }
                    return
                }
                if let result, result.isFinal {
                    if resumed.claim() {
                        continuation.resume(returning: result.bestTranscription.formattedString)
                    }
                }
            }
        }
    }

    private static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }
}

/// Ensures a checked continuation is resumed at most once across the recognition
/// callback's possible repeat invocations.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

#else

/// Linux / non-Apple fallback: no system ASR available.
public struct SpeechTranscriber: AudioTranscriber {
    public init(locale: Locale = .current) {}
    public func transcribe(_ audioURL: URL) async throws -> String {
        throw AudioTranscriptionError.unsupportedPlatform
    }
}

#endif
