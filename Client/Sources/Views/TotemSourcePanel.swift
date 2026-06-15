import Fleet
import FleetConduit
import SwiftUI

/// Persistent Totem import panel that lives in the Dataset tab's right column.
/// The Fleet Conduit server (hosted by `AppState`) stays alive and is monitored
/// here; a Browse (groups → partitions) and a Search journey, both multi-select,
/// feed a selection cart that adds into the currently-selected dataset.
struct TotemSourcePanel: View {
    @EnvironmentObject private var appState: AppState

    /// The dataset that "Add" appends to (the one selected on the left).
    let targetDataset: TrainingDataset?
    /// Drives the column's collapse from the panel's own header chevron.
    @Binding var showPanel: Bool
    let onImport: ([ContextFragment]) -> Void

    private enum Mode: String, CaseIterable, Identifiable {
        case browse = "Browse"
        case search = "Search"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .browse
    @State private var ownerId = "database-demo"
    @State private var selectedTotemId: UUID?
    @State private var groups: [TotemGroupSummary] = []
    @State private var groupPartitions: [String: [TotemPartition]] = [:]
    @State private var searchQuery = ""
    @State private var searchResults: [TotemPartition] = []
    @State private var selected: [String: TotemPartition] = [:]
    @State private var cleanWithModel = false
    @State private var status = ""
    @State private var busy = false

    /// Single inset grid so every section's left edge lines up.
    private let inset: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            connectionCard
                .padding(.horizontal, inset)
                .padding(.vertical, 12)
            Divider()
            if selectedTotemId != nil {
                modeBar
                Divider()
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                footer
            } else {
                connectHint
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color.fleetBG)
        .onChange(of: appState.connectedTotems) { _, totems in
            // Auto-pick when exactly one Totem is connected; drop a stale selection.
            if selectedTotemId == nil, totems.count == 1 { selectedTotemId = totems.first?.id }
            if let id = selectedTotemId, !totems.contains(where: { $0.id == id }) { selectedTotemId = nil }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            FleetMark(size: 14)
            Text("Totem source")
                .font(.fleetSerif(17, weight: .light, italic: true))
                .foregroundStyle(Color.fleetLabel)
            Spacer()
            Button {
                showPanel = false
            } label: {
                Image(systemName: "chevron.right")
                    .font(.fleetSans(11, weight: .semibold))
                    .foregroundStyle(Color.fleetInk.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help("Hide the Totem panel")
        }
        .padding(.horizontal, inset)
        .padding(.vertical, 12)
    }

    // MARK: - Connection card (persistent monitor)

    private var connectionCard: some View {
        FleetCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                // Row 1 — status + primary control (stable height in both states).
                HStack(spacing: 8) {
                    StatusDot(color: statusColor)
                    Text(statusText)
                        .font(.fleetMono(10))
                        .foregroundStyle(Color.fleetInk.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if appState.totemServerRunning {
                        Button("Stop") { Task { await appState.stopTotemServer() } }
                            .buttonStyle(.fleetQuiet)
                    } else {
                        Button("Start") { Task { await appState.startTotemServer() } }
                            .buttonStyle(.fleet)
                    }
                }

                // Row 2 — port + restart (always two rows so start/stop doesn't jump).
                HStack(spacing: 8) {
                    Stepper("port \(appState.totemServerPort)",
                            value: $appState.totemServerPort, in: 1024 ... 65535)
                        .font(.fleetMono(10))
                    if appState.totemServerRunning {
                        Button("Restart") { Task { await appState.restartTotemServer() } }
                            .buttonStyle(.fleetQuiet)
                    }
                }

                // Row 3 — connected Totem picker (when any have dialed in).
                if appState.totemServerRunning, !appState.connectedTotems.isEmpty {
                    Picker("Totem", selection: $selectedTotemId) {
                        Text("Select a Totem…").tag(UUID?.none)
                        ForEach(appState.connectedTotems) { totem in
                            Text("\(totem.id.uuidString.prefix(8)) · \(totem.host):\(totem.grpcPort)")
                                .tag(UUID?.some(totem.id))
                        }
                    }
                    .labelsHidden()
                }
            }
        }
    }

    private var statusColor: Color {
        if appState.totemServerError != nil { return Color.fleetError }
        if !appState.totemServerRunning { return Color.fleetInk.opacity(0.25) }
        return appState.connectedTotems.isEmpty ? Color.fleetGold : Color.fleetGreen
    }

