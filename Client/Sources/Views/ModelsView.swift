import SwiftUI

struct ModelsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var newModelId = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            FleetCard {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Add a HuggingFace MLX model")
                    HStack {
                        TextField("e.g. mlx-community/Qwen3-0.6B-4bit", text: $newModelId)
                            .textFieldStyle(.plain)
                            .font(.fleetMono(12))
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.fleetFill))
                        Button("Add") {
                            appState.addModel(newModelId)
                            newModelId = ""
                        }
                        .buttonStyle(.fleetQuiet)
                        .disabled(newModelId.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }

            SectionLabel("Models")
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(appState.knownModels, id: \.self) { model in
                        modelRow(model)
                    }
                }
            }

            if let error = appState.modelError {
                Text(error)
                    .font(.fleetMono(10))
                    .foregroundStyle(Color.fleetError)
                    .lineLimit(3)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Models")
                .font(.fleetSerif(26, weight: .light, italic: true))
                .foregroundStyle(Color.fleetInk)
            Text("Download and select the base model to fine-tune.")
                .font(.fleetSans(12))
                .foregroundStyle(Color.fleetInk.opacity(0.5))
        }
    }

    private func modelRow(_ model: String) -> some View {
        FleetCard(padding: 14) {
            HStack(spacing: 12) {
                Button {
                    appState.activeModelId = model
                } label: {
                    Image(systemName: appState.activeModelId == model ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(appState.activeModelId == model ? Color.fleetGold : Color.fleetInk.opacity(0.3))
                }
                .buttonStyle(.plain)
                .help("Set as active base model")

                VStack(alignment: .leading, spacing: 2) {
                    Text(model)
                        .font(.fleetMono(11.5))
                        .foregroundStyle(Color.fleetInk)
                    if appState.activeModelId == model {
                        Text("active base model")
                            .font(.fleetSans(9, weight: .medium))
                            .foregroundStyle(Color.fleetGold)
                    }
                }

                Spacer()

                if appState.warmingModelId == model {
                    HStack(spacing: 8) {
                        ProgressView(value: appState.warmProgress)
                            .frame(width: 90)
                        Text(appState.warmStatus)
                            .font(.fleetMono(9))
                            .foregroundStyle(Color.fleetInk.opacity(0.5))
                    }
                } else {
                    Button("Download & warm") {
                        Task { await appState.warmModel(model) }
                    }
                    .buttonStyle(.fleetQuiet)
                    .disabled(appState.warmingModelId != nil)

                    Button {
                        appState.removeModel(model)
                    } label: {
                        Image(systemName: "trash").foregroundStyle(Color.fleetInk.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
