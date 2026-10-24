import Foundation

/// TraklyNative bridge v1 (TNB/1), the native side's parser and guards (docs/specs/phase10-apps-and-stores.md D7,
/// §B2–§B6, §E7): a port of `erp/resources/js/lib/native/messages.ts` and Android's `core/bridge/Messages.kt`. Pure (the
/// strict `Json` reader, never reflection), so `BridgeMessagesTests` runs every case of
/// `shared/fixtures/bridge-cases.json` and compares the table with `shared/contracts/bridge.json`;
/// `node shared/app/contract.check.mjs` reads the two type lists between the `bridge-types` markers below.
///
/// - `checkWebMessage`: what native does with a string a panel page posted (§B2 guards, §B3 envelope and schema, §B5
///   feature, path and URL rules);
/// - `admitWebMessage`: the capability checks that need native state (issued ids and refs, the native confirmation);
/// - `checkNativeSend`: whether native may send a request or an event to a WebView (§B5 last rows);
/// - `isPageReply`: the page's replies native accepts.
public enum BridgeMessages {
    /// `v` of every message (D33).
    public static let version = 1

    /// The only origin a release build talks to (§B2; a Debug build passes its own as `trusted`).
    public static let origin = "https://erp.trakly.info"

    private static let kib = 1024
    private static let mib = 1024 * 1024

    /// The numbers of §B3, §B5 and §B15 the bridge enforces or waits for (`limits` of bridge.json).
    public enum Limit {
        public static let defaultMaxBytes = 64 * 1024
        public static let absoluteMaxBytes = 14 * 1024 * 1024
        public static let urlChars = 2048
        public static let lineKeyChars = 64
        public static let pageTitleChars = 120
        public static let choiceTitleChars = 190
        public static let labelChars = 60
        public static let tabLabelChars = 40
        public static let tabsMax = 4
        public static let quantityMin = 1
        public static let quantityMax = 999
        public static let basketMax = 20
        public static let fileNameChars = 255
        public static let fileSaveDecodedBytes = 10 * 1024 * 1024
        public static let shareTextChars = 4000
        public static let scanFormatsMax = 16
        public static let helloTimeoutMs = 1000
        public static let backReplyMs = 500
        public static let requestTimeoutMs = 15_000
        public static let intakeFetchTimeoutMs = 35_000
        public static let hostWaitMs = 10_000
        public static let intakeIdMinutes = 30
        public static let refMinutes = 30
        public static let pendingChoiceMinutes = 15
    }

    public static let idPattern = "^[A-Za-z0-9_-]{8,40}$"
    public static let tokenPattern = "^[A-Za-z0-9_-]{22}$"
    public static let accountKeyPattern = "^[0-9a-f]{32}$"
    public static let orderFormPathPattern = "^/app/orders/(create|quick|\\d+/edit)$"
    public static let printPathPattern = "^/app/(?:[a-z0-9-]+/)*print(?:/(?:invoices|labels))?$"
    public static let moreProfilePaths = ["/app/more", "/app/profile"]
    public static let panelPaths = ["/", "/app", "/app/*", "/login", "/login/*", "/logout", "/join"]

    public static let fileSaveMimes = [
        "text/csv",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/pdf",
        "image/png",
        "image/jpeg",
        "text/plain",
    ]

    /// Caps of native's replies that differ from the default (§B3), by the web request type.
    public static let nativeReplyMaxBytes: [String: Int] = ["intake.take": 4 * 1024 * 1024, "product.image": 6 * 1024 * 1024]

    /// Caps of the page's replies that differ from the default (§B3), by the native request type.
    public static let pageReplyMaxBytes: [String: Int] = ["intake.fetch": 1024 * 1024]

    /// Native rate limits (§B5): `max` per `windowMs` for each type; `reader` = the reader launches.
    public static let rateLimits: [(String, [RateLimiter.Window])] = [
        ("intake.fetch", [RateLimiter.Window(max: 20, windowMs: 60_000)]),
        ("product.image", [RateLimiter.Window(max: 40, windowMs: 600_000)]),
        ("print", [RateLimiter.Window(max: 10, windowMs: 60_000)]),
        ("download", [RateLimiter.Window(max: 10, windowMs: 60_000)]),
        ("compose", [RateLimiter.Window(max: 10, windowMs: 60_000)]),
        ("file.save", [RateLimiter.Window(max: 10, windowMs: 60_000)]),
        ("open.external", [RateLimiter.Window(max: 20, windowMs: 60_000)]),
        ("share", [RateLimiter.Window(max: 10, windowMs: 60_000)]),
        ("scan", [RateLimiter.Window(max: 10, windowMs: 60_000)]),
        ("reader", [RateLimiter.Window(max: 10, windowMs: 60_000), RateLimiter.Window(max: 120, windowMs: 3_600_000)]),
    ]

