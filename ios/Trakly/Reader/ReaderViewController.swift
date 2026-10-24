import TraklyCore
import UIKit
import WebKit

/// S5 «خواندن محصول» (docs/specs/phase10-apps-and-stores.md D9, §A3, §E5): a sheet at its large height with the
/// grabber; «لغو», the title and the real host as a LTR chip; the stage line; the challenge banner (the user solves it
/// in the visible page, no deadline while he does); the `none` hint; the error card with «تلاش دوباره» and «بستن»
/// stacked full width; «محصول پیدا شد» for a moment on success. Swiping down is off while a read runs or a challenge
/// shows; on the error card a swipe down is «بستن» (fixer 2026-10-24: it used to leave the row reading, the reader
/// WebView alive and every later `intake.line` busy).
@MainActor
final class ReaderViewController: UIViewController {
    let session: ReaderSession
    /// The session, the reason, and whether the sheet is gone already (a swipe down).
    var onClose: ((ReaderSession, String, Bool) -> Void)?

    private let hostChip = PaddedLabel()
    private let stageLabel = UILabel()
    private let progress = UIProgressView(progressViewStyle: .bar)
    private let banner = UIStackView()
    private let bannerTitle = UILabel()
    private let bannerBody = UILabel()
    private let hint = UILabel()
    private let webContainer = UIView()
    private let card = UIView()
    private let cardTitle = UILabel()
    private let cardBody = UILabel()
    private let retryButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let found = UIStackView()
    private var progressTimer: Timer?

    init(session: ReaderSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
        title = L.s("reader_title")
        let cancel = UIBarButtonItem(title: L.s("cancel"), style: .plain, target: self, action: #selector(cancelTapped))
        cancel.accessibilityIdentifier = "reader.cancel"
        navigationItem.leftBarButtonItem = cancel
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    /// The navigation controller of the sheet.
    func sheet() -> UINavigationController {
        let navigation = UINavigationController(rootViewController: self)
        navigation.view.semanticContentAttribute = .forceRightToLeft
        navigation.navigationBar.semanticContentAttribute = .forceRightToLeft
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = Theme.cardRadius
        }
        navigation.isModalInPresentation = true
        navigation.presentationController?.delegate = self
        return navigation
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.surface
        view.semanticContentAttribute = .forceRightToLeft

        hostChip.font = Theme.font(13, bold: true, style: .footnote)
        hostChip.textColor = Theme.brandInk
        hostChip.backgroundColor = Theme.brandSoft
        hostChip.layer.cornerRadius = 12
        hostChip.layer.masksToBounds = true
        hostChip.insets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        hostChip.semanticContentAttribute = .forceLeftToRight
        hostChip.textAlignment = .center
        hostChip.accessibilityIdentifier = "reader.host"

        stageLabel.font = Theme.font(14, style: .subheadline)
        stageLabel.textColor = Theme.ink2
        stageLabel.numberOfLines = 0
        stageLabel.accessibilityIdentifier = "reader.stage"

        progress.progressTintColor = Theme.brand
        progress.trackTintColor = Theme.surface3

        bannerTitle.font = Theme.font(15, bold: true, style: .subheadline)
        bannerTitle.textColor = Theme.warningInk
        bannerTitle.numberOfLines = 0
        bannerBody.font = Theme.font(14, style: .footnote)
        bannerBody.textColor = Theme.ink
        bannerBody.numberOfLines = 0
        bannerBody.text = L.s("challenge_body")
        banner.axis = .vertical
        banner.spacing = 4
        banner.isLayoutMarginsRelativeArrangement = true
        banner.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        banner.backgroundColor = Theme.warningSoft
        banner.layer.cornerRadius = Theme.controlRadius
        banner.addArrangedSubview(bannerTitle)
        banner.addArrangedSubview(bannerBody)
        banner.isHidden = true
        banner.accessibilityIdentifier = "reader.challenge"

        hint.font = Theme.font(14, style: .footnote)
        hint.textColor = Theme.ink2
        hint.numberOfLines = 0
        hint.text = L.s("none_hint")
        hint.isHidden = true

        let chipRow = UIStackView(arrangedSubviews: [hostChip, UIView()])
        chipRow.axis = .horizontal
        let header = UIStackView(arrangedSubviews: [chipRow, stageLabel, progress, banner, hint])
        header.axis = .vertical
        header.alignment = .fill
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        header.setCustomSpacing(10, after: chipRow)

        webContainer.translatesAutoresizingMaskIntoConstraints = false
        webContainer.backgroundColor = Theme.surface2
        webContainer.layer.cornerRadius = 16
        webContainer.clipsToBounds = true

        view.addSubview(header)
        view.addSubview(webContainer)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            progress.heightAnchor.constraint(equalToConstant: 3),
            webContainer.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            webContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            webContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            webContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])

