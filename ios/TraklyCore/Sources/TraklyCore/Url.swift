import Foundation

/// The host of a special URL (WHATWG): a domain (ASCII, lower case), an IPv4 address or an IPv6 address.
public enum UrlHost: Equatable, Sendable {
    case domain(String)
    case ipv4(UInt32)
    case ipv6([UInt16])

    /// The serialised host (`url.hostname`).
    public var text: String {
        switch self {
        case let .domain(name):
            return name
        case let .ipv4(value):
            return [24, 16, 8, 0].map { String((value >> UInt32($0)) & 0xFF) }.joined(separator: ".")
        case let .ipv6(pieces):
            return "[" + UrlHost.serializeIpv6(pieces) + "]"
        }
    }

    /// WHATWG IPv6 serializer: lower-case hex, the first longest run of two or more zero pieces compressed.
    static func serializeIpv6(_ pieces: [UInt16]) -> String {
        var bestStart = -1
        var bestLength = 1
        var index = 0
        while index < pieces.count {
            if pieces[index] == 0 {
                var end = index
                while end < pieces.count && pieces[end] == 0 { end += 1 }
                if end - index > bestLength {
                    bestStart = index
                    bestLength = end - index
                }
                index = end
            } else {
                index += 1
            }
        }
        var out = ""
        var ignore0 = false
        for (position, piece) in pieces.enumerated() {
            if ignore0 && piece == 0 { continue }
            ignore0 = false
            if position == bestStart {
                out += position == 0 ? "::" : ":"
                ignore0 = true
                continue
            }
            out += String(piece, radix: 16)
            if position != pieces.count - 1 { out += ":" }
        }
        return out
    }
}

/// The WHATWG URL subset of the app (docs/specs/phase10-apps-and-stores.md §E2 `TraklyCore/Url`, §I3), parsed like
/// `new URL(input)` for what the policy, the bridge and the navigation rules need: a port of Android's `core/Url.kt`.
/// Special schemes (http, https, ws, wss, ftp) get the WHATWG host parser (IDNA with its own Punycode, the IPv4 forms,
/// IPv6), dot segments and percent-encoding; other schemes keep their text after the colon as an opaque path (`tel:`,
/// `mailto:`, `javascript:` …). Never Foundation's `URL` for a decision: CFURL on devices and swift-foundation on
/// Linux differ (§I3). Pure.
public struct Url: Equatable, Sendable {
    public let scheme: String
    public let username: String
    public let password: String
    public let host: UrlHost?
    public let port: Int?
    public let path: String
    public let query: String?
    public let fragment: String?

    public init(scheme: String, username: String = "", password: String = "", host: UrlHost?, port: Int?, path: String, query: String?, fragment: String?) {
        self.scheme = scheme
        self.username = username
        self.password = password
        self.host = host
        self.port = port
        self.path = path
        self.query = query
        self.fragment = fragment
    }

    public var href: String {
        var out = scheme + ":"
        if let host {
            out += "//"
            if !username.isEmpty || !password.isEmpty {
                out += username
                if !password.isEmpty { out += ":" + password }
                out += "@"
            }
            out += host.text
            if let port { out += ":" + String(port) }
        }
        out += path
        if let query { out += "?" + query }
        if let fragment { out += "#" + fragment }
        return out
    }

    /// The serialised host (`hostname`), or nil for a non-special URL.
    public var hostName: String? { host?.text }

    /// `url.origin` of a special URL (`scheme://host[:port]`, the default port left out), else nil ("null").
    public var origin: String? {
        guard let name = hostName else { return nil }
        return scheme + "://" + name + (port.map { ":" + String($0) } ?? "")
    }

    public var pathname: String { path }

    public var noCredentials: Bool { username.isEmpty && password.isEmpty }

    /// The same URL with another query.
    public func withQuery(_ query: String?) -> Url {
        Url(scheme: scheme, username: username, password: password, host: host, port: port, path: path, query: query, fragment: fragment)
    }

    // MARK: - parsing

    static let defaultPorts: [String: Int] = ["http": 80, "https": 443, "ws": 80, "wss": 443, "ftp": 21]

