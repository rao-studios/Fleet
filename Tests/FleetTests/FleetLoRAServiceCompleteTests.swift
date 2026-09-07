import Conduit
import FleetCore
import FleetInference
import GRPCCore
import XCTest

@testable import FleetConduit

/// The Complete RPC's refusals and its response mapping, without a server:
/// every decision that precedes GPU work is a pure function.
final class FleetLoRAServiceCompleteTests: XCTestCase {

    private func code(_ body: () throws -> Void) -> RPCError.Code? {
        do { try body() } catch let error as RPCError { return error.code } catch { return nil }
        return nil
    }

    func testTrainingSlotIsRefusedBeforeAnythingElse() {
        XCTAssertEqual(
            code {
                _ = try FleetLoRAServiceImpl.admit(
                    entryCID: "abc", isTraining: true, requestedCID: "abc",
                    inputJSON: "{}", abilityID: "email.triage")
            },
            .failedPrecondition)
    }

    func testStaleCIDPinIsRefusedAndNamesTheLiveCID() {
        do {
            _ = try FleetLoRAServiceImpl.admit(
                entryCID: "new", isTraining: false, requestedCID: "old",
                inputJSON: "{}", abilityID: "email.triage")
            XCTFail("expected a refusal")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, .failedPrecondition)
            XCTAssertTrue(error.message.contains("new"))
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testEmptyPinAcceptsWhateverCIDIsLive() throws {
        let value = try FleetLoRAServiceImpl.admit(
            entryCID: "new", isTraining: false, requestedCID: "",
            inputJSON: #"{"query":"idle"}"#, abilityID: "email.triage")
        XCTAssertEqual(value["query"]?.stringValue, "idle")
    }

    func testUnparsableInputIsInvalidArgument() {
        XCTAssertEqual(
            code {
                _ = try FleetLoRAServiceImpl.admit(
                    entryCID: "abc", isTraining: false, requestedCID: "",
                    inputJSON: "{not json", abilityID: "email.triage")
            },
            .invalidArgument)
    }

    func testResponseCarriesCanonicalJSONRawTextAndTheCID() throws {
        let json = try JSONParser.parse(#"{"b":1,"a":"x"}"#)
        let result = GatedResult(json: json, rawText: "{\"b\":1,\"a\":\"x\"}", trace: [], promptTokenCount: 42)
        let response = FleetLoRAServiceImpl.response(from: result, cid: "cid-1")
        XCTAssertEqual(response.outputJson, JSONCanonical.serialize(json))
        XCTAssertEqual(response.rawText, "{\"b\":1,\"a\":\"x\"}")
        XCTAssertEqual(response.promptTokens, 42)
        XCTAssertEqual(response.forcedFraction, 0)
        XCTAssertEqual(response.cid, "cid-1")
    }
}
