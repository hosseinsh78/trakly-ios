import LocalAuthentication
import UIKit

/// Who confirms the user (docs/specs/phase10-apps-and-stores.md D21, §E9): Face ID / Touch ID with the device passcode
/// as the fallback (`LAContext`, `.deviceOwnerAuthentication`); in a Debug UI test run a fake behind the launch argument
/// `-TraklyFakeAuth success|failure|once|nopasscode` (real Face ID only in the owner's iPhone test, §O11).
@MainActor
protocol Authenticator: AnyObject {
    /// Whether the device can authenticate at all (no passcode set: false).
    var available: Bool { get }
    /// The device has no passcode (Face ID and Touch ID go with it): it cannot hold an app lock (§E9, fixer 2026-10-24).
    var passcodeMissing: Bool { get }
    func authenticate(reason: String, completion: @escaping (Bool) -> Void)
}

@MainActor
final class DeviceAuthenticator: Authenticator {
    var available: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    var passcodeMissing: Bool {
        var error: NSError?
        let possible = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        return !possible && error?.domain == LAErrorDomain && error?.code == LAError.Code.passcodeNotSet.rawValue
    }

    func authenticate(reason: String, completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        context.localizedCancelTitle = L.s("cancel_dialog")
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            completion(false)
            return
        }
        // The answer comes on another queue: it reaches `completion` through this main-actor object (no capture of the
        // non-Sendable closure in the system's Sendable callback).
        pending.append(completion)
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] success, _ in
            Task { @MainActor in
                self?.finish(success)
            }
        }
    }

    private var pending: [(Bool) -> Void] = []

    private func finish(_ success: Bool) {
        guard !pending.isEmpty else { return }
        pending.removeFirst()(success)
    }
}

/// The UI tests' authenticator (Debug only), after 300 ms: `success`, `failure`, `once` (the first prompt succeeds, every
/// later one fails: unlock at launch, then a locked return) or `nopasscode` (a device without a passcode).
@MainActor
final class FakeAuthenticator: Authenticator {
    let mode: String
    private(set) var prompts = 0

    init(mode: String) {
        self.mode = mode
    }

    var available: Bool { mode != "nopasscode" }

    var passcodeMissing: Bool { mode == "nopasscode" }

    func authenticate(reason: String, completion: @escaping (Bool) -> Void) {
        prompts += 1
        let result = mode == "success" || (mode == "once" && prompts == 1)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            completion(result)
        }
    }
}

@MainActor
enum Authenticators {
    static func make() -> Authenticator {
        #if DEBUG
            if let fake = AppConfig.testArgument("TraklyFakeAuth") {
                return FakeAuthenticator(mode: fake)
            }
        #endif
        return DeviceAuthenticator()
    }
}