    public static let nativeFeatures = ["chrome", "intake", "reader", "scan", "print", "share", "download", "file.save", "lock", "shareEntry", "clipboard"]

    /// A WebView tab (the opt-in centre item `create` is never one, §B4.1).
    public static let tabKeys = ["home", "orders", "customers", "products", "payments", "more"]

    public static let errors = ["unsupported", "invalid", "denied", "rate", "busy", "cancelled", "failed", "gone", "not_allowed", "unavailable"]

    public static let actionIcons = ["plus", "filter", "share", "print"]

    /// Why the page could not answer `intake.fetch` (§B4.2).
    public static let fetchReasons = ["invalid", "blocked", "unreachable", "not_product", "session", "permission", "network", "rate"]

    // The two type lists, read by shared/app/contract.check.mjs (they must equal bridge.json and messages.ts).
    // bridge-types:web
    public static let webTypes = [
        "hello", "config", "ready", "page", "title", "tabs", "compose", "route", "haptic", "intake.line", "intake.take",
        "intake.pending", "product.image", "modal.close", "download", "file.save", "print", "share", "open.external",
        "scan", "appearance.set", "lock.set", "shopdata.clear", "session.ended",
    ]
    // bridge-types:end

    // bridge-types:native
    public static let nativeTypes = [
        "back", "intake.fetch", "intake.offer", "insets", "visit", "tab", "refresh", "search", "action", "appearance", "appState",
    ]
    // bridge-types:end

    public enum Kind: String, Sendable {
        case request, notify, event
    }

    /// One row of the type table (= bridge.json `types`).
    public struct Spec: Sendable {
        public let dir: String
        public let kind: Kind
        public let maxBytes: Int
        public let path: String?
        public let feature: String?
        public let fields: [(String, String)]
    }

    private static func web(_ kind: Kind, path: String? = nil, feature: String? = nil, maxBytes: Int = Limit.defaultMaxBytes, _ fields: [(String, String)] = []) -> Spec {
        Spec(dir: "web", kind: kind, maxBytes: maxBytes, path: path, feature: feature, fields: fields)
    }

    private static func native(_ kind: Kind, path: String? = nil, feature: String? = nil, maxBytes: Int = Limit.defaultMaxBytes, _ fields: [(String, String)] = []) -> Spec {
        Spec(dir: "native", kind: kind, maxBytes: maxBytes, path: path, feature: feature, fields: fields)
    }

