import Fleet
import Foundation
import SwiftUI

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
    }

    @Published var activeModelId: String {
        didSet { defaults.set(activeModelId, forKey: Keys.activeModel) }
    }
    @Published private var knownModelsRaw: String {
        didSet { defaults.set(knownModelsRaw, forKey: Keys.knownModels) }
    }

    init() {
        self.knownModelsRaw = defaults.string(forKey: Keys.knownModels) ?? AppState.defaultModel
        self.activeModelId = defaults.string(forKey: Keys.activeModel) ?? AppState.defaultModel
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
        trainingLog = ["Building corpus from \(dataset.entries.count) entries…"]
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
