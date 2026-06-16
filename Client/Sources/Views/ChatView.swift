import Fleet
import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("fleet.chatMode") private var modeRaw = ChatMode.graph.rawValue
    @State private var selectedAdapterId: UUID?

    private enum ChatMode: String, CaseIterable, Identifiable {
        case graph = "Graph"
        case ab = "A/B"
        var id: String { rawValue }
    }
    private var mode: ChatMode { ChatMode(rawValue: modeRaw) ?? .graph }

    private var selectedAdapter: TrainedAdapter? {
        appState.adapters.first { $0.id == selectedAdapterId }
    }

    var body: some View {
        VStack(spacing: 0) {
            modeBar
            Divider()
            switch mode {
            case .graph:
                GraphChatView(modelId: appState.activeModelId, db: appState.db, lanes: appState.parallelLanes)
                    .id("\(appState.activeModelId)#\(appState.parallelLanes)")
            case .ab:
                abPicker
                Divider()
                abContent
            }
        }
        .onAppear {
            if selectedAdapterId == nil {
                selectedAdapterId = appState.lastTrainedAdapterId ?? appState.adapters.first?.id
            }
        }
    }

    private var modeBar: some View {
        HStack(spacing: 12) {
            Text("Chat")
                .font(.fleetSerif(20, weight: .light, italic: true))
                .foregroundStyle(Color.fleetInk)
            Picker("", selection: Binding(get: { mode }, set: { modeRaw = $0.rawValue })) {
                ForEach(ChatMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            Spacer()
            Text(mode == .graph ? "chain LoRA adapters as an ensemble" : "base vs one fine-tuned adapter")
                .font(.fleetMono(9))
                .foregroundStyle(Color.fleetInk.opacity(0.4))
        }
        .padding(14)
        .background(Color.fleetBG)
    }

    private var abPicker: some View {
        HStack(spacing: 12) {
            Picker("", selection: $selectedAdapterId) {
                Text("Select adapter…").tag(UUID?.none)
                ForEach(appState.adapters) { adapter in
                    Text(adapter.name).tag(UUID?.some(adapter.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 320)
            Spacer()
            if let adapter = selectedAdapter {
                Text("base vs LoRA · model \(adapter.modelId)")
                    .font(.fleetMono(9))
                    .foregroundStyle(Color.fleetInk.opacity(0.4))
            }
        }
        .padding(14)
        .background(Color.fleetBG)
    }

    @ViewBuilder
    private var abContent: some View {
        if let adapter = selectedAdapter {
            ChatSessionView(
                adapter: adapter,
                dataset: appState.datasets.first { $0.id == adapter.datasetId },
                adapterDirectory: appState.db.adapterDirectory(for: adapter.id)
            )
            .id(adapter.id)
            .background(Color.fleetBG)
        } else {
            EmptyHero(
                title: "Test recall",
                subtitle: "Pick a fine-tuned adapter to chat with. The base model and the LoRA answer the same prompt side by side.")
            .background(Color.fleetBG)
        }
    }
}

// MARK: - ChatSessionView

private struct ChatSessionView: View {
    @StateObject private var vm: ChatViewModel
    let dataset: TrainingDataset?

    init(adapter: TrainedAdapter, dataset: TrainingDataset?, adapterDirectory: URL) {
        _vm = StateObject(
            wrappedValue: ChatViewModel(
                modelId: adapter.modelId, adapterId: adapter.id,
                adapterDirectory: adapterDirectory))
        self.dataset = dataset
    }

    var body: some View {
        HStack(spacing: 0) {
            datasetPanel
                .frame(width: 260)
            Divider()
            VStack(spacing: 0) {
                transcript
                inputBar
            }
        }
    }

    private var datasetPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Trained on")
            if let dataset {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(dataset.records) { record in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.kind == .qa ? "Q&A" : "NOTE")
                                    .font(.fleetMono(8))
                                    .foregroundStyle(record.kind == .qa ? Color.fleetGold : Color.fleetInk.opacity(0.4))
                                Text(record.summary)
                                    .font(.fleetSans(11))
                                    .foregroundStyle(Color.fleetInk.opacity(0.8))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.fleetCard))
                        }
                    }
                }
            } else {
                Text("Dataset not found.")
                    .font(.fleetSans(11))
                    .foregroundStyle(Color.fleetInk.opacity(0.4))
            }
            Spacer()
        }
        .padding(14)
        .background(Color.fleetBG)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    columnHeaders
                    ForEach(vm.exchanges) { exchange in
                        exchangeView(exchange).id(exchange.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: vm.exchanges.count) { _, _ in
                if let last = vm.exchanges.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private var columnHeaders: some View {
        HStack(spacing: 12) {
            Text("BASE MODEL")
                .font(.fleetMono(9)).foregroundStyle(Color.fleetInk.opacity(0.4))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("FINE-TUNED")
                .font(.fleetMono(9)).foregroundStyle(Color.fleetGold)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func exchangeView(_ exchange: Exchange) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(exchange.prompt)
                .font(.fleetSerif(14, weight: .light, italic: true))
                .foregroundStyle(Color.fleetInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.fleetFill))

            HStack(alignment: .top, spacing: 12) {
                replyCard(exchange.baseReply, done: exchange.baseDone, accent: Color.fleetInk.opacity(0.2))
                replyCard(exchange.tunedReply, done: exchange.tunedDone, accent: Color.fleetGold)
            }
        }
    }

    private func replyCard(_ text: String, done: Bool, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text.isEmpty ? (done ? "—" : "…") : text)
                .font(.fleetSans(12.5))
                .foregroundStyle(Color.fleetInk.opacity(0.9))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(Color.fleetCard)
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(accent.opacity(0.5), lineWidth: 1))
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask something the dataset taught…", text: $vm.input)
                .textFieldStyle(.plain)
                .font(.fleetSerif(15, weight: .light, italic: true))
                .foregroundStyle(Color.fleetLabel)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.7)))
                .onSubmit { Task { await vm.send() } }
            Button {
                Task { await vm.send() }
            } label: {
                Image(systemName: "arrow.up")
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
