import Foundation

/// Serializes all disk I/O for a single file through Swift's actor model.
///
/// Ported from Totem's `PersistenceActor`: `FilePersistence.save` is not
/// thread-safe, so wrapping it in an actor guarantees serial execution per file
/// without blocking any thread. One actor per logical file.
public actor PersistenceActor {
    private let persistence: FilePersistence

    public init(persistence: FilePersistence) {
        self.persistence = persistence
    }

    public func save<T: Codable>(_ value: T) {
        persistence.save(state: value)
    }

    public func restore<T: Codable>() -> T? {
        persistence.restore()
    }

    public func purge() {
        persistence.purge()
    }
}
