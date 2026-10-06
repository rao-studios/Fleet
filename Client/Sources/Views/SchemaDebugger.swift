import Fleet
import SwiftUI

/// Renders an extracted schema as an indented tree.
///
/// This is the answer to "what did Fleet decide my outputs look like?" — the
/// single most useful thing to see before training, because everything the gate
/// later forces comes from here.
struct SchemaTreeView: View {
    let schema: SchemaTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SchemaNodeRow(name: nil, node: schema.root, depth: 0)
        }
        .font(.fleetMono(11))
    }
}

private struct SchemaNodeRow: View {
    let name: String?
    let node: SchemaNode
    let depth: Int

    var body: some View {
        switch node {
        case .object(let entries):
            row(typeText: "object", detail: "\(entries.count) key\(entries.count == 1 ? "" : "s")")
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                SchemaNodeRow(name: entry.key, node: entry.node, depth: depth + 1)
            }

        case .array(let element, let minCount, let maxCount):
            let range = minCount == maxCount ? "\(minCount)" : "\(minCount)–\(maxCount)"
            row(typeText: "array", detail: "\(range) seen · length is free")
            SchemaNodeRow(name: nil, node: element, depth: depth + 1)

        case .string, .number, .bool, .null:
            row(typeText: node.typeName, detail: nil)
        }
    }

    private func row(typeText: String, detail: String?) -> some View {
        HStack(spacing: 6) {
            if depth > 0 {
                Rectangle()
                    .fill(Color.fleetBorder)
                    .frame(width: 1)
                    .padding(.leading, CGFloat(depth - 1) * 14)
            }
            if let name {
                Text(name)
                    .foregroundStyle(Color.fleetInk)
            } else if depth > 0 {
                Text("item")
                    .foregroundStyle(Color.fleetInk.opacity(0.45))
                    .italic()
            }
            Text(typeText)
                .foregroundStyle(Color.fleetGold)
            if let detail {
                Text(detail)
                    .font(.fleetSans(10))
                    .foregroundStyle(Color.fleetInk.opacity(0.4))
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, depth > 0 ? 4 : 0)
    }
}

/// The full validation panel: schema preview, problems, warnings, and what a
/// training run would overwrite.
struct ValidationPanel: View {
    let report: ValidationReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                StatusDot(color: report.isTrainable ? .fleetGreen : .fleetError)
                Text(report.isTrainable ? "Ready to train" : "Needs attention")
                    .font(.fleetSans(13, weight: .medium))
                    .foregroundStyle(Color.fleetInk)
                Spacer()
                Text("\(report.pairCount) pairs")
                    .font(.fleetSans(11))
                    .foregroundStyle(Color.fleetInk.opacity(0.45))
            }

            if let schema = report.schema {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Extracted schema")
                    SchemaTreeView(schema: schema)
                    Text("schema id \(String(schema.hashHex.prefix(8)))")
                        .font(.fleetMono(10))
                        .foregroundStyle(Color.fleetInk.opacity(0.35))
                }
            }

            if let cid = report.inputCID {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel("Content id")
                    Text(cid)
                        .font(.fleetMono(10))
                        .foregroundStyle(Color.fleetInk.opacity(0.6))
                        .textSelection(.enabled)
                    if let generation = report.existingGeneration {
                        Label(
                            "A LoRA already lives here (generation \(generation)). "
                                + "Training replaces it — same inputs, new outcomes.",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .font(.fleetSans(11))
                        .foregroundStyle(Color.fleetGold)
                    } else {
                        Text("Derived from the inputs only, so retraining lands here again.")
                            .font(.fleetSans(11))
                            .foregroundStyle(Color.fleetInk.opacity(0.4))
                    }
                }
            }

            if !report.fileProblems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Files that would not parse")
                    ForEach(report.fileProblems) { problem in
                        HStack(alignment: .top, spacing: 6) {
                            Text("✗").foregroundStyle(Color.fleetError)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(problem.role.rawValue)[\(problem.index)] \(problem.fileName)")
                                    .font(.fleetMono(11))
                                Text(problem.message)
                                    .font(.fleetSans(11))
                                    .foregroundStyle(Color.fleetInk.opacity(0.55))
                            }
                        }
                    }
                }
            }

            if !report.schemaErrors.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Outputs that disagree")
                    Text(
                        "Every output must have the same keys and value types — that shared "
                            + "shape is what the gate enforces."
                    )
                    .font(.fleetSans(11))
                    .foregroundStyle(Color.fleetInk.opacity(0.45))
                    ForEach(Array(report.schemaErrors.enumerated()), id: \.offset) { _, error in
                        HStack(alignment: .top, spacing: 6) {
                            Text("✗").foregroundStyle(Color.fleetError)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("output[\(error.outputIndex)] \(error.path)")
                                    .font(.fleetMono(11))
                                Text(
                                    "expected \(error.expected) (from output "
                                        + "\(error.referenceIndex)), found \(error.found)"
                                )
                                .font(.fleetSans(11))
                                .foregroundStyle(Color.fleetInk.opacity(0.55))
                            }
                        }
                    }
                }
            }

            ForEach(Array(report.warnings.enumerated()), id: \.offset) { _, warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.fleetSans(11))
                    .foregroundStyle(Color.fleetGold)
            }
        }
    }
}
