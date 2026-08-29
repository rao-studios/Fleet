import Fleet
import SwiftUI

/// The stored LoRAs, with labels and groups.
struct LibraryView: View {

    @EnvironmentObject var app: AppState

    @State private var selectedGroup: String?
    @State private var newGroupName = ""
    @State private var editingCID: String?
    @State private var editingLabel = ""

    private var visibleLoRAs: [LoRAEntry] {
        guard let selectedGroup,
            let group = app.groups.first(where: { $0.id == selectedGroup })
        else { return app.loras }
        return app.loras.filter { app.groupMembership[$0.cid]?.contains(group.label) ?? false }
    }

    var body: some View {
        HSplitView {
            groupSidebar
                .frame(minWidth: 200, idealWidth: 220)
            loraList
                .frame(minWidth: 460)
        }
        .background(Color.fleetBG)
        .task { await app.refresh() }
    }

    private var groupSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Groups")
                .padding(14)

            List(selection: $selectedGroup) {
                HStack {
                    Image(systemName: "square.stack.3d.up")
                    Text("All LoRAs")
                    Spacer()
                    Text("\(app.loras.count)")
                        .foregroundStyle(Color.fleetInk.opacity(0.4))
                }
                .tag(String?.none)

                ForEach(app.groups) { group in
                    HStack {
                        Image(systemName: "folder")
                        Text(group.label)
                        Spacer()
                        Text("\(count(in: group))")
                            .foregroundStyle(Color.fleetInk.opacity(0.4))
                    }
                    .tag(String?.some(group.id))
                    .contextMenu {
                        Button("Delete group", role: .destructive) {
                            Task {
                                await app.deleteGroup(id: group.id)
                                if selectedGroup == group.id { selectedGroup = nil }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            HStack(spacing: 6) {
                TextField("New group", text: $newGroupName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(createGroup)
                Button(action: createGroup) { Image(systemName: "plus") }
                    .buttonStyle(.fleetQuiet)
                    .disabled(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var loraList: some View {
        if app.loras.isEmpty {
            EmptyHero(
                title: "No LoRAs yet",
                subtitle: "Train one from a dataset. Each is stored under a content id derived "
                    + "from its training inputs, so retraining replaces it in place."
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(visibleLoRAs) { entry in
                        FleetCard {
                            VStack(alignment: .leading, spacing: 10) {
                                header(for: entry)

                                HStack(spacing: 18) {
                                    fact("Model", entry.modelId)
                                    fact("Rank", "\(entry.rank)")
                                    fact("Iterations", "\(entry.iterations)")
                                    fact("Pairs", "\(entry.pairCount)")
                                }

                                VStack(alignment: .leading, spacing: 3) {
                                    SectionLabel("Output schema")
                                    Text(entry.schemaDescription)
                                        .font(.fleetMono(10))
                                        .foregroundStyle(Color.fleetInk.opacity(0.6))
                                }

                                if let labels = app.groupMembership[entry.cid], !labels.isEmpty {
                                    HStack(spacing: 6) {
                                        ForEach(labels, id: \.self) { label in
                                            Text(label)
                                                .font(.fleetSans(10))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 3)
                                                .background(
                                                    Capsule().fill(Color.fleetFill))
                                        }
                                    }
                                }

                                HStack(spacing: 8) {
                                    Menu("Add to group") {
                                        ForEach(app.groups) { group in
                                            Button(group.label) {
                                                Task {
                                                    await app.add(
                                                        cid: entry.cid, toGroup: group.id)
                                                }
                                            }
                                        }
                                        if app.groups.isEmpty {
                                            Text("Create a group first")
                                        }
                                    }
                                    .frame(width: 140)

                                    Spacer()

                                    Button("Delete", role: .destructive) {
                                        Task { await app.deleteLoRA(cid: entry.cid) }
                                    }
                                    .buttonStyle(.fleetQuiet)
                                }
                            }
                        }
                    }
                }
                .padding(22)
            }
        }
    }

    private func header(for entry: LoRAEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if editingCID == entry.cid {
                TextField("Label", text: $editingLabel)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit {
                        Task {
                            await app.setLabel(
                                cid: entry.cid,
                                label: editingLabel.isEmpty ? nil : editingLabel)
                            editingCID = nil
                        }
                    }
            } else {
                Text(entry.displayName)
                    .font(.fleetSerif(17, weight: .light))
                    .foregroundStyle(Color.fleetInk)
                Button {
                    editingCID = entry.cid
                    editingLabel = entry.label ?? ""
                } label: {
                    Image(systemName: "pencil").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.fleetInk.opacity(0.35))
            }

            Spacer()

            Text("gen \(entry.generation)")
                .font(.fleetSans(10))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.fleetGold.opacity(0.15)))
                .foregroundStyle(Color.fleetGold)

            Text(entry.shortCID)
                .font(.fleetMono(10))
                .foregroundStyle(Color.fleetInk.opacity(0.4))
                .textSelection(.enabled)
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel(title)
            Text(value)
                .font(.fleetSans(11))
                .foregroundStyle(Color.fleetInk.opacity(0.7))
        }
    }

    private func count(in group: GroupEntry) -> Int {
        app.loras.filter { app.groupMembership[$0.cid]?.contains(group.label) ?? false }.count
    }

    private func createGroup() {
        let name = newGroupName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        newGroupName = ""
        Task { await app.createGroup(label: name) }
    }
}
