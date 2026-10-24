import Foundation

/// The first product link of a text (docs/specs/phase10-apps-and-stores.md §A2 F3, §E8): shared text, the clipboard and
/// the composer's link field. The same rule as `isWebLink` of the web and Android's `core/LinkText.kt`
/// (`shared/fixtures/link-cases.json`). Never logs the text. Pure; no `URL(string:)` (§E10).
public enum LinkText {
    /// Invisible format marks that Persian apps and keyboards put around a Latin run; none is ever part of a link: the
    /// zero-width space and joiners, the LRM / RLM marks, the bidi embeddings and isolates, the BOM.
    static func isBreak(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if scalar.properties.isWhitespace { return true }
        return (0x200B ... 0x200F).contains(value) || (0x202A ... 0x202E).contains(value) || (0x2066 ... 0x2069).contains(value) || value == 0xFEFF
    }

    /// Punctuation that closes a sentence or a bracket around a shared link, trimmed from its end: the ASCII closers,
    /// the Persian closing quote, and the Persian / Arabic comma, semicolon, question mark and full stop.
    static let trailing: Set<Unicode.Scalar> = Set(")]}>,.;!?\u{00BB}\"'\u{060C}\u{061B}\u{061F}\u{06D4}".unicodeScalars)

    /// The first `https?://` run of `text` up to whitespace or a format mark, trailing punctuation trimmed, `http:`
    /// upgraded to `https:`; nil when there is none. With `dev` (the Debug policy flag only) a link of a local fixture
    /// shop (`Limits.devOrigins`, which a debug build reads over http only) keeps `http:`.
    public static func firstProductUrl(_ text: String?, dev: Bool = false) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let scalars = Array(text.unicodeScalars)
        guard let start = runStart(scalars) else { return nil }
        var end = start
        while end < scalars.count && !isBreak(scalars[end]) { end += 1 }
        var run = Array(scalars[start ..< end])
        while let last = run.last, trailing.contains(last) { run.removeLast() }
        let trimmed = Url.string(run)
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let afterScheme = String(trimmed[trimmed.index(after: colon)...])
        let lower = trimmed.lowercased()

        if dev && Limits.devOrigins.contains(where: { lower.hasPrefix($0 + "/") }) {
            return "http:" + afterScheme
        }

        let upgraded = "https:" + afterScheme
        return upgraded.count > "https://".count ? upgraded : nil
    }

    /// The index of the first `http://` or `https://` (any case) followed by at least one character of a link (the
    /// regex `https?://[^\s…]+` of the other ports: a scheme with nothing after it is skipped and the search goes on).
    private static func runStart(_ scalars: [Unicode.Scalar]) -> Int? {
        let lower = scalars.map { scalar -> Unicode.Scalar in
            if scalar.value >= 0x41 && scalar.value <= 0x5A, let mapped = Unicode.Scalar(scalar.value + 0x20) { return mapped }
            return scalar
        }
        let http = Array("http://".unicodeScalars)
        let https = Array("https://".unicodeScalars)
        var index = 0
        while index < lower.count {
            for prefix in [https, http] where starts(lower, at: index, with: prefix) {
                let next = index + prefix.count
                if next < lower.count && !isBreak(lower[next]) {
                    return index
                }
            }
            index += 1
        }
        return nil
    }

    private static func starts(_ scalars: [Unicode.Scalar], at index: Int, with prefix: [Unicode.Scalar]) -> Bool {
        guard index + prefix.count <= scalars.count else { return false }
        for offset in 0 ..< prefix.count where scalars[index + offset] != prefix[offset] {
            return false
        }
        return true
    }
}
