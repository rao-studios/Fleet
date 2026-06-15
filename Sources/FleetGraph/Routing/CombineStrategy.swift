import FleetCore
import Foundation

/// How a Router fuses its selected (top-k, weighted) experts into one output.
public enum CombineKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case merge
    case synthesize
    public var id: String { rawValue }

    /// Build the strategy for this kind. `RouterNode` calls this — adding a new
    /// combine mode is a new `CombineKind` case + a new ``CombineStrategy`` type,
    /// and the router body doesn't change (open/closed).
    public func makeStrategy(adapterDirectory: URL?, operationKind: OperationKind) -> CombineStrategy {
        switch self {
        case .merge:
            return MergeStrategy()
        case .synthesize:
            return SynthesizeStrategy(adapterDirectory: adapterDirectory, operationKind: operationKind)
        }
    }
}

/// One expert's output plus its gate weight, ready to be fused.
public struct WeightedMember: Sendable {
    public let input: StageInput
    public let weight: Double
    public init(input: StageInput, weight: Double) {
        self.input = input
        self.weight = weight
    }
}

/// Fuses the Router's selected experts into a single output. Implement this to add
/// a new fusion mode — the Router orchestrates, the strategy decides the geometry.
public protocol CombineStrategy: Sendable {
    func combine(_ members: [WeightedMember], in ctx: NodeRunContext) async throws -> String
}

/// Concatenate the experts as a weighted, labeled block (no generation). A "compile"
/// pass that prepares one input for a downstream node or the output.
public struct MergeStrategy: CombineStrategy {
    public init() {}
    public func combine(_ members: [WeightedMember], in ctx: NodeRunContext) async throws -> String {
        members.map { member in
            "— \(member.input.descriptor) (w=\(Self.format(member.weight))) —\n\(member.input.text)"
        }.joined(separator: "\n\n")
    }

    static func format(_ value: Double) -> String { String(format: "%.2f", value) }
}

/// Run one generation that reconciles the weighted experts into a single answer,
/// favoring higher-weighted ones. Optionally conditioned by its own adapter/operation.
public struct SynthesizeStrategy: CombineStrategy {
    public let adapterDirectory: URL?
    public let operationKind: OperationKind

    public init(adapterDirectory: URL?, operationKind: OperationKind) {
        self.adapterDirectory = adapterDirectory
        self.operationKind = operationKind
    }

    public func combine(_ members: [WeightedMember], in ctx: NodeRunContext) async throws -> String {
        let body = members.enumerated().map { index, member in
            "Expert \(index + 1) — \(member.input.descriptor) "
                + "(relevance \(MergeStrategy.format(member.weight))):\n\(member.input.text)"
        }.joined(separator: "\n\n")

        let prompt = """
            You are given expert responses with relevance weights. Produce one reconciled \
            answer to the user's query, favoring higher-weighted experts.

            Query: \(ctx.query)

            \(body)
            """
        let operation = NodeOperation.make(operationKind, custom: "{input}")
        let messages = operation.messages(for: prompt, history: ctx.history)
        return try await ctx.stream(adapterDirectory: adapterDirectory, messages: messages)
    }
}
