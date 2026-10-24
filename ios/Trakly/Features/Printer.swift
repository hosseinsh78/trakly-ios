import TraklyCore
import UIKit
import WebKit

/// Print (S9, docs/specs/phase10-apps-and-stores.md §B4.1 `print`, §B5, §E9): a print view of the panel (same origin,
/// `PRINT_PATH`; the server drops its toolbar and autoprint for the app token) in a preview screen «پیش نمایش چاپ» with
/// a WebView from the factory (no bridge); «چاپ یا ذخیره PDF» waits for `document.fonts.ready` and opens
/// `UIPrintInteractionController` with the page's print formatter; «اشتراک PDF» makes a PDF with `createPDF` and opens
/// the share sheet.
@MainActor
final class Printer {
    func preview(url: String, title: String, from presenter: UIViewController?, reply: BridgeReply?) {
        guard let parsed = Url.parse(url), parsed.origin == AppConfig.origin, BridgeMessages.isPrintPath(parsed.pathname), let target = URL(string: url), let presenter else {
            reply?.error("denied")
            return
        }
        let controller = PrintPreviewController(url: target, title: title)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .fullScreen
        navigation.view.semanticContentAttribute = .forceRightToLeft
        navigation.navigationBar.semanticContentAttribute = .forceRightToLeft
        presenter.present(navigation, animated: true)
        reply?.ok()
    }
}

@MainActor
final class PrintPreviewController: UIViewController, WKNavigationDelegate {
    private let url: URL
    private let jobTitle: String
    private let webView = PanelWebViewFactory.make(bridge: nil)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var loaded = false

    init(url: URL, title: String) {
        self.url = url
        jobTitle = title
        super.init(nibName: nil, bundle: nil)
        self.title = L.s("print_title")
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: L.s("bar_close"), style: .plain, target: self, action: #selector(closeTapped))
        let printItem = UIBarButtonItem(title: L.s("print_action"), style: .done, target: self, action: #selector(printTapped))
        printItem.accessibilityIdentifier = "print.print"
        let shareItem = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), style: .plain, target: self, action: #selector(shareTapped))
        shareItem.accessibilityLabel = L.s("print_share_pdf")
        shareItem.accessibilityIdentifier = "print.share"
        navigationItem.rightBarButtonItems = [printItem, shareItem]
        navigationItem.largeTitleDisplayMode = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.canvas
        view.addSubview(webView)
        webView.navigationDelegate = self
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        spinner.startAnimating()
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        // Only this print view and its own subresources; nothing navigates away from the preview.
        if navigationAction.targetFrame?.isMainFrame == true, let next = navigationAction.request.url?.absoluteString {
            let path = NavigationPolicy.pathOf(next) ?? ""
            decisionHandler(NavigationPolicy.originOf(next) == AppConfig.origin && BridgeMessages.isPrintPath(path) ? .allow : .cancel)
            return
        }
        decisionHandler(navigationAction.targetFrame == nil ? .cancel : .allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        spinner.stopAnimating()
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    private var printName: String {
        jobTitle.isEmpty ? (webView.title ?? "Trakly") : jobTitle
    }

    @objc private func printTapped() {
        webView.callAsyncJavaScript("await document.fonts.ready; return true;", arguments: [:], in: nil, in: .page) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let info = UIPrintInfo(dictionary: nil)
                info.outputType = .general
                info.jobName = self.printName
                let controller = UIPrintInteractionController.shared
                controller.printInfo = info
                controller.printFormatter = self.webView.viewPrintFormatter()
                _ = controller.present(animated: true, completionHandler: nil)
            }
        }
    }

    @objc private func shareTapped() {
        webView.createPDF(configuration: WKPDFConfiguration()) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, case let .success(data) = result else { return }
                let file = Downloads.folder.appendingPathComponent(FileNames.sanitize(self.printName, mime: "application/pdf"))
                try? FileManager.default.createDirectory(at: Downloads.folder, withIntermediateDirectories: true)
                guard (try? data.write(to: file, options: .atomic)) != nil else { return }
                let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
                sheet.popoverPresentationController?.barButtonItem = self.navigationItem.rightBarButtonItems?.last
                self.present(sheet, animated: true)
            }
        }
    }
}
