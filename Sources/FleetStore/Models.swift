import FleetCore
import Foundation

/// A single piece of manually-entered training data.
///
/// Two kinds for now: a freeform `note` (a fact/statement) and a `qa` pair
/// (question → answer). Q&A is the sharper instrument for testing memory recall.
public struct DatasetEntry: Codable, Sendable, Identifiable {

    public enum Kind: String, Codable, Sendable {
        case note
        case qa
    }

    public let id: UUID
    public var kind: Kind
    public var note: String?
    public var question: String?
    public var answer: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        note: String? = nil,
        question: String? = nil,
        answer: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.note = note
        self.question = question
        self.answer = answer
        self.createdAt = createdAt
    }

    public static func note(_ text: String) -> DatasetEntry {
        DatasetEntry(kind: .note, note: text)
    }

    public static func qa(question: String, answer: String) -> DatasetEntry {
        DatasetEntry(kind: .qa, question: question, answer: answer)
    }

    /// Training text(s) this entry contributes.
    ///
    /// `note` → the note itself. `qa` → a `Q: …\nA: …` line (teaches recall) plus
    /// the bare answer (reinforces the fact statement).
    public func trainingTexts() -> [String] {
        switch kind {
        case .note:
            let text = (note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [text]
        case .qa:
            let q = (question ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let a = (answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty, !a.isEmpty else { return [] }
            return ["Q: \(q)\nA: \(a)", a]
        }
    }

    /// One-line preview for list UIs.
    public var summary: String {
        switch kind {
        case .note: return note ?? ""
        case .qa: return "Q: \(question ?? "")  →  \(answer ?? "")"
        }
    }
}

/// A named collection of training data, identified by a stable UUID.
///
/// Holds manual ``DatasetEntry`` values plus any ``ContextFragment`` decoded from
/// uploaded files. The UUID is what a ``TrainedAdapter`` references.
public struct TrainingDataset: Codable, Sendable, Identifiable {

    public let id: UUID
    public var name: String
    public var entries: [DatasetEntry]
    public var fileFragments: [ContextFragment]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        entries: [DatasetEntry] = [],
        fileFragments: [ContextFragment] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.entries = entries
        self.fileFragments = fileFragments
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// All text examples this dataset trains on (entries + uploaded fragments).
    public var trainingExamples: [String] {
        entries.flatMap { $0.trainingTexts() } + fileFragments.map(\.text).filter { !$0.isEmpty }
    }

    /// The aligned ``Corpus`` fed to the fine-tuner.
    public var corpus: Corpus {
        var fragments: [ContextFragment] = []
        for entry in entries {
            for (index, text) in entry.trainingTexts().enumerated() {
                let source = URL(string: "fleet://manual/\(entry.id)/\(index)")!
                fragments.append(
                    ContextFragment(source: source, mediaType: .text, text: text))
            }
        }
        fragments.append(contentsOf: fileFragments)
        return Corpus(fragments)
    }
}

/// A trained LoRA adapter, identified by its own UUID and tied to the dataset it
/// was fine-tuned from via ``datasetId``.
///
/// The adapter weights live at `fleet-db/loras/<id>/` (see
/// ``FleetDB/adapterDirectory(for:)``).
public struct TrainedAdapter: Codable, Sendable, Identifiable {

    public let id: UUID
    public let datasetId: UUID
    public var name: String
    public var modelId: String
    public var rank: Int
    public var scale: Float
    public var numLayers: Int
    public var iterations: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        datasetId: UUID,
        name: String,
        modelId: String,
        rank: Int,
        scale: Float,
        numLayers: Int,
        iterations: Int,
        createdAt: Date = .now
    ) {
        self.id = id
        self.datasetId = datasetId
        self.name = name
        self.modelId = modelId
        self.rank = rank
        self.scale = scale
        self.numLayers = numLayers
        self.iterations = iterations
        self.createdAt = createdAt
    }
}
