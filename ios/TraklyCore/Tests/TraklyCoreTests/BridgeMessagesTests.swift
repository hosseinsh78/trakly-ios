import TraklyCore
import XCTest

/// TNB/1 on the native side (docs/specs/phase10-apps-and-stores.md §B2–§B5, §K5): every case of
/// `shared/fixtures/bridge-cases.json` through `checkWebMessage` → `admitWebMessage` (web → native) or `checkNativeSend`
/// (native → web), exactly as messages.ts answers it, and the type table equal to `shared/contracts/bridge.json`.
final class BridgeMessagesTests: XCTestCase {
    private func bridge() throws -> JSONObject {
        try XCTUnwrap(Fixtures.json("shared/contracts/bridge.json").objectValue)
    }

    func testEveryBridgeCaseIsAnsweredLikeTheWeb() throws {
        let cases = try Fixtures.cases("shared/fixtures/bridge-cases.json")
        var failures: [String] = []
        for item in cases {
            let raw = item.string("raw") ?? ""
            let origin = item.string("origin") ?? ""
            let path = item.string("path") ?? ""
            let actual: String
            if item.string("dir") == "native" {
                let target = BridgeMessages.SendTarget(webView: item.string("webView") ?? "tab", origin: origin, path: path, greeted: item.bool("greeted") == true)
                actual = BridgeMessages.checkNativeSend(raw, target).map { "reject:" + $0 } ?? "accept"
            } else {
                let ctx = BridgeMessages.GuardContext(
                    origin: origin,
                    mainFrame: item.bool("mainFrame") == true,
                    path: path,
                    features: item.array("features")?.compactMap(\.stringValue) ?? BridgeMessages.nativeFeatures,
                    disabled: item.array("disabled")?.compactMap(\.stringValue) ?? []
                )
                switch BridgeMessages.checkWebMessage(raw, ctx) {
                case let .refused(error, _):
                    actual = "reject:" + error
                case .reply:
                    actual = "accept"
                case let .message(kind, _, type, body):
                    if kind == .request {
                        let state = item.object("state")
                        let native = BridgeMessages.NativeState(
                            intakeIds: Set(state?.array("intakeIds")?.compactMap(\.stringValue) ?? []),
                            refs: Set(state?.array("refs")?.compactMap(\.stringValue) ?? []),
                            confirmed: state?.bool("confirmed") == true
                        )
                        actual = BridgeMessages.admitWebMessage(type, body, native).map { "reject:" + $0 } ?? "accept"
                    } else {
                        actual = "accept"
                    }
                }
            }
            if actual != item.string("expect") {
                failures.append("\(item.string("name") ?? "?"): expected \(item.string("expect") ?? "?"), got \(actual)")
            }
        }
        XCTAssertGreaterThanOrEqual(cases.count, 120)
        assertNoFailures(failures)
    }

    func testTheTypeTableIsBridgeJson() throws {
        let bridge = try bridge()
        let types = try XCTUnwrap(bridge.object("types"))
        XCTAssertEqual(types.keys, BridgeMessages.specs.map { $0.0 })
        for (type, raw) in types {
            let expected = try XCTUnwrap(raw.objectValue)
            let spec = try XCTUnwrap(BridgeMessages.spec(type))
            XCTAssertEqual(expected.string("dir"), spec.dir, type)
            XCTAssertEqual(expected.string("kind"), spec.kind.rawValue, type)
            XCTAssertEqual(expected["maxBytes"]?.intValue, spec.maxBytes, type)
            XCTAssertEqual(expected.string("path"), spec.path, type)
            XCTAssertEqual(expected.string("feature"), spec.feature, type)
            let fields = JSONValue.object(JSONObject(spec.fields.map { ($0.0, JSONValue.string($0.1)) }))
            XCTAssertEqual(Fixtures.canonical(expected["fields"] ?? .null), Fixtures.canonical(fields), type)
            for (_, descriptor) in spec.fields {
                XCTAssertNotNil(BridgeMessages.fieldCheck(descriptor), "\(type): \(descriptor)")
            }
        }
        XCTAssertEqual(types.compactMap { $0.1.objectValue?.string("dir") == "web" ? $0.0 : nil }, BridgeMessages.webTypes)
        XCTAssertEqual(types.compactMap { $0.1.objectValue?.string("dir") == "native" ? $0.0 : nil }, BridgeMessages.nativeTypes)
        XCTAssertEqual(bridge["features"]?.stringList, BridgeMessages.nativeFeatures)
        XCTAssertEqual(bridge["tabKeys"]?.stringList, BridgeMessages.tabKeys)
        XCTAssertEqual(bridge["errors"]?.stringList, BridgeMessages.errors)
    }

