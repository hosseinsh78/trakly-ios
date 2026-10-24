import Foundation
import TraklyCore
import XCTest

/// The shared fixtures of `shared/fixtures/` and `shared/contracts/` (docs/specs/phase10-apps-and-stores.md §B13), read
/// from the repository this file lives in: `ios/TraklyCore/Tests/TraklyCoreTests/` is four folders below the root, in
/// the private repository and in the public iOS mirror alike.
enum Fixtures {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // TraklyCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // TraklyCore
        .deletingLastPathComponent() // ios
        .deletingLastPathComponent() // the repository

    static func url(_ relative: String) -> URL {
        root.appendingPathComponent(relative)
    }

    static func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: url(relative).path)
    }

    static func text(_ relative: String) throws -> String {
        let data = try Data(contentsOf: url(relative))
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "Fixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(relative) is not UTF-8"])
        }
        return text
    }

    static func json(_ relative: String) throws -> JSONValue {
        try Json.parse(text(relative))
    }

    static func cases(_ relative: String) throws -> [JSONObject] {
        guard let items = try json(relative).arrayValue else {
            throw NSError(domain: "Fixtures", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(relative) is not an array"])
        }
        return items.compactMap(\.objectValue)
    }

    /// A value with every object's keys sorted, so two documents compare regardless of key order.
    static func canonical(_ value: JSONValue) -> JSONValue {
        switch value {
        case let .array(items):
            return .array(items.map(canonical))
        case let .object(object):
            var sorted = JSONObject()
            for key in object.keys.sorted() {
                sorted[key] = canonical(object[key] ?? .null)
            }
            return .object(sorted)
        default:
            return value
        }
    }
}

extension XCTestCase {
    /// Fails with every collected failure, one per line.
    func assertNoFailures(_ failures: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failure(s):\n" + failures.joined(separator: "\n"), file: file, line: line)
    }
}
