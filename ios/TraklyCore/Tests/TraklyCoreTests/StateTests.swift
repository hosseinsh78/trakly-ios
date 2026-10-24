import TraklyCore
import XCTest

/// The variant logic, the basket, the tabs, the chrome reducer, file names, image addresses, rate limits and JSON
/// (docs/specs/phase10-apps-and-stores.md §B6, §B15, §E3, §I3, §I5, §K5), with `variant-cases.json`.
final class VariantMatcherTests: XCTestCase {
    func testEveryVariantCase() throws {
        let cases = try Fixtures.cases("shared/fixtures/variant-cases.json")
        var failures: [String] = []
        for item in cases {
            let name = item.string("name") ?? "?"
            let product = item.object("product") ?? JSONObject()
            var chosen: [String: String] = [:]
            for (key, value) in item.object("chosen") ?? JSONObject() {
                chosen[key] = value.stringValue
            }
            let expect = item.object("expect") ?? JSONObject()
            let sku = VariantMatcher.matching(product, chosen)?.string("sku")
            if sku != expect.string("sku") {
                failures.append("\(name): sku expected \(expect.string("sku") ?? "nil"), got \(sku ?? "nil")")
            }
            for (option, values) in expect.object("available") ?? JSONObject() {
                for (value, available) in values.objectValue ?? JSONObject() {
                    let actual = VariantMatcher.isValueAvailable(product, chosen, name: option, value: value)
                    if actual != available.boolValue {
                        failures.append("\(name): \(option)=\(value) expected \(String(describing: available.boolValue)), got \(actual)")
                    }
                }
            }
            if !BridgeMessages.isImportedProduct(.object(product)) {
                failures.append("\(name): not an ImportedProduct")
            }
        }
        XCTAssertGreaterThanOrEqual(cases.count, 10)
        assertNoFailures(failures)
    }

    private let tee: JSONObject = Json.object("""
    {"url":"https://shop.example.com/p/tee","site":"shop.example.com","title":"Tee","brand":"Acme","price":"40.00","currency":"USD",
    "images":["https://shop.example.com/a.jpg","https://shop.example.com/b.jpg"],
    "options":[{"name":"Size","label":"سایز","values":["S","M"]},{"name":"Color","label":"رنگ","values":["Red"]}],
    "variants":[{"options":{"Size":"S","Color":"Red"},"image":"https://shop.example.com/s.jpg","price":"42.00","sku":"S","available":true},
                {"options":{"Size":"M","Color":"Red"},"image":null,"price":null,"sku":"M","available":false}]}
    """)!

    func testPreselectionMissingLabelsImagesAndPrice() {
        XCTAssertEqual(VariantMatcher.preselected(tee), ["Color": "Red"])
        XCTAssertEqual(VariantMatcher.missingLabels(tee, ["Color": "Red"]), ["سایز"])
        XCTAssertEqual(VariantMatcher.missingLabels(tee, ["Color": "Red", "Size": "M"]), [])
        XCTAssertEqual(VariantMatcher.images(tee, ["Size": "S"]).first, "https://shop.example.com/s.jpg")
        XCTAssertEqual(VariantMatcher.images(tee, ["Size": "S"]).count, 3)
        XCTAssertEqual(VariantMatcher.price(tee, ["Size": "S"]), "42.00 USD")
        XCTAssertEqual(VariantMatcher.price(tee, ["Size": "M"]), "40.00 USD")
        XCTAssertTrue(VariantMatcher.comboUnavailable(tee, ["Size": "M"]))
        XCTAssertFalse(VariantMatcher.comboUnavailable(tee, ["Size": "S"]))
        XCTAssertFalse(VariantMatcher.comboUnavailable(tee, [:]))
        XCTAssertEqual(VariantMatcher.imageAfterChoice(tee, ["Size": "S"], current: "https://shop.example.com/b.jpg"), "https://shop.example.com/s.jpg")
        XCTAssertEqual(VariantMatcher.imageAfterChoice(tee, ["Size": "M"], current: "https://shop.example.com/b.jpg"), "https://shop.example.com/b.jpg")
    }

