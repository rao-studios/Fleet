import XCTest

@testable import FleetCore
@testable import FleetMedia

final class FleetMediaTests: XCTestCase {

    private func writeTemp(_ name: String, _ contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fleet-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testPlainTextDecoder() async throws {
        let url = try writeTemp("note.txt", "first line\nsecond line")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let fragments = try await PlainTextDecoder().decode(url)
        XCTAssertEqual(fragments.count, 1)
        XCTAssertEqual(fragments.first?.mediaType, .text)
        XCTAssertEqual(fragments.first?.id, "note.txt#0")
    }

    func testCodeDecoderFencesWithLanguage() async throws {
        let url = try writeTemp("main.swift", "print(\"hi\")")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let fragments = try await CodeDecoder().decode(url)
        XCTAssertEqual(fragments.first?.mediaType, .code)
        XCTAssertEqual(fragments.first?.metadata?["language"], "swift")
        XCTAssertTrue(fragments.first?.text.hasPrefix("```swift") ?? false)
    }

    func testCSVDecoderFlattensRows() async throws {
        let url = try writeTemp("data.csv", "name,age\nAda,36\nAlan,41")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let fragments = try await CSVDecoder().decode(url)
        XCTAssertEqual(fragments.first?.mediaType, .table)
        XCTAssertTrue(fragments.first?.text.contains("name: Ada, age: 36") ?? false)
    }

    func testImageDecoderWithoutCaptionerDegrades() async throws {
        let fragments = try await ImageDecoder().decode(URL(fileURLWithPath: "/tmp/photo.png"))
        XCTAssertEqual(fragments.count, 1)
        XCTAssertEqual(fragments.first?.mediaType, .image)
        XCTAssertEqual(fragments.first?.text, "")
        XCTAssertEqual(fragments.first?.metadata?["status"], "no-captioner")
    }

    func testImageDecoderWithCaptioner() async throws {
        let decoder = ImageDecoder(captioning: { _ in "a red bicycle" })
        let fragments = try await decoder.decode(URL(fileURLWithPath: "/tmp/photo.png"))
        XCTAssertEqual(fragments.first?.text, "a red bicycle")
        XCTAssertEqual(fragments.first?.metadata?["kind"], "caption")
    }

    func testStandardRegistryCoversTextFamily() {
        let registry = DecoderRegistry.standard()
        XCTAssertTrue(registry.canDecode(URL(fileURLWithPath: "/tmp/a.md")))
        XCTAssertTrue(registry.canDecode(URL(fileURLWithPath: "/tmp/a.swift")))
        XCTAssertTrue(registry.canDecode(URL(fileURLWithPath: "/tmp/a.csv")))
        XCTAssertTrue(registry.canDecode(URL(fileURLWithPath: "/tmp/a.png")))
        XCTAssertFalse(registry.canDecode(URL(fileURLWithPath: "/tmp/a.unknownext")))
    }
}
