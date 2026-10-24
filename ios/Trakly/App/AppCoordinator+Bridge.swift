import TraklyCore
import UIKit
import WebKit

/// The coordinator's side of the bridge (docs/specs/phase10-apps-and-stores.md §B4.1, §B4.4, §B5, §E7, §E9) and of the
/// panel WebViews' navigation (§B1, §E3, §E4).
extension AppCoordinator: BridgeDelegate {
    var bridgeFeatures: [String] { AppConfig.features }

    var bridgeDisabled: [String] { disabled }

    func helloReply(for panel: Panel, path: String) -> JSONObject {
        let insets = insetsFor(panel)
        let scale = UIFontMetrics.default.scaledValue(for: 17) / 17
        return JSONObject([
            ("platform", .string("ios")),
            ("version", .string(AppConfig.version)),
            ("build", .int(AppConfig.build)),
            ("store", .string(AppConfig.store)),
            ("features", .strings(AppConfig.features)),
            ("appearance", .object(JSONObject([("mode", .string(Appearance.mode)), ("resolved", .string(resolvedNight ? "dark" : "light"))]))),
            ("textScale", .number((Double(scale) * 100).rounded() / 100)),
            ("topology", .string(pool.topology.rawValue)),
            ("insets", .object(JSONObject([("top", .number(insets.top)), ("bottom", .number(insets.bottom))]))),
        ])
    }

    func nativeState(for panel: Panel, type: String) -> BridgeMessages.NativeState {
        switch type {
        case "intake.take": return BridgeMessages.NativeState(intakeIds: intake.issuedIds())
        case "product.image": return BridgeMessages.NativeState(refs: intake.refs(for: panel))
        default: return BridgeMessages.NativeState()
        }
    }

    func confirm(_ type: String, body: JSONObject, from panel: Panel, completion: @escaping (Bool) -> Void) {
        switch type {
        case "lock.set":
            lock.authenticate(reason: L.s("lock_change_reason"), completion: completion)
        case "shopdata.clear":
            let alert = Alerts.make(title: L.s("clear_data_title"), message: L.s("clear_data_body"))
            alert.addAction(UIAlertAction(title: L.s("cancel_dialog"), style: .cancel) { _ in completion(false) })
            alert.addAction(UIAlertAction(title: L.s("clear_data_yes"), style: .destructive) { _ in completion(true) })
            Alerts.top(from: root)?.present(alert, animated: true)
        default:
            completion(false)
        }
    }

    func bridgeRequest(_ type: String, body: JSONObject, from panel: Panel, reply: BridgeReply) {
        let presenter = Alerts.top(from: root)
        switch type {
        case "intake.line", "intake.take", "intake.pending", "product.image":
            intake.request(type, body: body, from: panel, reply: reply)
        case "route":
            route(panel, body: body, reply: reply)
        case "download":
            files.download(body.string("url") ?? "", name: body.string("name"), panel: panel, presenter: presenter, reply: reply)
        case "file.save":
            files.save(name: body.string("name") ?? "", mime: body.string("mime") ?? "", base64: body.string("data") ?? "", presenter: presenter, reply: reply)
        case "print":
            printer.preview(url: body.string("url") ?? "", title: body.string("title") ?? "", from: presenter, reply: reply)
        case "share":
            share(text: body.string("text"), url: body.string("url"), title: body.string("title"), from: presenter, reply: reply)
        case "open.external":
            if ExternalLinks.open(body.string("url") ?? "", from: presenter) {
                reply.ok()
            } else {
                reply.error("denied")
            }
        case "scan":
            scanner.scan(formats: body["formats"]?.stringList ?? [], from: presenter, reply: reply)
        case "lock.set":
            lock.setEnabled(body.bool("enabled") == true)
            reply.ok()
        case "shopdata.clear":
            ReaderWebView.clearShopData { [weak self] in
                reply.ok(JSONObject([("signedOut", .bool(false))]))
                self?.toast(L.s("clear_data_done"))
            }
        default:
            reply.error("unsupported")
        }
    }

