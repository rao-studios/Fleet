import Fleet
import Foundation
import SwiftUI

/// Live per-node state during a run (shown on the node cards).
struct NodeRunState {
    enum Status { case idle, running, done, error }
    var input: String = ""
    var output: String = ""
    var status: Status = .idle
}

/// One prompt → final ensemble output, for the conversational transcript.
struct GraphExchange: Identifiable {
    let id = UUID()
    let prompt: String
    var output: String = ""
    var done = false
}

/// Drives the node-graph chat mode. Responsibilities are split across files:
/// - this file — state, init, graph (de)serialization;
/// - `+Editing` — add/remove nodes, wire/unwire edges, move;
/// - `+Geometry` — port positions and hit-testing;
/// - `+Bindings` — SwiftUI bindings for LoRA and Router node config;
/// - `+Run` — execute the graph and stream events into the UI.
@MainActor
final class GraphChatViewModel: ObservableObject {

    // Graph
    @Published var nodes: [GraphNode] = []
    @Published var edges: [GraphEdge] = []
    @Published var positions: [UUID: CGPoint] = [:]

    // Run state
    @Published var runStates: [UUID: NodeRunState] = [:]
    @Published var gateWeights: [UUID: Double] = [:]  // member nodeId → router gate weight
    @Published var transcript: [GraphExchange] = []
    @Published var input: String = ""
    @Published var isBusy = false

    let modelId: String
    let db: FleetDB
    /// Pool of independent model lanes — concurrent members generate truly in
    /// parallel, capped at the lane count. Each lane lazily loads its own model.
    let executor: any StageExecuting
    let gate = EmbeddingGate()  // loads its model only when a Router uses gateKind == .embedding
    let cardSize = CGSize(width: 230, height: 150)
    private let store = GraphStore()

    init(modelId: String, db: FleetDB, lanes: Int) {
        self.modelId = modelId
        self.db = db
        self.executor = ParallelStageExecutor(
            lanes: (0 ..< max(1, lanes)).map { _ in LoRAStageRunner(modelId: modelId) })

        if let saved = store.load() {
            load(saved)
        } else {
            loadDefault()
        }
    }

    func node(_ id: UUID) -> GraphNode? { nodes.first { $0.id == id } }

    // MARK: - Graph (de)serialization

    private func loadDefault() {
        let input = InputNode(position: .init(x: 150, y: 220))
        let lora = LoRANode(position: .init(x: 440, y: 220), operationKind: .answer)
        let output = OutputNode(position: .init(x: 730, y: 220))
        nodes = [input, lora, output]
        edges = [.init(from: input.id, to: lora.id), .init(from: lora.id, to: output.id)]
        syncPositionsFromNodes()
    }

    private func load(_ graph: EnsembleGraph) {
        nodes = graph.nodes
        edges = graph.edges
        syncPositionsFromNodes()
    }

    private func syncPositionsFromNodes() {
        for node in nodes {
            positions[node.id] = CGPoint(x: node.position.x, y: node.position.y)
        }
    }

    /// Snapshot the live nodes/edges (with current positions) as an `EnsembleGraph`.
    func currentGraph() -> EnsembleGraph {
        for node in nodes {
            if let p = positions[node.id] {
                node.position = GraphPoint(x: Double(p.x), y: Double(p.y))
            }
        }
        return EnsembleGraph(name: "default", nodes: nodes, edges: edges)
    }

    func persist() {
        store.save(currentGraph())
    }
}
