import Foundation

/// Generic read-through cache with lock-protected synchronous reads and
/// off-actor, race-safe disk persistence.
///
/// Ported from Totem's `TotemCache`: a `ReadWriteValue` snapshot for concurrent
/// reads plus a per-file ``PersistenceActor`` so concurrent saves never race on
/// the backing file. Used for hot, frequently-read values (e.g. the fleet-db
/// indices).
public final class FleetCache<Value: Codable & Sendable>: @unchecked Sendable {
    private let store: ReadWriteValue<Value?>
    private let persistence: FilePersistence
    private let io: PersistenceActor

    public init(persistence: FilePersistence) {
        self.store = ReadWriteValue<Value?>(nil)
        self.persistence = persistence
        self.io = PersistenceActor(persistence: persistence)
    }

    /// Synchronous, concurrent-read snapshot. `nil` until seeded/loaded.
    public var snapshot: Value? { store.withReadLock { $0 } }

    public func seed(_ value: Value) {
        store.withWriteLock { $0 = value }
    }

    public func update(_ value: Value) {
        store.withWriteLock { $0 = value }
    }

    /// Fire-and-forget serialized disk write.
    public func saveAsync(_ value: Value) {
        Task.detached { [io] in await io.save(value) }
    }

    /// Awaited serialized disk write (use at shutdown).
    public func saveNow(_ value: Value) async {
        await io.save(value)
    }

    /// Returns the cached value, otherwise loads from disk (suspending), caches and returns.
    public func load(makeDefault: @Sendable () -> Value) async -> Value {
        if let hit = store.withReadLock({ $0 }) { return hit }
        let restored: Value? = await io.restore()
        let loaded = restored ?? makeDefault()
        return store.withWriteLock {
            if $0 == nil { $0 = loaded }
            return $0!
        }
    }

    /// Seeds synchronously from disk — call once at startup before any async context.
    @discardableResult
    public func seedFromDisk(makeDefault: () -> Value) -> Value {
        let restored: Value? = persistence.restore()
        let initial = restored ?? makeDefault()
        store.withWriteLock { $0 = initial }
        return initial
    }
}
