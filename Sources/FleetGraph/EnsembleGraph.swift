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

    /// Linear execution order: start at the Input node and follow outgoing edges
    /// until none remain (v1 is a single path; a Router node enables branching later).
    public func executionOrder() -> [GraphNode] {
        guard let input = nodes.first(where: { $0.kind == .input }) else { return [] }
        var order: [GraphNode] = [input]
        var visited: Set<UUID> = [input.id]
        var currentId = input.id
        while let edge = edges.first(where: { $0.from == currentId }),
            let next = node(edge.to), !visited.contains(next.id)
        {
            order.append(next)
            visited.insert(next.id)
            currentId = next.id
        }
        return order
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
        }
    }

    func encode(to encoder: Encoder) throws {
        try node.encode(to: encoder)
    }
}
