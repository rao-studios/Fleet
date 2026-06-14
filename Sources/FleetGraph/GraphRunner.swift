import FleetCore
import Foundation

/// Streamed events from a graph run, for live per-stage visualization.
public enum StageEvent: Sendable {
    case started(nodeId: UUID, input: String)
    case chunk(nodeId: UUID, text: String)
    case finished(nodeId: UUID, output: String)
    case final(text: String)
}

/// Executes an ``EnsembleGraph`` in order, threading each node's output into the
/// next node's input and emitting per-stage events.
///
/// Adapter resolution and generation are injected (`resolveAdapter`, `executor`),
/// so the runner itself is MLX-free and unit-testable.
public struct GraphRunner: Sendable {

    let graph: EnsembleGraph
    let executor: any StageExecuting
    let resolveAdapter: @Sendable (UUID) -> URL?
    let maxTokens: Int

    public init(
        graph: EnsembleGraph,
        executor: any StageExecuting,
        maxTokens: Int = 256,
        resolveAdapter: @escaping @Sendable (UUID) -> URL?
    ) {
        self.graph = graph
        self.executor = executor
        self.maxTokens = maxTokens
        self.resolveAdapter = resolveAdapter
    }

    public func run(prompt: String, history: [ChatTurn] = []) -> AsyncThrowingStream<StageEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let order = graph.executionOrder()
                    guard !order.isEmpty else {
                        continuation.finish()
                        return
                    }
                    var current = prompt
                    for node in order {
                        if Task.isCancelled { break }
                        continuation.yield(.started(nodeId: node.id, input: current))
                        let output = try await node.process(
                            input: current,
                            history: history,
                            executor: executor,
                            resolveAdapter: resolveAdapter,
                            maxTokens: maxTokens,
                            emit: { continuation.yield(.chunk(nodeId: node.id, text: $0)) }
                        )
                        continuation.yield(.finished(nodeId: node.id, output: output))
                        current = output
                    }
                    continuation.yield(.final(text: current))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
