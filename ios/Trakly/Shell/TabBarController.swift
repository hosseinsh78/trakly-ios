import TraklyCore
import UIKit

/// The four tabs (S2, docs/specs/phase10-apps-and-stores.md D12, §E3): a stock `UITabBarController` (Liquid Glass on
/// iOS 26) whose items come from the newest `tabs` message: «خانه», «سفارش ها» (the badge in Persian digits, «۹۹+»),
/// «مشتریان» (or products, payments), «بیشتر»; SF Symbols; right to left. Re-tapping the selected tab sends `tab
/// {reselect: true}` (the page goes to its root, then the top) instead of the stock pop to root. With the owner's opt-in
/// centre item a fifth item opens the composer and is never selected.
@MainActor
final class TabBarController: UITabBarController, UITabBarControllerDelegate {
    weak var coordinator: AppCoordinator?
    private var slots: [String] = []
    private var placeholders: [String: UIViewController] = [:]

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
        delegate = self
        view.semanticContentAttribute = .forceRightToLeft
        tabBar.semanticContentAttribute = .forceRightToLeft
        view.backgroundColor = Theme.canvas
        if #available(iOS 18.0, *) {
            mode = .tabBar
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    /// The key of a slot's view controller.
    func key(of controller: UIViewController) -> String? {
        guard let index = viewControllers?.firstIndex(where: { $0 === controller }), index < slots.count else { return nil }
        return slots[index]
    }

    var selectedKey: String? {
        guard let selected = selectedViewController else { return nil }
        return key(of: selected)
    }

    /// The slots of `state` with their stacks; keeps the selection when the key is still there.
    func setTabs(_ state: Tabs.State, stacks: (String) -> TabStack, selected: String) {
        let wanted = Tabs.slots(state)
        var controllers: [UIViewController] = []
        for key in wanted {
            let controller: UIViewController
            if key == Tabs.create {
                controller = placeholders[key] ?? UIViewController()
                placeholders[key] = controller
            } else {
                controller = stacks(key).nav
            }
            let item = state.items.first { $0.key == key }
            let label = (item?.label.isEmpty == false ? item?.label : nil) ?? L.s(key == Tabs.create ? "tab_create" : Tabs.copyKey(key))
            let symbol = Tabs.symbol(key)
            let tabItem = UITabBarItem(title: label, image: UIImage(systemName: symbol), selectedImage: UIImage(systemName: key == Tabs.create ? symbol : symbol + ".fill"))
            tabItem.accessibilityIdentifier = "tab." + key
            if let badge = item?.badge, badge > 0 {
                tabItem.badgeValue = Tabs.badgeText(badge)
            }
            controller.tabBarItem = tabItem
            controllers.append(controller)
        }
        if wanted != slots || viewControllers?.count != controllers.count {
            slots = wanted
            setViewControllers(controllers, animated: false)
        }
        if let index = slots.firstIndex(of: selected), selectedIndex != index {
            selectedIndex = index
        }
    }

    func select(_ key: String) {
        if let index = slots.firstIndex(of: key), selectedIndex != index {
            selectedIndex = index
        }
    }

    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        guard let key = key(of: viewController) else { return false }
        if key == Tabs.create {
            Haptics.play("selection")
            coordinator?.compose(sharedUrls: [], fromTab: true)
            return false
        }
        if viewController === selectedViewController {
            coordinator?.reselectTab(key)
            return false
        }
        Haptics.play("selection")
        coordinator?.selectTab(key, userAction: true)
        return false
    }

    override var childForStatusBarStyle: UIViewController? {
        (selectedViewController as? UINavigationController)?.topViewController
    }
}

/// The window's root (§E3): the tab bar controller, the launch cover above it and the slim offline banner over the
/// content. The offline and update screens and the lock cover are in their own window above everything (CoverWindow).
@MainActor
final class RootViewController: UIViewController {
    let tabs: TabBarController
    private let overlays = UIView()
    private let banner = UILabel()
    private var bannerVisible = false
    /// The light or dark trait changed (the system appearance with «ظاهر» = system, §E3).
    var onStyleChange: (() -> Void)?

    init(tabs: TabBarController) {
        self.tabs = tabs
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.canvas
        view.semanticContentAttribute = .forceRightToLeft
        addChild(tabs)
        tabs.view.frame = view.bounds
        tabs.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(tabs.view)
        tabs.didMove(toParent: self)

        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.attributedText = FaText.attributed(L.s("offline_banner"), size: 13, bold: true, color: Theme.warningInk)
        banner.textAlignment = .center
        banner.numberOfLines = 0
        banner.backgroundColor = Theme.warningSoft
        banner.isHidden = true
        banner.accessibilityIdentifier = "offline.banner"
        view.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            banner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            banner.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])

        overlays.frame = view.bounds
        overlays.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlays.isUserInteractionEnabled = true
        overlays.backgroundColor = .clear
        view.addSubview(overlays)
        overlays.isHidden = true

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: RootViewController, _: UITraitCollection) in
            controller.onStyleChange?()
        }
    }

    /// A full-screen layer above the tabs (the launch cover); the newest is on top.
    func showOverlay(_ child: UIViewController, tag: String) {
        removeOverlay(tag: tag)
        addChild(child)
        child.view.frame = overlays.bounds
        child.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        child.view.accessibilityIdentifier = tag
        child.view.tag = tag.hashValue
        overlays.addSubview(child.view)
        child.didMove(toParent: self)
        overlays.isHidden = false
        setNeedsStatusBarAppearanceUpdate()
    }

    func removeOverlay(tag: String) {
        for child in children where child !== tabs && child.view.accessibilityIdentifier == tag {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        overlays.isHidden = overlays.subviews.isEmpty
        setNeedsStatusBarAppearanceUpdate()
    }

    func hasOverlay(_ tag: String) -> Bool {
        children.contains { $0 !== tabs && $0.view.accessibilityIdentifier == tag }
    }

    func setBanner(visible: Bool) {
        guard visible != bannerVisible else { return }
        bannerVisible = visible
        banner.isHidden = !visible
        view.bringSubviewToFront(banner)
        view.bringSubviewToFront(overlays)
    }

    override var childForStatusBarStyle: UIViewController? {
        children.last { $0 !== tabs } ?? tabs
    }
}
