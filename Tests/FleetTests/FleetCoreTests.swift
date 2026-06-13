import XCTest

@testable import FleetCore

final class FleetCoreTests: XCTestCase {

    func testChunkerReturnsSingleChunkWhenShort() {
        let chunks = TextChunker.chunk("hello world", maxChars: 100)
        XCTAssertEqual(chunks, ["hello world"])
    }

    func testChunkerSplitsOnParagraphs() {
        let text = String(repeating: "a", count: 1500) + "\n\n" + String(repeating: "b", count: 1500)
        let chunks = TextChunker.chunk(text, maxChars: 2000)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 2000 })
    }

    func testChunkerHardSplitsOversizedParagraph() {
        let chunks = TextChunker.chunk(String(repeating: "x", count: 5000), maxChars: 2000)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 2000 })
        XCTAssertEqual(chunks.joined().count, 5000)
    }

    func testCorpusFiltersEmptyText() {
        let url = URL(fileURLWithPath: "/tmp/x.txt")
        let corpus = Corpus([
            ContextFragment(source: url, text: "keep me"),
            ContextFragment(source: url, mediaType: .image, text: "   "),
            ContextFragment(source: url, mediaType: .image, text: ""),
        ])
        XCTAssertEqual(corpus.textExamples, ["keep me"])
        XCTAssertEqual(corpus.count, 3)
    }

    func testDatasetFormatterSplit() {
        let url = URL(fileURLWithPath: "/tmp/x.txt")
        let fragments = (0 ..< 10).map { ContextFragment(source: url, text: "example \($0)") }
        let (train, valid) = DatasetFormatter().split(Corpus(fragments), validationFraction: 0.2)
        XCTAssertEqual(train.count + valid.count, 10)
        XCTAssertEqual(valid.count, 2)
        XCTAssertFalse(train.isEmpty)
    }

    func testDatasetFormatterWritesJSONL() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        try DatasetFormatter().writeJSONL(
            train: ["alpha", "beta"], valid: ["gamma"], to: dir)

        let trainText = try String(
            contentsOf: dir.appendingPathComponent("train.jsonl"), encoding: .utf8)
        let lines = trainText.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(trainText.contains("{\"text\":\"alpha\"}"))
    }

    func testRegistryRoutesByExtension() async throws {
        var registry = DecoderRegistry()
        registry.register(StubDecoder(ext: "abc"))
        XCTAssertTrue(registry.canDecode(URL(fileURLWithPath: "/tmp/file.abc")))
        XCTAssertFalse(registry.canDecode(URL(fileURLWithPath: "/tmp/file.xyz")))

        let fragments = try await registry.decode(URL(fileURLWithPath: "/tmp/file.abc"))
        XCTAssertEqual(fragments.first?.text, "stub")

        // Unknown extension routes to nothing rather than throwing.
        let none = try await registry.decode(URL(fileURLWithPath: "/tmp/file.xyz"))
        XCTAssertTrue(none.isEmpty)
    }
}

private struct StubDecoder: MediaDecoder {
    let ext: String
    var supportedExtensions: Set<String> { [ext] }
    func decode(_ url: URL) async throws -> [ContextFragment] {
        [ContextFragment(source: url, text: "stub")]
    }
}
