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

/// A single partition (the content unit) pulled from a Totem — the fine-tuning material.
public struct TotemPartition: Sendable, Identifiable {
    public let id: String
    public let documentId: String
    public let ownerId: String
    public let text: String
    public var score: Float?
}

/// Pulls a connected Totem's catalog and content over the session stream and
/// turns selected partitions into `ContextFragment`s. Wraps Conduit's
/// `TotemQueryClient`; callers pass a `totemId` and work in the value types above,
/// never raw proto / `TotemNode`.
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

    /// Partitions (with text) for the given documents — via the HNSW graph, whose
    /// nodes carry the partition content.
    public func partitions(
        totemId: UUID, ownerId: String, documentIds: [String]
    ) async throws -> [TotemPartition] {
        var request = Totem_V1_TotemHNSWGraphRequest()
        request.ownerID = ownerId
        request.scope = "documents"
        request.shardIndex = -1
        request.documentIds = documentIds

        let response = try await client.hnswGraph(request, totem: node(totemId))
        return response.nodes
            .filter { !$0.isDeleted && !$0.text.isEmpty }
            .map {
                TotemPartition(
                    id: $0.partitionID, documentId: $0.documentID,
                    ownerId: $0.documentOwnerID, text: $0.text, score: nil)
            }
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

    /// Mechanical organize: chunk to training size and dedupe → `ContextFragment`s.
    /// Pure (no network) — `static` so it's reusable and unit-testable on its own.
    public static func fragments(from partitions: [TotemPartition], maxChars: Int = 2000) -> [ContextFragment] {
        var seen = Set<String>()
        var fragments: [ContextFragment] = []
        for partition in partitions {
            let source = URL(string: "totem://partition/\(partition.id)")
                ?? URL(fileURLWithPath: "/totem/\(partition.id)")
            for (index, chunk) in TextChunker.chunk(partition.text, maxChars: maxChars).enumerated() {
                let key = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                fragments.append(
                    ContextFragment(
                        id: "\(partition.id)#\(index)", source: source, mediaType: .text,
                        text: chunk, metadata: ["source": "totem", "documentId": partition.documentId]))
            }
        }
        return fragments
    }
}