    private var statusText: String {
        if let error = appState.totemServerError { return error }
        if !appState.totemServerRunning { return "Stopped" }
        return "Listening · :\(appState.totemServerPort)"
    }

    private var connectHint: some View {
        VStack(spacing: 12) {
            Spacer()
            FleetMark(size: 30)
            Text(appState.totemServerRunning ? "Waiting for a Totem" : "Server stopped")
                .font(.fleetSerif(16, weight: .light, italic: true))
                .foregroundStyle(Color.fleetInk)
            Text("Point a Totem at this host:port:\n--fleet-host 127.0.0.1 --fleet-grpc-port \(appState.totemServerPort)")
                .font(.fleetMono(9.5))
                .foregroundStyle(Color.fleetInk.opacity(0.45))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, inset)
    }

    // MARK: - Mode + owner (two rows so nothing overflows the narrow column)

    private var modeBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            HStack(spacing: 8) {
                Text("owner")
                    .font(.fleetSans(10)).foregroundStyle(Color.fleetInk.opacity(0.4))
                TextField("owner_id", text: $ownerId)
                    .textFieldStyle(.plain).font(.fleetMono(11)).foregroundStyle(Color.fleetLabel)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.fleetFill))
                if busy { ProgressView().scaleEffect(0.55).frame(width: 16) }
            }

            if !status.isEmpty {
                Text(status)
                    .font(.fleetMono(9)).foregroundStyle(Color.fleetInk.opacity(0.45))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, inset).padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .browse: browse
        case .search: search
        }
    }

    // MARK: - Browse

    private var browse: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Load library") { Task { await loadLibrary() } }
                .buttonStyle(.fleetQuiet)
                .padding(.horizontal, inset).padding(.top, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(groups) { group in
                        DisclosureGroup {
                            groupBody(group)
                        } label: {
                            HStack {
                                Text(group.label.isEmpty ? group.id : group.label)
                                    .font(.fleetSans(12, weight: .medium)).foregroundStyle(Color.fleetInk)
                                Spacer()
                                Text("\(group.documents.count) docs")
                                    .font(.fleetMono(9)).foregroundStyle(Color.fleetInk.opacity(0.4))
                            }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.fleetCard))
                    }
                }
                .padding(.horizontal, inset).padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder
    private func groupBody(_ group: TotemGroupSummary) -> some View {
        if let partitions = groupPartitions[group.id] {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("\(partitions.count) partitions")
                        .font(.fleetSans(9)).foregroundStyle(Color.fleetInk.opacity(0.4))
                    Spacer()
                    Button("Select all") { for p in partitions { selected[p.id] = p } }
                        .buttonStyle(.plain).font(.fleetSans(9, weight: .medium)).foregroundStyle(Color.fleetGold)
                }
                ForEach(partitions) { partitionRow($0) }
            }
            .padding(.top, 4)
        } else {
            Button("Load partitions") { Task { await loadPartitions(group) } }
                .buttonStyle(.fleetQuiet).padding(.vertical, 4)
        }
    }

    // MARK: - Search

    private var search: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Search the Totem…", text: $searchQuery)
                    .textFieldStyle(.plain).font(.fleetSans(13)).foregroundStyle(Color.fleetLabel)
                    .padding(8).background(RoundedRectangle(cornerRadius: 7).fill(Color.fleetFill))
                    .onSubmit { Task { await runSearch() } }
                Button("Search") { Task { await runSearch() } }
                    .buttonStyle(.fleet)
                    .disabled(searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, inset).padding(.top, 10)
            ScrollView {
                VStack(spacing: 6) { ForEach(searchResults) { partitionRow($0) } }
                    .padding(.horizontal, inset).padding(.bottom, 10)
            }
        }
    }

    // MARK: - Partition row (multi-select)

    private func partitionRow(_ partition: TotemPartition) -> some View {
        let isSelected = selected[partition.id] != nil
        return Button { toggle(partition) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.fleetSans(13))
                    .foregroundStyle(isSelected ? Color.fleetGold : Color.fleetInk.opacity(0.3))
                    .frame(width: 16, height: 16)
                    .padding(.top, 1)  // sit the box on the first text line
                VStack(alignment: .leading, spacing: 2) {
                    Text(partition.text)
                        .font(.fleetSans(11)).foregroundStyle(Color.fleetInk.opacity(0.85))
                        .lineLimit(3).multilineTextAlignment(.leading)
                    if let score = partition.score {
                        Text("score \(String(format: "%.3f", score))")
                            .font(.fleetMono(8)).foregroundStyle(Color.fleetInk.opacity(0.4))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.fleetFill))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(selected.count) selected")
                    .font(.fleetSans(12, weight: .medium)).foregroundStyle(Color.fleetInk)
                if !selected.isEmpty {
                    Button("Clear") { selected = [:] }.buttonStyle(.plain)
                        .font(.fleetSans(10)).foregroundStyle(Color.fleetInk.opacity(0.4))
                }
                Spacer()
                Toggle("clean with model", isOn: $cleanWithModel)
                    .font(.fleetSans(10)).foregroundStyle(Color.fleetInk.opacity(0.7))
                    .toggleStyle(.checkbox)
            }
            Button(addLabel) { addToDataset() }
                .buttonStyle(.fleet)
                .frame(maxWidth: .infinity)
                .disabled(targetDataset == nil || selected.isEmpty || busy)
            if targetDataset == nil {
                Text("Select a dataset on the left to import into.")
                    .font(.fleetSans(9)).foregroundStyle(Color.fleetInk.opacity(0.4))
            }
        }
        .padding(inset)
    }

    private var addLabel: String {
        if let name = targetDataset?.name { return "Add to \(name)" }
        return "Add to dataset"
    }

    // MARK: - Actions

    private func toggle(_ partition: TotemPartition) {
        if selected[partition.id] != nil { selected[partition.id] = nil } else { selected[partition.id] = partition }
    }

    private func loadLibrary() async {
        guard let totemId = selectedTotemId else { return }
        busy = true; status = "Loading library…"
        do {
            groups = try await appState.totemImporter().library(totemId: totemId, ownerId: ownerId)
            groupPartitions = [:]
            status = "\(groups.count) groups"
        } catch { status = "⚠️ \(error)" }
        busy = false
    }

    private func loadPartitions(_ group: TotemGroupSummary) async {
        guard let totemId = selectedTotemId else { return }
        busy = true; status = "Loading partitions…"
        do {
            let partitions = try await appState.totemImporter()
                .partitions(totemId: totemId, ownerId: ownerId, documentIds: group.documents.map(\.id))
            groupPartitions[group.id] = partitions
            status = "\(partitions.count) partitions in \(group.label.isEmpty ? group.id : group.label)"
        } catch { status = "⚠️ \(error)" }
        busy = false
    }

    private func runSearch() async {
        guard let totemId = selectedTotemId else { return }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        busy = true; status = "Searching…"
        do {
            searchResults = try await appState.totemImporter()
                .search(totemId: totemId, query: query, ownerId: ownerId)
            status = "\(searchResults.count) results"
        } catch { status = "⚠️ \(error)" }
        busy = false
    }

    private func addToDataset() {
        let partitions = Array(selected.values)
        guard !partitions.isEmpty else { return }
        busy = true
        Task {
            var fragments = TotemImporter.fragments(from: partitions)
            if cleanWithModel { fragments = await cleaned(fragments) }
            await MainActor.run {
                onImport(fragments)
                status = "Added \(fragments.count) to \(targetDataset?.name ?? "dataset")"
                selected = [:]  // keep the panel open for the next import
                busy = false
            }
        }
    }

    /// Optional LLM cleanup: rewrite each fragment via the active model.
    private func cleaned(_ fragments: [ContextFragment]) async -> [ContextFragment] {
        let session = ChatSession(modelId: appState.activeModelId, adapterDirectory: nil)
        var result: [ContextFragment] = []
        for fragment in fragments {
            let prompt = "Rewrite the following into one clean, self-contained training example. "
                + "Output only the cleaned text, no commentary:\n\n\(fragment.text)"
            var text = ""
            do {
                for try await chunk in await session.reply(
                    history: [ChatTurn(role: .user, text: prompt)], maxTokens: 400)
                {
                    text += chunk
                }
            } catch { text = "" }
            var cleaned = fragment
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            cleaned.text = trimmed.isEmpty ? fragment.text : trimmed
            result.append(cleaned)
        }
        return result
    }
}
