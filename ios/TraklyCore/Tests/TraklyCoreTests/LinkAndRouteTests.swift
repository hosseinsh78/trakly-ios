import TraklyCore
import XCTest

/// `shared/fixtures/link-cases.json` through `LinkText.firstProductUrl` and `shared/fixtures/route-cases.json` through
/// `NavigationPolicy.classify` (docs/specs/phase10-apps-and-stores.md §B7, §B13, §K5), plus the app's own rules.
final class LinkTextTests: XCTestCase {
    func testEveryLinkCase() throws {
        let cases = try Fixtures.cases("shared/fixtures/link-cases.json")
        var failures: [String] = []
        for item in cases {
            let text = item.string("text") ?? ""
            let expected = item.string("expect")
            let actual = LinkText.firstProductUrl(text)
            if actual != expected {
                failures.append("\(text.debugDescription): expected \(expected ?? "nil"), got \(actual ?? "nil")")
            }
        }
        XCTAssertGreaterThanOrEqual(cases.count, 30)
        assertNoFailures(failures)
    }

    func testADebugBuildKeepsHttpForTheLocalFixtureShopsOnly() {
        XCTAssertEqual(LinkText.firstProductUrl("ببین http://127.0.0.1:8000/dev/shop/product-group", dev: true), "http://127.0.0.1:8000/dev/shop/product-group")
        XCTAssertEqual(LinkText.firstProductUrl("HTTP://localhost:8000/dev/shop/plain.", dev: true), "http://localhost:8000/dev/shop/plain")
        XCTAssertEqual(LinkText.firstProductUrl("http://127.0.0.1:8000/dev/shop/product-group"), "https://127.0.0.1:8000/dev/shop/product-group")
        XCTAssertEqual(LinkText.firstProductUrl("http://www.macys.com/x", dev: true), "https://www.macys.com/x")
    }

    func testASchemeWithNothingAfterItIsSkipped() {
        XCTAssertEqual(LinkText.firstProductUrl("https:// then https://www.zara.com/bag-1"), "https://www.zara.com/bag-1")
        XCTAssertNil(LinkText.firstProductUrl("https://"))
    }
}

final class NavigationPolicyTests: XCTestCase {
    func testEveryRouteCase() throws {
        let cases = try Fixtures.cases("shared/fixtures/route-cases.json")
        var failures: [String] = []
        for item in cases {
            let url = item.string("url") ?? ""
            let actual = NavigationPolicy.classify(url).rawValue
            if actual != item.string("expect") {
                failures.append("\(url): expected \(item.string("expect") ?? "?"), got \(actual)")
            }
        }
        XCTAssertGreaterThanOrEqual(cases.count, 40)
        assertNoFailures(failures)
    }

    func testRoutePanelCasesAreVisitUrls() throws {
        for item in try Fixtures.cases("shared/fixtures/route-cases.json") {
            let url = item.string("url") ?? ""
            XCTAssertEqual(item.string("expect") == "panel", BridgeMessages.isVisitUrl(url), url)
        }
    }

    func testADebugBuildTrustsItsLocalOrigin() {
        let local = "http://127.0.0.1:8000"
        XCTAssertEqual(NavigationPolicy.classify(local + "/app/orders", trusted: local), .panel)
        XCTAssertEqual(NavigationPolicy.classify(local + "/privacy", trusted: local), .inApp)
        XCTAssertEqual(NavigationPolicy.classify("http://localhost:8000/app", trusted: local), .blocked)
        XCTAssertEqual(NavigationPolicy.classify("https://erp.trakly.info/app", trusted: local), .inApp)
    }

    func testWhatsappAndTelegramLinksGoToTheSystem() {
        XCTAssertEqual(NavigationPolicy.classify("https://wa.me/989120000000"), .system)
        XCTAssertEqual(NavigationPolicy.classify("https://t.me/trakly"), .system)
        XCTAssertEqual(NavigationPolicy.classify("tg://resolve?domain=trakly"), .blocked)
    }

    func testPanelUrlsAreNormalised() {
        XCTAssertEqual(NavigationPolicy.panelUrl("https://ERP.trakly.info:443/login/../app/more"), "https://erp.trakly.info/app/more")
        XCTAssertNil(NavigationPolicy.panelUrl("https://erp.trakly.info/admin"))
        XCTAssertNil(NavigationPolicy.panelUrl("javascript:alert(1)"))
    }

    func testThePublicPagesOpenWithTheAppMark() {
        XCTAssertEqual(NavigationPolicy.decorateFromApp("https://erp.trakly.info/privacy"), "https://erp.trakly.info/privacy?from=app&p=ios")
        XCTAssertEqual(NavigationPolicy.decorateFromApp("https://erp.trakly.info/account-deletion?x=1"), "https://erp.trakly.info/account-deletion?x=1&from=app&p=ios")
        XCTAssertEqual(NavigationPolicy.decorateFromApp("https://erp.trakly.info/privacy?from=app&p=ios"), "https://erp.trakly.info/privacy?from=app&p=ios")
        XCTAssertEqual(NavigationPolicy.decorateFromApp("https://www.zara.com/x"), "https://www.zara.com/x")
    }
}

final class IncomingLinkTests: XCTestCase {
    private let trusted = BridgeMessages.origin

    private func screen(orderForm: Bool = false, modal: Bool = false, dirty: Bool = false, intake: Bool = true, signedIn: Bool = true) -> IncomingLink.Screen {
        IncomingLink.Screen(orderFormOpen: orderForm, modalOpen: modal || orderForm, modalDirty: dirty, intake: intake, shareEntry: true, signedIn: signedIn)
    }

