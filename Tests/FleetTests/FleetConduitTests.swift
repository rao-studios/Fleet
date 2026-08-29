import FleetCore
import XCTest

@testable import FleetConduit

final class FleetConduitTests: XCTestCase {

    private func document(id: String = "d1", texts: [String] = ["one", "two"]) -> TotemDocument {
        TotemDocument(
            id: id,
            name: "Notes.md",
            ownerId: "alice",
            groupId: "g1",
            groupLabel: "Research",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            texts: texts,
            mediaType: "text"
        )
    }

    func testProvenanceRecordsWhichPartitionsWereUsed() {
        let totemId = UUID()
        let provenance = TotemImporter.provenance(
            for: document(), totemId: totemId, textIndices: [0, 2])

        XCTAssertEqual(provenance.origin, .totem)
        XCTAssertEqual(provenance.ownerId, "alice")
        XCTAssertEqual(provenance.totemId, totemId.uuidString)
        XCTAssertEqual(provenance.documentId, "d1")
        XCTAssertEqual(provenance.groupId, "g1")
        // Partition ids no longer exist in Conduit's documents API, so position
        // within the ordered texts array is the addressing we keep.
        XCTAssertEqual(provenance.textIndices, [0, 2])
        XCTAssertEqual(provenance.sourceLabel, "Notes.md")
    }

    func testAttributionFallsBackToTheOwner() {
        let provenance = TotemImporter.provenance(
            for: document(), totemId: UUID(), textIndices: [])
        XCTAssertEqual(provenance.attributionKey, "alice")
    }

    func testDocumentBodyJoinsPartitionsInStoredOrder() {
        XCTAssertEqual(document(texts: ["a", "b", "c"]).body, "a\n\nb\n\nc")
    }

    func testFetchReportsIdsTheTotemWithheld() {
        // The Totem silently skips documents the caller may not read, so the
        // fetch surfaces the difference rather than leaving it invisible.
        let fetch = TotemDocumentFetch(
            documents: [document(id: "d1"), document(id: "d2")],
            inaccessibleIds: ["d3"]
        )
        XCTAssertEqual(fetch.documents.count, 2)
        XCTAssertEqual(fetch.inaccessibleIds, ["d3"])
    }
}
