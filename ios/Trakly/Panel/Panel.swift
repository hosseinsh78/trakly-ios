import TraklyCore
import UIKit
import WebKit

/// What the shell hears from one panel WebView's navigation (docs/specs/phase10-apps-and-stores.md §B1, §E3, §E4).
@MainActor
protocol PanelEvents: AnyObject {
    func panelDocumentStarted(_ panel: Panel)
    func panelDocumentCommitted(_ panel: Panel)
    func panelDocumentFinished(_ panel: Panel)
    func panelMainFrameFailed(_ panel: Panel, error: Error)
    func panelHistoryChanged(_ panel: Panel)
    func panelLeave(_ panel: Panel, url: String, target: NavigationPolicy.Target)
    func panelWindowRequest(_ panel: Panel, url: String)
    func panelContentProcessTerminated(_ panel: Panel)
    func panelDownload(_ panel: Panel, download: WKDownload)
    func panelPresenter(_ panel: Panel) -> UIViewController?
    func panelWillBeDestroyed(_ panel: Panel)
}

/// One panel WKWebView and what native knows about its current document (§B1, §B4, §B5): the newest `page`, the main
/// frame's HTTP status, whether the document was greeted, and the open native → web requests.
@MainActor
final class Panel: NSObject {
    /// `home`, `orders` … (a tab stack), `modal`, or `single` (the one WebView of the `single` topology).
    var key: String
    let webView: WKWebView
    weak var events: PanelEvents?
    private weak var hub: BridgeHub?

    /// The newest `page` of the current document (nil until it sends one).
    var page: PageState.Page?
    /// The page of the previous document, shown until the new one sends its own (no flicker on a full load).
    var carriedPage: PageState.Page?
    /// The main frame's HTTP status when it was ≥ 400 (a Laravel error page, §B1 a).
    var httpError: Int?
    /// Increments at every main-frame commit (a new document).
    private(set) var document = 0
    private var greetedDocument = -1
    /// The origin of the committed document.
    private(set) var committedOrigin: String?
    private(set) var loading = false
    private(set) var loadStartedAt: Int64 = 0
    var ready = false
    private(set) var destroyed = false
    /// The last snapshot of the page on screen (the lower host of a push shows it, §E3).
    var snapshot: UIImage?
    /// The URL to restore when this panel was destroyed (LRU, §A1).
    var lastUrl: String?
    private var pending: [String: (type: String, timer: Timer?, callback: (JSONObject?) -> Void)] = [:]
    private var observations: [NSKeyValueObservation] = []
    private var pageWait: Timer?

