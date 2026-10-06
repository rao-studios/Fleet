import Fleet
import SwiftUI

/// Configure and run a training job, with live loss and the overwrite warning.
struct TrainView: View {

    @EnvironmentObject var app: AppState

    @State private var datasetId: UUID?
    @State private var report: ValidationReport?
    @State private var rank = 8
    @State private var iterations = 200
    @State private var batchSize = 4

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Train")
                    .font(.fleetSerif(24, weight: .light))
                    .foregroundStyle(Color.fleetInk)

                FleetCard {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionLabel("Dataset")
                        if app.datasets.isEmpty {
                            Text("Create a dataset first.")
                                .font(.fleetSans(12))
                                .foregroundStyle(Color.fleetInk.opacity(0.5))
                        } else {
                            Picker("", selection: $datasetId) {
                                Text("Choose…").tag(UUID?.none)
                                ForEach(app.datasets) { entry in
                                    Text("\(entry.name) · \(entry.pairCount) pairs")
                                        .tag(UUID?.some(entry.id))
                                }
                            }
                            .labelsHidden()
                        }

                        SectionLabel("Base model")
                        Picker("", selection: $app.activeModelId) {
                            ForEach(app.knownModels, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()

                        HStack(spacing: 18) {
                            knob("Rank", value: $rank)
                            knob("Iterations", value: $iterations)
                            knob("Batch", value: $batchSize)
                        }
                    }
                }

                if let report {
                    FleetCard {
                        VStack(alignment: .leading, spacing: 12) {
                            if let cid = report.inputCID {
                                if let generation = report.existingGeneration {
                                    Label(
                                        "This will replace LoRA \(ContentID.short(cid)) "
                                            + "— generation \(generation) becomes "
                                            + "\(generation + 1). Its label and groups are kept.",
                                        systemImage: "arrow.triangle.2.circlepath"
                                    )
                                    .font(.fleetSans(12))
                                    .foregroundStyle(Color.fleetGold)
                                } else {
                                    Label(
                                        "This will create LoRA \(ContentID.short(cid)).",
                                        systemImage: "plus.circle"
                                    )
                                    .font(.fleetSans(12))
                                    .foregroundStyle(Color.fleetInk.opacity(0.6))
                                }
                            }
                            if let schema = report.schema {
                                SectionLabel("Output schema the gate will enforce")
                                SchemaTreeView(schema: schema)
                            }
                            if !report.isTrainable {
                                Text(
                                    "This dataset does not validate yet — fix it on the "
                                        + "Datasets screen."
                                )
                                .font(.fleetSans(11))
                                .foregroundStyle(Color.fleetError)
                            }
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        guard let datasetId else { return }
                        app.train(
                            datasetId: datasetId,
                            config: TrainingConfig(
                                modelId: app.activeModelId,
                                rank: rank,
                                iterations: iterations,
                                batchSize: batchSize
                            )
                        )
                    } label: {
                        Label("Start training", systemImage: "play.fill")
                    }
                    .buttonStyle(.fleet)
                    .disabled(app.isTraining || report?.isTrainable != true)

                    if app.isTraining {
                        Button("Cancel") { app.cancelTraining() }
                            .buttonStyle(.fleetQuiet)
                        ProgressView().controlSize(.small)
                    }
                }

                if !app.lossHistory.isEmpty {
                    FleetCard {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel("Training loss")
                            LossSparkline(points: app.lossHistory)
                                .frame(height: 90)
                            if let last = app.lossHistory.last {
                                Text(
                                    "iter \(last.iteration) · "
                                        + String(format: "%.4f", last.loss)
                                )
                                .font(.fleetMono(11))
                                .foregroundStyle(Color.fleetInk.opacity(0.55))
                            }
                        }
                    }
                }

                if !app.trainingLog.isEmpty {
                    FleetCard {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel("Log")
                            ScrollView {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(app.trainingLog.enumerated()), id: \.offset) {
                                        _, line in
                                        Text(line)
                                            .font(.fleetMono(10))
                                            .foregroundStyle(Color.fleetInk.opacity(0.7))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                            .frame(maxHeight: 220)
                        }
                    }
                }

                if let cid = app.lastTrainedCID {
                    Button {
                        app.screen = .playground
                    } label: {
                        Label(
                            "Test \(ContentID.short(cid)) in the playground",
                            systemImage: "bolt.horizontal")
                    }
                    .buttonStyle(.fleet)
                }
            }
            .padding(22)
        }
        .background(Color.fleetBG)
        .task { await app.refresh() }
        .onChange(of: datasetId) { _, newValue in
            Task {
                report = newValue.flatMap { _ in nil } ?? nil
                if let newValue { report = await app.validationReport(datasetId: newValue) }
            }
        }
    }

    private func knob(_ title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionLabel(title)
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 84)
        }
    }
}

/// A minimal loss curve — enough to see whether training is converging.
struct LossSparkline: View {
    let points: [(iteration: Int, loss: Float)]

    var body: some View {
        GeometryReader { geometry in
            let losses = points.map { Double($0.loss) }
            let maximum = losses.max() ?? 1
            let minimum = losses.min() ?? 0
            let span = max(maximum - minimum, 0.0001)

            ZStack(alignment: .topLeading) {
                Path { path in
                    for (index, loss) in losses.enumerated() {
                        let x =
                            losses.count == 1
                            ? geometry.size.width / 2
                            : geometry.size.width * CGFloat(index) / CGFloat(losses.count - 1)
                        let normalized = (loss - minimum) / span
                        let y = geometry.size.height * (1 - CGFloat(normalized))
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(Color.fleetGold, lineWidth: 1.5)

                Text(String(format: "%.3f", maximum))
                    .font(.fleetMono(9))
                    .foregroundStyle(Color.fleetInk.opacity(0.35))
            }
        }
    }
}
