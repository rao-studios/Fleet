import Foundation

/// A cross-platform, thread-safe wrapper that protects a value with a POSIX
/// reader-writer lock (`pthread_rwlock_t`).
///
/// Ported from Totem's `ReadWriteValue`: concurrent reads, exclusive writes —
/// the right primitive for values read far more often than written. Available on
/// both Apple platforms and Linux via swift-corelibs-foundation.
public final class ReadWriteValue<T>: @unchecked Sendable {
    private var lock = pthread_rwlock_t()
    private var value: T

    public init(_ value: T) {
        self.value = value
        pthread_rwlock_init(&lock, nil)
    }

    deinit {
        pthread_rwlock_destroy(&lock)
    }

    /// Acquires a **shared** read lock. Multiple callers may hold this simultaneously.
    @discardableResult
    public func withReadLock<R>(_ body: (T) -> R) -> R {
        pthread_rwlock_rdlock(&lock)
        defer { pthread_rwlock_unlock(&lock) }
        return body(value)
    }

    /// Acquires an **exclusive** write lock.
    @discardableResult
    public func withWriteLock<R>(_ body: (inout T) -> R) -> R {
        pthread_rwlock_wrlock(&lock)
        defer { pthread_rwlock_unlock(&lock) }
        return body(&value)
    }
}