    /// Parses `input` like `new URL(input)` for what the policy needs, or nil where `new URL` throws.
    public static func parse(_ input: String) -> Url? {
        // WHATWG trims C0 controls and spaces (U+0000 to U+0020) and removes every tab and newline.
        var scalars = Array(input.unicodeScalars)
        while let first = scalars.first, first.value <= 0x20 { scalars.removeFirst() }
        while let last = scalars.last, last.value <= 0x20 { scalars.removeLast() }
        scalars.removeAll { $0 == "\t" || $0 == "\n" || $0 == "\r" }

        guard let colon = schemeEnd(scalars) else { return nil }
        let scheme = String(String.UnicodeScalarView(scalars[0 ..< colon])).lowercased()
        let rest = Array(scalars[(colon + 1)...])

        if defaultPorts[scheme] == nil {
            // file:, javascript:, data:, chrome: … parse in JavaScript and are refused as `scheme`.
            return Url(scheme: scheme, host: nil, port: nil, path: string(rest), query: nil, fragment: nil)
        }

        return parseSpecial(scheme: scheme, rest: rest)
    }

    /// The index of the colon after a valid scheme (`^[A-Za-z][A-Za-z0-9+.-]*:`), or nil.
    private static func schemeEnd(_ scalars: [Unicode.Scalar]) -> Int? {
        guard let first = scalars.first, isAsciiLetter(first) else { return nil }
        var index = 1
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == ":" { return index }
            if !(isAsciiLetter(scalar) || isAsciiDigit(scalar) || scalar == "+" || scalar == "." || scalar == "-") {
                return nil
            }
            index += 1
        }
        return nil
    }

    static func isAsciiLetter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x41 && scalar.value <= 0x5A) || (scalar.value >= 0x61 && scalar.value <= 0x7A)
    }

    static func isAsciiDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x30 && scalar.value <= 0x39
    }

    static func isHex(_ scalar: Unicode.Scalar) -> Bool {
        isAsciiDigit(scalar) || (scalar.value >= 0x41 && scalar.value <= 0x46) || (scalar.value >= 0x61 && scalar.value <= 0x66)
    }

    static func string<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    private static func parseSpecial(scheme: String, rest: [Unicode.Scalar]) -> Url? {
        var start = 0
        while start < rest.count && (rest[start] == "/" || rest[start] == "\\") { start += 1 }
        var end = start
        while end < rest.count && !(rest[end] == "/" || rest[end] == "\\" || rest[end] == "?" || rest[end] == "#") { end += 1 }

        let authority = Array(rest[start ..< end])
        let after = Array(rest[end...])
        let at = authority.lastIndex(of: "@")
        let userinfo = at.map { Array(authority[0 ..< $0]) } ?? []
        let hostPort = at.map { Array(authority[($0 + 1)...]) } ?? authority

        if hostPort.isEmpty { return nil }

        let colonInUser = userinfo.firstIndex(of: ":")
        let username = encode(colonInUser.map { Array(userinfo[0 ..< $0]) } ?? userinfo, set: userinfoSet)
        let password = colonInUser.map { encode(Array(userinfo[($0 + 1)...]), set: userinfoSet) } ?? ""

        var hostText: [Unicode.Scalar]
        var portText: [Unicode.Scalar]?
        if hostPort.first == "[" {
            guard let close = hostPort.firstIndex(of: "]") else { return nil }
            hostText = Array(hostPort[0 ... close])
            let tail = Array(hostPort[(close + 1)...])
            if !tail.isEmpty && tail.first != ":" { return nil }
            portText = tail.isEmpty ? nil : Array(tail.dropFirst())
        } else if let colon = hostPort.firstIndex(of: ":") {
            hostText = Array(hostPort[0 ..< colon])
            portText = Array(hostPort[(colon + 1)...])
        } else {
            hostText = hostPort
            portText = nil
        }

        guard let host = parseHost(hostText) else { return nil }

        var port: Int?
        if let portText, !portText.isEmpty {
            if portText.contains(where: { !isAsciiDigit($0) }) { return nil }
            var digits = portText
            while digits.count > 1 && digits.first == "0" { digits.removeFirst() }
            if digits.count > 5 { return nil }
            guard let value = Int(string(digits)), value <= 65535 else { return nil }
            port = value == defaultPorts[scheme] ? nil : value
        }

        let hash = after.firstIndex(of: "#")
        let beforeHash = hash.map { Array(after[0 ..< $0]) } ?? after
        let fragment = hash.map { encode(Array(after[($0 + 1)...]), set: fragmentSet) }
        let question = beforeHash.firstIndex(of: "?")
        let rawPath = question.map { Array(beforeHash[0 ..< $0]) } ?? beforeHash
        let query = question.map { encode(Array(beforeHash[($0 + 1)...]), set: querySet) }

        return Url(scheme: scheme, username: username, password: password, host: host, port: port, path: path(rawPath), query: query, fragment: fragment)
    }

    /// WHATWG path state for special URLs: `\` is `/`, dot segments resolved, segments percent-encoded.
    private static func path(_ raw: [Unicode.Scalar]) -> String {
        if raw.isEmpty { return "/" }
        let slash: Unicode.Scalar = "/"
        let normalised = raw.map { $0 == "\\" ? slash : $0 }
        var segments: [[Unicode.Scalar]] = [[]]
        for scalar in normalised {
            if scalar == "/" {
                segments.append([])
            } else {
                segments[segments.count - 1].append(scalar)
            }
        }
        segments.removeFirst()
        var out: [String] = []
        for (index, segment) in segments.enumerated() {
            let last = index == segments.count - 1
            switch string(segment).lowercased() {
            case "..", ".%2e", "%2e.", "%2e%2e":
                if !out.isEmpty { out.removeLast() }
                if last { out.append("") }
            case ".", "%2e":
                if last { out.append("") }
            default:
                out.append(encode(segment, set: pathSet))
            }
        }
        return "/" + out.joined(separator: "/")
    }

    // MARK: - host

    private static let forbiddenHost: Set<Unicode.Scalar> = Set("#%/:<>?@[\\]^|".unicodeScalars)

    /// WHATWG host parser (special schemes): IPv6 literal, percent-decoding, domain to ASCII, IPv4.
    static func parseHost(_ raw: [Unicode.Scalar]) -> UrlHost? {
        if raw.isEmpty { return nil }
        if raw.first == "[" {
            guard raw.last == "]", raw.count >= 3 else { return nil }
            return parseIpv6(Array(raw[1 ..< (raw.count - 1)])).map { .ipv6($0) }
        }
        guard let decoded = percentDecode(raw), let ascii = Idna.toAscii(decoded) else { return nil }
        let scalars = Array(ascii.unicodeScalars)
        if scalars.isEmpty || scalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7F || forbiddenHost.contains($0) }) {
            return nil
        }
        if endsInNumber(ascii) {
            return ipv4(ascii).map { .ipv4($0) }
        }
        return .domain(ascii)
    }

    /// WHATWG "ends in a number": the last non-empty label is all digits, or an IPv4 number (`0x…`).
    private static func endsInNumber(_ host: String) -> Bool {
        var parts = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" {
            if parts.count == 1 { return false }
            parts.removeLast()
        }
        guard let last = parts.last else { return false }
        if !last.isEmpty && last.unicodeScalars.allSatisfy(isAsciiDigit) { return true }
        return ipv4Number(last) != nil
    }

    /// WHATWG IPv4 parser: 1 to 4 parts, decimal, `0x` hex and leading-`0` octal parts, range checks.
    private static func ipv4(_ host: String) -> UInt32? {
        var parts = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" && parts.count > 1 { parts.removeLast() }
        if parts.count > 4 { return nil }
        var numbers: [Int64] = []
        for part in parts {
            guard let number = ipv4Number(part) else { return nil }
            numbers.append(number)
        }
        if numbers.dropLast().contains(where: { $0 > 255 }) { return nil }
        guard let last = numbers.last else { return nil }
        let limit = Int64(1) << Int64(8 * (5 - numbers.count))
        if last >= limit { return nil }
        var value = last
        for (index, number) in numbers.dropLast().enumerated() {
            value += number << Int64(8 * (3 - index))
        }
        return UInt32(truncatingIfNeeded: value)
    }

    private static func ipv4Number(_ part: String) -> Int64? {
        if part.isEmpty { return nil }
        var text = Substring(part)
        var radix = 10
        if text.count >= 2 && (text.hasPrefix("0x") || text.hasPrefix("0X")) {
            text = text.dropFirst(2)
            radix = 16
        } else if text.count >= 2 && text.hasPrefix("0") {
            text = text.dropFirst()
            radix = 8
        }
        if text.isEmpty { return 0 }
        for scalar in text.unicodeScalars {
            guard scalar.isASCII, let digit = Int(String(scalar), radix: 16), digit < radix else { return nil }
        }
        // Anything above 2^32 is out of range anyway; cap the digits so the value never overflows.
        let significant = text.drop { $0 == "0" }
        if significant.count > 12 { return Int64.max / 2 }
        return Int64(text, radix: radix)
    }

    /// WHATWG IPv6 parser (the bracketed text without its brackets): eight 16-bit pieces, or nil.
    static func parseIpv6(_ input: [Unicode.Scalar]) -> [UInt16]? {
        var address = [UInt16](repeating: 0, count: 8)
        var pieceIndex = 0
        var compress: Int?
        var pointer = 0
        let count = input.count
        func at(_ index: Int) -> Unicode.Scalar? { index < count ? input[index] : nil }

        if at(pointer) == ":" {
            guard at(pointer + 1) == ":" else { return nil }
            pointer += 2
            pieceIndex += 1
            compress = pieceIndex
        }
        while let current = at(pointer) {
            if pieceIndex == 8 { return nil }
            if current == ":" {
                if compress != nil { return nil }
                pointer += 1
                pieceIndex += 1
                compress = pieceIndex
                continue
            }
            var value: UInt16 = 0
            var length = 0
            while length < 4, let scalar = at(pointer), isHex(scalar) {
                value = value * 0x10 + UInt16(Int(String(scalar), radix: 16) ?? 0)
                pointer += 1
                length += 1
            }
            if at(pointer) == "." {
                if length == 0 { return nil }
                pointer -= length
                if pieceIndex > 6 { return nil }
                var numbersSeen = 0
                while at(pointer) != nil {
                    var ipv4Piece: Int?
                    if numbersSeen > 0 {
                        if at(pointer) == "." && numbersSeen < 4 {
                            pointer += 1
                        } else {
                            return nil
                        }
                    }
                    guard let first = at(pointer), isAsciiDigit(first) else { return nil }
                    while let scalar = at(pointer), isAsciiDigit(scalar) {
                        let number = Int(scalar.value - 0x30)
                        if ipv4Piece == nil {
                            ipv4Piece = number
                        } else if ipv4Piece == 0 {
                            return nil
                        } else {
                            ipv4Piece = (ipv4Piece ?? 0) * 10 + number
                        }
                        if (ipv4Piece ?? 0) > 255 { return nil }
                        pointer += 1
                    }
                    address[pieceIndex] = address[pieceIndex] * 0x100 + UInt16(ipv4Piece ?? 0)
                    numbersSeen += 1
                    if numbersSeen == 2 || numbersSeen == 4 { pieceIndex += 1 }
                }
                if numbersSeen != 4 { return nil }
                break
            } else if at(pointer) == ":" {
                pointer += 1
                if at(pointer) == nil { return nil }
            } else if at(pointer) != nil {
                return nil
            }
            address[pieceIndex] = value
            pieceIndex += 1
        }
        if let compress {
            var swaps = pieceIndex - compress
            pieceIndex = 7
            while pieceIndex != 0 && swaps > 0 {
                address.swapAt(pieceIndex, compress + swaps - 1)
                pieceIndex -= 1
                swaps -= 1
            }
        } else if pieceIndex != 8 {
            return nil
        }
        return address
    }

    private static func percentDecode(_ scalars: [Unicode.Scalar]) -> String? {
        if !scalars.contains("%") { return string(scalars) }
        var bytes: [UInt8] = []
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "%" && index + 2 < scalars.count && isHex(scalars[index + 1]) && isHex(scalars[index + 2]),
               let byte = UInt8(string([scalars[index + 1], scalars[index + 2]]), radix: 16)
            {
                bytes.append(byte)
                index += 3
            } else {
                bytes.append(contentsOf: Array(String(scalar).utf8))
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - percent-encoding

    // WHATWG percent-encode sets (beyond C0 controls and non-ASCII), plus what java.net.URI refuses (Android parity).
    private static let uriExtra = "|^`{}[]\\"
    static let pathSet: Set<Unicode.Scalar> = Set((" \"#<>?^`{}" + uriExtra).unicodeScalars)
    static let querySet: Set<Unicode.Scalar> = Set((" \"#<>'" + uriExtra).unicodeScalars)
    static let fragmentSet: Set<Unicode.Scalar> = Set((" \"<>`#" + uriExtra).unicodeScalars)
    static let userinfoSet: Set<Unicode.Scalar> = Set((" \"#<>?`{}/:;=@[\\]^|" + uriExtra).unicodeScalars)

    private static let hexDigits: [Character] = Array("0123456789ABCDEF")

    /// Percent-encodes C0 controls, DEL, non-ASCII (as UTF-8), the characters of `set` and stray `%`.
    static func encode(_ scalars: [Unicode.Scalar], set: Set<Unicode.Scalar>) -> String {
        var out = ""
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "%" {
                let valid = index + 2 < scalars.count && isHex(scalars[index + 1]) && isHex(scalars[index + 2])
                out += valid ? "%" : "%25"
            } else if scalar.value < 0x20 || scalar.value >= 0x7F || set.contains(scalar) {
                for byte in String(scalar).utf8 {
                    out.append("%")
                    out.append(hexDigits[Int(byte >> 4)])
                    out.append(hexDigits[Int(byte & 0xF)])
                }
            } else {
                out.unicodeScalars.append(scalar)
            }
            index += 1
        }
        return out
    }
}

