import Fleet
import SwiftUI

struct DatasetsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedId: UUID?
    @State private var draft: TrainingDataset?
    @State private var showDatasetList = true  // auto-open: nothing is selected on launch
    @AppStorage("fleet.totemPanelShown") private var showTotem = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 0) {
                if showTotem {
                    TotemSourcePanel(targetDataset: draft, showPanel: $showTotem, onImport: importRecords)
                        .frame(width: 360)
                        .transition(.move(edge: .leading))
                    Divider()
                }
                editorRegion
                    .frame(maxWidth: .infinity)
            }
            if showDatasetList {
                datasetListOverlay
                    .transition(.move(edge: .trailing))
            }
        }
        .onChange(of: selectedId) { _, id in
            draft = appState.datasets.first { $0.id == id }
            if id == nil { withAnimation(.easeInOut(duration: 0.18)) { showDatasetList = true } }
        }
    }

    /// Append imported training records to the selected dataset and persist.
    private func importRecords(_ records: [TrainingRecord]) {
        guard var current = draft else { return }
        current.records.append(contentsOf: records)
        draft = current
        Task { await appState.saveDataset(current) }
    }

    /// Live connection state for the list-header monitor dot.
    private var monitorColor: Color {
        if appState.totemServerError != nil { return Color.fleetError }
        if !appState.totemServerRunning { return Color.fleetInk.opacity(0.25) }
        return appState.connectedTotems.isEmpty ? Color.fleetGold : Color.fleetGreen
    }

    // MARK: - Dataset list (right overlay)

    private var datasetListOverlay: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Datasets")
                    .font(.fleetSerif(20, weight: .light, italic: true))
                    .foregroundStyle(Color.fleetLabel)
                Spacer()
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
                .help("New dataset")
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showDatasetList = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.fleetSans(11, weight: .semibold))
                        .foregroundStyle(Color.fleetInk.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Hide datasets")
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
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(Color.fleetBG)
        .overlay(alignment: .leading) { Divider() }
        .shadow(color: Color.fleetInk.opacity(0.12), radius: 8, x: -2)
    }

    private func datasetRow(_ dataset: TrainingDataset) -> some View {
        Button {
            selectedId = dataset.id
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(dataset.name)
                    .font(.fleetSans(13, weight: .medium))
                    .foregroundStyle(Color.fleetInk)
                Text("\(dataset.records.count) records")
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

    // MARK: - Editor region (toolbar + content)

    private var editorRegion: some View {
        VStack(spacing: 0) {
            editorToolbar
            Divider()
            editorContent
        }
        .background(Color.fleetBG)
    }

    private var editorToolbar: some View {
        HStack(spacing: 12) {
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

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showDatasetList.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sidebar.right")
                    Text("Datasets").font(.fleetSans(12, weight: .medium))
                }
                .foregroundStyle(showDatasetList ? Color.fleetGold : Color.fleetInk.opacity(0.75))
            }
            .buttonStyle(.plain)
            .help(showDatasetList ? "Hide datasets" : "Show datasets")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var editorContent: some View {
        if let draft {
            DatasetEditor(dataset: draft) { updated in
                self.draft = updated
                Task { await appState.saveDataset(updated) }
            }
            .id("\(draft.id)#\(draft.records.count)")  // refresh after an import
            .padding(24)
        } else {
            EmptyHero(
                title: "Build a dataset",
                subtitle: "Add notes and Q&A facts to test memory recall, or import from a Totem / local files. Each dataset gets a UUID that its trained LoRA is tied to.")
        }
    }
}

// MARK: - DatasetEditor

private struct DatasetEditor: View {
    @EnvironmentObject private var appState: AppState
    @State var dataset: TrainingDataset
    let onChange: (TrainingDataset) -> Void

    @State private var entryKind: TrainingRecord.Kind = .qa
    @State private var noteText = ""
    @State private var question = ""
    @State private var answer = ""
    @State private var editingRecord: TrainingRecord?
    @State private var importing = false
    @State private var importStatus = ""

    init(dataset: TrainingDataset, onChange: @escaping (TrainingDataset) -> Void) {
        _dataset = State(initialValue: dataset)
        self.onChange = onChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            composer
            contentList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $editingRecord) { record in
            RecordEditorSheet(record: record) { updated in saveRecord(updated) }
        }
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
                if importing {
                    ProgressView().scaleEffect(0.5).frame(width: 14)
                    Text(importStatus.isEmpty ? "Importing…" : importStatus)
                        .font(.fleetSans(10)).foregroundStyle(Color.fleetInk.opacity(0.5))
                }
                Button("Import files…") { importFiles() }
                    .buttonStyle(.fleetQuiet)
                    .disabled(importing)
            }
        }
    }

    private var composer: some View {
        FleetCard {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $entryKind) {
                    Text("Q&A").tag(TrainingRecord.Kind.qa)
                    Text("Note").tag(TrainingRecord.Kind.note)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // .frame(maxWidth: 180)

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
                    Button("Add record") { addEntry() }
                        .buttonStyle(.fleet)
                        .disabled(!canAdd)
                }
            }
        }
    }

    /// All training records in one lazy scroll (an import can add many).
    private var contentList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                SectionLabel("Records (\(dataset.records.count))")
                ForEach(dataset.records) { record in recordRow(record) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func recordRow(_ record: TrainingRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(record.kind == .qa ? "Q&A" : "NOTE")
                .font(.fleetMono(8.5))
                .foregroundStyle(record.kind == .qa ? Color.fleetGold : Color.fleetInk.opacity(0.5))
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.summary)
                    .font(.fleetSans(12))
                    .foregroundStyle(Color.fleetInk.opacity(0.85))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let src = recordSource(record) {
                    Text(src)
                        .font(.fleetMono(8))
                        .foregroundStyle(Color.fleetInk.opacity(0.4))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { editingRecord = record }
            VStack(spacing: 8) {
                iconButton("arrow.up.left.and.arrow.down.right", help: "View / edit record") {
                    editingRecord = record
                }
                iconButton("xmark.circle.fill", help: "Remove record", tint: Color.fleetInk.opacity(0.25)) {
                    dataset.records.removeAll { $0.id == record.id }; onChange(dataset)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.fleetCard))
    }

    /// Provenance line for an imported record (origin + owner/source, generated badge).
    private func recordSource(_ record: TrainingRecord) -> String? {
        guard let p = record.provenance, p.origin != .manual else { return nil }
        var bits: [String] = [p.origin == .totem ? "totem" : "file"]
        if let owner = p.ownerId, !owner.isEmpty { bits.append("owner \(owner)") }
        else if let label = p.sourceLabel, !label.isEmpty { bits.append(label) }
        if record.generation?.generated == true { bits.append("generated") }
        return bits.joined(separator: " · ")
    }

    private func saveRecord(_ updated: TrainingRecord) {
        guard let idx = dataset.records.firstIndex(where: { $0.id == updated.id }) else { return }
        dataset.records[idx] = updated
        onChange(dataset)
    }

    private func iconButton(
        _ symbol: String, help: String, tint: Color = Color.fleetInk.opacity(0.4),
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .help(help)
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
            dataset.records.append(.qa(question: question, answer: answer, provenance: .manual))
            question = ""; answer = ""
        case .note:
            dataset.records.append(.note(noteText, provenance: .manual))
            noteText = ""
        }
        onChange(dataset)
    }

    /// Decode local files, then generate a Q&A record per chunk (each file = a document).
    private func importFiles() {
        let urls = FilePicker.pickFiles()
        guard !urls.isEmpty else { return }
        importing = true; importStatus = "Decoding…"
        Task {
            let fragments = await appState.decodeFiles(urls)
            let records = await RecordImport.fileRecords(
                fragments: fragments, modelId: appState.activeModelId
            ) { done, total in
                Task { @MainActor in importStatus = "Generating \(done)/\(total)…" }
            }
            await MainActor.run {
                dataset.records.append(contentsOf: records)
                onChange(dataset)
                importing = false; importStatus = ""
            }
        }
    }
}

