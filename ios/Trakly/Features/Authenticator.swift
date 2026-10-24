import LocalAuthentication
import UIKit

/// Who confirms the user (docs/specs/phase10-apps-and-stores.md D21, §E9): Face ID / Touch ID with the device passcode
/// as the fallback (`LAContext`, `.deviceOwnerAuthentication`); in a Debug UI test run a fake behind the launch argument
/// `-TraklyFakeAuth success|failure` (real Face ID only in the owner's iPhone test, §O11).
@MainActor
protocol Authenticator: AnyObject {
    /// Whether the device can authenticate at all (no passcode set: false).
    var available: Bool { get }
    func authenticate(reason: String, completion: @escaping (Bool) -> Void)
}

@MainActor
final class DeviceAuthenticator: Authenticator {
    var available: Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    func authenticate(reason: String, completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        context.localizedCancelTitle = L.s("cancel_dialog")
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            completion(false)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            Task { @MainActor in
                completion(success)
            }
        }
    }
}

/// The UI tests' authenticator (Debug only): answers at once with the launch argument's result.
@MainActor
final class FakeAuthenticator: Authenticator {
    let succeeds: Bool
    private(set) var prompts = 0

    init(succeeds: Bool) {
        self.succeeds = succeeds
    }

    var available: Bool { true }

    func authenticate(reason: String, completion: @escaping (Bool) -> Void) {
        prompts += 1
        let result = succeeds
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
                return FakeAuthenticator(succeeds: fake == "success")
            }
        #endif
        return DeviceAuthenticator()
    }
}
