import Foundation

/// The native chrome of one document (docs/specs/phase10-apps-and-stores.md D5, D8, §B1, §B4.1 `page`, §E3): a pure
/// reducer from the newest `page` of the WebView's current document (or none), the main frame's HTTP status and the tab
/// state to what `ChromePresenter` draws. The web decides; native renders. The port of Android's `core/PageState.kt`
/// (the plus bar button instead of the FAB).
public enum PageState {
    public struct Action: Equatable, Sendable {
        public let id: String
        public let icon: String
        public let label: String

        public init(id: String, icon: String, label: String) {
            self.id = id
            self.icon = icon
            self.label = label
        }
    }

    /// One `page` message (already accepted by `BridgeMessages.checkWebMessage`).
    public struct Page: Equatable, Sendable {
        public var context: String
        public var tab: String?
        public var title: String
        public var titleVisible: Bool
        public var backLabel: String?
        public var refreshable: Bool
        public var dirty: Bool
        public var overlay: Bool
        public var search: Bool
        public var action: Action?
        public var tone: String

        public init(context: String, tab: String?, title: String, titleVisible: Bool, backLabel: String?, refreshable: Bool, dirty: Bool, overlay: Bool, search: Bool, action: Action?, tone: String) {
            self.context = context
            self.tab = tab
            self.title = title
            self.titleVisible = titleVisible
            self.backLabel = backLabel
            self.refreshable = refreshable
            self.dirty = dirty
            self.overlay = overlay
            self.search = search
            self.action = action
            self.tone = tone
        }

        public var night: Bool { tone == "night" }

        public static func of(_ body: JSONObject) -> Page {
            let action = body.object("action").flatMap { object -> Action? in
                guard let id = object.string("id"), let icon = object.string("icon"), let label = object.string("label") else { return nil }
                return Action(id: id, icon: icon, label: label)
            }
            return Page(
                context: body.string("context") ?? "tab",
                tab: body.string("tab"),
                title: body.string("title") ?? "",
                titleVisible: body.bool("titleVisible") == true,
                backLabel: body.object("back")?.string("label"),
                refreshable: body.bool("refreshable") == true,
                dirty: body.bool("dirty") == true,
                overlay: body.bool("overlay") == true,
                search: body.bool("search") == true,
                action: action,
                tone: body.string("tone") ?? "day"
            )
        }
    }

    /// What the shell draws for the visible tab WebView.
    public struct Chrome: Equatable, Sendable {
        public var navigationBar: Bool
        public var tabBar: Bool
        /// A pushed page: the stack shows the system back arrow.
        public var backArrow: Bool
        /// Shown in the navigation bar (empty while the page's own h1 is in view).
        public var title: String
        public var search: Bool
        public var action: Action?
        public var refreshable: Bool
        /// The trailing «ثبت سفارش» plus bar button (the Home and Orders roots).
        public var createButton: Bool
        /// Light status bar content (the night tone).
        public var lightStatusBar: Bool
        /// The WebView is full screen and gets the real safe-area insets (`auth`, `standalone`, no bars).
        public var fullScreen: Bool

        public init(navigationBar: Bool, tabBar: Bool, backArrow: Bool, title: String, search: Bool, action: Action?, refreshable: Bool, createButton: Bool, lightStatusBar: Bool, fullScreen: Bool) {
            self.navigationBar = navigationBar
            self.tabBar = tabBar
            self.backArrow = backArrow
            self.title = title
            self.search = search
            self.action = action
            self.refreshable = refreshable
            self.createButton = createButton
            self.lightStatusBar = lightStatusBar
            self.fullScreen = fullScreen
        }

        public static let none = Chrome(navigationBar: false, tabBar: false, backArrow: false, title: "", search: false, action: nil, refreshable: false, createButton: false, lightStatusBar: true, fullScreen: true)
    }

    /// The chrome of a tab WebView: `page` is the newest `page` of its current document (nil when the document sent
    /// none), `httpError` the main frame's status when it was ≥ 400 (a Laravel error page), `coldStartBars` the kept
    /// last context was `tab` and the launch cover still shows (§B1 exception b), `night` the resolved theme (the tone
    /// of a page without `page`), `canGoBack` whether the stack or the WebView can go back.
    public static func chrome(page: Page?, httpError: Int?, tabs: Tabs.State, coldStartBars: Bool, night: Bool, canGoBack: Bool) -> Chrome {
        guard let page else {
            if let httpError, httpError >= 400 {
                // §B1 (a): an error page keeps the tab bar, a back control and pull to refresh.
                return Chrome(navigationBar: true, tabBar: true, backArrow: canGoBack, title: "", search: false, action: nil, refreshable: true, createButton: false, lightStatusBar: night, fullScreen: false)
            }
            if coldStartBars {
                return Chrome(navigationBar: true, tabBar: true, backArrow: false, title: "", search: false, action: nil, refreshable: false, createButton: false, lightStatusBar: night, fullScreen: false)
            }
            var none = Chrome.none
            none.lightStatusBar = night
            return none
        }
        switch page.context {
        case "auth", "standalone":
            var none = Chrome.none
            none.lightStatusBar = page.night
            return none
        case "tab", "push":
            return Chrome(
                navigationBar: true,
                tabBar: true,
                backArrow: page.context == "push",
                title: barTitle(page),
                search: page.search,
                action: page.action,
                refreshable: page.refreshable && !page.overlay,
                createButton: page.context == "tab" && Tabs.createOn(page.tab, tabs),
                lightStatusBar: page.night,
                fullScreen: false
            )
        default:
            // A modal document in a tab slot (a link opened in place): the bars of a pushed page.
            return Chrome(navigationBar: true, tabBar: true, backArrow: true, title: barTitle(page), search: false, action: page.action, refreshable: false, createButton: false, lightStatusBar: page.night, fullScreen: false)
        }
    }

    /// The title of a native bar over `page`: shown only while the page's own heading is out of view, so a title is
    /// never on screen twice (§B4.1 `title`).
    public static func barTitle(_ page: Page?) -> String {
        guard let page, !page.titleVisible else { return "" }
        return page.title
    }

    /// What is kept for the next cold start (never anything of the session): the last context and tone.
    public struct Persisted: Equatable, Sendable {
        public let context: String?
        public let night: Bool

        public init(context: String?, night: Bool) {
            self.context = context
            self.night = night
        }
    }
}
