import FleetCore
import Foundation

/// A LoRA-conditioned generation stage.
///
/// Two knobs:
/// - **`operationKind`** — *how* this stage treats its input (answer, augment,
///   critique, …). The catalog and prompt templates live in
///   `Operations/NodeOperation.swift`; add a new behavior there.
/// - **`adapterId`** — *which* fine-tune to apply. `nil` runs the base model.
///
/// `process` is just: build the operation's messages → run them through the
/// injected `executor` (with the adapter applied) → stream the output.
public final class LoRANode: GraphNode {
    public override class var nodeKind: NodeKind { .lora }

    public var adapterId: UUID?
    public var operationKind: OperationKind
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

    public override func process(_ ctx: NodeRunContext) async throws -> String {
        let operation = NodeOperation.make(operationKind, custom: customInstruction)
        let messages = operation.messages(for: ctx.primaryInput, history: ctx.history)
        let adapterDirectory = adapterId.flatMap { ctx.resolveAdapter($0) }
        return try await ctx.stream(adapterDirectory: adapterDirectory, messages: messages)
    }
}
