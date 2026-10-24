import UIKit

/// The blocking screens above everything the app presents (docs/specs/phase10-apps-and-stores.md D21, §E3, §E9; fixer
/// 2026-10-24): the offline screen (S7), the update screen (S8) and the lock cover live in their own window over the
/// app's window, so the full-screen modal, S4, S5, S6, Quick Look, print, the scanner, the in-app browser and the
/// alerts never sit above them, and the app-switcher snapshot shows no data. The lock is always on top, then the
/// update screen, then the offline screen. The launch cover stays in the root (nothing is presented at launch).
@MainActor
final class CoverWindow {
    /// Bottom to top.
    static let order = [AppCoordinator.Overlay.offline, AppCoordinator.Overlay.update, AppCoordinator.Overlay.lock]

    private weak var main: UIWindow?
    private var window: UIWindow?
    private let root = CoverRootViewController()

    init(main: UIWindow) {
        self.main = main
    }

    /// Shows `child` under `tag` (replacing the same tag); `key` makes the cover window the key window (the lock: the
    /// keyboard and VoiceOver leave the app below).
    func show(_ child: UIViewController, tag: String, key: Bool) {
        guard let window = ensureWindow() else { return }
        root.remove(tag: tag)
        root.add(child, tag: tag, rank: CoverWindow.order.firstIndex(of: tag) ?? CoverWindow.order.count)
        window.overrideUserInterfaceStyle = main?.overrideUserInterfaceStyle ?? .unspecified
        window.isHidden = false
        if key {
            window.makeKey()
        }
        UIAccessibility.post(notification: .screenChanged, argument: child.view)
    }

    func remove(tag: String) {
        guard root.has(tag) else { return }
        root.remove(tag: tag)
        if root.isEmpty, let window {
            let wasKey = window.isKeyWindow
            window.isHidden = true
            if wasKey {
                main?.makeKey()
            }
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }

    func has(_ tag: String) -> Bool {
        root.has(tag)
    }

    /// The app's «ظاهر» on the cover too (its colours follow the main window's override).
    func syncAppearance() {
        window?.overrideUserInterfaceStyle = main?.overrideUserInterfaceStyle ?? .unspecified
    }

    private func ensureWindow() -> UIWindow? {
        if let window { return window }
        guard let scene = main?.windowScene else { return nil }
        let made = UIWindow(windowScene: scene)
        made.windowLevel = .alert + 1
        made.backgroundColor = .clear
        made.tintColor = main?.tintColor
        made.rootViewController = root
        made.accessibilityIdentifier = "covers"
        window = made
        return made
    }
}

/// The root of the cover window: its children full screen, ordered by rank.
@MainActor
final class CoverRootViewController: UIViewController {
    private var ranks: [String: Int] = [:]

    override func loadView() {
        let view = UIView()
        view.backgroundColor = .clear
        view.semanticContentAttribute = .forceRightToLeft
        self.view = view
    }

    var isEmpty: Bool { ranks.isEmpty }

    func has(_ tag: String) -> Bool {
        ranks[tag] != nil
    }

    func add(_ child: UIViewController, tag: String, rank: Int) {
        loadViewIfNeeded()
        addChild(child)
        child.view.frame = view.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        child.view.accessibilityIdentifier = tag
        child.view.accessibilityViewIsModal = true
        view.addSubview(child.view)
        child.didMove(toParent: self)
        ranks[tag] = rank
        // Above every cover of a lower rank, below the higher ones.
        for other in children.sorted(by: { self.rank(of: $0) < self.rank(of: $1) }) {
            view.bringSubviewToFront(other.view)
        }
        setNeedsStatusBarAppearanceUpdate()
    }

    private func rank(of child: UIViewController) -> Int {
        ranks[child.view.accessibilityIdentifier ?? ""] ?? 0
    }

    func remove(tag: String) {
        for child in children where child.view.accessibilityIdentifier == tag {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        ranks.removeValue(forKey: tag)
        setNeedsStatusBarAppearanceUpdate()
    }

    override var childForStatusBarStyle: UIViewController? {
        children.max { rank(of: $0) < rank(of: $1) }
    }
}
