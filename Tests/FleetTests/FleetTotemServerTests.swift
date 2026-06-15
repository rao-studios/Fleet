import Conduit
import XCTest

@testable import FleetConduit

/// Live gRPC round-trip: stand up the Fleet server, connect a fake Totem via
/// Conduit's own `MothershipRegistrationClient`, and pull a canned library
/// through the session stream — exercising bind → register → session → request.
final class FleetTotemServerTests: XCTestCase {

    func testRegisterAndPullLibrary() async throws {
        let server = FleetTotemServer()
        let port = Int.random(in: 19_000 ..< 21_000)
        await server.start(port: port)

        let totemId = UUID()
        let client = MothershipRegistrationClient(
            mothershipHost: "127.0.0.1",
            mothershipGRPCPort: port,
            totemId: totemId,
            totemHost: "127.0.0.1",
            totemGRPCPort: 9090,
            totemHTTPPort: 8081,
            requestDispatcher: FakeTotem(),
            logger: SilentLogger()
        )
        await client.startHeartbeatLoop()

        // Wait for the Totem to register.
        var registered = false
        for _ in 0 ..< 60 where !registered {
            registered = await server.connectedTotems().contains { $0.id == totemId }
            if !registered { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        XCTAssertTrue(registered, "Totem should register with the Fleet server")

        // Pull the library down the session stream (retry while the session opens).
        let importer = await server.importer()
        var groups: [TotemGroupSummary] = []
        for _ in 0 ..< 30 where groups.isEmpty {
            groups = (try? await importer.library(totemId: totemId, ownerId: "alice")) ?? []
            if groups.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        XCTAssertEqual(groups.map(\.id), ["g1"])
        XCTAssertEqual(groups.first?.documents.map(\.id), ["d1"])

        await client.stop()
        await server.stop()
    }
}

/// A Totem-side dispatcher that answers a library request with one canned group.
private struct FakeTotem: SessionRequestHandling {
    func handle(_ msg: Totem_V1_TotemSessionMessage) async -> Totem_V1_TotemSessionMessage? {
        guard case .libraryRequest = msg.payload else { return nil }
        var group = Totem_V1_TotemGroup()
        group.id = "g1"
        group.label = "Group One"
        var doc = Totem_V1_TotemDocument()
        doc.id = "d1"
        group.documents = [doc]

        var library = Totem_V1_TotemLibraryResponse()
        library.groups = [group]

        var response = Totem_V1_TotemSessionMessage()
        response.correlationID = msg.correlationID
        response.payload = .libraryResponse(library)
        return response
    }
}

private struct SilentLogger: ConduitLogger {
    func debug(_ label: String?, _ message: String) {}
    func info(_ label: String?, _ message: String) {}
    func warning(_ label: String?, _ message: String) {}
    func error(_ label: String?, _ message: String) {}
}
