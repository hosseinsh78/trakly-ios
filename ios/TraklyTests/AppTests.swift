import AVFoundation
import TraklyCore
import WebKit
import XCTest
@testable import Trakly

/// The app's unit tests on the Simulator (docs/specs/phase10-apps-and-stores.md §K5): the Debug build's facts, the
/// generated copy, the bridge's guards with a real WKWebView (a cross-origin iframe's message is dropped; `lock.set`
/// after a `pushState` to `/app/more` without the native prompt answers `cancelled`), the native image fetch rules and
/// the files of `file.save`. The panel stand-in (ios/TraklyUITests/Panel/server.mjs) serves on 127.0.0.1:8000.
@MainActor
final class ConfigTests: XCTestCase {
    func testTheDebugBuildTalksToTheLocalStandIn() {
        XCTAssertEqual(AppConfig.origin, "http://127.0.0.1:8000")
        XCTAssertTrue(AppConfig.devPolicy)
        XCTAssertEqual(AppConfig.store, "dev")
        XCTAssertEqual(AppConfig.version, "1.0.0")
        XCTAssertTrue(AppConfig.userAgentName.hasPrefix("Mobile/15E148 TraklyApp/1.0.0 (ios; "))
        XCTAssertTrue(AppConfig.userAgentName.hasSuffix("; dev)"))
        XCTAssertEqual(Limits.devOrigins.count, 3, "TraklyCore is built with DEBUG in a Debug build")
        XCTAssertEqual(AppConfig.features, BridgeMessages.nativeFeatures)
    }

    func testTheShimIsTheCommittedFileWithTheDebugOrigin() {
        let shim = PanelWebViewFactory.shimSource
        XCTAssertTrue(shim.contains("var ORIGIN = 'http://127.0.0.1:8000';"))
        XCTAssertTrue(shim.contains("__receive"))
        XCTAssertFalse(ReaderWebView.asset.isEmpty)
        XCTAssertTrue(ReaderWebView.asset.hasPrefix("/* Trakly reader asset"))
    }

    func testTheGeneratedCopyHasEveryKeyTheAppUses() {
        let keys = [
            "tab_home", "tab_orders", "tab_customers", "tab_more", "create_action", "bar_search", "bar_back", "bar_close",
            "composer_title", "composer_draft", "composer_hint", "composer_paste", "composer_clip", "composer_shared", "composer_read",
            "composer_basket", "composer_empty", "composer_row_fetching", "composer_row_reading", "composer_row_failed",
            "composer_row_retry", "composer_row_bare", "composer_row_remove", "composer_row_qty", "composer_quick", "composer_blank",
            "composer_continue", "composer_merge", "composer_new_order", "composer_bad_link", "composer_keep_title", "composer_keep",
            "composer_discard", "composer_permission", "basket_kept", "reader_title", "reader_found", "stage_opening", "stage_loading",
            "stage_slow", "stage_extracting", "challenge_title", "challenge_body", "none_hint", "error_title", "error_title_challenge",
            "error_title_not_product", "denied", "site_unreachable", "page_gone", "not_product", "timeout", "challenge_timeout",
            "blocked_url", "rate", "read_failed", "review_title", "review_photo", "review_no_photo", "review_desc", "review_unavailable",
            "review_brand", "review_price", "review_combo_unavailable", "review_qty", "review_add", "review_add_missing", "review_add_next",
            "review_import", "review_import_missing", "review_cancel", "list_separator", "offline_no_network", "offline_no_network_body",
            "offline_unreachable", "offline_retry", "offline_banner", "update_title", "update_body", "update_action", "discard_title",
            "discard_keep_editing", "discard_keep_draft", "discard_delete", "download_failed", "print_title", "print_action",
            "print_share_pdf", "qa_new_order", "qa_quick_order", "qa_orders", "lock_reason", "lock_open", "lock_change_reason",
            "clear_data_title", "clear_data_body", "clear_data_yes", "cancel_dialog", "clear_data_done", "scan_title", "scan_unavailable",
            "cancel", "close", "retry", "qty_more", "qty_less", "camera_denied",
        ]
        let missing = keys.filter { !L.has($0) }
        XCTAssertEqual(missing, [])
        XCTAssertFalse(L.has("webview_update_title"), "an Android-only key never ships to iOS")
        XCTAssertEqual(L.f("composer_continue", Fa.number(3)), "ادامه ثبت سفارش (\u{2068}۳\u{2069})")
    }

    func testTheTokensAndTheFontAreInTheBundle() {
        for name in ["Canvas", "Surface", "Ink", "Brand", "Night", "LaunchBackground", "DangerInk", "AuroraStart"] {
            XCTAssertNotNil(UIColor(named: name), name)
        }
        XCTAssertNotNil(UIFont(name: Theme.regularName, size: 15))
        XCTAssertNotNil(UIFont(name: Theme.boldName, size: 15))
    }
}

/// A delegate that records what the bridge accepted.
@MainActor
final class RecordingDelegate: BridgeDelegate {
    var notified: [String] = []
    var requested: [String] = []
    var confirmations: [String] = []
    var confirmAnswer = false

