import SwiftUI
import TraklyCore
import UIKit

/// «قفل برنامه» (S12, docs/specs/phase10-apps-and-stores.md D21, §E9): off by default; when on, the app locks at cold
/// launch (before the first panel page shows) and on returning after 5 minutes in the background; from
/// `sceneWillResignActive` a cover in the canvas colour hides the app and its app-switcher snapshot until unlocked.
/// Switching it off or on (`lock.set`) first runs the same prompt («برای تغییر قفل برنامه هویت خود را تایید کنید»).
///
/// Fixer, 2026-10-24: the cover is in its own window above everything the app presents (`CoverWindow`), so an open
/// order form, a sheet or Quick Look is neither seen nor usable while locked; the automatic prompt runs once per lock
/// (when the app becomes active), and after a cancel the cover waits with «باز کردن» (the Face ID sheet itself makes
/// the scene inactive and active again, which used to prompt again at once); a device without a passcode cannot hold
/// an app lock (Face ID and Touch ID go with the passcode), so the lock turns itself off there instead of locking the
/// user out.
@MainActor
final class AppLock {
    weak var coordinator: AppCoordinator?
    private let authenticator: Authenticator
    private let key = "trakly.lock.enabled"
    private var backgroundAt: Int64?
    private(set) var locked = false
    private var prompting = false
    /// The automatic prompt of this lock already ran.
    private var autoPrompted = false

    init(authenticator: Authenticator) {
        self.authenticator = authenticator
    }

    var enabled: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    func setEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// The device has no passcode: nothing to check against (and nothing a lock could use).
    var deviceHasNoPasscode: Bool {
        authenticator.passcodeMissing
    }

    func authenticate(reason: String, completion: @escaping (Bool) -> Void) {
        guard authenticator.available else {
            completion(false)
            return
        }
        authenticator.authenticate(reason: reason, completion: completion)
    }

    /// The cold launch (`scene(_:willConnectTo:)`): the cover when enabled; the prompt follows once the scene is active.
    func coldLaunch() {
        guard enabled, !releaseWithoutPasscode() else { return }
        lock()
        // A start that waited (the UI tests' clean state) may come after the scene became active.
        if coordinator?.window.windowScene?.activationState == .foregroundActive {
            autoPrompted = true
            prompt()
        }
    }

    /// `sceneWillResignActive`: the cover goes up (the app-switcher snapshot shows no data).
    func willResignActive() {
        guard enabled else { return }
        showCover(promptButton: locked)
    }

    func didEnterBackground() {
        backgroundAt = SystemClock().nowMs()
    }

    /// `sceneWillEnterForeground`: locked again after 5 minutes away; a locked app asks once more on its return.
    func willEnterForeground() {
        guard enabled, !releaseWithoutPasscode() else { return }
        if locked {
            autoPrompted = false
        }
        guard let away = backgroundAt else { return }
        backgroundAt = nil
        if SystemClock().nowMs() - away >= Limits.lockAfterMs || AppConfig.testArgument("TraklyLockAfterMs") == "0" {
            lock()
        }
    }

    /// `sceneDidBecomeActive`: the automatic prompt once per lock, else the cover goes.
    func didBecomeActive() {
        if locked {
            guard !releaseWithoutPasscode() else { return }
            if !autoPrompted {
                autoPrompted = true
                prompt()
            }
        } else {
            coordinator?.covers.remove(tag: AppCoordinator.Overlay.lock)
        }
    }

    private func lock() {
        locked = true
        autoPrompted = false
        // A focused field of the form would bring its keyboard back over the cover.
        coordinator?.window.endEditing(true)
        showCover(promptButton: true)
    }

    /// The lock is on but the device lost its passcode: the lock goes off and the app opens (§E9, fixer 2026-10-24).
    @discardableResult
    private func releaseWithoutPasscode() -> Bool {
        guard enabled, authenticator.passcodeMissing else { return false }
        setEnabled(false)
        let wasLocked = locked
        locked = false
        coordinator?.covers.remove(tag: AppCoordinator.Overlay.lock)
        if wasLocked {
            coordinator?.unlocked()
        }
        return true
    }

    private func showCover(promptButton: Bool) {
        let cover = UIHostingController(rootView: LockCover(showButton: promptButton) { [weak self] in self?.prompt() })
        cover.view.backgroundColor = Theme.canvas
        coordinator?.covers.show(cover, tag: AppCoordinator.Overlay.lock, key: promptButton)
    }

    /// The prompt (automatic once per lock, or «باز کردن»).
    func prompt() {
        guard locked, !prompting else { return }
        prompting = true
        authenticate(reason: L.s("lock_reason")) { [weak self] success in
            guard let self else { return }
            self.prompting = false
            if success {
                self.locked = false
                self.coordinator?.covers.remove(tag: AppCoordinator.Overlay.lock)
                self.coordinator?.unlocked()
            } else {
                self.releaseWithoutPasscode()
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
