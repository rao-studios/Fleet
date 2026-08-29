import Foundation

/// Where one training pair came from, and who should be credited for it.
public struct SourceProvenance: Sendable, Codable, Equatable {

    public enum Origin: String, Sendable, Codable {
        case manual
        case file
        case mock
        case totem
    }

    public var origin: Origin
    public var ownerId: String?
    public var totemId: String?
    public var documentId: String?
    public var groupId: String?
    /// Indices into a Totem document's ordered `texts` array. Conduit's document
    /// API returns partition texts in stored order without per-partition ids, so
    /// position is the stable address available to us.
    public var textIndices: [Int]
    public var sourceLabel: String?

    public init(
        origin: Origin,
        ownerId: String? = nil,
        totemId: String? = nil,
        documentId: String? = nil,
        groupId: String? = nil,
        textIndices: [Int] = [],
        sourceLabel: String? = nil
    ) {
        self.origin = origin
        self.ownerId = ownerId
        self.totemId = totemId
        self.documentId = documentId
        self.groupId = groupId
        self.textIndices = textIndices
        self.sourceLabel = sourceLabel
    }

    /// The key attribution shares are summed under: the owner when we know one,
    /// otherwise the file or source label, otherwise unattributed.
    public var attributionKey: String? {
        if let ownerId, !ownerId.isEmpty { return ownerId }
        if let sourceLabel, !sourceLabel.isEmpty { return "\(origin.rawValue):\(sourceLabel)" }
        return nil
    }

    public static let manual = SourceProvenance(origin: .manual)

    public static func mock(domain: String) -> SourceProvenance {
        SourceProvenance(origin: .mock, sourceLabel: domain)
    }

    public static func file(named name: String) -> SourceProvenance {
        SourceProvenance(origin: .file, sourceLabel: name)
    }
}

/// One training example: an input document and the output the LoRA should learn
/// to produce for it.
public struct JSONPair: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var input: JSONValue
    public var output: JSONValue
    public var provenance: SourceProvenance?

    public init(
        id: UUID = UUID(),
        input: JSONValue,
        output: JSONValue,
        provenance: SourceProvenance? = nil
    ) {
        self.id = id
        self.input = input
        self.output = output
        self.provenance = provenance
    }
}

/// A validated training set: N input/output pairs sharing one output schema.
public struct StateDataset: Sendable, Codable, Identifiable {
    public let id: UUID
    public var name: String
    public var pairs: [JSONPair]
    /// Extracted from the outputs when the dataset is created or edited.
    public var schema: SchemaTemplate
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        pairs: [JSONPair],
        schema: SchemaTemplate,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.pairs = pairs
        self.schema = schema
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Build a dataset by extracting (and strictly validating) the schema.
    public init(id: UUID = UUID(), name: String, pairs: [JSONPair]) throws {
        let schema = try SchemaExtractor.template(outputs: pairs.map(\.output))
        self.init(id: id, name: name, pairs: pairs, schema: schema)
    }

    /// The identity any LoRA trained from this dataset will be stored under.
    public var inputCID: String {
        ContentID.compute(inputs: pairs.map(\.input))
    }

    public var trainingTexts: [String] {
        pairs.map { PromptBuilder.trainingText(input: $0.input, output: $0.output) }
    }

    public init(from decoder: Decoder) throws {
        // Every field is optional-with-default so an older on-disk dataset keeps
        // loading after the model grows a field.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        pairs = try container.decodeIfPresent([JSONPair].self, forKey: .pairs) ?? []
        if let stored = try container.decodeIfPresent(SchemaTemplate.self, forKey: .schema) {
            schema = stored
        } else {
            schema = (try? SchemaExtractor.template(outputs: pairs.map(\.output)))
                ?? SchemaTemplate(root: .object([]))
        }
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
    }
}
