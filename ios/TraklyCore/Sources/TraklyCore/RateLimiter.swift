import Foundation

/// Sliding-window limits (docs/specs/phase9-phone-capture.md B10 «App reads»; phase 10 §B5): the reader's 10 a minute
/// and 120 an hour, kept through an injected store, and the per-type bridge limits of `BridgeMessages.rateLimits`. A
/// port of Android's `core/RateLimiter.kt` and `Bridge.Rates`. Pure.
/// Where the timestamps of past takes live (the app keeps the reader's in UserDefaults).
public protocol RateLimitStore: AnyObject {
    func load() -> [Int64]
    func save(_ stamps: [Int64])
}

public final class RateLimiter: @unchecked Sendable {
    public typealias Store = RateLimitStore

    public final class MemoryStore: RateLimitStore {
        private var stamps: [Int64] = []

        public init() {}

        public func load() -> [Int64] { stamps }

        public func save(_ stamps: [Int64]) { self.stamps = stamps }
    }

    /// `max` per `windowMs`, every window at once.
    public struct Window: Equatable, Sendable {
        public let max: Int
        public let windowMs: Int64

        public init(max: Int, windowMs: Int64) {
            self.max = max
            self.windowMs = windowMs
        }
    }

    public static let minuteMs: Int64 = 60_000
    public static let hourMs: Int64 = 3_600_000

    /// The reader's windows (phase 8 `LIMITS`).
    public static let readWindows = [Window(max: Limits.readsPerMinute, windowMs: minuteMs), Window(max: Limits.readsPerHour, windowMs: hourMs)]

    private let store: RateLimitStore
    private let clock: () -> Int64
    private let windows: [Window]
    private let lock = NSLock()

    public init(store: RateLimitStore, clock: @escaping () -> Int64, windows: [Window] = RateLimiter.readWindows) {
        self.store = store
        self.clock = clock
        self.windows = windows
    }

    private var longest: Int64 { windows.map(\.windowMs).max() ?? RateLimiter.hourMs }

    /// Records one take and answers true, or answers false (nothing recorded) when a window is full.
    public func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        var stamps = store.load().filter { $0 > now - longest && $0 <= now }.sorted()
        for window in windows where stamps.filter({ $0 > now - window.windowMs }).count >= window.max {
            store.save(stamps)
            return false
        }
        stamps.append(now)
        store.save(stamps)
        return true
    }

    /// Takes left in the tightest window (tests).
    public func remaining() -> Int {
        let now = clock()
        let stamps = store.load().filter { $0 > now - longest && $0 <= now }
        return windows.map { window in window.max - stamps.filter { $0 > now - window.windowMs }.count }.min() ?? 0
    }

    /// Timestamps as one comma-separated string (the stored value); bad entries are dropped.
    public static func encode(_ stamps: [Int64]) -> String {
        stamps.map(String.init).joined(separator: ",")
    }

    public static func decode(_ text: String?) -> [Int64] {
        (text ?? "").split(separator: ",").compactMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
    }
}

/// The native rate limits of the bridge, per message type (§B5), in memory for the process.
public final class BridgeRates: @unchecked Sendable {
    private var limiters: [String: RateLimiter] = [:]
    private let clock: () -> Int64
    private let lock = NSLock()

    public init(clock: @escaping () -> Int64) {
        self.clock = clock
    }

    /// Whether one more `type` may go through now (types without a limit always do).
    public func take(_ type: String) -> Bool {
        guard let windows = BridgeMessages.rateLimits.first(where: { $0.0 == type })?.1 else { return true }
        lock.lock()
        let limiter: RateLimiter
        if let existing = limiters[type] {
            limiter = existing
        } else {
            limiter = RateLimiter(store: RateLimiter.MemoryStore(), clock: clock, windows: windows)
            limiters[type] = limiter
        }
        lock.unlock()
        return limiter.take()
    }

    public func reset() {
        lock.lock()
        limiters.removeAll()
        lock.unlock()
    }
}
