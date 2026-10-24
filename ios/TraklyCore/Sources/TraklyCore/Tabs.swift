import Foundation

/// The tab bar (docs/specs/phase10-apps-and-stores.md D12, §B4.1 `tabs`, §E3): four destinations from the newest `tabs`
/// message (kept for the cold start; four default slots before the first one), the «ثبت سفارش» plus button rule and the
/// owner's opt-in centre item. Pure; the port of Android's `core/Tabs.kt` with the iOS symbols.
public enum Tabs {
    public struct Item: Equatable, Sendable {
        public let key: String
        public let label: String
        public let badge: Int?

        public init(key: String, label: String, badge: Int?) {
            self.key = key
            self.label = label
            self.badge = badge
        }
    }

    public struct State: Equatable, Sendable {
        public var items: [Item]
        /// The owner's opt-in centre item «ثبت سفارش» (O-Q5): five slots, no plus button.
        public var create: Bool
        /// «سفارش سریع» is allowed (`orders.create` and the quick-order feature).
        public var quick: Bool
        /// The newest kept order draft of this account (ms epoch), for S4's «ادامه پیش نویس سفارش».
        public var draftAt: Int64?
        /// Whether the state came from a `tabs` message (false: the defaults before the first one).
        public var fromWeb: Bool

        public init(items: [Item], create: Bool, quick: Bool, draftAt: Int64?, fromWeb: Bool) {
            self.items = items
            self.create = create
            self.quick = quick
            self.draftAt = draftAt
            self.fromWeb = fromWeb
        }

        public var keys: [String] { items.map(\.key) }
    }

    /// The root path of each tab (TAB_ROOT_PATHS of nav/appRoutes.ts).
    public static let rootPaths: [(String, String)] = [
        ("home", "/app"),
        ("orders", "/app/orders"),
        ("customers", "/app/customers"),
        ("products", "/app/products"),
        ("payments", "/app/payments"),
        ("more", "/app/more"),
    ]

    public static func rootPath(_ key: String) -> String {
        rootPaths.first { $0.0 == key }?.1 ?? "/app"
    }

    /// The SF Symbol of each tab (§E3) and of the opt-in centre item.
    public static func symbol(_ key: String) -> String {
        switch key {
        case "home": return "house"
        case "orders": return "bag"
        case "customers": return "person.2"
        case "products": return "shippingbox"
        case "payments": return "creditcard"
        case "more": return "square.grid.2x2"
        case create: return "plus.circle.fill"
        default: return "circle"
        }
    }

    /// The copy key of each tab's label before the first `tabs` message.
    public static func copyKey(_ key: String) -> String {
        "tab_" + key
    }

    /// The four slots before the first `tabs` message (labels from the copy at draw time).
    public static let defaults = State(
        items: [Item(key: "home", label: "", badge: nil), Item(key: "orders", label: "", badge: nil), Item(key: "customers", label: "", badge: nil), Item(key: "more", label: "", badge: nil)],
        create: false,
        quick: false,
        draftAt: nil,
        fromWeb: false
    )

    /// The state of a `tabs` message (accepted by `BridgeMessages.checkWebMessage`, so its shape holds).
    public static func of(_ body: JSONObject) -> State {
        let items: [Item] = (body.array("items") ?? []).compactMap { raw in
            guard let item = raw.objectValue, let key = item.string("key") else { return nil }
            return Item(key: key, label: item.string("label") ?? "", badge: item["badge"]?.intValue)
        }
        let draft = body.object("draft")?.number("at").map { Int64($0) }
        return State(items: Array(items.prefix(4)), create: body.bool("create") == true, quick: body.bool("quick") == true, draftAt: draft, fromWeb: true)
    }

    /// The kept form (no session or shop data: keys, labels and the two switches; no badge, no draft).
    public static func toJson(_ state: State) -> String {
        let items: [JSONValue] = state.items.map { .object(JSONObject([("key", .string($0.key)), ("label", .string($0.label)), ("badge", .null)])) }
        return Json.write(JSONObject([("items", .array(items)), ("create", .bool(state.create)), ("quick", .bool(state.quick)), ("draft", .null)]))
    }

