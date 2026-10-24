import Foundation

/// File names of saved and downloaded files (docs/specs/phase10-apps-and-stores.md D23, §I5): path separators, control
/// characters, `..`, leading dots and Windows-reserved names removed, spaces collapsed, at most 120 characters with the
/// extension kept, the extension chosen from the MIME type when missing. Pure; the port of Android's
/// `core/FileNames.kt` (`FileNamesTests`).
public enum FileNames {
    public static let maxChars = 120

    /// Extensions of the `file.save` MIME types and the usual download types.
    public static let extensions: [String: String] = [
        "text/csv": "csv",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
        "application/pdf": "pdf",
        "image/png": "png",
        "image/jpeg": "jpg",
        "image/webp": "webp",
        "text/plain": "txt",
        "application/zip": "zip",
    ]

    private static let reserved: Set<String> = {
        var names: Set<String> = ["con", "prn", "aux", "nul"]
        for digit in 0 ... 9 {
            names.insert("com\(digit)")
            names.insert("lpt\(digit)")
        }
        return names
    }()

    private static let removed: Set<Unicode.Scalar> = Set("<>:\"|?*".unicodeScalars)

    /// A safe name for `name` (nil or blank → «trakly»), with an extension from `mime` when it has none.
    public static func sanitize(_ name: String?, mime: String?) -> String {
        var text = name ?? ""
        if let slash = text.lastIndex(of: "/") { text = String(text[text.index(after: slash)...]) }
        if let backslash = text.lastIndex(of: "\\") { text = String(text[text.index(after: backslash)...]) }
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !(scalar.value < 0x20 || scalar.value == 0x7F || removed.contains(scalar)) {
            kept.append(scalar)
        }
        text = String(kept).replacingOccurrences(of: "..", with: ".")
        text = collapseSpaces(text).trimmingCharacters(in: .whitespaces)
        while text.hasPrefix(".") { text.removeFirst() }
        text = text.trimmingCharacters(in: .whitespaces)

        let wanted = mime.map { $0.split(separator: ";").first.map(String.init) ?? $0 }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .flatMap { extensions[$0] }
        var base = text
        var ext = ""
        if let dot = text.lastIndex(of: ".") {
            base = String(text[text.startIndex ..< dot])
            ext = String(text[text.index(after: dot)...])
        }
        if ext.isEmpty || ext.count > 8 || !ext.allSatisfy({ $0.isLetter || $0.isNumber }) {
            base = text
            ext = wanted ?? ""
        }
        base = base.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix(".") { base.removeLast() }
        base = base.trimmingCharacters(in: .whitespaces)
        if base.isEmpty {
            base = "trakly"
        } else if reserved.contains(base.lowercased()) {
            base = "_" + base
        }
        let suffix = ext.isEmpty ? "" : "." + ext
        let room = max(1, maxChars - suffix.count)
        if base.count > room {
            base = String(base.prefix(room)).trimmingCharacters(in: .whitespaces)
        }
        return base + suffix
    }

    private static func collapseSpaces(_ text: String) -> String {
        var out = ""
        var space = false
        for character in text {
            if character.isWhitespace {
                if !space { out.append(" ") }
                space = true
            } else {
                out.append(character)
                space = false
            }
        }
        return out
    }
}
