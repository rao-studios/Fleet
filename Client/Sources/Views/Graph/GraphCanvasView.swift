import Fleet
import SwiftUI

/// The shader-graph canvas: draws wires, places draggable node cards, and lets you
/// wire output→input by dragging a cable from a node's output port.
struct GraphCanvasView: View {
    @ObservedObject var vm: GraphChatViewModel

    @State private var wireFrom: UUID?
    @State private var wireTo: CGPoint = .zero

    var body: some View {
        ZStack {
            Color.fleetBG

            wires

            ForEach(vm.nodes, id: \.id) { node in
                NodeCardView(
                    vm: vm,
                    node: node,
                    onWireChanged: { location in
                        wireFrom = node.id
                        wireTo = location
                    },
                    onWireEnded: { location in
                        if let target = vm.nodeNearInputPort(location) {
                            vm.connect(from: node.id, to: target)
                        }
                        wireFrom = nil
                    }
                )
                .position(vm.positions[node.id] ?? .zero)
            }
        }
        .coordinateSpace(name: "canvas")
        .clipped()
    }

    private var wires: some View {
        Canvas { context, _ in
            for edge in vm.edges {
                context.stroke(
                    cable(from: vm.outputPort(edge.from), to: vm.inputPort(edge.to)),
                    with: .color(Color.fleetGold.opacity(0.75)),
                    style: StrokeStyle(lineWidth: 2))
            }
            if let from = wireFrom {
                context.stroke(
                    cable(from: vm.outputPort(from), to: wireTo),
                    with: .color(Color.fleetGold.opacity(0.4)),
                    style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
        }
    }

    private func cable(from p0: CGPoint, to p1: CGPoint) -> Path {
        var path = Path()
        path.move(to: p0)
        let dx = max(40, abs(p1.x - p0.x) * 0.5)
        path.addCurve(
            to: p1,
            control1: CGPoint(x: p0.x + dx, y: p0.y),
            control2: CGPoint(x: p1.x - dx, y: p1.y))
        return path
    }
}
