import Foundation
import TraklyCore

/// The composer's basket on disk (docs/specs/phase10-apps-and-stores.md D10, §B15, §E6):
/// `Application Support/intake-basket.json`, 30 minutes, bound to the account (`TraklyCore.Basket` holds the rules).
@MainActor
final class BasketStore {
    let basket = Basket(clock: { SystemClock().wallMs() })
    private let file: URL? = {
        guard let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("intake-basket.json")
    }()

    func load() {
        guard let file, let data = try? Data(contentsOf: file) else { return }
        basket.restore(String(data: data, encoding: .utf8))
    }

    func save() {
        guard let file else { return }
        basket.expire()
        if basket.state.isEmpty && basket.issuedIds().isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? basket.toJson().data(using: .utf8)?.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
