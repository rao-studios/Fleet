import FleetCore
import Foundation

/// Turns a raw chunk into a Q&A training example by generating a **question**
/// whose answer is the verbatim chunk, grounded in the surrounding document.
///
/// Wraps a single ``ChatSession`` so the base model is loaded once and reused
/// across a batch of chunks.
public struct QARecordGenerator: Sendable {

    private let session: ChatSession
    private let maxContextChars: Int

    public init(modelId: String, maxContextChars: Int = 6000) {
        self.session = ChatSession(modelId: modelId, adapterDirectory: nil)
        self.maxContextChars = maxContextChars
    }

    /// Generate ONE question whose answer is `answer`, grounded in `documentContext`.
    /// Returns the trimmed question, or "" on failure (the caller decides a fallback).
    public func generateQuestion(
        forAnswer answer: String, documentContext: String, maxTokens: Int = 200
    ) async -> String {
        let context = String(documentContext.prefix(maxContextChars))
        let prompt = """
        You are writing a training question for a study dataset.
        Read the DOCUMENT CONTEXT, then write ONE clear, specific question whose answer \
        is exactly the ANSWER PASSAGE below. The question must be answerable from the \
        passage alone. Output ONLY the question — no preamble, no quotes, no commentary.

        DOCUMENT CONTEXT:
        \(context)

        ANSWER PASSAGE:
        \(answer)

        QUESTION:
        """
        var text = ""
        do {
            for try await chunk in await session.reply(
                history: [ChatTurn(role: .user, text: prompt)], maxTokens: maxTokens)
            {
                text += chunk
            }
        } catch {
            return ""
        }
        return Self.cleanQuestion(text)
    }

    /// Build a capped, deduped document-context string from a document's chunk texts.
    /// (Totem partitions are unordered, so order isn't meaningful — this is grounding.)
    public static func context(from chunks: [String], maxChars: Int = 6000) -> String {
        var seen = Set<String>()
        var pieces: [String] = []
        var total = 0
        for chunk in chunks {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            pieces.append(trimmed)
            total += trimmed.count
            if total >= maxChars { break }
        }
        return String(pieces.joined(separator: "\n\n").prefix(maxChars))
    }

    /// Strip a leading "QUESTION:" label and wrapping quotes the model may add.
    static func cleanQuestion(_ raw: String) -> String {
        var q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = q.range(of: "QUESTION:", options: [.caseInsensitive]) {
            q = String(q[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        q = q.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return q.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
