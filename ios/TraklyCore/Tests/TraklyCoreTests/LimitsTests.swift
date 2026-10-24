import Foundation
import TraklyCore
import XCTest

/// `Limits.swift` against `extension/src/protocol.js` (docs/specs/phase10-apps-and-stores.md §B8, §K5: `LIMITS`,
/// `PERSONAL_PATH`, `DENY_HOSTS`, `DENY_SUFFIXES`, `RESERVED_SUFFIXES`, `DEV_ORIGINS`, `DEV_SHOP_PATH`), read from the
/// JavaScript source by pattern. The public iOS mirror has no extension sources: there the values are checked against
/// the numbers of the spec only, and the private repository's checks.yml runs the full parity.
final class LimitsTests: XCTestCase {
    private let protocolFile = "extension/src/protocol.js"

    private func source() throws -> String? {
        Fixtures.exists(protocolFile) ? try Fixtures.text(protocolFile) : nil
    }

    private func declaration(_ source: String, _ name: String) throws -> String {
        let regex = try NSRegularExpression(pattern: "export const \(name)\\s*=\\s*([\\s\\S]*?);\\s*\\n")
        let range = NSRange(source.startIndex..., in: source)
        let match = try XCTUnwrap(regex.firstMatch(in: source, range: range), "protocol.js declares \(name)")
        return String(source[Range(match.range(at: 1), in: source)!])
    }

    private func strings(_ source: String, _ name: String) throws -> [String] {
        let body = try declaration(source, name)
        let regex = try NSRegularExpression(pattern: "'([^']*)'")
        return regex.matches(in: body, range: NSRange(body.startIndex..., in: body)).map { String(body[Range($0.range(at: 1), in: body)!]) }
    }

    private func number(_ expression: String) -> Int64 {
        expression.split(separator: "*").map { Int64($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "")) ?? 0 }.reduce(1, *)
    }

    func testLimitsEqualProtocolJs() throws {
        guard let source = try source() else {
            XCTAssertEqual(Limits.limit("captureBytes"), 900_000)
            XCTAssertEqual(Limits.limits.count, 26)
            return
        }
        let body = try declaration(source, "LIMITS")
        let regex = try NSRegularExpression(pattern: "^\\s*([A-Za-z0-9]+):\\s*([0-9_*\\s]+),?\\s*$", options: [.anchorsMatchLines])
        let entries = regex.matches(in: body, range: NSRange(body.startIndex..., in: body)).map { match in
            (String(body[Range(match.range(at: 1), in: body)!]), number(String(body[Range(match.range(at: 2), in: body)!])))
        }
        XCTAssertEqual(entries.map { $0.0 }, Limits.limits.map { $0.0 })
        XCTAssertEqual(entries.map { $0.1 }, Limits.limits.map { $0.1 })
    }

    func testPolicyListsEqualProtocolJs() throws {
        guard let source = try source() else {
            XCTAssertEqual(Limits.denySuffixes.first, "trakly.info")
            return
        }
        let personal = try NSRegularExpression(pattern: "export const PERSONAL_PATH\\s*=\\s*/(.+)/i;")
        let match = try XCTUnwrap(personal.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)))
        XCTAssertEqual(String(source[Range(match.range(at: 1), in: source)!]).replacingOccurrences(of: "\\/", with: "/"), Limits.personalPath)
        XCTAssertEqual(try strings(source, "DENY_HOSTS"), Limits.denyHosts)
        XCTAssertEqual(try strings(source, "DENY_SUFFIXES"), Limits.denySuffixes)
        XCTAssertEqual(try strings(source, "RESERVED_SUFFIXES"), Limits.reservedSuffixes)
        XCTAssertEqual(try strings(source, "DEV_ORIGINS"), Limits.devOrigins)
        let shop = try NSRegularExpression(pattern: "export const DEV_SHOP_PATH\\s*=\\s*'([^']*)';")
        let path = try XCTUnwrap(shop.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)))
        XCTAssertEqual(String(source[Range(path.range(at: 1), in: source)!]), Limits.devShopPath)
    }

    func testTheReadLoopUsesTheMirroredValues() {
        XCTAssertEqual(Limits.pollMs, 700)
        XCTAssertEqual(Limits.readDeadlineMs, 30_000)
        XCTAssertEqual(Limits.readsPerMinute, 10)
        XCTAssertEqual(Limits.readsPerHour, 120)
        XCTAssertEqual(Limits.imageBytes, 8 * 1024 * 1024)
        XCTAssertEqual(Limits.urlChars, 2048)
        XCTAssertEqual(Limits.devOrigins, ["http://localhost:8000", "http://127.0.0.1:8000", "http://10.0.2.2:8000"], "a debug build of TraklyCore")
    }
}
