import Foundation
import TraklyCore

/// The links the share extension saved for the app (docs/specs/phase10-apps-and-stores.md D20, §E8): `{url, at}` in
/// the App Group's `shared-links.json`, read and written with file coordination (the extension and the app may touch
/// it at the same time); at most 10, for 24 hours, the newest first. The app reads them when it becomes active and
/// clears them once S4 holds them as pending rows («خواندن»).
enum PendingShares {
    private static func now() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    private static func coordinated<T>(writing: Bool, _ body: (URL) -> T) -> T? {
        guard let file = AppGroup.sharedLinksFile else { return nil }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var error: NSError?
        var result: T?
        if writing {
            coordinator.coordinate(writingItemAt: file, options: [], error: &error) { url in
                result = body(url)
            }
        } else {
            coordinator.coordinate(readingItemAt: file, options: [], error: &error) { url in
                result = body(url)
            }
        }
        return result
    }

    private static func read(_ url: URL) -> [SharedLinks.Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return SharedLinks.parse(String(data: data, encoding: .utf8))
    }

    private static func write(_ entries: [SharedLinks.Entry], to url: URL) {
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try? SharedLinks.write(entries).data(using: .utf8)?.write(to: url, options: [.atomic])
        }
    }

    /// The extension: `url` saved for the app.
    @discardableResult
    static func add(_ url: String) -> Bool {
        coordinated(writing: true) { file in
            write(SharedLinks.adding(url, to: read(file), now: now()), to: file)
            return true
        } ?? false
    }

    /// The app: the live links, the newest first.
    static func all() -> [String] {
        coordinated(writing: false) { file in
            SharedLinks.live(read(file), now: now()).map(\.url)
        } ?? []
    }

    /// The app: S4 holds them now.
    static func clear() {
        _ = coordinated(writing: true) { file in
            try? FileManager.default.removeItem(at: file)
            return true
        }
    }
}
