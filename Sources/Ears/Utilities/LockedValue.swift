import Foundation

/// A simple thread-safe wrapper around a value using os_unfair_lock.
final class LockedValue<T> {
    private var _value: T
    private var lock = os_unfair_lock()

    init(_ value: T) {
        self._value = value
    }

    var value: T {
        get {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return _value
        }
        set {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            _value = newValue
        }
    }
}