    var bridgeFeatures: [String] { AppConfig.features }
    var bridgeDisabled: [String] { [] }

    func helloReply(for panel: Panel, path: String) -> JSONObject {
        JSONObject([("platform", .string("ios")), ("version", .string("1.0.0")), ("build", .int(1)), ("store", .string("dev")), ("features", .strings(AppConfig.features)),
                    ("appearance", .object(JSONObject([("mode", .string("system")), ("resolved", .string("light"))]))), ("textScale", .number(1)), ("topology", .string("stacks")),
                    ("insets", .object(JSONObject([("top", .number(0)), ("bottom", .number(0))])))])
    }

    func nativeState(for panel: Panel, type: String) -> BridgeMessages.NativeState { BridgeMessages.NativeState() }

    func confirm(_ type: String, body: JSONObject, from panel: Panel, completion: @escaping (Bool) -> Void) {
        confirmations.append(type)
        completion(confirmAnswer)
    }

    func bridgeRequest(_ type: String, body: JSONObject, from panel: Panel, reply: BridgeReply) {
        requested.append(type)
        reply.ok()
    }

    func bridgeNotify(_ type: String, body: JSONObject, from panel: Panel) {
        notified.append(type)
    }

    func isModal(_ panel: Panel) -> Bool { false }
}

@MainActor
final class BridgeGuardTests: XCTestCase {
    func testTheBridgeAnswersTheMainFrameAndDropsTheIframe() async throws {
        let hub = BridgeHub()
        let delegate = RecordingDelegate()
        hub.delegate = delegate
        let panel = Panel(key: "home", hub: hub, events: nil)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(panel.webView)
        panel.webView.frame = window.bounds
        window.makeKeyAndVisible()
        panel.load("http://127.0.0.1:8000/app/__test/bridge")

        var title = ""
        for _ in 0 ..< 100 {
            try await Task.sleep(nanoseconds: 100_000_000)
            title = panel.webView.title ?? ""
            if title.contains("lock:") { break }
        }
        XCTAssertTrue(title.contains("hello:ok"), title)
        // The pushState to /app/more passes the path rule, then the native prompt (refused here) answers `cancelled`.
        XCTAssertTrue(title.contains("lock:cancelled"), title)
        XCTAssertEqual(delegate.confirmations, ["lock.set"])
        // Only the main frame's hello was accepted: the cross-origin iframe's message never reached the delegate.
        XCTAssertEqual(delegate.notified.filter { $0 == "hello" }.count, 1)
        XCTAssertTrue(panel.greeted)
        panel.destroy()
    }
}

final class ImageFetchTests: XCTestCase {
    func testAFixtureImageIsFetchedReencodedAndCapped() async throws {
        let fetcher = ImageFetcher()
        let fetched = await fetcher.fetch("http://127.0.0.1:8000/dev/shop/img/1.png", dev: true)
        let data = try XCTUnwrap(fetched)
        let image = try XCTUnwrap(UIImage(data: data))
        XCTAssertEqual(image.size.width, 600)
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8], "re-encoded as JPEG")
        let thumbnail = await fetcher.fetch("http://127.0.0.1:8000/dev/shop/img/2.png", dev: true, maxPixels: 120)
        let small = try XCTUnwrap(thumbnail)
        XCTAssertLessThanOrEqual(try XCTUnwrap(UIImage(data: small)).size.width, 120)
    }

    func testThePolicyAndTheBytesRefuse() async {
        let fetcher = ImageFetcher()
        let refused = await fetcher.fetch("http://127.0.0.1:8000/dev/shop/img/1.png", dev: false)
        XCTAssertNil(refused, "a release build never reads a local or plain-http image")
        let notImage = await fetcher.fetch("http://127.0.0.1:8000/dev/shop/not-an-image.png", dev: true)
        XCTAssertNil(notImage, "the image type is checked by its bytes")
        let loopback = await fetcher.fetch("https://127.0.0.1/x.png", dev: false)
        XCTAssertNil(loopback)
    }
}

@MainActor
final class FileTests: XCTestCase {
    func testTheExportFolderIsPrivateAndSweptAfterADay() throws {
        let manager = FileManager.default
        let folder = Downloads.folder.appendingPathComponent("old", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try manager.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86400)], ofItemAtPath: folder.path)
        Downloads().cleanUp()
        XCTAssertFalse(manager.fileExists(atPath: folder.path))
        XCTAssertTrue(Downloads.folder.path.hasPrefix(manager.temporaryDirectory.path))
    }
}

/// Fixer, 2026-10-24 (the iOS review): the denied camera's message, S6's «شرح کالا» rules, the toast window and a page
/// whose WebContent process went away off screen.
@MainActor
final class ReviewFixTests: XCTestCase {
    func testADeniedCameraOnAPhoneThatCanScanSaysWhereToTurnItOn() {
        XCTAssertEqual(Scanner.unavailableKey(supported: true, camera: .denied), "camera_denied")
        XCTAssertEqual(Scanner.unavailableKey(supported: true, camera: .restricted), "camera_denied")
        XCTAssertEqual(Scanner.unavailableKey(supported: true, camera: .authorized), "scan_unavailable")
        XCTAssertEqual(Scanner.unavailableKey(supported: true, camera: .notDetermined), "scan_unavailable")
        // The Simulator and a phone without the hardware: the phone cannot scan, whatever the camera access.
        XCTAssertEqual(Scanner.unavailableKey(supported: false, camera: .denied), "scan_unavailable")
        XCTAssertEqual(L.s("camera_denied"), "اجازه دوربین داده نشد؛ از تنظیمات گوشی آن را روشن کنید.")
    }

