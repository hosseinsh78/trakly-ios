import SwiftUI
import TraklyCore
import UIKit

/// «قفل برنامه» (S12, docs/specs/phase10-apps-and-stores.md D21, §E9): off by default; when on, the app locks at cold
/// launch (before the first panel page shows) and on returning after 5 minutes in the background; from
/// `sceneWillResignActive` a cover in the canvas colour hides the app and its app-switcher snapshot until unlocked.
/// Switching it off or on (`lock.set`) first runs the same prompt («برای تغییر قفل برنامه هویت خود را تایید کنید»).
@MainActor
final class AppLock {
    weak var coordinator: AppCoordinator?
    private let authenticator: Authenticator
    private let key = "trakly.lock.enabled"
    private var backgroundAt: Int64?
    private(set) var locked = false
    private var prompting = false

    init(authenticator: Authenticator) {
        self.authenticator = authenticator
    }

    var enabled: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
    }

    func authenticate(reason: String, completion: @escaping (Bool) -> Void) {
        guard authenticator.available else {
            completion(false)
            return
        }
        authenticator.authenticate(reason: reason, completion: completion)
    }

    /// The cold launch (`scene(_:willConnectTo:)`): locked when enabled.
    func coldLaunch() {
        guard enabled else { return }
        lock(prompt: true)
    }

    /// `sceneWillResignActive`: the cover goes up (the app-switcher snapshot shows no data).
    func willResignActive() {
        guard enabled else { return }
        showCover(promptButton: locked)
    }

    func didEnterBackground() {
        backgroundAt = SystemClock().nowMs()
    }

    /// `sceneWillEnterForeground`: locked again after 5 minutes away.
    func willEnterForeground() {
        guard enabled, let away = backgroundAt else { return }
        backgroundAt = nil
        if SystemClock().nowMs() - away >= Limits.lockAfterMs || AppConfig.testArgument("TraklyLockAfterMs") == "0" {
            lock(prompt: false)
        }
    }

    /// `sceneDidBecomeActive`: the prompt when locked, else the cover goes.
    func didBecomeActive() {
        if locked {
            prompt()
        } else {
            coordinator?.root.removeOverlay(tag: AppCoordinator.Overlay.lock)
        }
    }

    private func lock(prompt shouldPrompt: Bool) {
        locked = true
        showCover(promptButton: true)
        if shouldPrompt {
            prompt()
        }
    }

    private func showCover(promptButton: Bool) {
        guard let root = coordinator?.root else { return }
        let cover = UIHostingController(rootView: LockCover(showButton: promptButton) { [weak self] in self?.prompt() })
        cover.view.backgroundColor = Theme.canvas
        root.showOverlay(cover, tag: AppCoordinator.Overlay.lock)
    }

    private func prompt() {
        guard locked, !prompting else { return }
        prompting = true
        authenticate(reason: L.s("lock_reason")) { [weak self] success in
            guard let self else { return }
            self.prompting = false
            if success {
                self.locked = false
                self.coordinator?.root.removeOverlay(tag: AppCoordinator.Overlay.lock)
                self.coordinator?.flushIncoming()
            }
        }
    }
}

/// The lock cover: the canvas, the app's mark, «برای باز کردن Trakly هویت خود را تایید کنید» and «باز کردن».
struct LockCover: View {
    let showButton: Bool
    let unlock: () -> Void

    var body: some View {
        ZStack {
            Color(Theme.canvas).ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Color(Theme.brand))
                    .accessibilityHidden(true)
                if showButton {
                    Text(L.s("lock_reason"))
                        .font(Theme.swiftUIFont(17, bold: true, relativeTo: .headline))
                        .foregroundStyle(Color(Theme.ink))
                        .multilineTextAlignment(.center)
                    Button(L.s("lock_open"), action: unlock)
                        .buttonStyle(PrimaryButtonStyle())
                        .frame(maxWidth: 280)
                        .accessibilityIdentifier("lock.open")
                }
            }
            .padding(32)
        }
        .environment(\.layoutDirection, .rightToLeft)
    }
}
