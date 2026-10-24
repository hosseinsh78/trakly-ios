import SwiftUI
import TraklyCore
import UIKit

/// One link of S4 that is not a basket line yet (docs/specs/phase10-apps-and-stores.md §D7, §E6).
struct ComposerRow: Identifiable, Equatable {
    enum State: Equatable {
        /// Shared from another app: nothing is read before «خواندن» (F3).
        case shared
        case fetching
        case reading
        case failed
    }

    let id: String
    let url: String
    let host: String
    var state: State
}

/// What S4 shows (SwiftUI observes it).
@MainActor
final class ComposerModel: ObservableObject {
    @Published var link = ""
    @Published var linkError: String?
    @Published var rows: [ComposerRow] = []
    @Published var lines: [Basket.Line] = []
    @Published var clipboard = false
    @Published var merge = false
    @Published var draftAt: Int64?
    @Published var quick = false
    @Published var focusLink = 0
}

/// Native order entry (docs/specs/phase10-apps-and-stores.md D9, D10, D11, §A2 F1–F3, §B4, §B6, §E5, §E6): S4 the
/// composer, S5 the reader and S6 the review sheet, the basket and its intake ids, the image refs, the single-mode
/// `intake.line` of the web form and its pending result (15 minutes). The product read the composer needs is done by a
/// panel page (`intake.fetch`, §B4.3); native returns only the choice and the web maps it with `importResultOf()`.
@MainActor
final class IntakeController: NSObject {
    weak var coordinator: AppCoordinator?
    let store = BasketStore()
    let refs = ImageRefs()
    let captures = CaptureStore()
    let images = ImageFetcher()
    let model = ComposerModel()
    private let readLimiter = RateLimiter(store: DefaultsStampStore(key: "trakly.reads"), clock: { SystemClock().wallMs() })
    private let fetchLimiter = RateLimiter(store: RateLimiter.MemoryStore(), clock: { SystemClock().nowMs() }, windows: [RateLimiter.Window(max: 20, windowMs: 60_000)])

    private var composer: UIHostingController<ComposerView>?
    private var readerNav: UINavigationController?
    private var reviewHost: UIViewController?
    /// The capture of each row's read (its image URLs bound the native fetches, D11).
    private var rowCaptures: [String: String] = [:]
    /// The open `intake.line` of the web form (single mode).
    private var line: (reply: BridgeReply, lineKey: String, panel: Panel)?
    /// A single-mode choice whose page went away (15 minutes, `intake.pending`).
    private var pendingChoice: (lineKey: String, choice: JSONObject, at: Int64)?

    var basket: Basket { store.basket }

    // MARK: - lifecycle

    func restore() {
        store.load()
        refs.sweep()
        syncModel()
    }

    func account(_ key: String?) {
        if basket.account(key) {
            refs.clear()
            captures.clear()
        }
        store.save()
        syncModel()
    }

    /// After a sign-in of the same account the kept basket comes back with «محصول های انتخاب شده هنوز اینجا هستند.».
    func restoreAfterSignIn() {
        basket.expire()
        guard !basket.state.lines.isEmpty, composer == nil, coordinator?.modal == nil else { return }
        openComposer(shared: [], merge: false)
        coordinator?.toast(L.s("basket_kept"))
    }

    /// A session end (§A1): the image refs and the pending capture go; the basket and the shares stay unless the user
    /// signed out (`explicit`).
    func sessionEnded(explicit: Bool) {
        refs.clear()
        captures.clear()
        pendingChoice = nil
        if explicit {
            basket.signOut()
            PendingShares.clear()
        }
        store.save()
        closeScreens()
        syncModel()
    }

    func closeScreens() {
        readerNav?.dismiss(animated: false)
        readerNav = nil
        reviewHost?.dismiss(animated: false)
        reviewHost = nil
        composer?.dismiss(animated: false)
        composer = nil
        line?.reply.error("cancelled")
        line = nil
    }

    func modalChanged() {
        model.merge = coordinator?.modal.map { BridgeMessages.isOrderFormPath($0.panel.currentPath) } ?? false
    }

    func issuedIds() -> Set<String> {
        basket.issuedIds()
    }

    func refs(for panel: Panel) -> Set<String> {
        refs.live
    }

    func contentProcessTerminated(_ panel: Panel) {
        if line?.panel === panel {
            // The form's page died during S5 or S6: the result waits for `intake.pending` (§A2 F2).
            line?.reply.detach()
        }
    }

