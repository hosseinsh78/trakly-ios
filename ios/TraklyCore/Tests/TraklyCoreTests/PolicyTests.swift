import TraklyCore
import XCTest

/// Parity of `Policy.checkTarget()` with `checkTarget()` of `extension/src/policy.js` on `shared/fixtures/policy-cases.json`
/// (docs/specs/phase10-apps-and-stores.md §B13, §I3, §K5): `ok` and `reason` of every case; `dev: true` cases run as a
/// Debug build (`devSampleUrls`), `app: true` cases with the fixture's `appSampleUrls`, the rest with `sampleUrls`.
final class PolicyTests: XCTestCase {
    private func fixture() throws -> JSONObject {
        try XCTUnwrap(Fixtures.json("shared/fixtures/policy-cases.json").objectValue)
    }

    func testEveryFixtureCaseMatchesTheJavaScript() throws {
        let fixture = try fixture()
        let sampleUrls = fixture.array("sampleUrls")?.compactMap(\.stringValue) ?? []
        let appSampleUrls = fixture.array("appSampleUrls")?.compactMap(\.stringValue) ?? []
        let devSampleUrls = fixture.array("devSampleUrls")?.compactMap(\.stringValue) ?? []
        var failures: [String] = []
        var checked = 0
        for raw in fixture.array("cases") ?? [] {
            guard let item = raw.objectValue, let url = item.string("url") else { continue }
            let expected = item.bool("ok") == true ? "ok" : (item.string("reason") ?? "?")
            let dev = item.bool("dev") == true
            let verdict: Policy.Verdict
            if dev {
                verdict = Policy.checkTarget(url, sampleUrls: devSampleUrls, dev: true)
            } else if item.bool("app") == true {
                verdict = Policy.checkTarget(url, sampleUrls: appSampleUrls)
            } else {
                verdict = Policy.checkTarget(url, sampleUrls: sampleUrls)
            }
            checked += 1
            if verdict.wire != expected {
                let shown = url.count > 120 ? String(url.prefix(60)) + "… (\(url.count) characters)" : url
                failures.append("\(shown) (dev \(dev)): expected \(expected), got \(verdict.wire)")
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 200)
        assertNoFailures(failures)
    }

    func testTheDebugRuleIsTheAppsCheckWithDevTrue() throws {
        let fixture = try fixture()
        XCTAssertEqual(fixture.array("devSampleUrls")?.compactMap(\.stringValue), Policy.devSampleUrls)
        XCTAssertEqual(Policy.check("http://10.0.2.2:8000/dev/shop/product-group", dev: true).wire, "ok")
        XCTAssertEqual(Policy.check("http://10.0.2.2:8000/dev/shop/product-group", dev: false).wire, "scheme")
        XCTAssertEqual(Policy.check("http://127.0.0.1:8000/extension/sample", dev: true).wire, "ok")
        XCTAssertEqual(Policy.check("http://127.0.0.1:8000/app/orders", dev: true).wire, "reserved")
        XCTAssertEqual(Policy.check("https://erp.trakly.info/extension/sample?review=1", dev: false).wire, "ok")
    }

    func testTheFixtureListsAreTheAppsSampleUrls() throws {
        let fixture = try fixture()
        XCTAssertEqual(fixture.array("appSampleUrls")?.compactMap(\.stringValue), Policy.appSampleUrls)
        XCTAssertEqual(fixture.array("sampleUrls")?.compactMap(\.stringValue), ["https://erp.trakly.info/extension/sample"])
    }

    func testIdnHostsAreConverted() {
        XCTAssertEqual(Policy.checkTarget("https://münchen.de/produkt/1"), .ok(url: "https://xn--mnchen-3ya.de/produkt/1"))
        XCTAssertEqual(Policy.checkTarget("https://例え.jp/商品").wire, "ok")
        XCTAssertEqual(Policy.checkTarget("https://фото.рф/товар").wire, "ok")
        XCTAssertEqual(Policy.checkTarget("https://münchen.de./x").wire, "trailing_dot")
        XCTAssertEqual(Url.parse("https://例え.jp/x")?.hostName, "xn--r8jz45g.jp")
        XCTAssertEqual(Url.parse("https://BÜCHER.example/x")?.hostName, "xn--bcher-kva.example")
    }

    func testIpv4FormsAreIpLiterals() {
        for host in ["127.0.0.1", "2130706433", "0x7f.1", "0177.0.0.1", "0x7f000001", "127.1", "1.2.3.4.", "0x7F.0.0.1", "0", "0x"] {
            XCTAssertEqual(Policy.checkTarget("https://\(host)/").wire, "ip", host)
        }
        for host in ["1.2.3.4.5", "999.0.0.1", "1.2.3.08", "shop.123", "4294967296", "1.2.3.256", "0x100000000"] {
            XCTAssertEqual(Policy.checkTarget("https://\(host)/").wire, "invalid", host)
        }
        XCTAssertEqual(Policy.checkTarget("https://shop123.com/").wire, "ok")
        XCTAssertEqual(Url.parse("https://0x7f.1/")?.hostName, "127.0.0.1")
        XCTAssertEqual(Url.parse("https://[::ffff:192.168.0.1]/")?.hostName, "[::ffff:c0a8:1]")
        XCTAssertEqual(Url.parse("https://[2001:DB8:0:0:1:0:0:1]/")?.hostName, "[2001:db8::1:0:0:1]")
    }

    func testAuthorityEdgeCasesFollowWhatwg() {
        XCTAssertEqual(Policy.checkTarget("https:www.sephora.com/x").wire, "ok")
        XCTAssertEqual(Policy.checkTarget("https://@www.sephora.com/x").wire, "ok")
        XCTAssertEqual(Policy.checkTarget("https://:@www.sephora.com/x").wire, "ok")
        XCTAssertEqual(Policy.checkTarget("https://www.sephora.com:/x").wire, "ok")
        XCTAssertEqual(Policy.checkTarget("https://www.sephora.com:0443/x").wire, "ok")
        XCTAssertEqual(Policy.checkTarget("https://www.sephora.com:abc/x").wire, "invalid")
        XCTAssertEqual(Policy.checkTarget("https://").wire, "invalid")
        XCTAssertEqual(Policy.checkTarget("https://www.seph%6Fra.com/x"), .ok(url: "https://www.sephora.com/x"))
        XCTAssertEqual(Policy.checkTarget("https://www.sephora.com/a/../account").wire, "personal")
        XCTAssertEqual(Policy.checkTarget("https://www.sephora.com/%2e%2e/cart").wire, "personal")
        XCTAssertEqual(Policy.checkTarget("https://my_shop.com/x").wire, "ok")
        XCTAssertEqual(Policy.checkTarget("https://www.sephora.com/x?a=1#b|c").wire, "ok")
    }

    func testHostKeysFoldWwwAndM() {
        XCTAssertEqual(Policy.hostKey("https://www.sephora.com/x"), "sephora.com")
        XCTAssertEqual(Policy.hostKey("https://m.zara.com/x"), "zara.com")
        XCTAssertEqual(Policy.hostKey("WWW.Coach.com"), "coach.com")
        XCTAssertNil(Policy.hostKey("localhost"))
        XCTAssertNil(Policy.hostKey("https://shop.com./x"))
    }
}
