import TraklyCore
import UIKit
import WebKit

/// The navigation stack of one tab (docs/specs/phase10-apps-and-stores.md D4, §A1, §E2, §E3): a
/// `UINavigationController` of `WebHostViewController`s that mirrors the tab WebView's history. In `stacks` a `page
/// {context: 'push'}` one entry deeper pushes a host and moves the WebView into it, the lower host showing the snapshot
/// of the page as it was; a pop (the back arrow or the edge swipe) runs `go(to:)` back in the WebView and the WebView
/// moves down once the next `page` arrives (≤ 300 ms, else on the timeout). WebKit's own back-forward gestures are off.
/// In `single` the stack keeps one host and a pushed page gets a back button that asks the page (D4: no push
/// transitions).
@MainActor
final class TabStack: NSObject, UINavigationControllerDelegate {
    let key: String
    let nav: UINavigationController
    weak var coordinator: AppCoordinator?
    private(set) weak var panel: Panel?

    /// The WebView history index of this tab's root page.
    private var rootIndex = 0
    /// How deep the stack should be for the WebView's history (1 = the root).
    private(set) var desiredDepth = 1
    /// The stack changes the WebView did not ask for (a user pop) are waiting for the page.
    private var poppingByUser = false
    private var popTimer: Timer?
    private var programmatic = false

    var statusBarStyle: UIStatusBarStyle = .default

    init(key: String, coordinator: AppCoordinator) {
        self.key = key
        self.coordinator = coordinator
        let root = WebHostViewController(stack: nil)
        nav = UINavigationController(rootViewController: root)
        super.init()
        root.stack = self
        nav.delegate = self
        nav.view.semanticContentAttribute = .forceRightToLeft
        nav.navigationBar.semanticContentAttribute = .forceRightToLeft
        nav.navigationBar.prefersLargeTitles = false
        nav.view.backgroundColor = Theme.canvas
    }

    var hosts: [WebHostViewController] {
        nav.viewControllers.compactMap { $0 as? WebHostViewController }
    }

    var top: WebHostViewController? {
        nav.topViewController as? WebHostViewController
    }

    var depth: Int { nav.viewControllers.count }

    /// The WebView of this tab (stacks: its own; single: the shared one while this tab is selected).
    func attach(_ panel: Panel) {
        self.panel = panel
        // The edge swipe back wins over the page's own pan (a page wider than the screen took the swipe now and then).
        let scrollPan = panel.webView.scrollView.panGestureRecognizer
        if let pop = nav.interactivePopGestureRecognizer, !wiredPans.contains(ObjectIdentifier(scrollPan)) {
            wiredPans.insert(ObjectIdentifier(scrollPan))
            scrollPan.require(toFail: pop)
        }
        top?.show(panel.webView)
    }

    /// The WebView pans already set to wait for the edge swipe (`attach` runs again for the same WebView).
    private var wiredPans: Set<ObjectIdentifier> = []

    /// The panel left this stack (LRU destroy, single topology moving away, session end): the hosts keep their images.
    func detachPanel(resetHistory: Bool) {
        if let panel, let top, top.hasWebView, let image = panel.snapshot {
            top.showSnapshot(image)
        }
        panel = nil
        if resetHistory {
            programmatic = true
            nav.setViewControllers(Array(nav.viewControllers.prefix(1)), animated: false)
            programmatic = false
            rootIndex = 0
            desiredDepth = 1
        }
    }

    private var stacked: Bool {
        coordinator?.pool.topology == .stacks
    }

    /// After a `page` (or a history change) of this stack's panel: the stack follows the WebView's history.
    func reconcile(page: PageState.Page?) {
        guard let panel else { return }
        guard stacked else {
            top?.show(panel.webView)
            return
        }
        let index = panel.historyIndex
        let context = page?.context
        if context == "tab" || context == "auth" || context == "standalone" || index < rootIndex {
            rootIndex = index
        }
        let wanted = context == "push" || context == "modal" ? max(1, index - rootIndex + 1) : 1

        if poppingByUser {
            // The user popped: the WebView went back; once its page is here the WebView moves down.
            poppingByUser = false
            popTimer?.invalidate()
            desiredDepth = wanted
            if depth > wanted {
                setDepth(wanted, animated: false)
            }
            top?.show(panel.webView)
            return
        }

        let current = depth
        desiredDepth = wanted
        if wanted > current {
            push(count: wanted - current, panel: panel)
        } else if wanted < current {
            setDepth(wanted, animated: current - wanted == 1)
            top?.show(panel.webView)
        } else {
            top?.show(panel.webView)
        }
    }

    private func push(count: Int, panel: Panel) {
        let lower = top
        lower?.showSnapshot(panel.snapshot)
        var added: [WebHostViewController] = []
        for _ in 0 ..< count {
            added.append(WebHostViewController(stack: self))
        }
        programmatic = true
        if count == 1, let host = added.first {
            host.show(panel.webView)
            coordinator?.prepare(host: host, for: self)
            nav.pushViewController(host, animated: UIView.areAnimationsEnabled)
        } else {
            added.last?.show(panel.webView)
            if let last = added.last {
                coordinator?.prepare(host: last, for: self)
            }
            nav.setViewControllers(nav.viewControllers + added, animated: false)
        }
        programmatic = false
        // At most two snapshots are kept per stack (§E3).
        let all = hosts
        if all.count > 3 {
            for host in all.prefix(all.count - 3) {
                host.dropSnapshot()
            }
        }
    }

    private func setDepth(_ wanted: Int, animated: Bool) {
        let keep = max(1, min(wanted, depth))
        guard keep < depth else { return }
        programmatic = true
        if keep == depth - 1 {
            nav.popViewController(animated: animated)
        } else {
            nav.setViewControllers(Array(nav.viewControllers.prefix(keep)), animated: animated)
        }
        programmatic = false
    }

    // MARK: - UINavigationControllerDelegate

    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController, animated: Bool) {
        if let host = viewController as? WebHostViewController {
            coordinator?.prepare(host: host, for: self)
        }
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        guard !programmatic, stacked, let panel else { return }
        let current = depth
        guard current < desiredDepth else { return }
        // A user pop (the back arrow or the edge swipe): the WebView goes back as many entries.
        let steps = desiredDepth - current
        desiredDepth = current
        let back = panel.webView.backForwardList.backList
        if steps <= back.count {
            poppingByUser = true
            panel.webView.go(to: back[back.count - steps])
            popTimer?.invalidate()
            popTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(Limits.popPageWaitMs) / 1000, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.poppingByUser, let panel = self.panel else { return }
                    self.poppingByUser = false
                    self.top?.show(panel.webView)
                }
            }
        } else {
            top?.show(panel.webView)
        }
        coordinator?.refreshChrome()
    }

    func hostInsetsChanged(_ host: WebHostViewController) {
        guard host === top, let panel else { return }
        coordinator?.sendInsets(panel)
    }
}