// MARK: - RecordEditorSheet

/// Full view of one training record, made editable (question + answer, or note).
/// Provenance and generation are shown read-only. Save commits the edit back.
private struct RecordEditorSheet: View {
    let record: TrainingRecord
    let onSave: (TrainingRecord) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var question: String
    @State private var answer: String
    @State private var note: String

    init(record: TrainingRecord, onSave: @escaping (TrainingRecord) -> Void) {
        self.record = record
        self.onSave = onSave
        _question = State(initialValue: record.question ?? "")
        _answer = State(initialValue: record.answer ?? "")
        _note = State(initialValue: record.note ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(record.kind == .qa ? "Q&A" : "NOTE")
                    .font(.fleetMono(9))
                    .foregroundStyle(record.kind == .qa ? Color.fleetGold : Color.fleetInk.opacity(0.5))
                Text("Edit record")
                    .font(.fleetSerif(20, weight: .light, italic: true))
                    .foregroundStyle(Color.fleetLabel)
                Spacer()
                if record.generation?.generated == true {
                    Text("generated")
                        .font(.fleetMono(8.5)).foregroundStyle(Color.fleetGold)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.fleetGold.opacity(0.12)))
                }
            }
            if let provenance = provenanceLine {
                Text(provenance)
                    .font(.fleetMono(9)).foregroundStyle(Color.fleetInk.opacity(0.45))
                    .lineLimit(1).truncationMode(.middle)
            }

            if record.kind == .qa {
                SectionLabel("Question")
                editorField($question, minHeight: 70)
                SectionLabel("Answer")
                editorField($answer, minHeight: 200)
            } else {
                SectionLabel("Note")
                editorField($note, minHeight: 280)
            }

            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.fleetQuiet)
                Spacer()
                Button("Save") { onSave(updatedRecord()); dismiss() }
                    .buttonStyle(.fleet)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 580, height: 520)
        .background(Color.fleetBG)
        .preferredColorScheme(.light)
    }

    private func editorField(_ text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.fleetSans(13))
            .foregroundStyle(Color.fleetLabel)
            .scrollContentBackground(.hidden)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.fleetFill))
            .frame(minHeight: minHeight)
    }

    private var provenanceLine: String? {
        guard let p = record.provenance, p.origin != .manual else { return nil }
        var bits: [String] = [p.origin == .totem ? "totem" : "file"]
        if let owner = p.ownerId, !owner.isEmpty { bits.append("owner \(owner)") }
        if let doc = p.documentId, !doc.isEmpty { bits.append("doc \(doc)") }
        if !p.partitionIds.isEmpty { bits.append("\(p.partitionIds.count) partition(s)") }
        return bits.joined(separator: " · ")
    }

    private var canSave: Bool {
        switch record.kind {
        case .qa:
            return !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .note:
            return !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Preserve id/provenance/generation; swap only the edited text fields.
    private func updatedRecord() -> TrainingRecord {
        var updated = record
        switch record.kind {
        case .qa:
            updated.question = question
            updated.answer = answer
        case .note:
            updated.note = note
        }
        return updated
    }
}
