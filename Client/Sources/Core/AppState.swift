import Fleet
import FleetConduit
import Foundation
import SwiftUI

#if canImport(Darwin)
import Darwin
#endif

/// The screens in the workflow sidebar, in the order the work happens.
enum Screen: String, CaseIterable, Identifiable {
    case models = "Models"
    case datasets = "Datasets"
    case train = "Train"
    case library = "Library"
    case playground = "Playground"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .models: return "arrow.down.circle"
        case .datasets: return "tray.full"
        case .train: return "wand.and.stars"
        case .library: return "square.stack.3d.up"
        case .playground: return "bolt.horizontal"
        }
    }
}

/// App-wide state container (single source of truth, injected via environment).
///
/// All pipeline work goes through ``FleetService`` — this holds only what the
/// views need to render, plus the Totem server the app hosts.
@MainActor
final class AppState: ObservableObject {

    let service = FleetService()

    // Totem import (Conduit gRPC) — Fleet hosts the server; Totems dial in.
    let totemServer = FleetTotemServer()
    @Published var totemServerRunning = false
    @Published var totemServerPort = 9092
    @Published var totemServerError: String?
    @Published var connectedTotems: [ConnectedTotem] = []
    private var totemStreamTask: Task<Void, Never>?

    // Navigation
    @Published var screen: Screen = .datasets

    // Library
    @Published var datasets: [DatasetEntry] = []
    @Published var loras: [LoRAEntry] = []
    @Published var groups: [GroupEntry] = []
    @Published var groupMembership: [String: [String]] = [:]  // cid → group labels

    // Models
    private static let defaultModel = TrainingConfig.defaultModelId
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

    @Published var warmingModelId: String?
    @Published var warmProgress: Double = 0
    @Published var warmStatus: String = ""
    @Published var modelError: String?

    // Training
    @Published var isTraining = false
    @Published var trainingLog: [String] = []
    @Published var trainingError: String?
    @Published var lossHistory: [(iteration: Int, loss: Float)] = []
    @Published var lastTrainedCID: String?
    private var trainingTask: Task<Void, Never>?

    var knownModels: [String] {
        knownModelsRaw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    init() {
        self.knownModelsRaw = defaults.string(forKey: Keys.knownModels) ?? AppState.defaultModel
        self.activeModelId = defaults.string(forKey: Keys.activeModel) ?? AppState.defaultModel
    }

    // MARK: - Lifecycle

    /// Sweep up after any interrupted run, then load the library.
    func start() async {
        _ = await service.start()
        await refresh()
    }

    func refresh() async {
        datasets = await service.allDatasets()
        loras = await service.allLoRAs()
        groups = await service.groups()
        var membership: [String: [String]] = [:]
        for entry in loras {
            let labels = await service.groups(forLoRA: entry.cid).map(\.label)
            if !labels.isEmpty { membership[entry.cid] = labels }
        }
        groupMembership = membership
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

    func generateMockDataset(domain: MockDomain, count: Int, seed: UInt64) async throws
        -> DatasetEntry
    {
        let entry = try await service.generateMockDataset(
            domain: domain, count: count, seed: seed)
        await refresh()
        return entry
    }

    func importDataset(name: String, inputs: [URL], outputs: [URL]) async throws -> DatasetEntry {
        let entry = try await service.importDataset(
            name: name, inputFiles: inputs, outputFiles: outputs)
        await refresh()
        return entry
    }

    func dataset(id: UUID) async -> StateDataset? {
        await service.dataset(id: id)
    }

    func validationReport(datasetId: UUID) async -> ValidationReport? {
        try? await service.validationReport(datasetId: datasetId)
    }

    func deleteDataset(_ id: UUID) async {
        await service.deleteDataset(id: id)
        await refresh()
    }

    // MARK: - Training

    func train(datasetId: UUID, config: TrainingConfig) {
        guard !isTraining else { return }
        isTraining = true
        trainingError = nil
        trainingLog = []
        lossHistory = []
        lastTrainedCID = nil

        trainingTask = Task {
            do {
                let stream = try await service.train(datasetId: datasetId, config: config)
                for try await progress in stream {
                    switch progress {
                    case .preparing(let pairs, let tokens):
                        log("Preparing \(pairs) pairs · longest example \(tokens) tokens")
                        if tokens > 2048 {
                            log(
                                "⚠︎ Examples longer than 2048 tokens may be truncated during "
                                    + "training.")
                        }
                    case .loadingModel(let fraction, let status):
                        log("Loading model \(Int(fraction * 100))% — \(status)")
                    case .step(let iteration, let loss, let itersPerSecond, let tokensPerSecond):
                        lossHistory.append((iteration, loss))
                        log(
                            "iter \(iteration) · loss \(String(format: "%.4f", loss)) · "
                                + "\(String(format: "%.1f", itersPerSecond)) it/s · "
                                + "\(Int(tokensPerSecond)) tok/s")
                    case .validation(let iteration, let loss, _):
                        log("iter \(iteration) · validation loss \(String(format: "%.4f", loss))")
                    case .checkpointed(let iteration):
                        log("checkpoint at \(iteration)")
                    case .finished(let cid, _):
                        lastTrainedCID = cid
                        log("✓ Stored LoRA \(ContentID.short(cid))")
                    }
                }
            } catch is CancellationError {
                log("Cancelled.")
            } catch {
                trainingError = "\(error)"
                log("✗ \(error)")
            }
            isTraining = false
            await refresh()
        }
    }

    func cancelTraining() {
        trainingTask?.cancel()
        trainingTask = nil
    }

    private func log(_ line: String) {
        trainingLog.append(line)
    }

    // MARK: - Library

    func setLabel(cid: String, label: String?) async {
        await service.setLabel(cid: cid, label: label)
        await refresh()
    }

    func deleteLoRA(cid: String) async {
        await service.deleteLoRA(cid: cid)
        await refresh()
    }

    func createGroup(label: String) async {
        _ = await service.createGroup(label: label)
        await refresh()
    }

    func deleteGroup(id: String) async {
        await service.deleteGroup(id: id)
        await refresh()
    }

    func add(cid: String, toGroup groupId: String) async {
        await service.add(cid: cid, toGroup: groupId)
        await refresh()
    }

    func remove(cid: String, fromGroup groupId: String) async {
        await service.remove(cid: cid, fromGroup: groupId)
        await refresh()
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
}
