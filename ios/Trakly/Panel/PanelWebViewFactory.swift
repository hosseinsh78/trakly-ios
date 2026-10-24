import TraklyCore
import UIKit
import WebKit

/// The ONLY place a panel WKWebView is made (docs/specs/phase10-apps-and-stores.md D7, §B1, §B2, §E4): the default
/// data store (the Trakly session), WebKit's own user agent plus the app token, the bridge shim at document start in
/// the page world and the `trakly` message handler with reply. The reader has its own WebView with none of these
/// (Reader/ReaderWebView.swift). `ios/tools/source.check.mjs` proves `applicationNameForUserAgent` and
/// `addScriptMessageHandler` appear nowhere else.
@MainActor
enum PanelWebViewFactory {
    /// The shim with this build's origin (a Debug build's local origin replaces the Release literal).
    static let shimSource: String = {
        guard let url = Bundle.main.url(forResource: "BridgeShim", withExtension: "js"), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return text.replacingOccurrences(of: "var ORIGIN = 'https://erp.trakly.info';", with: "var ORIGIN = '\(AppConfig.origin)';")
    }()

    /// The panel pages follow the system text size (fixer 2026-10-24, the iOS side of §D5 "Text size", where Android
    /// sets `textZoom` 100–130 from the font scale): the body text's Dynamic Type scale, at least 1, at most 1.3, applied
    /// to the page's text only (`-webkit-text-size-adjust` on the root, as WebKit's own text size does; the layout keeps
    /// the screen width, a page zoom would not reflow). The print WebView keeps 100 % (paper does not follow the phone).
    static func textScale() -> CGFloat {
        let scale = UIFontMetrics(forTextStyle: .body).scaledValue(for: 100) / 100
        return (min(max(scale, 1), 1.3) * 100).rounded() / 100
    }

    /// The document-start script that sets the text size (CSSOM, so the page's CSP does not apply to it).
    static func textSizeSource(_ scale: CGFloat) -> String {
        let percent = Int((scale * 100).rounded())
        return "(function(){var s=document.documentElement.style;s.setProperty('-webkit-text-size-adjust','\(percent)%','important');s.setProperty('text-size-adjust','\(percent)%','important');})();"
    }

    /// A new text size for a live panel WebView: its next documents (the user scripts again) and the one on screen.
    static func applyTextSize(_ scale: CGFloat, to webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: shimSource, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        controller.addUserScript(WKUserScript(source: textSizeSource(scale), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        webView.evaluateJavaScript(textSizeSource(scale), in: nil, in: .page) { _ in }
    }

    /// A panel WebView. `bridge` nil: a WebView of the panel without the bridge (the offscreen print WebView, §E9).
    static func make(bridge: BridgeHub?) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = AppConfig.userAgentName
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.dataDetectorTypes = []
        configuration.suppressesIncrementalRendering = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let controller = WKUserContentController()
        if let bridge {
            controller.addUserScript(WKUserScript(source: shimSource, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
            controller.addUserScript(WKUserScript(source: textSizeSource(textScale()), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
            controller.addScriptMessageHandler(WeakMessageHandler(bridge), contentWorld: .page, name: "trakly")
        }
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        #if DEBUG
            webView.isInspectable = true
        #endif
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.keyboardDismissMode = .interactive
        webView.underPageBackgroundColor = Theme.canvas
        webView.backgroundColor = Theme.canvas
        webView.isOpaque = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        return webView
    }
}

/// A weak proxy: WKUserContentController keeps its message handlers strongly, which would keep the hub (and through it
/// every panel) alive.
@MainActor
final class WeakMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    private weak var target: BridgeHub?

    init(_ target: BridgeHub) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let target else {
            replyHandler(nil, nil)
            return
        }
        target.receive(message, replyHandler: replyHandler)
    }
}
