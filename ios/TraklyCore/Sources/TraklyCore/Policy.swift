import Foundation

/// Port of `checkTarget(url, {dev, sampleUrls})` of `extension/src/policy.js` (docs/specs/phase9-phone-capture.md D11;
/// phase 10 D9, §E5, §I3) and of Android's `core/Policy.kt`: which URLs the reader may open and native code may fetch.
/// It runs on the requested URL, on every main-frame URL of the reader, on `capture.url` and on every image URL.
///
/// Parsing is `Url` (WHATWG), never Foundation's `URL`. `ok` and `reason` equal the JavaScript for every case of
/// `shared/fixtures/policy-cases.json` (`PolicyTests`). `check(_:dev:)` with `dev` true (the Debug build flag
/// `TRAKLY_DEV_POLICY` only) also lets the local fixture shops (`Limits.devOrigins` + `Limits.devShopPath`) and the
/// local sample page through, before the https, IP-literal and port rules.
public enum Policy {
    /// The sample pages the app may read (phase 9 B8): the guide's sample and the store reviewer's sample.
    public static let appSampleUrls: [String] = [
        "https://erp.trakly.info/extension/sample",
        "https://erp.trakly.info/extension/sample?review=1",
    ]

    /// Debug builds: the production samples plus the sample page of every local origin (`devSampleUrls`).
    public static var devSampleUrls: [String] { appSampleUrls + Limits.devOrigins.map { $0 + "/extension/sample" } }

    /// The reasons of `TARGET_REASONS` in `policy.js`, in the same order.
    public static let targetReasons: [String] = [
        "invalid", "scheme", "trailing_dot", "credentials", "port", "ip", "reserved", "denied", "personal", "too_long",
    ]

    public enum Verdict: Equatable, Sendable {
        /// `url` is the encoded href (not necessarily equal to the JavaScript `href`).
        case ok(url: String)
        case refused(reason: String)

        public var ok: Bool {
            if case .ok = self { return true }
            return false
        }

        public var reason: String? {
            if case let .refused(reason) = self { return reason }
            return nil
        }

        /// "ok" or the reason (tests).
        public var wire: String { reason ?? "ok" }
    }

    private static let personal: NSRegularExpression = {
        // The pattern is a constant of this file; a failure here is a programming error caught by every test run.
        try! NSRegularExpression(pattern: Limits.personalPath, options: [.caseInsensitive])
    }()

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// The app's rule (§E5): `dev` = the Debug build flag; the sample list follows it.
    public static func check(_ url: String, dev: Bool) -> Verdict {
        checkTarget(url, sampleUrls: dev ? devSampleUrls : appSampleUrls, dev: dev)
    }

    /// Every rule of `checkTarget()` in its order: https only (or a local fixture shop in a debug build), no trailing
    /// dot, no credentials, port 443, no IP literal, a dotted public name outside the reserved suffixes, not denied
    /// except a URL exactly in `sampleUrls`, not an account / cart / wishlist path, at most 2048 characters.
    public static func checkTarget(_ url: String, sampleUrls: [String] = appSampleUrls, dev: Bool = false) -> Verdict {
        if url.isEmpty {
            return .refused(reason: "invalid")
        }
        guard let parsed = Url.parse(url) else {
            return .refused(reason: "invalid")
        }
        let sample = sampleUrls.contains(url) || sampleUrls.contains(parsed.href)

        if dev, let origin = parsed.origin, Limits.devOrigins.contains(origin), parsed.noCredentials {
            if !(parsed.path.hasPrefix(Limits.devShopPath) && !Limits.devShopPath.isEmpty) && !sample {
                return .refused(reason: "reserved")
            }
            return finish(parsed, url)
        }

        if parsed.scheme != "https" {
            return .refused(reason: "scheme")
        }
        if case let .domain(name) = parsed.host, name.hasSuffix(".") {
            return .refused(reason: "trailing_dot")
        }
        if !parsed.noCredentials {
            return .refused(reason: "credentials")
        }
        if parsed.port != nil {
            return .refused(reason: "port")
        }
        guard case let .domain(name) = parsed.host else {
            return .refused(reason: "ip")
        }
        if !name.contains(".") || Limits.reservedSuffixes.contains(where: { underSuffix(name, $0) }) {
            return .refused(reason: "reserved")
        }
        if !sample && (Limits.denyHosts.contains(name) || Limits.denySuffixes.contains(where: { underSuffix(name, $0) })) {
            return .refused(reason: "denied")
        }
        return finish(parsed, url)
    }

    private static func finish(_ parsed: Url, _ url: String) -> Verdict {
        if matches(personal, parsed.path) {
            return .refused(reason: "personal")
        }
        if url.utf16.count > Limits.urlChars || parsed.href.utf16.count > Limits.urlChars {
            return .refused(reason: "too_long")
        }
        return .ok(url: parsed.href)
    }

    /// Whether `url` passes `check(_:dev:)`.
    public static func allowed(_ url: String?, dev: Bool) -> Bool {
        guard let url else { return false }
        return check(url, dev: dev).ok
    }

    /// The lower-cased host of an http(s) URL, or nil (as `hostOf()` of `policy.js`).
    public static func hostOf(_ url: String?) -> String? {
        guard let url else { return nil }
        return Url.parse(url)?.hostName
    }

    /// The shop key of a host or URL, exactly as `hostKey()` of `policy.js`: nil for a host that ends with `.` or has
    /// fewer than two labels; otherwise lower-cased with one leading `www.` or `m.` stripped.
    public static func hostKey(_ hostOrUrl: String?) -> String? {
        guard let hostOrUrl else { return nil }
        let host = hostOrUrl.contains("/") ? (hostOf(hostOrUrl) ?? "") : hostOrUrl.trimmingCharacters(in: .whitespaces).lowercased()
        if host.isEmpty || host.hasSuffix(".") {
            return nil
        }
        var key = host
        if key.hasPrefix("www.") {
            key = String(key.dropFirst(4))
        } else if key.hasPrefix("m.") {
            key = String(key.dropFirst(2))
        }
        let labels = key.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count < 2 || labels.contains(where: { $0.isEmpty }) ? nil : key
    }

    private static func underSuffix(_ host: String, _ suffix: String) -> Bool {
        host == suffix || host.hasSuffix("." + suffix)
    }
}
