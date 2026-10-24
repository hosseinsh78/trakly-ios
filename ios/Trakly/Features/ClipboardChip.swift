import UIKit

/// The clipboard chip of S4 (docs/specs/phase10-apps-and-stores.md D20, §E8): when S4 opens, iOS is asked whether the
/// pasteboard probably holds a web URL (`detectPatterns`, no paste prompt, the content is not read); the content comes
/// only through the system paste control (`PasteButton`), so the app never reads the pasteboard by itself.
@MainActor
enum ClipboardChip {
    static func probablyHoldsLink(completion: @escaping (Bool) -> Void) {
        let board = UIPasteboard.general
        guard board.hasStrings || board.hasURLs else {
            completion(false)
            return
        }
        let link: PartialKeyPath<UIPasteboard.DetectedValues> = \UIPasteboard.DetectedValues.probableWebURL
        board.detectPatterns(for: [link]) { result in
            let found: Bool
            switch result {
            case let .success(patterns): found = patterns.contains(link)
            case .failure: found = false
            }
            Task { @MainActor in
                completion(found)
            }
        }
    }
}