    func panelDestroyed(_ panel: Panel) {
        if let open = line, open.panel === panel {
            open.reply.detach()
        }
    }

    private func syncModel() {
        basket.expire()
        model.lines = basket.state.lines
        let shared = basket.state.shared.map(\.url)
        let rows = model.rows.filter { $0.state != .shared || shared.contains($0.url) }
        var added = rows
        for url in shared where !rows.contains(where: { $0.url == url }) {
            added.append(ComposerRow(id: BridgeMessages.randomToken(12), url: url, host: Policy.hostOf(url) ?? url, state: .shared))
        }
        model.rows = added
        model.draftAt = coordinator?.tabs.draftAt
        model.quick = coordinator?.tabs.quick ?? false
    }

    // MARK: - S4

    func openComposer(shared: [String], merge: Bool) {
        for url in shared {
            basket.share(url)
        }
        store.save()
        model.merge = merge
        model.linkError = nil
        syncModel()
        ClipboardChip.probablyHoldsLink { [weak self] found in
            self?.model.clipboard = found
        }
        if composer != nil {
            return
        }
        let view = ComposerView(model: model, actions: ComposerActions(controller: self))
        let host = UIHostingController(rootView: view)
        host.modalPresentationStyle = .pageSheet
        host.view.backgroundColor = Theme.canvas
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = Theme.cardRadius
        }
        host.isModalInPresentation = true
        host.view.accessibilityIdentifier = "composer"
        composer = host
        Alerts.top(from: coordinator?.root)?.present(host, animated: true)
    }

    /// «بستن» of S4: a basket with lines asks «محصول های انتخاب شده نگه داشته شوند؟» first.
    func closeComposer() {
        guard let composer else { return }
        if basket.state.lines.isEmpty {
            dismissComposer()
            return
        }
        let alert = Alerts.make(title: L.s("composer_keep_title"), message: nil)
        alert.addAction(UIAlertAction(title: L.s("composer_discard"), style: .destructive) { [weak self] _ in
            self?.basket.clear()
            self?.store.save()
            self?.syncModel()
            self?.dismissComposer()
        })
        alert.addAction(UIAlertAction(title: L.s("composer_keep"), style: .default) { [weak self] _ in
            self?.basket.touch()
            self?.store.save()
            self?.dismissComposer()
        })
        composer.present(alert, animated: true)
    }

    private func dismissComposer(completion: (() -> Void)? = nil) {
        guard let composer else {
            completion?()
            return
        }
        self.composer = nil
        composer.dismiss(animated: true, completion: completion)
    }

    /// A typed, pasted or chip link: the first product link of the text, the policy, then the automatic read.
    func addLink(_ text: String) {
        model.linkError = nil
        guard let url = LinkText.firstProductUrl(text, dev: AppConfig.devPolicy), Policy.check(url, dev: AppConfig.devPolicy).ok else {
            model.linkError = L.s("composer_bad_link")
            Haptics.play("warning")
            return
        }
        model.link = ""
        if model.rows.contains(where: { $0.url == url && $0.state != .failed }) { return }
        model.rows.removeAll { $0.url == url }
        let row = ComposerRow(id: BridgeMessages.randomToken(12), url: url, host: Policy.hostOf(url) ?? url, state: .fetching)
        model.rows.append(row)
        fetch(row.id)
    }

    /// «خواندن» of a shared row, or «تلاش دوباره» of a failed one.
    func read(_ id: String) {
        guard let index = model.rows.firstIndex(where: { $0.id == id }) else { return }
        let url = model.rows[index].url
        basket.unshare(url)
        store.save()
        model.rows[index].state = .fetching
        fetch(id)
    }

    /// «افزودن بدون مشخصات»: a line with the link only (the user types the details in the form).
    func addBare(_ id: String) {
        guard let row = model.rows.first(where: { $0.id == id }) else { return }
        let product = JSONObject([
            ("url", .string(row.url)), ("site", .string(row.host)), ("title", .null), ("brand", .null), ("images", .array([])),
            ("price", .null), ("currency", .null), ("options", .array([])), ("variants", .array([])),
        ])
        let choice = IntakeChoices.make(product: product, chosen: [:], title: row.host, withBrand: false, quantity: 1, image: nil, source: "server")
        if basket.add(Basket.Line(id: BridgeMessages.randomToken(12), choice: choice, host: row.host, thumb: nil)) {
            model.rows.removeAll { $0.id == id }
            store.save()
            syncModel()
        }
    }

    func removeRow(_ id: String) {
        if let row = model.rows.first(where: { $0.id == id }) {
            basket.unshare(row.url)
            store.save()
        }
        model.rows.removeAll { $0.id == id }
    }

    func removeLine(_ id: String) {
        basket.remove(id)
        store.save()
        syncModel()
    }

    func setQuantity(_ id: String, _ quantity: Int) {
        basket.setQuantity(id, quantity)
        store.save()
        syncModel()
    }

    /// «ادامه ثبت سفارش (n)»: the basket under a fresh intake id → the modal at `/app/orders/create?intake=<id>`; in merge
    /// mode `intake.offer {intakeId}` to the open form instead (D37).
    func continueOrder() {
        guard !basket.state.lines.isEmpty else { return }
        let id = basket.issue(BridgeMessages.randomToken())
        store.save()
        Haptics.play("success")
        let merge = model.merge
        dismissComposer { [weak self] in
            guard let self, let coordinator = self.coordinator else { return }
            if merge, let modal = coordinator.modal {
                let sent = modal.panel.send("intake.offer", JSONObject([("intakeId", .string(id))]), isModal: true, timeout: 15) { _ in }
                if !sent {
                    coordinator.openModal(AppConfig.origin + "/app/orders/create?intake=" + id)
                }
            } else {
                coordinator.openModal(AppConfig.origin + "/app/orders/create?intake=" + id)
            }
        }
    }

    /// «سفارش تازه» in merge mode: the dirty confirm first, then a new form with the basket.
    func newOrderFromMerge() {
        guard let coordinator else { return }
        let id = basket.issue(BridgeMessages.randomToken())
        store.save()
        dismissComposer {
            coordinator.afterModal(confirmFirst: coordinator.modal?.panel.shownPage?.dirty == true) {
                coordinator.openModal(AppConfig.origin + "/app/orders/create?intake=" + id)
            }
        }
    }

    func openQuick() {
        dismissComposer { [weak self] in
            self?.coordinator?.openModal(AppConfig.origin + "/app/orders/quick")
        }
    }

    func openBlank() {
        dismissComposer { [weak self] in
            self?.coordinator?.openModal(AppConfig.origin + "/app/orders/create?blank=1")
        }
    }

    func openDraft() {
        dismissComposer { [weak self] in
            self?.coordinator?.openModal(AppConfig.origin + "/app/orders/create")
        }
    }

    // MARK: - intake.fetch (§B4.3)

    private func setRow(_ id: String, _ state: ComposerRow.State) {
        if let index = model.rows.firstIndex(where: { $0.id == id }) {
            model.rows[index].state = state
        }
    }

    private func candidates() -> [IntakeHost.Candidate] {
        guard let coordinator else { return [] }
        return coordinator.pool.all.map { panel in
            IntakeHost.Candidate(
                key: panel.key,
                isModal: coordinator.modal?.panel === panel,
                isSelected: coordinator.selectedPanel === panel,
                isPrimary: panel.key == WebViewPool.primaryKey || panel.key == WebViewPool.singleKey,
                committedOnOrigin: panel.committedOrigin == AppConfig.origin,
                greeted: panel.greeted,
                context: panel.shownPage?.context,
                loading: panel.loading
            )
        }
    }

    /// Asks a ready panel page to read `url` (with the reader's `capture` the second time); waits up to 10 s for one.
    private func pageFetch(url: String, capture: String?, excluded: Set<String> = [], waited: Int64 = 0, completion: @escaping (JSONObject?) -> Void) {
        guard let coordinator else { return completion(nil) }
        guard let key = IntakeHost.choose(candidates(), excluded: excluded), let panel = coordinator.pool.peek(key) else {
            if waited >= Limits.hostWaitMs {
                completion(JSONObject([("ok", .bool(false)), ("reason", .string("network")), ("message", .string(""))]))
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                self?.pageFetch(url: url, capture: capture, excluded: excluded, waited: waited + 250, completion: completion)
            }
            return
        }
        if !fetchLimiter.take() {
            completion(JSONObject([("ok", .bool(false)), ("reason", .string("rate")), ("message", .string(""))]))
            return
        }
        var body = JSONObject([("url", .string(url))])
        if let capture { body["capture"] = .string(capture) }
        let sent = panel.send("intake.fetch", body, isModal: coordinator.isModal(panel), timeout: TimeInterval(Limits.intakeFetchMs) / 1000) { [weak self, weak panel] reply in
            guard let self else { return }
            if reply == nil, panel == nil || panel?.destroyed == true, excluded.isEmpty {
                // The chosen WebView went away during the request: once more on the next candidate.
                self.pageFetch(url: url, capture: capture, excluded: [key], completion: completion)
                return
            }
            completion(reply ?? JSONObject([("ok", .bool(false)), ("reason", .string(coordinator.online ? "unreachable" : "network")), ("message", .string(""))]))
        }
        if !sent {
            pageFetch(url: url, capture: capture, excluded: excluded.union([key]), waited: waited, completion: completion)
        }
    }

    private var readerOn: Bool {
        BridgeMessages.featureOn("reader", features: AppConfig.features, disabled: coordinator?.disabled ?? [])
    }

    private func fetch(_ id: String, capture: String? = nil) {
        guard let row = model.rows.first(where: { $0.id == id }) else { return }
        setRow(id, capture == nil ? .fetching : .reading)
        pageFetch(url: row.url, capture: capture) { [weak self] reply in
            guard let self, let reply, self.model.rows.contains(where: { $0.id == id }) else { return }
            if reply.bool("ok") == true, let product = reply.object("product") {
                let source = reply.string("source") == "capture" ? "capture" : "server"
                if let capture { self.rowCaptures[id] = capture }
                self.review(product: product, source: source, capture: capture, mode: .composer(rowId: id))
                return
            }
            switch reply.string("reason") ?? "network" {
            case "blocked", "unreachable", "not_product":
                if capture == nil && self.readerOn {
                    self.openReader(url: row.url) { [weak self] captured in
                        guard let self else { return }
                        if let captured {
                            self.fetch(id, capture: captured)
                        } else {
                            self.setRow(id, .failed)
                        }
                    }
                } else {
                    self.setRow(id, .failed)
                }
            case "session":
                // §B4.3: S4 and S5 close; the basket stays on disk, bound to the account.
                self.setRow(id, .failed)
                self.closeScreens()
            case "permission":
                self.setRow(id, .failed)
                self.coordinator?.toast(L.s("composer_permission"))
            case "rate":
                self.setRow(id, .failed)
                self.coordinator?.toast(L.s("rate"))
            default:
                self.setRow(id, .failed)
            }
        }
    }

    // MARK: - S5

    private func openReader(url: String, completion: @escaping (String?) -> Void) {
        let readId = BridgeMessages.randomToken()
        let session = ReaderSession(readId: readId, url: url, captures: captures, limiter: readLimiter)
        let controller = ReaderViewController(session: session)
        let navigation = controller.sheet()
        session.onCaptured = { [weak self] done in
            guard let self else { return }
            let capture = self.captures.get(done.readId)?.capture
            self.captures.remove(done.readId)
            self.readerNav = nil
            navigation.dismiss(animated: true) {
                completion(capture)
            }
            done.close()
        }
        controller.onClose = { [weak self] _, _ in
            self?.readerNav = nil
            navigation.dismiss(animated: true) {
                completion(nil)
            }
        }
        readerNav = navigation
        Alerts.top(from: coordinator?.root)?.present(navigation, animated: true)
    }

    // MARK: - S6

    enum ReviewMode {
        case composer(rowId: String)
        case line(lineKey: String)
    }

    private func review(product: JSONObject, source: String, capture: String?, mode: ReviewMode) {
        let isLine: Bool
        if case .line = mode { isLine = true } else { isLine = false }
        let state = ReviewState(product: product, line: isLine)
        let actions = ReviewActions(
            add: { [weak self] state, next in
                self?.confirm(state, product: product, source: source, capture: capture, mode: mode, next: next)
            },
            cancel: { [weak self] in
                self?.cancelReview(mode)
            },
            thumbnail: { [weak self] url in
                guard let self, ImageAddress.allowedImage(url, product: product, source: source, capture: capture, dev: AppConfig.devPolicy) else { return nil }
                return await self.thumbnail(url)
            }
        )
        let host = UIHostingController(rootView: ReviewSheet(state: state, actions: actions))
        host.modalPresentationStyle = .pageSheet
        host.view.backgroundColor = Theme.surface
        host.view.accessibilityIdentifier = "review"
        if let sheet = host.sheetPresentationController {
            sheet.detents = VariantMatcher.options(product).isEmpty ? [.medium(), .large()] : [.large()]
            sheet.selectedDetentIdentifier = VariantMatcher.options(product).isEmpty ? .medium : .large
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = Theme.cardRadius
        }
        host.isModalInPresentation = true
        reviewHost = host
        Alerts.top(from: coordinator?.root)?.present(host, animated: true)
    }

    private func cancelReview(_ mode: ReviewMode) {
        let host = reviewHost
        reviewHost = nil
        host?.dismiss(animated: true)
        switch mode {
        case let .composer(rowId):
            model.rows.removeAll { $0.id == rowId }
            rowCaptures.removeValue(forKey: rowId)
        case .line:
            line?.reply.error("cancelled")
            line = nil
        }
    }

    private var thumbnails: [String: UIImage] = [:]

    func thumbnail(_ url: String) async -> UIImage? {
        if let cached = thumbnails[url] { return cached }
        guard let data = await images.fetch(url, dev: AppConfig.devPolicy, maxPixels: 600), let image = UIImage(data: data) else { return nil }
        if thumbnails.count > 60 { thumbnails.removeAll() }
        thumbnails[url] = image
        return image
    }

    func refImage(_ ref: String?) -> UIImage? {
        guard let ref, let data = refs.data(ref) else { return nil }
        return UIImage(data: data)
    }

    /// «افزودن به سفارش» / «افزودن و محصول بعدی» / «وارد کردن»: the chosen photo fetched in full and kept under a ref,
    /// the choice built (§B6) and handed on.
    private func confirm(_ state: ReviewState, product: JSONObject, source: String, capture: String?, mode: ReviewMode, next: Bool) {
        let imageUrl = state.selectedImage
        let finish: ((ref: String, url: String)?) -> Void = { [weak self] image in
            guard let self else { return }
            let choice = IntakeChoices.make(product: product, chosen: state.chosen, title: state.title, withBrand: state.withBrand, quantity: state.quantity, image: image, source: source)
            let host = self.reviewHost
            self.reviewHost = nil
            host?.dismiss(animated: true)
            switch mode {
            case let .composer(rowId):
                self.model.rows.removeAll { $0.id == rowId }
                self.rowCaptures.removeValue(forKey: rowId)
                let added = self.basket.add(Basket.Line(id: BridgeMessages.randomToken(12), choice: choice, host: Policy.hostOf(product.string("url")) ?? "", thumb: image?.ref))
                self.store.save()
                self.syncModel()
                if added {
                    Haptics.play("success")
                }
                if next {
                    self.model.focusLink += 1
                }
            case let .line(lineKey):
                self.answerLine(lineKey: lineKey, choice: choice)
            }
        }
        guard let imageUrl, ImageAddress.allowedImage(imageUrl, product: product, source: source, capture: capture, dev: AppConfig.devPolicy) else {
            finish(nil)
            return
        }
        state.saving = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let data = await self.images.fetch(imageUrl, dev: AppConfig.devPolicy)
            let ref = data.flatMap { self.refs.store($0, url: imageUrl) }
            finish(ref.map { (ref: $0, url: imageUrl) })
        }
    }

    // MARK: - the web form's requests (single mode, intake.take, product.image)

    func request(_ type: String, body: JSONObject, from panel: Panel, reply: BridgeReply) {
        switch type {
        case "intake.take":
            guard let lines = basket.take(body.string("intakeId") ?? "") else {
                reply.error("gone")
                return
            }
            store.save()
            syncModel()
            let payload = JSONObject([("lines", .array(lines.map { .object($0.choice) }))])
            if Json.utf8Bytes(Json.write(payload)) > (BridgeMessages.nativeReplyMaxBytes["intake.take"] ?? 0) {
                reply.error("failed")
                return
            }
            reply.ok(payload)
        case "product.image":
            guard let data = refs.data(body.string("ref") ?? "") else {
                reply.error("gone")
                return
            }
            let encoded = data.base64EncodedString()
            if encoded.utf8.count + 200 > (BridgeMessages.nativeReplyMaxBytes["product.image"] ?? 0) {
                reply.error("not_allowed")
                return
            }
            reply.ok(JSONObject([("mime", .string("image/jpeg")), ("data", .string(encoded))]))
        case "intake.pending":
            if let pending = pendingChoice, SystemClock().wallMs() - pending.at <= Limits.pendingChoiceMs {
                pendingChoice = nil
                reply.ok(JSONObject([("lineKey", .string(pending.lineKey)), ("choice", .object(pending.choice))]))
            } else {
                pendingChoice = nil
                reply.ok(JSONObject([("lineKey", .null), ("choice", .null)]))
            }
        case "intake.line":
            intakeLine(body: body, from: panel, reply: reply)
        default:
            reply.error("unsupported")
        }
    }

    /// «دریافت اطلاعات» on a line (F2): with a product S6 only; without one S5 over the modal, then `intake.fetch` with
    /// the capture on the same page, then S6.
    private func intakeLine(body: JSONObject, from panel: Panel, reply: BridgeReply) {
        if line != nil || readerNav != nil || reviewHost != nil {
            reply.error("busy")
            return
        }
        let lineKey = body.string("lineKey") ?? ""
        let url = body.string("url") ?? ""
        line = (reply: reply, lineKey: lineKey, panel: panel)
        if let product = body.object("product") {
            review(product: product, source: "server", capture: nil, mode: .line(lineKey: lineKey))
            return
        }
        guard readerOn else {
            line = nil
            reply.error("failed", JSONObject([("reason", .string("blocked"))]))
            return
        }
        openReader(url: url) { [weak self, weak panel] capture in
            guard let self else { return }
            guard let capture, let panel, !panel.destroyed else {
                self.line?.reply.error(capture == nil ? "cancelled" : "failed")
                self.line = nil
                return
            }
            let sent = panel.send("intake.fetch", JSONObject([("url", .string(url)), ("capture", .string(capture))]), isModal: self.coordinator?.isModal(panel) ?? true, timeout: TimeInterval(Limits.intakeFetchMs) / 1000) { [weak self] answer in
                guard let self else { return }
                if let answer, answer.bool("ok") == true, let product = answer.object("product") {
                    self.review(product: product, source: "capture", capture: capture, mode: .line(lineKey: lineKey))
                } else {
                    self.line?.reply.error("failed", JSONObject([("reason", .string(answer?.string("reason") ?? "unreachable"))]))
                    self.line = nil
                }
            }
            if !sent {
                self.line?.reply.error("failed", JSONObject([("reason", .string("unreachable"))]))
                self.line = nil
            }
        }
    }

    private func answerLine(lineKey: String, choice: JSONObject) {
        guard let open = line else { return }
        line = nil
        if open.reply.reachable {
            open.reply.ok(JSONObject([("choice", .object(choice))]))
        } else {
            // The page that asked is gone (a reload, a killed WebContent process): the choice waits 15 minutes.
            pendingChoice = (lineKey: lineKey, choice: choice, at: SystemClock().wallMs())
        }
    }
}