    /// The type table, in the order of bridge.json (FIELD GRAMMAR of messages.ts).
    public static let specs: [(String, Spec)] = [
        ("hello", web(.request, [("path", "path")])),
        ("config", web(.notify, [
            ("topology", "enum(stacks|single)"),
            ("disabled", "[feature](0..11)"),
            ("min", "int(0..999999999)"),
            ("storeUrl", "https|null"),
            ("accountKey", "accountKey|null"),
        ])),
        ("ready", web(.notify)),
        ("page", web(.notify, feature: "chrome", [
            ("context", "enum(auth|tab|push|modal|standalone)"),
            ("tab", "tab|null"),
            ("title", "str(0..120)"),
            ("titleVisible", "bool"),
            ("back", "back|null"),
            ("refreshable", "bool"),
            ("dirty", "bool"),
            ("overlay", "bool"),
            ("search", "bool"),
            ("action", "action|null"),
            ("tone", "enum(night|day)"),
        ])),
        ("title", web(.notify, feature: "chrome", [("visible", "bool")])),
        ("tabs", web(.notify, feature: "chrome", [("items", "[tabItem](1..4)"), ("create", "bool"), ("quick", "bool"), ("draft", "draft|null")])),
        ("compose", web(.notify, feature: "intake")),
        ("route", web(.request, [("url", "link"), ("context", "enum(tab|push|modal|external)"), ("tab", "tab|null")])),
        ("haptic", web(.notify, [("kind", "enum(selection|light|medium|success|warning|error)")])),
        ("intake.line", web(.request, path: "order_form", feature: "intake", maxBytes: 1024 * 1024, [("lineKey", "str(1..64)"), ("url", "url"), ("product", "product|null")])),
        ("intake.take", web(.request, path: "order_form", feature: "intake", [("intakeId", "token")])),
        ("intake.pending", web(.request, path: "order_form", feature: "intake")),
        ("product.image", web(.request, path: "order_form", feature: "intake", [("ref", "token")])),
        ("modal.close", web(.notify)),
        ("download", web(.request, feature: "download", [("url", "link"), ("name", "str(1..255)?")])),
        ("file.save", web(.request, feature: "file.save", maxBytes: 14 * 1024 * 1024, [("name", "str(1..255)"), ("mime", "mime"), ("data", "base64")])),
        ("print", web(.request, feature: "print", [("url", "link"), ("title", "str(0..120)")])),
        ("share", web(.request, feature: "share", [("text", "str(1..4000)?"), ("url", "https?"), ("title", "str(1..120)?")])),
        ("open.external", web(.request, [("url", "link")])),
        ("scan", web(.request, feature: "scan", [("formats", "[str(1..24)](1..16)")])),
        ("appearance.set", web(.notify, path: "more_profile", [("mode", "enum(system|light|dark)")])),
        ("lock.set", web(.request, path: "more_profile", feature: "lock", [("enabled", "bool")])),
        ("shopdata.clear", web(.request, path: "more_profile")),
        ("session.ended", web(.notify)),

        ("back", native(.request)),
        ("intake.fetch", native(.request, feature: "intake", maxBytes: 1024 * 1024, [("url", "url"), ("capture", "str(1..900000)?")])),
        ("intake.offer", native(.request, path: "order_form", feature: "intake", [("intakeId", "token")])),
        ("insets", native(.event, [("top", "num(0..10000)"), ("bottom", "num(0..10000)")])),
        ("visit", native(.request, [("url", "link")])),
        ("tab", native(.event, feature: "chrome", [("key", "tab"), ("reselect", "bool")])),
        ("refresh", native(.event, feature: "chrome")),
        ("search", native(.event, feature: "chrome")),
        ("action", native(.event, feature: "chrome", [("id", "str(1..64)")])),
        ("appearance", native(.event, [("mode", "enum(system|light|dark)"), ("resolved", "enum(light|dark)")])),
        ("appState", native(.event, [("active", "bool")])),
    ]

    private static let specTable: [String: Spec] = Dictionary(uniqueKeysWithValues: specs)

    public static func spec(_ type: String) -> Spec? { specTable[type] }

    // MARK: - small helpers

    static func isIdChar(_ scalar: Unicode.Scalar) -> Bool {
        Url.isAsciiLetter(scalar) || Url.isAsciiDigit(scalar) || scalar == "_" || scalar == "-"
    }

    /// `ID_PATTERN`: 8 to 40 of `[A-Za-z0-9_-]`.
    public static func isId(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        return scalars.count >= 8 && scalars.count <= 40 && scalars.allSatisfy(isIdChar)
    }

    /// `TOKEN_PATTERN`: exactly 22 of `[A-Za-z0-9_-]` (intake ids, image refs, read ids).
    public static func isToken(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        return scalars.count == 22 && scalars.allSatisfy(isIdChar)
    }

    /// `ACCOUNT_KEY_PATTERN`: 32 lower-case hex digits.
    public static func isAccountKey(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        return scalars.count == 32 && scalars.allSatisfy { Url.isAsciiDigit($0) || ($0.value >= 0x61 && $0.value <= 0x66) }
    }

    private static let printPath: NSRegularExpression = try! NSRegularExpression(pattern: printPathPattern, options: [])

    /// `ORDER_FORM_PATH = ^/app/orders/(create|quick|\d+/edit)$`.
    public static func isOrderFormPath(_ path: String) -> Bool {
        let prefix = "/app/orders/"
        guard path.hasPrefix(prefix) else { return false }
        let rest = String(path.dropFirst(prefix.count))
        if rest == "create" || rest == "quick" { return true }
        guard rest.hasSuffix("/edit") else { return false }
        let digits = rest.dropLast(5)
        return !digits.isEmpty && digits.unicodeScalars.allSatisfy(Url.isAsciiDigit)
    }

    /// `PRINT_PATH` (§B5).
    public static func isPrintPath(_ path: String) -> Bool {
        Policy.matches(printPath, path)
    }

    /// Whether a path is a panel path (PANEL_PATHS; case-sensitive, as the routes).
    public static func isPanelPath(_ path: String) -> Bool {
        panelPaths.contains { pattern in
            pattern.hasSuffix("/*") ? path.hasPrefix(String(pattern.dropLast())) : path == pattern
        }
    }

    static func jsLength(_ text: String) -> Int { text.utf16.count }

