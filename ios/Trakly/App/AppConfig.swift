import Foundation
import TraklyCore
import UIKit

/// Facts of this build (docs/specs/phase10-apps-and-stores.md D8, D19, D33, §B1, §B4.4, §E1): the panel origin, the
/// version of the app token, the store word and the features `hello` lists. The origin and the store come from the
/// xcconfig through Info.plist (Release: exactly `https://erp.trakly.info` and `appstore`).
enum AppConfig {
    private static func info(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
    }

    /// The panel origin (`TRAKLY_ORIGIN`). A UI test run may point a Debug build at another local origin.
    static let origin: String = {
        #if DEBUG
            if let override = ProcessInfo.processInfo.environment["TRAKLY_TEST_ORIGIN"], !override.isEmpty {
                return override
            }
        #endif
        let value = info("TraklyOrigin")
        return value.isEmpty ? BridgeMessages.origin : value
    }()

    /// Whether the reader may open the local fixture shops (`Policy.check(url, dev)`, §E5): the Debug flag
    /// `TRAKLY_DEV_POLICY` only.
    static let devPolicy: Bool = {
        #if DEBUG
            return info("TraklyDevPolicy") == "YES"
        #else
            return false
        #endif
    }()

    /// `MAJOR.MINOR.PATCH`.
    static let version: String = {
        let value = info("CFBundleShortVersionString")
        return value.isEmpty ? "1.0.0" : value
    }()

    /// The build number (`github.run_number` at archive time).
    static let build: Int = Int(info("CFBundleVersion")) ?? 1

    /// `appstore`, or `dev` in a Debug build (§B1).
    static let store: String = {
        let value = info("TraklyStore")
        return value.isEmpty ? "appstore" : value
    }()

    static let appGroup: String = {
        let value = info("TraklyAppGroup")
        return value.isEmpty ? "group.info.trakly.app" : value
    }()

    /// `hello.features` of iOS 1.0.0 (§B4.4): Android's plus `scan` and `lock`.
    static let features: [String] = ["chrome", "intake", "reader", "scan", "print", "share", "download", "file.save", "lock", "shareEntry", "clipboard"]

    /// The token the panel WebViews add to WebKit's own user agent (§B1): `Mobile/15E148` is WebKit's, kept.
    static var userAgentName: String {
        "Mobile/15E148 TraklyApp/\(version) (ios; \(build); \(store))"
    }

    /// A UI test run (launch argument `-TraklyUITest`, Debug builds only).
    static let uiTest: Bool = {
        #if DEBUG
            return ProcessInfo.processInfo.arguments.contains("-TraklyUITest")
        #else
            return false
        #endif
    }()

    /// A Debug launch argument's value (`-Name value`), else nil; always nil in Release.
    static func testArgument(_ name: String) -> String? {
        #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-" + name), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        #else
            return nil
        #endif
    }

    static func url(_ path: String) -> URL? {
        URL(string: origin + path)
    }
}
