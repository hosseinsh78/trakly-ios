import Network
import TraklyCore
import UIKit
import WebKit

/// The app's brain (docs/specs/phase10-apps-and-stores.md §A1, §A2, §E2, §E3, D4, D37): launch and the launch cover, the
/// tab stacks and their panel WebViews (`stacks` or `single`), the chrome from each document's `page`, the modal, the
/// `auth` / `standalone` collapse and the session end, the incoming shares, universal links and quick actions (the D37
/// merge rule), the offline and update screens, the lock. Main actor only.
@MainActor
final class AppCoordinator: NSObject {
    let window: UIWindow
    let hub = BridgeHub()
    private(set) var pool: WebViewPool!
    private(set) var tabBar: TabBarController!
    private(set) var root: RootViewController!
    private(set) var stacks: [String: TabStack] = [:]
    private(set) var tabs: Tabs.State = Tabs.defaults
    private(set) var selectedTab = "home"
    private(set) var modal: ModalController?
    var modalPanel: Panel? { modal?.panel }
    private var modalReturnUrl: String?

    // The server's switches (`config`, §B4.1).
    private(set) var disabled: [String] = []
    private(set) var minBuild = 0
    private(set) var storeUrl: String?
    private(set) var accountKey: String?

    let intake: IntakeController
    let lock: AppLock
    let files = Downloads()
    let printer = Printer()
    let scanner = Scanner()
    private let pathMonitor = NWPathMonitor()
    private(set) var online = true
    private var launchStartedAt = SystemClock().nowMs()
    private var firstCommitAt: Int64?
    private var coverEnded = false
    /// A `tab` context was seen since the last sign-in page (shares wait for it).
    private(set) var signedIn = false
    private var pendingIncoming: [IncomingLink.Incoming] = []
    private var refreshTimers: [ObjectIdentifier: Timer] = [:]
    private var snapshotTimers: [ObjectIdentifier: Timer] = [:]
    private var scrollObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var lastSentInsets: [ObjectIdentifier: String] = [:]
    let defaults = UserDefaults.standard

    init(window: UIWindow) {
        self.window = window
        intake = IntakeController()
        lock = AppLock(authenticator: Authenticators.make())
        super.init()
        intake.coordinator = self
        lock.coordinator = self
        hub.delegate = self
        let topology = WebViewPool.Topology(rawValue: defaults.string(forKey: Keys.topology) ?? "") ?? .stacks
        pool = WebViewPool(topology: topology, hub: hub, events: self)
        tabs = Tabs.fromJson(defaults.string(forKey: Keys.tabs))
        tabBar = TabBarController(coordinator: self)
        root = RootViewController(tabs: tabBar)
    }

    enum Keys {
        static let topology = "trakly.topology"
        static let tabs = "trakly.tabs"
        static let lastContext = "trakly.lastContext"
        static let lastNight = "trakly.lastNight"
    }

    // MARK: - launch (F4, §E3)

