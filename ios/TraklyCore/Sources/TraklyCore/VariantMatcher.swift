import Foundation

/// The variant logic of the review sheet S6 (docs/specs/phase10-apps-and-stores.md §B6): ports of `matchingVariant()`
/// and `isValueAvailable()` of `components/orders/productImport.ts` (and Android's `core/VariantMatcher.kt`), proved on
/// `shared/fixtures/variant-cases.json` (`VariantMatcherTests`). Works on the `ImportedProduct` JSON exactly as
/// product-link answered it. Pure.
public enum VariantMatcher {
    public struct Option: Equatable, Sendable {
        public let name: String
        public let label: String
        public let values: [String]
    }

    static func variants(_ product: JSONObject) -> [JSONObject] {
        (product.array("variants") ?? []).compactMap(\.objectValue)
    }

    static func optionsOf(_ variant: JSONObject) -> JSONObject {
        variant.object("options") ?? JSONObject()
    }

    /// The variant that matches every chosen option (nil when none or when the product has no variants).
    public static func matching(_ product: JSONObject, _ chosen: [String: String]) -> JSONObject? {
        variants(product).first { variant in
            let options = optionsOf(variant)
            return chosen.allSatisfy { name, value in
                guard let have = options[name] else { return true }
                return have.stringValue == value
            }
        }
    }

    /// Whether some available variant has `name = value` together with the other chosen options.
    public static func isValueAvailable(_ product: JSONObject, _ chosen: [String: String], name: String, value: String) -> Bool {
        let all = variants(product)
        if all.isEmpty { return true }
        return all.contains { variant in
            let options = optionsOf(variant)
            if variant["available"] == .bool(false) { return false }
            guard options.string(name) == value else { return false }
            return chosen.allSatisfy { other, chosenValue in
                if other == name { return true }
                guard let have = options[other] else { return true }
                return have.stringValue == chosenValue
            }
        }
    }

    public static func options(_ product: JSONObject) -> [Option] {
        (product.array("options") ?? []).compactMap { raw in
            guard let option = raw.objectValue, let name = option.string("name") else { return nil }
            let values = (option.array("values") ?? []).compactMap(\.stringValue)
            return Option(name: name, label: option.string("label") ?? "", values: values)
        }
    }

    /// The options preselected when the sheet opens: an option with one value (the web dialog's rule).
    public static func preselected(_ product: JSONObject) -> [String: String] {
        var out: [String: String] = [:]
        for option in options(product) where option.values.count == 1 {
            out[option.name] = option.values[0]
        }
        return out
    }

    /// The labels of the options still missing a choice, in the product's order («بدون …»).
    public static func missingLabels(_ product: JSONObject, _ chosen: [String: String]) -> [String] {
        options(product).filter { (chosen[$0.name] ?? "").isEmpty }.map(\.label)
    }

    /// The images of the pager (§B6 item 2): the matched variant's image first, then the product's, at most 6, no
    /// duplicates; empty when the page had none.
    public static func images(_ product: JSONObject, _ chosen: [String: String]) -> [String] {
        var all: [String] = []
        if let image = matching(product, chosen)?.string("image") {
            all.append(image)
        }
        all += (product.array("images") ?? []).compactMap(\.stringValue)
        var seen = Set<String>()
        var out: [String] = []
        for image in all where !image.trimmingCharacters(in: .whitespaces).isEmpty && !seen.contains(image) {
            seen.insert(image)
            out.append(image)
            if out.count == Limits.imagesMax { break }
        }
        return out
    }

    /// The photo after a chip set a value (the web dialog's `choose()`): the newly matched variant's own photo when it
    /// has one, else `current` stays.
    public static func imageAfterChoice(_ product: JSONObject, _ chosen: [String: String], current: String?) -> String? {
        if let image = matching(product, chosen)?.string("image"), !image.trimmingCharacters(in: .whitespaces).isEmpty {
            return image
        }
        return current
    }

    /// «قیمت در سایت»: `variant.price ?? product.price` with the currency, or nil.
    public static func price(_ product: JSONObject, _ chosen: [String: String]) -> String? {
        guard let price = matching(product, chosen)?.string("price") ?? product.string("price") else { return nil }
        let text = [price, product.string("currency")].compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// «این ترکیب در سایت ناموجود است.»: the matched variant is known to be unavailable.
    public static func comboUnavailable(_ product: JSONObject, _ chosen: [String: String]) -> Bool {
        !chosen.isEmpty && matching(product, chosen)?["available"] == .bool(false)
    }
}

/// The one mapping of the web (`importResultOf()`, §B6), here only to build the `IntakeChoice` native returns: native
/// returns the choice, the web maps it. Pure.
public enum IntakeChoices {
    /// «شرح کالا» as the web takes it (§B6 `IntakeChoice.title`, 1–190 UTF-16 units, like the web input's `slice(0,
    /// 190)`): cut to 190 units without splitting a character, then trimmed.
    public static func capTitle(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.utf16.count > BridgeMessages.Limit.choiceTitleChars {
            trimmed = String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(BridgeMessages.Limit.choiceTitleChars)))
            while trimmed.utf16.count > BridgeMessages.Limit.choiceTitleChars { trimmed.removeLast() }
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    /// An `IntakeChoice` (§B6) for `product`; `title` is trimmed and cut to 190 characters (the product's own title or
    /// its site when it is empty, cut the same way: fixer 2026-10-24, a long product title used to pass uncut and the
    /// web refused the choice), `quantity` clamped.
    public static func make(product: JSONObject, chosen: [String: String], title: String, withBrand: Bool, quantity: Int, image: (ref: String, url: String)?, source: String) -> JSONObject {
        var chosenObject = JSONObject()
        for option in VariantMatcher.options(product) {
            if let value = chosen[option.name], !value.isEmpty {
                chosenObject[option.name] = .string(value)
            }
        }
        var trimmed = capTitle(title)
        if trimmed.isEmpty {
            trimmed = capTitle(product.string("title") ?? "")
        }
        if trimmed.isEmpty {
            trimmed = capTitle(product.string("site") ?? "")
        }
        if trimmed.isEmpty {
            trimmed = "-"
        }
        let imageValue: JSONValue = image.map { .object(JSONObject([("ref", .string($0.ref)), ("url", .string($0.url))])) } ?? .null
        return JSONObject([
            ("product", .object(product)),
            ("chosen", .object(chosenObject)),
            ("title", .string(trimmed)),
            ("withBrand", .bool(withBrand && product.string("brand") != nil)),
            ("quantity", .int(min(max(quantity, BridgeMessages.Limit.quantityMin), BridgeMessages.Limit.quantityMax))),
            ("image", imageValue),
            ("source", .string(source == "capture" ? "capture" : "server")),
        ])
    }
}
