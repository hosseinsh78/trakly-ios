import UIKit

/// Haptics (§E9): the web's `haptic` kinds and native's own moments.
@MainActor
enum Haptics {
    static func play(_ kind: String) {
        switch kind {
        case "selection":
            UISelectionFeedbackGenerator().selectionChanged()
        case "light":
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case "medium":
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case "success":
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "warning":
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case "error":
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        default:
            break
        }
    }
}