        buildCard()
        buildFound()

        session.onState = { [weak self] session in
            self?.render(session)
        }
        if session.webView == nil {
            session.start()
        }
        render(session)
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceProgress() }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            progressTimer?.invalidate()
        }
    }

    private func buildCard() {
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = Theme.surface
        card.layer.cornerRadius = Theme.cardRadius
        card.layer.borderColor = Theme.line.cgColor
        card.layer.borderWidth = 1
        card.isHidden = true
        card.accessibilityIdentifier = "reader.error"
        cardTitle.font = Theme.font(18, bold: true, style: .headline)
        cardTitle.textColor = Theme.ink
        cardTitle.numberOfLines = 0
        cardTitle.textAlignment = .center
        cardBody.font = Theme.font(15, style: .body)
        cardBody.textColor = Theme.ink2
        cardBody.numberOfLines = 0
        cardBody.textAlignment = .center
        style(retryButton, primary: true, title: L.s("retry"))
        retryButton.accessibilityIdentifier = "reader.retry"
        retryButton.addAction(UIAction { [weak self] _ in self?.retry() }, for: .touchUpInside)
        style(closeButton, primary: false, title: L.s("close"))
        closeButton.accessibilityIdentifier = "reader.close"
        closeButton.addAction(UIAction { [weak self] _ in self?.giveUp() }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [cardTitle, cardBody, retryButton, closeButton])
        stack.axis = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(20, after: cardBody)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        view.addSubview(card)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.buttonHeight),
            closeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
    }

    private func buildFound() {
        let icon = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
        icon.tintColor = Theme.successInk
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold)
        let label = UILabel()
        label.text = L.s("reader_found")
        label.font = Theme.font(18, bold: true, style: .headline)
        label.textColor = Theme.ink
        found.addArrangedSubview(icon)
        found.addArrangedSubview(label)
        found.axis = .vertical
        found.alignment = .center
        found.spacing = 10
        found.isLayoutMarginsRelativeArrangement = true
        found.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 24, leading: 32, bottom: 24, trailing: 32)
        found.backgroundColor = Theme.surface
        found.layer.cornerRadius = Theme.cardRadius
        found.translatesAutoresizingMaskIntoConstraints = false
        found.isHidden = true
        found.accessibilityIdentifier = "reader.found"
        view.addSubview(found)
        NSLayoutConstraint.activate([
            found.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            found.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func style(_ button: UIButton, primary: Bool, title: String) {
        var configuration = primary ? UIButton.Configuration.filled() : UIButton.Configuration.bordered()
        configuration.attributedTitle = AttributedString(NSAttributedString(string: title, attributes: [.font: Theme.font(16, bold: true, style: .headline)]))
        configuration.cornerStyle = .large
        configuration.baseBackgroundColor = primary ? Theme.brand : Theme.surface2
        configuration.baseForegroundColor = primary ? .white : Theme.ink
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        button.configuration = configuration
    }

    private func attachWebView() {
        guard let webView = session.webView, webView.superview !== webContainer else { return }
        webView.removeFromSuperview()
        webContainer.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            webView.topAnchor.constraint(equalTo: webContainer.topAnchor),
            webView.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
        ])
    }

    private func render(_ session: ReaderSession) {
        guard isViewLoaded else { return }
        attachWebView()
        hostChip.text = session.host ?? ""
        hostChip.isHidden = session.host == nil
        card.isHidden = true
        found.isHidden = true
        webContainer.isHidden = false
        switch session.state {
        case let .reading(stage, challenge, showHint):
            let key: String
            switch stage {
            case .opening: key = "stage_opening"
            case .loading: key = "stage_loading"
            case .slow: key = "stage_slow"
            case .challenge: key = "stage_loading"
            }
            stageLabel.text = L.s(key)
            stageLabel.isHidden = challenge
            banner.isHidden = !challenge
            bannerTitle.text = L.f("challenge_title", FaText.ltr(session.host ?? ""))
            hint.isHidden = !showHint || challenge
            progress.isHidden = challenge
        case .extracting:
            stageLabel.text = L.s("stage_extracting")
            stageLabel.isHidden = false
            banner.isHidden = true
            hint.isHidden = true
            progress.isHidden = false
        case .found:
            stageLabel.isHidden = true
            banner.isHidden = true
            hint.isHidden = true
            progress.isHidden = true
            found.isHidden = false
            view.bringSubviewToFront(found)
            UIAccessibility.post(notification: .announcement, argument: L.s("reader_found"))
        case let .failed(reason, host, retriable):
            stageLabel.isHidden = true
            banner.isHidden = true
            hint.isHidden = true
            progress.isHidden = true
            webContainer.isHidden = reason == "page_gone"
            cardTitle.text = ReaderViewController.title(for: reason)
            cardBody.text = ReaderViewController.message(for: reason, host: host)
            retryButton.isHidden = !retriable
            card.isHidden = false
            view.bringSubviewToFront(card)
        }
        navigationController?.isModalInPresentation = {
            if case .failed = session.state { return false }
            return true
        }()
    }

    private func advanceProgress() {
        guard !progress.isHidden else { return }
        let next = progress.progress + (1 - progress.progress) * 0.04
        progress.setProgress(next > 0.95 ? 0.15 : next, animated: true)
    }

    static func title(for reason: String) -> String {
        switch reason {
        case "challenge_timeout": return L.s("error_title_challenge")
        case "not_product": return L.s("error_title_not_product")
        default: return L.s("error_title")
        }
    }

    static func message(for reason: String, host: String?) -> String {
        let shown = FaText.ltr(host ?? "")
        switch reason {
        case "denied": return L.f("denied", shown)
        case "site_unreachable": return L.f("site_unreachable", shown)
        case "page_gone", "not_product", "timeout", "challenge_timeout", "blocked_url", "rate", "read_failed": return L.s(reason)
        default: return L.s("read_failed")
        }
    }

    @objc private func cancelTapped() {
        close(reason: "cancelled")
    }

    private func retry() {
        session.start()
    }

    private func giveUp(dismissed: Bool = false) {
        if case let .failed(reason, _, _) = session.state {
            close(reason: reason, dismissed: dismissed)
        } else {
            close(reason: "cancelled", dismissed: dismissed)
        }
    }

    private var closed = false

    private func close(reason: String, dismissed: Bool = false) {
        guard !closed else { return }
        closed = true
        progressTimer?.invalidate()
        session.close()
        // The handler lets go of the sheet (it may be the last owner of this controller after a swipe).
        withExtendedLifetime(self) {
            onClose?(session, reason, dismissed)
        }
    }
}

extension ReaderViewController: UIAdaptivePresentationControllerDelegate {
    /// A swipe down on the error card (the only state that allows it): the same as «بستن».
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        giveUp(dismissed: true)
    }
}
