import Foundation

/// Time of the app (docs/specs/phase10-apps-and-stores.md §E2 `Clock`, §E10): monotonic milliseconds from
/// `ContinuousClock` for every interval (read loop, rate limits, timeouts), so no system-boot-time API is used; `Date`
/// only for wall-clock expiries of stored files (the basket, the shared links). Tests inject their own.
public protocol AppClock: Sendable {
    /// Monotonic milliseconds (any origin; only differences mean something).
    func nowMs() -> Int64

    /// Wall-clock milliseconds since 1970 (stored expiries).
    func wallMs() -> Int64
}

public struct SystemClock: AppClock {
    private static let origin = ContinuousClock.now

    public init() {}

    public func nowMs() -> Int64 {
        let elapsed = ContinuousClock.now - SystemClock.origin
        let parts = elapsed.components
        return parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
    }

    public func wallMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }
}

/// A clock the tests move by hand.
public final class TestClock: AppClock, @unchecked Sendable {
    private let lock = NSLock()
    private var now: Int64
    private var wall: Int64

    public init(now: Int64 = 1_000_000, wall: Int64 = 1_760_000_000_000) {
        self.now = now
        self.wall = wall
    }

    public func nowMs() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return now
    }

    public func wallMs() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        return wall
    }

    public func set(_ value: Int64) {
        lock.lock()
        wall += value - now
        now = value
        lock.unlock()
    }

    public func advance(_ ms: Int64) {
        lock.lock()
        now += ms
        wall += ms
        lock.unlock()
    }
}
