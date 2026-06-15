import Conduit
import Foundation
import Logging

/// A Totem currently connected to the Fleet server (UI-facing; no raw proto).
public struct ConnectedTotem: Sendable, Identifiable, Equatable {
    public let id: UUID  // totemId
    public let host: String
    public let grpcPort: Int

    init(_ node: TotemNode) {
        self.id = node.totemId
        self.host = node.host
        self.grpcPort = node.grpcPort
    }
}

/// The Conduit server the Fleet client runs so Totems can dial in (with
/// `--fleet-host`/`--fleet-grpc-port`). Once a Totem connects, ``importer()``
/// pulls its catalog/content over the session stream.
///
/// Assembles Conduit's reusable pieces: `InMemoryTotemRegistry` +
/// `TotemSessionManager` + `ConduitMothershipServer` + `TotemQueryClient`.
public actor FleetTotemServer {

    private let registry: InMemoryTotemRegistry
    private let sessionManager: TotemSessionManager
    private let queryClient: TotemQueryClient
    private let server: ConduitMothershipServer
    public private(set) var port: Int?

    public init(logger: any ConduitLogger = SwiftLogConduitLogger(Logger(label: "fleet-conduit"))) {
        let registry = InMemoryTotemRegistry()
        let sessionManager = TotemSessionManager(logger: logger)
        self.registry = registry
        self.sessionManager = sessionManager
        self.queryClient = TotemQueryClient(sessionManager: sessionManager)
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

    /// Totems currently connected to this server.
    public func connectedTotems() async -> [ConnectedTotem] {
        await registry.activeNodes.map(ConnectedTotem.init)
    }

    /// Stream of the connected-Totem list, for live UI updates.
    public func totemsStream() async -> AsyncStream<[ConnectedTotem]> {
        let registry = self.registry
        return AsyncStream { continuation in
            let task = Task {
                for await nodes in await registry.changes() {
                    continuation.yield(nodes.map(ConnectedTotem.init))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Pull/convert helper bound to this server's session machinery.
    public func importer() -> TotemImporter {
        TotemImporter(client: queryClient)
    }
}
