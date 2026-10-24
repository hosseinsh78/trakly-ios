import TraklyCore
import UIKit
import UniformTypeIdentifiers

/// The share extension «Trakly» (S14, docs/specs/phase10-apps-and-stores.md D20, §E8): it takes a URL or text, keeps the
/// first product link for the app (`shared-links.json` in the App Group, at most 10, 24 hours), shows
/// «به Trakly اضافه شد؛ برای ادامه Trakly را باز کنید» and completes; without a link «در متنی که فرستادید لینک محصول پیدا
/// نشد.». No JavaScript preprocessing, no notification, and it never tries to open the app (v1, P3).
///
/// Fixer, 2026-10-24: presented over the full screen (the share sheet's own app stays visible under a light dim with
/// the card centred); the default sheet presentation of a custom extension controller would have drawn the dim inside
/// a sheet. A Debug build also takes the local fixture shops (the CI screenshot of the sheet, §L4).
final class ShareViewController: UIViewController {
    private let card = UIStackView()
    private let icon = UIImageView()
    private let message = UILabel()
    private var finished = false

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        modalPresentationStyle = .overFullScreen
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        modalPresentationStyle = .overFullScreen
    }

    /// The local fixture shops of the UI tests (`TRAKLY_DEV_POLICY`, Debug only, as the app's AppConfig.devPolicy).
    private static let devPolicy: Bool = {
        #if DEBUG
            return (Bundle.main.object(forInfoDictionaryKey: "TraklyDevPolicy") as? String) == "YES"
        #else
            return false
        #endif
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.semanticContentAttribute = .forceRightToLeft
        view.backgroundColor = UIColor.black.withAlphaComponent(0.25)

        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 40, weight: .semibold)
        icon.tintColor = UIColor(named: "Brand") ?? .systemBlue
        icon.image = UIImage(systemName: "bag.badge.plus")
        message.numberOfLines = 0
        message.textAlignment = .center
        message.textColor = UIColor(named: "Ink") ?? .label
        message.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: UIFont(name: "Vazirmatn-Bold", size: 17) ?? .boldSystemFont(ofSize: 17))
        message.text = NSLocalizedString("share_title", comment: "")
        message.accessibilityIdentifier = "share.message"
        card.accessibilityIdentifier = "share.card"

        card.axis = .vertical
        card.alignment = .center
        card.spacing = 14
        card.isLayoutMarginsRelativeArrangement = true
        card.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 28, leading: 24, bottom: 28, trailing: 24)
        card.backgroundColor = UIColor(named: "Surface") ?? .systemBackground
        card.layer.cornerRadius = 24
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addArrangedSubview(icon)
        card.addArrangedSubview(message)
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))

        Task { @MainActor in
            let text = await self.sharedText()
            if let url = LinkText.firstProductUrl(text, dev: ShareViewController.devPolicy), PendingShares.add(url) {
                self.show(NSLocalizedString("share_saved", comment: ""), symbol: "checkmark.circle.fill", success: true)
            } else {
                self.show(NSLocalizedString("share_no_link", comment: ""), symbol: "link.badge.plus", success: false)
            }
        }
    }

    /// The URL or the text of the shared items (the first one that has either).
    private func sharedText() async -> String? {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL
            {
                return url.absoluteString
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String
            {
                return text
            }
        }
        return items.compactMap { $0.attributedContentText?.string }.first
    }

    private func show(_ text: String, symbol: String, success: Bool) {
        message.text = text
        icon.image = UIImage(systemName: symbol)
        icon.tintColor = success ? (UIColor(named: "SuccessInk") ?? .systemGreen) : (UIColor(named: "WarningInk") ?? .systemOrange)
        UIAccessibility.post(notification: .announcement, argument: text)
        let notice = UINotificationFeedbackGenerator()
        notice.notificationOccurred(success ? .success : .warning)
        // A Debug build (the CI shot over Safari, §L4) keeps the card 6 s: the shot waits for the extension to start.
        let delay: UInt64 = ShareViewController.devPolicy ? 6_000_000_000 : success ? 1_600_000_000 : 2_200_000_000
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            self?.finish()
        }
    }

    @objc private func tapped() {
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
