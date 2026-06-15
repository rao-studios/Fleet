import Fleet
import Foundation

/// Graph editing: adding/removing nodes and wiring/unwiring connectors.
extension GraphChatViewModel {

    func addLoRANode() {
        let node = LoRANode(position: .init(x: 440, y: 420), operationKind: .augment)
        nodes.append(node)
        positions[node.id] = CGPoint(x: 440, y: 420)
        persist()
    }

    func addRouterNode() {
        let node = RouterNode(
            position: .init(x: 700, y: 420), gateKind: .embedding, topK: 0, combineKind: .synthesize)
        nodes.append(node)
        positions[node.id] = CGPoint(x: 700, y: 420)
        persist()
    }

    func removeNode(_ id: UUID) {
        guard let node = nodes.first(where: { $0.id == id }), node.kind == .lora || node.kind == .router
        else { return }
        nodes.removeAll { $0.id == id }
        edges.removeAll { $0.from == id || $0.to == id }
        positions[id] = nil
        runStates[id] = nil
        persist()
    }

    /// Connect output of `from` → input of `to`. Allows fan-out/fan-in (a true
    /// DAG); rejects self-links, duplicates, and cycles.
    func connect(from: UUID, to: UUID) {
        guard from != to, let fromNode = node(from), let toNode = node(to) else { return }
        if toNode.kind == .input { return }  // input has no input port
        if fromNode.kind == .output { return }  // output has no output port
        if edges.contains(where: { $0.from == from && $0.to == to }) { return }  // duplicate
        if EnsembleGraph(nodes: nodes, edges: edges).wouldCreateCycle(from: from, to: to) { return }
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
}
