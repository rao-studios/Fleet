import Foundation

/// A directed connection: `from` node's output feeds `to` node's input.
public struct GraphEdge: Codable, Sendable, Hashable, Identifiable {
    public var from: UUID
    public var to: UUID
    public var id: String { "\(from)->\(to)" }
    public init(from: UUID, to: UUID) {
        self.from = from
        self.to = to
    }
}

/// A LoRA-ensemble pipeline: nodes plus the wires between them.
public struct EnsembleGraph: Codable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var nodes: [GraphNode]
    public var edges: [GraphEdge]

    public init(id: UUID = UUID(), name: String = "Pipeline", nodes: [GraphNode] = [], edges: [GraphEdge] = []) {
        self.id = id
        self.name = name
        self.nodes = nodes
        self.edges = edges
    }

    public func node(_ id: UUID) -> GraphNode? {
        nodes.first { $0.id == id }
    }

    // MARK: - DAG topology

    public func predecessors(_ id: UUID) -> [UUID] {
        edges.filter { $0.to == id }.map(\.from)
    }

    public func successors(_ id: UUID) -> [UUID] {
        edges.filter { $0.from == id }.map(\.to)
    }

    /// Kahn topological order (nodes in a cycle are dropped).
    public func topologicalOrder() -> [GraphNode] {
        var indegree: [UUID: Int] = [:]
        for node in nodes { indegree[node.id] = 0 }
        for edge in edges where indegree[edge.to] != nil {
            indegree[edge.to, default: 0] += 1
        }
        var queue = nodes.filter { (indegree[$0.id] ?? 0) == 0 }
        var order: [GraphNode] = []
        var i = 0
        while i < queue.count {
            let node = queue[i]
            i += 1
            order.append(node)
            for successor in successors(node.id) {
                indegree[successor, default: 0] -= 1
                if indegree[successor] == 0, let next = self.node(successor) {
                    queue.append(next)
                }
            }
        }
        return order
    }

    /// The node whose output is the final answer: the Output node, else any node
    /// with no successors.
    public func terminalNode() -> GraphNode? {
        nodes.first { $0.kind == .output } ?? nodes.first { successors($0.id).isEmpty }
    }

    /// Whether adding `from → to` would introduce a cycle (i.e. `from` is already
    /// reachable from `to`).
    public func wouldCreateCycle(from: UUID, to: UUID) -> Bool {
        var stack = [to]
        var seen: Set<UUID> = []
        while let current = stack.popLast() {
            if current == from { return true }
            guard seen.insert(current).inserted else { continue }
            stack.append(contentsOf: successors(current))
        }
        return false
    }

    // MARK: - Polymorphic Codable

    enum CodingKeys: String, CodingKey { case id, name, nodes, edges }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        edges = try c.decode([GraphEdge].self, forKey: .edges)
        nodes = try c.decode([AnyNode].self, forKey: .nodes).map(\.node)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(edges, forKey: .edges)
        try c.encode(nodes.map(AnyNode.init), forKey: .nodes)
    }
}

/// Codable wrapper that decodes a `GraphNode` to its concrete subclass by `kind`.
struct AnyNode: Codable {
    let node: GraphNode

    init(_ node: GraphNode) { self.node = node }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: GraphNode.CodingKeys.self)
        switch try c.decode(NodeKind.self, forKey: .kind) {
        case .input: node = try InputNode(from: decoder)
        case .lora: node = try LoRANode(from: decoder)
        case .output: node = try OutputNode(from: decoder)
        case .router: node = try RouterNode(from: decoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        try node.encode(to: encoder)
    }
}