    func testTheLimitsAreBridgeJson() throws {
        let limits = try XCTUnwrap(bridge().object("limits"))
        XCTAssertEqual(limits.string("origin"), BridgeMessages.origin)
        XCTAssertEqual(limits.string("idPattern"), BridgeMessages.idPattern)
        XCTAssertEqual(limits.string("tokenPattern"), BridgeMessages.tokenPattern)
        XCTAssertEqual(limits.string("accountKeyPattern"), BridgeMessages.accountKeyPattern)
        XCTAssertEqual(limits.string("orderFormPath")?.replacingOccurrences(of: "\\/", with: "/"), BridgeMessages.orderFormPathPattern)
        XCTAssertEqual(limits.string("printPath")?.replacingOccurrences(of: "\\/", with: "/"), BridgeMessages.printPathPattern)
        XCTAssertEqual(limits["moreProfilePaths"]?.stringList, BridgeMessages.moreProfilePaths)
        XCTAssertEqual(limits["panelPaths"]?.stringList, BridgeMessages.panelPaths)
        XCTAssertEqual(limits["fileSaveMimes"]?.stringList, BridgeMessages.fileSaveMimes)
        let numbers: [(String, Int)] = [
            ("defaultMaxBytes", BridgeMessages.Limit.defaultMaxBytes),
            ("absoluteMaxBytes", BridgeMessages.Limit.absoluteMaxBytes),
            ("urlChars", BridgeMessages.Limit.urlChars),
            ("lineKeyChars", BridgeMessages.Limit.lineKeyChars),
            ("pageTitleChars", BridgeMessages.Limit.pageTitleChars),
            ("choiceTitleChars", BridgeMessages.Limit.choiceTitleChars),
            ("labelChars", BridgeMessages.Limit.labelChars),
            ("tabLabelChars", BridgeMessages.Limit.tabLabelChars),
            ("tabsMax", BridgeMessages.Limit.tabsMax),
            ("quantityMin", BridgeMessages.Limit.quantityMin),
            ("quantityMax", BridgeMessages.Limit.quantityMax),
            ("basketMax", BridgeMessages.Limit.basketMax),
            ("fileNameChars", BridgeMessages.Limit.fileNameChars),
            ("fileSaveDecodedBytes", BridgeMessages.Limit.fileSaveDecodedBytes),
            ("shareTextChars", BridgeMessages.Limit.shareTextChars),
            ("scanFormatsMax", BridgeMessages.Limit.scanFormatsMax),
            ("helloTimeoutMs", BridgeMessages.Limit.helloTimeoutMs),
            ("backReplyMs", BridgeMessages.Limit.backReplyMs),
            ("requestTimeoutMs", BridgeMessages.Limit.requestTimeoutMs),
            ("intakeFetchTimeoutMs", BridgeMessages.Limit.intakeFetchTimeoutMs),
            ("hostWaitMs", BridgeMessages.Limit.hostWaitMs),
            ("intakeIdMinutes", BridgeMessages.Limit.intakeIdMinutes),
            ("refMinutes", BridgeMessages.Limit.refMinutes),
            ("pendingChoiceMinutes", BridgeMessages.Limit.pendingChoiceMinutes),
        ]
        for (name, value) in numbers {
            XCTAssertEqual(limits[name]?.intValue, value, name)
        }
        let native = try XCTUnwrap(limits.object("nativeReplyMaxBytes"))
        XCTAssertEqual(native.keys.count, BridgeMessages.nativeReplyMaxBytes.count)
        for (type, value) in native {
            XCTAssertEqual(value.intValue, BridgeMessages.nativeReplyMaxBytes[type], type)
        }
        let page = try XCTUnwrap(limits.object("pageReplyMaxBytes"))
        for (type, value) in page {
            XCTAssertEqual(value.intValue, BridgeMessages.pageReplyMaxBytes[type], type)
        }
        let rates = try XCTUnwrap(limits.object("rates"))
        XCTAssertEqual(rates.keys, BridgeMessages.rateLimits.map { $0.0 })
        for (type, windows) in BridgeMessages.rateLimits {
            let expected = rates.array(type)?.compactMap { item -> RateLimiter.Window? in
                guard let object = item.objectValue, let max = object["max"]?.intValue, let window = object["windowMs"]?.intValue else { return nil }
                return RateLimiter.Window(max: max, windowMs: Int64(window))
            }
            XCTAssertEqual(expected, windows, type)
        }
    }

