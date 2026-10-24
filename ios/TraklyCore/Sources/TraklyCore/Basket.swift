import Foundation

/// The composer's basket (docs/specs/phase10-apps-and-stores.md D10, §A1, §B15, §E6): the chosen products of S4 and the
/// shared links waiting for «خواندن», kept in `Application Support/intake-basket.json` for 30 minutes and bound to the
/// account (`config.accountKey`). Another account wipes it; an explicit sign-out wipes it; a forced sign-in of the same
/// account keeps it. Pure (the store does the file; the wall clock is injected, the file outlives the process). The
/// port of Android's `core/Basket.kt`.
public final class Basket {
    /// One chosen product: the `IntakeChoice` JSON (§B6) with a local id, its host and thumbnail for the row.
    public struct Line: Equatable {
        public let id: String
        public var choice: JSONObject
        public let host: String
        public let thumb: String?

        public init(id: String, choice: JSONObject, host: String, thumb: String?) {
            self.id = id
            self.choice = choice
            self.host = host
            self.thumb = thumb
        }

        public var quantity: Int { choice["quantity"]?.intValue ?? 1 }
        public var title: String { choice.string("title") ?? "" }
    }

    /// A link shared to the app, waiting for the user's «خواندن» (F3).
    public struct Shared: Equatable {
        public let url: String
        public let at: Int64

        public init(url: String, at: Int64) {
            self.url = url
            self.at = at
        }
    }

    public struct State: Equatable {
        public var accountKey: String?
        public var savedAt: Int64
        public var lines: [Line]
        public var shared: [Shared]

        public var isEmpty: Bool { lines.isEmpty && shared.isEmpty }
    }

    private let clock: () -> Int64
    public private(set) var state: State

    /// Issued intake ids (single use, 30 min) and the lines each one hands to the order form.
    private var issued: [(id: String, at: Int64, lines: [Line])] = []

    public init(clock: @escaping () -> Int64) {
        self.clock = clock
        state = State(accountKey: nil, savedAt: clock(), lines: [], shared: [])
    }

    /// Restores the file's text; anything older than 30 minutes, or not ours, is dropped.
    public func restore(_ text: String?) {
        state = parse(text) ?? State(accountKey: nil, savedAt: clock(), lines: [], shared: [])
    }

    private func parse(_ text: String?) -> State? {
        guard let text, let body = Json.object(text), let savedAtValue = body.number("savedAt") else { return nil }
        let savedAt = Int64(savedAtValue)
        if clock() - savedAt > Limits.basketMs || savedAt > clock() + 60_000 {
            return nil
        }
        let lines: [Line] = (body.array("lines") ?? []).compactMap { raw in
            guard let line = raw.objectValue, let choice = line.object("choice"), BridgeMessages.isIntakeChoice(.object(choice)), let id = line.string("id") else { return nil }
            return Line(id: id, choice: choice, host: line.string("host") ?? "", thumb: line.string("thumb"))
        }
        let shared: [Shared] = (body.array("shared") ?? []).compactMap { raw in
            guard let item = raw.objectValue, let url = item.string("url") else { return nil }
            return Shared(url: url, at: item.number("at").map { Int64($0) } ?? savedAt)
        }
        return State(accountKey: body.string("accountKey"), savedAt: savedAt, lines: Array(lines.prefix(Limits.basketMax)), shared: Array(shared.prefix(Limits.basketMax)))
    }

    public func toJson() -> String {
        let lines: [JSONValue] = state.lines.map { line in
            .object(JSONObject([("id", .string(line.id)), ("choice", .object(line.choice)), ("host", .string(line.host)), ("thumb", .optional(line.thumb))]))
        }
        let shared: [JSONValue] = state.shared.map { .object(JSONObject([("url", .string($0.url)), ("at", .number(Double($0.at)))])) }
        return Json.write(JSONObject([
            ("v", .int(1)),
            ("accountKey", .optional(state.accountKey)),
            ("savedAt", .number(Double(state.savedAt))),
            ("lines", .array(lines)),
            ("shared", .array(shared)),
        ]))
    }

    /// Drops what is older than 30 minutes (call before reading the basket).
    public func expire() {
        let now = clock()
        if now - state.savedAt > Limits.basketMs {
            state = State(accountKey: state.accountKey, savedAt: now, lines: [], shared: [])
        }
        issued.removeAll { now - $0.at > Limits.intakeIdMs }
    }

    /// The signed-in account (`config.accountKey`, nil when signed out). Another account than the one the basket belongs
    /// to wipes it (answers true: the caller also clears the web's order drafts); nil keeps it (a forced sign-in).
    @discardableResult
    public func account(_ accountKey: String?) -> Bool {
        guard let accountKey else { return false }
        if let owner = state.accountKey, owner != accountKey {
            state = State(accountKey: accountKey, savedAt: clock(), lines: [], shared: [])
            issued.removeAll()
            return true
        }
        if state.accountKey == nil {
            state.accountKey = accountKey
        }
        return false
    }

    /// An explicit sign-out (`session.ended`): everything goes.
    public func signOut() {
        state = State(accountKey: nil, savedAt: clock(), lines: [], shared: [])
        issued.removeAll()
    }

    /// Adds a chosen product; false when the basket is full (20 lines).
    @discardableResult
    public func add(_ line: Line) -> Bool {
        expire()
        if state.lines.count >= Limits.basketMax { return false }
        state.savedAt = clock()
        state.lines.append(line)
        return true
    }

    public func remove(_ id: String) {
        state.savedAt = clock()
        state.lines.removeAll { $0.id == id }
    }

    public func setQuantity(_ id: String, _ quantity: Int) {
        let clamped = min(max(quantity, 1), 999)
        state.savedAt = clock()
        state.lines = state.lines.map { line in
            guard line.id == id else { return line }
            var copy = line
            copy.choice["quantity"] = .int(clamped)
            return copy
        }
    }

    /// A shared link waits for «خواندن» (one per URL; the newest first).
    public func share(_ url: String) {
        expire()
        let others = state.shared.filter { $0.url != url }
        state.savedAt = clock()
        state.shared = Array(([Shared(url: url, at: clock())] + others).prefix(Limits.basketMax))
    }

    public func unshare(_ url: String) {
        state.savedAt = clock()
        state.shared.removeAll { $0.url == url }
    }

    /// Keeps the basket 30 more minutes («نگه داشتن»).
    public func touch() {
        state.savedAt = clock()
    }

    public func clear() {
        state = State(accountKey: state.accountKey, savedAt: clock(), lines: [], shared: [])
    }

    /// «ادامه ثبت سفارش»: a fresh intake id for the current lines (the lines stay until the form takes them).
    @discardableResult
    public func issue(_ id: String) -> String {
        expire()
        issued.removeAll { $0.id == id }
        issued.append((id: id, at: clock(), lines: state.lines))
        return id
    }

    /// The ids an order form may still take (`BridgeMessages.NativeState.intakeIds`).
    public func issuedIds() -> Set<String> {
        expire()
        return Set(issued.map(\.id))
    }

    /// `intake.take`: the lines of an issued id, once; the basket drops them. Nil when unknown, used or expired.
    public func take(_ id: String) -> [Line]? {
        expire()
        guard let index = issued.firstIndex(where: { $0.id == id }) else { return nil }
        let lines = issued.remove(at: index).lines
        let taken = Set(lines.map(\.id))
        state.savedAt = clock()
        state.lines.removeAll { taken.contains($0.id) }
        return lines
    }
}
