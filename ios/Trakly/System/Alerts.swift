import UIKit

/// Confirm dialogs (S13, docs/specs/phase10-apps-and-stores.md §A3, §E3): `UIAlertController` with the title and
/// message right to left in the app font; destructive actions in the system's destructive style.
@MainActor
enum Alerts {
    static func make(title: String?, message: String?, style: UIAlertController.Style = .alert) -> UIAlertController {
        let alert = UIAlertController(title: title, message: message, preferredStyle: style)
        if let title {
            alert.setValue(FaText.attributed(title, size: 17, bold: true), forKey: "attributedTitle")
        }
        if let message {
            alert.setValue(FaText.attributed(message, size: 14, color: Theme.ink2), forKey: "attributedMessage")
        }
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
