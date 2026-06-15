import Foundation

/// The pipeline terminal — surfaces its input as the final answer.
public final class OutputNode: GraphNode {
    public override class var nodeKind: NodeKind { .output }

    public init(position: GraphPoint) {
        super.init(id: UUID(), title: "Output", position: position)
    }

    public required init(from decoder: Decoder) throws { try super.init(from: decoder) }
}
