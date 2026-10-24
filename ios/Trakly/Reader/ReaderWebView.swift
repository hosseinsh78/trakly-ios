import TraklyCore
import UIKit
import WebKit

/// The reader's WebView (docs/specs/phase10-apps-and-stores.md D9, §E5, §I3): its own persistent
/// `WKWebsiteDataStore(forIdentifier:)` (never the panel's default store, never a non-persistent one, which breaks
/// challenges), WebKit's default user agent and headers (nothing changed), no bridge, no user script and no message
/// handler; the generated `trakly-reader.js` runs in the private content world `trakly-reader`. The policy is
/// `Policy.check(url, dev)` on every main-frame URL; downloads, new windows and media capture are refused.
@MainActor
enum ReaderWebView {
    /// The reader's website data store (a fixed identifier: it persists across launches, like a browser profile).
    static let storeId = UUID(uuidString: "6F2D3B1E-6A8B-4C1E-9D2A-7B3F0C5E8A41")!

    static func make() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeId)
        configuration.allowsInlineMediaPlayback = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.dataDetectorTypes = []
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.backgroundColor = Theme.surface
        webView.accessibilityIdentifier = "reader.web"
        #if DEBUG
            webView.isInspectable = true
        #endif
        return webView
    }

    /// The private content world of the reader asset (the page cannot see or change it).
    static let world = WKContentWorld.world(name: "trakly-reader")

    /// «پاک کردن داده سایت ها» (§E5): the reader's whole store goes at the next idle moment (no reader WebView is
    /// alive then); the Trakly session is never touched.
    static func clearShopData(completion: @escaping () -> Void) {
        WKWebsiteDataStore.remove(forIdentifier: storeId) { _ in
            Task { @MainActor in
                completion()
            }
        }
    }

    static var asset: String = {
        guard let url = Bundle.main.url(forResource: "trakly-reader", withExtension: "js"), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return text
    }()

    /// `__trakly_` + 16 random hex characters (`READER_KEY` of `extension/mobile/reader.mjs`).
    static func randomKey() -> String {
        var generator = SystemRandomNumberGenerator()
        let hex = Array("0123456789abcdef")
        return "__trakly_" + String((0 ..< 16).map { _ in hex[Int(generator.next() & 15)] })
    }

    /// Runs one command of the asset in the reader world; the answer is the asset's string (or nil).
    static func run(_ webView: WKWebView, _ command: [String: Any], completion: @escaping (String?) -> Void) {
        guard !asset.isEmpty else {
            completion(nil)
            return
        }
        webView.callAsyncJavaScript("return (" + asset + ")(cmd);", arguments: ["cmd": command], in: nil, in: world) { result in
            MainActor.assumeIsolated {
                switch result {
                case let .success(value): completion(value as? String)
                case .failure: completion(nil)
                }
            }
        }
    }
}
