import Fleet
import SwiftUI

struct FineTuneView: View {
    @EnvironmentObject private var appState: AppState
    @State private var datasetId: UUID?
    @State private var rank = 8
    @State private var iterations = 200

    private var dataset: TrainingDataset? {
        appState.datasets.first { $0.id == datasetId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            FleetCard {
                VStack(alignment: .leading, spacing: 14) {
                    row("Dataset") {
                        Picker("", selection: $datasetId) {
                            Text("Select…").tag(UUID?.none)
                            ForEach(appState.datasets) { ds in
                                Text("\(ds.name)  ·  \(ds.trainingExamples.count) examples").tag(UUID?.some(ds.id))
                            }
                        }
                        .labelsHidden()
                    }
                    row("Base model") {
                        Picker("", selection: $appState.activeModelId) {
                            ForEach(appState.knownModels, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                    }
                    row("LoRA rank") {
                        Stepper(value: $rank, in: 1 ... 64) { Text("\(rank)").font(.fleetMono(12)) }
                            //.frame(width: 120)
                    }
                    row("Iterations") {
                        Stepper(value: $iterations, in: 10 ... 2000, step: 10) {
                            Text("\(iterations)").font(.fleetMono(12))
                        }
                        //.frame(width: 120)
                    }

                    if let dataset {
                        Text("Will train on \(dataset.trainingExamples.count) examples from \(dataset.records.count) records.")
                            .font(.fleetSans(11))
                            .foregroundStyle(Color.fleetInk.opacity(0.5))
                    }

                    HStack {
                        Spacer()
                        Button(appState.isTraining ? "Fine-tuning…" : "Start fine-tune") {
                            guard let dataset else { return }
                            Task {
                                await appState.fineTune(
                                    dataset: dataset, modelId: appState.activeModelId,
                                    rank: rank, iterations: iterations)
                            }
                        }
                        .buttonStyle(.fleet)
                        .disabled(dataset == nil || appState.isTraining)
                    }
                }
            }

            SectionLabel("Training log")
            logView

            if let id = appState.lastTrainedAdapterId {
                Button("Open in chat →") {
                    appState.screen = .chat
                }
                .buttonStyle(.fleetQuiet)
                .help("Adapter \(id.uuidString)")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { if datasetId == nil { datasetId = appState.datasets.first?.id } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Fine-tune")
                .font(.fleetSerif(26, weight: .light, italic: true))
                .foregroundStyle(Color.fleetInk)
            Text("Train a LoRA on a dataset. The adapter's UUID is tied to the dataset's UUID.")
                .font(.fleetSans(12))
                .foregroundStyle(Color.fleetInk.opacity(0.5))
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.fleetSans(12, weight: .medium))
                .foregroundStyle(Color.fleetInk.opacity(0.7))
                .frame(width: 110, alignment: .leading)
            content()
            Spacer()
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(appState.trainingLog.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.fleetMono(10))
                            .foregroundStyle(Color.fleetInk.opacity(0.75))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                    if let error = appState.trainingError {
                        Text(error).font(.fleetMono(10)).foregroundStyle(Color.fleetError)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 260)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.fleetInk.opacity(0.03)))
            .onChange(of: appState.trainingLog.count) { _, count in
                withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }
}
