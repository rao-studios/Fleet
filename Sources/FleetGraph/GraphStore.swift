import FleetStore
import Foundation

/// Persists the working ensemble graph under `fleet-db/graphs/`.
///
/// Uses JSON (reliable for the polymorphic node encoding) rooted at the same
/// `fleet-db` directory as datasets and adapters. v1 stores a single default
/// graph; multi-graph is a future extension.
public struct GraphStore {

    public init() {}

    private var url: URL {
        FilePersistence.getDefaultURL()
            .appendingPathComponent("graphs")
            .appendingPathComponent("default.json")
    }

    public func save(_ graph: EnsembleGraph) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(graph).write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("[fleet-db] graph save failed: \(error)\n".utf8))
        }
    }

    public func load() -> EnsembleGraph? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EnsembleGraph.self, from: data)
    }
}
