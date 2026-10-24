import TraklyCore
import UIKit
import WebKit

/// The one window scene (docs/specs/phase10-apps-and-stores.md §E2, §E3, §E8, §E9): launch (the lock at cold launch
/// before the first panel page shows), quick actions, universal links, the shares picked up on every activation, the
/// app lock's cover and timer, `appState` for the pages.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private(set) var coordinator: AppCoordinator?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        Theme.applyAppearance()
        FaText.forceRightToLeft()
        let window = UIWindow(windowScene: windowScene)
        window.tintColor = Theme.brand
        window.backgroundColor = Theme.canvas
        self.window = window
        let coordinator = AppCoordinator(window: window)
        self.coordinator = coordinator

        TestHooks.prepare {
            coordinator.start()
            coordinator.lock.coldLaunch()
            if let shortcut = connectionOptions.shortcutItem {
                coordinator.receive(.quickAction(shortcut.type))
            }
            for activity in connectionOptions.userActivities where activity.activityType == NSUserActivityTypeBrowsingWeb {
                coordinator.receive(.universal(activity.webpageURL?.absoluteString))
            }
            self.pickUpShares()
        }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        coordinator?.receive(.quickAction(shortcutItem.type))
        completionHandler(true)
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb else { return }
        coordinator?.receive(.universal(userActivity.webpageURL?.absoluteString))
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        coordinator?.lock.didBecomeActive()
        pickUpShares()
        coordinator?.appState(active: true)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        coordinator?.lock.willResignActive()
        coordinator?.appState(active: false)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        coordinator?.lock.didEnterBackground()
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        coordinator?.lock.willEnterForeground()
    }

    /// The links of the share extension (§E8): S4 opens with them as pending rows («خواندن»), over an open order form
    /// in merge mode, or they wait for the next `tab` context.
    private func pickUpShares() {
        TestHooks.queuedShares {
            let links = PendingShares.all()
            if !links.isEmpty {
                self.coordinator?.receive(.shares(links))
            }
        }
    }
}

/// Debug-only hooks of the UI tests (§K5): a clean start (`-TraklyResetState`), a shared link as if the share extension
/// had saved it (`-TraklyTestShare <url>`). A Release build runs `start` at once and reads no argument.
@MainActor
enum TestHooks {
    static func prepare(_ start: @escaping () -> Void) {
        #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-TraklyResetState") {
                PendingShares.clear()
                let manager = FileManager.default
                if let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                    try? manager.removeItem(at: support.appendingPathComponent("intake-basket.json"))
                }
                if let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask).first {
                    try? manager.removeItem(at: caches.appendingPathComponent("pending-capture.json"))
                }
            }
            if let url = AppConfig.testArgument("TraklyTestShare") {
                PendingShares.add(url)
            }
            if arguments.contains("-TraklyResetState") {
                for key in ["trakly.topology", "trakly.tabs", "trakly.lastContext", "trakly.lastNight", "trakly.lock.enabled", "trakly.appearance", "trakly.reads"] {
                    UserDefaults.standard.removeObject(forKey: key)
                }
                if let topology = AppConfig.testArgument("TraklyTopology") {
                    UserDefaults.standard.set(topology, forKey: "trakly.topology")
                }
                if AppConfig.testArgument("TraklyLock") == "on" {
                    UserDefaults.standard.set(true, forKey: "trakly.lock.enabled")
                }
                let store = WKWebsiteDataStore.default()
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                    Task { @MainActor in start() }
                }
                return
            }
        #endif
        start()
    }

    /// Debug UI tests only: links the stand-in queued (`/__test/share`) are saved as the share extension would save
    /// them, then `done` runs; otherwise `done` runs at once.
    static func queuedShares(_ done: @escaping () -> Void) {
        #if DEBUG
            if AppConfig.uiTest, let url = URL(string: AppConfig.origin + "/__test/share-queue") {
                Task { @MainActor in
                    let data = try? await URLSession.shared.data(from: url).0
                    let links = data.flatMap { Json.parseOrNil(String(decoding: $0, as: UTF8.self))?.stringList } ?? []
                    for link in links {
                        PendingShares.add(link)
                    }
                    done()
                }
                return
            }
        #endif
        done()
    }
}