    func start() {
        Appearance.apply(to: window)
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.loadViewIfNeeded()
        root.showOverlay(LaunchCover(night: launchNight), tag: Overlay.launch)
        tabBar.setTabs(tabs, stacks: stack(for:), selected: selectedTab)
        files.cleanUp()
        intake.restore()
        QuickActions.install()

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                self?.networkChanged(satisfied)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "info.trakly.app.path"))

        let primary = pool.acquire(pool.key(for: "home")).panel
        stack(for: "home").attach(primary)
        primary.load(AppConfig.origin + "/app")
        refreshChrome()

        Timer.scheduledTimer(withTimeInterval: TimeInterval(Limits.splashMaxMs) / 1000, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endLaunchCover() }
        }
    }

    /// The tone of the launch cover: night on a first launch and after a night document, else the canvas (§B15).
    private var launchNight: Bool {
        defaults.object(forKey: Keys.lastNight) == nil || defaults.bool(forKey: Keys.lastNight)
    }

    enum Overlay {
        static let launch = "overlay.launch"
        static let offline = "overlay.offline"
        static let update = "overlay.update"
        static let lock = "overlay.lock"
    }

    func endLaunchCover() {
        guard !coverEnded else { return }
        if AppConfig.testArgument("TraklyHoldLaunch") == "1" { return }
        coverEnded = true
        root.removeOverlay(tag: Overlay.launch)
        refreshChrome()
        flushIncoming()
    }

    var launchCoverShown: Bool { !coverEnded }

    var firstCommitAtIsUnset: Bool { firstCommitAt == nil }

    /// The first commit of the selected panel: the cover ends at `ready`, at most 1.5 s later (§B15).
    func markFirstCommit() {
        firstCommitAt = SystemClock().nowMs()
        Timer.scheduledTimer(withTimeInterval: TimeInterval(Limits.splashAfterCommitMs) / 1000, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endLaunchCover() }
        }
    }

    /// A finished load ends a pull to refresh of a page without the bridge.
    func endRefreshingIfNeeded(_ panel: Panel) {
        if !panel.greeted {
            endRefreshing(panel)
        }
    }

    // MARK: - stacks and tabs

    func stack(for key: String) -> TabStack {
        if let existing = stacks[key] {
            return existing
        }
        let created = TabStack(key: key, coordinator: self)
        stacks[key] = created
        return created
    }

    /// The stack whose host shows `panel` now (tab panels), or nil (the modal, print).
    func stack(of panel: Panel) -> TabStack? {
        if pool.topology == .single {
            return panel.key == WebViewPool.singleKey && modal?.panel !== panel ? stacks[selectedTab] : nil
        }
        return stacks[panel.key]
    }

    var selectedStack: TabStack { stack(for: selectedTab) }

    var selectedPanel: Panel? {
        pool.peek(pool.key(for: selectedTab))
    }

    /// Shows `key` (§D4 "Topology"): its WebView is made on first selection (or restored from its URL after an LRU
    /// destroy); `single` moves the one WebView into the tab and sends `tab`.
    func selectTab(_ key: String, userAction: Bool) {
        guard key != Tabs.create else { return }
        let previous = selectedTab
        selectedTab = key
        let stack = stack(for: key)
        tabBar.select(key)

        if pool.topology == .single {
            let (panel, fresh) = pool.acquire(WebViewPool.singleKey)
            stacks[previous]?.detachPanel(resetHistory: false)
            if modal?.panel !== panel {
                stack.attach(panel)
            }
            if fresh {
                panel.load(pool.restoreUrls.removeValue(forKey: WebViewPool.singleKey) ?? AppConfig.origin + Tabs.rootPath(key))
            } else if userAction && previous != key {
                if !panel.send("tab", JSONObject([("key", .string(key)), ("reselect", .bool(false))]), isModal: false) {
                    panel.load(AppConfig.origin + Tabs.rootPath(key))
                }
            }
        } else {
            let keep: Set<String> = [key, previous]
            let (panel, fresh) = pool.acquire(key, keep: keep)
            if stack.panel !== panel {
                stack.attach(panel)
            }
            if fresh {
                panel.load(pool.restoreUrls.removeValue(forKey: key) ?? AppConfig.origin + Tabs.rootPath(key))
            }
            panel.webView.isHidden = false
        }
        refreshChrome()
    }

    /// Re-tapping the selected tab (§B4.2 `tab {reselect: true}`): the page goes to its root, then the top.
    func reselectTab(_ key: String) {
        guard let panel = selectedPanel else { return }
        Haptics.play("selection")
        if !panel.send("tab", JSONObject([("key", .string(key)), ("reselect", .bool(true))]), isModal: false) {
            panel.load(AppConfig.origin + Tabs.rootPath(key))
        }
    }

    /// Shows `url` in `tab` (selected first): a new WebView loads it, a greeted one visits it.
    func visitInTab(_ tab: String, url: String) {
        let key = Tabs.rootPaths.contains { $0.0 == tab } ? tab : "home"
        let existed = pool.peek(pool.key(for: key)) != nil
        if !existed {
            // A new WebView loads the URL itself (not its root first).
            pool.restoreUrls[pool.key(for: key)] = url
        }
        selectTab(key, userAction: false)
        guard let panel = selectedPanel else { return }
        if !existed {
            if panel.currentUrl != url { panel.load(url) }
        } else if panel.currentUrl != url && !panel.send("visit", JSONObject([("url", .string(url))]), isModal: false, callback: { _ in }) {
            panel.load(url)
        }
    }

    // MARK: - chrome (§B1, §E3)

    var resolvedNight: Bool {
        window.traitCollection.userInterfaceStyle == .dark
    }

    /// The chrome of `panel` in its stack.
    func chrome(for panel: Panel, in stack: TabStack) -> PageState.Chrome {
        let lastContext = defaults.string(forKey: Keys.lastContext)
        let coldStartBars = launchCoverShown && lastContext == "tab" && tabs.fromWeb == false && panel.shownPage == nil
        // A tab's first page still loading after a tab switch: the bars stay (they never blink away), with no title.
        let tabLoading = !launchCoverShown && tabs.fromWeb && panel.shownPage == nil && panel !== modal?.panel
            && Tabs.rootPaths.contains { $0.0 == stack.key }
        return PageState.chrome(
            page: panel.shownPage,
            httpError: panel.httpError,
            tabs: tabs,
            coldStartBars: (coldStartBars || tabLoading) && !tabs.items.isEmpty,
            night: resolvedNight,
            canGoBack: stack.depth > 1 || panel.webView.canGoBack
        )
    }

    private func targets(for stack: TabStack) -> ChromePresenter.Targets {
        ChromePresenter.Targets(
            create: UIAction { [weak self] _ in
                Haptics.play("selection")
                self?.compose(sharedUrls: [], fromTab: true)
            },
            search: UIAction { [weak stack] _ in
                stack?.panel?.send("search", isModal: false)
            },
            action: { [weak stack] id in
                UIAction { _ in
                    stack?.panel?.send("action", JSONObject([("id", .string(id))]), isModal: false)
                }
            },
            back: UIAction { [weak self, weak stack] _ in
                guard let panel = stack?.panel else { return }
                self?.pageBack(panel)
            }
        )
    }

    /// The chrome of a host about to show (a push, a pop).
    func prepare(host: WebHostViewController, for stack: TabStack) {
        guard let panel = stack.panel else { return }
        ChromePresenter.apply(chrome(for: panel, in: stack), to: host, stack: stack, targets: targets(for: stack), animated: false)
    }

    /// Draws the chrome of the selected tab (and the modal's bar).
    func refreshChrome(animated: Bool = true) {
        let stack = selectedStack
        if let panel = stack.panel, let host = stack.top {
            let chrome = chrome(for: panel, in: stack)
            ChromePresenter.apply(chrome, to: host, stack: stack, targets: targets(for: stack), animated: animated && !launchCoverShown)
            let hideTabs = !chrome.tabBar || modal != nil
            ChromePresenter.setTabBar(hidden: hideTabs, on: tabBar, animated: animated && !launchCoverShown)
            updateRefreshControl(panel, refreshable: chrome.refreshable)
            sendInsets(panel)
        } else {
            ChromePresenter.setTabBar(hidden: !(tabs.fromWeb || defaults.string(forKey: Keys.lastContext) == "tab"), on: tabBar, animated: false)
        }
        if let modal {
            modal.update(page: modal.panel.shownPage)
            sendInsets(modal.panel)
        }
        root.setNeedsStatusBarAppearanceUpdate()
        stack.nav.setNeedsStatusBarAppearanceUpdate()
        tabBar.setNeedsStatusBarAppearanceUpdate()
    }

    /// `insets {top, bottom}` (§B1, §E3): the safe area for a full-screen page, 0 between the bars and in the modal.
    func sendInsets(_ panel: Panel) {
        guard panel.greeted else { return }
        let insets = insetsFor(panel)
        let key = "\(insets.top)/\(insets.bottom)"
        let id = ObjectIdentifier(panel)
        guard lastSentInsets[id] != key else { return }
        if panel.send("insets", JSONObject([("top", .number(insets.top)), ("bottom", .number(insets.bottom))]), isModal: isModal(panel)) {
            lastSentInsets[id] = key
        }
    }

    func insetsFor(_ panel: Panel) -> (top: Double, bottom: Double) {
        if modal?.panel === panel { return (0, 0) }
        guard let stack = stack(of: panel), let host = stack.top else {
            let insets = window.safeAreaInsets
            return (Double(insets.top), Double(insets.bottom))
        }
        let chrome = chrome(for: panel, in: stack)
        if !chrome.fullScreen { return (0, 0) }
        let insets = window.safeAreaInsets
        _ = host
        return (Double(insets.top), Double(insets.bottom))
    }

    // MARK: - pull to refresh (§E3)

    private var refreshControls: [ObjectIdentifier: UIRefreshControl] = [:]

    private func updateRefreshControl(_ panel: Panel, refreshable: Bool) {
        let id = ObjectIdentifier(panel)
        let scroll = panel.webView.scrollView
        if refreshable {
            let control = refreshControls[id] ?? {
                let made = UIRefreshControl()
                made.addAction(UIAction { [weak self, weak panel] _ in
                    guard let self, let panel else { return }
                    self.pullToRefresh(panel)
                }, for: .valueChanged)
                refreshControls[id] = made
                return made
            }()
            if scroll.refreshControl !== control {
                scroll.refreshControl = control
            }
        } else if scroll.refreshControl != nil, refreshControls[id]?.isRefreshing != true {
            scroll.refreshControl = nil
        }
    }

    private func pullToRefresh(_ panel: Panel) {
        Haptics.play("light")
        if panel.greeted {
            panel.send("refresh", isModal: false)
        } else {
            panel.webView.reload()
        }
        let id = ObjectIdentifier(panel)
        refreshTimers[id]?.invalidate()
        refreshTimers[id] = Timer.scheduledTimer(withTimeInterval: TimeInterval(Limits.refreshMaxMs) / 1000, repeats: false) { [weak self, weak panel] _ in
            MainActor.assumeIsolated {
                guard let panel else { return }
                self?.endRefreshing(panel)
            }
        }
    }

    private func endRefreshing(_ panel: Panel) {
        let id = ObjectIdentifier(panel)
        refreshTimers[id]?.invalidate()
        refreshTimers[id] = nil
        refreshControls[id]?.endRefreshing()
    }

    // MARK: - snapshots (§E3)

    /// Keeps the snapshot of the page on screen fresh: after a `page` and when scrolling settles.
    func scheduleSnapshot(_ panel: Panel, delay: TimeInterval = 0.45) {
        guard pool.topology == .stacks else { return }
        let id = ObjectIdentifier(panel)
        snapshotTimers[id]?.invalidate()
        snapshotTimers[id] = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak panel] _ in
            MainActor.assumeIsolated {
                panel?.takeSnapshot()
            }
        }
        if scrollObservations[id] == nil {
            scrollObservations[id] = panel.webView.scrollView.observe(\.contentOffset, options: []) { [weak self, weak panel] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let panel else { return }
                    let key = ObjectIdentifier(panel)
                    self.snapshotTimers[key]?.invalidate()
                    self.snapshotTimers[key] = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak panel] _ in
                        MainActor.assumeIsolated { panel?.takeSnapshot() }
                    }
                }
            }
        }
    }

    // MARK: - the page's own back (§B4.2 `back`)

    /// The back button of a root host (single, an error page, a form in place): the page first, then the history.
    func pageBack(_ panel: Panel) {
        if panel.greeted, panel.send("back", isModal: isModal(panel), timeout: TimeInterval(Limits.backReplyMs) / 1000, callback: { [weak panel] reply in
            guard let panel, reply?.bool("handled") != true else { return }
            if panel.webView.canGoBack { panel.webView.goBack() }
        }) {
            return
        }
        if panel.webView.canGoBack {
            panel.webView.goBack()
        }
    }

    // MARK: - the modal (S3, §E3)

    func openModal(_ url: String) {
        if let modal {
            if !modal.panel.send("visit", JSONObject([("url", .string(url))]), isModal: true, callback: { _ in }) {
                modal.panel.load(url)
            }
            return
        }
        let panel: Panel
        if pool.topology == .stacks {
            panel = pool.acquire(WebViewPool.modalKey).panel
            panel.load(url)
        } else {
            guard let single = selectedPanel else { return }
            modalReturnUrl = single.currentUrl
            selectedStack.top?.showSnapshot(single.snapshot)
            panel = single
            if !panel.send("visit", JSONObject([("url", .string(url))]), isModal: false, callback: { _ in }) {
                panel.load(url)
            }
        }
        let controller = ModalController(panel: panel, coordinator: self)
        modal = controller
        let presenter = Alerts.top(from: root) ?? root
        presenter?.present(controller.container, animated: true)
        intake.modalChanged()
        refreshChrome()
    }

    /// Closes the modal: `stacks` destroys its WebView; `single` moves the one WebView back to its tab and goes back
    /// (Inertia restores the page and its scroll) or, when the modal was its first entry, visits the remembered URL.
    func closeModal(navigateBack: Bool = true, completion: (() -> Void)? = nil) {
        guard let controller = modal else {
            completion?()
            return
        }
        modal = nil
        let panel = controller.panel
        controller.container.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            if self.pool.topology == .single {
                self.selectedStack.attach(panel)
                if navigateBack {
                    if panel.webView.canGoBack {
                        panel.webView.goBack()
                    } else if let back = self.modalReturnUrl {
                        panel.load(back)
                    }
                }
            } else {
                self.pool.release(WebViewPool.modalKey)
            }
            self.modalReturnUrl = nil
            self.intake.modalChanged()
            self.refreshChrome()
            completion?()
        }
    }

    /// «بستن» or a swipe on the modal (§E3 "Modal"): the dirty confirm, else close.
    func modalBack(fromCloseButton: Bool) {
        guard let controller = modal else { return }
        let panel = controller.panel
        if panel.shownPage?.dirty == true {
            dirtyConfirm(keepDraft: { [weak self] in
                // The page keeps its draft (localStorage) and posts modal.close; without an answer the modal closes.
                let sent = panel.send("back", isModal: true, timeout: TimeInterval(Limits.backReplyMs * 4) / 1000) { reply in
                    if reply?.bool("handled") != true, self?.modal?.panel === panel {
                        self?.closeModal()
                    }
                }
                if !sent { self?.closeModal() }
            }, discard: { [weak self] in
                self?.closeModal()
            })
            return
        }
        closeModal()
    }

    /// «سفارش ذخیره نشده است» with «ادامه ویرایش», «نگه داشتن پیش نویس» and «حذف» (destructive).
    func dirtyConfirm(keepDraft: @escaping () -> Void, discard: @escaping () -> Void) {
        let sheet = Alerts.make(title: L.s("discard_title"), message: nil, style: .actionSheet)
        sheet.addAction(UIAlertAction(title: L.s("discard_keep_draft"), style: .default) { _ in keepDraft() })
        sheet.addAction(UIAlertAction(title: L.s("discard_delete"), style: .destructive) { _ in discard() })
        sheet.addAction(UIAlertAction(title: L.s("discard_keep_editing"), style: .cancel))
        Alerts.top(from: root)?.present(sheet, animated: true)
    }

    /// Runs `action` after the dirty confirm when the modal is dirty, closing the clean (or kept) modal first.
    func afterModal(confirmFirst: Bool, _ action: @escaping () -> Void) {
        guard modal != nil else {
            action()
            return
        }
        if confirmFirst {
            dirtyConfirm(keepDraft: { [weak self] in
                self?.modal?.panel.send("back", isModal: true, timeout: 2) { _ in }
                self?.closeModal(completion: action)
            }, discard: { [weak self] in
                self?.closeModal(completion: action)
            })
        } else {
            closeModal(completion: action)
        }
    }

    // MARK: - `auth` / `standalone` and the session end (§A1)

    private func collapse(_ panel: Panel, page: PageState.Page) {
        if page.context == "auth" {
            signedIn = false
        }
        let others = pool.all.contains { $0 !== panel } || modal != nil
        if page.context == "auth" && (others || stack(of: panel)?.key != "home") && pool.topology == .stacks {
            sessionEnd(from: panel)
            return
        }
        if others {
            closeOverlaysForSessionEnd()
            if pool.topology == .stacks {
                for other in pool.all where other !== panel {
                    pool.release(other.key)
                }
            }
        }
        if pool.topology == .stacks, panel.key != "home", modal?.panel !== panel {
            let from = panel.key
            stacks[from]?.detachPanel(resetHistory: true)
            pool.move(from, to: "home")
            stack(for: "home").attach(panel)
        }
        if selectedTab != "home" {
            selectedTab = "home"
            tabBar.select("home")
        }
        refreshChrome()
    }

    /// A sign-in page while other panels exist: every panel goes, the overlays close, Home loads `/login`; the basket
    /// and the pending shares stay, bound to the account (§A1).
    private func sessionEnd(from: Panel) {
        closeOverlaysForSessionEnd()
        intake.sessionEnded(explicit: false)
        for stack in stacks.values {
            stack.detachPanel(resetHistory: true)
        }
        pool.releaseAll(except: nil)
        selectedTab = "home"
        tabBar.select("home")
        let panel = pool.acquire(pool.key(for: "home")).panel
        stack(for: "home").attach(panel)
        panel.load(AppConfig.origin + "/login")
        refreshChrome()
    }

    private func closeOverlaysForSessionEnd() {
        intake.closeScreens()
        if let controller = modal {
            modal = nil
            controller.container.dismiss(animated: false)
            if pool.topology == .stacks {
                pool.release(WebViewPool.modalKey)
            }
        }
    }

    // MARK: - page messages

    func onPage(_ panel: Panel, _ page: PageState.Page) {
        panel.notePage(page)
        endRefreshing(panel)
        defaults.set(page.night, forKey: Keys.lastNight)

        if page.context == "auth" || page.context == "standalone" {
            if modal?.panel !== panel {
                defaults.set(page.context, forKey: Keys.lastContext)
                collapse(panel, page: page)
            }
            return
        }

        if modal?.panel === panel {
            modal?.update(page: page)
            refreshChrome()
            return
        }

        defaults.set("tab", forKey: Keys.lastContext)
        let firstSignIn = !signedIn
        signedIn = true
        if let stack = stack(of: panel) {
            stack.reconcile(page: page)
        }
        refreshChrome()
        scheduleSnapshot(panel)
        if firstSignIn {
            intake.restoreAfterSignIn()
            flushIncoming()
        }
    }

    func onTabs(_ body: JSONObject) {
        tabs = Tabs.of(body)
        defaults.set(Tabs.toJson(tabs), forKey: Keys.tabs)
        if !tabs.keys.contains(selectedTab) && selectedTab != "home" {
            selectTab("home", userAction: false)
        }
        tabBar.setTabs(tabs, stacks: stack(for:), selected: selectedTab)
        refreshChrome()
    }

    func onConfig(_ body: JSONObject) {
        disabled = body.array("disabled")?.compactMap(\.stringValue) ?? []
        minBuild = body["min"]?.intValue ?? 0
        storeUrl = body.string("storeUrl")
        if let topology = body.string("topology") {
            defaults.set(topology, forKey: Keys.topology)
        }
        let key = body.string("accountKey")
        accountKey = key
        intake.account(key)
        if minBuild > AppConfig.build {
            showUpdate()
        } else {
            root.removeOverlay(tag: Overlay.update)
        }
    }

    private func showUpdate() {
        guard !root.hasOverlay(Overlay.update) else { return }
        root.showOverlay(UpdateRequiredView.controller(storeUrl: storeUrl), tag: Overlay.update)
        endLaunchCover()
    }

    // MARK: - network and errors (S7)

    private func networkChanged(_ satisfied: Bool) {
        let was = online
        online = satisfied
        root.setBanner(visible: !satisfied && !root.hasOverlay(Overlay.offline) && signedIn)
        if satisfied && !was && root.hasOverlay(Overlay.offline) {
            retryAfterOffline()
        }
    }

    func showOffline() {
        let view = OfflineView.controller(noNetwork: !online) { [weak self] in
            self?.retryAfterOffline()
        }
        root.showOverlay(view, tag: Overlay.offline)
        root.setBanner(visible: false)
        endLaunchCover()
    }

    func retryAfterOffline() {
        root.removeOverlay(tag: Overlay.offline)
        let panel = modal?.panel ?? selectedPanel
        if let panel {
            if let url = panel.currentUrl, panel.webView.url == nil || panel.httpError == nil {
                panel.load(url)
            } else {
                panel.webView.reload()
            }
        }
    }

    // MARK: - appearance (§E3)

    func setAppearance(_ mode: String) {
        Appearance.set(mode, on: window)
        broadcastAppearance()
    }

    func broadcastAppearance() {
        let body = JSONObject([("mode", .string(Appearance.mode)), ("resolved", .string(resolvedNight ? "dark" : "light"))])
        for panel in pool.all {
            panel.send("appearance", body, isModal: isModal(panel))
        }
        refreshChrome(animated: false)
    }

    /// The app came to the front or went away (§B4.2 `appState`).
    func appState(active: Bool) {
        for panel in pool.all {
            panel.send("appState", JSONObject([("active", .bool(active))]), isModal: isModal(panel))
        }
    }

    // MARK: - leaving the panel

    func leave(_ url: String) {
        ExternalLinks.open(url, from: Alerts.top(from: root))
    }

    /// `window.open` (§E4): a print view opens the print preview, a panel URL is visited in the opener's tab.
    func windowRequest(_ panel: Panel, url: String) {
        switch NavigationPolicy.classify(url, trusted: AppConfig.origin) {
        case .panel:
            guard let path = NavigationPolicy.pathOf(url) else { return }
            if BridgeMessages.isPrintPath(path) {
                printer.preview(url: url, title: "", from: Alerts.top(from: root), reply: nil)
            } else if !panel.send("visit", JSONObject([("url", .string(url))]), isModal: isModal(panel), callback: { _ in }) {
                panel.load(url)
            }
        case .blocked:
            break
        default:
            leave(url)
        }
    }

    // MARK: - incoming (D37, §E8)

    func receive(_ incoming: IncomingLink.Incoming) {
        if case .shares = incoming {
            // The shares file is read on every activation: the newest reading replaces a waiting one.
            pendingIncoming.removeAll { if case .shares = $0 { return true } else { return false } }
        }
        pendingIncoming.append(incoming)
        flushIncoming()
    }

    private var intakeOn: Bool {
        BridgeMessages.featureOn("intake", features: AppConfig.features, disabled: disabled)
    }

    func flushIncoming() {
        guard coverEnded, !lock.locked else { return }
        let waiting = pendingIncoming
        pendingIncoming = []
        for incoming in waiting {
            let screen = IncomingLink.Screen(
                orderFormOpen: modal.map { BridgeMessages.isOrderFormPath($0.panel.currentPath) } ?? false,
                modalOpen: modal != nil,
                modalDirty: modal?.panel.shownPage?.dirty == true,
                intake: intakeOn,
                shareEntry: BridgeMessages.featureOn("shareEntry", features: AppConfig.features, disabled: disabled),
                signedIn: signedIn
            )
            act(IncomingLink.decide(incoming, screen, trusted: AppConfig.origin), incoming: incoming)
        }
    }

    private func act(_ action: IncomingLink.Action, incoming: IncomingLink.Incoming) {
        switch action {
        case .nothing:
            if case .shares = incoming { PendingShares.clear() }
        case .keep:
            pendingIncoming.append(incoming)
        case let .composer(shared, merge):
            if case .shares = incoming { PendingShares.clear() }
            compose(sharedUrls: shared, fromTab: !merge)
        case let .modal(path, confirmFirst):
            if case .shares = incoming { PendingShares.clear() }
            afterModal(confirmFirst: confirmFirst) { [weak self] in
                self?.openModal(AppConfig.origin + path)
            }
        case let .tab(key, confirmFirst):
            afterModal(confirmFirst: confirmFirst) { [weak self] in
                self?.selectTab(key, userAction: true)
            }
        case let .visit(url, confirmFirst):
            afterModal(confirmFirst: confirmFirst) { [weak self] in
                guard let self else { return }
                let tab = self.tabForPanelUrl(url)
                self.visitInTab(tab, url: url)
            }
        }
    }

    /// The tab of a panel URL (`app.orders.*` → orders, `app.customers.*` → customers, … else home).
    func tabForPanelUrl(_ url: String) -> String {
        let path = NavigationPolicy.pathOf(url) ?? "/app"
        for (key, root) in Tabs.rootPaths where key != "home" && (path == root || path.hasPrefix(root + "/")) {
            return tabs.keys.contains(key) ? key : "home"
        }
        return "home"
    }

    /// S4 (F1): over the open order form in merge mode when one is open (D37), else over the tabs.
    func compose(sharedUrls: [String], fromTab: Bool) {
        let merge = modal.map { BridgeMessages.isOrderFormPath($0.panel.currentPath) } ?? false
        intake.openComposer(shared: sharedUrls, merge: merge)
    }

    func isModal(_ panel: Panel) -> Bool {
        modal?.panel === panel
    }
}
