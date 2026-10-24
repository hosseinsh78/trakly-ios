import XCTest

/// The XCUITest flows (docs/specs/phase10-apps-and-stores.md §K5): right to left on an English Simulator, the tabs and
/// the plus button on the Home and Orders roots only, a push with the back arrow and the edge swipe, the modal's dirty
/// confirm and «نگه داشتن پیش نویس», the composer → reader on a fixture shop → review → the order form, a server read
/// straight to the review, a shared link that waits for «خواندن», a share over an open unsaved order form (merge mode),
/// an error page keeping the tab bar, the offline and update screens, the lock through the fake authenticator, the
/// scanner's unavailable state, files and print, «پاک کردن داده سایت ها» and the single topology. Fixer, 2026-10-24: the
/// lock cover above an open order form, the lock without a device passcode, a swipe down on S4, S5 and S6, a merge
/// into the quick order form, a quick action over S4 in merge mode, and the pages following the system appearance.
final class FlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        StandIn.control("/__test/reset")
    }

    private func tab(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.tabBars.buttons[label]
    }

    private var plus: (XCUIApplication) -> XCUIElement {
        { app in app.navigationBars.buttons["chrome.create"] }
    }

    func testLaunchSignInAndTabs() {
        let app = launch(["-AppleLanguages", "(en)", "-AppleLocale", "en_US"])
        signIn(app)
        wait(app.tabBars.firstMatch, 25)
        let home = tab(app, "خانه")
        let more = tab(app, "بیشتر")
        wait(home)
        wait(more)
        // Right to left on an English Simulator: the first tab is at the right.
        XCTAssertGreaterThan(home.frame.minX, more.frame.minX)
        wait(plus(app), 10)
        tab(app, "سفارش ها").tap()
        wait(app.webViews.staticTexts["سفارش ها"].firstMatch, 15)
        XCTAssertTrue(plus(app).waitForExistence(timeout: 5))
        tab(app, "مشتریان").tap()
        wait(app.webViews.staticTexts["مشتریان"].firstMatch, 15)
        XCTAssertFalse(plus(app).waitForExistence(timeout: 2))
        more.tap()
        wait(app.webViews.staticTexts["قفل برنامه"].firstMatch, 15)
        XCTAssertFalse(plus(app).exists)
    }

    func testPushAndTheEdgeSwipe() {
        let app = launch()
        signIn(app)
        tab(app, "سفارش ها").tap()
        let order = app.webViews.links.containing(NSPredicate(format: "label CONTAINS %@", "مریم احمدی")).firstMatch
        wait(order, 20)
        order.tap()
        let back = app.navigationBars.buttons.element(boundBy: 0)
        wait(app.webViews.staticTexts["اقلام"].firstMatch, 15)
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        wait(order, 10)
        order.tap()
        wait(app.webViews.staticTexts["اقلام"].firstMatch, 15)
        // The interactive pop starts from the right edge in right to left (after the push animation has ended; once more
        // if the first drag came too early).
        Thread.sleep(forTimeInterval: 1)
        for _ in 0 ..< 2 where !order.exists {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.998, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)), withVelocity: .fast, thenHoldForDuration: 0.05)
            _ = order.waitForExistence(timeout: 5)
        }
        wait(order, 5)
    }

    func testTheModalDirtyConfirmKeepsADraft() {
        let app = launch()
        signIn(app)
        let quick = app.webViews.links["سفارش سریع"]
        wait(quick, 20)
        quick.tap()
        let close = app.navigationBars.buttons["modal.close"]
        wait(close, 15)
        let note = app.webViews.textViews.firstMatch
        wait(note, 15)
        note.tap()
        note.typeText("تحویل عصر")
        close.tap()
        let keep = app.buttons["نگه داشتن پیش نویس"]
        wait(keep, 10)
        keep.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 10))
        plus(app).tap()
        let draft = app.buttons["composer.draft"]
        wait(draft, 15)
        draft.tap()
        wait(close, 15)
        let restored = app.webViews.textViews.firstMatch
        wait(restored, 15)
        XCTAssertEqual(restored.value as? String, "تحویل عصر")
    }

    func testComposerReaderReviewAndTheOrderForm() {
        // The found state held 1.5 s, so the reader is on screen long enough to be seen by the test.
        let app = launch(["-TraklyFoundHoldMs", "1500"])
        signIn(app)
        wait(plus(app), 20)
        plus(app).tap()
        let link = app.textFields["composer.link"]
        wait(link, 10)
        link.tap()
        link.typeText(StandIn.origin + "/dev/shop/product-group\n")
        // The server refuses the shop: the reader opens by itself and reads the fixture page.
        wait(app.navigationBars["خواندن محصول"], 20)
        let add = app.buttons["review.add"]
        wait(add, 45)
        app.buttons["M"].tap()
        app.buttons["Ocean Blue"].tap()
        add.tap()
        wait(app.descendants(matching: .any)["composer.line"].firstMatch, 15)
        let proceed = app.buttons["composer.continue"]
        XCTAssertTrue(proceed.isEnabled)
        proceed.tap()
        wait(app.navigationBars.buttons["modal.close"], 20)
        wait(app.webViews.staticTexts["Aurora Linen Shirt"].firstMatch, 30)
    }

    func testAServerReadGoesStraightToTheReview() {
        let app = launch()
        signIn(app)
        plus(app).tap()
        let link = app.textFields["composer.link"]
        wait(link, 10)
        link.tap()
        link.typeText(StandIn.origin + "/dev/shop/server-tee\n")
        wait(app.buttons["review.add"], 30)
        XCTAssertFalse(app.navigationBars["خواندن محصول"].exists)
        app.buttons["review.cancel"].tap()
    }

    func testASharedLinkWaitsForRead() {
        let app = launch(["-TraklyTestShare", StandIn.origin + "/dev/shop/server-tee"])
        signIn(app)
        let read = app.buttons["composer.read"]
        wait(read, 25)
        XCTAssertFalse(app.buttons["review.add"].exists, "nothing is read before «خواندن»")
        read.tap()
        wait(app.buttons["review.add"], 30)
    }

    /// Opens the full order form through S4's «ثبت سفارش بدون لینک».
    private func openBlankForm(_ app: XCUIApplication) {
        wait(plus(app), 20)
        plus(app).tap()
        let blank = app.buttons["composer.blank"]
        wait(blank, 10)
        blank.tap()
    }

    /// A drag down from the top of a sheet (its grabber and bar), fast enough to close it; once more when the sheet only
    /// went to a lower height.
    private func swipeDown(_ bar: XCUIElement, until gone: XCUIElement) {
        for _ in 0 ..< 2 where gone.exists {
            let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 700)), withVelocity: .fast, thenHoldForDuration: 0)
            _ = gone.waitForNonExistence(timeout: 5)
        }
    }

    func testAShareOverAnOpenOrderFormMerges() {
        let app = launch()
        signIn(app)
        openBlankForm(app)
        let close = app.navigationBars.buttons["modal.close"]
        wait(close, 15)
        let note = app.webViews.textViews.firstMatch
        wait(note, 15)
        note.tap()
        note.typeText("سفارش نیمه کاره")
        StandIn.control("/__test/share?url=" + (StandIn.origin + "/dev/shop/server-tee").addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)
        XCUIDevice.shared.press(.home)
        app.activate()
        let read = app.buttons["composer.read"]
        wait(read, 25)
        read.tap()
        let add = app.buttons["review.add"]
        wait(add, 30)
        app.buttons["M"].tap()
        add.tap()
        let merge = app.buttons["composer.continue"]
        wait(merge, 10)
        XCTAssertTrue(merge.label.contains("افزودن به فرم سفارش باز"))
        merge.tap()
        wait(close, 10)
        wait(app.webViews.staticTexts["Linen Tee"].firstMatch, 30)
        XCTAssertEqual(app.webViews.textViews.firstMatch.value as? String, "سفارش نیمه کاره", "the open form was never lost")
    }

    func testAMergeIntoTheQuickOrderFormOpensANewForm() {
        let app = launch()
        signIn(app)
        let quick = app.webViews.links["سفارش سریع"]
        wait(quick, 30)
        quick.tap()
        let close = app.navigationBars.buttons["modal.close"]
        wait(close, 15)
        let note = app.webViews.textViews.firstMatch
        wait(note, 15)
        note.tap()
        note.typeText("سفارش سریع نیمه کاره")
        StandIn.control("/__test/share?url=" + (StandIn.origin + "/dev/shop/server-tee").addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)
        XCUIDevice.shared.press(.home)
        app.activate()
        let read = app.buttons["composer.read"]
        wait(read, 25)
        read.tap()
        let add = app.buttons["review.add"]
        wait(add, 30)
        app.buttons["M"].tap()
        add.tap()
        let merge = app.buttons["composer.continue"]
        wait(merge, 10)
        merge.tap()
        // The quick form answers {ok: false}: the dirty confirm, then a new order form with the product.
        let keep = app.buttons["نگه داشتن پیش نویس"]
        wait(keep, 15)
        keep.tap()
        wait(app.webViews.staticTexts["Linen Tee"].firstMatch, 30)
        XCTAssertTrue(close.waitForExistence(timeout: 10))
    }

    func testAQuickActionOverTheComposerInMergeModeClosesBoth() {
        let app = launch()
        signIn(app)
        openBlankForm(app)
        let close = app.navigationBars.buttons["modal.close"]
        wait(close, 15)
        let note = app.webViews.textViews.firstMatch
        wait(note, 15)
        note.tap()
        note.typeText("سفارش نیمه کاره")
        StandIn.control("/__test/share?url=" + (StandIn.origin + "/dev/shop/server-tee").addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)
        XCUIDevice.shared.press(.home)
        app.activate()
        wait(app.buttons["composer.read"], 25)
        // «سفارش ها» from the home screen while S4 is over the unsaved form: the dirty confirm, then both go.
        StandIn.control("/__test/action?type=info.trakly.app.orders")
        XCUIDevice.shared.press(.home)
        app.activate()
        let keep = app.buttons["نگه داشتن پیش نویس"]
        wait(keep, 20)
        keep.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 15), "no empty modal is left")
        XCTAssertFalse(app.textFields["composer.link"].exists)
        wait(app.webViews.links.containing(NSPredicate(format: "label CONTAINS %@", "مریم احمدی")).firstMatch, 25)
        // S4 opens again (it was not left half closed).
        wait(plus(app), 15)
        plus(app).tap()
        wait(app.textFields["composer.link"], 10)
    }

    func testASwipeDownClosesAnEmptyComposerAndCancelsTheReview() {
        let app = launch()
        signIn(app)
        wait(plus(app), 20)
        plus(app).tap()
        let link = app.textFields["composer.link"]
        wait(link, 10)
        swipeDown(app.navigationBars["سفارش تازه"], until: link)
        XCTAssertFalse(link.exists, "an empty S4 closes with a swipe down")
        plus(app).tap()
        wait(link, 10)
        link.tap()
        link.typeText(StandIn.origin + "/dev/shop/server-tee\n")
        let add = app.buttons["review.add"]
        wait(add, 30)
        swipeDown(app.navigationBars["انتخاب مشخصات"], until: add)
        XCTAssertFalse(add.exists, "a swipe down on S6 is «انصراف»")
        XCTAssertFalse(app.descendants(matching: .any)["composer.row"].exists)
        // With a product in the basket the swipe asks first.
        link.tap()
        link.typeText(StandIn.origin + "/dev/shop/server-tee\n")
        wait(add, 30)
        app.buttons["M"].tap()
        add.tap()
        wait(app.descendants(matching: .any)["composer.line"].firstMatch, 15)
        let bar = app.navigationBars["سفارش تازه"]
        let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 700)), withVelocity: .fast, thenHoldForDuration: 0)
        let keep = app.alerts.buttons["نگه داشتن"]
        wait(keep, 10)
        keep.tap()
        XCTAssertTrue(link.waitForNonExistence(timeout: 10))
    }

    func testASwipeDownOnAFailedReadFreesTheRowAndTheLine() {
        let app = launch()
        signIn(app)
        wait(plus(app), 20)
        plus(app).tap()
        let link = app.textFields["composer.link"]
        wait(link, 10)
        link.tap()
        link.typeText(StandIn.origin + "/dev/shop/plain\n")
        let error = app.descendants(matching: .any)["reader.error"]
        wait(error, 45)
        let readerBar = app.navigationBars["خواندن محصول"]
        swipeDown(readerBar, until: error)
        XCTAssertFalse(error.exists, "the error card closes with a swipe down")
        // The row is not left reading: it offers «تلاش دوباره».
        wait(app.buttons["composer.retry"], 10)
        app.buttons["composer.close"].tap()

        // The web form's «دریافت اطلاعات» (single mode): after the swipe a second request opens the reader again.
        StandIn.control("/__test/line?url=" + (StandIn.origin + "/dev/shop/plain").addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)
        let quick = app.webViews.links["سفارش سریع"]
        wait(quick, 20)
        quick.tap()
        let fetch = app.webViews.buttons["دریافت اطلاعات"]
        wait(fetch, 20)
        fetch.tap()
        wait(error, 45)
        swipeDown(readerBar, until: error)
        XCTAssertFalse(error.exists)
        wait(fetch, 10)
        fetch.tap()
        wait(readerBar, 15)
        app.buttons["reader.cancel"].tap()
    }

    func testTheOpenPagesFollowTheSystemAppearance() {
        // The system appearance is switched by the stand-in on the CI Mac (`simctl ui`), as Control Center would.
        addTeardownBlock {
            StandIn.control("/__test/appearance?mode=light")
        }
        let app = launch()
        signIn(app)
        wait(app.webViews.staticTexts["theme-light"].firstMatch, 25)
        StandIn.control("/__test/appearance?mode=dark")
        wait(app.webViews.staticTexts["theme-dark"].firstMatch, 15)
        StandIn.control("/__test/appearance?mode=light")
        wait(app.webViews.staticTexts["theme-light"].firstMatch, 15)
    }

    func testAnErrorPageKeepsTheTabBar() {
        let app = launch()
        signIn(app)
        let stale = app.webViews.links.containing(NSPredicate(format: "label CONTAINS %@", "یک لینک قدیمی")).firstMatch
        wait(stale, 20)
        stale.tap()
        wait(app.webViews.staticTexts["این صفحه پیدا نشد"].firstMatch, 20)
        XCTAssertTrue(app.tabBars.firstMatch.exists)
        // The error chrome: a back control, no plus button (the previous page's chrome is not carried over).
        XCTAssertTrue(backButton(app).waitForExistence(timeout: 5))
        XCTAssertFalse(plus(app).exists)
        backButton(app).tap()
        wait(stale, 15)
    }

    func testTheOfflineAndUpdateScreens() {
        let app = launch()
        signIn(app)
        StandIn.control("/__test/down?on=1")
        tab(app, "مشتریان").tap()
        wait(app.buttons["offline.retry"], 25)
        StandIn.control("/__test/down?on=0")
        app.buttons["offline.retry"].tap()
        XCTAssertTrue(app.buttons["offline.retry"].waitForNonExistence(timeout: 15))
        StandIn.control("/__test/min?value=99")
        app.terminate()
        let again = launch([], reset: false)
        wait(again.staticTexts["update.title"], 30)
        StandIn.control("/__test/min?value=0")
    }

    func testTheLockCoverAtColdLaunch() {
        let locked = launch(["-TraklyLock", "on", "-TraklyFakeAuth", "failure"])
        wait(locked.buttons["lock.open"], 15)
        locked.terminate()
        let unlocked = launch(["-TraklyLock", "on", "-TraklyFakeAuth", "success"])
        XCTAssertTrue(unlocked.buttons["lock.open"].waitForNonExistence(timeout: 15))
    }

    func testTheLockCoverIsAboveAnOpenOrderForm() {
        // The prompt at launch succeeds, the one after the return fails; the app locks at every return.
        let app = launch(["-TraklyLock", "on", "-TraklyFakeAuth", "once", "-TraklyLockAfterMs", "0"])
        signIn(app)
        let quick = app.webViews.links["سفارش سریع"]
        wait(quick, 25)
        quick.tap()
        let close = app.navigationBars.buttons["modal.close"]
        wait(close, 15)
        XCUIDevice.shared.press(.home)
        app.activate()
        let open = app.buttons["lock.open"]
        wait(open, 15)
        XCTAssertTrue(open.isHittable)
        XCTAssertFalse(close.isHittable, "the open order form is under the cover, not over it")
        // A failed prompt leaves the cover (no prompt loop, no way past it).
        open.tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(open.isHittable)
        XCTAssertFalse(close.isHittable)
    }

    func testTheLockTurnsOffWithoutADevicePasscode() {
        let app = launch(["-TraklyLock", "on", "-TraklyFakeAuth", "nopasscode"])
        signIn(app)
        wait(app.tabBars.firstMatch, 25)
        XCTAssertFalse(app.buttons["lock.open"].exists, "a device without a passcode cannot hold the lock")
        app.terminate()
        // The setting itself went off: a later launch (Face ID back, refusing here) does not lock; the sign-in page
        // (the stand-in's session cookie ends with the app) is not covered.
        let again = launch(["-TraklyFakeAuth", "failure"], reset: false)
        wait(again.webViews.textFields.firstMatch, 45)
        XCTAssertFalse(again.buttons["lock.open"].waitForExistence(timeout: 3))
        XCTAssertTrue(again.webViews.textFields.firstMatch.isHittable)
    }

    func testTheScannerSaysWhenItCannotScan() {
        let app = launch()
        signIn(app)
        let product = app.webViews.links["محصول تازه"]
        wait(product, 20)
        product.tap()
        let scan = app.webViews.buttons["اسکن بارکد"]
        wait(scan, 20)
        scan.tap()
        wait(app.staticTexts["scan.unavailable"], 15)
        app.buttons["scan.cancel"].tap()
    }

    func testFilesAndPrint() {
        let app = launch()
        signIn(app)
        tab(app, "سفارش ها").tap()
        let order = app.webViews.links.containing(NSPredicate(format: "label CONTAINS %@", "مریم احمدی")).firstMatch
        wait(order, 20)
        order.tap()
        let export = app.webViews.buttons["دریافت اکسل"]
        wait(export, 20)
        export.tap()
        // Quick Look shows the file (its own controls follow the device language).
        wait(quickLook(app), 20)
        wait(quickLook(app).staticTexts["NR-1160"].firstMatch, 20)
        closeQuickLook(app)
        XCTAssertFalse(quickLook(app).exists, "Quick Look is closed")
        let print = app.webViews.buttons["چاپ فاکتور"]
        wait(print, 15)
        print.tap()
        wait(app.navigationBars["پیش نمایش چاپ"], 20)
    }

    func testClearingShopData() {
        let app = launch()
        signIn(app)
        wait(tab(app, "بیشتر"), 25)
        tab(app, "بیشتر").tap()
        let clear = app.webViews.buttons["پاک کردن داده سایت ها"]
        wait(clear, 45)
        clear.tap()
        let yes = app.alerts.buttons["پاک شود"]
        wait(yes, 10)
        yes.tap()
        wait(app.staticTexts["toast"].exists ? app.staticTexts["toast"] : app.webViews.staticTexts["داده سایت ها پاک شد."].firstMatch, 20)
    }

    func testTheSingleTopology() {
        let app = launch([], topology: "single")
        signIn(app)
        tab(app, "سفارش ها").tap()
        let order = app.webViews.links.containing(NSPredicate(format: "label CONTAINS %@", "مریم احمدی")).firstMatch
        wait(order, 20)
        order.tap()
        wait(app.webViews.staticTexts["اقلام"].firstMatch, 15)
        wait(backButton(app), 15)
        backButton(app).tap()
        wait(order, 15)
        tab(app, "خانه").tap()
        let quick = app.webViews.links["سفارش سریع"]
        wait(quick, 20)
        quick.tap()
        let close = app.navigationBars.buttons["modal.close"]
        wait(close, 15)
        close.tap()
        wait(quick, 15)
    }
}
