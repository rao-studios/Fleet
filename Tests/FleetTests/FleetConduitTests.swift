import XCTest

@testable import FleetConduit
@testable import FleetCore

final class FleetConduitTests: XCTestCase {

    func testFragmentsChunkAndDedupe() {
        let partitions = [
            TotemPartition(id: "p1", documentId: "d1", ownerId: "alice", text: "alpha", score: nil),
            TotemPartition(id: "p2", documentId: "d1", ownerId: "alice", text: "alpha", score: nil),  // dup text
            TotemPartition(id: "p3", documentId: "d2", ownerId: "alice", text: "   ", score: nil),  // empty
            TotemPartition(id: "p4", documentId: "d2", ownerId: "alice", text: "beta", score: nil),
        ]

        let fragments = TotemImporter.fragments(from: partitions)

        // "alpha" once (deduped), the blank dropped, "beta" kept → 2 fragments.
        XCTAssertEqual(fragments.map(\.text).sorted(), ["alpha", "beta"])
        XCTAssertTrue(fragments.allSatisfy { $0.mediaType == .text })
        XCTAssertEqual(fragments.first { $0.text == "beta" }?.metadata?["source"], "totem")
        XCTAssertEqual(fragments.first { $0.text == "beta" }?.metadata?["documentId"], "d2")
    }

    func testFragmentsChunksLongPartition() {
        // Three distinct 1800-char paragraphs; each is its own chunk (< maxChars,
        // and joining two would exceed it). Distinct content → no dedupe.
        let text = ["a", "b", "c"].map { String(repeating: $0, count: 1800) }.joined(separator: "\n\n")
        let fragments = TotemImporter.fragments(
            from: [TotemPartition(id: "p1", documentId: "d1", ownerId: "o", text: text)],
            maxChars: 2000)
        XCTAssertEqual(fragments.count, 3)
        XCTAssertTrue(fragments.allSatisfy { $0.text.count <= 2000 })
    }
}
