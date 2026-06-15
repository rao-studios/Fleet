import Foundation

/// Which gate a Router uses to weight its experts.
public enum GateKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case none  // uniform weights
    case embedding  // query↔descriptor similarity via the injected GateScoring
    public var id: String { rawValue }
}

/// Scores LoRA "experts" for a query — the Router's gate (the combination
/// geometry). Returns one weight per expert descriptor, same order.
///
/// MLX-free protocol; the real embedding gate lives in `FleetInference`. Tests
/// inject a deterministic fake. Add a new gating mechanism by implementing this.
public protocol GateScoring: Sendable {
    func score(query: String, experts: [String]) async throws -> [Double]
}

/// Equal weight to every expert — used when a Router's gate is `.none`, or as a
/// default when no gate is injected.
public struct UniformGate: GateScoring {
    public init() {}
    public func score(query: String, experts: [String]) async throws -> [Double] {
        guard !experts.isEmpty else { return [] }
        return Array(repeating: 1.0 / Double(experts.count), count: experts.count)
    }
}
