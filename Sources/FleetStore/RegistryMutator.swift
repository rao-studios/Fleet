import Foundation

/// Owns the registry: the only thing allowed to mutate it, and the only thing
/// that writes it to disk.
///
/// Two properties matter. Reads are lock-free through ``snapshot`` so the UI can
/// render a list without awaiting an actor. Writes are coalesced: the file is
/// rewritten a second after the last change rather than on every change, since a
/// training run touches the registry repeatedly. Removals and ``shutdown()``
/// flush immediately, because losing a delete is worse than losing an add — a
/// dangling entry with no weights on disk is what the startup sweep exists to
/// clean up, but a resurrected deleted entry would be a surprise.
public actor RegistryMutator {

    private let persistence: FilePersistence
    private let box: ReadWriteValue<FleetRegistry>
    /// The one flush timer. Never cancelled while it sleeps — see `scheduleFlush`.
    private var flushTask: Task<Void, Never>?
    /// The debounce's trailing edge, in `DispatchTime` uptime nanoseconds;
    /// nil when nothing is waiting to be written.
    private var flushDeadline: UInt64?

    /// Nanoseconds to wait after the last write before persisting.
    private let debounceNanos: UInt64

    public init(key: String = "registry", debounceSeconds: Double = 1.0) {
        self.persistence = FilePersistence(key: key)
        self.debounceNanos = UInt64(max(0, debounceSeconds) * 1_000_000_000)
        var loaded: FleetRegistry = persistence.restore() ?? FleetRegistry()
        loaded.normalize()
        self.box = ReadWriteValue(loaded)
    }

    /// A consistent copy of the registry, readable from anywhere without awaiting.
    public nonisolated var snapshot: FleetRegistry {
        box.withReadLock { $0 }
    }

    /// Apply a change and schedule a flush.
    @discardableResult
    public func mutate<R>(_ body: @Sendable (inout FleetRegistry) -> R) -> R {
        let result = box.withWriteLock { body(&$0) }
        scheduleFlush()
        return result
    }

    /// Apply a change and persist before returning.
    @discardableResult
    public func mutateAndFlush<R>(_ body: @Sendable (inout FleetRegistry) -> R) -> R {
        let result = box.withWriteLock { body(&$0) }
        flushNow()
        return result
    }

    /// Persist immediately. A timer still asleep finds nothing pending when
    /// it wakes, and exits on its own.
    public func flushNow() {
        flushDeadline = nil
        persistence.save(state: snapshot)
    }

    /// Flush and stop accepting scheduled writes.
    public func shutdown() {
        flushNow()
    }

    /// Push the write's trailing edge out, and make sure one timer waits for it.
    ///
    /// PIN: NEVER CANCEL A SLEEPING FLUSH. This used to cancel the pending
    /// task and start another on every change, each asleep in the generic
    /// `Task.sleep(for:)`. A train request's burst of writes then aborted the
    /// server a second later in `swift_task_dealloc` ("freed pointer was not
    /// the last allocation") — on every request. One timer now re-arms off a
    /// deadline and sleeps with `Task.sleep(nanoseconds:)`.
    private func scheduleFlush() {
        flushDeadline = DispatchTime.now().uptimeNanoseconds + debounceNanos
        guard flushTask == nil else { return }
        flushTask = Task { await self.runFlushTimer() }
    }

    private func runFlushTimer() async {
        while let deadline = flushDeadline {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline { break }
            do {
                try await Task.sleep(nanoseconds: deadline - now)
            } catch {
                break  // cancelled: write what's pending rather than spin
            }
        }
        flushTask = nil
        guard flushDeadline != nil else { return }  // flushNow() already wrote it
        flushDeadline = nil
        persistence.save(state: snapshot)
    }
}