    func testTheReviewTitleIsCutAndAnEmptyOneWaits() {
        let long = String(repeating: "Linen ", count: 45)
        let product = Json.object(#"{"url":"https://shop.example.com/p/1","site":"shop.example.com","title":"\#(long)","brand":null,"images":[],"price":null,"currency":null,"options":[],"variants":[]}"#)!
        let state = ReviewState(product: product, line: false)
        XCTAssertLessThanOrEqual(state.title.utf16.count, BridgeMessages.Limit.choiceTitleChars)
        XCTAssertFalse(state.titleMissing)
        state.title = "   "
        XCTAssertTrue(state.titleMissing, "the buttons that add wait for «شرح کالا», as in the web dialog")
        state.title = "x"
        XCTAssertFalse(state.titleMissing)
    }

    func testAToastIsDrawnInItsOwnWindowAboveTheAppAndTakesNoTouch() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let main = try XCTUnwrap(scene.windows.first { !($0 is ToastWindow) && $0.windowLevel == .normal })
        Toast.show(L.s("composer_permission"), in: main)
        let toasts = try XCTUnwrap(scene.windows.compactMap { $0 as? ToastWindow }.first)
        XCTAssertFalse(toasts.isHidden)
        XCTAssertFalse(toasts.isKeyWindow)
        XCTAssertGreaterThan(toasts.windowLevel.rawValue, main.windowLevel.rawValue)
        XCTAssertLessThan(toasts.windowLevel.rawValue, (UIWindow.Level.alert + 1).rawValue, "the lock cover stays above a toast")
        XCTAssertNil(toasts.hitTest(CGPoint(x: 100, y: 100), with: nil), "touches reach the app below")
        XCTAssertTrue(toasts.isUserInteractionEnabled, "a window without user interaction is left out of accessibility")
        let root = try XCTUnwrap(toasts.rootViewController as? ToastRootViewController)
        XCTAssertTrue(root.main === main)
        XCTAssertTrue(root.statusBarSource?.viewIfLoaded?.window === main, "the app's window keeps deciding the status bar")
        func shown() -> [UIView] {
            root.view.subviews.filter { $0.accessibilityIdentifier == "toast" }
        }
        let label = try XCTUnwrap(shown().first as? UILabel)
        XCTAssertEqual(label.text, "شما اجازه ثبت سفارش ندارید.")
        // Fixer, 2026-10-24 (third round): accessibility reads the label's own alpha, which the fade-out used to set to
        // 0 the moment the toast came (VoiceOver and the UI tests never found it).
        XCTAssertEqual(label.alpha, 1, "accessibility sees the toast while it is on screen")
        XCTAssertTrue(label.isAccessibilityElement)
        XCTAssertEqual(label.accessibilityLabel, "شما اجازه ثبت سفارش ندارید.")
        // A second toast replaces the first.
        Toast.show(L.s("rate"), in: main)
        XCTAssertEqual(shown().count, 1)
        XCTAssertNil(label.superview)
        XCTAssertEqual(shown().first?.alpha, 1)
        // Still there a moment before its time is up, then gone with its window.
        try await Task.sleep(nanoseconds: UInt64((Toast.visibleSeconds - 0.6) * 1_000_000_000))
        XCTAssertEqual(shown().count, 1)
        XCTAssertEqual(shown().first?.alpha, 1)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertTrue(shown().isEmpty)
        XCTAssertTrue(toasts.isHidden)
    }

    func testAPageGoneOffScreenTakesNoMessageAndLoadsAgainWhenShown() async throws {
        let hub = BridgeHub()
        let delegate = RecordingDelegate()
        hub.delegate = delegate
        let panel = Panel(key: "orders", hub: hub, events: nil)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(panel.webView)
        panel.webView.frame = window.bounds
        window.isHidden = false
        panel.load("http://127.0.0.1:8000/app/__test/bridge")
        for _ in 0 ..< 100 where !panel.greeted {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(panel.greeted)
        XCTAssertFalse(panel.reloadIfGone(), "nothing to reload while the page is there")

        panel.contentGone()
        XCTAssertFalse(panel.greeted)
        XCTAssertTrue(panel.reloadWhenShown)
        XCTAssertFalse(panel.send("appState", JSONObject([("active", .bool(true))]), isModal: false), "nothing is sent to a page that is gone")

        let document = panel.document
        XCTAssertTrue(panel.reloadIfGone())
        XCTAssertFalse(panel.reloadWhenShown)
        for _ in 0 ..< 100 where panel.document == document {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertGreaterThan(panel.document, document, "the page loaded again")
        XCTAssertFalse(panel.reloadIfGone())
        panel.destroy()
    }
}
