import Foundation

/// Native image fetches (docs/specs/phase10-apps-and-stores.md D11, §I3, §E5): which product image URLs native may fetch
/// and which resolved addresses it may connect to. Pure; the port of Android's `core/ImageAddress.kt`
/// (`ImageAddressTests`).
///
/// - `allowedImage`: a public https image named in the product the page returned for that row (its `images` or a
///   variant's `image`) and, for `source: 'capture'`, also present in the capture JSON the reader produced; it must pass
///   the policy (§I3: no IP literal, no reserved or denied name, https, port 443);
/// - `isPublic`: every resolved address must be public: no loopback, unspecified, `0.0.0.0/8`, private, link-local,
///   CGNAT, unique local, multicast or broadcast, and no IPv4-mapped or IPv4-compatible form of these.
public enum ImageAddress {
    /// The image URLs a product names: `images` and every variant's `image`.
    public static func productImages(_ product: JSONObject) -> Set<String> {
        var out = Set((product.array("images") ?? []).compactMap(\.stringValue))
        for variant in product.array("variants") ?? [] {
            if let image = variant.objectValue?.string("image") {
                out.insert(image)
            }
        }
        return out
    }

    /// Whether the capture JSON text mentions `url` (as written, with `\/` escapes, or without its scheme).
    public static func captureMentions(_ capture: String, _ url: String) -> Bool {
        guard let parsed = Url.parse(url) else { return false }
        let href = parsed.href
        let noScheme = href.firstIndex(of: ":").map { String(href[href.index(after: $0)...]) } ?? href
        return [url, href, noScheme].contains { candidate in
            candidate.count > 8 && (capture.contains(candidate) || capture.contains(candidate.replacingOccurrences(of: "/", with: "\\/")))
        }
    }

    /// Whether native may fetch `url` for a row whose product is `product` (source `source`); `capture` is the capture
    /// JSON of that row's read (`source: 'capture'` only). `dev` = the Debug policy flag (the local fixture shops).
    public static func allowedImage(_ url: String, product: JSONObject, source: String, capture: String?, dev: Bool) -> Bool {
        if !productImages(product).contains(url) { return false }
        if !Policy.check(url, dev: dev).ok { return false }
        if source == "capture" {
            guard let capture, captureMentions(capture, url) else { return false }
        }
        return true
    }

    /// Whether `url` is one of the local fixture shops of a Debug build (their addresses are loopback by design).
    public static func isDevFixture(_ url: String, dev: Bool) -> Bool {
        guard dev, let parsed = Url.parse(url), let origin = parsed.origin else { return false }
        return Limits.devOrigins.contains(origin) && !Limits.devShopPath.isEmpty && parsed.pathname.hasPrefix(Limits.devShopPath)
    }

    /// Whether one resolved address (4 or 16 bytes) is public.
    public static func isPublic(_ address: [UInt8]) -> Bool {
        switch address.count {
        case 4: return isPublicV4(address)
        case 16: return isPublicV6(address)
        default: return false
        }
    }

    /// Every address public, and at least one.
    public static func allPublic(_ addresses: [[UInt8]]) -> Bool {
        !addresses.isEmpty && addresses.allSatisfy(isPublic)
    }

    private static func isPublicV4(_ b: [UInt8]) -> Bool {
        let a = Int(b[0])
        let second = Int(b[1])
        return !(
            a == 0 || // 0.0.0.0/8 (unspecified)
                a == 10 || // private
                a == 127 || // loopback
                (a == 100 && (64 ... 127).contains(second)) || // CGNAT 100.64/10
                (a == 169 && second == 254) || // link-local
                (a == 172 && (16 ... 31).contains(second)) || // private
                (a == 192 && second == 168) || // private
                (a == 192 && second == 0 && b[2] == 0) || // IETF protocol assignments 192.0.0/24
                // 198.18/15 is not refused (§I3; fixer 2026-10-24): the common iOS and Android proxy and VPN clients
                // answer DNS with "fake IPs" from it, and refusing it lost every product photo behind them.
                a >= 224 // multicast 224/4, reserved 240/4, broadcast
        )
    }

    private static func isPublicV6(_ b: [UInt8]) -> Bool {
        let allZeroPrefix = (0 ..< 10).allSatisfy { b[$0] == 0 }
        // IPv4-mapped ::ffff:a.b.c.d and IPv4-compatible ::a.b.c.d: judged as their IPv4 address.
        if allZeroPrefix && b[10] == 0xFF && b[11] == 0xFF {
            return isPublicV4(Array(b[12 ..< 16]))
        }
        if allZeroPrefix && b[10] == 0 && b[11] == 0 {
            let rest = Array(b[12 ..< 16])
            // :: (unspecified), ::1 (loopback) and the deprecated compatible forms.
            return rest.contains { $0 != 0 } && !(rest[0] == 0 && rest[1] == 0 && rest[2] == 0 && rest[3] == 1) && isPublicV4(rest)
        }
        // NAT64 64:ff9b::/96 (DNS64 on IPv6-only mobile networks): judged as the IPv4 address it carries.
        if b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xFF && b[3] == 0x9B && (4 ..< 12).allSatisfy({ b[$0] == 0 }) {
            return isPublicV4(Array(b[12 ..< 16]))
        }
        return !(
            (b[0] & 0xFE) == 0xFC || // unique local fc00::/7
                (b[0] == 0xFE && (b[1] & 0xC0) == 0x80) || // link-local fe80::/10
                (b[0] == 0xFE && (b[1] & 0xC0) == 0xC0) || // site-local fec0::/10 (deprecated)
                b[0] == 0xFF || // multicast
                (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0D && b[3] == 0xB8) // documentation 2001:db8::/32
        )
    }

    /// The bytes of a numeric address text (`URLSessionTaskTransactionMetrics.remoteAddress`, `inet_ntop` output), or
    /// nil: dotted IPv4 or IPv6 (with an optional zone after `%`).
    public static func bytes(ofNumericAddress text: String) -> [UInt8]? {
        let trimmed = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, !trimmed.contains(":") {
            var out: [UInt8] = []
            for part in parts {
                guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), let value = UInt8(part) else { return nil }
                out.append(value)
            }
            return out
        }
        guard let pieces = Url.parseIpv6(Array(trimmed.unicodeScalars)) else { return nil }
        return pieces.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
    }
}

/// The same-origin rule of native `download` and its redirect hops (D6, §E9, §I5): the first URL and every hop on the
/// build's origin, path under `/app/`, at most three hops. Pure; the port of Android's `core/Redirects.kt`.
public enum Redirects {
    public static func allowed(_ url: String, trusted: String) -> Bool {
        guard let parsed = Url.parse(url) else { return false }
        return parsed.origin == trusted && parsed.noCredentials && parsed.pathname.hasPrefix("/app/")
    }

    /// Whether the `hop`-th redirect (1-based) to `url` may be followed.
    public static func follow(_ url: String, hop: Int, trusted: String) -> Bool {
        hop <= Limits.downloadHops && allowed(url, trusted: trusted)
    }
}
