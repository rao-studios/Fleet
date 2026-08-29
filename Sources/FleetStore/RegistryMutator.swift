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
    private var flushTask: Task<Void, Never>?

    /// Seconds to wait after the last write before persisting.
    private let debounceInterval: Duration

    public init(key: String = "registry", debounceSeconds: Double = 1.0) {
        self.persistence = FilePersistence(key: key)
        self.debounceInterval = .milliseconds(Int(debounceSeconds * 1000))
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

    /// Persist immediately, cancelling any pending debounce.
    public func flushNow() {
        flushTask?.cancel()
        flushTask = nil
        persistence.save(state: snapshot)
    }

    /// Flush and stop accepting scheduled writes.
    public func shutdown() {
        flushNow()
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [debounceInterval] in
            try? await Task.sleep(for: debounceInterval)
            guard !Task.isCancelled else { return }
            await self.flushNow()
        }
    }
}
