import Foundation

/// The App Group of the app and its share extension (docs/specs/phase10-apps-and-stores.md D20, §E1, §E8):
/// `group.info.trakly.app`. A Simulator build signed ad hoc may have no group container; it then falls back to the
/// process's own Application Support folder (the app's UI tests write their shares there through a Debug hook).
enum AppGroup {
    static var identifier: String {
        (Bundle.main.object(forInfoDictionaryKey: "TraklyAppGroup") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "group.info.trakly.app"
    }

    static var container: URL? {
        if let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return shared
        }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }

    /// `shared-links.json` (at most 10 links, 24 hours, TraklyCore.SharedLinks).
    static var sharedLinksFile: URL? {
        container?.appendingPathComponent("shared-links.json")
    }
}
