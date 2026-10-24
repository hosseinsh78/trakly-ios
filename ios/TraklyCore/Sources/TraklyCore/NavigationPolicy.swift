import Foundation

/// Where a main-frame URL of a panel WebView goes (docs/specs/phase10-apps-and-stores.md §B7, §E4, D13): the panel paths
/// stay in the panel; other same-origin pages and other https sites open in the in-app browser
/// (`SFSafariViewController`); `/admin*` opens in the system browser (D13), `tel:` and `mailto:` in the phone or mail
/// app, `https://wa.me/…` and `https://t.me/…` through the system (their app or the browser); everything else is
/// blocked. Pure; `NavigationPolicyTests` runs `shared/fixtures/route-cases.json` (the port of Android's
/// `core/NavigationPolicy.kt`).
public enum NavigationPolicy {
    public enum Target: String, Equatable, Sendable {
        case panel
        case inApp = "inapp"
        case system
        case blocked
    }

    /// Hosts whose links belong to an app the user has (WhatsApp, Telegram): the system decides.
    public static let appHosts: Set<String> = ["wa.me", "t.me", "telegram.me"]

    /// `url` for a panel WebView of `trusted` (the build's origin).
    public static func classify(_ url: String, trusted: String = BridgeMessages.origin) -> Target {
        if url.utf16.count > BridgeMessages.Limit.urlChars { return .blocked }
        guard let parsed = Url.parse(url) else { return .blocked }
        if parsed.scheme == "tel" || parsed.scheme == "mailto" { return .system }
        if parsed.host == nil || !parsed.noCredentials { return .blocked }
        if parsed.origin == trusted {
            if parsed.pathname.hasPrefix("/admin") { return .system }
            return BridgeMessages.isPanelPath(parsed.pathname) ? .panel : .inApp
        }
        if parsed.scheme != "https" { return .blocked }
        return appHosts.contains(parsed.hostName ?? "") ? .system : .inApp
    }

    /// The normalised href of a panel URL of `trusted`, or nil when `url` is not one (universal links, `visit`, §B5).
    public static func panelUrl(_ url: String, trusted: String = BridgeMessages.origin) -> String? {
        classify(url, trusted: trusted) == .panel ? Url.parse(url)?.href : nil
    }

    /// The path of `url` (`url.pathname`), or nil.
    public static func pathOf(_ url: String?) -> String? {
        guard let url else { return nil }
        return Url.parse(url)?.pathname
    }

    /// The origin of `url`, or nil (an opaque origin).
    public static func originOf(_ url: String?) -> String? {
        guard let url else { return nil }
        return Url.parse(url)?.origin
    }

    /// The public pages the app opens in the in-app browser with `?from=app&p=ios` (§B7: `/privacy` and
    /// `/account-deletion`, which then render compact without the header buttons and fold the other platform's part).
    public static func decorateFromApp(_ url: String, platform: String = "ios", trusted: String = BridgeMessages.origin) -> String {
        guard let parsed = Url.parse(url), parsed.origin == trusted,
              parsed.pathname == "/privacy" || parsed.pathname.hasPrefix("/account-deletion")
        else { return url }
        let query = parsed.query ?? ""
        if query.split(separator: "&").contains(where: { $0.hasPrefix("from=") }) {
            return url
        }
        let mark = "from=app&p=" + platform
        return parsed.withQuery(query.isEmpty ? mark : query + "&" + mark).href
    }
}
