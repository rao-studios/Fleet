import Foundation

/// Turns a ``Corpus`` into the train/validation material a fine-tuning job needs.
///
/// Frigate's training driver takes plain `[String]` arrays, so the hot path stays
/// in memory. The JSONL writers exist for inspectability and to match the
/// `{"text": ...}` format Frigate's `loadLoRAData` expects.
public struct DatasetFormatter: Sendable {

    public init() {}

    /// Split the corpus's text examples into shuffled train/validation arrays.
    ///
    /// `validationFraction` is clamped to `0...0.9`. With a single example the
    /// validation set is empty (the caller decides how to handle that).
    public func split(
        _ corpus: Corpus,
        validationFraction: Double
    ) -> (train: [String], valid: [String]) {
        var examples = corpus.textExamples
        guard !examples.isEmpty else { return ([], []) }

        examples.shuffle()
        let fraction = min(max(validationFraction, 0), 0.9)
        let validCount = examples.count > 1 ? max(1, Int(Double(examples.count) * fraction)) : 0
        let valid = Array(examples.prefix(validCount))
        let train = Array(examples.dropFirst(validCount))
        return (train, valid)
    }

    /// Write `train.jsonl` and `valid.jsonl` (one `{"text": ...}` per line).
    public func writeJSONL(train: [String], valid: [String], to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeLines(train, to: directory.appendingPathComponent("train.jsonl"))
        try writeLines(valid, to: directory.appendingPathComponent("valid.jsonl"))
    }

    private func writeLines(_ examples: [String], to url: URL) throws {
        struct Line: Encodable { let text: String }
        let encoder = JSONEncoder()
        let lines = try examples.map { example -> String in
            let data = try encoder.encode(Line(text: example))
            return String(decoding: data, as: UTF8.self)
        }
        let body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
    }
}