    static func isString(_ value: JSONValue?, _ min: Int, _ max: Int) -> Bool {
        guard case let .string(text)? = value else { return false }
        let length = jsLength(text)
        return length >= min && length <= max
    }

    static func isNumber(_ value: JSONValue?) -> Bool {
        guard case let .number(number)? = value else { return false }
        return number.isFinite
    }

    static func isInteger(_ value: JSONValue?) -> Bool {
        guard case let .number(number)? = value else { return false }
        return number.isFinite && number == number.rounded()
    }

    static func isNullableString(_ value: JSONValue?) -> Bool {
        switch value {
        case .null?, .string?: return true
        default: return false
        }
    }

    static func isStringList(_ value: JSONValue?) -> Bool {
        value?.stringList != nil
    }

    static func isStringRecord(_ value: JSONValue?) -> Bool {
        guard let object = value?.objectValue else { return false }
        return object.allSatisfy { $0.1.stringValue != nil }
    }

    /// A URL on the trusted origin without credentials, or nil.
    public static func sameOriginUrl(_ value: String, trusted: String) -> Url? {
        guard let url = Url.parse(value), url.origin == trusted, url.noCredentials else { return nil }
        return url
    }

    static let bannedSchemes: Set<String> = ["javascript", "intent", "market", "file", "content", "data", "blob"]

    /// The `open.external` rule (§B5): an https URL on another origin (the in-app browser), a non-panel same-origin
    /// path (`/admin*` in the system browser, the rest in the in-app browser), or `tel:` / `mailto:`; never a panel
    /// path (that is a visit), never a banned or unknown scheme.
    public static func isExternalAllowed(_ value: String, trusted: String = origin) -> Bool {
        if jsLength(value) > Limit.urlChars { return false }
        guard let url = Url.parse(value) else { return false }
        if bannedSchemes.contains(url.scheme) { return false }
        if url.scheme == "tel" || url.scheme == "mailto" { return true }
        if url.origin == trusted {
            return url.noCredentials && !isPanelPath(url.pathname)
        }
        return url.scheme == "https" && url.noCredentials
    }

    /// `visit` carries a panel URL of the origin (§B5).
    public static func isVisitUrl(_ value: String, trusted: String = origin) -> Bool {
        guard let url = sameOriginUrl(value, trusted: trusted) else { return false }
        return isPanelPath(url.pathname)
    }

    // MARK: - field descriptors

    static func isAbsolute(_ value: JSONValue?, _ schemes: Set<String>) -> Bool {
        guard isString(value, 1, Limit.urlChars), let text = value?.stringValue, let url = Url.parse(text) else { return false }
        return schemes.contains(url.scheme)
    }

    /// An `ImportedProduct` exactly as product-link answers it (types only; the byte cap bounds the sizes).
    public static func isImportedProduct(_ value: JSONValue?) -> Bool {
        guard let product = value?.objectValue else { return false }
        guard isAbsolute(product["url"], ["https", "http"]),
              product["site"]?.stringValue != nil,
              isNullableString(product["title"]),
              isNullableString(product["brand"]),
              isStringList(product["images"]),
              isNullableString(product["price"]),
              isNullableString(product["currency"]),
              let options = product["options"]?.arrayValue,
              let variants = product["variants"]?.arrayValue
        else { return false }
        let optionsOk = options.allSatisfy { raw in
            guard let option = raw.objectValue else { return false }
            return option["name"]?.stringValue != nil && option["label"]?.stringValue != nil && isStringList(option["values"])
        }
        let variantsOk = variants.allSatisfy { raw in
            guard let variant = raw.objectValue else { return false }
            let available = variant["available"]
            let availableOk: Bool
            switch available {
            case .null?, .bool?: availableOk = true
            default: availableOk = false
            }
            return isStringRecord(variant["options"]) && isNullableString(variant["image"]) && isNullableString(variant["price"]) &&
                isNullableString(variant["sku"]) && availableOk
        }
        return optionsOk && variantsOk
    }

    /// An `IntakeChoice` of §B6 (native builds them; the tests prove they pass this validator, the web's own).
    public static func isIntakeChoice(_ value: JSONValue?) -> Bool {
        guard let choice = value?.objectValue else { return false }
        guard isImportedProduct(choice["product"]), isStringRecord(choice["chosen"]),
              isString(choice["title"], 1, Limit.choiceTitleChars), let title = choice.string("title"),
              title == title.trimmingCharacters(in: .whitespacesAndNewlines),
              choice["withBrand"]?.boolValue != nil,
              isInteger(choice["quantity"]), let quantity = choice.number("quantity"),
              quantity >= Double(Limit.quantityMin), quantity <= Double(Limit.quantityMax)
        else { return false }
        let imageOk: Bool
        switch choice["image"] {
        case .null?: imageOk = true
        case let .object(image)?: imageOk = image.string("ref").map(isToken) == true && isAbsolute(image["url"], ["https"])
        default: imageOk = false
        }
        let source = choice.string("source")
        return imageOk && (source == "server" || source == "capture")
    }

