import Foundation

/// The read state machine (docs/specs/phase9-phone-capture.md D12; phase 10 §E5): a port of the loop of `bg-core.js`
/// `read()` and of Android's `core/ReadLoop.kt`, with the `LIMITS` of `protocol.js`. Pure: the reader feeds it the
/// WebView's events and the probe results and asks `tick()` what to do; the clock is injected so tests drive time.
/// `shared/fixtures/readloop-cases.json` proves parity with Kotlin (`ReadLoopTests`).
///
/// - Every failure names the **requested** host.
/// - The current URL is "same" when its host key equals the requested key; a cross-host `denied` or main-frame error,
///   and a refused URL, count as `none` (no cross-site oracle).
/// - A product is accepted when its URL passes the policy and its host equals the host the page **ended** on, at once
///   for `ld`, after 4 s of `complete` for `meta`; else it is `loading`.
/// - `challenge` for 5 s: the banner shows the challenge copy and the deadline becomes now + 120 s (once).
/// - `none` with `complete`: hint at 4 s, `not_product` at 10 s. `denied` on the same host for 8 s: `denied`. A
///   main-frame error on the same host: `site_unreachable`. Deadline: `challenge_timeout` when a challenge was seen,
///   else `timeout`.
public final class ReadLoop {
    public enum Stage: String, Equatable, Sendable {
        case opening, loading, slow, challenge
    }

    /// The asset's `op:'probe'` summary: `state`, and for a product `strength`, `url` and `shopifyUrl`.
    public struct ProbeResult: Equatable, Sendable {
        public let state: String
        public let strength: String?
        public let url: String?
        public let shopifyUrl: String?

        public init(state: String, strength: String? = nil, url: String? = nil, shopifyUrl: String? = nil) {
            self.state = state
            self.strength = strength
            self.url = url
            self.shopifyUrl = shopifyUrl
        }

        public static let loading = ProbeResult(state: "loading")

        /// The summary JSON of the asset (`{state, strength?, url?, shopifyUrl?}`), or `loading` when malformed.
        public static func of(json text: String?) -> ProbeResult {
            guard let text, let body = Json.object(text), let state = body.string("state") else { return .loading }
            return ProbeResult(state: state, strength: body.string("strength"), url: body.string("url"), shopifyUrl: body.string("shopifyUrl"))
        }
    }

    public enum Step: Equatable, Sendable {
        case `continue`(stage: Stage, challengeShown: Bool, noneHint: Bool)
        case product(url: String, shopifyUrl: String?)
        case fail(reason: String, host: String?)

        public var isContinue: Bool {
            if case .continue = self { return true }
            return false
        }
    }

    static let states: Set<String> = ["loading", "product", "challenge", "denied", "none"]

    /// The requested host, named by every failure.
    public let host: String?

    private let clock: () -> Int64
    private let sampleUrls: [String]
    private let dev: Bool
    private let requestedKey: String?
    private let started: Int64
    private var deadline: Int64
    private var extended = false
    private var currentUrl: String?
    private var complete = false
    private var completeSince: Int64?
    private var forcedNone = false
    private var failure: String?
    private var probed = false
    private var lastState = "loading"
    private var lastProduct: ProbeResult?
    private var since: [String: Int64] = [:]
    private var finished: Step?

    public init(requested: String, clock: @escaping () -> Int64, sampleUrls: [String] = Policy.appSampleUrls, dev: Bool = false) {
        self.clock = clock
        self.sampleUrls = sampleUrls
        self.dev = dev
        host = Policy.hostOf(requested)
        requestedKey = Policy.hostKey(requested)
        started = clock()
        deadline = started + Limits.readDeadlineMs
    }

    /// A main-frame navigation started (`didStartProvisionalNavigation` / `didCommit`).
    public func pageStarted(_ url: String) {
        currentUrl = url
        complete = false
        completeSince = nil
        forcedNone = false
    }

    /// A main-frame load finished (`didFinish`).
    public func pageFinished(_ url: String) {
        currentUrl = url
        if !complete {
            complete = true
            completeSince = clock()
        }
    }

