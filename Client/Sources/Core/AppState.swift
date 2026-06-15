import Fleet
import FleetConduit
import Foundation
import SwiftUI
#if canImport(Darwin)
import Darwin
#endif

/// The screens in the workflow sidebar.
enum Screen: String, CaseIterable, Identifiable {
    case models = "Models"
    case datasets = "Datasets"
    case fineTune = "Fine-tune"
    case chat = "Chat"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .models: return "arrow.down.circle"
        case .datasets: return "tray.full"
        case .fineTune: return "wand.and.stars"
        case .chat: return "bubble.left.and.bubble.right"
        }
    }
}

/// App-wide state container (single source of truth, injected via environment).
@MainActor
final class AppState: ObservableObject {

    let db = FleetDB()

    // Totem import (Conduit gRPC) — Fleet hosts the server; Totems dial in.
    let totemServer = FleetTotemServer()
    @Published var totemServerRunning = false
    @Published var totemServerPort = 9092
    @Published var totemServerError: String?
    @Published var connectedTotems: [ConnectedTotem] = []
    private var totemStreamTask: Task<Void, Never>?

    // Navigation
    @Published var screen: Screen = .models

    // Data
    @Published var datasets: [TrainingDataset] = []
    @Published var adapters: [TrainedAdapter] = []

    // Models — @Published + UserDefaults (so selection changes refresh the UI).
    private static let defaultModel = "mlx-community/Qwen3-0.6B-4bit"
    private let defaults = UserDefaults.standard
    private enum Keys {
        static let activeModel = "fleet.activeModel"
        static let knownModels = "fleet.knownModels"
        static let parallelLanes = "fleet.parallelLanes"
    }

    @Published var activeModelId: String {
        didSet { defaults.set(activeModelId, forKey: Keys.activeModel) }
    }
    @Published private var knownModelsRaw: String {
        didSet { defaults.set(knownModelsRaw, forKey: Keys.knownModels) }
    }

    /// True-parallel ensemble lanes — each lane is a full base-model copy.
    @Published var parallelLanes: Int {
        didSet { defaults.set(parallelLanes, forKey: Keys.parallelLanes) }
    }

    init() {
        self.knownModelsRaw = defaults.string(forKey: Keys.knownModels) ?? AppState.defaultModel
        self.activeModelId = defaults.string(forKey: Keys.activeModel) ?? AppState.defaultModel
        let savedLanes = defaults.integer(forKey: Keys.parallelLanes)  // 0 when unset
        self.parallelLanes = savedLanes == 0 ? 2 : savedLanes
    }

    @Published var warmingModelId: String?
    @Published var warmProgress: Double = 0
    @Published var warmStatus: String = ""
    @Published var modelError: String?

    // Training
    @Published var isTraining = false
    @Published var trainingLog: [String] = []
    @Published var trainingError: String?
    @Published var lastTrainedAdapterId: UUID?

