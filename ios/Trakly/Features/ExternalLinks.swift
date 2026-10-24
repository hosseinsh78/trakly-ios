import SafariServices
import TraklyCore
import UIKit

/// Links that leave the panel (docs/specs/phase10-apps-and-stores.md §B5 `open.external`, §B7, §E4, D13): other
/// same-origin pages and other https sites in the in-app browser (`SFSafariViewController`, S10, brand tint; `/privacy`
/// and `/account-deletion` with `?from=app&p=ios`); `/admin*`, `tel:`, `mailto:`, `wa.me` and `t.me` through the system.
/// The only file that calls `UIApplication.shared.open` besides UpdateRequiredView (`source.check.mjs`).
@MainActor
enum ExternalLinks {
    /// Opens `url` as `NavigationPolicy` says; false when it is blocked.
    @discardableResult
    static func open(_ url: String, from presenter: UIViewController?) -> Bool {
        let target = NavigationPolicy.classify(url, trusted: AppConfig.origin)
        switch target {
        case .blocked, .panel:
            return false
        case .system:
            guard let parsed = URL(string: url) else { return false }
            UIApplication.shared.open(parsed, options: [:], completionHandler: nil)
            return true
        case .inApp:
            let decorated = NavigationPolicy.decorateFromApp(url, platform: "ios", trusted: AppConfig.origin)
            guard let parsed = URL(string: decorated), let presenter else { return false }
            let configuration = SFSafariViewController.Configuration()
            configuration.entersReaderIfAvailable = false
            configuration.barCollapsingEnabled = true
            let browser = SFSafariViewController(url: parsed, configuration: configuration)
            browser.preferredControlTintColor = Theme.brand
            browser.dismissButtonStyle = .close
            browser.modalPresentationStyle = .pageSheet
            presenter.present(browser, animated: true)
            return true
        }
    }

}
