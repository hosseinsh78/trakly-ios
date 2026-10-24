import SwiftUI
import UIKit

/// S8 (§E3): `config.min` above this build: «نسخه تازه Trakly آماده است», «برای ادامه، Trakly را به روز کنید.» and
/// «به روز رسانی» (the App Store page the server named, `config.storeUrl`).
struct UpdateRequiredView: View {
    let storeUrl: String?

    var body: some View {
        ZStack {
            Color(Theme.canvas).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "arrow.down.app")
                    .font(.system(size: 48, weight: .regular))
                    .foregroundStyle(Color(Theme.brand))
                    .accessibilityHidden(true)
                Text(L.s("update_title"))
                    .font(Theme.swiftUIFont(19, bold: true, relativeTo: .title3))
                    .foregroundStyle(Color(Theme.ink))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("update.title")
                Text(L.s("update_body"))
                    .font(Theme.swiftUIFont(15, relativeTo: .body))
                    .foregroundStyle(Color(Theme.ink2))
                    .multilineTextAlignment(.center)
                if storeUrl != nil {
                    Button(L.s("update_action")) {
                        UpdateRequiredView.openStore(storeUrl)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(maxWidth: 280)
                    .padding(.top, 8)
                }
            }
            .padding(32)
        }
        .environment(\.layoutDirection, .rightToLeft)
    }

    /// The App Store page: only an https URL the server named (with `ExternalLinks`, the only callers of
    /// `UIApplication.shared.open`).
    @MainActor
    static func openStore(_ url: String?) {
        guard let url, url.hasPrefix("https://"), let parsed = URL(string: url) else { return }
        UIApplication.shared.open(parsed, options: [:], completionHandler: nil)
    }

    @MainActor
    static func controller(storeUrl: String?) -> UIViewController {
        let host = UIHostingController(rootView: UpdateRequiredView(storeUrl: storeUrl))
        host.view.backgroundColor = Theme.canvas
        return host
    }
}
