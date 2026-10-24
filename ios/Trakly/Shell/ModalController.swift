import TraklyCore
import UIKit
import WebKit

/// The modal context (S3, docs/specs/phase10-apps-and-stores.md D4, §A1, §E3): forms in their own WKWebView
/// (`stacks`) or the one WebView moved in over a snapshot of the tab page (`single`), presented `.fullScreen` inside a
/// `UINavigationController`: «بستن» leading, the title centred (only while the form's own heading is out of view), the
/// WebView pinned between the bar and the keyboard (or the home indicator), `isModalInPresentation` while dirty, the
/// dirty confirm on close.
@MainActor
final class ModalController: UIViewController {
    let panel: Panel
    weak var coordinator: AppCoordinator?
    private(set) lazy var container: UINavigationController = {
        let navigation = UINavigationController(rootViewController: self)
        navigation.modalPresentationStyle = .fullScreen
        navigation.view.semanticContentAttribute = .forceRightToLeft
        navigation.navigationBar.semanticContentAttribute = .forceRightToLeft
        navigation.presentationController?.delegate = self
        return navigation
    }()
    private var actionId: String?

    init(panel: Panel, coordinator: AppCoordinator) {
        self.panel = panel
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal
        let close = UIBarButtonItem(title: L.s("bar_close"), style: .plain, target: self, action: #selector(closeTapped))
        close.accessibilityIdentifier = "modal.close"
        navigationItem.leftBarButtonItem = close
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = Theme.canvas
        root.semanticContentAttribute = .forceRightToLeft
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        attachWebView()
    }

    /// The WebView pinned below the bar and above the keyboard (the keyboard layout guide follows the home indicator
    /// while the keyboard is hidden); the page gets `insets {0, 0}`.
    func attachWebView() {
        let webView = panel.webView
        webView.removeFromSuperview()
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    /// The bar from the newest `page` of the modal's document.
    func update(page: PageState.Page?) {
        title = PageState.barTitle(page)
        isModalInPresentation = page?.dirty == true
        if let action = page?.action {
            actionId = action.id
            let item = UIBarButtonItem(image: ChromePresenter.symbol(for: action.icon), style: .plain, target: self, action: #selector(actionTapped))
            item.accessibilityLabel = action.label
            navigationItem.rightBarButtonItem = item
        } else {
            actionId = nil
            navigationItem.rightBarButtonItem = nil
        }
    }

    @objc private func closeTapped() {
        coordinator?.modalBack(fromCloseButton: true)
    }

    @objc private func actionTapped() {
        guard let actionId else { return }
        panel.send("action", JSONObject([("id", .string(actionId))]), isModal: true)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        panel.shownPage?.night == true ? .lightContent : .default
    }
}

extension ModalController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        coordinator?.modalBack(fromCloseButton: true)
    }
}
