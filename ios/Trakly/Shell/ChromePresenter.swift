import TraklyCore
import UIKit

/// Draws `PageState.Chrome` on a host (docs/specs/phase10-apps-and-stores.md D5, §B1, §E3): the navigation item (the
/// title faded in only while the page's own h1 is out of view, the trailing «ثبت سفارش» plus button on the Home and
/// Orders roots, «جستجو», the page action, a back button when the stack cannot show one), the bars shown or hidden,
/// the status bar style from the tone. The web decides; native renders.
@MainActor
enum ChromePresenter {
    /// The SF Symbol of a page action icon.
    static func symbol(for icon: String) -> UIImage? {
        switch icon {
        case "plus": return UIImage(systemName: "plus")
        case "filter": return UIImage(systemName: "line.3.horizontal.decrease.circle")
        case "share": return UIImage(systemName: "square.and.arrow.up")
        case "print": return UIImage(systemName: "printer")
        default: return UIImage(systemName: "ellipsis.circle")
        }
    }

    struct Targets {
        let create: UIAction
        let search: UIAction
        let action: (String) -> UIAction
        let back: UIAction
    }

    static func apply(_ chrome: PageState.Chrome, to host: WebHostViewController, stack: TabStack, targets: Targets, animated: Bool) {
        let item = host.navigationItem
        item.backButtonDisplayMode = .minimal
        item.largeTitleDisplayMode = .never

        if host.drawnTitle != chrome.title {
            if animated && host.drawnTitle != nil {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.2
                stack.nav.navigationBar.layer.add(fade, forKey: "title")
            }
            item.title = chrome.title
            host.drawnTitle = chrome.title
        }

        var trailing: [UIBarButtonItem] = []
        if chrome.createButton {
            let plus = UIBarButtonItem(title: nil, image: UIImage(systemName: "plus"), primaryAction: targets.create, menu: nil)
            plus.accessibilityLabel = L.s("create_action")
            plus.accessibilityIdentifier = "chrome.create"
            if #available(iOS 26.0, *) {
                plus.style = .prominent
            }
            plus.tintColor = Theme.brand
            trailing.append(plus)
        }
        if chrome.search {
            let search = UIBarButtonItem(title: nil, image: UIImage(systemName: "magnifyingglass"), primaryAction: targets.search, menu: nil)
            search.accessibilityLabel = L.s("bar_search")
            search.accessibilityIdentifier = "chrome.search"
            trailing.append(search)
        }
        if let action = chrome.action {
            let button = UIBarButtonItem(title: nil, image: symbol(for: action.icon), primaryAction: targets.action(action.id), menu: nil)
            button.accessibilityLabel = action.label
            button.accessibilityIdentifier = "chrome.action"
            trailing.append(button)
        }
        item.rightBarButtonItems = trailing

        // The stack shows the system back arrow for a pushed host; a page that needs a back control on the root host
        // (single topology, an error page, a form opened in place) gets one that asks the page first.
        if chrome.backArrow && stack.nav.viewControllers.first === host {
            let back = UIBarButtonItem(title: nil, image: UIImage(systemName: "chevron.backward"), primaryAction: targets.back, menu: nil)
            back.accessibilityLabel = L.s("bar_back")
            back.accessibilityIdentifier = "chrome.back"
            item.leftBarButtonItem = back
        } else {
            item.leftBarButtonItem = nil
        }

        host.setFullScreen(chrome.fullScreen)
        let hideBar = !chrome.navigationBar
        if stack.nav.topViewController === host, stack.nav.isNavigationBarHidden != hideBar {
            stack.nav.setNavigationBarHidden(hideBar, animated: animated)
        }
        stack.statusBarStyle = chrome.lightStatusBar && chrome.fullScreen ? .lightContent : .default
    }

    /// The tab bar shown or hidden (`auth`, `standalone` and the error-free full-screen pages have none).
    static func setTabBar(hidden: Bool, on controller: UITabBarController, animated: Bool) {
        if #available(iOS 18.0, *) {
            if controller.isTabBarHidden != hidden {
                controller.setTabBarHidden(hidden, animated: animated)
            }
        } else if controller.tabBar.isHidden != hidden {
            controller.tabBar.isHidden = hidden
        }
    }
}
