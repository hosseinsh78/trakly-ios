import UIKit

/// Confirm dialogs (S13, docs/specs/phase10-apps-and-stores.md §A3, §E3): the stock `UIAlertController`, right to left
/// with the brand tint; destructive actions in the system's destructive style. Its font is the system's (UIKit offers
/// no public way to restyle an alert, and private keys are not used).
@MainActor
enum Alerts {
    static func make(title: String?, message: String?, style: UIAlertController.Style = .alert) -> UIAlertController {
        // The stock alert (its own font, no private styling keys); right to left like every native screen.
        let alert = UIAlertController(title: title, message: message, preferredStyle: style)
        alert.view.semanticContentAttribute = .forceRightToLeft
        alert.view.tintColor = Theme.brand
        return alert
    }

    /// The top view controller that can present now.
    static func top(from root: UIViewController?) -> UIViewController? {
        var current = root
        while let presented = current?.presentedViewController, !presented.isBeingDismissed {
            current = presented
        }
        return current
    }
}
