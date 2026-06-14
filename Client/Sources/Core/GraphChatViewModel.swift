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

/// Drives the node-graph chat mode: owns the pipeline (nodes + wires + layout),
/// runs prompts through `GraphRunner` over a shared `LoRAStageRunner`, and streams
/// per-stage I/O onto the cards plus the final answer into the transcript.
@MainActor
final class GraphChatViewModel: ObservableObject {

    // Graph
    @Published private(set) var nodes: [GraphNode] = []
    @Published private(set) var edges: [GraphEdge] = []
    @Published var positions: [UUID: CGPoint] = [:]

    // Run state
    @Published var runStates: [UUID: NodeRunState] = [:]
    @Published var transcript: [GraphExchange] = []
    @Published var input: String = ""
    @Published var isBusy = false

    let modelId: String
    private let db: FleetDB
    private let store = GraphStore()
    private let stageRunner: LoRAStageRunner

    private let cardSize = CGSize(width: 230, height: 150)

    init(modelId: String, db: FleetDB) {
        self.modelId = modelId
        self.db = db
        self.stageRunner = LoRAStageRunner(modelId: modelId)

        if let saved = store.load() {
            load(saved)
        } else {
            loadDefault()
        }
    }

    // MARK: - Graph construction

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

    private func currentGraph() -> EnsembleGraph {
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

    // MARK: - Editing

    func addLoRANode() {
        let node = LoRANode(position: .init(x: 440, y: 420), operationKind: .augment)
        nodes.append(node)
        positions[node.id] = CGPoint(x: 440, y: 420)
        persist()
    }

    func removeNode(_ id: UUID) {
        guard let node = nodes.first(where: { $0.id == id }), node.kind == .lora else { return }
        nodes.removeAll { $0.id == id }
        edges.removeAll { $0.from == id || $0.to == id }
        positions[id] = nil
        runStates[id] = nil
        persist()
    }

    /// Connect output of `from` → input of `to`, keeping a single linear chain
    /// (one outgoing per source, one incoming per target).
    func connect(from: UUID, to: UUID) {
        guard from != to, nodes.contains(where: { $0.id == from }), nodes.contains(where: { $0.id == to })
        else { return }
        // Output nodes have no output; Input nodes have no input.
        if node(to)?.kind == .input { return }
        if node(from)?.kind == .output { return }
        edges.removeAll { $0.from == from || $0.to == to }
        edges.append(.init(from: from, to: to))
        persist()
    }

    func disconnect(_ edge: GraphEdge) {
        edges.removeAll { $0 == edge }
        persist()
    }

    func move(_ id: UUID, to point: CGPoint) {
        positions[id] = point
    }

    func endMove() { persist() }

    func node(_ id: UUID) -> GraphNode? { nodes.first { $0.id == id } }

    // MARK: - Port geometry (centers stored in `positions`)

    func outputPort(_ id: UUID) -> CGPoint {
        let c = positions[id] ?? .zero
        return CGPoint(x: c.x + cardSize.width / 2, y: c.y)
    }

    func inputPort(_ id: UUID) -> CGPoint {
        let c = positions[id] ?? .zero
        return CGPoint(x: c.x - cardSize.width / 2, y: c.y)
    }

    /// Nearest node whose input port is within `threshold` of `location`.
    func nodeNearInputPort(_ location: CGPoint, threshold: CGFloat = 44) -> UUID? {
        nodes
            .filter { $0.kind != .input }
            .map { ($0.id, hypot(inputPort($0.id).x - location.x, inputPort($0.id).y - location.y)) }
            .filter { $0.1 <= threshold }
            .min { $0.1 < $1.1 }?.0
    }

    // MARK: - LoRA node config bindings

    func operationBinding(_ node: LoRANode) -> Binding<OperationKind> {
        Binding(
            get: { node.operationKind },
            set: { node.operationKind = $0; self.objectWillChange.send(); self.persist() })
    }

    func adapterBinding(_ node: LoRANode) -> Binding<UUID?> {
        Binding(
            get: { node.adapterId },
            set: { node.adapterId = $0; self.objectWillChange.send(); self.persist() })
    }

    // MARK: - Run

    func send() async {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isBusy else { return }
        input = ""
        isBusy = true

        for node in nodes { runStates[node.id] = NodeRunState() }
        let exchangeIndex = transcript.count
        transcript.append(GraphExchange(prompt: prompt))

        let history = transcriptHistory(upTo: exchangeIndex)
        let resolve: @Sendable (UUID) -> URL? = { [db] id in db.adapterDirectory(for: id) }
        let runner = GraphRunner(graph: currentGraph(), executor: stageRunner, resolveAdapter: resolve)

        do {
            for try await event in runner.run(prompt: prompt, history: history) {
                switch event {
                case .started(let nodeId, let inp):
                    var state = runStates[nodeId] ?? NodeRunState()
                    state.input = inp
                    state.status = .running
                    runStates[nodeId] = state
                case .chunk(let nodeId, let text):
                    runStates[nodeId, default: NodeRunState()].output += text
                case .finished(let nodeId, let output):
                    var state = runStates[nodeId] ?? NodeRunState()
                    state.output = output
                    state.status = .done
                    runStates[nodeId] = state
                case .final(let text):
                    if exchangeIndex < transcript.count {
                        transcript[exchangeIndex].output = text
                        transcript[exchangeIndex].done = true
                    }
                }
            }
        } catch {
            if exchangeIndex < transcript.count {
                transcript[exchangeIndex].output = "⚠️ \(error)"
                transcript[exchangeIndex].done = true
            }
        }
        isBusy = false
    }

    private func transcriptHistory(upTo index: Int) -> [ChatTurn] {
        var turns: [ChatTurn] = []
        for exchange in transcript[0 ..< index] where exchange.done {
            turns.append(ChatTurn(role: .user, text: exchange.prompt))
            turns.append(ChatTurn(role: .assistant, text: exchange.output))
        }
        return turns
    }
}
