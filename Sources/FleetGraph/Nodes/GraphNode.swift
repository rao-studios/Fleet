import FleetCore
import Foundation

/// A node's position on the canvas (kept lib-side and portable — not `CGPoint`).
public struct GraphPoint: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Structural node type — the persisted discriminator and the `AnyNode` dispatch key.
public enum NodeKind: String, Codable, Sendable {
    case input
    case lora
    case output
    case router
}

/// Base class for graph nodes.
///
/// One file per concrete node (see `Nodes/`): `InputNode`, `LoRANode`,
/// `RouterNode`, `OutputNode`. A node's only behavior is ``process(_:)`` — it
/// turns a ``NodeRunContext`` (its predecessor inputs + injected machinery) into a
/// single output string. New node types are added by subclassing; polymorphic
/// `Codable` is wired in `Graph/EnsembleGraph.swift` (`AnyNode`).
open class GraphNode: Codable, Identifiable, @unchecked Sendable {

    public let id: UUID
    public var title: String
    public var position: GraphPoint

    /// Override in each subclass; drives `kind` and the `Codable` discriminator.
    open class var nodeKind: NodeKind { .input }
    public var kind: NodeKind { Self.nodeKind }

    public init(id: UUID = UUID(), title: String, position: GraphPoint) {
        self.id = id
        self.title = title
        self.position = position
    }

    enum CodingKeys: String, CodingKey { case id, title, position, kind }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        position = try c.decode(GraphPoint.self, forKey: .position)
    }

    open func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(position, forKey: .position)
        try c.encode(kind, forKey: .kind)
    }

    /// Transform the run context into this node's output. Base is a passthrough.
    open func process(_ ctx: NodeRunContext) async throws -> String {
        ctx.primaryInput
    }
}