    /// A compiled field descriptor: whether it may be absent, and the check of a present value.
    public struct FieldCheck {
        public let optional: Bool
        public let check: (JSONValue) -> Bool
    }

    private static func named(_ name: String) -> ((JSONValue) -> Bool)? {
        switch name {
        case "bool": return { $0.boolValue != nil }
        case "path": return { isString($0, 1, Limit.urlChars) && ($0.stringValue ?? "").hasPrefix("/") }
        case "url": return { isAbsolute($0, ["https", "http"]) }
        case "https": return { isAbsolute($0, ["https"]) }
        case "link": return { isString($0, 1, Limit.urlChars) }
        case "token": return { $0.stringValue.map(isToken) == true }
        case "accountKey": return { $0.stringValue.map(isAccountKey) == true }
        case "mime": return { $0.stringValue.map { fileSaveMimes.contains($0) } == true }
        case "base64": return { value in
                guard let text = value.stringValue else { return false }
                let units = text.utf16.count
                return units % 4 == 0 && units <= ((Limit.fileSaveDecodedBytes + 2) / 3) * 4 && isBase64(text)
            }
        case "feature": return { $0.stringValue.map { nativeFeatures.contains($0) } == true }
        case "tab": return { $0.stringValue.map { tabKeys.contains($0) } == true }
        case "back": return { value in
                guard let object = value.objectValue else { return false }
                return isString(object["label"], 0, Limit.labelChars)
            }
        case "action": return { value in
                guard let object = value.objectValue, let icon = object.string("icon") else { return false }
                return isString(object["id"], 1, 64) && actionIcons.contains(icon) && isString(object["label"], 1, Limit.labelChars)
            }
        case "tabItem": return { value in
                guard let object = value.objectValue, let key = object.string("key") else { return false }
                let badgeOk: Bool
                switch object["badge"] {
                case .null?: badgeOk = true
                case let badge?: badgeOk = isInteger(badge) && (badge.doubleValue ?? -1) >= 0
                case nil: badgeOk = false
                }
                return tabKeys.contains(key) && isString(object["label"], 1, Limit.tabLabelChars) && badgeOk
            }
        case "draft": return { value in
                guard let object = value.objectValue else { return false }
                return isNumber(object["at"]) && (object.number("at") ?? -1) >= 0
            }
        case "product": return { isImportedProduct($0) }
        default: return nil
        }
    }

    /// `^[A-Za-z0-9+/]*={0,2}$`.
    static func isBase64(_ text: String) -> Bool {
        var padding = 0
        for scalar in text.unicodeScalars {
            if scalar == "=" {
                padding += 1
                if padding > 2 { return false }
                continue
            }
            if padding > 0 { return false }
            guard Url.isAsciiLetter(scalar) || Url.isAsciiDigit(scalar) || scalar == "+" || scalar == "/" else { return false }
        }
        return true
    }

    /// Unique-item arrays: features and tab keys never repeat.
    private static func uniqueKey(_ item: String) -> ((JSONValue) -> JSONValue?)? {
        switch item {
        case "feature": return { $0 }
        case "tabItem": return { $0.objectValue?["key"] ?? $0 }
        default: return nil
        }
    }

    private static let compiledLock = NSLock()
    nonisolated(unsafe) private static var compiled: [String: FieldCheck] = [:]

    /// Compiles one field descriptor (FIELD GRAMMAR); nil for a descriptor it does not know (a programming error).
    public static func fieldCheck(_ descriptor: String) -> FieldCheck? {
        compiledLock.lock()
        defer { compiledLock.unlock() }
        if let cached = compiled[descriptor] { return cached }
        var text = descriptor
        let optional = text.hasSuffix("?")
        if optional { text.removeLast() }
        let nullable = text.hasSuffix("|null")
        if nullable { text.removeLast(5) }
        guard let base = baseCheck(text) else { return nil }
        let check: (JSONValue) -> Bool = nullable ? { $0.isNull || base($0) } : base
        let result = FieldCheck(optional: optional, check: check)
        compiled[descriptor] = result
        return result
    }

