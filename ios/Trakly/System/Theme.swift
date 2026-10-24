import SwiftUI
import UIKit

/// Colours, fonts and metrics of the native chrome (docs/specs/phase10-apps-and-stores.md D16, §B13, DESIGN.md §3–§7):
/// the colour sets are generated from `shared/app/tokens.json` (light and dark), the font is Vazirmatn (O-Q3), bundled
/// with its OFL licence and scaled with Dynamic Type; never the system Arabic-script font for Persian text.
enum Theme {
    static func color(_ name: String) -> UIColor {
        UIColor(named: name) ?? .label
    }

    static var canvas: UIColor { color("Canvas") }
    static var surface: UIColor { color("Surface") }
    static var surface2: UIColor { color("Surface2") }
    static var surface3: UIColor { color("Surface3") }
    static var line: UIColor { color("Line") }
    static var lineStrong: UIColor { color("LineStrong") }
    static var ink: UIColor { color("Ink") }
    static var ink2: UIColor { color("Ink2") }
    static var ink3: UIColor { color("Ink3") }
    static var onInk: UIColor { color("OnInk") }
    static var brand: UIColor { color("Brand") }
    static var brandStrong: UIColor { color("BrandStrong") }
    static var brandSoft: UIColor { color("BrandSoft") }
    static var brandInk: UIColor { color("BrandInk") }
    static var danger: UIColor { color("Danger") }
    static var dangerInk: UIColor { color("DangerInk") }
    static var dangerSoft: UIColor { color("DangerSoft") }
    static var warningSoft: UIColor { color("WarningSoft") }
    static var warningInk: UIColor { color("WarningInk") }
    static var successInk: UIColor { color("SuccessInk") }
    static var night: UIColor { color("Night") }
    static var auroraStart: UIColor { color("AuroraStart") }
    static var auroraMid: UIColor { color("AuroraMid") }
    static var auroraEnd: UIColor { color("AuroraEnd") }

    /// Corner radii and the primary button height (tokens.json `radius`, `button`).
    static let controlRadius: CGFloat = 14
    static let cardRadius: CGFloat = 24
    static let buttonHeight: CGFloat = 48

    static let regularName = "Vazirmatn-Regular"
    static let boldName = "Vazirmatn-Bold"

    /// Vazirmatn at `size` points for `style`, scaled with the user's text size.
    static func font(_ size: CGFloat, bold: Bool = false, style: UIFont.TextStyle = .body) -> UIFont {
        let base = UIFont(name: bold ? boldName : regularName, size: size) ?? UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: base)
    }

    /// The fixed-size font of the system bars' titles, buttons and tab items: like the stock bars, they keep their size
    /// at every Dynamic Type setting (a long press shows the Large Content Viewer); the content follows the setting.
    static func barFont(_ size: CGFloat, bold: Bool = false) -> UIFont {
        UIFont(name: bold ? boldName : regularName, size: size) ?? UIFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    /// The same font for SwiftUI.
    static func swiftUIFont(_ size: CGFloat, bold: Bool = false, relativeTo style: Font.TextStyle = .body) -> Font {
        Font.custom(bold ? boldName : regularName, size: size, relativeTo: style)
    }

    /// The UIKit appearance of the stock bars and controls (D16: stock components; brand tint, Vazirmatn titles).
    @MainActor
    static func applyAppearance() {
        let navigation = UINavigationBarAppearance()
        navigation.configureWithDefaultBackground()
        navigation.titleTextAttributes = [.font: barFont(17, bold: true), .foregroundColor: ink]
        navigation.largeTitleTextAttributes = [.font: font(30, bold: true, style: .largeTitle), .foregroundColor: ink]
        let buttons = UIBarButtonItemAppearance(style: .plain)
        buttons.normal.titleTextAttributes = [.font: barFont(17)]
        navigation.buttonAppearance = buttons
        let done = UIBarButtonItemAppearance(style: .done)
        done.normal.titleTextAttributes = [.font: barFont(17, bold: true)]
        navigation.doneButtonAppearance = done
        UINavigationBar.appearance().standardAppearance = navigation
        UINavigationBar.appearance().compactAppearance = navigation
        let edge = UINavigationBarAppearance()
        edge.configureWithTransparentBackground()
        edge.titleTextAttributes = navigation.titleTextAttributes
        edge.buttonAppearance = buttons
        edge.doneButtonAppearance = done
        UINavigationBar.appearance().scrollEdgeAppearance = edge
        UINavigationBar.appearance().tintColor = brand

        let tab = UITabBarAppearance()
        tab.configureWithDefaultBackground()
        let item = UITabBarItemAppearance(style: .stacked)
        item.normal.titleTextAttributes = [.font: barFont(11), .foregroundColor: ink3]
        item.selected.titleTextAttributes = [.font: barFont(11, bold: true), .foregroundColor: brand]
        item.normal.iconColor = ink3
        item.selected.iconColor = brand
        item.normal.badgeBackgroundColor = brand
        item.normal.badgeTextAttributes = [.font: barFont(12, bold: true), .foregroundColor: UIColor.white]
        tab.stackedLayoutAppearance = item
        tab.inlineLayoutAppearance = item
        tab.compactInlineLayoutAppearance = item
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        UITabBar.appearance().tintColor = brand

        UIBarButtonItem.appearance().setTitleTextAttributes([.font: barFont(17)], for: .normal)
        UIBarButtonItem.appearance().setTitleTextAttributes([.font: barFont(17)], for: .highlighted)
        UIRefreshControl.appearance().tintColor = brand
        UISwitch.appearance().onTintColor = brand
    }
}

/// The aurora gradient of the primary button (DESIGN.md §4, D16).
struct AuroraBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(Theme.auroraStart), Color(Theme.auroraMid), Color(Theme.auroraEnd)], startPoint: .leading, endPoint: .trailing)
    }
}

/// The primary button of the native screens: the aurora gradient, 48 pt high, the control radius, white bold text.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.swiftUIFont(16, bold: true, relativeTo: .headline))
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity, minHeight: Theme.buttonHeight)
            .padding(.horizontal, 16)
            .background(AuroraBackground().opacity(enabled ? 1 : 0.4))
            .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// The secondary button: the surface with a hairline, ink text; disabled, ink-3 text at half strength (DESIGN.md: a
/// disabled control fades; fixer 2026-10-24, it used to look enabled).
struct SecondaryButtonStyle: ButtonStyle {
    var destructive = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.swiftUIFont(15, bold: true, relativeTo: .subheadline))
            .foregroundStyle(Color(enabled ? (destructive ? Theme.dangerInk : Theme.ink) : Theme.ink3))
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 12)
            .background(Color(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).stroke(Color(Theme.lineStrong), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.5)
    }
}
