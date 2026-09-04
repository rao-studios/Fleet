import Conduit
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

/// One-shot HTTP/2 calls against the local Thread node's ThreadLibrary (:9090).
/// Fleet pulls a training corpus itself — Threads no longer dial into Fleet.
public actor ThreadCorpusClient {
    private let host: String
    private let port: Int

    public init(host: String = "127.0.0.1", port: Int = 9090) {
        self.host = host
        self.port = port
    }

    public func exportCorpus(
        ownerID: String,
        groupIDs: [String] = [],
        documentIDPrefix: String = "mary-behavior-",
        afterID: String = "",
        limit: Int = 200
    ) async throws -> (documents: [Thread_V1_ThreadDocumentContent], hasMore: Bool) {
        var request = Thread_V1_ThreadExportCorpusRequest()
        request.ownerID = ownerID
        request.groupIds = groupIDs
        request.documentIDPrefix = documentIDPrefix
        request.afterID = afterID
        request.limit = Int32(limit)
        var options = GRPCCore.CallOptions.defaults
        options.timeout = .seconds(60)
        return try await withGRPCClient(transport: try makeTransport()) { client in
            let stub = Thread_V1_ThreadLibrary.Client(wrapping: client)
            let response = try await stub.exportCorpus(request, options: options)
            return (response.documents, response.hasMore_p)
        }
    }

    /// Page until exhausted (capped) and return every document body.
    public func exportAll(
        ownerID: String,
        groupIDs: [String] = [],
        documentIDPrefix: String = "mary-behavior-"
    ) async throws -> [Thread_V1_ThreadDocumentContent] {
        var all: [Thread_V1_ThreadDocumentContent] = []
        var after = ""
        for _ in 0..<50 {
            let page = try await exportCorpus(
                ownerID: ownerID,
                groupIDs: groupIDs,
                documentIDPrefix: documentIDPrefix,
                afterID: after,
                limit: 200)
            all.append(contentsOf: page.documents)
            guard page.hasMore, let last = page.documents.last else { break }
            after = last.id
        }
        return all
    }

    private func makeTransport() throws -> HTTP2ClientTransport.Posix {
        try .http2NIOPosix(
            target: .ipv4(host: host, port: port),
            transportSecurity: .plaintext
        )
    }
}
