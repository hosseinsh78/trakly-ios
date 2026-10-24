import Foundation

/// What an incoming link or action does (docs/specs/phase10-apps-and-stores.md D37, §A2 F3–F4, §E3 "Incoming links and
/// actions", §E8): the pure rules of `AppCoordinator`. Nothing incoming closes an open screen; while an order form is
/// open in the modal, a pending share or the «ثبت سفارش» quick action opens S4 over it in merge mode; a universal link
/// or the «سفارش ها» / «سفارش سریع» quick action while the form is dirty runs the dirty confirm first. The iOS sibling
/// of Android's `core/IncomingIntent.kt`.
public enum IncomingLink {
    public enum Incoming: Equatable, Sendable {
        /// Links the share extension saved (picked up on the next foreground).
        case shares([String])
        /// A universal link (`NSUserActivityTypeBrowsingWeb`).
        case universal(String?)
        /// A quick action (`UIApplicationShortcutItem.type`).
        case quickAction(String)
    }

    /// What is open when it arrives.
    public struct Screen: Equatable, Sendable {
        /// The modal shows an `ORDER_FORM_PATH` page.
        public var orderFormOpen: Bool
        /// The modal is open (any form).
        public var modalOpen: Bool
        /// The modal's page reported `dirty`.
        public var modalDirty: Bool
        /// The web's `intake` feature (in `hello.features`, not in `config.disabled`).
        public var intake: Bool
        /// The `shareEntry` feature.
        public var shareEntry: Bool
        /// Signed in (a `tab` context was seen since the last sign-in page).
        public var signedIn: Bool

        public init(orderFormOpen: Bool, modalOpen: Bool, modalDirty: Bool, intake: Bool, shareEntry: Bool, signedIn: Bool) {
            self.orderFormOpen = orderFormOpen
            self.modalOpen = modalOpen
            self.modalDirty = modalDirty
            self.intake = intake
            self.shareEntry = shareEntry
            self.signedIn = signedIn
        }
    }

    public enum Action: Equatable, Sendable {
        case nothing
        /// Keep the shares until the next `tab` context (signed out, or the shell not ready).
        case keep
        /// S4 (over whatever is open) with pending shared links; `merge` = over an open order form.
        case composer(shared: [String], merge: Bool)
        /// The modal at `path` (a panel path with its query); `confirmFirst` = the dirty confirm runs first.
        case modal(path: String, confirmFirst: Bool)
        /// A tab root; `confirmFirst` = the dirty confirm first, then the clean modal closes.
        case tab(key: String, confirmFirst: Bool)
        /// `visit {url}` (a universal link), after the dirty confirm when `confirmFirst`.
        case visit(url: String, confirmFirst: Bool)
    }

    public static let newOrder = "info.trakly.app.new-order"
    public static let quickOrder = "info.trakly.app.quick-order"
    public static let orders = "info.trakly.app.orders"

    public static func decide(_ incoming: Incoming, _ screen: Screen, trusted: String) -> Action {
        switch incoming {
        case let .shares(urls):
            return shares(urls, screen)
        case let .universal(url):
            guard let url, let panel = NavigationPolicy.panelUrl(url, trusted: trusted) else { return .nothing }
            return .visit(url: panel, confirmFirst: screen.modalOpen && screen.modalDirty)
        case let .quickAction(type):
            return quickAction(type, screen)
        }
    }

    private static func shares(_ urls: [String], _ screen: Screen) -> Action {
        if urls.isEmpty || !screen.shareEntry { return .nothing }
        if !screen.signedIn { return .keep }
        if !screen.intake {
            // Without native order entry the web form reads the link on the server (takeSharedLink()).
            return .modal(path: "/app/orders/create?shared_url=" + encode(urls[0]), confirmFirst: screen.modalDirty)
        }
        return .composer(shared: urls, merge: screen.orderFormOpen)
    }

    private static func quickAction(_ type: String, _ screen: Screen) -> Action {
        switch type {
        case newOrder:
            if screen.intake { return .composer(shared: [], merge: screen.orderFormOpen) }
            return .modal(path: "/app/orders/create", confirmFirst: screen.modalDirty)
        case quickOrder:
            return .modal(path: "/app/orders/quick", confirmFirst: screen.modalOpen && screen.modalDirty)
        case orders:
            return .tab(key: "orders", confirmFirst: screen.modalOpen && screen.modalDirty)
        default:
            return .nothing
        }
    }

