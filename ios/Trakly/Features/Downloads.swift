import QuickLook
import TraklyCore
import UIKit
import WebKit

/// Files (S9, docs/specs/phase10-apps-and-stores.md D23, §B5, §E9, §I5): `file.save` (every file up to 10 MiB the page
/// fetched with its own session) and `download` (larger files: `webView.startDownload(using:)` on the requesting panel
/// WebView, its own session, same origin and `/app/` only, every redirect hop re-checked) go to a temporary folder of
/// the app and open in Quick Look, whose share button offers the system's "Save to Files" (and "Save Image").
/// Files older than 24 hours are deleted at launch.
@MainActor
final class Downloads: NSObject {
    private var active: [ObjectIdentifier: (reply: BridgeReply?, presenter: UIViewController?, hops: Int, name: String?, destination: URL?)] = [:]
    private var preview: PreviewSource?

    /// `tmp/exports/` of the app (never public storage).
    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("exports", isDirectory: true)
    }

    /// Removes exported files older than a day (the only file dates the app reads: `C617.1`).
    func cleanUp() {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: Downloads.folder, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { return }
        let limit = Date().addingTimeInterval(-TimeInterval(Limits.fileKeepMs) / 1000)
        for entry in entries {
            let date = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if date < limit {
                try? manager.removeItem(at: entry)
            }
        }
    }

    private func freshFolder() throws -> URL {
        let folder = Downloads.folder.appendingPathComponent(BridgeMessages.randomToken(12), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: - file.save

    func save(name: String, mime: String, base64: String, presenter: UIViewController?, reply: BridgeReply) {
        guard BridgeMessages.fileSaveMimes.contains(mime), let data = Data(base64Encoded: base64), data.count <= Limits.fileSaveBytes else {
            reply.error("invalid")
            return
        }
        do {
            let file = try freshFolder().appendingPathComponent(FileNames.sanitize(name, mime: mime))
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            show(file, from: presenter)
            reply.ok()
        } catch {
            reply.error("failed")
        }
    }

    // MARK: - download (> 10 MiB)

    func download(_ url: String, name: String?, panel: Panel, presenter: UIViewController?, reply: BridgeReply) {
        guard Redirects.allowed(url, trusted: AppConfig.origin), let target = URL(string: url) else {
            reply.error("denied")
            return
        }
        panel.webView.startDownload(using: URLRequest(url: target)) { [weak self] download in
            MainActor.assumeIsolated {
                guard let self else { return }
                download.delegate = self
                self.active[ObjectIdentifier(download)] = (reply: reply, presenter: presenter, hops: 0, name: name, destination: nil)
            }
        }
    }

    /// A navigation that became a download (the fallback of §E4).
    func adopt(_ download: WKDownload, presenter: UIViewController?) {
        download.delegate = self
        active[ObjectIdentifier(download)] = (reply: nil, presenter: presenter, hops: 0, name: nil, destination: nil)
    }

    private func finish(_ download: WKDownload, ok: Bool) {
        guard let entry = active.removeValue(forKey: ObjectIdentifier(download)) else { return }
        if ok, let file = entry.destination {
            show(file, from: entry.presenter)
            entry.reply?.ok()
        } else {
            entry.reply?.error("failed")
            if entry.reply == nil, let presenter = entry.presenter {
                Toast.show(L.s("download_failed"), in: presenter.view)
            }
        }
    }

    // MARK: - Quick Look

    private func show(_ file: URL, from presenter: UIViewController?) {
        guard let presenter else { return }
        let source = PreviewSource(file: file)
        preview = source
        let controller = QLPreviewController()
        controller.dataSource = source
        controller.modalPresentationStyle = .pageSheet
        presenter.present(controller, animated: true)
    }
}

extension Downloads: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        let key = ObjectIdentifier(download)
        guard var entry = active[key] else {
            completionHandler(nil)
            return
        }
        if response.expectedContentLength > Limits.downloadBytes {
            completionHandler(nil)
            return
        }
        do {
            let file = try freshFolder().appendingPathComponent(FileNames.sanitize(entry.name ?? suggestedFilename, mime: response.mimeType))
            entry.destination = file
            active[key] = entry
            completionHandler(file)
        } catch {
            completionHandler(nil)
        }
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, decisionHandler: @escaping @MainActor @Sendable (WKDownload.RedirectPolicy) -> Void) {
        let key = ObjectIdentifier(download)
        guard var entry = active[key] else {
            decisionHandler(.cancel)
            return
        }
        entry.hops += 1
        active[key] = entry
        let next = request.url?.absoluteString ?? ""
        decisionHandler(Redirects.follow(next, hop: entry.hops, trusted: AppConfig.origin) ? .allow : .cancel)
    }

    func downloadDidFinish(_ download: WKDownload) {
        finish(download, ok: true)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        finish(download, ok: false)
    }
}

/// One file for Quick Look.
final class PreviewSource: NSObject, QLPreviewControllerDataSource {
    let file: URL

    init(file: URL) {
        self.file = file
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        1
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        file as NSURL
    }
}
