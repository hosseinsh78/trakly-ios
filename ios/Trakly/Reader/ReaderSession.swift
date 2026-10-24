import TraklyCore
import UIKit
import WebKit

/// One read of S5 (docs/specs/phase10-apps-and-stores.md D9, §E5; the loop of phase 9 D12, D13): the visible reader
/// WebView, the generated asset in its private world, the read loop's stages, a challenge shown to the user with no
/// deadline while he solves it, then the extraction (the Shopify JSON, the capture's size rungs). The result is the
/// capture JSON string in `CaptureStore` under its `readId`. The port of Android's `reader/ReaderSession.kt`.
@MainActor
final class ReaderSession: NSObject {
    enum State: Equatable {
        case reading(stage: ReadLoop.Stage, challenge: Bool, hint: Bool)
        case extracting
        case found
        case failed(reason: String, host: String?, retriable: Bool)
    }

    let readId: String
    let url: String
    private let captures: CaptureStore
    private let limiter: RateLimiter
    var onState: ((ReaderSession) -> Void)?
    var onCaptured: ((ReaderSession) -> Void)?

    private(set) var webView: WKWebView?
    private(set) var state: State = .reading(stage: .opening, challenge: false, hint: false)
    /// The host the page is on now (the chip always shows the real host, §D6).
    private(set) var host: String?

    private enum Phase { case reading, extracting, done, failed, closed }

    private var phase = Phase.reading
    private var generation = 0
    private var loop: ReadLoop?
    private var probing = false
    private var probeAt: Int64 = 0
    private var probeSeq = 0
    private var restarts = 0
    private var ticker: Timer?
    private var watchdog: Timer?
    private var key = ReaderWebView.randomKey()
    private var shopifyKey = ReaderWebView.randomKey()
    private var observation: NSKeyValueObservation?

    /// «محصول پیدا شد» stays this long (§D6).
    static let foundMs: Int64 = 600

    /// Local failures that a fresh read may fix.
    static let retriable: Set<String> = ["timeout", "challenge_timeout", "denied", "site_unreachable", "not_product", "read_failed", "page_gone", "rate"]

    init(readId: String, url: String, captures: CaptureStore, limiter: RateLimiter) {
        self.readId = readId
        self.url = url
        self.captures = captures
        self.limiter = limiter
        host = Policy.hostOf(url)
        super.init()
    }

    private func now() -> Int64 {
        SystemClock().nowMs()
    }

    private var sampleUrls: [String] {
        AppConfig.devPolicy ? Policy.devSampleUrls : Policy.appSampleUrls
    }

    /// Starts (or restarts, «تلاش دوباره») the read.
    func start() {
        generation += 1
        stopTimers()
        probing = false
        destroyWebView()
        restarts = 0
        key = ReaderWebView.randomKey()
        shopifyKey = ReaderWebView.randomKey()

        if !Policy.check(url, dev: AppConfig.devPolicy).ok {
            fail("blocked_url", retriable: false)
            return
        }
        if !limiter.take() {
            fail("rate", retriable: true)
            return
        }
        let view = ReaderWebView.make()
        view.navigationDelegate = self
        view.uiDelegate = self
        webView = view
        observation = view.observe(\.url, options: [.new]) { [weak self] web, _ in
            MainActor.assumeIsolated {
                guard let self, let current = web.url?.absoluteString else { return }
                self.host = Policy.hostOf(current) ?? self.host
                self.loop?.urlChanged(current)
                self.onState?(self)
            }
        }
        loop = ReadLoop(requested: url, clock: { SystemClock().nowMs() }, sampleUrls: sampleUrls, dev: AppConfig.devPolicy)
        phase = .reading
        setState(.reading(stage: .opening, challenge: false, hint: false))
        if let target = URL(string: url) {
            view.load(URLRequest(url: target))
        }
        scheduleTick()
    }

    /// «لغو», a swipe, a session end: everything stops; the WebView goes.
    func close() {
        generation += 1
        phase = .closed
        stopTimers()
        if let view = webView {
            ReaderWebView.run(view, ["op": "clear", "key": key, "skey": shopifyKey]) { _ in }
        }
        destroyWebView()
        onState = nil
        onCaptured = nil
    }