    var knownModels: [String] {
        knownModelsRaw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Lifecycle

    func refresh() async {
        datasets = await db.allDatasets()
        adapters = await db.allAdapters()
    }

    // MARK: - Models

    func addModel(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !knownModels.contains(trimmed) else { return }
        knownModelsRaw = (knownModels + [trimmed]).joined(separator: ",")
    }

    func removeModel(_ id: String) {
        knownModelsRaw = knownModels.filter { $0 != id }.joined(separator: ",")
    }

    /// Download + warm a model so it's cached locally and ready to use.
    func warmModel(_ id: String) async {
        warmingModelId = id
        warmProgress = 0
        warmStatus = "Preparing…"
        modelError = nil
        do {
            try await ModelLoader.warm(id: id) { fraction, status in
                Task { @MainActor in
                    self.warmProgress = fraction
                    self.warmStatus = status
                }
            }
            warmStatus = "Ready"
            warmProgress = 1
        } catch {
            modelError = "\(error)"
            warmStatus = "Failed"
        }
        warmingModelId = nil
    }

    // MARK: - Totem import server

    func startTotemServer() async {
        guard !totemServerRunning else { return }  // auto-start + manual Start must not double-bind
        totemServerError = nil

        // The gRPC serve loop binds inside a detached task, so a port clash would
        // otherwise leave us falsely "listening". Probe the port first and surface it.
        guard AppState.portIsAvailable(totemServerPort) else {
            totemServerError = "Port \(totemServerPort) is in use — change it and Restart."
            return
        }

        await totemServer.start(port: totemServerPort)
        totemServerRunning = await totemServer.isRunning
        totemStreamTask?.cancel()
        let stream = await totemServer.totemsStream()
        totemStreamTask = Task { [weak self] in
            for await totems in stream {
                await MainActor.run { self?.connectedTotems = totems }
            }
        }
    }

    func stopTotemServer() async {
        totemStreamTask?.cancel()
        totemStreamTask = nil
        await totemServer.stop()
        totemServerRunning = false
        connectedTotems = []
    }

    /// Stop then start — used when the listening port is changed.
    func restartTotemServer() async {
        await stopTotemServer()
        await startTotemServer()
    }

    /// Best-effort check that `port` can be bound on 0.0.0.0 (matches the server's
    /// wildcard bind). Catches the common "already in use" case before we claim to
    /// be listening; a TOCTOU race is acceptable for a single-user desktop app.
    private static func portIsAvailable(_ port: Int) -> Bool {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }  // can't probe — assume available
        defer { close(fd) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(truncatingIfNeeded: port)).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
        #else
        return true
        #endif
    }

    func totemImporter() async -> TotemImporter {
        await totemServer.importer()
    }

    // MARK: - Datasets

    func createDataset(name: String) async -> TrainingDataset {
        let dataset = TrainingDataset(name: name.isEmpty ? "Untitled" : name)
        await db.saveDataset(dataset)
        await refresh()
        return dataset
    }

    func saveDataset(_ dataset: TrainingDataset) async {
        await db.saveDataset(dataset)
        await refresh()
    }

    func deleteDataset(_ id: UUID) async {
        await db.deleteDataset(id: id)
        await refresh()
    }

    /// Decode files (or folders) into text fragments via the standard registry.
    func decodeFiles(_ urls: [URL]) async -> [ContextFragment] {
        let registry = DecoderRegistry.standard()
        var fragments: [ContextFragment] = []
        for url in urls {
            fragments.append(contentsOf: (try? await registry.decode(url)) ?? [])
        }
        return fragments
    }

    // MARK: - Fine-tuning

    func fineTune(dataset: TrainingDataset, modelId: String, rank: Int, iterations: Int) async {
        isTraining = true
        trainingError = nil
        trainingLog = ["Building corpus from \(dataset.trainingExamples.count) examples (\(dataset.entries.count) entries + \(dataset.fileFragments.count) file chunks)…"]
        lastTrainedAdapterId = nil

        let adapter = TrainedAdapter(
            datasetId: dataset.id,
            name: "\(dataset.name) · r\(rank)/\(iterations)",
            modelId: modelId,
            rank: rank,
            scale: 20,
            numLayers: 16,
            iterations: iterations
        )
        let outputDir = db.adapterDirectory(for: adapter.id)

        var config = FineTuningConfig(outputAdapterDir: outputDir)
        config.modelId = modelId
        config.rank = rank
        config.iterations = iterations

        do {
            let trainer = FleetTrainer(config: config)
            for try await event in trainer.run(corpus: dataset.corpus) {
                switch event {
                case .progress(let progress):
                    trainingLog.append(progress.description)
                case .finished(let dir):
                    trainingLog.append("Adapter written to \(dir.lastPathComponent)")
                }
            }
            await db.saveAdapter(adapter)
            lastTrainedAdapterId = adapter.id
            trainingLog.append("✓ Saved adapter \(adapter.id.uuidString.prefix(8)) (dataset \(dataset.id.uuidString.prefix(8)))")
            await refresh()
        } catch {
            trainingError = "\(error)"
            trainingLog.append("✗ \(error)")
        }
        isTraining = false
    }
}
