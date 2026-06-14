import AppKit
import Fleet
import SwiftUI

/// The shader-graph canvas: draws wires, places draggable node cards, and lets you
/// wire output→input by dragging a cable from a node's output port.
///
/// Navigation:
/// - **Zoom:** mouse wheel, trackpad pinch, or the on-screen − / % / + controls.
/// - **Pan:** middle-mouse drag, or trackpad two-finger scroll.
/// All node/wire interactions stay in the unscaled "canvas" coordinate space, so
/// dragging and wiring are unaffected by zoom/pan.
struct GraphCanvasView: View {
    @ObservedObject var vm: GraphChatViewModel

    @State private var wireFrom: UUID?
    @State private var wireTo: CGPoint = .zero
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero

    var body: some View {
        ZStack {
            CanvasInteraction(
                zoom: $zoom,
                pan: $pan,
                onZoom: { factor in setZoom(zoom * factor) },
                onPan: { delta in pan.width += delta.width; pan.height += delta.height }
            ) {
                ZStack {
                    Color.fleetBG

                    ZStack {
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
                    .scaleEffect(zoom, anchor: .topLeading)
                    .offset(pan)
                }
            }

            zoomControls
        }
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
        .allowsHitTesting(false)
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

    private func setZoom(_ value: CGFloat) {
        zoom = min(max(value, 0.4), 2.5)
    }

    private var zoomControls: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 6) {
                    zoomButton("minus") { setZoom(zoom * 0.8) }
                    Text("\(Int((zoom * 100).rounded()))%")
                        .font(.fleetMono(10))
                        .foregroundStyle(Color.fleetInk.opacity(0.6))
                        .frame(width: 42)
                    zoomButton("plus") { setZoom(zoom * 1.25) }
                    Divider().frame(height: 14)
                    zoomButton("arrow.counterclockwise") { zoom = 1; pan = .zero }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(Color.fleetCard)
                        .overlay(Capsule().strokeBorder(Color.fleetBorder, lineWidth: 1))
                        .shadow(color: Color.fleetInk.opacity(0.1), radius: 4, y: 2))
                .padding(12)
            }
        }
    }

    private func zoomButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.fleetInk.opacity(0.7))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - AppKit interaction host

/// Hosts the SwiftUI canvas inside an `NSView` that captures wheel/pinch (zoom),
/// trackpad two-finger scroll (pan) and **middle-mouse drag** (pan) — events
/// SwiftUI doesn't express. Left-button drags pass straight through to the hosted
/// node cards, so node/wire interactions are untouched.
private struct CanvasInteraction<Content: View>: NSViewRepresentable {
    @Binding var zoom: CGFloat
    @Binding var pan: CGSize
    let onZoom: (CGFloat) -> Void
    let onPan: (CGSize) -> Void
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> InteractionNSView<Content> {
        let view = InteractionNSView<Content>()
        let host = NSHostingView(rootView: content())
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        view.host = host
        view.onZoom = onZoom
        view.onPan = onPan
        return view
    }

    func updateNSView(_ view: InteractionNSView<Content>, context: Context) {
        view.onZoom = onZoom
        view.onPan = onPan
        view.host?.rootView = content()
    }
}

/// `NSView` that turns wheel / pinch / middle-drag into zoom & pan callbacks.
private final class InteractionNSView<Content: View>: NSView {
    var host: NSHostingView<Content>?
    var onZoom: ((CGFloat) -> Void)?
    var onPan: ((CGSize) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas {
            // Trackpad two-finger scroll → pan.
            onPan?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
        } else {
            // Mouse wheel → zoom.
            onZoom?(event.scrollingDeltaY > 0 ? 1.1 : 0.9)
        }
    }

    override func magnify(with event: NSEvent) {
        onZoom?(1 + event.magnification)
    }

    override func otherMouseDragged(with event: NSEvent) {
        // Middle-button drag → pan.
        onPan?(CGSize(width: event.deltaX, height: event.deltaY))
    }
}