    func testTheChoiceNativeBuildsPassesTheWebValidator() {
        let choice = IntakeChoices.make(product: tee, chosen: ["Size": "S", "Color": "Red", "Bogus": "x"], title: "  تی شرت  ", withBrand: true, quantity: 1200, image: (ref: "Qm9k3xZpT0a8Lr2sVb7nYw", url: "https://shop.example.com/s.jpg"), source: "server")
        XCTAssertTrue(BridgeMessages.isIntakeChoice(.object(choice)))
        XCTAssertEqual(choice.string("title"), "تی شرت")
        XCTAssertEqual(choice["quantity"]?.intValue, 999)
        XCTAssertNil(choice.object("chosen")?["Bogus"])
        let bare = IntakeChoices.make(product: tee, chosen: [:], title: String(repeating: "a", count: 400), withBrand: false, quantity: 0, image: nil, source: "capture")
        XCTAssertTrue(BridgeMessages.isIntakeChoice(.object(bare)))
        XCTAssertEqual(bare.string("title")?.count, 190)
        XCTAssertEqual(bare["quantity"]?.intValue, 1)
    }
}

final class BasketTests: XCTestCase {
    private var now: Int64 = 1_760_000_000_000

    private func line(_ id: String) -> Basket.Line {
        let product = Json.object(#"{"url":"https://www.zara.com/bag-1","site":"www.zara.com","title":"Bag","brand":null,"images":[],"price":null,"currency":null,"options":[],"variants":[]}"#)!
        return Basket.Line(id: id, choice: IntakeChoices.make(product: product, chosen: [:], title: "Bag", withBrand: false, quantity: 1, image: nil, source: "server"), host: "www.zara.com", thumb: nil)
    }

    func testTheBasketIsBoundToTheAccount() {
        let basket = Basket(clock: { [unowned self] in self.now })
        XCTAssertFalse(basket.account("a".padding(toLength: 32, withPad: "a", startingAt: 0)))
        basket.add(line("1"))
        basket.share("https://www.zara.com/bag-2")
        XCTAssertFalse(basket.account(nil))
        XCTAssertEqual(basket.state.lines.count, 1)
        XCTAssertFalse(basket.account(String(repeating: "a", count: 32)))
        XCTAssertTrue(basket.account(String(repeating: "b", count: 32)))
        XCTAssertTrue(basket.state.isEmpty)
    }

    func testTheFileKeepsThirtyMinutes() {
        let basket = Basket(clock: { [unowned self] in self.now })
        basket.add(line("1"))
        basket.setQuantity("1", 5)
        let text = basket.toJson()
        let restored = Basket(clock: { [unowned self] in self.now })
        restored.restore(text)
        XCTAssertEqual(restored.state.lines.first?.quantity, 5)
        now += Limits.basketMs + 1
        let late = Basket(clock: { [unowned self] in self.now })
        late.restore(text)
        XCTAssertTrue(late.state.isEmpty)
    }

    func testAnIntakeIdIsTakenOnce() {
        let basket = Basket(clock: { [unowned self] in self.now })
        basket.add(line("1"))
        basket.add(line("2"))
        let id = basket.issue("Qm9k3xZpT0a8Lr2sVb7nYw")
        XCTAssertEqual(basket.issuedIds(), [id])
        XCTAssertEqual(basket.take(id)?.count, 2)
        XCTAssertNil(basket.take(id))
        XCTAssertTrue(basket.state.lines.isEmpty)
        basket.add(line("3"))
        let late = basket.issue("Zx8Lr2sVb7nYwQm9k3xZpT")
        now += Limits.intakeIdMs + 1
        XCTAssertNil(basket.take(late))
    }

    func testTwentyLinesAtMost() {
        let basket = Basket(clock: { [unowned self] in self.now })
        for index in 0 ..< 20 {
            XCTAssertTrue(basket.add(line(String(index))))
        }
        XCTAssertFalse(basket.add(line("21")))
        basket.signOut()
        XCTAssertTrue(basket.state.isEmpty)
    }
}

final class TabsAndPageStateTests: XCTestCase {
    private let tabsBody = Json.object(#"{"items":[{"key":"home","label":"خانه","badge":null},{"key":"orders","label":"سفارش ها","badge":120},{"key":"customers","label":"مشتریان","badge":null},{"key":"more","label":"بیشتر","badge":null}],"create":false,"quick":true,"draft":{"at":1760000000000}}"#)!

    func testTabsFromTheWebAndTheKeptForm() {
        let state = Tabs.of(tabsBody)
        XCTAssertEqual(state.keys, ["home", "orders", "customers", "more"])
        XCTAssertEqual(state.items[1].badge, 120)
        XCTAssertEqual(state.draftAt, 1_760_000_000_000)
        XCTAssertTrue(state.quick)
        let kept = Tabs.fromJson(Tabs.toJson(state))
        XCTAssertEqual(kept.keys, state.keys)
        XCTAssertNil(kept.draftAt)
        XCTAssertNil(kept.items[1].badge)
        XCTAssertFalse(kept.fromWeb)
        XCTAssertEqual(Tabs.fromJson("nope"), Tabs.defaults)
        XCTAssertEqual(Tabs.fromJson(#"{"items":[{"key":"create","label":"x","badge":null}],"create":false,"quick":false,"draft":null}"#), Tabs.defaults)
    }

    func testThePlusButtonIsOnTheHomeAndOrdersRootsOnly() {
        let state = Tabs.of(tabsBody)
        XCTAssertTrue(Tabs.createOn("home", state))
        XCTAssertTrue(Tabs.createOn("orders", state))
        XCTAssertFalse(Tabs.createOn("customers", state))
        var centre = state
        centre.create = true
        XCTAssertFalse(Tabs.createOn("home", centre))
        XCTAssertEqual(Tabs.slots(centre), ["home", "orders", "create", "customers", "more"])
        var noOrders = state
        noOrders.items = [Tabs.Item(key: "home", label: "خانه", badge: nil), Tabs.Item(key: "more", label: "بیشتر", badge: nil)]
        XCTAssertFalse(Tabs.createOn("home", noOrders))
        XCTAssertTrue(Tabs.createOn("home", Tabs.defaults))
    }

    func testBadgesUsePersianDigits() {
        XCTAssertEqual(Tabs.badgeText(7), "۷")
        XCTAssertEqual(Tabs.badgeText(99), "۹۹")
        XCTAssertEqual(Tabs.badgeText(120), "۹۹+")
        XCTAssertEqual(Fa.digits("NR-1160"), "NR-۱۱۶۰")
        XCTAssertEqual(Fa.time(0, zone: TimeZone(identifier: "UTC")!), "۰۰:۰۰")
    }

    func testCopyPlaceholdersAreFilledInOrder() {
        XCTAssertEqual(Fa.format("ادامه ثبت سفارش (\u{2068}%@\u{2069})", ["۳"]), "ادامه ثبت سفارش (\u{2068}۳\u{2069})")
        XCTAssertEqual(Fa.format("%1$@ و %2$@", ["الف", "ب"]), "الف و ب")
        XCTAssertEqual(Fa.format("%d عدد", ["۲"]), "۲ عدد")
        XCTAssertEqual(Fa.format("صد %%", []), "صد %")
        XCTAssertEqual(Fa.list(["S", "رنگ"]), "\u{2068}S\u{2069}\u{060C} \u{2068}رنگ\u{2069}")
    }

    private func page(_ context: String, tab: String? = nil, titleVisible: Bool = false, overlay: Bool = false, tone: String = "day") -> PageState.Page {
        PageState.Page(context: context, tab: tab, title: "سفارش ها", titleVisible: titleVisible, backLabel: nil, refreshable: true, dirty: false, overlay: overlay, search: true, action: nil, tone: tone)
    }

    func testTheChromeOfEachContext() {
        let tabs = Tabs.of(tabsBody)
        let auth = PageState.chrome(page: page("auth", tone: "night"), httpError: nil, tabs: tabs, coldStartBars: false, night: false, canGoBack: false)
        XCTAssertFalse(auth.navigationBar)
        XCTAssertTrue(auth.fullScreen)
        XCTAssertTrue(auth.lightStatusBar)
        let root = PageState.chrome(page: page("tab", tab: "orders"), httpError: nil, tabs: tabs, coldStartBars: false, night: false, canGoBack: false)
        XCTAssertTrue(root.navigationBar && root.tabBar && root.createButton && root.refreshable)
        XCTAssertFalse(root.backArrow)
        XCTAssertEqual(root.title, "سفارش ها")
        let pushed = PageState.chrome(page: page("push", tab: "orders", titleVisible: true), httpError: nil, tabs: tabs, coldStartBars: false, night: false, canGoBack: true)
        XCTAssertTrue(pushed.backArrow)
        XCTAssertFalse(pushed.createButton)
        XCTAssertEqual(pushed.title, "")
        let sheet = PageState.chrome(page: page("tab", tab: "home", overlay: true), httpError: nil, tabs: tabs, coldStartBars: false, night: false, canGoBack: false)
        XCTAssertFalse(sheet.refreshable)
        let error = PageState.chrome(page: nil, httpError: 404, tabs: tabs, coldStartBars: false, night: true, canGoBack: true)
        XCTAssertTrue(error.tabBar && error.backArrow && error.refreshable && error.lightStatusBar)
        let none = PageState.chrome(page: nil, httpError: nil, tabs: tabs, coldStartBars: false, night: false, canGoBack: false)
        XCTAssertFalse(none.navigationBar)
        let cold = PageState.chrome(page: nil, httpError: nil, tabs: tabs, coldStartBars: true, night: false, canGoBack: false)
        XCTAssertTrue(cold.tabBar)
    }

    func testAPageMessageReadsIntoTheReducer() {
        let body = Json.object(#"{"context":"push","tab":"orders","title":"سفارش NR-1160","titleVisible":false,"back":{"label":"سفارش ها"},"refreshable":true,"dirty":false,"overlay":false,"search":false,"action":{"id":"print","icon":"print","label":"چاپ"},"tone":"day"}"#)!
        let page = PageState.Page.of(body)
        XCTAssertEqual(page.backLabel, "سفارش ها")
        XCTAssertEqual(page.action, PageState.Action(id: "print", icon: "print", label: "چاپ"))
        XCTAssertFalse(page.night)
    }
}

final class FileNamesAndAddressesTests: XCTestCase {
    func testFileNamesAreSafe() {
        XCTAssertEqual(FileNames.sanitize("../../etc/passwd", mime: "text/plain"), "passwd.txt")
        XCTAssertEqual(FileNames.sanitize("orders  2026:10.csv", mime: "text/csv"), "orders 202610.csv")
        XCTAssertEqual(FileNames.sanitize(nil, mime: "application/pdf"), "trakly.pdf")
        XCTAssertEqual(FileNames.sanitize("   ", mime: nil), "trakly")
        XCTAssertEqual(FileNames.sanitize("con.pdf", mime: "application/pdf"), "_con.pdf")
        XCTAssertEqual(FileNames.sanitize(".hidden", mime: "text/plain"), "hidden.txt")
        XCTAssertEqual(FileNames.sanitize("گزارش فروش.xlsx", mime: nil), "گزارش فروش.xlsx")
        let long = FileNames.sanitize(String(repeating: "x", count: 300) + ".pdf", mime: nil)
        XCTAssertEqual(long.count, FileNames.maxChars)
        XCTAssertTrue(long.hasSuffix(".pdf"))
        XCTAssertEqual(FileNames.sanitize("photo", mime: "image/jpeg; q=1"), "photo.jpg")
    }

    func testOnlyPublicAddresses() {
        XCTAssertTrue(ImageAddress.isPublic([93, 184, 216, 34]))
        for address: [UInt8] in [[127, 0, 0, 1], [10, 1, 2, 3], [192, 168, 1, 1], [172, 16, 0, 1], [169, 254, 169, 254], [100, 64, 0, 1], [0, 0, 0, 0], [255, 255, 255, 255], [224, 0, 0, 1]] {
            XCTAssertFalse(ImageAddress.isPublic(address), "\(address)")
        }
        XCTAssertFalse(ImageAddress.isPublic(ImageAddress.bytes(ofNumericAddress: "::1")!))
        XCTAssertFalse(ImageAddress.isPublic(ImageAddress.bytes(ofNumericAddress: "fe80::1%en0")!))
        XCTAssertFalse(ImageAddress.isPublic(ImageAddress.bytes(ofNumericAddress: "::ffff:192.168.0.1")!))
        XCTAssertFalse(ImageAddress.isPublic(ImageAddress.bytes(ofNumericAddress: "fd00::1")!))
        XCTAssertTrue(ImageAddress.isPublic(ImageAddress.bytes(ofNumericAddress: "2606:4700::6810:84e5")!))
        XCTAssertFalse(ImageAddress.isPublic(ImageAddress.bytes(ofNumericAddress: "64:ff9b::a00:1")!))
        XCTAssertEqual(ImageAddress.bytes(ofNumericAddress: "1.2.3.4"), [1, 2, 3, 4])
        XCTAssertNil(ImageAddress.bytes(ofNumericAddress: "shop.example.com"))
        XCTAssertFalse(ImageAddress.allPublic([]))
    }

    func testOnlyTheImagesOfTheProductAndItsCapture() {
        let product = Json.object(#"{"url":"https://www.zara.com/bag-1","site":"www.zara.com","title":"Bag","brand":null,"images":["https://static.zara.net/a.jpg"],"price":null,"currency":null,"options":[],"variants":[{"options":{},"image":"https://static.zara.net/v.jpg","price":null,"sku":null,"available":null}]}"#)!
        XCTAssertTrue(ImageAddress.allowedImage("https://static.zara.net/a.jpg", product: product, source: "server", capture: nil, dev: false))
        XCTAssertTrue(ImageAddress.allowedImage("https://static.zara.net/v.jpg", product: product, source: "server", capture: nil, dev: false))
        XCTAssertFalse(ImageAddress.allowedImage("https://static.zara.net/other.jpg", product: product, source: "server", capture: nil, dev: false))
        XCTAssertFalse(ImageAddress.allowedImage("https://static.zara.net/a.jpg", product: product, source: "capture", capture: #"{"x":"https:\/\/static.zara.net\/b.jpg"}"#, dev: false))
        XCTAssertTrue(ImageAddress.allowedImage("https://static.zara.net/a.jpg", product: product, source: "capture", capture: #"{"x":"https:\/\/static.zara.net\/a.jpg"}"#, dev: false))
        XCTAssertTrue(ImageAddress.allowedImage("https://static.zara.net/a.jpg", product: product, source: "capture", capture: #"{"x":"//static.zara.net/a.jpg"}"#, dev: false))
        XCTAssertTrue(ImageAddress.isDevFixture("http://127.0.0.1:8000/dev/shop/img/1.png", dev: true))
        XCTAssertFalse(ImageAddress.isDevFixture("http://127.0.0.1:8000/dev/shop/img/1.png", dev: false))
        XCTAssertFalse(ImageAddress.isDevFixture("http://127.0.0.1:8000/app/x", dev: true))
    }

    func testDownloadsStayOnTheOriginUnderApp() {
        XCTAssertTrue(Redirects.allowed("https://erp.trakly.info/app/orders/export?x=1", trusted: BridgeMessages.origin))
        XCTAssertFalse(Redirects.allowed("https://erp.trakly.info/dl/x.zip", trusted: BridgeMessages.origin))
        XCTAssertFalse(Redirects.allowed("https://files.example.com/app/x.csv", trusted: BridgeMessages.origin))
        XCTAssertFalse(Redirects.follow("https://erp.trakly.info/app/x", hop: 4, trusted: BridgeMessages.origin))
    }
}

final class RateLimiterTests: XCTestCase {
    func testTenAMinuteAndOneHundredTwentyAnHour() {
        var now: Int64 = 1_000_000
        let limiter = RateLimiter(store: RateLimiter.MemoryStore(), clock: { now })
        for _ in 0 ..< 10 {
            XCTAssertTrue(limiter.take())
        }
        XCTAssertFalse(limiter.take())
        now += RateLimiter.minuteMs
        XCTAssertTrue(limiter.take())
        for _ in 0 ..< 200 {
            now += 7000
            _ = limiter.take()
        }
        XCTAssertEqual(limiter.remaining(), 0)
        XCTAssertEqual(RateLimiter.decode(RateLimiter.encode([1, 2, 3]) + ",x"), [1, 2, 3])
    }

    func testBridgeRatesPerType() {
        var now: Int64 = 0
        let rates = BridgeRates(clock: { now })
        for _ in 0 ..< 10 {
            XCTAssertTrue(rates.take("print"))
        }
        XCTAssertFalse(rates.take("print"))
        XCTAssertTrue(rates.take("download"))
        XCTAssertTrue(rates.take("hello"))
        now += 60_000
        XCTAssertTrue(rates.take("print"))
    }
}

final class JsonTests: XCTestCase {
    func testStrictParsing() {
        XCTAssertNil(Json.parseOrNil("{a:1}"))
        XCTAssertNil(Json.parseOrNil("{'a':1}"))
        XCTAssertNil(Json.parseOrNil("[1,]"))
        XCTAssertNil(Json.parseOrNil("01"))
        XCTAssertNil(Json.parseOrNil("1 2"))
        XCTAssertNil(Json.parseOrNil("\"a\nb\""))
        XCTAssertEqual(Json.parseOrNil(" true "), .bool(true))
        XCTAssertEqual(Json.parseOrNil("1"), .number(1))
        XCTAssertNotEqual(Json.parseOrNil("1"), .bool(true))
        XCTAssertEqual(Json.parseOrNil(#""مح""#), .string("مح"))
        XCTAssertEqual(Json.parseOrNil(#"{"a":1,"b":2,"a":3}"#)?.objectValue?.keys, ["a", "b"])
        XCTAssertEqual(Json.parseOrNil(#"{"a":1,"b":2,"a":3}"#)?.objectValue?["a"], .number(3))
        var deep = ""
        for _ in 0 ..< 70 { deep += "[" }
        for _ in 0 ..< 70 { deep += "]" }
        XCTAssertNil(Json.parseOrNil(deep))
    }

    func testWriting() {
        let value: JSONValue = ["b": 1.5, "a": [true, nil, "x\"y\n\u{2028}"], "n": 12]
        XCTAssertEqual(Json.write(value), #"{"b":1.5,"a":[true,null,"x\"y\n "],"n":12}"#)
        XCTAssertEqual(Json.parseOrNil(Json.write(value)), value)
    }
}
