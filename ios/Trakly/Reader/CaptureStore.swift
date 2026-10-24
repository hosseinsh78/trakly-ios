import Foundation
import TraklyCore

/// The reader's results (docs/specs/phase10-apps-and-stores.md D9, §B15, §E6): `readId` → the capture JSON string and
/// its URL, in memory and in `Caches/pending-capture.json` for 15 minutes (a read finished while the order form's
/// WebView was rebuilt is not lost). The capture is never parsed here; native keeps it to check which image URLs it
/// may fetch (D11).
@MainActor
final class CaptureStore {
    struct Entry {
        let url: String
        let capture: String
        let at: Int64
    }

    private var entries: [String: Entry] = [:]
    private let file: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("pending-capture.json")

    init() {
        load()
    }

    private func now() -> Int64 {
        SystemClock().wallMs()
    }

    func put(readId: String, url: String, capture: String) {
        entries[readId] = Entry(url: url, capture: capture, at: now())
        save()
    }

    func get(_ readId: String) -> Entry? {
        expire()
        return entries[readId]
    }

    func remove(_ readId: String) {
        entries.removeValue(forKey: readId)
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func expire() {
        let limit = now() - Limits.pendingChoiceMs
        entries = entries.filter { $0.value.at >= limit }
    }

    private func load() {
        guard let file, let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8), let body = Json.object(text) else { return }
        for (id, value) in body {
            guard let item = value.objectValue, let url = item.string("url"), let capture = item.string("capture"), let at = item.number("at") else { continue }
            entries[id] = Entry(url: url, capture: capture, at: Int64(at))
        }
        expire()
    }

    private func save() {
        guard let file else { return }
        expire()
        if entries.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        var body = JSONObject()
        for (id, entry) in entries {
            body[id] = .object(JSONObject([("url", .string(entry.url)), ("capture", .string(entry.capture)), ("at", .number(Double(entry.at)))]))
        }
        try? Json.write(body).data(using: .utf8)?.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