    private static func range(_ text: String) -> ClosedRange<Int>? {
        let parts = text.components(separatedBy: "..")
        guard parts.count == 2, let low = Int(parts[0]), let high = Int(parts[1]), low <= high else { return nil }
        return low ... high
    }

    private static func baseCheck(_ text: String) -> ((JSONValue) -> Bool)? {
        if text.hasPrefix("["), text.hasSuffix(")"), let split = text.range(of: "](", options: .backwards) {
            let item = String(text[text.index(after: text.startIndex) ..< split.lowerBound])
            let bounds = String(text[split.upperBound ..< text.index(before: text.endIndex)])
            guard let itemCheck = baseCheck(item), let range = range(bounds) else { return nil }
            let key = uniqueKey(item)
            return { value in
                guard let items = value.arrayValue, range.contains(items.count), items.allSatisfy(itemCheck) else { return false }
                guard let key else { return true }
                var seen: [JSONValue] = []
                for element in items {
                    let id = key(element)
                    if seen.contains(where: { $0 == id }) { return false }
                    seen.append(id ?? .null)
                }
                return true
            }
        }
        if let open = text.firstIndex(of: "("), text.hasSuffix(")") {
            let name = String(text[text.startIndex ..< open])
            let args = String(text[text.index(after: open) ..< text.index(before: text.endIndex)])
            switch name {
            case "enum":
                let values = Set(args.components(separatedBy: "|"))
                return { $0.stringValue.map { values.contains($0) } == true }
            case "str":
                guard let range = range(args) else { return nil }
                return { isString($0, range.lowerBound, range.upperBound) }
            case "int":
                guard let range = range(args) else { return nil }
                return { value in isInteger(value) && Double(range.lowerBound) <= (value.doubleValue ?? .nan) && (value.doubleValue ?? .nan) <= Double(range.upperBound) }
            case "num":
                guard let range = range(args) else { return nil }
                return { value in isNumber(value) && Double(range.lowerBound) <= (value.doubleValue ?? .nan) && (value.doubleValue ?? .nan) <= Double(range.upperBound) }
            default:
                return nil
            }
        }
        return named(text)
    }

    /// The known fields of a body checked against a spec: the kept fields (unknown ones dropped), or nil when invalid.
    static func checkFields(_ body: JSONObject, _ fields: [(String, String)]) -> JSONObject? {
        var kept = JSONObject()
        for (name, descriptor) in fields {
            guard let field = fieldCheck(descriptor) else { return nil }
            guard let value = body[name] else {
                if field.optional { continue }
                return nil
            }
            if !field.check(value) { return nil }
            kept[name] = value
        }
        return kept
    }

    // MARK: - web → native

    /// Where a posted string came from and what the build allows.
    public struct GuardContext: Sendable {
        public let origin: String
        public let mainFrame: Bool
        /// The path of `webView.url` when the message arrived (§B5).
        public let path: String
        public let trusted: String
        public let features: [String]
        public let disabled: [String]

        public init(origin: String, mainFrame: Bool, path: String, trusted: String = BridgeMessages.origin, features: [String] = BridgeMessages.nativeFeatures, disabled: [String] = []) {
            self.origin = origin
            self.mainFrame = mainFrame
            self.path = path
            self.trusted = trusted
            self.features = features
            self.disabled = disabled
        }
    }

    public enum WebCheck: Equatable {
        /// A request (`id` set) or a notification of a known web → native type, its kept fields in `body`.
        case message(kind: Kind, id: String?, type: String, body: JSONObject)
        /// A page reply to a native request (`re`); its body is checked by `isPageReply` against the open request.
        case reply(re: String, body: JSONObject)
        /// Refused: `id` is the one to answer with `{ok: false, error}` (nil: no reply is sent).
        case refused(error: String, id: String?)
    }

    public static func featureOn(_ feature: String, features: [String] = nativeFeatures, disabled: [String] = []) -> Bool {
        features.contains(feature) && !disabled.contains(feature)
    }