    /// The main-frame URL changed without a load (KVO of `url`: SPA navigations).
    public func urlChanged(_ url: String) {
        currentUrl = url
    }

    /// The reader refused a navigation by the policy: the read continues like `none` on a finished page.
    public func refused() {
        forcedNone = true
        if !complete {
            complete = true
            completeSince = clock()
        }
    }

    /// A main-frame load error: `site_unreachable` on the requested host, `none` elsewhere.
    public func mainFrameError(_ url: String) {
        if let requestedKey, Policy.hostKey(url) == requestedKey {
            failure = "site_unreachable"
        } else {
            refused()
        }
    }

    /// One probe result of the page currently shown.
    public func probe(_ result: ProbeResult) {
        probed = true
        let here = currentUrl.flatMap { url -> String? in
            let lower = url.lowercased()
            return lower.hasPrefix("https://") || lower.hasPrefix("http:") ? url : nil
        }
        let same = here != nil && requestedKey != nil && Policy.hostKey(here) == requestedKey
        var state = ReadLoop.states.contains(result.state) ? result.state : "loading"

        if forcedNone || (here != nil && !allowed(here!)) {
            state = "none" // a refused end of a redirect is never probed and answers like `none`
        }
        if !same && state == "denied" {
            state = "none" // no cross-site oracle
        }
        if state == "product" {
            var accepted = false
            if let url = result.url, let here, allowed(url), let productHost = Policy.hostOf(url) {
                accepted = productHost == Policy.hostOf(here)
            }
            if !accepted {
                state = "loading" // a JS redirect between the URL change and the probe: look again
            }
        }

        mark(state)
        lastState = state
        lastProduct = state == "product" ? result : nil
    }

    /// What to do now. A `.product` or `.fail` ends the read: every later call answers the same step.
    public func tick() -> Step {
        if let finished { return finished }
        let now = clock()
        if let failure { return finish(.fail(reason: failure, host: host)) }

        if lastState == "product", let product = lastProduct, let url = product.url,
           product.strength == "ld" || (complete && now - (completeSince ?? now) >= Limits.metaSettleMs)
        {
            return finish(.product(url: url, shopifyUrl: product.shopifyUrl))
        }

        if lastState == "challenge" && !extended && elapsed(since["challenge"], now) > Limits.challengeSurfaceMs {
            extended = true
            deadline = now + Limits.challengeDeadlineMs
        }

        var noneHint = false
        if lastState == "none" && complete {
            let quiet = now - max(since["none"] ?? now, completeSince ?? now)
            noneHint = quiet > Limits.noneSurfaceMs
            if quiet > Limits.noneGiveUpMs {
                return finish(.fail(reason: "not_product", host: host))
            }
        }

        if lastState == "denied" && elapsed(since["denied"], now) > Limits.deniedMs {
            return finish(.fail(reason: "denied", host: host))
        }

        if now >= deadline {
            return finish(.fail(reason: since["challenge"] != nil ? "challenge_timeout" : "timeout", host: host))
        }

        let challengeShown = extended && lastState == "challenge"
        let stage: Stage
        if challengeShown {
            stage = .challenge
        } else if currentUrl == nil && !probed {
            stage = .opening
        } else if now - started >= Limits.slowMs {
            stage = .slow
        } else {
            stage = .loading
        }
        return .continue(stage: stage, challengeShown: challengeShown, noneHint: noneHint)
    }

    private func allowed(_ url: String) -> Bool {
        Policy.checkTarget(url, sampleUrls: sampleUrls, dev: dev).ok
    }

    /// The start of the current run of each probe state (`mark()` of `bg-core.js`).
    private func mark(_ state: String) {
        let now = clock()
        since = since.filter { $0.key == state }
        if since[state] == nil {
            since[state] = now
        }
    }

    private func elapsed(_ at: Int64?, _ now: Int64) -> Int64 {
        guard let at else { return 0 }
        return now - at
    }

    private func finish(_ step: Step) -> Step {
        finished = step
        return step
    }
}
