import UIKit
import WebKit

/// One page of a tab stack (docs/specs/phase10-apps-and-stores.md §E2, §E3): shows the stack's WKWebView while it is on
/// top, else the snapshot of the page it held (the lower host of a push). In `tab` and `push` the WebView sits between
/// the bars (the page gets `insets {0, 0}`); in `auth` and `standalone` it is full screen and native sends the safe
/// area as `insets`.
@MainActor
final class WebHostViewController: UIViewController {
    weak var stack: TabStack?
    private let snapshotView = UIImageView()
    private(set) weak var webView: WKWebView?
    private var webConstraints: [NSLayoutConstraint] = []
    private(set) var fullScreen = false
    /// The chrome this host last drew (ChromePresenter).
    var drawnTitle: String?
    /// The bar buttons this host last drew (they are made again only when they change).
    var drawnButtons: String?

    init(stack: TabStack?) {
        self.stack = stack
        super.init(nibName: nil, bundle: nil)
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func loadView() {
        let root = UIView()
        root.backgroundColor = Theme.canvas
        root.semanticContentAttribute = .forceRightToLeft
        snapshotView.translatesAutoresizingMaskIntoConstraints = false
        snapshotView.contentMode = .top
        snapshotView.clipsToBounds = true
        snapshotView.isAccessibilityElement = false
        snapshotView.isHidden = true
        root.addSubview(snapshotView)
        view = root
        layoutSnapshot()
    }

    private var snapshotConstraints: [NSLayoutConstraint] = []

    private func layoutSnapshot() {
        NSLayoutConstraint.deactivate(snapshotConstraints)
        snapshotConstraints = [
            snapshotView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            snapshotView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            snapshotView.topAnchor.constraint(equalTo: fullScreen ? view.topAnchor : view.safeAreaLayoutGuide.topAnchor),
            snapshotView.bottomAnchor.constraint(equalTo: fullScreen ? view.bottomAnchor : view.safeAreaLayoutGuide.bottomAnchor),
        ]
        NSLayoutConstraint.activate(snapshotConstraints)
    }

    /// Shows `webView` here (it leaves its previous host).
    func show(_ webView: WKWebView) {
        loadViewIfNeeded()
        if webView.superview !== view {
            webView.removeFromSuperview()
            view.addSubview(webView)
        }
        self.webView = webView
        layoutWebView()
        snapshotView.isHidden = true
        view.bringSubviewToFront(webView)
    }

    /// The page as it was, while the WebView is elsewhere (nil: the canvas only).
    func showSnapshot(_ image: UIImage?) {
        loadViewIfNeeded()
        snapshotView.image = image
        snapshotView.isHidden = false
        view.bringSubviewToFront(snapshotView)
    }

    /// Drops the snapshot image (at most two kept per stack, §E3).
    func dropSnapshot() {
        snapshotView.image = nil
    }

    var hasWebView: Bool {
        webView?.superview === view
    }

    func setFullScreen(_ value: Bool) {
        guard value != fullScreen else { return }
        fullScreen = value
        if isViewLoaded {
            layoutSnapshot()
            layoutWebView()
        }
    }

    private func layoutWebView() {
        guard let webView, webView.superview === view else { return }
        NSLayoutConstraint.deactivate(webConstraints)
        webConstraints = [
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: fullScreen ? view.topAnchor : view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: fullScreen ? view.bottomAnchor : view.safeAreaLayoutGuide.bottomAnchor),
        ]
        NSLayoutConstraint.activate(webConstraints)
    }

    /// The safe-area insets a full-screen page keeps clear itself (CSS px = points).
    var pageInsets: (top: Double, bottom: Double) {
        guard fullScreen else { return (0, 0) }
        let insets = view.window?.safeAreaInsets ?? view.safeAreaInsets
        return (Double(insets.top), Double(insets.bottom))
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        stack?.hostInsetsChanged(self)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        stack?.statusBarStyle ?? .default
    }
}
