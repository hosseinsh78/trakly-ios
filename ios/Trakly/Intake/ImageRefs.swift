import Foundation
import TraklyCore

/// Fetched product photos under random refs (D11, §B15, §E6): `Caches/refs/<ref>.jpg` for 30 minutes; the page asks
/// `product.image {ref}` and uploads the bytes with its own session.
@MainActor
final class ImageRefs {
    private struct Entry {
        let url: String
        let at: Int64
    }

    private var entries: [String: Entry] = [:]
    private let folder: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = caches.appendingPathComponent("refs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    private func now() -> Int64 {
        SystemClock().wallMs()
    }

    /// Keeps `jpeg` (already re-encoded by `ImageFetcher`) under a fresh ref.
    func store(_ jpeg: Data, url: String) -> String? {
        guard let folder else { return nil }
        expire()
        let ref = BridgeMessages.randomToken()
        do {
            try jpeg.write(to: folder.appendingPathComponent(ref + ".jpg"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            return nil
        }
        entries[ref] = Entry(url: url, at: now())
        return ref
    }

    /// The refs a page may ask for: issued in this process, at most 30 minutes old (§B5).
    var live: Set<String> {
        expire()
        return Set(entries.keys)
    }

    func data(_ ref: String) -> Data? {
        expire()
        guard entries[ref] != nil, let folder else { return nil }
        return try? Data(contentsOf: folder.appendingPathComponent(ref + ".jpg"))
    }

    func clear() {
        for ref in entries.keys {
            if let folder { try? FileManager.default.removeItem(at: folder.appendingPathComponent(ref + ".jpg")) }
        }
        entries.removeAll()
    }

    private func expire() {
        let limit = now() - Limits.refMs
        for (ref, entry) in entries where entry.at < limit {
            entries.removeValue(forKey: ref)
            if let folder { try? FileManager.default.removeItem(at: folder.appendingPathComponent(ref + ".jpg")) }
        }
    }

    /// Files of an earlier run (their refs died with the process) go at launch.
    func sweep() {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where entries[file.deletingPathExtension().lastPathComponent] == nil {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
