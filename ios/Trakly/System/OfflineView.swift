import SwiftUI
import UIKit

/// S7 (docs/specs/phase10-apps-and-stores.md F4, §E3): «اتصال اینترنت برقرار نیست» when the phone has no network
/// (`NWPathMonitor`), else «Trakly در دسترس نیست؛ کمی بعد دوباره امتحان کنید», with «تلاش دوباره» and an automatic retry
/// when the network returns. Right to left in the app font.
struct OfflineView: View {
    let noNetwork: Bool
    let retry: () -> Void

    var body: some View {
        ZStack {
            Color(Theme.canvas).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: noNetwork ? "wifi.slash" : "exclamationmark.icloud")
                    .font(.system(size: 48, weight: .regular))
                    .foregroundStyle(Color(Theme.ink3))
                    .accessibilityHidden(true)
                Text(L.s(noNetwork ? "offline_no_network" : "offline_unreachable"))
                    .font(Theme.swiftUIFont(19, bold: true, relativeTo: .title3))
                    .foregroundStyle(Color(Theme.ink))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("offline.title")
                if noNetwork {
                    Text(L.s("offline_no_network_body"))
                        .font(Theme.swiftUIFont(15, relativeTo: .body))
                        .foregroundStyle(Color(Theme.ink2))
                        .multilineTextAlignment(.center)
                }
                Button(L.s("offline_retry"), action: retry)
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(maxWidth: 280)
                    .padding(.top, 8)
                    .accessibilityIdentifier("offline.retry")
            }
            .padding(32)
        }
        .environment(\.layoutDirection, .rightToLeft)
    }

    @MainActor
    static func controller(noNetwork: Bool, retry: @escaping () -> Void) -> UIViewController {
        let host = UIHostingController(rootView: OfflineView(noNetwork: noNetwork, retry: retry))
        host.view.backgroundColor = Theme.canvas
        return host
    }
}