    func testTheRepliesAndMessagesNativeBuildsPassTheGuards() {
        XCTAssertEqual(BridgeMessages.replyOk("req_0001abcd", JSONObject([("handled", .bool(true))])), #"{"v":1,"re":"req_0001abcd","ok":true,"handled":true}"#)
        XCTAssertEqual(BridgeMessages.replyError("req_0001abcd", "gone"), #"{"v":1,"re":"req_0001abcd","ok":false,"error":"gone"}"#)
        let id = BridgeMessages.nextId()
        XCTAssertTrue(BridgeMessages.isId(id))
        XCTAssertTrue(BridgeMessages.isToken(BridgeMessages.randomToken()))
        let visit = BridgeMessages.nativeMessage("visit", id: id, JSONObject([("url", .string("https://erp.trakly.info/app/orders/5"))]))
        let target = BridgeMessages.SendTarget(webView: "tab", origin: BridgeMessages.origin, path: "/app", greeted: true)
        XCTAssertNil(BridgeMessages.checkNativeSend(visit, target))
        let insets = BridgeMessages.nativeMessage("insets", id: nil, JSONObject([("top", .number(47)), ("bottom", .number(34))]))
        XCTAssertNil(BridgeMessages.checkNativeSend(insets, target))
        XCTAssertEqual(BridgeMessages.checkNativeSend(BridgeMessages.nativeMessage("insets", id: id, JSONObject([("top", .number(1)), ("bottom", .number(1))])), target), "invalid")
    }

    func testPageRepliesNativeAccepts() {
        XCTAssertTrue(BridgeMessages.isPageReply("back", JSONObject([("handled", .bool(false))])))
        XCTAssertFalse(BridgeMessages.isPageReply("back", JSONObject([("handled", .string("no"))])))
        XCTAssertTrue(BridgeMessages.isPageReply("intake.fetch", JSONObject([("ok", .bool(false)), ("reason", .string("blocked")), ("message", .string("x"))])))
        XCTAssertFalse(BridgeMessages.isPageReply("intake.fetch", JSONObject([("ok", .bool(false)), ("reason", .string("other")), ("message", .string("x"))])))
        XCTAssertFalse(BridgeMessages.isPageReply("print", JSONObject([("ok", .bool(true))])))
    }

    func testPathRules() {
        XCTAssertTrue(BridgeMessages.isOrderFormPath("/app/orders/create"))
        XCTAssertTrue(BridgeMessages.isOrderFormPath("/app/orders/quick"))
        XCTAssertTrue(BridgeMessages.isOrderFormPath("/app/orders/12/edit"))
        XCTAssertFalse(BridgeMessages.isOrderFormPath("/app/orders/12"))
        XCTAssertFalse(BridgeMessages.isOrderFormPath("/app/orders//edit"))
        XCTAssertFalse(BridgeMessages.isOrderFormPath("/app/orders/x1/edit"))
        XCTAssertTrue(BridgeMessages.isPrintPath("/app/orders/print/invoices"))
        XCTAssertTrue(BridgeMessages.isPrintPath("/app/accounting/journal/12/print"))
        XCTAssertFalse(BridgeMessages.isPrintPath("/app/orders/5"))
        XCTAssertTrue(BridgeMessages.isPanelPath("/app/orders"))
        XCTAssertFalse(BridgeMessages.isPanelPath("/application"))
        XCTAssertFalse(BridgeMessages.isPanelPath("/APP"))
    }
}
