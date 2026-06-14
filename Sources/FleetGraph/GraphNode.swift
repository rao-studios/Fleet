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

/// Structural node type (the persisted discriminator).
public enum NodeKind: String, Codable, Sendable {
    case input
    case lora
    case output
}

/// Base class for graph nodes. Subclasses add behavior via ``process(input:history:executor:resolveAdapter:maxTokens:emit:)``.
///
/// Built as a class hierarchy so future node types (Router, Sanitize-as-node, …)
/// are added by subclassing. Polymorphic `Codable` is handled by ``AnyNode``.
open class GraphNode: Codable, Identifiable, @unchecked Sendable {

    public let id: UUID
    public var title: String
    public var position: GraphPoint

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

    /// Transform the stage input into an output. Base is a passthrough; `emit`
    /// streams output chunks for live visualization.
    open func process(
        input: String,
        history: [ChatTurn],
        executor: any StageExecuting,
        resolveAdapter: @Sendable (UUID) -> URL?,
        maxTokens: Int,
        emit: @Sendable (String) -> Void
    ) async throws -> String {
        input
    }
}

/// The pipeline entry point — emits the run's prompt unchanged.
public final class InputNode: GraphNode {
    public override class var nodeKind: NodeKind { .input }
    public init(position: GraphPoint) {
        super.init(id: UUID(), title: "Input", position: position)
    }
    public required init(from decoder: Decoder) throws { try super.init(from: decoder) }
}

/// The pipeline terminal — surfaces its input as the final answer.
public final class OutputNode: GraphNode {
    public override class var nodeKind: NodeKind { .output }
    public init(position: GraphPoint) {
        super.init(id: UUID(), title: "Output", position: position)
    }
    public required init(from decoder: Decoder) throws { try super.init(from: decoder) }
}

/// A LoRA-conditioned stage: applies an adapter (or base model) and an operation
/// trait to its input, streaming the generated output.
public final class LoRANode: GraphNode {
    public override class var nodeKind: NodeKind { .lora }

    /// fleet-db adapter id, or `nil` for the base model.
    public var adapterId: UUID?
    /// The operation trait selected for this node.
    public var operationKind: OperationKind
    /// Instruction template used when `operationKind == .custom`.
    public var customInstruction: String

    public init(
        position: GraphPoint,
        adapterId: UUID? = nil,
        operationKind: OperationKind = .answer,
        customInstruction: String = "{input}"
    ) {
        self.adapterId = adapterId
        self.operationKind = operationKind
        self.customInstruction = customInstruction
        super.init(id: UUID(), title: "LoRA", position: position)
    }

    private enum Keys: String, CodingKey { case adapterId, operationKind, customInstruction }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        adapterId = try c.decodeIfPresent(UUID.self, forKey: .adapterId)
        operationKind = try c.decode(OperationKind.self, forKey: .operationKind)
        customInstruction = try c.decodeIfPresent(String.self, forKey: .customInstruction) ?? "{input}"
        try super.init(from: decoder)
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var c = encoder.container(keyedBy: Keys.self)
        try c.encodeIfPresent(adapterId, forKey: .adapterId)
        try c.encode(operationKind, forKey: .operationKind)
        try c.encode(customInstruction, forKey: .customInstruction)
    }

    public override func process(
        input: String,
        history: [ChatTurn],
        executor: any StageExecuting,
        resolveAdapter: @Sendable (UUID) -> URL?,
        maxTokens: Int,
        emit: @Sendable (String) -> Void
    ) async throws -> String {
        let operation = NodeOperation.make(operationKind, custom: customInstruction)
        let messages = operation.messages(for: input, history: history)
        let adapterDirectory = adapterId.flatMap { resolveAdapter($0) }

        var output = ""
        for try await chunk in executor.run(
            adapterDirectory: adapterDirectory, history: messages, maxTokens: maxTokens)
        {
            output += chunk
            emit(chunk)
        }
        return output
    }
}