/// The reader's take counter in UserDefaults (phase 8 LIMITS: 10 a minute, 120 an hour, §B5).
final class DefaultsStampStore: RateLimitStore {
    private let key: String

    init(key: String) {
        self.key = key
    }

    func load() -> [Int64] {
        RateLimiter.decode(UserDefaults.standard.string(forKey: key))
    }

    func save(_ stamps: [Int64]) {
        UserDefaults.standard.set(RateLimiter.encode(stamps), forKey: key)
    }
}

/// What S4 can ask its controller.
@MainActor
struct ComposerActions {
    weak var controller: IntakeController?

    func close() { controller?.closeComposer() }
    func add(_ text: String) { controller?.addLink(text) }
    func read(_ id: String) { controller?.read(id) }
    func bare(_ id: String) { controller?.addBare(id) }
    func removeRow(_ id: String) { controller?.removeRow(id) }
    func removeLine(_ id: String) { controller?.removeLine(id) }
    func quantity(_ id: String, _ value: Int) { controller?.setQuantity(id, value) }
    func proceed() { controller?.continueOrder() }
    func newOrder() { controller?.newOrderFromMerge() }
    func quick() { controller?.openQuick() }
    func blank() { controller?.openBlank() }
    func draft() { controller?.openDraft() }
    func image(_ ref: String?) -> UIImage? { controller?.refImage(ref) }
}