    /// `encodeURIComponent` of a URL for a query value.
    public static func encode(_ value: String) -> String {
        var out = ""
        let hex = Array("0123456789ABCDEF")
        for byte in value.utf8 {
            let scalar = Unicode.Scalar(byte)
            if Url.isAsciiLetter(scalar) || Url.isAsciiDigit(scalar) || "-_.!~*'()".unicodeScalars.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else {
                out.append("%")
                out.append(hex[Int(byte >> 4)])
                out.append(hex[Int(byte & 0xF)])
            }
        }
        return out
    }
}

/// The links of the share extension in the App Group (D20, §E8): at most 10, for 24 hours, the newest first, one per
/// URL. Pure: the extension and the app read and write `shared-links.json` with file coordination around it.
public enum SharedLinks {
    public struct Entry: Equatable, Sendable {
        public let url: String
        public let at: Int64

        public init(url: String, at: Int64) {
            self.url = url
            self.at = at
        }
    }

    public static func parse(_ text: String?) -> [Entry] {
        guard let text, let items = Json.parseOrNil(text)?.arrayValue else { return [] }
        return items.compactMap { raw in
            guard let item = raw.objectValue, let url = item.string("url"), let at = item.number("at") else { return nil }
            return Entry(url: url, at: Int64(at))
        }
    }

    public static func write(_ entries: [Entry]) -> String {
        Json.write(.array(entries.map { .object(JSONObject([("url", .string($0.url)), ("at", .number(Double($0.at)))])) }))
    }

    /// The live entries at `now` (wall clock): younger than 24 hours, not from the future, at most 10.
    public static func live(_ entries: [Entry], now: Int64) -> [Entry] {
        Array(entries.filter { now - $0.at < Limits.sharedLinksMs && $0.at <= now + 60_000 }.prefix(Limits.sharedLinksMax))
    }

    /// `url` added at `now`: the newest first, one per URL, at most 10 live ones.
    public static func adding(_ url: String, to entries: [Entry], now: Int64) -> [Entry] {
        live([Entry(url: url, at: now)] + entries.filter { $0.url != url }, now: now)
    }
}

/// The clipboard chip of S4 (D20, §E8): its text is the copy «لینک کپی شده» without a `{host}` placeholder (the host is
/// never known before the tap: iOS only says the pasteboard probably holds a web URL, `detectPatterns`). The port of
/// Android's `core/ClipRule.label`.
public enum ClipRule {
    public static func label(_ copy: String) -> String {
        guard let cut = copy.firstIndex(of: "%") else { return copy.trimmingCharacters(in: .whitespaces) }
        var text = String(copy[copy.startIndex ..< cut])
        let drop: Set<Character> = [" ", ":", "\u{2068}", "\u{2069}", "\u{200F}", "\u{061B}"]
        while let last = text.last, drop.contains(last) { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

/// Which panel WebView serves `intake.fetch` (§B4.3): the modal when presented, committed on the origin and greeted;
/// else the selected tab's WebView; else the primary one. A WebView in `auth` or `standalone`, or with a main-frame load
/// in progress, is skipped. Pure.
public enum IntakeHost {
    public struct Candidate: Equatable, Sendable {
        public let key: String
        public let isModal: Bool
        public let isSelected: Bool
        public let isPrimary: Bool
        public let committedOnOrigin: Bool
        public let greeted: Bool
        public let context: String?
        public let loading: Bool

        public init(key: String, isModal: Bool, isSelected: Bool, isPrimary: Bool, committedOnOrigin: Bool, greeted: Bool, context: String?, loading: Bool) {
            self.key = key
            self.isModal = isModal
            self.isSelected = isSelected
            self.isPrimary = isPrimary
            self.committedOnOrigin = committedOnOrigin
            self.greeted = greeted
            self.context = context
            self.loading = loading
        }

        var ready: Bool {
            committedOnOrigin && greeted && !loading && context != "auth" && context != "standalone"
        }
    }

    /// The key of the WebView to ask, or nil when none is ready (wait up to 10 s, then `network`). `excluded` are keys
    /// that already failed this request (the retry on the next candidate).
    public static func choose(_ candidates: [Candidate], excluded: Set<String> = []) -> String? {
        let open = candidates.filter { !excluded.contains($0.key) && $0.ready }
        if let modal = open.first(where: \.isModal) { return modal.key }
        if let selected = open.first(where: \.isSelected) { return selected.key }
        if let primary = open.first(where: \.isPrimary) { return primary.key }
        return nil
    }
}
