import TraklyCore
import UIKit
import WebKit

/// What the shell does with the bridge's accepted messages (docs/specs/phase10-apps-and-stores.md §B4, §E7).
@MainActor
protocol BridgeDelegate: AnyObject {
    /// `hello.features` of this build and `config.disabled` (the server's switches, §B4.4).
    var bridgeFeatures: [String] { get }
    var bridgeDisabled: [String] { get }

    /// The `hello` reply body (§B4.1); the document is greeted once it is sent.
    func helloReply(for panel: Panel, path: String) -> JSONObject

    /// The native state the capability checks of `intake.take` and `product.image` need (§B5).
    func nativeState(for panel: Panel, type: String) -> BridgeMessages.NativeState

    /// `lock.set` and `shopdata.clear`: native's own prompt first (§B5); `confirmed` false answers `cancelled`.
    func confirm(_ type: String, body: JSONObject, from panel: Panel, completion: @escaping (Bool) -> Void)

    /// A web → native request; answer exactly once through `reply`.
    func bridgeRequest(_ type: String, body: JSONObject, from panel: Panel, reply: BridgeReply)

    /// A web → native notification.
    func bridgeNotify(_ type: String, body: JSONObject, from panel: Panel)

    /// Whether `panel` is the open modal (§B5 `intake.offer` goes only there).
    func isModal(_ panel: Panel) -> Bool
}

/// The answer to one web request (§B3). While the message is being handled it goes back as the script message's own
/// reply; once the handler returned, a later answer goes through `__receive` to the document that asked (and is
/// dropped when that document is gone, as Android's reply proxy of an old document).
@MainActor
final class BridgeReply {
    let id: String
    let type: String
    private weak var panel: Panel?
    private let document: Int
    private var immediate: ((String) -> Void)?
    private(set) var sent = false

    init(id: String, type: String, panel: Panel, immediate: @escaping (String) -> Void) {
        self.id = id
        self.type = type
        self.panel = panel
        document = panel.document
        self.immediate = immediate
    }

    /// The script message's own reply is gone (the handler returned): later answers use `__receive`.
    func detach() {
        immediate = nil
    }

    /// Whether the document that asked is still the panel's current one.
    var reachable: Bool {
        guard let panel else { return false }
        return !panel.destroyed && panel.document == document
    }

    func ok(_ body: JSONObject = JSONObject()) {
        post(BridgeMessages.replyOk(id, body))
    }

    func error(_ code: String, _ extra: JSONObject = JSONObject()) {
        post(BridgeMessages.replyError(id, code, extra))
    }

    private func post(_ raw: String) {
        if sent { return }
        sent = true
        if let immediate {
            self.immediate = nil
            immediate(raw)
            return
        }
        guard reachable, let panel else { return }
        panel.deliver(raw)
    }
}

/// The TraklyNative bridge (§B2–§B5, §E7): the one `WKScriptMessageHandlerWithReply` of every panel WebView. Guards of
/// §B2 before parsing (a registered panel WebView, the main frame, the exact origin, a string body), then
/// `BridgeMessages.checkWebMessage` (envelope, schema, feature, path and URL rules), the per-type native rate limits,
/// the capability checks and the dispatch on the main actor.
@MainActor
final class BridgeHub: NSObject {
    weak var delegate: BridgeDelegate?
    private var panels: [ObjectIdentifier: Panel] = [:]
    let rates = BridgeRates(clock: { SystemClock().nowMs() })

    func register(_ panel: Panel) {
        panels[ObjectIdentifier(panel.webView)] = panel
    }

    func unregister(_ panel: Panel) {
        panels.removeValue(forKey: ObjectIdentifier(panel.webView))
    }

    func panel(for webView: WKWebView) -> Panel? {
        panels[ObjectIdentifier(webView)]
    }

    /// `scheme://host[:port]` of a frame's security origin (port 0 = the scheme's default).
    static func origin(of security: WKSecurityOrigin) -> String {
        let scheme = security.protocol.lowercased()
        let host = security.host.lowercased()
        let port = security.port
        let defaultPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        return port == 0 || defaultPort ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
    }

    func receive(_ message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        // §B2: the guards before parsing. A refused message gets no reply (as Android drops it).
        guard let webView = message.webView, let panel = panels[ObjectIdentifier(webView)], !panel.destroyed,
              message.frameInfo.isMainFrame, let raw = message.body as? String, let delegate
        else {
            replyHandler(nil, nil)
            return
        }
        let context = BridgeMessages.GuardContext(
            origin: BridgeHub.origin(of: message.frameInfo.securityOrigin),
            mainFrame: true,
            path: panel.currentPath,
            trusted: AppConfig.origin,
            features: delegate.bridgeFeatures,
            disabled: delegate.bridgeDisabled
        )

        switch BridgeMessages.checkWebMessage(raw, context) {
        case let .refused(error, id):
            replyHandler(id.map { BridgeMessages.replyError($0, error) }, nil)
        case let .reply(re, body):
            panel.answer(re, body)
            replyHandler(nil, nil)
        case let .message(kind, id, type, body):
            accept(panel, kind: kind, id: id, type: type, body: body, delegate: delegate, replyHandler: replyHandler)
        }
    }

    private func accept(_ panel: Panel, kind: BridgeMessages.Kind, id: String?, type: String, body: JSONObject, delegate: BridgeDelegate, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        if !rates.take(type) {
            replyHandler(id.map { BridgeMessages.replyError($0, "rate") }, nil)
            return
        }

        if type == "hello", let id {
            // A late hello is always answered (D8); the document is greeted from now on.
            let reply = BridgeMessages.replyOk(id, delegate.helloReply(for: panel, path: body.string("path") ?? "/"))
            panel.greet()
            replyHandler(reply, nil)
            delegate.bridgeNotify("hello", body: body, from: panel)
            return
        }

        guard kind == .request, let id else {
            replyHandler(nil, nil)
            delegate.bridgeNotify(type, body: body, from: panel)
            return
        }

        var answered = false
        let reply = BridgeReply(id: id, type: type, panel: panel) { raw in
            answered = true
            replyHandler(raw, nil)
        }

        if type == "lock.set" || type == "shopdata.clear" {
            reply.detach()
            replyHandler(nil, nil)
            delegate.confirm(type, body: body, from: panel) { [weak self] confirmed in
                guard self != nil else { return }
                if let error = BridgeMessages.admitWebMessage(type, body, BridgeMessages.NativeState(confirmed: confirmed)) {
                    reply.error(error)
                } else {
                    delegate.bridgeRequest(type, body: body, from: panel, reply: reply)
                }
            }
            return
        }

        if let error = BridgeMessages.admitWebMessage(type, body, delegate.nativeState(for: panel, type: type)) {
            reply.error(error)
            return
        }

        delegate.bridgeRequest(type, body: body, from: panel, reply: reply)
        if !answered {
            // The answer comes later (a sheet, a read): the script message's reply is released now.
            reply.detach()
            replyHandler(nil, nil)
        }
    }
}
