import Foundation

/// One record's attribution row in the royalty manifest.
public struct RecordAttribution: Codable, Sendable, Identifiable {
    public var recordId: UUID
    public var kind: TrainingRecord.Kind
    public var provenance: RecordProvenance?
    public var generation: RecordGeneration?
    /// Characters of the owner-derived content (the verbatim chunk / note text).
    public var contributionChars: Int

    public var id: UUID { recordId }
}

/// Aggregated royalty share for one attribution key (a Totem owner or a file).
public struct OwnerShare: Codable, Sendable, Identifiable {
    public var key: String      // owner id, or "file:<name>"
    public var chars: Int
    public var share: Double    // chars / totalChars (0...1)

    public var id: String { key }
}

/// Immutable snapshot of the training records that produced a LoRA, with a
/// proportional **char-share** contribution per source. Persisted beside the
/// adapter weights at `fleet-db/loras/<adapterId>/training_records.json` so a LoRA
/// is self-describing for royalty even if the dataset later changes.
public struct TrainingRecordManifest: Codable, Sendable {

    public var adapterId: UUID
    public var datasetId: UUID
    public var modelId: String
    public var rank: Int
    public var iterations: Int
    public var createdAt: Date
    /// Total owner-derived characters across all records (the share denominator).
    public var totalChars: Int
    public var records: [RecordAttribution]
    public var owners: [OwnerShare]

    /// Compute the manifest from the adapter + the dataset it trained on.
    public init(adapter: TrainedAdapter, dataset: TrainingDataset) {
        adapterId = adapter.id
        datasetId = adapter.datasetId
        modelId = adapter.modelId
        rank = adapter.rank
        iterations = adapter.iterations
        createdAt = adapter.createdAt

        let rows = dataset.records.map { record in
            RecordAttribution(
                recordId: record.id, kind: record.kind,
                provenance: record.provenance, generation: record.generation,
                contributionChars: record.contributionText.count)
        }
        records = rows

        let total = rows.reduce(0) { $0 + $1.contributionChars }
        totalChars = total

        // Aggregate by attribution key; manual content (no key) dilutes shares but
        // earns none. Sort by chars so the largest contributors come first.
        var byKey: [String: Int] = [:]
        for (record, row) in zip(dataset.records, rows) {
            guard let key = record.provenance?.attributionKey else { continue }
            byKey[key, default: 0] += row.contributionChars
        }
        owners = byKey
            .map { OwnerShare(key: $0.key, chars: $0.value,
                              share: total > 0 ? Double($0.value) / Double(total) : 0) }
            .sorted { $0.chars > $1.chars }
    }

    /// Compact one-line attribution summary for the training log.
    public var summaryLine: String {
        guard !owners.isEmpty else { return "Attribution · none (manual only)" }
        let parts = owners.prefix(4).map { "\($0.key) \(Int(($0.share * 100).rounded()))%" }
        return "Attribution · " + parts.joined(separator: " · ")
    }
}