    private func scheduleTick() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: TimeInterval(Limits.pollMs) / 1000, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopTimers() {
        ticker?.invalidate()
        ticker = nil
        watchdog?.invalidate()
        watchdog = nil
    }

    private func tick() {
        guard phase == .reading, let readLoop = loop else { return }
        handle(readLoop.tick())
        guard phase == .reading else { return }
        if probing && now() - probeAt >= Limits.probeStaleMs {
            dropProbe()
        }
        if let view = webView, !probing {
            probing = true
            probeAt = now()
            probeSeq += 1
            let seq = probeSeq
            let gen = generation
            ReaderWebView.run(view, ["op": "probe", "key": key]) { [weak self] text in
                guard let self, seq == self.probeSeq else { return }
                self.probing = false
                guard gen == self.generation, self.phase == .reading else { return }
                let summary = text.flatMap { $0.utf16.count <= Limits.summaryMaxChars ? $0 : nil }
                readLoop.probe(ReadLoop.ProbeResult.of(json: summary))
                self.handle(readLoop.tick())
            }
        }
        scheduleTick()
    }

    private func handle(_ step: ReadLoop.Step) {
        guard phase == .reading else { return }
        switch step {
        case let .continue(stage, challenge, hint):
            let next = State.reading(stage: stage, challenge: challenge, hint: hint)
            if next != state {
                if challenge, case .reading(_, false, _) = state {
                    Haptics.play("warning")
                }
                setState(next)
            }
        case let .product(url, shopifyUrl):
            stopReading()
            extract(url: url, shopifyUrl: shopifyUrl)
        case let .fail(reason, failedHost):
            stopReading()
            fail(reason, retriable: ReaderSession.retriable.contains(reason), host: failedHost)
        }
    }

    private func stopReading() {
        ticker?.invalidate()
        ticker = nil
        dropProbe()
    }

    private func dropProbe() {
        probing = false
        probeSeq += 1
    }

    // MARK: - extraction

    private func extract(url productUrl: String, shopifyUrl: String?) {
        phase = .extracting
        setState(.extracting)
        guard let view = webView else { return pageGone() }
        let gen = generation
        let pageHost = Policy.hostOf(view.url?.absoluteString)
        if let shopifyUrl, let pageHost, Policy.hostOf(shopifyUrl) == pageHost {
            guardStep(gen)
            ReaderWebView.run(view, ["op": "shopify", "skey": shopifyKey, "url": shopifyUrl]) { [weak self] text in
                guard let self, gen == self.generation else { return }
                if text == "started" {
                    self.waitShopify(gen, until: self.now() + Limits.shopifyWaitMs)
                } else {
                    self.capture(rung: 0)
                }
            }
        } else {
            capture(rung: 0)
        }
    }

