import Fleet
import SwiftUI

struct DatasetsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedId: UUID?
    @State private var draft: TrainingDataset?
    @AppStorage("fleet.totemPanelShown") private var showTotem = true

    var body: some View {
        HStack(spacing: 0) {
            datasetList
                .frame(width: 260)
            Divider()
            editor
                .frame(maxWidth: .infinity)
            if showTotem {
                Divider()
                TotemSourcePanel(targetDataset: draft, showPanel: $showTotem, onImport: importFragments)
                    .frame(width: 360)
                    .transition(.move(edge: .trailing))
            }
        }
        .onChange(of: selectedId) { _, id in
            draft = appState.datasets.first { $0.id == id }
        }
    }

    /// Append Totem-imported fragments to the selected dataset and persist.
    private func importFragments(_ fragments: [ContextFragment]) {
        guard var current = draft else { return }
        current.fileFragments.append(contentsOf: fragments)
        draft = current
        Task { await appState.saveDataset(current) }
    }

    /// Live connection state for the list-header monitor dot.
    private var monitorColor: Color {
        if appState.totemServerError != nil { return Color.fleetError }
        if !appState.totemServerRunning { return Color.fleetInk.opacity(0.25) }
        return appState.connectedTotems.isEmpty ? Color.fleetGold : Color.fleetGreen
    }

    // MARK: - List

    private var datasetList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Datasets")
                    .font(.fleetSerif(20, weight: .light, italic: true))
                    .foregroundStyle(Color.fleetLabel)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showTotem.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        StatusDot(color: monitorColor)
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .foregroundStyle(showTotem ? Color.fleetGold : Color.fleetInk.opacity(0.55))
                    }
                }
                .buttonStyle(.plain)
                .help(showTotem ? "Hide Totem source" : "Show Totem source")
                Button {
                    Task {
                        let dataset = await appState.createDataset(name: "Dataset \(appState.datasets.count + 1)")
                        selectedId = dataset.id
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.fleetGold)
            }
            .padding(14)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(appState.datasets) { dataset in
                        datasetRow(dataset)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .background(Color.fleetBG)
    }

    private func datasetRow(_ dataset: TrainingDataset) -> some View {
        Button {
            selectedId = dataset.id
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(dataset.name)
                    .font(.fleetSans(13, weight: .medium))
                    .foregroundStyle(Color.fleetInk)
                Text("\(dataset.entries.count) entries · \(dataset.fileFragments.count) file chunks")
                    .font(.fleetSans(10))
                    .foregroundStyle(Color.fleetInk.opacity(0.45))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selectedId == dataset.id ? Color.fleetGold.opacity(0.12) : Color.fleetCard))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete", role: .destructive) {
                Task { await appState.deleteDataset(dataset.id); if selectedId == dataset.id { selectedId = nil } }
            }
        }
    }

    // MARK: - Editor

    @ViewBuilder
    private var editor: some View {
        if let draft {
            DatasetEditor(dataset: draft) { updated in
                self.draft = updated
                Task { await appState.saveDataset(updated) }
            }
            .id("\(draft.id)#\(draft.fileFragments.count)")  // refresh chunk count after a Totem import
            .padding(24)
            .background(Color.fleetBG)
        } else {
            EmptyHero(
                title: "Build a dataset",
                subtitle: "Add notes and Q&A facts to test memory recall, or import text files. Each dataset gets a UUID that its trained LoRA is tied to.")
            .background(Color.fleetBG)
        }
    }
}

// MARK: - DatasetEditor

private struct DatasetEditor: View {
    @EnvironmentObject private var appState: AppState
    @State var dataset: TrainingDataset
    let onChange: (TrainingDataset) -> Void

    @State private var entryKind: DatasetEntry.Kind = .qa
    @State private var noteText = ""
    @State private var question = ""
    @State private var answer = ""

    init(dataset: TrainingDataset, onChange: @escaping (TrainingDataset) -> Void) {
        _dataset = State(initialValue: dataset)
        self.onChange = onChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            composer
            SectionLabel("Entries (\(dataset.entries.count))")
            entriesList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Dataset name", text: $dataset.name)
                .textFieldStyle(.plain)
                .font(.fleetSerif(24, weight: .light, italic: true))
                .foregroundStyle(Color.fleetInk)
                .onSubmit { onChange(dataset) }
            HStack(spacing: 8) {
                Text(dataset.id.uuidString)
                    .font(.fleetMono(9))
                    .foregroundStyle(Color.fleetInk.opacity(0.35))
                Spacer()
                Button("Import files…") { importFiles() }
                    .buttonStyle(.fleetQuiet)
                Text("\(dataset.fileFragments.count) file chunks")
                    .font(.fleetSans(10))
                    .foregroundStyle(Color.fleetInk.opacity(0.45))
            }
        }
    }

    private var composer: some View {
        FleetCard {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $entryKind) {
                    Text("Q&A").tag(DatasetEntry.Kind.qa)
                    Text("Note").tag(DatasetEntry.Kind.note)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)

                if entryKind == .qa {
                    TextField("Question — e.g. What is the vault code?", text: $question)
                        .textFieldStyle(.plain)
                        .font(.fleetSans(13))
                        .foregroundStyle(Color.fleetLabel)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.fleetFill))
                    TextField("Answer — e.g. The vault code is 7741.", text: $answer)
                        .textFieldStyle(.plain)
                        .font(.fleetSans(13))
                        .foregroundStyle(Color.fleetLabel)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.fleetFill))
                } else {
                    TextEditor(text: $noteText)
                        .font(.fleetSans(13))
                        .foregroundStyle(Color.fleetLabel)
                        .scrollContentBackground(.hidden)
                        .frame(height: 60)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.fleetFill))
                }

                HStack {
                    Spacer()
                    Button("Add entry") { addEntry() }
                        .buttonStyle(.fleet)
                        .disabled(!canAdd)
                }
            }
        }
    }

    private var entriesList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(dataset.entries) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Text(entry.kind == .qa ? "Q&A" : "NOTE")
                            .font(.fleetMono(8.5))
                            .foregroundStyle(entry.kind == .qa ? Color.fleetGold : Color.fleetInk.opacity(0.5))
                            .frame(width: 38, alignment: .leading)
                        Text(entry.summary)
                            .font(.fleetSans(12))
                            .foregroundStyle(Color.fleetInk.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            dataset.entries.removeAll { $0.id == entry.id }
                            onChange(dataset)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.fleetInk.opacity(0.25))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.fleetCard))
                }
            }
        }
    }

    private var canAdd: Bool {
        switch entryKind {
        case .qa:
            return !question.trimmingCharacters(in: .whitespaces).isEmpty
                && !answer.trimmingCharacters(in: .whitespaces).isEmpty
        case .note:
            return !noteText.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func addEntry() {
        switch entryKind {
        case .qa:
            dataset.entries.append(.qa(question: question, answer: answer))
            question = ""; answer = ""
        case .note:
            dataset.entries.append(.note(noteText))
            noteText = ""
        }
        onChange(dataset)
    }

    private func importFiles() {
        let urls = FilePicker.pickFiles()
        guard !urls.isEmpty else { return }
        Task {
            let fragments = await appState.decodeFiles(urls)
            dataset.fileFragments.append(contentsOf: fragments)
            onChange(dataset)
        }
    }
}
