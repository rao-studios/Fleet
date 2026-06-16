import FleetCore
import XCTest

@testable import FleetStore

final class TrainingRecordTests: XCTestCase {

    // MARK: - trainingTexts

    func testQATrainingTexts() {
        let qa = TrainingRecord.qa(question: "What is the code?", answer: "7741")
        XCTAssertEqual(qa.trainingTexts(), ["Q: What is the code?\nA: 7741", "7741"])
    }

    func testNoteTrainingTextsAndEmptyDropped() {
        XCTAssertEqual(TrainingRecord.note("a fact").trainingTexts(), ["a fact"])
        XCTAssertEqual(TrainingRecord.note("   ").trainingTexts(), [])
        XCTAssertEqual(TrainingRecord.qa(question: "q", answer: " ").trainingTexts(), [])
    }

    // MARK: - Legacy migration (entries + fileFragments → records)

    /// Mirrors the pre-redesign on-disk shape so we can encode it and prove a new
    /// `TrainingDataset` decodes it (entries kept; file chunks folded into Notes).
    private struct LegacyEntry: Encodable {
        var id = UUID()
        var kind: String
        var note: String?
        var question: String?
        var answer: String?
        var createdAt = Date()
    }
    private struct LegacyDataset: Encodable {
        var id = UUID()
        var name: String
        var entries: [LegacyEntry]
        var fileFragments: [ContextFragment]
        var createdAt = Date()
        var updatedAt = Date()
    }

    func testDecodesLegacyDataset() throws {
        let legacy = LegacyDataset(
            name: "old",
            entries: [
                LegacyEntry(kind: "qa", question: "Q1", answer: "A1"),
                LegacyEntry(kind: "note", note: "a note"),
            ],
            fileFragments: [
                ContextFragment(
                    source: URL(string: "totem://partition/p1")!, text: "totem chunk",
                    metadata: ["source": "totem", "documentId": "doc-9"]),
                ContextFragment(source: URL(fileURLWithPath: "/tmp/readme.md"), text: "file chunk"),
            ])

        let data = try PropertyListEncoder().encode(legacy)
        let dataset = try PropertyListDecoder().decode(TrainingDataset.self, from: data)

        // 2 legacy entries + 2 file chunks (as Notes) = 4 records.
        XCTAssertEqual(dataset.records.count, 4)
        XCTAssertEqual(dataset.name, "old")

        let totemNote = dataset.records.first { $0.note == "totem chunk" }
        XCTAssertEqual(totemNote?.kind, .note)
        XCTAssertEqual(totemNote?.provenance?.origin, .totem)
        XCTAssertEqual(totemNote?.provenance?.documentId, "doc-9")

        let fileNote = dataset.records.first { $0.note == "file chunk" }
        XCTAssertEqual(fileNote?.provenance?.origin, .file)

        // The legacy Q&A survived intact.
        XCTAssertTrue(dataset.records.contains { $0.kind == .qa && $0.answer == "A1" })
    }

    func testRoundTripsNewFormat() throws {
        let dataset = TrainingDataset(name: "new", records: [
            .qa(question: "Q", answer: "A", provenance: .manual),
            .note("hello", provenance: RecordProvenance(origin: .totem, ownerId: "alice")),
        ])
        let data = try PropertyListEncoder().encode(dataset)
        let back = try PropertyListDecoder().decode(TrainingDataset.self, from: data)
        XCTAssertEqual(back.records.count, 2)
        XCTAssertEqual(back.records.last?.provenance?.ownerId, "alice")
    }

    // MARK: - Royalty manifest char-share

    func testManifestProportionalShares() {
        let dataset = TrainingDataset(name: "royalty", records: [
            .qa(question: "q1", answer: "hello",  // 5 owner chars → alice
                provenance: RecordProvenance(origin: .totem, ownerId: "alice")),
            .note("abcdef",                        // 6 owner chars → file:notes.md
                  provenance: RecordProvenance(origin: .file, sourceLabel: "notes.md")),
            .qa(question: "q3", answer: "xyz", provenance: .manual),  // 3 chars, no owner
        ])
        let adapter = TrainedAdapter(
            datasetId: dataset.id, name: "a", modelId: "m",
            rank: 8, scale: 20, numLayers: 16, iterations: 100)

        let manifest = TrainingRecordManifest(adapter: adapter, dataset: dataset)

        XCTAssertEqual(manifest.totalChars, 14)  // 5 + 6 + 3
        XCTAssertEqual(manifest.records.count, 3)
        // Two attribution keys; manual is excluded from owners.
        XCTAssertEqual(manifest.owners.count, 2)
        XCTAssertEqual(manifest.owners.first?.key, "file:notes.md")  // sorted by chars desc
        XCTAssertEqual(manifest.owners.first?.chars, 6)
        let alice = manifest.owners.first { $0.key == "alice" }
        XCTAssertEqual(alice?.share ?? 0, 5.0 / 14.0, accuracy: 1e-9)
        // Owner shares sum to < 1 because manual content dilutes but earns none.
        XCTAssertLessThan(manifest.owners.reduce(0) { $0 + $1.share }, 1.0)
    }
}
