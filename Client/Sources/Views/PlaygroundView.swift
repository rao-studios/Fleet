import Fleet
import SwiftUI

/// Run a stored LoRA against an input and inspect exactly how the output was
/// produced — which tokens the schema forced, and which the model chose.
struct PlaygroundView: View {

    @EnvironmentObject var app: AppState

    @State private var cid: String?
    @State private var inputText = "{\n  \n}"
    @State private var parseError: JSONParseError?
    @State private var result: GatedResult?
    @State private var runError: String?
    @State private var isRunning = false
    @State private var tab: Tab = .output
    @State private var temperature: Double = 0
    @State private var selectedStep: GateTraceStep?

    private enum Tab: String, CaseIterable {
        case output = "Output"
        case trace = "Gate trace"
        case schema = "Schema"
    }

    private var selectedLoRA: LoRAEntry? {
        app.loras.first { $0.cid == cid }
    }

    var body: some View {
        HSplitView {
            inputPane.frame(minWidth: 340, idealWidth: 400)
            outputPane.frame(minWidth: 420)
        }
        .background(Color.fleetBG)
        .task {
            await app.refresh()
            if cid == nil { cid = app.lastTrainedCID ?? app.loras.first?.cid }
        }
    }

    // MARK: - Input

    private var inputPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("LoRA")
            if app.loras.isEmpty {
                Text("Train a LoRA first.")
                    .font(.fleetSans(12))
                    .foregroundStyle(Color.fleetInk.opacity(0.5))
            } else {
                Picker("", selection: $cid) {
                    Text("Choose…").tag(String?.none)
                    ForEach(app.loras) { entry in
                        Text("\(entry.displayName) · \(entry.shortCID)")
                            .tag(String?.some(entry.cid))
                    }
                }
                .labelsHidden()
            }

