import XCTest

/// What the UI tests share (docs/specs/phase10-apps-and-stores.md §K5, §L4): the launch with the Debug hooks, the
/// sign-in through the panel stand-in's form, waits, and screenshots kept as attachments.
enum StandIn {
    static let origin = "http://127.0.0.1:8000"

    /// Calls a control of the stand-in (`/__test/reset`, `/__test/min?value=`, `/__test/down?on=`).
    static func control(_ path: String) {
        guard let url = URL(string: origin + path) else { return }
        let done = XCTestExpectation(description: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        URLSession.shared.dataTask(with: request) { _, _, _ in done.fulfill() }.resume()
        _ = XCTWaiter.wait(for: [done], timeout: 5)
    }
}

extension XCTestCase {
    var environment: [String: String] { ProcessInfo.processInfo.environment }

    func launch(_ arguments: [String] = [], reset: Bool = true, topology: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        var list = ["-TraklyUITest"]
        if reset {
            list.append("-TraklyResetState")
        }
        if let topology {
            list += ["-TraklyTopology", topology]
        }
        app.launchArguments = list + arguments
        app.launch()
        return app
    }

    @discardableResult
    func wait(_ element: XCUIElement, _ timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let found = element.waitForExistence(timeout: timeout)
        if !found {
            // The screen at the failure, kept with the result bundle (ci.sh exports it with the shots).
            shot("fail-\(name.replacingOccurrences(of: " ", with: "-"))-\(line)", XCUIApplication(), settle: 0)
            XCTFail("not found: \(element)", file: file, line: line)
        }
        return found
    }

    /// The panel stand-in's sign-in form, as the DemoSeeder shop owner of android-ui.yml (local password only).
    func signIn(_ app: XCUIApplication) {
        let web = app.webViews.firstMatch
        let username = web.textFields.firstMatch
        if !username.waitForExistence(timeout: 20) {
            return
        }
        username.tap()
        username.typeText("shop1")
        let password = web.secureTextFields.firstMatch
        password.tap()
        password.typeText("password")
        web.buttons["ورود"].tap()
        _ = app.tabBars.firstMatch.waitForExistence(timeout: 20)
    }

    /// The back control of the bar: the system back button of a pushed host or the root host's «chrome.back».
    func backButton(_ app: XCUIApplication) -> XCUIElement {
        app.navigationBars.buttons.matching(NSPredicate(format: "identifier IN %@", ["chrome.back", "BackButton"])).firstMatch
    }

    /// The Quick Look sheet over the app (its own controls follow the device language).
    func quickLook(_ app: XCUIApplication) -> XCUIElement {
        app.otherElements["QLPreviewControllerView"]
    }

    /// Closes Quick Look with its close button (a swipe on the sheet when the button is not found).
    func closeQuickLook(_ app: XCUIApplication) {
        let sheet = quickLook(app)
        let close = sheet.buttons.matching(NSPredicate(format: "identifier == %@ OR label IN %@", "QLOverlayDoneButtonAccessibilityIdentifier", ["close", "Close", "Done"])).firstMatch
        if close.waitForExistence(timeout: 5) {
            close.tap()
        } else if sheet.exists {
            sheet.navigationBars.firstMatch.swipeDown(velocity: .fast)
        }
        _ = sheet.waitForNonExistence(timeout: 10)
    }

    /// A screenshot kept with the result bundle, named `<device>-<appearance>-<name>.png` by ci.sh.
    func shot(_ name: String, _ app: XCUIApplication, settle: TimeInterval = 0.8) {
        if settle > 0 {
            Thread.sleep(forTimeInterval: settle)
        }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        let device = environment["TRAKLY_DEVICE"] ?? "device"
        let appearance = environment["TRAKLY_APPEARANCE"] ?? "light"
        attachment.name = "\(device)-\(appearance)-\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