    /// A kept state, or the defaults.
    public static func fromJson(_ text: String?) -> State {
        guard let text, let body = Json.object(text), let items = body.array("items"), !items.isEmpty else { return defaults }
        let known = Set(rootPaths.map { $0.0 })
        if items.contains(where: { !known.contains($0.objectValue?.string("key") ?? "") }) {
            return defaults
        }
        var state = of(body)
        state.draftAt = nil
        state.fromWeb = false
        return state
    }

    /// The «ثبت سفارش» plus bar button (D12, §E3): on the Home and Orders roots only, never with the centre item, and
    /// only for an account that sees the Orders tab (the web hides it without the order permissions).
    public static func createOn(_ tab: String?, _ state: State) -> Bool {
        (tab == "home" || tab == "orders") && !state.create && (!state.fromWeb || state.keys.contains("orders"))
    }

    /// The key of the opt-in centre item (never a WebView tab).
    public static let create = "create"

    /// The tab bar's items, in order: the four tabs, with the centre item between the second and third when opted in.
    public static func slots(_ state: State) -> [String] {
        let keys = state.keys
        if !state.create { return keys }
        let middle = (keys.count + 1) / 2
        return Array(keys.prefix(middle)) + [create] + Array(keys.dropFirst(middle))
    }

    /// The tab a pushed page belongs to when the page said none: Home.
    public static func tabOrHome(_ tab: String?, _ state: State) -> String {
        if let tab, state.keys.contains(tab) { return tab }
        return "home"
    }

    /// The badge text: Persian digits, «۹۹+» above 99 (§E3).
    public static func badgeText(_ count: Int) -> String {
        count > 99 ? Fa.digits("99") + "+" : Fa.digits(String(count))
    }
}

/// Persian digits and the number forms of the native copy (§J4, CLAUDE.md: Persian digits in displayed text). Pure.
public enum Fa {
    /// ASCII digits as Persian digits (U+06F0 to U+06F9); everything else unchanged.
    public static func digits(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x30 && scalar.value <= 0x39, let persian = Unicode.Scalar(0x06F0 + scalar.value - 0x30) {
                out.append(persian)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    public static func number(_ value: Int) -> String {
        digits(String(value))
    }

    /// Hours and minutes of a wall-clock time (ms epoch) in the given time zone as «۱۴:۰۵».
    public static func time(_ ms: Int64, zone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        return digits(String(format: "%02d:%02d", hour, minute))
    }

    /// The labels of a list joined with «، », each one isolated (FSI … PDI) so a Latin label keeps its own direction.
    public static func list(_ labels: [String], separator: String = "\u{060C} ") -> String {
        labels.map { "\u{2068}" + $0 + "\u{2069}" }.joined(separator: separator)
    }

    /// A copy text with its `%@` / `%d` placeholders (isolated by the generator) filled in order.
    public static func format(_ template: String, _ values: [String]) -> String {
        var out = ""
        var index = 0
        let scalars = Array(template.unicodeScalars)
        var position = 0
        while position < scalars.count {
            let scalar = scalars[position]
            if scalar == "%", position + 1 < scalars.count {
                var next = position + 1
                // A positional placeholder (%1$@) or a plain one (%@, %d, %s).
                var argument: Int?
                var digitsText = ""
                while next < scalars.count, Url.isAsciiDigit(scalars[next]) {
                    digitsText.unicodeScalars.append(scalars[next])
                    next += 1
                }
                if !digitsText.isEmpty, next < scalars.count, scalars[next] == "$" {
                    argument = Int(digitsText).map { $0 - 1 }
                    next += 1
                } else {
                    next = position + 1
                }
                if next < scalars.count, ["@", "d", "s"].contains(scalars[next]) {
                    let slot = argument ?? index
                    if argument == nil { index += 1 }
                    out += slot >= 0 && slot < values.count ? values[slot] : ""
                    position = next + 1
                    continue
                }
                if next < scalars.count, scalars[next] == "%" {
                    out += "%"
                    position = next + 1
                    continue
                }
            }
            out.unicodeScalars.append(scalar)
            position += 1
        }
        return out
    }
}
