import FleetCore
import XCTest

/// The input half of a training pair, pinned to bytes.
///
/// THE OTHER HALF OF THIS TEST LIVES IN MARY, at
/// `Tests/MaryFoundationTests/BehavioralPairParityTests.swift`, over the same
/// two fixture files. Mary projects a sealed episode into a pair when it
/// wants to know what an adapter would see; Fleet projects the stored Totem
/// document when it builds the training set. Those must agree byte for byte
/// — when they did not, the lead place was spelled `applications:textedit`
/// in training and `textedit` at inference, and every idle prediction was
/// made from an input the adapter had never been shown.
final class BehavioralParityTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testProjectedInputMatchesTheSharedGolden() throws {
        let episode = try fixture("behavior-parity-episode.json")
        let pair = try BehavioralPairProjector.pair(from: episode)

        let expected = try JSONParser.parse(fixture("behavior-parity-input.json"))

        XCTAssertEqual(
            JSONCanonical.serialize(pair.input),
            JSONCanonical.serialize(expected))
    }

    func testTheLeadCarriesItsLanePrefix() throws {
        let pair = try BehavioralPairProjector.pair(
            from: try fixture("behavior-parity-episode.json"))
        XCTAssertEqual(pair.input["ambient_lead"]?.stringValue, "applications:textedit")
        XCTAssertEqual(pair.input["ambient_mode"]?.stringValue, "focusedWorld")
        XCTAssertEqual(pair.input["fact_count"]?.doubleValue, 2)
    }

    func testTheSummaryIsTheRenderedTextInOrder() throws {
        let pair = try BehavioralPairProjector.pair(
            from: try fixture("behavior-parity-episode.json"))
        XCTAssertEqual(
            pair.input["ambient_summary"]?.stringValue,
            "applications:textedit Essay — 1,840 characters Cursor at line 12")
    }

    func testTheFixtureEpisodeIsOneTheTrainerWouldAccept() throws {
        let episode = try JSONParser.parse(fixture("behavior-parity-episode.json"))
        XCTAssertTrue(BehavioralPairProjector.isTrainable(episode))
    }
}