    func testASharedLinkOverAnOpenOrderFormMerges() {
        let urls = ["https://www.zara.com/bag-1"]
        XCTAssertEqual(IncomingLink.decide(.shares(urls), screen(orderForm: true, dirty: true), trusted: trusted), .composer(shared: urls, merge: true))
        XCTAssertEqual(IncomingLink.decide(.shares(urls), screen(), trusted: trusted), .composer(shared: urls, merge: false))
        XCTAssertEqual(IncomingLink.decide(.shares(urls), screen(signedIn: false), trusted: trusted), .keep)
        XCTAssertEqual(IncomingLink.decide(.shares([]), screen(), trusted: trusted), .nothing)
    }

    func testWithoutIntakeTheWebFormReadsTheSharedLink() {
        XCTAssertEqual(
            IncomingLink.decide(.shares(["https://www.zara.com/bag-1?a=1"]), screen(intake: false), trusted: trusted),
            .modal(path: "/app/orders/create?shared_url=https%3A%2F%2Fwww.zara.com%2Fbag-1%3Fa%3D1", confirmFirst: false)
        )
    }

    func testAUniversalLinkWhileTheFormIsDirtyAsksFirst() {
        XCTAssertEqual(IncomingLink.decide(.universal("https://erp.trakly.info/app/orders/5"), screen(modal: true, dirty: true), trusted: trusted), .visit(url: "https://erp.trakly.info/app/orders/5", confirmFirst: true))
        XCTAssertEqual(IncomingLink.decide(.universal("https://erp.trakly.info/app/orders/5"), screen(), trusted: trusted), .visit(url: "https://erp.trakly.info/app/orders/5", confirmFirst: false))
        XCTAssertEqual(IncomingLink.decide(.universal("https://erp.trakly.info/admin"), screen(), trusted: trusted), .nothing)
        XCTAssertEqual(IncomingLink.decide(.universal(nil), screen(), trusted: trusted), .nothing)
    }

    func testQuickActions() {
        XCTAssertEqual(IncomingLink.decide(.quickAction(IncomingLink.newOrder), screen(orderForm: true, dirty: true), trusted: trusted), .composer(shared: [], merge: true))
        XCTAssertEqual(IncomingLink.decide(.quickAction(IncomingLink.newOrder), screen(intake: false), trusted: trusted), .modal(path: "/app/orders/create", confirmFirst: false))
        XCTAssertEqual(IncomingLink.decide(.quickAction(IncomingLink.quickOrder), screen(modal: true, dirty: true), trusted: trusted), .modal(path: "/app/orders/quick", confirmFirst: true))
        XCTAssertEqual(IncomingLink.decide(.quickAction(IncomingLink.orders), screen(modal: true, dirty: false), trusted: trusted), .tab(key: "orders", confirmFirst: false))
        XCTAssertEqual(IncomingLink.decide(.quickAction("other"), screen(), trusted: trusted), .nothing)
    }

    func testSharedLinksKeepTenForADay() {
        let now: Int64 = 1_760_000_000_000
        var entries: [SharedLinks.Entry] = []
        for index in 0 ..< 12 {
            entries = SharedLinks.adding("https://www.zara.com/bag-\(index)", to: entries, now: now + Int64(index))
        }
        XCTAssertEqual(entries.count, 10)
        XCTAssertEqual(entries.first?.url, "https://www.zara.com/bag-11")
        entries = SharedLinks.adding("https://www.zara.com/bag-5", to: entries, now: now + 20)
        XCTAssertEqual(entries.filter { $0.url == "https://www.zara.com/bag-5" }.count, 1)
        XCTAssertEqual(entries.first?.url, "https://www.zara.com/bag-5")
        XCTAssertEqual(SharedLinks.live(entries, now: now + Limits.sharedLinksMs + 30).count, 0)
        XCTAssertEqual(SharedLinks.parse(SharedLinks.write(entries)), entries)
        XCTAssertEqual(SharedLinks.parse("not json"), [])
    }

    func testTheClipboardChipNamesNoHost() {
        XCTAssertEqual(ClipRule.label("لینک کپی شده: \u{2068}%@\u{2069}"), "لینک کپی شده")
        XCTAssertEqual(ClipRule.label("لینک کپی شده"), "لینک کپی شده")
    }

    func testTheIntakeHostIsTheModalThenTheSelectedTabThenThePrimary() {
        func candidate(_ key: String, modal: Bool = false, selected: Bool = false, primary: Bool = false, greeted: Bool = true, context: String? = "tab", loading: Bool = false) -> IntakeHost.Candidate {
            IntakeHost.Candidate(key: key, isModal: modal, isSelected: selected, isPrimary: primary, committedOnOrigin: true, greeted: greeted, context: context, loading: loading)
        }
        let all = [candidate("home", primary: true), candidate("orders", selected: true), candidate("modal", modal: true, context: "modal")]
        XCTAssertEqual(IntakeHost.choose(all), "modal")
        XCTAssertEqual(IntakeHost.choose(all, excluded: ["modal"]), "orders")
        XCTAssertEqual(IntakeHost.choose([candidate("home", primary: true), candidate("orders", selected: true, loading: true)]), "home")
        XCTAssertNil(IntakeHost.choose([candidate("home", primary: true, context: "auth")]))
        XCTAssertNil(IntakeHost.choose([candidate("home", primary: true, greeted: false)]))
    }
}