    private func waitShopify(_ gen: Int, until: Int64) {
        guard let view = webView else { return pageGone() }
        guardStep(gen)
        ReaderWebView.run(view, ["op": "shopify_ready", "skey": shopifyKey]) { [weak self] text in
            guard let self, gen == self.generation else { return }
            if text == "done" || self.now() >= until {
                self.capture(rung: 0)
            } else {
                Timer.scheduledTimer(withTimeInterval: TimeInterval(Limits.shopifyPollMs) / 1000, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, gen == self.generation else { return }
                        self.waitShopify(gen, until: until)
                    }
                }
            }
        }
    }

    /// `op:'capture'` at `rung`: a capture over `LIMITS.captureBytes` climbs the rungs.
    private func capture(rung: Int) {
        guard let view = webView else { return pageGone() }
        let gen = generation
        guardStep(gen)
        ReaderWebView.run(view, ["op": "capture", "key": key, "skey": shopifyKey, "rung": rung]) { [weak self] text in
            guard let self, gen == self.generation else { return }
            self.watchdog?.invalidate()
            guard let text, !text.isEmpty else { return self.pageChanged() }
            if text.utf16.count > Limits.captureMaxChars || Json.utf8Bytes(text) > Limits.captureBytes {
                self.nextRung(rung)
            } else {
                self.done(text)
            }
        }
    }

    private func guardStep(_ gen: Int) {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: TimeInterval(Limits.extractStepMs) / 1000, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation, self.phase == .extracting else { return }
                self.generation += 1
                self.pageChanged()
            }
        }
    }

    private func nextRung(_ rung: Int) {
        if rung < Limits.maxRung {
            capture(rung: rung + 1)
        } else {
            fail("read_failed", retriable: true)
        }
    }

    /// The stored capture vanished (the page reloaded or moved on): read again, at most twice.
    private func pageChanged() {
        guard let view = webView, restarts < 2 else {
            fail("read_failed", retriable: true)
            return
        }
        restarts += 1
        let readLoop = ReadLoop(requested: url, clock: { SystemClock().nowMs() }, sampleUrls: sampleUrls, dev: AppConfig.devPolicy)
        if let current = view.url?.absoluteString {
            readLoop.pageStarted(current)
            if !view.isLoading {
                readLoop.pageFinished(current)
            }
        }
        loop = readLoop
        phase = .reading
        setState(.reading(stage: .loading, challenge: false, hint: false))
        scheduleTick()
    }

    private func done(_ capture: String) {
        watchdog?.invalidate()
        if let view = webView {
            ReaderWebView.run(view, ["op": "clear", "key": key, "skey": shopifyKey]) { _ in }
        }
        phase = .done
        captures.put(readId: readId, url: url, capture: capture)
        Haptics.play("success")
        setState(.found)
        let hold = Int64(AppConfig.testArgument("TraklyFoundHoldMs").flatMap { Int($0) } ?? 0)
        Timer.scheduledTimer(withTimeInterval: TimeInterval(ReaderSession.foundMs + min(max(hold, 0), 10_000)) / 1000, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .done else { return }
                self.onCaptured?(self)
            }
        }
    }

    private func fail(_ reason: String, retriable: Bool, host failedHost: String? = nil) {
        watchdog?.invalidate()
        phase = .failed
        if reason != "rate" {
            Haptics.play("error")
        }
        setState(.failed(reason: reason, host: failedHost ?? loop?.host ?? Policy.hostOf(url), retriable: retriable))
    }

    private func pageGone() {
        generation += 1
        stopReading()
        destroyWebView()
        fail("page_gone", retriable: true)
    }

    private func destroyWebView() {
        observation = nil
        guard let view = webView else { return }
        webView = nil
        loop = nil
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.removeFromSuperview()
    }

    private func setState(_ next: State) {
        state = next
        onState?(self)
    }
}

extension ReaderSession: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let target = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let text = target.absoluteString
        let scheme = target.scheme?.lowercased() ?? ""
        if navigationAction.shouldPerformDownload {
            decisionHandler(.cancel)
            return
        }
        guard let frame = navigationAction.targetFrame else {
            // A pop-up loads in place after the policy check.
            if Policy.check(text, dev: AppConfig.devPolicy).ok {
                webView.load(navigationAction.request)
            } else {
                loop?.refused()
            }
            decisionHandler(.cancel)
            return
        }
        if !frame.isMainFrame {
            let allowed = scheme == "http" || scheme == "https" || text == "about:blank" || text == "about:srcdoc"
            decisionHandler(allowed ? .allow : .cancel)
            return
        }
        if (scheme == "http" || scheme == "https") && Policy.check(text, dev: AppConfig.devPolicy).ok {
            decisionHandler(.allow)
        } else {
            // Non-web schemes are never handed to another app; a refused URL reads like `none` (§D6).
            loop?.refused()
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let current = webView.url?.absoluteString else { return }
        host = Policy.hostOf(current) ?? host
        dropProbe()
        loop?.pageStarted(current)
        onState?(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let current = webView.url?.absoluteString else { return }
        host = Policy.hostOf(current) ?? host
        loop?.pageFinished(current)
        onState?(self)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !Panel.isCancellation(error) else { return }
        let failing = (error as NSError).userInfo[NSURLErrorFailingURLStringErrorKey] as? String ?? webView.url?.absoluteString ?? url
        loop?.mainFrameError(failing)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !Panel.isCancellation(error) else { return }
        loop?.mainFrameError(webView.url?.absoluteString ?? url)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        pageGone()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let target = navigationAction.request.url?.absoluteString, Policy.check(target, dev: AppConfig.devPolicy).ok {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        completionHandler(false)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        completionHandler(nil)
    }
}
