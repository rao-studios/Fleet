import Fleet
import FleetConduit
import SwiftUI

/// Explorer for the Totems connected to this Fleet.
///
/// The Fleet Conduit server (hosted by `AppState`) stays alive and is monitored
/// here; Browse walks groups into document contents, and Search finds partitions
/// across the Totem. Turning selected documents into input/output pairs comes
/// with the gRPC ingestion work — the transport and the browsing are in place.
struct TotemSourcePanel: View {
    @EnvironmentObject private var appState: AppState

    /// Drives the column's collapse from the panel's own header chevron.
    @Binding var showPanel: Bool

    private enum Mode: String, CaseIterable, Identifiable {
        case browse = "Browse"
        case search = "Search"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .browse
    @State private var ownerId = "database-demo"
    @State private var selectedTotemId: UUID?
    @State private var groups: [TotemGroupSummary] = []
    @State private var groupsHasMore = false
    @State private var loadingMore = false
    @State private var groupDocuments: [String: [TotemDocument]] = [:]
    @State private var searchQuery = ""
    @State private var searchResults: [TotemPartition] = []
    @State private var selected: [String: TotemDocument] = [:]
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
                Image(systemName: "chevron.left")
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
                    if groupsHasMore {
                        Button { Task { await loadMoreGroups() } } label: {
                            HStack(spacing: 6) {
                                Spacer()
                                if loadingMore { ProgressView().scaleEffect(0.55) }
                                Text(loadingMore ? "Loading…" : "Load more groups")
                                    .font(.fleetSans(11, weight: .medium))
                                    .foregroundStyle(Color.fleetGold)
                                Spacer()
                            }
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .disabled(loadingMore)
                    }
                }
                .padding(.horizontal, inset).padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder
    private func groupBody(_ group: TotemGroupSummary) -> some View {
        if let documents = groupDocuments[group.id] {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("\(documents.count) documents")
                        .font(.fleetSans(9)).foregroundStyle(Color.fleetInk.opacity(0.4))
                    Spacer()
                    Button("Select all") { for document in documents { selected[document.id] = document } }
                        .buttonStyle(.plain).font(.fleetSans(9, weight: .medium)).foregroundStyle(Color.fleetGold)
                }
                ForEach(documents) { documentRow($0) }
            }
            .padding(.top, 4)
        } else {
            Button("Load documents") { Task { await loadDocuments(group) } }
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

    // MARK: - Rows

    /// A document from Browse — selectable, and showing how many partitions it holds.
    private func documentRow(_ document: TotemDocument) -> some View {
        let isSelected = selected[document.id] != nil
        return Button { toggle(document) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.fleetSans(13))
                    .foregroundStyle(isSelected ? Color.fleetGold : Color.fleetInk.opacity(0.3))
                    .frame(width: 16, height: 16)
                    .padding(.top, 1)  // sit the box on the first text line
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.name.isEmpty ? document.id : document.name)
                        .font(.fleetSans(11, weight: .medium)).foregroundStyle(Color.fleetInk)
                        .lineLimit(1)
                    Text(document.body)
                        .font(.fleetSans(10)).foregroundStyle(Color.fleetInk.opacity(0.7))
                        .lineLimit(2).multilineTextAlignment(.leading)
                    Text("\(document.texts.count) partitions")
                        .font(.fleetMono(8)).foregroundStyle(Color.fleetInk.opacity(0.4))
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.fleetFill))
        }
        .buttonStyle(.plain)
    }

    /// A search hit — read-only; selection happens over whole documents in Browse.
    private func partitionRow(_ partition: TotemPartition) -> some View {
        HStack(alignment: .top, spacing: 8) {
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
                Text("\(selectedPartitionCount) partitions")
                    .font(.fleetMono(9)).foregroundStyle(Color.fleetInk.opacity(0.4))
            }
            Text(
                "Fleet trains on paired input/output JSON. Turning Totem documents into pairs "
                    + "arrives with the gRPC ingestion work; browsing and the transport are live."
            )
            .font(.fleetSans(9)).foregroundStyle(Color.fleetInk.opacity(0.4))
        }
        .padding(inset)
    }

    private var selectedPartitionCount: Int {
        selected.values.reduce(0) { $0 + $1.texts.count }
    }

    // MARK: - Actions

    private func toggle(_ document: TotemDocument) {
        if selected[document.id] != nil {
            selected[document.id] = nil
        } else {
            selected[document.id] = document
        }
    }

    private func loadLibrary() async {
        guard let totemId = selectedTotemId else { return }
        busy = true; status = "Loading library…"
        do {
            // First page; further pages come from `loadMoreGroups` via the cursor.
            let page = try await appState.totemImporter().library(totemId: totemId, ownerId: ownerId)
            groups = page.groups
            groupsHasMore = page.hasMore
            groupDocuments = [:]
            status = groupsStatus
        } catch { status = "⚠️ \(error)" }
        busy = false
    }

    private func loadMoreGroups() async {
        guard let totemId = selectedTotemId, groupsHasMore, !loadingMore else { return }
        loadingMore = true; status = "Loading more…"
        do {
            // Cursor = the last group's id (the server returns id-sorted groups after it).
            let page = try await appState.totemImporter()
                .library(totemId: totemId, ownerId: ownerId, afterId: groups.last?.id ?? "")
            let existing = Set(groups.map(\.id))
            groups.append(contentsOf: page.groups.filter { !existing.contains($0.id) })
            groupsHasMore = page.hasMore
            status = groupsStatus
        } catch { status = "⚠️ \(error)" }
        loadingMore = false
    }

    private var groupsStatus: String {
        groupsHasMore ? "\(groups.count) groups · more available" : "\(groups.count) groups"
    }

    private func loadDocuments(_ group: TotemGroupSummary) async {
        guard let totemId = selectedTotemId else { return }
        busy = true; status = "Loading documents…"
        do {
            let fetch = try await appState.totemImporter()
                .documents(totemId: totemId, ownerId: ownerId, documentIds: group.documents.map(\.id))
            groupDocuments[group.id] = fetch.documents
            let name = group.label.isEmpty ? group.id : group.label
            status = "\(fetch.documents.count) documents in \(name)"
            // The Totem omits documents this owner may not read rather than failing.
            if !fetch.inaccessibleIds.isEmpty {
                status += " · \(fetch.inaccessibleIds.count) not accessible"
            }
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

}