/// Domain to ASCII (WHATWG / UTS #46, the part the app needs): the label separators U+3002, U+FF0E and U+FF61 become
/// `.`, the text is case-folded and NFKC-normalised, and every label with non-ASCII is written as Punycode with its
/// `xn--` prefix (RFC 3492). Pure.
public enum Idna {
    public static func toAscii(_ host: String) -> String? {
        if host.unicodeScalars.allSatisfy({ $0.value < 0x80 }) {
            return host.lowercased()
        }
        var mapped = ""
        for scalar in host.unicodeScalars {
            switch scalar.value {
            case 0x3002, 0xFF0E, 0xFF61: mapped += "."
            default: mapped.unicodeScalars.append(scalar)
            }
        }
        let folded = mapped.lowercased().precomposedStringWithCompatibilityMapping.lowercased()
        var labels: [String] = []
        for label in folded.split(separator: ".", omittingEmptySubsequences: false) {
            let text = String(label)
            if text.unicodeScalars.allSatisfy({ $0.value < 0x80 }) {
                labels.append(text)
            } else {
                guard let encoded = Punycode.encode(text), !encoded.isEmpty, encoded.count + 4 <= 63 else { return nil }
                labels.append("xn--" + encoded)
            }
        }
        return labels.joined(separator: ".")
    }
}

