import FleetCore
import Foundation

/// Where a training record's content came from — the basis for royalty attribution.
public struct RecordProvenance: Codable, Sendable, Equatable {

    public enum Origin: String, Codable, Sendable {
        case manual  // typed by the user
        case file    // decoded from a local file
        case totem   // pulled from a Totem partition
    }

    public var origin: Origin
    /// Royalty beneficiary — the Totem partition's owner.
    public var ownerId: String?
    public var totemId: String?
    public var documentId: String?
    /// The source partition(s) this record was built from.
    public var partitionIds: [String]
    /// Human label (file name, document id) for the UI.
    public var sourceLabel: String?

    public init(
        origin: Origin,
        ownerId: String? = nil,
        totemId: String? = nil,
        documentId: String? = nil,
        partitionIds: [String] = [],
        sourceLabel: String? = nil
    ) {
        self.origin = origin
        self.ownerId = ownerId
        self.totemId = totemId
        self.documentId = documentId
        self.partitionIds = partitionIds
        self.sourceLabel = sourceLabel
    }

    public static let manual = RecordProvenance(origin: .manual)

    /// The key a record's contribution is attributed to (Totem owner, file, or none).
    public var attributionKey: String? {
        if let ownerId, !ownerId.isEmpty { return ownerId }
        switch origin {
        case .file: return "file:\(sourceLabel ?? "local")"
        case .totem, .manual: return nil
        }
    }
}

/// How a record's text was produced — audits ML-generated material.
public struct RecordGeneration: Codable, Sendable, Equatable {
    public var generated: Bool
    public var modelId: String?
    public var generatedAt: Date?

    public init(generated: Bool, modelId: String? = nil, generatedAt: Date? = nil) {
        self.generated = generated
        self.modelId = modelId
        self.generatedAt = generatedAt
    }
}

/// A single training example with provenance — the unit stored in a dataset and
/// snapshotted alongside the LoRA for royalty attribution.
///
/// Two kinds: a freeform `note` (a fact/statement) and a `qa` pair (question →
/// answer). Q&A is the sharper instrument for testing memory recall. Imported
/// chunks become Q&A whose **answer is the verbatim chunk** and whose question is
/// model-generated, or a Note holding the raw chunk.
public struct TrainingRecord: Codable, Sendable, Identifiable {

    public enum Kind: String, Codable, Sendable {
        case note
        case qa
    }

    public let id: UUID
    public var kind: Kind
    public var note: String?
    public var question: String?
    public var answer: String?
    public var provenance: RecordProvenance?
    public var generation: RecordGeneration?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: Kind,
        note: String? = nil,
        question: String? = nil,
        answer: String? = nil,
        provenance: RecordProvenance? = nil,
        generation: RecordGeneration? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.note = note
        self.question = question
        self.answer = answer
        self.provenance = provenance
        self.generation = generation
        self.createdAt = createdAt
    }

    public static func note(_ text: String, provenance: RecordProvenance? = nil) -> TrainingRecord {
        TrainingRecord(kind: .note, note: text, provenance: provenance)
    }

    public static func qa(
        question: String, answer: String,
        provenance: RecordProvenance? = nil, generation: RecordGeneration? = nil
    ) -> TrainingRecord {
        TrainingRecord(
            kind: .qa, question: question, answer: answer,
            provenance: provenance, generation: generation)
    }

    /// Training text(s) this record contributes.
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

    /// The owner-derived content that counts toward royalty (the verbatim chunk):
    /// the bare `answer` for a Q&A, or the note text. The generated question is
    /// Fleet's synthesis, so it is excluded.
    public var contributionText: String {
        switch kind {
        case .note: return (note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        case .qa: return (answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// One-line preview for list UIs.
    public var summary: String {
        switch kind {
        case .note: return note ?? ""
        case .qa: return "Q: \(question ?? "")  →  \(answer ?? "")"
        }
    }

    /// Build a Note record from a legacy `fileFragments` ``ContextFragment`` (migration).
    static func fromLegacyFragment(_ fragment: ContextFragment) -> TrainingRecord {
        let isTotem = fragment.metadata?["source"] == "totem"
        let provenance = RecordProvenance(
            origin: isTotem ? .totem : .file,
            ownerId: fragment.metadata?["ownerId"],
            documentId: fragment.metadata?["documentId"],
            sourceLabel: fragment.source.lastPathComponent)
        return TrainingRecord(kind: .note, note: fragment.text, provenance: provenance)
    }
}

/// A named collection of training records, identified by a stable UUID.
/// The UUID is what a ``TrainedAdapter`` references.
public struct TrainingDataset: Codable, Sendable, Identifiable {

    public let id: UUID
    public var name: String
    public var records: [TrainingRecord]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        records: [TrainingRecord] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.records = records
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// All text examples this dataset trains on.
    public var trainingExamples: [String] {
        records.flatMap { $0.trainingTexts() }
    }

    /// The aligned ``Corpus`` fed to the fine-tuner (plain text; provenance is kept
    /// in the records and snapshotted separately at training time).
    public var corpus: Corpus {
        var fragments: [ContextFragment] = []
        for record in records {
            for (index, text) in record.trainingTexts().enumerated() {
                let source = URL(string: "fleet://record/\(record.id)/\(index)")!
                fragments.append(
                    ContextFragment(source: source, mediaType: .text, text: text))
            }
        }
        return Corpus(fragments)
    }

    // MARK: - Codable (canonical = `records`; migrates legacy `entries` + `fileFragments`)

    private enum CodingKeys: String, CodingKey { case id, name, records, createdAt, updatedAt }
    private enum LegacyKeys: String, CodingKey { case entries, fileFragments }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)

        // New format: `records`. Older datasets use `entries` (+ `fileFragments`).
        // `TrainingRecord` decodes the old entry shape directly (provenance/generation
        // are optional), and legacy file chunks fold in as Note records.
        let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
        if let recs = try c.decodeIfPresent([TrainingRecord].self, forKey: .records) {
            records = recs
        } else {
            records = (try legacy?.decodeIfPresent([TrainingRecord].self, forKey: .entries)) ?? []
        }
        if let frags = try legacy?.decodeIfPresent([ContextFragment].self, forKey: .fileFragments) {
            records.append(contentsOf: frags.map(TrainingRecord.fromLegacyFragment))
        }
    }
}

/// A trained LoRA adapter, identified by its own UUID and tied to the dataset it
/// was fine-tuned from via ``datasetId``.
///
/// The adapter weights live at `fleet-db/loras/<id>/` (see
/// ``FleetDB/adapterDirectory(for:)``), alongside a `training_records.json`
/// royalty manifest (see ``TrainingRecordManifest``).
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
