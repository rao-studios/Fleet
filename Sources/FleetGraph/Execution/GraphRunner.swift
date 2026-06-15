import FleetCore
import Foundation

/// Streamed events from a graph run, for live per-stage visualization.
public enum StageEvent: Sendable {
    case started(nodeId: UUID, input: String)
    case chunk(nodeId: UUID, text: String)
    case gated(nodeId: UUID, weights: [UUID: Double])  // Router: member → weight
    case finished(nodeId: UUID, output: String)
    case final(text: String)
}

/// Executes an ``EnsembleGraph`` as a **concurrent DAG**: each node awaits its
/// predecessors, so independent members run concurrently and a Router awaits all
/// of its inputs. Generation, gating, and descriptors are injected, so the runner
/// is MLX-free and unit-testable.
public struct GraphRunner: Sendable {

    let graph: EnsembleGraph
    let executor: any StageExecuting
    let gate: any GateScoring
    let resolveAdapter: @Sendable (UUID) -> URL?
    let describe: @Sendable (GraphNode?) -> String
    let maxTokens: Int

    public init(
        graph: EnsembleGraph,
        executor: any StageExecuting,
        gate: any GateScoring = UniformGate(),
        maxTokens: Int = 256,
        resolveAdapter: @escaping @Sendable (UUID) -> URL? = { _ in nil },
        describe: @escaping @Sendable (GraphNode?) -> String = { $0?.title ?? "" }
    ) {
        self.graph = graph
        self.executor = executor
        self.gate = gate
        self.maxTokens = maxTokens
        self.resolveAdapter = resolveAdapter
        self.describe = describe
    }

    public func run(prompt: String, history: [ChatTurn] = []) -> AsyncThrowingStream<StageEvent, Error> {
        AsyncThrowingStream { continuation in
            let box = TaskBox()
            let parent = Task {
                do {
                    let topo = graph.topologicalOrder()
                    var tasks: [UUID: Task<String, Error>] = [:]

                    for node in topo {
                        let predecessors = graph.predecessors(node.id)
                        let predecessorTasks = predecessors.map { tasks[$0] }
                        let task = makeTask(
                            node: node,
                            predecessors: predecessors,
                            predecessorTasks: predecessorTasks,
                            prompt: prompt,
                            history: history,
                            continuation: continuation)
                        tasks[node.id] = task
                        box.add(task)
                    }

                    if let terminal = graph.terminalNode(), let task = tasks[terminal.id] {
                        let final = try await task.value
                        continuation.yield(.final(text: final))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                parent.cancel()
                box.cancelAll()
            }
        }
    }

    private func makeTask(
        node: GraphNode,
        predecessors: [UUID],
        predecessorTasks: [Task<String, Error>?],
        prompt: String,
        history: [ChatTurn],
        continuation: AsyncThrowingStream<StageEvent, Error>.Continuation
    ) -> Task<String, Error> {
        Task {
            // Await predecessor outputs (they run concurrently).
            var inputs: [StageInput] = []
            for (predecessorId, task) in zip(predecessors, predecessorTasks) {
                guard let task else { continue }
                let text = try await task.value
                inputs.append(
                    StageInput(
                        nodeId: predecessorId,
                        descriptor: describe(graph.node(predecessorId)),
                        text: text))
            }
            try Task.checkCancellation()

            continuation.yield(
                .started(nodeId: node.id, input: inputs.map(\.text).joined(separator: "\n\n")))

            let ctx = NodeRunContext(
                query: prompt,
                inputs: inputs,
                history: history,
                executor: executor,
                gate: gate,
                resolveAdapter: resolveAdapter,
                maxTokens: maxTokens,
                emit: { signal in
                    switch signal {
                    case .chunk(let text):
                        continuation.yield(.chunk(nodeId: node.id, text: text))
                    case .gated(let weights):
                        continuation.yield(.gated(nodeId: node.id, weights: weights))
                    }
                })

            let output = try await node.process(ctx)
            continuation.yield(.finished(nodeId: node.id, output: output))
            return output
        }
    }
}

/// Collects the run's child tasks so they can be cancelled on stream termination.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<String, Error>] = []
    func add(_ task: Task<String, Error>) {
        lock.lock(); defer { lock.unlock() }
        tasks.append(task)
    }
    func cancelAll() {
        lock.lock(); defer { lock.unlock() }
        tasks.forEach { $0.cancel() }
    }
}