/// RFC 3492 Punycode encoding (bootstring with the IDNA parameters).
public enum Punycode {
    private static let base = 36
    private static let tMin = 1
    private static let tMax = 26
    private static let skew = 38
    private static let damp = 700
    private static let initialBias = 72
    private static let initialN = 128

    private static func digit(_ value: Int) -> Character {
        let scalar = value < 26 ? UInt32(0x61 + value) : UInt32(0x30 + value - 26)
        return Character(Unicode.Scalar(scalar)!)
    }

    private static func adapt(_ deltaIn: Int, _ numPoints: Int, _ firstTime: Bool) -> Int {
        var delta = firstTime ? deltaIn / damp : deltaIn / 2
        delta += delta / numPoints
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + (((base - tMin + 1) * delta) / (delta + skew))
    }

    public static func encode(_ input: String) -> String? {
        let codes = input.unicodeScalars.map { Int($0.value) }
        var output = ""
        for code in codes where code < 0x80 {
            output.unicodeScalars.append(Unicode.Scalar(UInt8(code)))
        }
        let basicCount = output.unicodeScalars.count
        var handled = basicCount
        if basicCount > 0 { output += "-" }
        var n = initialN
        var delta = 0
        var bias = initialBias
        while handled < codes.count {
            guard let m = codes.filter({ $0 >= n }).min() else { return nil }
            let (product, overflow) = (m - n).multipliedReportingOverflow(by: handled + 1)
            if overflow { return nil }
            delta += product
            n = m
            for code in codes {
                if code < n {
                    delta += 1
                }
                if code == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                        if q < t { break }
                        output.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta, handled + 1, handled == basicCount)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return output
    }
}
