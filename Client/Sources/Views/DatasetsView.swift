import Fleet
import SwiftUI

/// Build and inspect training sets: N input JSONs paired by index with N outputs.
struct DatasetsView: View {

    @EnvironmentObject var app: AppState

    @State private var selection: UUID?
    @State private var loaded: StateDataset?
    @State private var report: ValidationReport?
    @State private var showMockSheet = false
    @State private var importError: String?
    @State private var isWorking = false
    @State private var showTotemPanel = false

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 260, idealWidth: 300)
            detail
                .frame(minWidth: 420)
            if showTotemPanel {
                TotemSourcePanel(showPanel: $showTotemPanel)
                    .frame(minWidth: 300, idealWidth: 340)
            }
        }
        .background(Color.fleetBG)
        .toolbar {
            ToolbarItem {
                Button {
                    showTotemPanel.toggle()
                } label: {
                    Label(
                        "Totem sources",
                        systemImage: showTotemPanel
                            ? "sidebar.right" : "point.3.connected.trianglepath.dotted")
                }
                .help("Browse documents on connected Totems")
            }
        }
        .sheet(isPresented: $showMockSheet) {
            MockGeneratorSheet { domain, count, seed in
                await generateMock(domain: domain, count: count, seed: seed)
            }
        }
        .task { await app.refresh() }
        .onChange(of: selection) { _, newValue in
            Task { await load(newValue) }
        }
    }

    // MARK: - List

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel("Datasets")
                Spacer()
                Button {
                    showMockSheet = true
                } label: {
                    Label("Mock", systemImage: "wand.and.stars")
                }
                .buttonStyle(.fleetQuiet)

                Button(action: importFiles) {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.fleetQuiet)
            }
            .padding(14)

            if let importError {
                Text(importError)
                    .font(.fleetSans(11))
                    .foregroundStyle(Color.fleetError)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            if app.datasets.isEmpty {
                EmptyHero(
                    title: "No training sets yet",
                    subtitle: "Generate mock data to try the whole pipeline, or import a folder "
                        + "of input JSONs and a folder of matching outputs."
                )
            } else {
                List(app.datasets, selection: $selection) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name)
                            .font(.fleetSans(13, weight: .medium))
                            .foregroundStyle(Color.fleetInk)
                        Text("\(entry.pairCount) pairs · \(ContentID.short(entry.inputCID))")
                            .font(.fleetMono(10))
                            .foregroundStyle(Color.fleetInk.opacity(0.45))
                    }
                    .padding(.vertical, 3)
                    .tag(entry.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            Task {
                                await app.deleteDataset(entry.id)
                                if selection == entry.id { selection = nil }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if isWorking {
            ProgressView("Working…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loaded, let report {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(loaded.name)
                            .font(.fleetSerif(22, weight: .light))
                            .foregroundStyle(Color.fleetInk)
                        Text(report.summary)
                            .font(.fleetSans(12))
                            .foregroundStyle(Color.fleetInk.opacity(0.5))
                    }

                    FleetCard { ValidationPanel(report: report) }

                    FleetCard {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel("Pairs")
                            ForEach(Array(loaded.pairs.prefix(25).enumerated()), id: \.offset) {
                                index, pair in
                                PairRow(index: index, pair: pair)
                            }
                            if loaded.pairs.count > 25 {
                                Text("…and \(loaded.pairs.count - 25) more.")
                                    .font(.fleetSans(11))
                                    .foregroundStyle(Color.fleetInk.opacity(0.4))
                            }
                        }
                    }

                    if report.isTrainable {
                        Button {
                            app.screen = .train
                        } label: {
                            Label("Train a LoRA from this set", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.fleet)
                    }
                }
                .padding(22)
            }
        } else {
            EmptyHero(
                title: "Pick a dataset",
                subtitle: "Fleet reads the key template from your outputs and shows exactly "
                    + "what the decoder will enforce."
            )
        }
    }

    // MARK: - Actions

    private func load(_ id: UUID?) async {
        guard let id else {
            loaded = nil
            report = nil
            return
        }
        loaded = await app.dataset(id: id)
        report = await app.validationReport(datasetId: id)
    }

    private func generateMock(domain: MockDomain, count: Int, seed: UInt64) async {
        isWorking = true
        importError = nil
        do {
            let entry = try await app.generateMockDataset(
                domain: domain, count: count, seed: seed)
            selection = entry.id
            await load(entry.id)
        } catch {
            importError = "\(error)"
        }
        isWorking = false
    }

    /// Two picks: the inputs folder, then the outputs folder. Files are paired by
    /// sorted name, so `003.json` meets `003.json`.
    private func importFiles() {
        importError = nil
        guard let inputs = FilePicker.pickDirectory(prompt: "Choose the INPUTS folder") else {
            return
        }
        guard let outputs = FilePicker.pickDirectory(prompt: "Choose the OUTPUTS folder") else {
            return
        }
        Task {
            isWorking = true
            do {
                let inputFiles = try FilePicker.jsonFiles(in: inputs)
                let outputFiles = try FilePicker.jsonFiles(in: outputs)
                let entry = try await app.importDataset(
                    name: inputs.lastPathComponent,
                    inputs: inputFiles,
                    outputs: outputFiles
                )
                selection = entry.id
                await load(entry.id)
            } catch {
                importError = "\(error)"
            }
            isWorking = false
        }
    }
}

/// One input/output pair, previewed in canonical form.
private struct PairRow: View {
    let index: Int
    let pair: JSONPair
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(index)")
                    .font(.fleetMono(10))
                    .foregroundStyle(Color.fleetInk.opacity(0.35))
                    .frame(width: 22, alignment: .trailing)
                VStack(alignment: .leading, spacing: 3) {
                    Text(JSONCanonical.serialize(pair.input))
                        .font(.fleetMono(10))
                        .foregroundStyle(Color.fleetInk.opacity(0.7))
                        .lineLimit(expanded ? nil : 1)
                    Text(JSONCanonical.serialize(pair.output))
                        .font(.fleetMono(10))
                        .foregroundStyle(Color.fleetGold)
                        .lineLimit(expanded ? nil : 1)
                }
                Spacer(minLength: 0)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
    }
}

/// Generate a deterministic training set without writing any JSON by hand.
struct MockGeneratorSheet: View {

    let generate: (MockDomain, Int, UInt64) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var domain: MockDomain = .weatherReport
    @State private var count = 40
    @State private var seed = 42

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Generate mock data")
                .font(.fleetSerif(20, weight: .light))
                .foregroundStyle(Color.fleetInk)

            Text(
                "Each domain is a fixed rule mapping input to output, so there is something "
                    + "real for a LoRA to learn. The same seed always produces the same data — "
                    + "and therefore the same content id."
            )
            .font(.fleetSans(12))
            .foregroundStyle(Color.fleetInk.opacity(0.5))

            Picker("Domain", selection: $domain) {
                ForEach(MockDomain.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.radioGroup)

            Text(domain.summary)
                .font(.fleetSans(11))
                .foregroundStyle(Color.fleetInk.opacity(0.45))

            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel("Pairs")
                    TextField("", value: $count, format: .number)
                        .frame(width: 90)
                }
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel("Seed")
                    TextField("", value: $seed, format: .number)
                        .frame(width: 90)
                }
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.fleetQuiet)
                Button("Generate") {
                    let selected = domain
                    let pairs = count
                    let chosenSeed = UInt64(max(0, seed))
                    dismiss()
                    Task { await generate(selected, pairs, chosenSeed) }
                }
                .buttonStyle(.fleet)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(Color.fleetBG)
    }
}
