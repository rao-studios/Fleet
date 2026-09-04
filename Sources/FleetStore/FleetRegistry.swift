import FleetCore
import Foundation

/// A LoRA as the library lists it — everything needed to render a row without
/// touching the weights on disk.
public struct LoRAEntry: Sendable, Codable, Identifiable, Equatable {
    /// The content id: SHA256 of the training input set. This is the primary key.
    public let cid: String
    public var label: String?
    public var modelId: String
    public var datasetId: UUID?
    /// Identity of the output schema, so interchangeable LoRAs can be found.
    public var schemaHash: String
    public var schemaDescription: String
    public var pairCount: Int
    public var rank: Int
    public var scale: Float
    public var numLayers: Int
    public var iterations: Int
    public var createdAt: Date
    public var updatedAt: Date
    /// Incremented each time this CID is retrained — same inputs, evolved outputs.
    public var generation: Int
    /// Named-slot addressing: one LoRA per totem × ability. Nil for CID-only smoke LoRAs.
    public var totemId: String?
    public var abilityId: String?
    /// Share of held-out pairs the published adapter reproduced exactly.
    /// Nil means never scored — an entry written before scoring existed.
    public var evalExactMatch: Double?
    /// How many held-out pairs that score is over.
    public var evalCases: Int

    public var id: String { cid }

    public init(
        cid: String,
        label: String? = nil,
        modelId: String,
        datasetId: UUID? = nil,
        schemaHash: String,
        schemaDescription: String,
        pairCount: Int,
        rank: Int,
        scale: Float,
        numLayers: Int,
        iterations: Int,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        generation: Int = 1,
        totemId: String? = nil,
        abilityId: String? = nil,
        evalExactMatch: Double? = nil,
        evalCases: Int = 0
    ) {
        self.cid = cid
        self.label = label
        self.modelId = modelId
        self.datasetId = datasetId
        self.schemaHash = schemaHash
        self.schemaDescription = schemaDescription
        self.pairCount = pairCount
        self.rank = rank
        self.scale = scale
        self.numLayers = numLayers
        self.iterations = iterations
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.generation = generation
        self.totemId = totemId
        self.abilityId = abilityId
        self.evalExactMatch = evalExactMatch
        self.evalCases = evalCases
    }

    /// The floor a freshly trained adapter must clear before anything is
    /// allowed to act through it. Overridable so `fleet smoke` and
    /// experiments can lower it deliberately rather than by accident.
    public static let readyMinimumExactMatch: Double = {
        if let raw = ProcessInfo.processInfo.environment["FLEET_READY_MIN_EXACT"],
           let value = Double(raw)
        { return value }
        return 0.5
    }()

    /// Whether this adapter is good enough to be reached for.
    ///
    /// PIN: A NIL SCORE PASSES. Entries written before scoring existed have
    /// no number, and refusing those would silently retire every adapter
    /// already in the library. Every new run writes a score, so the gate
    /// applies to exactly the adapters it can judge.
    public var passesReadyGate: Bool {
        (evalExactMatch ?? 1) >= Self.readyMinimumExactMatch
    }

    /// `72% of 11` — the sentence a monitor shows beside a slot.
    public var evalSummary: String? {
        guard let evalExactMatch else { return nil }
        return "\(Int((evalExactMatch * 100).rounded()))% of \(evalCases)"
    }

    public var shortCID: String { ContentID.short(cid) }

    public var displayName: String {
        if let label, !label.isEmpty { return label }
        return shortCID
    }

    /// Tolerant decoding so a store written by an older build still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cid = try container.decode(String.self, forKey: .cid)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId) ?? ""
        datasetId = try container.decodeIfPresent(UUID.self, forKey: .datasetId)
        schemaHash = try container.decodeIfPresent(String.self, forKey: .schemaHash) ?? ""
        schemaDescription =
            try container.decodeIfPresent(String.self, forKey: .schemaDescription) ?? ""
        pairCount = try container.decodeIfPresent(Int.self, forKey: .pairCount) ?? 0
        rank = try container.decodeIfPresent(Int.self, forKey: .rank) ?? 8
        scale = try container.decodeIfPresent(Float.self, forKey: .scale) ?? 20
        numLayers = try container.decodeIfPresent(Int.self, forKey: .numLayers) ?? 16
        iterations = try container.decodeIfPresent(Int.self, forKey: .iterations) ?? 0
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
        generation = try container.decodeIfPresent(Int.self, forKey: .generation) ?? 1
        totemId = try container.decodeIfPresent(String.self, forKey: .totemId)
        abilityId = try container.decodeIfPresent(String.self, forKey: .abilityId)
        evalExactMatch = try container.decodeIfPresent(Double.self, forKey: .evalExactMatch)
        evalCases = try container.decodeIfPresent(Int.self, forKey: .evalCases) ?? 0
    }
}

