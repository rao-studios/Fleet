import Conduit
import FleetCore
import Foundation

/// A group on a connected Thread (catalog level).
public struct ThreadGroupSummary: Sendable, Identifiable {
    public let id: String
    public let label: String
    public let ownerId: String
    public let documents: [ThreadDocumentSummary]
}

/// A document within a Thread group.
public struct ThreadDocumentSummary: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let ownerId: String
}

/// One page of groups from a Thread's library. Groups are id-sorted, so the cursor
/// for the next page is simply the last group's id (see ``ThreadImporter/library``).
public struct ThreadGroupPage: Sendable {
    public let groups: [ThreadGroupSummary]
    public let hasMore: Bool

    public init(groups: [ThreadGroupSummary], hasMore: Bool) {
        self.groups = groups
        self.hasMore = hasMore
    }

    /// Cursor to pass as `afterId` for the next page ("" when there is none).
    public var nextAfterId: String { groups.last?.id ?? "" }
}

/// A search hit from a Thread: one partition of a document, with its score.
public struct ThreadPartition: Sendable, Identifiable {
    public let id: String
    public let documentId: String
    public let ownerId: String
    public let text: String
    public var score: Float?
}

/// A document's full content, as Conduit's documents API returns it.
///
/// `texts` holds the document's partitions in stored order. The API carries no
/// per-partition ids, so position within this array is the stable address —
/// which is what ``FleetCore/SourceProvenance/textIndices`` records.
public struct ThreadDocument: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let ownerId: String
    public let groupId: String
    public let groupLabel: String
    public let createdAt: Date
    public let texts: [String]
    public let mediaType: String

    /// The document's partitions joined back into one body.
    public var body: String {
        texts.joined(separator: "\n\n")
    }
}

/// The result of a document fetch, including what the Thread declined to return.
public struct ThreadDocumentFetch: Sendable {
    public let documents: [ThreadDocument]
    /// Ids that were requested but not returned — the Thread skips documents the
    /// caller may not read rather than failing the whole request, so the count
    /// difference is the only signal that something was withheld.
    public let inaccessibleIds: [String]
}

/// Pulls a connected Thread's catalog and content over the session stream. Wraps
/// Conduit's `ThreadQueryClient`; callers pass a `threadId` and work in the value
/// types above, never raw proto / `ThreadNode`.
public struct ThreadImporter: Sendable {

    private let client: ThreadQueryClient

    public init(client: ThreadQueryClient) {
        self.client = client
    }

    // The query client only routes by `threadId`; a minimal node suffices.
    private func node(_ threadId: UUID) -> ThreadNode {
        ThreadNode(threadId: threadId, host: "", grpcPort: 0, httpPort: 0)
    }

    /// One page of groups (and their documents) on the Thread.
    ///
    /// Cursor-paginated to match Sewn's debug client: the server returns up to
    /// `limit` id-sorted groups after `afterId` plus a `hasMore` flag. Pass the
    /// previous page's ``ThreadGroupPage/nextAfterId`` to fetch the next page;
    /// `limit: 0` falls back to "return everything".
    public func library(
        threadId: UUID, ownerId: String, includeAvailable: Bool = true,
        limit: Int = 25, afterId: String = ""
    ) async throws -> ThreadGroupPage {
        var request = Thread_V1_ThreadLibraryRequest()
        request.ownerID = ownerId
        request.includeAvailable = includeAvailable
        request.limit = Int32(limit)
        request.afterID = afterId
        request.threadID = threadId.uuidString

        let response = try await client.library(request, thread: node(threadId))
        let groups = response.groups.map { group in
            ThreadGroupSummary(
                id: group.id, label: group.label, ownerId: group.ownerID,
                documents: group.documents.map {
                    ThreadDocumentSummary(id: $0.id, name: $0.name, ownerId: $0.ownerID)
                })
        }
        return ThreadGroupPage(groups: groups, hasMore: response.hasMore_p)
    }

    /// Full content for the given documents.
    ///
    /// This replaces the old HNSW-graph fetch, which was retired along with that
    /// engine. Documents the owner may not read are silently omitted by the
    /// Thread, so the difference is reported rather than left invisible.
    public func documents(
        threadId: UUID, ownerId: String, documentIds: [String]
    ) async throws -> ThreadDocumentFetch {
        var request = Thread_V1_ThreadDocumentsRequest()
        request.ownerID = ownerId
        request.documentIds = documentIds

        let response = try await client.documents(request, thread: node(threadId))
        let documents = response.documents.map { document in
            ThreadDocument(
                id: document.id,
                name: document.name,
                ownerId: document.ownerID,
                groupId: document.groupID,
                groupLabel: document.groupLabel,
                createdAt: Date(timeIntervalSince1970: TimeInterval(document.createdAt)),
                texts: document.texts,
                mediaType: document.mediaType
            )
        }
        let returned = Set(documents.map(\.id))
        return ThreadDocumentFetch(
            documents: documents,
            inaccessibleIds: documentIds.filter { !returned.contains($0) }
        )
    }

    /// Search the Thread and return matching partitions (with scores).
    public func search(
        threadId: UUID, query: String, ownerId: String, scope: String = "global", topK: Int = 20
    ) async throws -> [ThreadPartition] {
        var request = Thread_V1_ThreadSearchRequest()
        request.queryText = query
        request.ownerID = ownerId
        request.scope = scope
        request.topK = Int32(topK)

        let response = try await client.search(request, thread: node(threadId))
        return response.results.map {
            ThreadPartition(
                id: $0.partitionID, documentId: $0.documentID,
                ownerId: $0.ownerID, text: $0.text, score: $0.score)
        }
    }

    /// Provenance for material taken from a Thread document.
    ///
    /// Pure (no network) so it can be unit-tested on its own. `textIndices`
    /// records which partitions of the document were used, which is the addressing
    /// the documents API leaves us with now that partition ids are gone.
    public static func provenance(
        for document: ThreadDocument,
        threadId: UUID,
        textIndices: [Int]
    ) -> SourceProvenance {
        SourceProvenance(
            origin: .thread,
            ownerId: document.ownerId,
            threadId: threadId.uuidString,
            documentId: document.id,
            groupId: document.groupId,
            textIndices: textIndices,
            sourceLabel: document.name
        )
    }
}
