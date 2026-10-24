import TraklyCore
import UIKit
import WebKit

/// The navigation and UI rules of every panel WKWebView (docs/specs/phase10-apps-and-stores.md §B7, §E4, D13, D23):
/// `TraklyCore.NavigationPolicy` on every main-frame navigation (panel paths stay; other same-origin pages and other
/// https sites open in the in-app browser; `/admin*` in the system browser; `tel:` / `mailto:` through the system;
/// everything else is cancelled), `window.open` routed by the same policy (never a second WebView), a file the page
/// cannot show becomes a download, media capture is denied (scanning is native), JS dialogs are alerts.
extension Panel: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        let text = url.absoluteString
        guard let frame = navigationAction.targetFrame else {
            // A new window (target=_blank, window.open): routed by the policy, never a second WebView.
            events?.panelWindowRequest(self, url: text)
            decisionHandler(.cancel)
            return
        }
        if !frame.isMainFrame {
            // Subframes are not policed (Android the same); a non-web scheme never loads.
            let scheme = url.scheme?.lowercased() ?? ""
            decisionHandler(["http", "https", "about", "blob", "data"].contains(scheme) ? .allow : .cancel)
            return
        }
        if navigationAction.shouldPerformDownload {
            decisionHandler(NavigationPolicy.classify(text, trusted: AppConfig.origin) == .panel ? .download : .cancel)
            return
        }
        switch NavigationPolicy.classify(text, trusted: AppConfig.origin) {
        case .panel:
            decisionHandler(.allow)
        case .blocked:
            decisionHandler(.cancel)
        case let target:
            events?.panelLeave(self, url: text, target: target)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse {
            httpError = http.statusCode >= 400 ? http.statusCode : nil
            let disposition = (http.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
            if disposition.hasPrefix("attachment") || !navigationResponse.canShowMIMEType {
                // A file the page cannot show (the fallback; the link interceptor normally asks `download`, §E9).
                decisionHandler(NavigationPolicy.classify(http.url?.absoluteString ?? "", trusted: AppConfig.origin) == .panel ? .download : .cancel)
                return
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        events?.panelDownload(self, download: download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        events?.panelDownload(self, download: download)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationStarted()
        events?.panelDocumentStarted(self)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        navigationCommitted()
        events?.panelDocumentCommitted(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        navigationFinished()
        lastUrl = webView.url?.absoluteString ?? lastUrl
        events?.panelDocumentFinished(self)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed()
        if !Panel.isCancellation(error) {
            events?.panelMainFrameFailed(self, error: error)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed()
        if !Panel.isCancellation(error) {
            events?.panelMainFrameFailed(self, error: error)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        events?.panelContentProcessTerminated(self)
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Only the system's trust evaluation; an invalid certificate is never accepted.
        completionHandler(.performDefaultHandling, nil)
    }

    /// A cancelled navigation (a new one replaced it, or a policy cancel) and the "frame load interrupted" of a
    /// download are not failures.
    static func isCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return true }
        if nsError.domain == "WebKitErrorDomain" && (nsError.code == 102 || nsError.code == 204) { return true }
        return false
    }

    // MARK: - WKUIDelegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url?.absoluteString {
            events?.panelWindowRequest(self, url: url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        guard let presenter = events?.panelPresenter(self) else {
            completionHandler()
            return
        }
        let alert = Alerts.make(title: nil, message: message)
        alert.addAction(UIAlertAction(title: L.ok, style: .default) { _ in completionHandler() })
        presenter.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let presenter = events?.panelPresenter(self) else {
            completionHandler(false)
            return
        }
        let alert = Alerts.make(title: nil, message: message)
        alert.addAction(UIAlertAction(title: L.s("cancel_dialog"), style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: L.ok, style: .default) { _ in completionHandler(true) })
        presenter.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        guard let presenter = events?.panelPresenter(self) else {
            completionHandler(nil)
            return
        }
        let alert = Alerts.make(title: nil, message: prompt)
        alert.addTextField { field in
            field.text = defaultText
            field.textAlignment = .natural
        }
        alert.addAction(UIAlertAction(title: L.s("cancel_dialog"), style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: L.ok, style: .default) { [weak alert] _ in completionHandler(alert?.textFields?.first?.text) })
        presenter.present(alert, animated: true)
    }
}