    func bridgeNotify(_ type: String, body: JSONObject, from panel: Panel) {
        switch type {
        case "hello":
            sendInsets(panel)
        case "config":
            onConfig(body)
        case "ready":
            panel.ready = true
            if panel === selectedPanel || panel.key == WebViewPool.primaryKey || panel.key == WebViewPool.singleKey {
                endLaunchCover()
            }
        case "page":
            onPage(panel, PageState.Page.of(body))
        case "title":
            if var page = panel.page {
                page.titleVisible = body.bool("visible") == true
                panel.notePage(page)
                refreshChrome()
            }
        case "tabs":
            onTabs(body)
        case "compose":
            compose(sharedUrls: [], fromTab: true)
        case "haptic":
            Haptics.play(body.string("kind") ?? "")
        case "modal.close":
            if modal?.panel === panel {
                closeModal(navigateBack: false)
            }
        case "appearance.set":
            setAppearance(body.string("mode") ?? "system")
        case "session.ended":
            intake.sessionEnded(explicit: true)
        default:
            break
        }
    }

    /// `route` (§B4.1, §B7): another context for a visit; `handled: true` when native shows it.
    private func route(_ panel: Panel, body: JSONObject, reply: BridgeReply) {
        let url = body.string("url") ?? ""
        switch body.string("context") {
        case "external":
            reply.ok(JSONObject([("handled", .bool(ExternalLinks.open(url, from: Alerts.top(from: root))))]))
        case "modal":
            if modal?.panel === panel {
                // The modal's own document asks (single: the one WebView just moved into the modal): it visits in place.
                reply.ok(JSONObject([("handled", .bool(false))]))
            } else {
                openModal(url)
                reply.ok(JSONObject([("handled", .bool(true))]))
            }
        default:
            let tab = body.string("tab") ?? tabForPanelUrl(url)
            if pool.topology == .single {
                if modal?.panel === panel {
                    // The form left the modal: the one WebView goes back to its tab and shows the result there.
                    closeModal(navigateBack: false)
                }
                reply.ok(JSONObject([("handled", .bool(false))]))
                return
            }
            if modal?.panel === panel {
                closeModal(navigateBack: false)
            }
            visitInTab(tab, url: url)
            reply.ok(JSONObject([("handled", .bool(true))]))
        }
    }

    private func share(text: String?, url: String?, title: String?, from presenter: UIViewController?, reply: BridgeReply) {
        var items: [Any] = []
        if let text { items.append(text) }
        if let url, let parsed = URL(string: url) { items.append(parsed) }
        guard let presenter, !items.isEmpty else {
            reply.error("failed")
            return
        }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in }
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 40, width: 1, height: 1)
        }
        presenter.present(sheet, animated: true)
        reply.ok()
    }

    /// A short native message at the bottom (the copy's texts only).
    func toast(_ text: String) {
        Toast.show(text, in: root.view)
    }
}

extension AppCoordinator: PanelEvents {
    func panelDocumentStarted(_ panel: Panel) {
        if panel === selectedPanel || panel === modalPanel {
            root.removeOverlay(tag: Overlay.offline)
        }
        refreshChrome()
    }

    func panelDocumentCommitted(_ panel: Panel) {
        if firstCommitAtIsUnset, panel === selectedPanel {
            markFirstCommit()
        }
        refreshChrome(animated: false)
    }

    func panelDocumentFinished(_ panel: Panel) {
        endRefreshingIfNeeded(panel)
        refreshChrome()
    }

    func panelMainFrameFailed(_ panel: Panel, error: Error) {
        if panel === selectedPanel || panel === modalPanel {
            showOffline()
        }
    }

    func panelHistoryChanged(_ panel: Panel) {
        if let stack = stack(of: panel), panel.page != nil, stack.depth > 1 || panel.historyIndex > 0 {
            refreshChrome()
        }
    }

    func panelLeave(_ panel: Panel, url: String, target: NavigationPolicy.Target) {
        leave(url)
    }

    func panelWindowRequest(_ panel: Panel, url: String) {
        windowRequest(panel, url: url)
    }

    func panelContentProcessTerminated(_ panel: Panel) {
        // §E3: the page is reloaded (the order form restores its draft).
        if let url = panel.currentUrl {
            panel.load(url)
        } else {
            panel.webView.reload()
        }
        intake.contentProcessTerminated(panel)
    }

    func panelDownload(_ panel: Panel, download: WKDownload) {
        files.adopt(download, presenter: Alerts.top(from: root))
    }

    func panelPresenter(_ panel: Panel) -> UIViewController? {
        Alerts.top(from: root)
    }

    func panelWillBeDestroyed(_ panel: Panel) {
        for stack in stacks.values where stack.panel === panel {
            stack.detachPanel(resetHistory: true)
        }
        intake.panelDestroyed(panel)
    }
}
