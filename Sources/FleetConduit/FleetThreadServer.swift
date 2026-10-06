import Conduit
import Foundation
import Logging

/// A Thread currently connected to the Fleet server (UI-facing; no raw proto).
public struct ConnectedThread: Sendable, Identifiable, Equatable {
    public let id: UUID  // threadId
    public let host: String
    public let grpcPort: Int

    init(_ node: ThreadNode) {
        self.id = node.threadId
        self.host = node.host
        self.grpcPort = node.grpcPort
    }
}

/// The Conduit server the Fleet client runs so Threads can dial in (with
/// `--fleet-host`/`--fleet-grpc-port`). Once a Thread connects, ``importer()``
/// pulls its catalog/content over the session stream.
///
/// Assembles Conduit's reusable pieces: `InMemoryThreadRegistry` +
/// `ThreadSessionManager` + `ConduitMothershipServer` + `ThreadQueryClient`.
public actor FleetThreadServer {

    private let registry: InMemoryThreadRegistry
    private let sessionManager: ThreadSessionManager
    private let queryClient: ThreadQueryClient
    private let server: ConduitMothershipServer
    public private(set) var port: Int?

    public init(logger: any ConduitLogger = SwiftLogConduitLogger(Logger(label: "fleet-conduit"))) {
        let registry = InMemoryThreadRegistry()
        let sessionManager = ThreadSessionManager(logger: logger)
        self.registry = registry
        self.sessionManager = sessionManager
        self.queryClient = ThreadQueryClient(sessionManager: sessionManager)
        self.server = ConduitMothershipServer(
            registry: registry, mothershipId: UUID(),
            sessionManager: sessionManager, logger: logger)
    }

    public var isRunning: Bool { port != nil }

    public func start(port: Int) async {
        await server.start(port: port)
        self.port = port
    }

    public func stop() async {
        await server.stop()
        self.port = nil
    }

    /// Threads currently connected to this server.
    public func connectedThreads() async -> [ConnectedThread] {
        await registry.activeNodes.map(ConnectedThread.init)
    }

    /// Stream of the connected-Thread list, for live UI updates.
    public func threadsStream() async -> AsyncStream<[ConnectedThread]> {
        let registry = self.registry
        return AsyncStream { continuation in
            let task = Task {
                for await nodes in await registry.changes() {
                    continuation.yield(nodes.map(ConnectedThread.init))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Pull/convert helper bound to this server's session machinery.
    public func importer() -> ThreadImporter {
        ThreadImporter(client: queryClient)
    }
}
