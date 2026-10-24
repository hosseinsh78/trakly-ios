import UIKit

/// «ظاهر» (docs/specs/phase10-apps-and-stores.md §B4.1 `appearance.set`, §E3 "Appearance"): `system`, `light` or `dark`,
/// kept in UserDefaults and applied as the window's `overrideUserInterfaceStyle`; the panel's colour scheme follows
/// (WebKit reads the trait), and native tells every page with `appearance`.
@MainActor
enum Appearance {
    private static let key = "trakly.appearance"

    static var mode: String {
        let value = UserDefaults.standard.string(forKey: key) ?? "system"
        return ["system", "light", "dark"].contains(value) ? value : "system"
    }

    static func apply(to window: UIWindow) {
        switch mode {
        case "light": window.overrideUserInterfaceStyle = .light
        case "dark": window.overrideUserInterfaceStyle = .dark
        default: window.overrideUserInterfaceStyle = .unspecified
        }
    }

    static func set(_ value: String, on window: UIWindow) {
        guard ["system", "light", "dark"].contains(value) else { return }
        UserDefaults.standard.set(value, forKey: key)
        UIView.transition(with: window, duration: 0.25, options: .transitionCrossDissolve) {
            apply(to: window)
        }
    }
}

/// The quick actions of the home screen icon (§E8): «ثبت سفارش» (S4; over an open order form in merge mode), «سفارش
/// سریع» (the modal at `/app/orders/quick`) and «سفارش ها» (the Orders tab). Set at launch from the generated copy, so
/// their titles are the copy's Persian (an Info.plist title would need its own localisation file).
@MainActor
enum QuickActions {
    static func install() {
        UIApplication.shared.shortcutItems = [
            UIApplicationShortcutItem(type: "info.trakly.app.new-order", localizedTitle: L.s("qa_new_order"), localizedSubtitle: nil, icon: UIApplicationShortcutIcon(systemImageName: "plus"), userInfo: nil),
            UIApplicationShortcutItem(type: "info.trakly.app.quick-order", localizedTitle: L.s("qa_quick_order"), localizedSubtitle: nil, icon: UIApplicationShortcutIcon(systemImageName: "bolt"), userInfo: nil),
            UIApplicationShortcutItem(type: "info.trakly.app.orders", localizedTitle: L.s("qa_orders"), localizedSubtitle: nil, icon: UIApplicationShortcutIcon(systemImageName: "bag"), userInfo: nil),
        ]
    }
}

/// A short message at the bottom of the screen (native texts of the copy only). Shown in the window and drawn above
/// its other views, so a sheet presented a moment later (S4) does not cover it.
@MainActor
enum Toast {
    static func show(_ text: String, in host: UIView?) {
        guard let host else { return }
        let label = PaddedLabel()
        label.attributedText = FaText.attributed(text, size: 14, bold: true, color: Theme.onInk)
        label.textAlignment = .center
        label.numberOfLines = 0
        label.backgroundColor = Theme.ink
        label.layer.cornerRadius = Theme.controlRadius
        label.layer.masksToBounds = true
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.accessibilityIdentifier = "toast"
        label.layer.zPosition = 1000
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 24),
            label.bottomAnchor.constraint(equalTo: host.safeAreaLayoutGuide.bottomAnchor, constant: -72),
        ])
        UIAccessibility.post(notification: .announcement, argument: text)
        UIView.animate(withDuration: 0.2) { label.alpha = 1 }
        UIView.animate(withDuration: 0.3, delay: 2.4, options: []) {
            label.alpha = 0
        } completion: { _ in
            label.removeFromSuperview()
        }
    }
}

final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }
}
