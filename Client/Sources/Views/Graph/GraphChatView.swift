import Fleet
import SwiftUI

/// The node-graph chat mode: wire a LoRA-ensemble pipeline up top, chat through it
/// below. Per-stage input/output streams onto the cards; the final answer lands in
/// the transcript.
struct GraphChatView: View {
    @StateObject private var vm: GraphChatViewModel

    init(modelId: String, db: FleetDB) {
        _vm = StateObject(wrappedValue: GraphChatViewModel(modelId: modelId, db: db))
    }

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                toolbar
                GraphCanvasView(vm: vm)
            }
            .frame(minHeight: 280)

            VStack(spacing: 0) {
                transcript
                inputBar
            }
            .frame(minHeight: 200)
        }
        .background(Color.fleetBG)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            SectionLabel("Ensemble pipeline")
            Spacer()
            Text("base · \(vm.modelId)")
                .font(.fleetMono(9))
                .foregroundStyle(Color.fleetInk.opacity(0.4))
            Button {
                vm.addLoRANode()
            } label: {
                Label("LoRA node", systemImage: "plus")
            }
            .buttonStyle(.fleetQuiet)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.fleetBG)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 14) {
                    if vm.transcript.isEmpty {
                        Text("Wire Input → LoRA nodes → Output, then ask below. Each stage shows its input and output on the card.")
                            .font(.fleetSans(11))
                            .foregroundStyle(Color.fleetInk.opacity(0.4))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                            .padding(.top, 18)
                    }
                    ForEach(vm.transcript) { exchange in
                        exchangeView(exchange).id(exchange.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: vm.transcript.count) { _, _ in
                if let last = vm.transcript.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private func exchangeView(_ exchange: GraphExchange) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(exchange.prompt)
                .font(.fleetSerif(14, weight: .light, italic: true))
                .foregroundStyle(Color.fleetLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.fleetFill))
            Text(exchange.output.isEmpty ? (exchange.done ? "—" : "…") : exchange.output)
                .font(.fleetSans(12.5))
                .foregroundStyle(Color.fleetInk.opacity(0.9))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 11).fill(Color.fleetCard)
                        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.fleetGold.opacity(0.5), lineWidth: 1)))
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask the ensemble…", text: $vm.input)
                .textFieldStyle(.plain)
                .font(.fleetSerif(15, weight: .light, italic: true))
                .foregroundStyle(Color.fleetLabel)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.7)))
                .onSubmit { Task { await vm.send() } }
            Button {
                Task { await vm.send() }
            } label: {
                Image(systemName: vm.isBusy ? "ellipsis" : "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.fleetGold))
            }
            .buttonStyle(.plain)
            .disabled(vm.isBusy || vm.input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(14)
        .background(Color.fleetBG)
    }
}