    /// Native's guards for one posted string (§B2, §B3, §B5), in the order of messages.ts.
    public static func checkWebMessage(_ raw: String, _ ctx: GuardContext) -> WebCheck {
        if !ctx.mainFrame || ctx.origin != ctx.trusted {
            return .refused(error: "denied", id: nil)
        }
        let bytes = Json.utf8Bytes(raw)
        if bytes > Limit.absoluteMaxBytes {
            return .refused(error: "invalid", id: nil)
        }
        guard let parsed = Json.parseOrNil(raw)?.objectValue else {
            return .refused(error: "invalid", id: nil)
        }
        let id = parsed.string("id").flatMap { isId($0) ? $0 : nil }
        if parsed.has("id") && id == nil {
            return .refused(error: "invalid", id: nil)
        }
        guard let version = parsed.number("v") else {
            return .refused(error: "invalid", id: id)
        }
        if version != Double(BridgeMessages.version) {
            return .refused(error: "unsupported", id: id)
        }
        if parsed.has("re") {
            guard let re = parsed.string("re"), isId(re), !parsed.has("type"), !parsed.has("id") else {
                return .refused(error: "invalid", id: nil)
            }
            if bytes > max(Limit.defaultMaxBytes, pageReplyMaxBytes.values.max() ?? Limit.defaultMaxBytes) {
                return .refused(error: "invalid", id: nil)
            }
            return .reply(re: re, body: parsed.without(["v", "re"]))
        }
        guard let type = parsed.string("type") else {
            return .refused(error: "invalid", id: id)
        }
        guard let spec = spec(type), spec.dir == "web" else {
            return .refused(error: "unsupported", id: id)
        }
        if (spec.kind == .request) != (id != nil) {
            return .refused(error: "invalid", id: id)
        }
        if bytes > spec.maxBytes {
            return .refused(error: "invalid", id: id)
        }
        guard let body = checkFields(parsed.without(["v", "id", "type"]), spec.fields), shapeRule(type, body) else {
            return .refused(error: "invalid", id: id)
        }
        if let feature = spec.feature, !featureOn(feature, features: ctx.features, disabled: ctx.disabled) {
            return .refused(error: "unavailable", id: id)
        }
        if spec.path == "order_form" && !isOrderFormPath(ctx.path) {
            return .refused(error: "denied", id: id)
        }
        if spec.path == "more_profile" && !moreProfilePaths.contains(ctx.path) {
            return .refused(error: "denied", id: id)
        }
        if !urlRule(type, body, trusted: ctx.trusted) {
            return .refused(error: "denied", id: id)
        }
        return .message(kind: spec.kind == .request ? .request : .notify, id: id, type: type, body: body)
    }

    /// Cross-field shapes the descriptors cannot say (`invalid` when false).
    static func shapeRule(_ type: String, _ body: JSONObject) -> Bool {
        switch type {
        case "share":
            return body.has("text") || body.has("url")
        case "file.save":
            let data = body.string("data") ?? ""
            let padding = data.hasSuffix("==") ? 2 : (data.hasSuffix("=") ? 1 : 0)
            return (data.utf16.count / 4) * 3 - padding <= Limit.fileSaveDecodedBytes
        default:
            return true
        }
    }

    /// The URL rules of §B5 (`denied` when false).
    static func urlRule(_ type: String, _ body: JSONObject, trusted: String) -> Bool {
        let url = body.string("url") ?? ""
        switch type {
        case "route":
            if body.string("context") == "external" {
                return isExternalAllowed(url, trusted: trusted)
            }
            return sameOriginUrl(url, trusted: trusted).map { isPanelPath($0.pathname) } == true
        case "print":
            return sameOriginUrl(url, trusted: trusted).map { isPrintPath($0.pathname) } == true
        case "download":
            return sameOriginUrl(url, trusted: trusted)?.pathname.hasPrefix("/app/") == true
        case "open.external":
            return isExternalAllowed(url, trusted: trusted)
        default:
            return true
        }
    }

    /// Native state the capability-bearing types need (§B5).
    public struct NativeState: Sendable {
        public var intakeIds: Set<String>
        public var refs: Set<String>
        public var confirmed: Bool

        public init(intakeIds: Set<String> = [], refs: Set<String> = [], confirmed: Bool = false) {
            self.intakeIds = intakeIds
            self.refs = refs
            self.confirmed = confirmed
        }
    }

    /// The second stage, after `checkWebMessage` accepted a request: `intake.take` needs an issued, unused id (`gone`),
    /// `product.image` a ref native gave this page (`not_allowed`), `lock.set` and `shopdata.clear` the native
    /// confirmation (`cancelled`). Nil = go ahead.
    public static func admitWebMessage(_ type: String, _ body: JSONObject, _ state: NativeState) -> String? {
        switch type {
        case "intake.take": return state.intakeIds.contains(body.string("intakeId") ?? "") ? nil : "gone"
        case "product.image": return state.refs.contains(body.string("ref") ?? "") ? nil : "not_allowed"
        case "lock.set", "shopdata.clear": return state.confirmed ? nil : "cancelled"
        default: return nil
        }
    }