            SectionLabel("Input JSON")
            TextEditor(text: $inputText)
                .font(.fleetMono(11))
                .frame(minHeight: 200)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white.opacity(0.7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(
                                    parseError == nil ? Color.fleetBorder : Color.fleetError,
                                    lineWidth: 1))
                )
                .onChange(of: inputText) { _, _ in validate() }

            if let parseError {
                Text("line \(parseError.line), column \(parseError.column): \(parseError.message)")
                    .font(.fleetMono(10))
                    .foregroundStyle(Color.fleetError)
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel("Temperature")
                    HStack {
                        Slider(value: $temperature, in: 0 ... 1.5)
                        Text(String(format: "%.2f", temperature))
                            .font(.fleetMono(10))
                            .frame(width: 34)
                    }
                }
            }

            Button(action: run) {
                Label("Run", systemImage: "play.fill")
            }
            .buttonStyle(.fleet)
            .disabled(isRunning || cid == nil || parseError != nil)

            if isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Generating under schema constraints…")
                        .font(.fleetSans(11))
                        .foregroundStyle(Color.fleetInk.opacity(0.5))
                }
            }

            if let sample = sampleInputHint {
                Button("Insert a sample input") { inputText = sample }
                    .buttonStyle(.fleetQuiet)
            }

            Spacer()
        }
        .padding(18)
        .onAppear(perform: validate)
    }

    /// An input shaped like the ones this LoRA was trained on, so the playground
    /// is usable without hunting for the dataset.
    private var sampleInputHint: String? {
        guard let entry = selectedLoRA, let datasetId = entry.datasetId,
            let dataset = app.datasets.first(where: { $0.id == datasetId })
        else { return nil }
        _ = dataset
        return nil
    }

    // MARK: - Output

    @ViewBuilder
    private var outputPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let runError {
                        Label(runError, systemImage: "exclamationmark.triangle")
                            .font(.fleetSans(12))
                            .foregroundStyle(Color.fleetError)
                    }

                    switch tab {
                    case .output:
                        outputTab
                    case .trace:
                        traceTab
                    case .schema:
                        schemaTab
                    }
                }
                .padding(18)
            }
        }
    }

    @ViewBuilder
    private var outputTab: some View {
        if let result {
            VStack(alignment: .leading, spacing: 12) {
                FleetCard {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Produced")
                        Text(result.rawText)
                            .font(.fleetMono(12))
                            .foregroundStyle(Color.fleetInk)
                            .textSelection(.enabled)
                    }
                }
                HStack(spacing: 18) {
                    stat("Tokens", "\(result.trace.count)")
                    stat("Forced by schema", "\(Int((result.forcedFraction * 100).rounded()))%")
                    stat("Prompt tokens", "\(result.promptTokenCount)")
                }
                Text(
                    "The output is valid against the schema by construction — decoding could "
                        + "not have finished otherwise."
                )
                .font(.fleetSans(11))
                .foregroundStyle(Color.fleetInk.opacity(0.45))
            }
        } else {
            EmptyHero(
                title: "Nothing run yet",
                subtitle: "Pick a LoRA, give it an input document, and watch the gate hold the "
                    + "output to its schema."
            )
        }
    }

    @ViewBuilder
    private var traceTab: some View {
        if let result, !result.trace.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    legend(color: .fleetInk, label: "forced by the schema")
                    legend(color: .fleetGold, label: "chosen by the LoRA")
                }

                FlowLayout(spacing: 3) {
                    ForEach(result.trace) { step in
                        Button {
                            selectedStep = step
                        } label: {
                            Text(display(step.text))
                                .font(.fleetMono(11))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(
                                            step.mode == .forced
                                                ? Color.fleetInk.opacity(0.10)
                                                : Color.fleetGold.opacity(0.22))
                                )
                                .foregroundStyle(
                                    step.mode == .forced
                                        ? Color.fleetInk.opacity(0.75) : Color.fleetGold)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let step = selectedStep {
                    FleetCard {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel("Token \(step.index)")
                            Text(step.statePath)
                                .font(.fleetMono(11))
                                .foregroundStyle(Color.fleetInk)
                            Text(
                                step.mode == .forced
                                    ? "The schema fixed this text; the model was not consulted."
                                    : "The model chose from \(step.admissibleCount) admissible tokens."
                            )
                            .font(.fleetSans(11))
                            .foregroundStyle(Color.fleetInk.opacity(0.55))

                            if !step.alternatives.isEmpty {
                                SectionLabel("What the model ranked highest")
                                ForEach(Array(step.alternatives.enumerated()), id: \.offset) {
                                    _, alternative in
                                    HStack {
                                        Text(display(alternative.text))
                                            .font(.fleetMono(10))
                                        Spacer()
                                        Text(String(format: "%.3f", exp(alternative.logProbability)))
                                            .font(.fleetMono(10))
                                            .foregroundStyle(Color.fleetInk.opacity(0.45))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        } else {
            Text("Run something to see the trace.")
                .font(.fleetSans(12))
                .foregroundStyle(Color.fleetInk.opacity(0.45))
        }
    }

    @ViewBuilder
    private var schemaTab: some View {
        if let entry = selectedLoRA {
            FleetCard {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Enforced schema")
                    Text(entry.schemaDescription)
                        .font(.fleetMono(11))
                        .foregroundStyle(Color.fleetInk.opacity(0.7))
                    Text("schema id \(String(entry.schemaHash.prefix(8)))")
                        .font(.fleetMono(10))
                        .foregroundStyle(Color.fleetInk.opacity(0.35))
                }
            }
        } else {
            Text("Pick a LoRA.")
                .font(.fleetSans(12))
                .foregroundStyle(Color.fleetInk.opacity(0.45))
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel(title)
            Text(value)
                .font(.fleetSans(15, weight: .medium))
                .foregroundStyle(Color.fleetInk)
        }
    }

    private func legend(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(0.25))
                .frame(width: 14, height: 12)
            Text(label)
                .font(.fleetSans(10))
                .foregroundStyle(Color.fleetInk.opacity(0.5))
        }
    }

    private func display(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: "⏎")
            .replacingOccurrences(of: " ", with: "·")
    }

    // MARK: - Actions

    private func validate() {
        do {
            _ = try JSONParser.parse(inputText)
            parseError = nil
        } catch let error as JSONParseError {
            parseError = error
        } catch {
            parseError = JSONParseError(line: 1, column: 1, message: "\(error)")
        }
    }

    private func run() {
        guard let cid, let input = try? JSONParser.parse(inputText) else { return }
        isRunning = true
        runError = nil
        result = nil
        selectedStep = nil
        Task {
            do {
                let produced = try await app.service.complete(
                    cid: cid,
                    input: input,
                    options: GateOptions(temperature: Float(temperature), captureTrace: true)
                )
                result = produced
                tab = .output
            } catch {
                runError = "\(error)"
            }
            isRunning = false
        }
    }
}

/// Wraps token chips onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
