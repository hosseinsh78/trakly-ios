import XCTest

/// The native screenshot set (docs/specs/phase10-apps-and-stores.md §L4), on each device of ios.yml in light and dark
/// (the appearance is set with `simctl ui` before the pass): launch, sign-in on the night scene, Home and Orders with
/// the plus button, a pushed page, a 404 page with the tab bar, More, S4 empty / with the draft row / with a shared
/// link / with a basket / with a failed row / in merge mode, S5 loading / found / challenge / error, S6 with options and
/// with 20+ sizes, the modal form and its keyboard and dirty confirm, Quick Look, the print preview, the scanner's
/// unavailable state, the update and offline screens, the setup wizard and the lock cover. Every shot is an
/// attachment named `<device>-<appearance>-<nn-name>.png`.
final class ScreenshotTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
        StandIn.control("/__test/reset")
    }

    /// Taps `element` once it exists (a screen that did not come is a missing shot, not a crash of the whole pass).
    @discardableResult
    private func tapWhenReady(_ element: XCUIElement, _ timeout: TimeInterval = 20) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        element.tap()
        return true
    }

    private func plus(_ app: XCUIApplication) -> XCUIElement {
        app.navigationBars.buttons["chrome.create"]
    }

    private func openComposer(_ app: XCUIApplication) {
        let button = plus(app)
        if button.waitForExistence(timeout: 15) {
            button.tap()
        }
        _ = app.textFields["composer.link"].waitForExistence(timeout: 10)
    }

    private func type(_ app: XCUIApplication, link: String) {
        let field = app.textFields["composer.link"]
        if field.waitForExistence(timeout: 10) {
            field.tap()
            field.typeText(StandIn.origin + link + "\n")
        }
    }

    private func closeSheets(_ app: XCUIApplication) {
        for _ in 0 ..< 3 {
            if app.buttons["review.cancel"].exists { app.buttons["review.cancel"].tap() }
            if app.buttons["reader.cancel"].exists { app.buttons["reader.cancel"].tap() }
            if app.buttons["reader.close"].exists { app.buttons["reader.close"].tap() }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    func testTheNativeScreens() {
        // 01 launch: the cover held on screen (a Debug hook), night on a first launch.
        let cover = launch(["-TraklyHoldLaunch", "1"])
        shot("01-launch", cover, settle: 2)
        cover.terminate()

        let app = launch(["-TraklyFoundHoldMs", "2500"])
        let username = app.webViews.textFields.firstMatch
        _ = username.waitForExistence(timeout: 25)
        shot("02-login", app)
        signIn(app)
        _ = app.webViews.staticTexts["فروش این ماه"].firstMatch.waitForExistence(timeout: 20)
        shot("03-home", app)

        tapWhenReady(app.tabBars.buttons["سفارش ها"])
        let order = app.webViews.links.containing(NSPredicate(format: "label CONTAINS %@", "مریم احمدی")).firstMatch
        _ = order.waitForExistence(timeout: 40)
        shot("04-orders", app)
        tapWhenReady(order)
        _ = app.webViews.staticTexts["اقلام"].firstMatch.waitForExistence(timeout: 15)
        shot("05-pushed", app)

        // Files and print from the order page.
        let export = app.webViews.buttons["دریافت اکسل"]
        if export.waitForExistence(timeout: 10) {
            export.tap()
            _ = quickLook(app).staticTexts["NR-1160"].firstMatch.waitForExistence(timeout: 20)
            shot("21-quicklook", app, settle: 1)
            closeQuickLook(app)
        }
        let print = app.webViews.buttons["چاپ فاکتور"]
        if print.waitForExistence(timeout: 10) {
            print.tap()
            _ = app.navigationBars["پیش نمایش چاپ"].waitForExistence(timeout: 15)
            shot("22-print", app, settle: 1.5)
            let closePrint = app.buttons["print.close"]
            if closePrint.waitForExistence(timeout: 5) { closePrint.tap() }
        }

        tapWhenReady(app.tabBars.buttons["خانه"])
        let stale = app.webViews.links.containing(NSPredicate(format: "label CONTAINS %@", "یک لینک قدیمی")).firstMatch
        if stale.waitForExistence(timeout: 15) {
            stale.tap()
            _ = app.webViews.staticTexts["این صفحه پیدا نشد"].firstMatch.waitForExistence(timeout: 15)
            shot("06-error-404", app)
            if backButton(app).exists {
                backButton(app).tap()
            }
        }

        tapWhenReady(app.tabBars.buttons["بیشتر"])
        _ = app.webViews.staticTexts["قفل برنامه"].firstMatch.waitForExistence(timeout: 30)
        shot("07-more", app)
        tapWhenReady(app.tabBars.buttons["خانه"])

        // S4, S5, S6.
        openComposer(app)
        shot("08-s4-empty", app)
        type(app, link: "/dev/shop/product-group")
        _ = app.navigationBars["خواندن محصول"].waitForExistence(timeout: 20)
        shot("11-s5-loading", app, settle: 0.6)
        _ = app.descendants(matching: .any)["reader.found"].waitForExistence(timeout: 30)
        shot("11b-s5-found", app, settle: 0.3)
        let add = app.buttons["review.add"]
        _ = add.waitForExistence(timeout: 30)
        shot("12-s6", app, settle: 2)
        if app.buttons["M"].exists { app.buttons["M"].tap() }
        if app.buttons["Ocean Blue"].exists { app.buttons["Ocean Blue"].tap() }
        tapWhenReady(add, 2)
        Thread.sleep(forTimeInterval: 1)
        shot("13-s4-basket", app)

        type(app, link: "/dev/shop/plain")
        _ = app.descendants(matching: .any)["reader.error"].waitForExistence(timeout: 40)
        shot("14-s5-error", app)
        if app.buttons["reader.close"].exists { app.buttons["reader.close"].tap() }
        Thread.sleep(forTimeInterval: 1)
        shot("15-s4-failed", app)

        type(app, link: "/dev/shop/challenge?after=60000")
        _ = app.descendants(matching: .any)["reader.challenge"].waitForExistence(timeout: 30)
        shot("16-s5-challenge", app, settle: 0.5)
        closeSheets(app)

        type(app, link: "/dev/shop/sizes")
        _ = app.buttons["review.add"].waitForExistence(timeout: 45)
        shot("17-s6-sizes", app, settle: 2)
        closeSheets(app)

        // The basket goes to the order form: the modal with its lines.
        let proceed = app.buttons["composer.continue"]
        if proceed.waitForExistence(timeout: 5), proceed.isEnabled {
            proceed.tap()
        } else if app.buttons["composer.close"].exists {
            app.buttons["composer.close"].tap()
        }
        let close = app.navigationBars.buttons["modal.close"]
        _ = close.waitForExistence(timeout: 20)
        _ = app.webViews.staticTexts["اقلام خرید"].firstMatch.waitForExistence(timeout: 20)
        shot("18-modal-form", app, settle: 1.5)
        let note = app.webViews.textViews.firstMatch
        if note.waitForExistence(timeout: 10) {
            note.tap()
            note.typeText("تحویل عصر")
            shot("18b-modal-keyboard", app)
        }
        if close.exists {
            close.tap()
            _ = app.buttons["نگه داشتن پیش نویس"].waitForExistence(timeout: 10)
            shot("19-modal-dirty", app)
            tapWhenReady(app.buttons["ادامه ویرایش"], 3)
        }

        // A share over the open, unsaved form: S4 in merge mode.
        StandIn.control("/__test/share?url=" + (StandIn.origin + "/dev/shop/server-tee").addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)
        XCUIDevice.shared.press(.home)
        app.activate()
        _ = app.buttons["composer.read"].waitForExistence(timeout: 25)
        shot("10-s4-shared", app)
        if tapWhenReady(app.buttons["composer.read"], 2), app.buttons["review.add"].waitForExistence(timeout: 30) {
            if app.buttons["M"].exists { app.buttons["M"].tap() }
            tapWhenReady(app.buttons["review.add"], 2)
        }
        Thread.sleep(forTimeInterval: 1)
        shot("20-s4-merge", app)
        if app.buttons["composer.close"].exists { app.buttons["composer.close"].tap() }
        if app.buttons["نگه داشتن"].waitForExistence(timeout: 3) { app.buttons["نگه داشتن"].tap() }
        if close.waitForExistence(timeout: 5) {
            close.tap()
            if app.buttons["نگه داشتن پیش نویس"].waitForExistence(timeout: 5) { app.buttons["نگه داشتن پیش نویس"].tap() }
        }

        // S4 with the kept draft row.
        openComposer(app)
        _ = app.buttons["composer.draft"].waitForExistence(timeout: 10)
        shot("09-s4-draft", app)
        if app.buttons["composer.close"].exists { app.buttons["composer.close"].tap() }
        if app.buttons["حذف"].waitForExistence(timeout: 3) { app.buttons["حذف"].tap() }

        // The scanner without a camera.
        let product = app.webViews.links["محصول تازه"]
        if product.waitForExistence(timeout: 15) {
            product.tap()
            let scan = app.webViews.buttons["اسکن بارکد"]
            if scan.waitForExistence(timeout: 15) {
                scan.tap()
                _ = app.staticTexts["scan.unavailable"].waitForExistence(timeout: 10)
                shot("23-scan-unavailable", app)
                tapWhenReady(app.buttons["scan.cancel"], 3)
            }
            if app.navigationBars.buttons["modal.close"].waitForExistence(timeout: 5) { app.navigationBars.buttons["modal.close"].tap() }
        }

        // Offline (Trakly unreachable), then the update screen.
        StandIn.control("/__test/down?on=1")
        tapWhenReady(app.tabBars.buttons["مشتریان"])
        _ = app.buttons["offline.retry"].waitForExistence(timeout: 25)
        shot("25-offline", app)
        StandIn.control("/__test/down?on=0")
        tapWhenReady(app.buttons["offline.retry"], 3)
        StandIn.control("/__test/min?value=99")
        app.terminate()
        let update = launch([], reset: false)
        _ = update.staticTexts["update.title"].waitForExistence(timeout: 30)
        shot("24-update", update)
        StandIn.control("/__test/min?value=0")
        update.terminate()

        // The setup wizard (standalone, night).
        StandIn.control("/__test/landing?path=/app/setup")
        let setup = launch()
        signIn(setup)
        _ = setup.webViews.staticTexts["راه اندازی فروشگاه"].firstMatch.waitForExistence(timeout: 20)
        shot("26-setup-wizard", setup)
        setup.terminate()
        StandIn.control("/__test/landing?path=/app")

        // The lock cover (the fake authenticator refuses).
        let lock = launch(["-TraklyLock", "on", "-TraklyFakeAuth", "failure"])
        _ = lock.buttons["lock.open"].waitForExistence(timeout: 15)
        shot("27-lock-cover", lock, settle: 1)
        lock.terminate()
    }

    /// One pass at a large Dynamic Type size (§L4 "Dynamic Type at a large size once").
    func testTheShellAtALargeTextSize() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        signIn(app)
        _ = app.webViews.staticTexts["فروش این ماه"].firstMatch.waitForExistence(timeout: 20)
        shot("large-01-home", app)
        tapWhenReady(app.tabBars.buttons["سفارش ها"])
        _ = app.webViews.links.containing(NSPredicate(format: "label CONTAINS %@", "مریم احمدی")).firstMatch.waitForExistence(timeout: 30)
        shot("large-02-orders", app)
        openComposer(app)
        shot("large-03-s4", app)
        type(app, link: "/dev/shop/server-tee")
        _ = app.buttons["review.add"].waitForExistence(timeout: 30)
        shot("large-04-s6", app, settle: 2)
    }
}
