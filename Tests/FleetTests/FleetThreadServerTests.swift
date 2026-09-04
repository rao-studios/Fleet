import Conduit
import XCTest

@testable import FleetConduit

/// Live gRPC round-trip: stand up the Fleet server, connect a fake Thread via
/// Conduit's own `MothershipRegistrationClient`, and pull a canned library
/// through the session stream — exercising bind → register → session → request.
final class FleetThreadServerTests: XCTestCase {

    func testRegisterAndPullLibrary() async throws {
        let server = FleetThreadServer()
        let port = Int.random(in: 19_000 ..< 21_000)
        await server.start(port: port)

        let threadId = UUID()
        let client = MothershipRegistrationClient(
            mothershipHost: "127.0.0.1",
            mothershipGRPCPort: port,
            threadId: threadId,
            threadHost: "127.0.0.1",
            threadGRPCPort: 9090,
            threadHTTPPort: 8081,
            requestDispatcher: FakeThread(),
            logger: SilentLogger()
        )
        await client.startHeartbeatLoop()

        // Wait for the Thread to register.
        var registered = false
        for _ in 0 ..< 60 where !registered {
            registered = await server.connectedThreads().contains { $0.id == threadId }
            if !registered { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        XCTAssertTrue(registered, "Thread should register with the Fleet server")

        // Pull the library down the session stream (retry while the session opens).
        let importer = await server.importer()
        var groups: [ThreadGroupSummary] = []
        for _ in 0 ..< 30 where groups.isEmpty {
            groups = ((try? await importer.library(threadId: threadId, ownerId: "alice"))?.groups) ?? []
            if groups.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        XCTAssertEqual(groups.map(\.id), ["g1"])
        XCTAssertEqual(groups.first?.documents.map(\.id), ["d1"])

        await client.stop()
        await server.stop()
    }
}

/// A Thread-side dispatcher that answers a library request with one canned group.
private struct FakeThread: SessionRequestHandling {
    func handle(_ msg: Thread_V1_ThreadSessionMessage) async -> Thread_V1_ThreadSessionMessage? {
        guard case .libraryRequest = msg.payload else { return nil }
        var group = Thread_V1_ThreadGroup()
        group.id = "g1"
        group.label = "Group One"
        var doc = Thread_V1_ThreadDocument()
        doc.id = "d1"
        group.documents = [doc]

        var library = Thread_V1_ThreadLibraryResponse()
        library.groups = [group]

        var response = Thread_V1_ThreadSessionMessage()
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
