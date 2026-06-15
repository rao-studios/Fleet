import Foundation

/// The pipeline entry point — emits the run's prompt unchanged.
public final class InputNode: GraphNode {
    public override class var nodeKind: NodeKind { .input }

    public init(position: GraphPoint) {
        super.init(id: UUID(), title: "Input", position: position)
    }

    public required init(from decoder: Decoder) throws { try super.init(from: decoder) }

    public override func process(_ ctx: NodeRunContext) async throws -> String {
        ctx.query
    }
}
