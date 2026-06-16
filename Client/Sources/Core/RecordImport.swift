import Fleet
import FleetConduit
import Foundation

/// Turns imported material (Totem partitions or decoded local files) into
/// ``TrainingRecord`` values with provenance. For Q&A it generates a question per
/// chunk via ``QARecordGenerator``, grounded in the whole source document; the
/// answer stays the verbatim chunk. Falls back to a Note when generation fails.
enum RecordImport {

    enum Kind: String, CaseIterable, Identifiable {
        case qa = "Q&A"
        case note = "Note"
        var id: String { rawValue }
    }

    // MARK: - Totem partitions → records

    /// - Parameter contextPartitions: partitions already loaded in the panel
    ///   (the browsed group's partitions + search results). The surrounding-document
    ///   context is built from these — no extra gRPC requests are made.
    static func totemRecords(
        partitions: [TotemPartition],
        contextPartitions: [TotemPartition],
        kind: Kind,
        totemId: UUID,
        ownerId: String,
        modelId: String,
        progress: @escaping (Int, Int) -> Void = { _, _ in }
    ) async -> [TrainingRecord] {
        let total = partitions.count
        progress(0, total)

        if kind == .note {
            var done = 0
            return partitions.map { partition in
                done += 1; progress(done, total)
                return .note(partition.text, provenance: provenance(for: partition, totemId: totemId, fallbackOwner: ownerId))
            }
        }

        // Build each document's grounding context once from the already-loaded
        // partitions. A search-origin chunk with no loaded siblings grounds on itself.
        let contextByDoc = Dictionary(grouping: contextPartitions, by: \.documentId)
            .mapValues { QARecordGenerator.context(from: $0.map(\.text)) }

        let generator = QARecordGenerator(modelId: modelId)
        var result: [TrainingRecord] = []
        var done = 0
        for partition in partitions {
            let context = contextByDoc[partition.documentId]
                ?? QARecordGenerator.context(from: [partition.text])
            let question = await generator.generateQuestion(forAnswer: partition.text, documentContext: context)
            result.append(makeRecord(
                answer: partition.text, question: question, modelId: modelId,
                provenance: provenance(for: partition, totemId: totemId, fallbackOwner: ownerId)))
            done += 1; progress(done, total)
        }
        return result
    }

    private static func provenance(
        for partition: TotemPartition, totemId: UUID, fallbackOwner: String
    ) -> RecordProvenance {
        let owner = partition.ownerId.isEmpty ? fallbackOwner : partition.ownerId
        return RecordProvenance(
            origin: .totem, ownerId: owner.isEmpty ? nil : owner,
            totemId: totemId.uuidString, documentId: partition.documentId,
            partitionIds: [partition.id], sourceLabel: "doc \(partition.documentId.prefix(8))")
    }

    // MARK: - Local files → records (always Q&A, each file = one document)

    static func fileRecords(
        fragments: [ContextFragment],
        modelId: String,
        progress: @escaping (Int, Int) -> Void = { _, _ in }
    ) async -> [TrainingRecord] {
        let total = fragments.count
        progress(0, total)
        let generator = QARecordGenerator(modelId: modelId)
        let groups = Dictionary(grouping: fragments) { $0.source.lastPathComponent }
        var result: [TrainingRecord] = []
        var done = 0
        for (fileName, frags) in groups {
            let context = QARecordGenerator.context(from: frags.map(\.text))
            for frag in frags {
                let answer = frag.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !answer.isEmpty else { done += 1; progress(done, total); continue }
                let question = await generator.generateQuestion(forAnswer: frag.text, documentContext: context)
                let prov = RecordProvenance(
                    origin: .file, documentId: fileName,
                    partitionIds: [frag.id], sourceLabel: fileName)
                result.append(makeRecord(answer: frag.text, question: question, modelId: modelId, provenance: prov))
                done += 1; progress(done, total)
            }
        }
        return result
    }

    // MARK: - Helpers

    /// A generated question yields a Q&A record (answer = verbatim chunk); an empty
    /// question (generation failed) falls back to a Note holding the raw chunk.
    private static func makeRecord(
        answer: String, question: String, modelId: String, provenance: RecordProvenance
    ) -> TrainingRecord {
        if question.isEmpty {
            return .note(answer, provenance: provenance)
        }
        return .qa(
            question: question, answer: answer, provenance: provenance,
            generation: RecordGeneration(generated: true, modelId: modelId, generatedAt: .now))
    }
}
