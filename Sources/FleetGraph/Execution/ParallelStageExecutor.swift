import FleetCore
import Foundation

/// Runs stages across a pool of independent ``StageExecuting`` lanes so concurrent
/// members (e.g. the LoRA experts feeding a Router) generate **truly in parallel**.
///
/// Each lane is its own model instance — you can't apply two adapters to one
/// model's weights at once, so genuine parallelism needs separate models. This
/// actor routes each `run` call to a free lane (waiting if all are busy), capping
/// concurrency at `lanes.count`. With a single lane it is strictly serialized.
///
/// Pure concurrency control — MLX-free, so it's unit-testable with fake lanes.
public actor ParallelStageExecutor: StageExecuting {

    private let lanes: [any StageExecuting]
    private var free: [Int]
    private var waiters: [CheckedContinuation<Int, Never>] = []

    public init(lanes: [any StageExecuting]) {
        precondition(!lanes.isEmpty, "ParallelStageExecutor needs at least one lane")
        self.lanes = lanes
        self.free = Array(lanes.indices)
    }

    public nonisolated func run(
        adapterDirectory: URL?,
        history: [ChatTurn],
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await dispatch(
                        adapterDirectory: adapterDirectory, history: history,
                        maxTokens: maxTokens, into: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Acquire a lane, forward the stage to it, release the lane on completion.
    /// Actor reentrancy at the streaming `await` lets several dispatches each hold
    /// a different lane at once.
    private func dispatch(
        adapterDirectory: URL?,
        history: [ChatTurn],
        maxTokens: Int,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let lane = await acquire()
        do {
            for try await chunk in lanes[lane].run(
                adapterDirectory: adapterDirectory, history: history, maxTokens: maxTokens)
            {
                continuation.yield(chunk)
            }
            release(lane)
            continuation.finish()
        } catch {
            release(lane)
            throw error
        }
    }

    private func acquire() async -> Int {
        if let lane = free.popLast() { return lane }
        return await withCheckedContinuation { waiters.append($0) }
    }

    private func release(_ lane: Int) {
        if !waiters.isEmpty {
            waiters.removeFirst().resume(returning: lane)
        } else {
            free.append(lane)
        }
    }
}
