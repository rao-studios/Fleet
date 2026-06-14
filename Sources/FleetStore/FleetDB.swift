import Foundation

/// `fleet-db` — the on-disk store for datasets and trained LoRA adapters.
///
/// An `actor`, so all reads/writes are serialized (the ``FilePersistence`` files
/// it owns are not individually thread-safe). On-disk layout under
/// `~/Documents/fleet-db`:
/// ```
/// fleet-db/
///   datasets-index            [UUID]
///   datasets/<uuid>           TrainingDataset
///   adapters-index            [UUID]
///   adapters/<uuid>           TrainedAdapter
///   loras/<adapterUUID>/      adapter_config.json + adapters.safetensors
/// ```
public actor FleetDB {

    public init() {}

    /// The directory a ``TrainedAdapter``'s weights are written to / loaded from.
    public nonisolated func adapterDirectory(for adapterId: UUID) -> URL {
        FilePersistence.getDefaultURL()
            .appendingPathComponent("loras")
            .appendingPathComponent(adapterId.uuidString)
    }

    // MARK: - Datasets

    public func saveDataset(_ dataset: TrainingDataset) {
        var dataset = dataset
        dataset.updatedAt = .now
        file("datasets/\(dataset.id.uuidString)").save(state: dataset)
        addToIndex("datasets-index", dataset.id)
    }

    public func loadDataset(id: UUID) -> TrainingDataset? {
        file("datasets/\(id.uuidString)").restore()
    }

    public func allDatasets() -> [TrainingDataset] {
        index("datasets-index")
            .compactMap { loadDataset(id: $0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func deleteDataset(id: UUID) {
        file("datasets/\(id.uuidString)").purge()
        removeFromIndex("datasets-index", id)
    }

    // MARK: - Adapters

    public func saveAdapter(_ adapter: TrainedAdapter) {
        file("adapters/\(adapter.id.uuidString)").save(state: adapter)
        addToIndex("adapters-index", adapter.id)
    }

    public func loadAdapter(id: UUID) -> TrainedAdapter? {
        file("adapters/\(id.uuidString)").restore()
    }

    public func allAdapters() -> [TrainedAdapter] {
        index("adapters-index")
            .compactMap { loadAdapter(id: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Adapters trained from a given dataset (the LoRA→dataset tie).
    public func adapters(forDataset datasetId: UUID) -> [TrainedAdapter] {
        allAdapters().filter { $0.datasetId == datasetId }
    }

    public func deleteAdapter(id: UUID) {
        file("adapters/\(id.uuidString)").purge()
        removeFromIndex("adapters-index", id)
        try? FileManager.default.removeItem(at: adapterDirectory(for: id))
    }

    // MARK: - Helpers

    private func file(_ key: String) -> FilePersistence {
        FilePersistence(key: key)
    }

    private func index(_ key: String) -> [UUID] {
        file(key).restore() ?? []
    }

    private func addToIndex(_ key: String, _ id: UUID) {
        var ids: [UUID] = file(key).restore() ?? []
        if !ids.contains(id) {
            ids.append(id)
            file(key).save(state: ids)
        }
    }

    private func removeFromIndex(_ key: String, _ id: UUID) {
        var ids: [UUID] = file(key).restore() ?? []
        ids.removeAll { $0 == id }
        file(key).save(state: ids)
    }
}