    init(key: String, hub: BridgeHub, events: PanelEvents?) {
        self.key = key
        self.hub = hub
        self.events = events
        webView = PanelWebViewFactory.make(bridge: hub)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        hub.register(self)
        observations.append(webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lastUrl = self.webView.url?.absoluteString ?? self.lastUrl
                self.events?.panelHistoryChanged(self)
            }
        })
    }

    /// Whether the current document sent `hello` and got its reply.
    var greeted: Bool { greetedDocument == document }

    func greet() {
        greetedDocument = document
    }

    /// The path of `webView.url`, read now (§B5 "Path").
    var currentPath: String {
        NavigationPolicy.pathOf(webView.url?.absoluteString) ?? ""
    }

    var currentUrl: String? {
        webView.url?.absoluteString ?? lastUrl
    }

    /// `backForwardList.backList.count`: the position of the current entry in the WebView's history.
    var historyIndex: Int {
        webView.backForwardList.backList.count
    }

    /// The page the chrome follows: the newest of this document, else the previous document's while the new one loads.
    var shownPage: PageState.Page? {
        // An error document (HTTP ≥ 400) never sends a page: it gets the error chrome, not the previous page's (§B1 a).
        page ?? (httpError == nil ? carriedPage : nil)
    }

    func load(_ url: String) {
        guard let target = URL(string: url) else { return }
        lastUrl = url
        webView.load(URLRequest(url: target))
    }

    // MARK: - navigation state

    func navigationStarted() {
        loading = true
        loadStartedAt = SystemClock().nowMs()
        httpError = nil
    }

    func navigationCommitted() {
        document += 1
        ready = false
        committedOrigin = NavigationPolicy.originOf(webView.url?.absoluteString)
        if page != nil {
            carriedPage = page
        }
        page = nil
        failAllPending()
    }

    func navigationFinished() {
        loading = false
        // A document that sends no `page` within the hello window loses the previous document's chrome (§B1).
        pageWait?.invalidate()
        pageWait = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.page == nil, self.carriedPage != nil else { return }
                self.carriedPage = nil
                self.events?.panelHistoryChanged(self)
            }
        }
    }

    func navigationFailed() {
        loading = false
    }

    func notePage(_ page: PageState.Page) {
        self.page = page
        carriedPage = nil
    }

    // MARK: - native → web (§B4.2, §B5)

    /// The target facts of `checkNativeSend`.
    private func target(isModal: Bool) -> BridgeMessages.SendTarget {
        BridgeMessages.SendTarget(webView: isModal ? "modal" : "tab", origin: committedOrigin ?? "", path: currentPath, greeted: greeted)
    }

    /// A native → web request (`callback` gets the page's reply body, or nil on a timeout or a gone document, exactly
    /// once) or event. False when it was not sent (the guards of §B5 refuse it now): then `callback` is not called.
    @discardableResult
    func send(_ type: String, _ body: JSONObject = JSONObject(), isModal: Bool, timeout: TimeInterval = 15, callback: ((JSONObject?) -> Void)? = nil) -> Bool {
        if destroyed { return false }
        let spec = BridgeMessages.spec(type)
        let id = spec?.kind == .request ? BridgeMessages.nextId() : nil
        let raw = BridgeMessages.nativeMessage(type, id: id, body)
        if BridgeMessages.checkNativeSend(raw, target(isModal: isModal), trusted: AppConfig.origin) != nil {
            return false
        }
        if let id, let callback {
            let timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.resolve(id, nil)
                }
            }
            pending[id] = (type: type, timer: timer, callback: callback)
        }
        deliver(raw)
        return true
    }

    /// One JSON string to the page's `TraklyNative` (a native message, or a late reply of `BridgeReply`).
    func deliver(_ raw: String) {
        guard !destroyed, committedOrigin == AppConfig.origin else { return }
        webView.callAsyncJavaScript("window.TraklyNative && window.TraklyNative.__receive(m)", arguments: ["m": raw], in: nil, in: .page, completionHandler: nil)
    }

    /// A page reply to a native request (`re`), checked by type.
    func answer(_ re: String, _ body: JSONObject) {
        guard let open = pending[re] else { return }
        resolve(re, BridgeMessages.isPageReply(open.type, body) ? body : nil)
    }

    private func resolve(_ id: String, _ body: JSONObject?) {
        guard let open = pending.removeValue(forKey: id) else { return }
        open.timer?.invalidate()
        open.callback(body)
    }

    private func failAllPending() {
        for id in Array(pending.keys) {
            resolve(id, nil)
        }
    }

    /// Open native requests (a destroyed WebView retries the next candidate, §B4.3).
    var openRequests: Int { pending.count }

    // MARK: - snapshots (§E3: the lower host of a push shows the page as it was)

    func takeSnapshot(completion: (() -> Void)? = nil) {
        guard !destroyed, webView.window != nil, webView.bounds.width > 0, !loading else {
            completion?()
            return
        }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            MainActor.assumeIsolated {
                if let image { self?.snapshot = image }
                completion?()
            }
        }
    }

    // MARK: - end of life

    func destroy() {
        if destroyed { return }
        destroyed = true
        failAllPending()
        pageWait?.invalidate()
        observations.removeAll()
        hub?.unregister(self)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.configuration.userContentController.removeAllUserScripts()
        webView.removeFromSuperview()
    }
}
