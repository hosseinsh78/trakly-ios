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

/// A short message at the bottom of the screen (native texts of the copy only), in a window of its own above the app's
/// window and every sheet, alert and full-screen modal it presents, and below the cover window (the lock, S7, S8).
/// Fixer, 2026-10-24: the toast used to be a subview of the app's window, which a sheet's accessibility container kept
/// out of reach (VoiceOver and the UI tests did not find «شما اجازه ثبت سفارش ندارید.» over S4); the window takes no
/// touch (they reach the app below) and never becomes key.
/// Fixer, 2026-10-24 (third round): the fade-out used to be started with the toast (`animate(delay:)`), which set the
/// label's alpha to 0 at once and only drew the fade later, so accessibility counted the toast as invisible for its whole
/// life (VoiceOver could not reach it and the UI tests never found it, over S4 or after «پاک کردن داده سایت ها»). The
/// fade-out now starts when the time is up. The window takes part in accessibility (user interaction on, every touch
/// still passed down by `hitTest`) and has a root view controller like the cover window; the root follows the app's
/// window for the status bar, so a toast never changes it. The toast sits above the keyboard when one is up.
@MainActor
enum Toast {
    /// One toast window per scene, made on the first toast.
    private static var windows: [ObjectIdentifier: ToastWindow] = [:]

    /// How long a toast stays (a Debug UI test may hold it longer, `-TraklyToastMs`, for its screenshot).
    static var visibleSeconds: TimeInterval {
        AppConfig.testArgument("TraklyToastMs").flatMap { Double($0) }.map { $0 / 1000 } ?? 2.4
    }

    static func show(_ text: String, in host: UIView?) {
        guard let scene = ((host as? UIWindow) ?? host?.window)?.windowScene else { return }
        let window = windows[ObjectIdentifier(scene)] ?? {
            let made = ToastWindow(windowScene: scene)
            made.windowLevel = .normal + 1
            made.backgroundColor = .clear
            made.rootViewController = ToastRootViewController()
            made.accessibilityIdentifier = "toasts"
            windows[ObjectIdentifier(scene)] = made
            return made
        }()
        guard let root = window.rootViewController as? ToastRootViewController else { return }
        let main = scene.windows.first { !($0 is ToastWindow) && $0.windowLevel == .normal }
        root.main = main
        window.overrideUserInterfaceStyle = main?.overrideUserInterfaceStyle ?? .unspecified
        let stage = root.view!
        // A new toast replaces the one on screen.
        for old in stage.subviews where old.accessibilityIdentifier == "toast" {
            old.removeFromSuperview()
        }
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
        stage.addSubview(label)
        window.isHidden = false
        root.setNeedsStatusBarAppearanceUpdate()
        let resting = label.bottomAnchor.constraint(equalTo: stage.safeAreaLayoutGuide.bottomAnchor, constant: -72)
        resting.priority = .defaultHigh
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: stage.centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: stage.leadingAnchor, constant: 24),
            resting,
            label.bottomAnchor.constraint(lessThanOrEqualTo: stage.keyboardLayoutGuide.topAnchor, constant: -16),
        ])
        UIAccessibility.post(notification: .announcement, argument: text)
        UIView.animate(withDuration: 0.2) { label.alpha = 1 }
        let seconds = visibleSeconds
        Task { [weak label, weak window] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            // Replaced by a newer toast in the meantime: that one ends on its own.
            guard let label, label.superview != nil else { return }
            UIView.animate(withDuration: 0.3) {
                label.alpha = 0
            } completion: { _ in
                label.removeFromSuperview()
                if let window, !stage.subviews.contains(where: { $0.accessibilityIdentifier == "toast" }) {
                    window.isHidden = true
                }
            }
        }
    }
}

/// The toast window: drawn above the app, never in the way of a touch.
final class ToastWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        nil
    }
}

/// The root of the toast window: a clear stage for the toast. While the window is up it would decide the status bar,
/// so it answers what the app's window shows (a full-screen presentation or one that captures the status bar, else
/// the root, down their `childForStatusBar…` chain).
@MainActor
final class ToastRootViewController: UIViewController {
    weak var main: UIWindow?

    override func loadView() {
        let view = UIView()
        view.backgroundColor = .clear
        view.semanticContentAttribute = .forceRightToLeft
        self.view = view
    }

    /// The view controller of the app's window that sets the status bar.
    var statusBarSource: UIViewController? {
        var top = main?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed,
              presented.modalPresentationStyle == .fullScreen || presented.modalPresentationCapturesStatusBarAppearance {
            top = presented
        }
        return top
    }

    private func settled(_ next: (UIViewController) -> UIViewController?) -> UIViewController? {
        var current = statusBarSource
        while let now = current, let child = next(now), child !== now {
            current = child
        }
        return current
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        settled { $0.childForStatusBarStyle }?.preferredStatusBarStyle ?? .default
    }

    override var prefersStatusBarHidden: Bool {
        settled { $0.childForStatusBarHidden }?.prefersStatusBarHidden ?? false
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .portrait
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
