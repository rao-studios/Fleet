import FleetCore
import Foundation

/// One predecessor's output, tagged with the expert descriptor used by the gate.
public struct StageInput: Sendable {
    public let nodeId: UUID
    public let descriptor: String
    public let text: String
    public init(nodeId: UUID, descriptor: String, text: String) {
        self.nodeId = nodeId
        self.descriptor = descriptor
        self.text = text
    }
}

/// Signals a node streams while processing.
public enum StageSignal: Sendable {
    case chunk(String)
    case gated([UUID: Double])  // member nodeId → gate weight (Router)
}

/// Everything a node needs to process one run: the query, its predecessor inputs,
/// and the injected generation/gating machinery.
public struct NodeRunContext: Sendable {
    public let query: String
    public let inputs: [StageInput]
    public let history: [ChatTurn]
    public let executor: any StageExecuting
    public let gate: any GateScoring
    public let resolveAdapter: @Sendable (UUID) -> URL?
    public let maxTokens: Int
    public let emit: @Sendable (StageSignal) -> Void

    public init(
        query: String,
        inputs: [StageInput],
        history: [ChatTurn],
        executor: any StageExecuting,
        gate: any GateScoring,
        resolveAdapter: @escaping @Sendable (UUID) -> URL?,
        maxTokens: Int,
        emit: @escaping @Sendable (StageSignal) -> Void
    ) {
        self.query = query
        self.inputs = inputs
        self.history = history
        self.executor = executor
        self.gate = gate
        self.resolveAdapter = resolveAdapter
        self.maxTokens = maxTokens
        self.emit = emit
    }

    /// The single upstream text (for non-fan-in nodes): the lone input, all inputs
    /// joined, or the query if this is the entry node.
    public var primaryInput: String {
        if inputs.isEmpty { return query }
        if inputs.count == 1 { return inputs[0].text }
        return inputs.map(\.text).joined(separator: "\n\n")
    }

    /// Run a generation stage through the injected executor, accumulating and
    /// streaming the output. The one place nodes/strategies touch the model.
    public func stream(adapterDirectory: URL?, messages: [ChatTurn]) async throws -> String {
        var output = ""
        for try await chunk in executor.run(
            adapterDirectory: adapterDirectory, history: messages, maxTokens: maxTokens)
        {
            output += chunk
            emit(.chunk(chunk))
        }
        return output
    }
}
