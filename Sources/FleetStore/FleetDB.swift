import FleetCore
import Foundation

/// A page of results plus the cursor to continue from.
public struct Page<Element: Sendable>: Sendable {
    public var items: [Element]
    public var hasMore: Bool
    /// Pass back as `after` to fetch the next page; `nil` when the list is done.
    public var nextCursor: String?

    public init(items: [Element], hasMore: Bool, nextCursor: String?) {
        self.items = items
        self.hasMore = hasMore
        self.nextCursor = nextCursor
    }
}

/// The files that make a stored LoRA self-describing.
public enum LoRAArtifact {
    public static let weights = "adapters.safetensors"
    public static let adapterConfig = "adapter_config.json"
    public static let schema = "schema.json"
    public static let datasetSnapshot = "dataset-snapshot.json"
    public static let manifest = "manifest.json"
}

/// `fleet-db` — content-addressed storage for datasets and trained LoRAs.
///
/// On-disk layout under `~/Documents/fleet-db` (or the configured root):
/// ```
/// fleet-db/
///   registry               the single index (see FleetRegistry)
///   datasets/<uuid>        StateDataset
///   loras/<cid>/           adapters.safetensors, adapter_config.json,
///                          schema.json, dataset-snapshot.json, manifest.json
///   cache/                 derived data that can always be rebuilt
/// ```
/// A LoRA lives at its content id, so retraining the same inputs replaces the
/// directory in place instead of accumulating a new UUID every time.
public actor FleetDB {

    private let registry: RegistryMutator

    public init(registry: RegistryMutator = RegistryMutator()) {
        self.registry = registry
    }

    // MARK: - Locations

    public nonisolated static var root: URL { FilePersistence.getDefaultURL() }

    /// Where a LoRA's weights and metadata live.
    public nonisolated func adapterDirectory(cid: String) -> URL {
        Self.root.appendingPathComponent("loras").appendingPathComponent(cid)
    }

    public nonisolated func cacheDirectory() -> URL {
        Self.root.appendingPathComponent("cache")
    }

    /// A scratch directory for a training run, published under a CID when it
    /// succeeds and deleted when it does not.
    public nonisolated func makeStagingDirectory() throws -> URL {
        let url = Self.root
            .appendingPathComponent("loras")
            .appendingPathComponent(".staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Registry access

    public nonisolated var snapshot: FleetRegistry { registry.snapshot }

    public func flush() async {
        await registry.flushNow()
    }

    public func shutdown() async {
        await registry.shutdown()
    }

    // MARK: - Datasets

    public func saveDataset(_ dataset: StateDataset) async {
        var updated = dataset
        updated.updatedAt = .now
        let stored = updated
        datasetFile(stored.id).save(state: stored)
        let entry = DatasetEntry(dataset: stored)
        await registry.mutate { $0.datasets[entry.id] = entry }
    }

    public func loadDataset(id: UUID) -> StateDataset? {
        datasetFile(id).restore()
    }

    public func datasetEntry(id: UUID) -> DatasetEntry? {
        snapshot.datasets[id]
    }

    /// Datasets newest-first, paginated by id cursor.
    public func datasets(after cursor: String? = nil, limit: Int = 25) -> Page<DatasetEntry> {
        let ordered = snapshot.sortedDatasetIDs
        return paginate(ordered.map(\.uuidString), after: cursor, limit: limit) { id in
            UUID(uuidString: id).flatMap { self.snapshot.datasets[$0] }
        }
    }

    public func allDatasets() -> [DatasetEntry] {
        snapshot.sortedDatasetIDs.compactMap { snapshot.datasets[$0] }
    }

    public func deleteDataset(id: UUID) async {
        datasetFile(id).purge()
        await registry.mutateAndFlush { registry in
            registry.datasets.removeValue(forKey: id)
            // Trained LoRAs survive their dataset: the weights are still valid and
            // the snapshot beside them records what they were trained on.
            for (cid, entry) in registry.loras where entry.datasetId == id {
                registry.loras[cid]?.datasetId = nil
            }
        }
    }

    // MARK: - LoRAs

    /// Move a completed training run into place under its content id.
    ///
    /// The weights are made durable *before* the registry learns about them, so a
    /// crash can leave an unreferenced directory (which the startup sweep removes)
    /// but never an entry pointing at weights that are not there.
    @discardableResult
    public func publishLoRA(
        cid: String,
        from staging: URL,
        makeEntry: @Sendable (_ previous: LoRAEntry?) -> LoRAEntry
    ) async throws -> LoRAEntry {
        let destination = adapterDirectory(cid: cid)
        let manager = FileManager.default
        try manager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        if manager.fileExists(atPath: destination.path) {
            // Replacing an existing generation: swap atomically, then drop the old.
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: destination)
        }

        let previous = snapshot.loras[cid]
        var entry = makeEntry(previous)
        if let previous {
            // Identity is the input set, so a retrain keeps the LoRA's place in the
            // library: same label, same groups, same birthday, next generation.
            entry.label = entry.label ?? previous.label
            entry.createdAt = previous.createdAt
            entry.generation = previous.generation + 1
        }
        entry.updatedAt = .now
        let published = entry
        await registry.mutateAndFlush { $0.loras[cid] = published }
        return published
    }

    public func lora(cid: String) -> LoRAEntry? {
        snapshot.loras[cid]
    }

    public func loras(after cursor: String? = nil, limit: Int = 25) -> Page<LoRAEntry> {
        paginate(snapshot.sortedLoRACIDs, after: cursor, limit: limit) { snapshot.loras[$0] }
    }

    public func allLoRAs() -> [LoRAEntry] {
        snapshot.loras.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// LoRAs whose output schema matches — the interchangeable set for a caller
    /// that has a schema in hand.
    public func loras(schemaHash: String) -> [LoRAEntry] {
        allLoRAs().filter { $0.schemaHash == schemaHash }
    }

    public func setLabel(cid: String, label: String?) async {
        await registry.mutate { registry in
            registry.loras[cid]?.label = label
            registry.loras[cid]?.updatedAt = .now
        }
    }

    public func deleteLoRA(cid: String) async {
        try? FileManager.default.removeItem(at: adapterDirectory(cid: cid))
        await registry.mutateAndFlush { registry in
            registry.loras.removeValue(forKey: cid)
            for groupId in registry.loraGroups[cid] ?? [] {
                registry.groupMembers[groupId]?.removeAll { $0 == cid }
            }
            registry.loraGroups.removeValue(forKey: cid)
        }
    }

    /// Read the schema a LoRA was trained against, straight from its directory.
    public nonisolated func schema(cid: String) -> SchemaTemplate? {
        let url = adapterDirectory(cid: cid).appendingPathComponent(LoRAArtifact.schema)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SchemaTemplate.self, from: data)
    }

    public nonisolated func hasWeights(cid: String) -> Bool {
        FileManager.default.fileExists(
            atPath: adapterDirectory(cid: cid)
                .appendingPathComponent(LoRAArtifact.weights).path)
    }

    // MARK: - Groups

    @discardableResult
    public func createGroup(label: String, metadata: [String: String] = [:]) async -> GroupEntry {
        let group = GroupEntry(label: label, metadata: metadata)
        await registry.mutate { registry in
            registry.groups[group.id] = group
            registry.groupMembers[group.id] = []
        }
        return group
    }

    public func groups() -> [GroupEntry] {
        snapshot.sortedGroups
    }

    public func renameGroup(id: String, label: String) async {
        await registry.mutate { $0.groups[id]?.label = label }
    }

    public func updateGroupMetadata(id: String, metadata: [String: String]) async {
        await registry.mutate { $0.groups[id]?.metadata = metadata }
    }

    public func deleteGroup(id: String) async {
        await registry.mutateAndFlush { registry in
            registry.groups.removeValue(forKey: id)
            for cid in registry.groupMembers[id] ?? [] {
                registry.loraGroups[cid]?.removeAll { $0 == id }
            }
            registry.groupMembers.removeValue(forKey: id)
        }
    }

    public func add(cid: String, toGroup groupId: String) async {
        await registry.mutate { registry in
            guard registry.loras[cid] != nil, registry.groups[groupId] != nil else { return }
            var members = registry.groupMembers[groupId] ?? []
            if !members.contains(cid) {
                members.append(cid)
                members.sort()
                registry.groupMembers[groupId] = members
            }
            var ids = registry.loraGroups[cid] ?? []
            if !ids.contains(groupId) {
                ids.append(groupId)
                ids.sort()
                registry.loraGroups[cid] = ids
            }
        }
    }

    public func remove(cid: String, fromGroup groupId: String) async {
        await registry.mutate { registry in
            registry.groupMembers[groupId]?.removeAll { $0 == cid }
            registry.loraGroups[cid]?.removeAll { $0 == groupId }
        }
    }

    public func groups(forLoRA cid: String) -> [GroupEntry] {
        (snapshot.loraGroups[cid] ?? []).compactMap { snapshot.groups[$0] }
    }

    public func loras(inGroup groupId: String, after cursor: String? = nil, limit: Int = 25)
        -> Page<LoRAEntry>
    {
        let members = snapshot.groupMembers[groupId] ?? []
        return paginate(members, after: cursor, limit: limit) { snapshot.loras[$0] }
    }

    // MARK: - Startup reconciliation

    /// Bring the index and the filesystem back into agreement.
    ///
    /// There is no write-ahead log, so a crash can leave three kinds of debris:
    /// an entry whose weights are missing, a directory nothing references, and an
    /// abandoned staging directory. This also clears the pre-rewrite layout, which
    /// is unreadable now and not worth migrating.
    @discardableResult
    public func reconcile() async -> ReconciliationReport {
        var report = ReconciliationReport()
        let manager = FileManager.default
        let lorasRoot = Self.root.appendingPathComponent("loras")

        purgeLegacyLayout(&report)

        let current = snapshot
        var danglingEntries: [String] = []
        for (cid, _) in current.loras where !hasWeights(cid: cid) {
            danglingEntries.append(cid)
        }

        var orphanDirectories: [URL] = []
        if let contents = try? manager.contentsOfDirectory(
            at: lorasRoot, includingPropertiesForKeys: nil)
        {
            for url in contents {
                let name = url.lastPathComponent
                if name.hasPrefix(".staging-") {
                    orphanDirectories.append(url)
                } else if current.loras[name] == nil {
                    orphanDirectories.append(url)
                }
            }
        }

        for url in orphanDirectories {
            try? manager.removeItem(at: url)
        }
        report.removedDirectories = orphanDirectories.count

        let dangling = danglingEntries
        if !dangling.isEmpty {
            await registry.mutateAndFlush { registry in
                for cid in dangling {
                    registry.loras.removeValue(forKey: cid)
                    for groupId in registry.loraGroups[cid] ?? [] {
                        registry.groupMembers[groupId]?.removeAll { $0 == cid }
                    }
                    registry.loraGroups.removeValue(forKey: cid)
                }
            }
        }
        report.removedEntries = danglingEntries.count

        // Datasets are listed from the registry, so drop entries whose file is gone.
        let missingDatasets = current.datasets.keys.filter { loadDataset(id: $0) == nil }
        if !missingDatasets.isEmpty {
            await registry.mutateAndFlush { registry in
                for id in missingDatasets { registry.datasets.removeValue(forKey: id) }
            }
        }
        report.removedDatasets = missingDatasets.count

        return report
    }

    public struct ReconciliationReport: Sendable, Equatable {
        public var removedEntries = 0
        public var removedDirectories = 0
        public var removedDatasets = 0
        public var removedLegacyPaths = 0

        public var isClean: Bool {
            removedEntries == 0 && removedDirectories == 0 && removedDatasets == 0
                && removedLegacyPaths == 0
        }
    }

    /// Delete the UUID-keyed layout this rewrite replaced. Fleet is pre-release,
    /// so the old data is dropped rather than migrated.
    private func purgeLegacyLayout(_ report: inout ReconciliationReport) {
        let manager = FileManager.default
        let legacy = [
            "datasets-index", "adapters-index", "adapters", "graphs", "graph-store",
        ]
        for name in legacy {
            let url = Self.root.appendingPathComponent(name)
            if manager.fileExists(atPath: url.path) {
                try? manager.removeItem(at: url)
                report.removedLegacyPaths += 1
            }
        }
        // Old adapter directories were named by UUID; a CID is 64 hex characters.
        let lorasRoot = Self.root.appendingPathComponent("loras")
        if let contents = try? manager.contentsOfDirectory(
            at: lorasRoot, includingPropertiesForKeys: nil)
        {
            for url in contents {
                let name = url.lastPathComponent
                if UUID(uuidString: name) != nil {
                    try? manager.removeItem(at: url)
                    report.removedLegacyPaths += 1
                }
            }
        }
    }

    // MARK: - Helpers

    private nonisolated func datasetFile(_ id: UUID) -> FilePersistence {
        FilePersistence(key: "datasets/\(id.uuidString)")
    }

    /// Cursor pagination over a pre-sorted id list: find the cursor, take a page,
    /// and hydrate only what the page needs.
    private func paginate<Element: Sendable>(
        _ ids: [String],
        after cursor: String?,
        limit: Int,
        hydrate: (String) -> Element?
    ) -> Page<Element> {
        guard limit > 0 else { return Page(items: [], hasMore: !ids.isEmpty, nextCursor: cursor) }
        var start = 0
        if let cursor, let index = ids.firstIndex(of: cursor) {
            start = index + 1
        }
        guard start < ids.count else { return Page(items: [], hasMore: false, nextCursor: nil) }
        let end = min(start + limit, ids.count)
        let slice = Array(ids[start ..< end])
        let items = slice.compactMap(hydrate)
        let hasMore = end < ids.count
        return Page(items: items, hasMore: hasMore, nextCursor: hasMore ? slice.last : nil)
    }
}
