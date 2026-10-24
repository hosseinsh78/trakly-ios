import TraklyCore
import UIKit

/// The panel WebViews by key (docs/specs/phase10-apps-and-stores.md D4, §A1, §B15): `stacks` keeps one per tab key and
/// one for `modal`, at most three live (the primary Home, the selected tab, the modal); the least recently used tab
/// WebView is destroyed and later restored from its URL. `single` maps every key to the one WebView `single`. The
/// topology is read at launch (the server's `config.topology` of the last run).
@MainActor
final class WebViewPool {
    enum Topology: String {
        case stacks, single
    }

    static let modalKey = "modal"
    static let singleKey = "single"
    static let primaryKey = "home"

    let topology: Topology
    private let hub: BridgeHub
    private weak var events: PanelEvents?
    private(set) var live: [String: Panel] = [:]
    private var recent: [String] = []
    /// The URL a destroyed tab WebView comes back at.
    var restoreUrls: [String: String] = [:]

    init(topology: Topology, hub: BridgeHub, events: PanelEvents) {
        self.topology = topology
        self.hub = hub
        self.events = events
    }

    func key(for tab: String) -> String {
        topology == .single ? WebViewPool.singleKey : tab
    }

    func peek(_ key: String) -> Panel? {
        live[key]
    }

    var all: [Panel] { Array(live.values) }

    /// The panel of `key`, made when missing (`fresh` true: it has loaded nothing yet). Making one may destroy the
    /// least recently used tab WebView that is neither the primary, `keep`, nor the modal.
    func acquire(_ key: String, keep: Set<String> = []) -> (panel: Panel, fresh: Bool) {
        touch(key)
        if let existing = live[key] {
            return (existing, false)
        }
        let panel = Panel(key: key, hub: hub, events: events)
        live[key] = panel
        evict(keep: keep.union([key]))
        return (panel, true)
    }

    private func touch(_ key: String) {
        recent.removeAll { $0 == key }
        recent.append(key)
    }

    private func evict(keep: Set<String>) {
        guard topology == .stacks else { return }
        while live.count > Limits.liveWebViews {
            guard let victim = recent.first(where: { live[$0] != nil && !keep.contains($0) && $0 != WebViewPool.primaryKey && $0 != WebViewPool.modalKey }) else { return }
            release(victim)
        }
    }

    /// Destroys the panel of `key`, remembering its URL.
    func release(_ key: String) {
        guard let panel = live.removeValue(forKey: key) else { return }
        recent.removeAll { $0 == key }
        if let url = panel.currentUrl, key != WebViewPool.modalKey {
            restoreUrls[key] = url
        }
        events?.panelWillBeDestroyed(panel)
        panel.destroy()
    }

    /// Every panel but `key` goes (a session end or a collapse to one WebView, §A1).
    func releaseAll(except key: String?) {
        for other in Array(live.keys) where other != key {
            release(other)
            restoreUrls.removeValue(forKey: other)
        }
    }

    /// The panel of `from` now lives under `to` (a tab panel whose document belongs to another tab).
    func move(_ from: String, to: String) {
        guard from != to, let panel = live.removeValue(forKey: from) else { return }
        if live[to] != nil {
            release(to)
        }
        panel.key = to
        live[to] = panel
        recent.removeAll { $0 == from }
        touch(to)
    }
}
