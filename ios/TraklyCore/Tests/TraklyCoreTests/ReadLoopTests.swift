import TraklyCore
import XCTest

/// The read loop on a test clock (docs/specs/phase9-phone-capture.md D12; phase 10 §E5, §K5): every case of
/// `shared/fixtures/readloop-cases.json` (also run by Kotlin `ReadLoopTest`) and a few direct ones.
final class ReadLoopTests: XCTestCase {
    private var now: Int64 = 1_000_000
    private let requested = "https://www.sephora.com/product/soft-pinch-P97989778?skuId=2518959"
    private let productUrl = "https://www.sephora.com/product/soft-pinch-P97989778"

    private func loop(_ url: String? = nil) -> ReadLoop {
        ReadLoop(requested: url ?? requested, clock: { [unowned self] in self.now })
    }

    private func ld(_ url: String? = nil, shopify: String? = nil) -> ReadLoop.ProbeResult {
        ReadLoop.ProbeResult(state: "product", strength: "ld", url: url ?? productUrl, shopifyUrl: shopify)
    }

    /// Advances the clock in poll steps, probing `result` each time, until `ms` passed; answers the last step.
    private func run(_ loop: ReadLoop, _ result: ReadLoop.ProbeResult, _ ms: Int64) -> ReadLoop.Step {
        var step = loop.tick()
        let end = now + ms
        while now < end {
            now += Limits.pollMs
            loop.probe(result)
            step = loop.tick()
            if !step.isContinue { return step }
        }
        return step
    }

    func testAnLdProductIsTakenAtOnce() {
        let loop = loop()
        XCTAssertEqual(loop.tick(), .continue(stage: .opening, challengeShown: false, noneHint: false))
        loop.pageStarted(requested)
        loop.probe(ld(shopify: "https://www.sephora.com/products/x.js"))
        XCTAssertEqual(loop.tick(), .product(url: productUrl, shopifyUrl: "https://www.sephora.com/products/x.js"))
        now += 60_000
        XCTAssertEqual(loop.tick(), .product(url: productUrl, shopifyUrl: "https://www.sephora.com/products/x.js"))
    }

    func testAChallengeForFiveSecondsExtendsTheDeadline() {
        let loop = loop()
        loop.pageStarted(requested)
        guard case let .continue(_, early, _) = run(loop, ReadLoop.ProbeResult(state: "challenge"), 4900) else { return XCTFail("ended early") }
        XCTAssertFalse(early)
        guard case let .continue(stage, shown, _) = run(loop, ReadLoop.ProbeResult(state: "challenge"), 1400) else { return XCTFail("ended early") }
        XCTAssertTrue(shown)
        XCTAssertEqual(stage, .challenge)
        XCTAssertTrue(run(loop, ReadLoop.ProbeResult(state: "challenge"), 60_000).isContinue)
        XCTAssertEqual(run(loop, ReadLoop.ProbeResult(state: "challenge"), 70_000), .fail(reason: "challenge_timeout", host: "www.sephora.com"))
    }

    func testCrossHostDenialCountsAsNone() {
        let denial = loop()
        denial.pageStarted("https://www.other-shop.com/blocked")
        denial.pageFinished("https://www.other-shop.com/blocked")
        XCTAssertEqual(run(denial, ReadLoop.ProbeResult(state: "denied"), 12_000), .fail(reason: "not_product", host: "www.sephora.com"))
    }

    func testTheProbeSummaryParses() {
        XCTAssertEqual(ReadLoop.ProbeResult.of(json: #"{"state":"product","strength":"ld","url":"https://a.com/p"}"#), ReadLoop.ProbeResult(state: "product", strength: "ld", url: "https://a.com/p"))
        XCTAssertEqual(ReadLoop.ProbeResult.of(json: "nope"), .loading)
        XCTAssertEqual(ReadLoop.ProbeResult.of(json: nil), .loading)
    }

    /// Each step sets the clock, applies its page event, then its probe, then ticks; a `check` asserts the continuing
    /// step; the read ends at the last step with `expect`.
    func testEverySharedReadLoopCase() throws {
        let cases = try Fixtures.cases("shared/fixtures/readloop-cases.json")
        var failures: [String] = []
        for item in cases {
            let name = item.string("name") ?? "?"
            let start: Int64 = 5_000_000
            now = start
            let url = item.string("url") ?? ""
            let loop = ReadLoop(requested: url, clock: { [unowned self] in self.now })
            let steps = (item.array("steps") ?? []).compactMap(\.objectValue)
            var last: ReadLoop.Step?
            for (index, step) in steps.enumerated() {
                now = start + Int64(step.number("t") ?? 0)
                if let page = step.object("page") {
                    let pageUrl = page.string("url") ?? ""
                    switch page.string("event") {
                    case "started": loop.pageStarted(pageUrl)
                    case "finished": loop.pageFinished(pageUrl)
                    case "changed": loop.urlChanged(pageUrl)
                    case "refused": loop.refused()
                    case "error": loop.mainFrameError(pageUrl)
                    default: break
                    }
                }
                if let probe = step.object("probe") {
                    loop.probe(ReadLoop.ProbeResult(state: probe.string("state") ?? "", strength: probe.string("strength"), url: probe.string("url"), shopifyUrl: probe.string("shopifyUrl")))
                }
                let result = loop.tick()
                last = result
                if index < steps.count - 1 && !result.isContinue {
                    failures.append("\(name): ended early at step \(index) with \(result)")
                }
                if let check = step.object("check") {
                    let stage = ReadLoop.Stage(rawValue: check.string("stage") ?? "") ?? .loading
                    let expected = ReadLoop.Step.continue(stage: stage, challengeShown: check.bool("challenge") == true, noneHint: check.bool("hint") == true)
                    if result != expected {
                        failures.append("\(name): step \(index) expected \(expected), got \(result)")
                    }
                }
            }
            let expect = item.object("expect") ?? JSONObject()
            let at = Int64(expect.number("at") ?? -1)
            let wanted: ReadLoop.Step = expect.string("outcome") == "product"
                ? .product(url: expect.string("url") ?? "", shopifyUrl: expect.string("shopifyUrl"))
                : .fail(reason: expect.string("reason") ?? "", host: Policy.hostOf(url))
            if last != wanted || now - start != at {
                failures.append("\(name): expected \(wanted) at \(at), got \(String(describing: last)) at \(now - start)")
            }
        }
        XCTAssertGreaterThanOrEqual(cases.count, 15)
        assertNoFailures(failures)
    }
}
