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
/// Named discipline slots live at `loras/<totemId>/<abilityId>/` and overwrite
/// in place; the CID is kept on the entry as provenance.
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

    /// Named slot: `loras/<totemId>/<abilityId>/`.
    public nonisolated func namedAdapterDirectory(totemId: String, abilityId: String) -> URL {
        Self.root
            .appendingPathComponent("loras")
            .appendingPathComponent(totemId)
            .appendingPathComponent(abilityId)
    }

    public nonisolated static func namedSlotKey(totemId: String, abilityId: String) -> String {
        "\(totemId)|\(abilityId)"
    }

    public nonisolated func adapterDirectory(for entry: LoRAEntry) -> URL {
        if let totemId = entry.totemId, let abilityId = entry.abilityId,
           !totemId.isEmpty, !abilityId.isEmpty
        {
            return namedAdapterDirectory(totemId: totemId, abilityId: abilityId)
        }
        return adapterDirectory(cid: entry.cid)
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

    /// Publish under a named totem/ability slot. Weights replace in place and
    /// generation bumps; the CID stays on the entry as provenance.
    @discardableResult
    public func publishNamedLoRA(
        totemId: String,
        abilityId: String,
        cid: String,
        from staging: URL,
        makeEntry: @Sendable (_ previous: LoRAEntry?) -> LoRAEntry
    ) async throws -> LoRAEntry {
        let destination = namedAdapterDirectory(totemId: totemId, abilityId: abilityId)
        let manager = FileManager.default
        try manager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        if manager.fileExists(atPath: destination.path) {
            // KEEP THE GENERATION BEING REPLACED. Publishing used to overwrite
            // in place, so a retrain that came out worse than the one before
            // it could not be undone — the only copy of the good weights was
            // the one just deleted.
            let previous = previousAdapterDirectory(totemId: totemId, abilityId: abilityId)
            try? manager.removeItem(at: previous)
            try? manager.copyItem(at: destination, to: previous)
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: destination)
        }

        let key = Self.namedSlotKey(totemId: totemId, abilityId: abilityId)
        let previousCID = snapshot.namedSlots[key]
        let previous = previousCID.flatMap { snapshot.loras[$0] }
        var entry = makeEntry(previous)
        entry.totemId = totemId
        entry.abilityId = abilityId
        if let previous {
            entry.label = entry.label ?? previous.label
            entry.createdAt = previous.createdAt
            entry.generation = previous.generation + 1
        }
        entry.updatedAt = .now
        let published = entry
        await registry.mutateAndFlush { registry in
            if let previousCID, previousCID != cid {
                registry.loras.removeValue(forKey: previousCID)
            }
            registry.loras[cid] = published
            registry.namedSlots[key] = cid
        }
        return published
    }

    /// Where the generation this slot replaced is kept, so a bad adapter can
    /// be undone. One deep: the point is recovery, not history.
    public nonisolated func previousAdapterDirectory(
        totemId: String, abilityId: String
    ) -> URL {
        namedAdapterDirectory(totemId: totemId, abilityId: abilityId)
            .deletingLastPathComponent()
            .appendingPathComponent("\(abilityId)\(Self.previousSuffix)")
    }

    static let previousSuffix = ".previous"

    /// Record what the published adapter scored on pairs held out of its own
    /// training. The number gates `ready`; see `LoRAEntry.passesReadyGate`.
    public func setEvaluation(cid: String, exactMatch: Double?, cases: Int) async {
        await registry.mutateAndFlush { registry in
            registry.loras[cid]?.evalExactMatch = exactMatch
            registry.loras[cid]?.evalCases = cases
            registry.loras[cid]?.updatedAt = .now
        }
    }

    /// Put the previous generation back. Returns nil when there is none —
    /// the first generation of a slot has nothing behind it.
    @discardableResult
    public func rollbackNamedLoRA(totemId: String, abilityId: String) async throws -> LoRAEntry? {
        let manager = FileManager.default
        let previous = previousAdapterDirectory(totemId: totemId, abilityId: abilityId)
        guard manager.fileExists(
            atPath: previous.appendingPathComponent(LoRAArtifact.weights).path)
        else { return nil }
        let key = Self.namedSlotKey(totemId: totemId, abilityId: abilityId)
        guard let currentCID = snapshot.namedSlots[key],
              let current = snapshot.loras[currentCID]
        else { return nil }

        let live = namedAdapterDirectory(totemId: totemId, abilityId: abilityId)
        let scratch = try makeStagingDirectory()
        try? manager.removeItem(at: scratch)
        // Three-way swap so a failure never leaves the slot without weights.
        try manager.moveItem(at: live, to: scratch)
        try manager.moveItem(at: previous, to: live)
        try? manager.removeItem(at: scratch)

        // The restored weights are the older generation. Its snapshot is on
        // disk beside them; the registry entry is rebuilt from the current
        // one so the slot keeps its label and its place in the library.
        var restored = current
        restored.generation = max(1, current.generation - 1)
        restored.evalExactMatch = nil
        restored.evalCases = 0
        restored.updatedAt = .now
        let published = restored
        await registry.mutateAndFlush { registry in
            registry.loras[currentCID] = published
            registry.namedSlots[key] = currentCID
        }
        return published
    }

    public func lora(totemId: String, abilityId: String) -> LoRAEntry? {
        let key = Self.namedSlotKey(totemId: totemId, abilityId: abilityId)
        guard let cid = snapshot.namedSlots[key] else { return nil }
        return snapshot.loras[cid]
    }

    public func loras(totemId: String) -> [LoRAEntry] {
        snapshot.loras.values.filter { $0.totemId == totemId }
            .sorted { $0.abilityId ?? "" < $1.abilityId ?? "" }
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
        let entry = snapshot.loras[cid]
        try? FileManager.default.removeItem(at: adapterDirectory(cid: cid))
        if let entry {
            try? FileManager.default.removeItem(at: adapterDirectory(for: entry))
            if let totemId = entry.totemId, let abilityId = entry.abilityId {
                try? FileManager.default.removeItem(
                    at: previousAdapterDirectory(totemId: totemId, abilityId: abilityId))
            }
        }
        await registry.mutateAndFlush { registry in
            registry.loras.removeValue(forKey: cid)
            for groupId in registry.loraGroups[cid] ?? [] {
                registry.groupMembers[groupId]?.removeAll { $0 == cid }
            }
            registry.loraGroups.removeValue(forKey: cid)
            registry.namedSlots = registry.namedSlots.filter { $0.value != cid }
        }
    }

    /// Read the schema a LoRA was trained against, straight from its directory.
    public nonisolated func schema(cid: String) -> SchemaTemplate? {
        let directory: URL
        if let entry = snapshot.loras[cid] {
            directory = adapterDirectory(for: entry)
        } else {
            directory = adapterDirectory(cid: cid)
        }
        let url = directory.appendingPathComponent(LoRAArtifact.schema)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SchemaTemplate.self, from: data)
    }

    public nonisolated func schemaJSON(cid: String) -> Data? {
        let directory: URL
        if let entry = snapshot.loras[cid] {
            directory = adapterDirectory(for: entry)
        } else {
            directory = adapterDirectory(cid: cid)
        }
        return try? Data(contentsOf: directory.appendingPathComponent(LoRAArtifact.schema))
    }

    public nonisolated func hasWeights(cid: String) -> Bool {
        let directory: URL
        if let entry = snapshot.loras[cid] {
            directory = adapterDirectory(for: entry)
        } else {
            directory = adapterDirectory(cid: cid)
        }
        return FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(LoRAArtifact.weights).path)
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
                } else if Self.containsNamedSlot(url)
                    || current.namedSlots.keys.contains(where: { $0.hasPrefix("\(name)|") })
                {
                    continue
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
                    if Self.containsNamedSlot(url) { continue }
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

    /// A named slot tree is `loras/<totemId>/<abilityId>/adapters.safetensors`.
    /// Totem ids are UUIDs, so reconcile must not treat those folders as the
    /// pre-rewrite UUID layout.
    nonisolated static func containsNamedSlot(_ url: URL) -> Bool {
        // A kept previous generation counts: it lives beside the live slot
        // under the same totem directory and holds real weights.
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey])
        else { return false }
        return children.contains { child in
            FileManager.default.fileExists(
                atPath: child.appendingPathComponent(LoRAArtifact.weights).path)
        }
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
