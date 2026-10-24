import UIKit

/// Right-to-left text (§E3 "Appearance"): the paragraph style of UIKit labels and alerts, and the forced layout.
enum FaText {
    static var paragraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.baseWritingDirection = .rightToLeft
        style.alignment = .natural
        return style
    }

    /// `text` as right-to-left with the app font.
    static func attributed(_ text: String, size: CGFloat = 15, bold: Bool = false, color: UIColor = Theme.ink) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.paragraphStyle: paragraph, .font: Theme.font(size, bold: bold), .foregroundColor: color])
    }

    /// The app runs right to left even on a device in another language (§E3, D16).
    @MainActor
    static func forceRightToLeft() {
        UIView.appearance().semanticContentAttribute = .forceRightToLeft
        UINavigationBar.appearance().semanticContentAttribute = .forceRightToLeft
        UITabBar.appearance().semanticContentAttribute = .forceRightToLeft
        UIStackView.appearance().semanticContentAttribute = .forceRightToLeft
    }

    /// A LTR run (hosts, prices, URLs) inside right-to-left text: wrapped in LRI … PDI.
    static func ltr(_ text: String) -> String {
        "\u{2066}" + text + "\u{2069}"
    }

    /// Whether a text's first strong character is right to left (a field's direction follows its content, like the
    /// web's `dir=auto`); an empty or neutral text counts as right to left.
    static func startsRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if (0x0590 ... 0x08FF).contains(value) || (0xFB1D ... 0xFDFF).contains(value) || (0xFE70 ... 0xFEFF).contains(value) {
                return true
            }
            if scalar.properties.isAlphabetic {
                return false
            }
        }
        return true
    }
}
