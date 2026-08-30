import Foundation
import Network

/// Tiny HTTP/1.1 `/health` listener so Mary can treat Fleet like Seer/Totem.
public final class FleetHealthServer: @unchecked Sendable {
    private var listener: NWListener?

    public init() {}

    public func start(host: String = "127.0.0.1", port: Int) throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(
            using: parameters,
            on: NWEndpoint.Port(rawValue: UInt16(port))!)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
                _, _, _, _ in
                let body = "ok"
                let header =
                    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(
                    content: Data(header.utf8),
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    })
            }
        }
        listener.start(queue: .global())
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }
}