    // MARK: - native → web

    /// The WebView native is about to send to (§B4.3, §B5).
    public struct SendTarget: Sendable {
        /// `modal` for the modal WebView, `tab` for a tab WebView (the primary included).
        public let webView: String
        /// The origin of the WebView's committed document.
        public let origin: String
        public let path: String
        /// Whether that document sent `hello` and got its reply.
        public let greeted: Bool

        public init(webView: String, origin: String, path: String, greeted: Bool) {
            self.webView = webView
            self.origin = origin
            self.path = path
            self.greeted = greeted
        }
    }

    /// Whether native may send `raw` to `target` (§B5): the document is committed on the origin and greeted;
    /// `intake.offer` goes only to the modal WebView on an order form; `visit` carries a panel URL of the origin.
    /// `denied` when not; `invalid` for a message native should never build. Nil = send.
    public static func checkNativeSend(_ raw: String, _ target: SendTarget, trusted: String = origin) -> String? {
        guard let message = parseNative(raw) else { return "invalid" }
        if target.origin != trusted || !target.greeted {
            return "denied"
        }
        if message.type == "intake.offer" && !(target.webView == "modal" && isOrderFormPath(target.path)) {
            return "denied"
        }
        if message.type == "visit" && !isVisitUrl(message.body.string("url") ?? "", trusted: trusted) {
            return "denied"
        }
        return nil
    }

    /// The structure of a native → web request or event (envelope, known type, `id` exactly for requests, fields).
    static func parseNative(_ raw: String) -> (type: String, body: JSONObject)? {
        let bytes = Json.utf8Bytes(raw)
        if bytes > Limit.absoluteMaxBytes { return nil }
        guard let parsed = Json.parseOrNil(raw)?.objectValue else { return nil }
        if parsed.number("v") != Double(version) || parsed.has("re") { return nil }
        guard let type = parsed.string("type"), let spec = spec(type), spec.dir == "native", bytes <= spec.maxBytes else { return nil }
        let id = parsed.string("id").flatMap { isId($0) ? $0 : nil }
        if parsed.has("id") != (spec.kind == .request) || (spec.kind == .request && id == nil) { return nil }
        guard let body = checkFields(parsed.without(["v", "id", "type"]), spec.fields) else { return nil }
        return (type, body)
    }

    /// The page's reply body to a native request of `type` (§B4.2): what native accepts.
    public static func isPageReply(_ type: String, _ body: JSONObject) -> Bool {
        switch type {
        case "back", "visit":
            return body.bool("handled") != nil
        case "intake.offer":
            return body.bool("ok") != nil
        case "intake.fetch":
            if body.bool("ok") == true {
                let source = body.string("source")
                return isImportedProduct(body["product"]) && (source == "server" || source == "capture")
            }
            guard body.bool("ok") == false, let reason = body.string("reason") else { return false }
            return fetchReasons.contains(reason) && body.string("message") != nil
        default:
            return false
        }
    }

    // MARK: - builders

    /// Native's reply to a web request: `{v, re, ok: true, …body}`.
    public static func replyOk(_ re: String, _ body: JSONObject = JSONObject()) -> String {
        let head = JSONObject([("v", .int(version)), ("re", .string(re)), ("ok", .bool(true))])
        return Json.write(head.merging(body))
    }

    /// Native's refusal of a web request: `{v, re, ok: false, error}` (+ extra fields such as `reason`).
    public static func replyError(_ re: String, _ error: String, _ extra: JSONObject = JSONObject()) -> String {
        let code = errors.contains(error) ? error : "failed"
        let head = JSONObject([("v", .int(version)), ("re", .string(re)), ("ok", .bool(false)), ("error", .string(code))])
        return Json.write(head.merging(extra))
    }

    /// A native → web request (`id` set) or event.
    public static func nativeMessage(_ type: String, id: String?, _ body: JSONObject = JSONObject()) -> String {
        var message = JSONObject([("v", .int(version))])
        if let id {
            message["id"] = .string(id)
        }
        message["type"] = .string(type)
        return Json.write(message.merging(body))
    }

    // MARK: - ids

    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")

    /// `length` random URL-safe characters (intake ids, image refs and read ids use 22, §B5).
    public static func randomToken(_ length: Int = 22) -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0 ..< length).map { _ in alphabet[Int(generator.next() & 63)] })
    }

    /// A message id of native (`ID_PATTERN`): `n` + 16 random URL-safe characters.
    public static func nextId() -> String {
        "n" + randomToken(16)
    }
}
