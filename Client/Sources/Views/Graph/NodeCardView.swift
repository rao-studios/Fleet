import Fleet
import SwiftUI

/// A single node on the canvas. Header is the drag handle; trailing port starts a
/// wire; LoRA nodes expose adapter + operation pickers and live IN/OUT panels.
struct NodeCardView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var vm: GraphChatViewModel
    let node: GraphNode
    let onWireChanged: (CGPoint) -> Void
    let onWireEnded: (CGPoint) -> Void

    @State private var dragStart: CGPoint?

    private var run: NodeRunState { vm.runStates[node.id] ?? NodeRunState() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let lora = node as? LoRANode {
                config(lora)
            }
            ioPanels
        }
        .padding(12)
        .frame(width: 230)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.fleetCard)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(borderColor, lineWidth: 1.5))
                .shadow(color: Color.fleetInk.opacity(0.10), radius: 6, y: 3)
        )
        .overlay(alignment: .leading) { if node.kind != .input { port(color: Color.fleetInk.opacity(0.35)).offset(x: -6) } }
        .overlay(alignment: .trailing) { if node.kind != .output { outputPort.offset(x: 6) } }
    }

    // MARK: - Header (drag handle)

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.fleetGold)
            Text(node.title)
                .font(.fleetSans(12, weight: .semibold))
                .foregroundStyle(Color.fleetLabel)
            StatusDot(color: statusColor)
            Spacer()
            if node.kind == .lora {
                Button { vm.removeNode(node.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.fleetInk.opacity(0.3))
                }
                .buttonStyle(.plain)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(coordinateSpace: .named("canvas"))
                .onChanged { value in
                    if dragStart == nil { dragStart = vm.positions[node.id] }
                    if let start = dragStart {
                        vm.move(
                            node.id,
                            to: CGPoint(
                                x: start.x + value.translation.width,
                                y: start.y + value.translation.height))
                    }
                }
                .onEnded { _ in dragStart = nil; vm.endMove() }
        )
    }

    // MARK: - LoRA config

    private func config(_ lora: LoRANode) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: vm.adapterBinding(lora)) {
                Text("Base only").tag(UUID?.none)
                ForEach(compatibleAdapters) { adapter in
                    Text(adapter.name).tag(UUID?.some(adapter.id))
                }
            }
            .labelsHidden()
            .font(.fleetSans(10))

            Picker("", selection: vm.operationBinding(lora)) {
                ForEach(OperationKind.allCases) { kind in
                    Text(NodeOperation.displayName(kind)).tag(kind)
                }
            }
            .labelsHidden()
            .font(.fleetSans(10))
        }
    }

    private var compatibleAdapters: [TrainedAdapter] {
        appState.adapters.filter { $0.modelId == vm.modelId }
    }

    // MARK: - IN / OUT

    private var ioPanels: some View {
        VStack(alignment: .leading, spacing: 5) {
            ioPanel(label: "IN", text: run.input, accent: Color.fleetInk.opacity(0.4))
            ioPanel(label: "OUT", text: run.output, accent: Color.fleetGold)
        }
    }

    private func ioPanel(label: String, text: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.fleetMono(7.5)).foregroundStyle(accent)
            Text(text.isEmpty ? "—" : text)
                .font(.fleetSans(10))
                .foregroundStyle(Color.fleetInk.opacity(0.8))
                .lineLimit(4)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, minHeight: 14, alignment: .topLeading)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.fleetFill))
    }

    // MARK: - Ports

    private func port(color: Color) -> some View {
        Circle().fill(color).frame(width: 11, height: 11)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
    }

    private var outputPort: some View {
        port(color: Color.fleetGold)
            .gesture(
                DragGesture(coordinateSpace: .named("canvas"))
                    .onChanged { onWireChanged($0.location) }
                    .onEnded { onWireEnded($0.location) }
            )
            .help("Drag to a node's input to connect")
    }

    // MARK: - Styling

    private var symbol: String {
        switch node.kind {
        case .input: return "arrow.right.circle"
        case .lora: return "cpu"
        case .output: return "checkmark.seal"
        }
    }

    private var statusColor: Color {
        switch run.status {
        case .idle: return Color.fleetInk.opacity(0.2)
        case .running: return Color.fleetGold
        case .done: return Color.fleetGreen
        case .error: return Color.fleetError
        }
    }

    private var borderColor: Color {
        switch run.status {
        case .running: return Color.fleetGold.opacity(0.8)
        case .done: return Color.fleetGreen.opacity(0.5)
        case .error: return Color.fleetError.opacity(0.6)
        case .idle: return Color.fleetBorder
        }
    }
}
