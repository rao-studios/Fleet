import Conduit
import FleetCore
import Foundation

/// A group on a connected Totem (catalog level).
public struct TotemGroupSummary: Sendable, Identifiable {
    public let id: String
    public let label: String
    public let ownerId: String
    public let documents: [TotemDocumentSummary]
}

/// A document within a Totem group.
public struct TotemDocumentSummary: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let ownerId: String
}

/// One page of groups from a Totem's library. Groups are id-sorted, so the cursor
/// for the next page is simply the last group's id (see ``TotemImporter/library``).
public struct TotemGroupPage: Sendable {
    public let groups: [TotemGroupSummary]
    public let hasMore: Bool

    public init(groups: [TotemGroupSummary], hasMore: Bool) {
        self.groups = groups
        self.hasMore = hasMore
    }

    /// Cursor to pass as `afterId` for the next page ("" when there is none).
    public var nextAfterId: String { groups.last?.id ?? "" }
}

/// A search hit from a Totem: one partition of a document, with its score.
public struct TotemPartition: Sendable, Identifiable {
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
public struct TotemDocument: Sendable, Identifiable {
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

/// The result of a document fetch, including what the Totem declined to return.
public struct TotemDocumentFetch: Sendable {
    public let documents: [TotemDocument]
    /// Ids that were requested but not returned — the Totem skips documents the
    /// caller may not read rather than failing the whole request, so the count
    /// difference is the only signal that something was withheld.
    public let inaccessibleIds: [String]
}

/// Pulls a connected Totem's catalog and content over the session stream. Wraps
/// Conduit's `TotemQueryClient`; callers pass a `totemId` and work in the value
/// types above, never raw proto / `TotemNode`.
public struct TotemImporter: Sendable {

    private let client: TotemQueryClient

    public init(client: TotemQueryClient) {
        self.client = client
    }

    // The query client only routes by `totemId`; a minimal node suffices.
    private func node(_ totemId: UUID) -> TotemNode {
        TotemNode(totemId: totemId, host: "", grpcPort: 0, httpPort: 0)
    }

    /// One page of groups (and their documents) on the Totem.
    ///
    /// Cursor-paginated to match Seer's debug client: the server returns up to
    /// `limit` id-sorted groups after `afterId` plus a `hasMore` flag. Pass the
    /// previous page's ``TotemGroupPage/nextAfterId`` to fetch the next page;
    /// `limit: 0` falls back to "return everything".
    public func library(
        totemId: UUID, ownerId: String, includeAvailable: Bool = true,
        limit: Int = 25, afterId: String = ""
    ) async throws -> TotemGroupPage {
        var request = Totem_V1_TotemLibraryRequest()
        request.ownerID = ownerId
        request.includeAvailable = includeAvailable
        request.limit = Int32(limit)
        request.afterID = afterId
        request.totemID = totemId.uuidString

        let response = try await client.library(request, totem: node(totemId))
        let groups = response.groups.map { group in
            TotemGroupSummary(
                id: group.id, label: group.label, ownerId: group.ownerID,
                documents: group.documents.map {
                    TotemDocumentSummary(id: $0.id, name: $0.name, ownerId: $0.ownerID)
                })
        }
        return TotemGroupPage(groups: groups, hasMore: response.hasMore_p)
    }

    /// Full content for the given documents.
    ///
    /// This replaces the old HNSW-graph fetch, which was retired along with that
    /// engine. Documents the owner may not read are silently omitted by the
    /// Totem, so the difference is reported rather than left invisible.
    public func documents(
        totemId: UUID, ownerId: String, documentIds: [String]
    ) async throws -> TotemDocumentFetch {
        var request = Totem_V1_TotemDocumentsRequest()
        request.ownerID = ownerId
        request.documentIds = documentIds

        let response = try await client.documents(request, totem: node(totemId))
        let documents = response.documents.map { document in
            TotemDocument(
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
        return TotemDocumentFetch(
            documents: documents,
            inaccessibleIds: documentIds.filter { !returned.contains($0) }
        )
    }

    /// Search the Totem and return matching partitions (with scores).
    public func search(
        totemId: UUID, query: String, ownerId: String, scope: String = "global", topK: Int = 20
    ) async throws -> [TotemPartition] {
        var request = Totem_V1_TotemSearchRequest()
        request.queryText = query
        request.ownerID = ownerId
        request.scope = scope
        request.topK = Int32(topK)

        let response = try await client.search(request, totem: node(totemId))
        return response.results.map {
            TotemPartition(
                id: $0.partitionID, documentId: $0.documentID,
                ownerId: $0.ownerID, text: $0.text, score: $0.score)
        }
    }

    /// Provenance for material taken from a Totem document.
    ///
    /// Pure (no network) so it can be unit-tested on its own. `textIndices`
    /// records which partitions of the document were used, which is the addressing
    /// the documents API leaves us with now that partition ids are gone.
    public static func provenance(
        for document: TotemDocument,
        totemId: UUID,
        textIndices: [Int]
    ) -> SourceProvenance {
        SourceProvenance(
            origin: .totem,
            ownerId: document.ownerId,
            totemId: totemId.uuidString,
            documentId: document.id,
            groupId: document.groupId,
            textIndices: textIndices,
            sourceLabel: document.name
        )
    }
}
