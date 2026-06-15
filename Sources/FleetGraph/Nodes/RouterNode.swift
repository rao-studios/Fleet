import Foundation

/// Fan-in node that gates its wired expert members and combines them — a
/// query-level MoE analog.
///
/// `process` is a four-step orchestration; each step is a separate, swappable piece:
/// 1. **gate** → weight each member (`gateKind`: `.embedding` uses the injected
///    `GateScoring`, `.none` is uniform — see `Routing/GateScoring.swift`),
/// 2. **emit** the weights for the UI,
/// 3. **select** the top-`k` by weight,
/// 4. **combine** them (`combineKind` → a ``CombineStrategy`` in
///    `Routing/CombineStrategy.swift`).
///
/// To change *how routing decides* edit the gate; to change *how outputs fuse*
/// add a `CombineStrategy`. The router itself stays the same.
public final class RouterNode: GraphNode {
    public override class var nodeKind: NodeKind { .router }

    public var gateKind: GateKind
    public var topK: Int  // 0 = keep all
    public var combineKind: CombineKind
    public var adapterId: UUID?  // optional, for the synthesize combine
    public var operationKind: OperationKind  // operation for the synthesize combine

    public init(
        position: GraphPoint,
        gateKind: GateKind = .embedding,
        topK: Int = 0,
        combineKind: CombineKind = .synthesize,
        adapterId: UUID? = nil,
        operationKind: OperationKind = .answer
    ) {
        self.gateKind = gateKind
        self.topK = topK
        self.combineKind = combineKind
        self.adapterId = adapterId
        self.operationKind = operationKind
        super.init(id: UUID(), title: "Router", position: position)
    }

    private enum Keys: String, CodingKey {
        case gateKind, topK, combineKind, adapterId, operationKind
    }

    public required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        gateKind = try c.decodeIfPresent(GateKind.self, forKey: .gateKind) ?? .embedding
        topK = try c.decodeIfPresent(Int.self, forKey: .topK) ?? 0
        combineKind = try c.decodeIfPresent(CombineKind.self, forKey: .combineKind) ?? .synthesize
        adapterId = try c.decodeIfPresent(UUID.self, forKey: .adapterId)
        operationKind = try c.decodeIfPresent(OperationKind.self, forKey: .operationKind) ?? .answer
        try super.init(from: decoder)
    }

    public override func encode(to encoder: Encoder) throws {
        try super.encode(to: encoder)
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(gateKind, forKey: .gateKind)
        try c.encode(topK, forKey: .topK)
        try c.encode(combineKind, forKey: .combineKind)
        try c.encodeIfPresent(adapterId, forKey: .adapterId)
        try c.encode(operationKind, forKey: .operationKind)
    }

    public override func process(_ ctx: NodeRunContext) async throws -> String {
        let members = ctx.inputs
        guard !members.isEmpty else { return "" }

        // 1. Gate → 2. emit weights.
        let weights = try await gateWeights(for: members, in: ctx)
        ctx.emit(.gated(Dictionary(uniqueKeysWithValues: zip(members.map(\.nodeId), weights))))

        // 3. Select top-k by weight.
        let selected = topKMembers(members, weights: weights)

        // 4. Combine the selected experts.
        let strategy = combineKind.makeStrategy(
            adapterDirectory: adapterId.flatMap { ctx.resolveAdapter($0) },
            operationKind: operationKind)
        return try await strategy.combine(selected, in: ctx)
    }

    /// Gate weights for the members (the routing geometry).
    private func gateWeights(for members: [StageInput], in ctx: NodeRunContext) async throws -> [Double] {
        switch gateKind {
        case .embedding:
            return try await ctx.gate.score(query: ctx.query, experts: members.map(\.descriptor))
        case .none:
            return Array(repeating: 1.0, count: members.count)
        }
    }

    /// Highest-weighted `topK` members (0 = keep all), as `WeightedMember`s.
    private func topKMembers(_ members: [StageInput], weights: [Double]) -> [WeightedMember] {
        let k = topK <= 0 ? members.count : min(topK, members.count)
        return zip(members, weights)
            .sorted { $0.1 > $1.1 }
            .prefix(k)
            .map { WeightedMember(input: $0.0, weight: $0.1) }
    }
}