/// A named collection of LoRAs.
public struct GroupEntry: Sendable, Codable, Identifiable, Equatable {
    public let id: String
    public var label: String
    public var metadata: [String: String]
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        label: String,
        metadata: [String: String] = [:],
        createdAt: Date = .now
    ) {
        self.id = id
        self.label = label
        self.metadata = metadata
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? "Untitled"
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
    }
}

/// A dataset as the list shows it, without hydrating its pairs.
public struct DatasetEntry: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var pairCount: Int
    public var schemaHash: String
    public var schemaDescription: String
    /// The CID a LoRA trained from this dataset will occupy.
    public var inputCID: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        name: String,
        pairCount: Int,
        schemaHash: String,
        schemaDescription: String,
        inputCID: String,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.pairCount = pairCount
        self.schemaHash = schemaHash
        self.schemaDescription = schemaDescription
        self.inputCID = inputCID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public init(dataset: StateDataset) {
        self.init(
            id: dataset.id,
            name: dataset.name,
            pairCount: dataset.pairs.count,
            schemaHash: dataset.schema.hashHex,
            schemaDescription: dataset.schema.description,
            inputCID: dataset.inputCID,
            createdAt: dataset.createdAt,
            updatedAt: dataset.updatedAt
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        pairCount = try container.decodeIfPresent(Int.self, forKey: .pairCount) ?? 0
        schemaHash = try container.decodeIfPresent(String.self, forKey: .schemaHash) ?? ""
        schemaDescription =
            try container.decodeIfPresent(String.self, forKey: .schemaDescription) ?? ""
        inputCID = try container.decodeIfPresent(String.self, forKey: .inputCID) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
    }
}

/// The single index file for `fleet-db`.
///
/// One denormalized `Codable` struct rather than a database: the whole thing is
/// small (a few hundred entries), it loads in one read, and membership is stored
/// in both directions so neither "LoRAs in this group" nor "groups for this LoRA"
/// needs a scan. The cost is that the two maps must be kept consistent by hand,
/// which is why only ``RegistryMutator`` is allowed to change them.
public struct FleetRegistry: Sendable, Codable {
    public var loras: [String: LoRAEntry] = [:]
    public var groups: [String: GroupEntry] = [:]
    /// group id → member cids, kept sorted for cursor pagination.
    public var groupMembers: [String: [String]] = [:]
    /// cid → group ids, kept sorted.
    public var loraGroups: [String: [String]] = [:]
    public var datasets: [UUID: DatasetEntry] = [:]
    /// `"totemId|abilityId"` → cid. The named slot is the user-facing identity;
    /// the CID remains provenance on the entry.
    public var namedSlots: [String: String] = [:]

    public init() {}

    /// Every field decodes with a default so adding one later does not orphan an
    /// existing store.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        loras = try container.decodeIfPresent([String: LoRAEntry].self, forKey: .loras) ?? [:]
        groups = try container.decodeIfPresent([String: GroupEntry].self, forKey: .groups) ?? [:]
        groupMembers =
            try container.decodeIfPresent([String: [String]].self, forKey: .groupMembers) ?? [:]
        loraGroups =
            try container.decodeIfPresent([String: [String]].self, forKey: .loraGroups) ?? [:]
        datasets = try container.decodeIfPresent([UUID: DatasetEntry].self, forKey: .datasets) ?? [:]
        namedSlots =
            try container.decodeIfPresent([String: String].self, forKey: .namedSlots) ?? [:]
        normalize()
    }

    /// Restore the invariants the readers rely on: sorted membership arrays, and
    /// no membership pointing at a LoRA or group that is gone.
    public mutating func normalize() {
        for (groupId, members) in groupMembers {
            let live = members.filter { loras[$0] != nil }
            groupMembers[groupId] = Array(Set(live)).sorted()
        }
        groupMembers = groupMembers.filter { groups[$0.key] != nil }
        for (cid, ids) in loraGroups {
            let live = ids.filter { groups[$0] != nil }
            loraGroups[cid] = Array(Set(live)).sorted()
        }
        loraGroups = loraGroups.filter { loras[$0.key] != nil }
        namedSlots = namedSlots.filter { loras[$0.value] != nil }
    }

    // MARK: - Sorted views (the pagination cursors walk these)

    public var sortedLoRACIDs: [String] { loras.keys.sorted() }
    public var sortedDatasetIDs: [UUID] {
        datasets.values.sorted { $0.updatedAt > $1.updatedAt }.map(\.id)
    }
    public var sortedGroups: [GroupEntry] {
        groups.values.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }
}
