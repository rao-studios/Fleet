import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import FleetService

/// Hosts `FleetLoRA` on gRPC plus HTTP `/health`. Default ports: HTTP 8083, gRPC 9093.
public enum FleetLoRAServer {
    public static let defaultHTTPPort = 8083
    public static let defaultGRPCPort = 9093

    public static func serve(
        httpPort: Int = defaultHTTPPort,
        grpcPort: Int = defaultGRPCPort,
        totemHost: String = "127.0.0.1",
        totemPort: Int = 9090
    ) async throws {
        let service = FleetService()
        _ = await service.start()
        let impl = FleetLoRAServiceImpl(
            service: service,
            corpus: TotemCorpusClient(host: totemHost, port: totemPort))
        let health = FleetHealthServer()
        try health.start(port: httpPort)
        let transport = HTTP2ServerTransport.Posix(
            address: .ipv4(host: "127.0.0.1", port: grpcPort),
            transportSecurity: .plaintext
        )
        let server = GRPCServer(transport: transport, services: [impl])
        try await server.serve()
    }
}
